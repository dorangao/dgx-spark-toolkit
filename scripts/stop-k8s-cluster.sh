#!/usr/bin/env bash
set -euo pipefail

# Gracefully stop the local Kubernetes cluster and worker node(s)

load_network_overrides() {
    local -a candidates=()
    [[ -n "${DGX_SPARK_NETWORK_CONFIG:-}" ]] && candidates+=("$DGX_SPARK_NETWORK_CONFIG")
    candidates+=("$HOME/.config/dgx-spark-toolkit/network.env" "$HOME/.dgx-spark-network" "$HOME/dgx-spark-network.env")
    for cfg in "${candidates[@]}"; do
        [[ -f "$cfg" ]] || continue
        # shellcheck disable=SC1090
        source "$cfg"
    done
}
load_network_overrides

DEFAULT_K8S_API_IP="10.10.10.1"
DEFAULT_K8S_API_CIDR="10.10.10.1/24"
DEFAULT_INTERFACE="enP7s7"
DEFAULT_CONNECTION_NAME="Wired connection 3"

CONTROL_PLANE_API_IP="${CONTROL_PLANE_API_IP:-${K8S_API_IP:-$DEFAULT_K8S_API_IP}}"
CONTROL_PLANE_API_CIDR="${CONTROL_PLANE_API_CIDR:-${K8S_API_CIDR:-$DEFAULT_K8S_API_CIDR}}"
CONTROL_PLANE_INTERFACE="${CONTROL_PLANE_INTERFACE:-${INTERFACE:-$DEFAULT_INTERFACE}}"
CONTROL_PLANE_CONNECTION="${CONTROL_PLANE_CONNECTION:-${CONNECTION_NAME:-$DEFAULT_CONNECTION_NAME}}"

K8S_API_IP="$CONTROL_PLANE_API_IP"
K8S_API_CIDR="$CONTROL_PLANE_API_CIDR"
INTERFACE="$CONTROL_PLANE_INTERFACE"
CONNECTION_NAME="$CONTROL_PLANE_CONNECTION"

FABRIC_CTRL_IP="${FABRIC_CTRL_IP:-${CONTROL_PLANE_FABRIC_IP:-}}"
FABRIC_CTRL_CIDR="${FABRIC_CTRL_CIDR:-${CONTROL_PLANE_FABRIC_CIDR:-}}"
FABRIC_CTRL_INTERFACE="${FABRIC_CTRL_INTERFACE:-${CONTROL_PLANE_FABRIC_INTERFACE:-}}"
FABRIC_CTRL_CONNECTION="${FABRIC_CTRL_CONNECTION:-${CONTROL_PLANE_FABRIC_CONNECTION:-}}"

WORKER_NODE_NAME="${WORKER_NODE_NAME:-spark-ba63}"
WORKER_NODE_IP="${WORKER_NODE_IP:-10.10.10.2}"
WORKER_NODE_CIDR="${WORKER_NODE_CIDR:-10.10.10.2/30}"
WORKER_NODE_NETWORK="${WORKER_NODE_NETWORK:-10.10.10.0/30}"
WORKER_NODE_INTERFACE="${WORKER_NODE_INTERFACE:-enp1s0f0np0}"
WORKER_NODE_SSH_TARGET="${WORKER_NODE_SSH_TARGET:-192.168.86.39}"
WORKER_NODE_SSH_USER="${WORKER_NODE_SSH_USER:-${SUDO_USER:-$USER}}"
WORKER_NODE_SSH_PORT="${WORKER_NODE_SSH_PORT:-22}"
ENABLE_WORKER_JOIN="${ENABLE_WORKER_JOIN:-1}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-120}"
DRAIN_MAX_RETRIES="${DRAIN_MAX_RETRIES:-3}"
KUBECTL_TIMEOUT="${KUBECTL_TIMEOUT:-10s}"
FORCE_PDB_REMOVAL="${FORCE_PDB_REMOVAL:-1}"
PURGE_LONGHORN="${PURGE_LONGHORN:-1}"
SSH_WORKER_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

remove_interface_address() {
    local label="$1"
    local interface="$2"
    local cidr="$3"
    local connection="$4"
    local ip="${cidr%/*}"

    if [[ -z "$interface" || -z "$cidr" ]]; then
        return 0
    fi

    if ip -o -4 addr show dev "$interface" | awk '{print $4}' | grep -q "^${ip}/"; then
        log_info "Removing $label IP $cidr from $interface"
        ip addr del "$cidr" dev "$interface" >/dev/null 2>&1 || log_warn "Failed to remove $label IP from $interface"
    else
        log_info "$label IP $ip already absent from $interface"
    fi

    if [[ -z "$connection" ]]; then
        return 0
    fi

    if ! nmcli connection show "$connection" &>/dev/null; then
        return 0
    fi

    if nmcli connection show "$connection" | grep -q "$ip"; then
        if nmcli connection modify "$connection" -ipv4.addresses "$cidr" >/dev/null 2>&1; then
            log_info "Removed $label IP $cidr from NetworkManager connection $connection"
            return 0
        fi
        log_warn "Failed to remove $label IP $cidr from NetworkManager connection $connection"
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)."
        exit 1
    fi
}

ensure_kubeconfig() {
    local first sudo_home
    local -a candidates=()

    if [[ -n "${KUBECONFIG:-}" ]]; then
        first=${KUBECONFIG%%:*}
        if [[ -f "$first" ]]; then
            log_info "Using kubeconfig specified by KUBECONFIG: $KUBECONFIG"
            return 0
        else
            log_warn "KUBECONFIG is set to '$KUBECONFIG' but file not found; auto-detecting."
        fi
    fi

    if [[ -n "${SUDO_USER:-}" ]]; then
        sudo_home=$(getent passwd "$SUDO_USER" | cut -d: -f6 2>/dev/null || true)
        if [[ -n "$sudo_home" && -f "$sudo_home/.kube/config" ]]; then
            candidates+=("$sudo_home/.kube/config")
        fi
    fi

    [[ -f "$HOME/.kube/config" ]] && candidates+=("$HOME/.kube/config")
    candidates+=("/etc/kubernetes/admin.conf" \
        "/etc/rancher/k3s/k3s.yaml" \
        "/var/lib/rancher/k3s/server/cred/admin.kubeconfig")

    for cfg in "${candidates[@]}"; do
        if [[ -f "$cfg" ]]; then
            export KUBECONFIG="$cfg"
            log_info "Using kubeconfig: $KUBECONFIG"
            return 0
        fi
    done

    log_warn "Unable to locate kubeconfig automatically; kubectl commands may fail."
    return 1
}

kubectl_available() {
    kubectl --request-timeout="$KUBECTL_TIMEOUT" cluster-info >/dev/null 2>&1
}

worker_node_exists() {
    if [[ "$ENABLE_WORKER_JOIN" != "1" ]]; then
        return 1
    fi

    if kubectl --request-timeout="$KUBECTL_TIMEOUT" get node "$WORKER_NODE_NAME" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

worker_ssh() {
    local endpoint
    endpoint="${WORKER_NODE_SSH_USER}@${WORKER_NODE_SSH_TARGET}"
    sudo -u "$WORKER_NODE_SSH_USER" ssh "${SSH_WORKER_OPTS[@]}" -p "$WORKER_NODE_SSH_PORT" "$endpoint" "$@"
}

drain_node() {
    local node="$1"
    if ! kubectl_available; then
        log_warn "kubectl not available; cannot drain $node"
        return 1
    fi

    if ! kubectl get node "$node" >/dev/null 2>&1; then
        log_warn "Node $node not found in cluster"
        return 1
    fi

    local attempt=1
    while [[ $attempt -le $DRAIN_MAX_RETRIES ]]; do
        log_info "Draining node $node (attempt $attempt/$DRAIN_MAX_RETRIES)..."
        log_info "Streaming kubectl drain output (timeout ${DRAIN_TIMEOUT}s)..."
        local drain_log
        drain_log=$(mktemp)
        if timeout "$DRAIN_TIMEOUT" kubectl --request-timeout="$KUBECTL_TIMEOUT" drain "$node" --ignore-daemonsets --delete-emptydir-data --force --grace-period=30 --timeout=5m | tee "$drain_log"; then
            log_info "Node $node drained"
            rm -f "$drain_log"
            return 0
        fi

        local handled="false"
        if grep -qi "disruption budget" "$drain_log"; then
            log_warn "Drain blocked by PodDisruptionBudgets"
            if delete_all_pdbs; then
                handled="true"
            fi
        fi

        if delete_blocking_pods_from_log "$drain_log"; then
            handled="true"
        fi

        rm -f "$drain_log"

        if [[ "$handled" != "true" ]]; then
            break
        fi

        attempt=$((attempt + 1))
    done

    # Last-resort drain without PDB/eviction respect to avoid infinite loops while shutting down
    if kubectl drain --help 2>/dev/null | grep -q -- "--disable-eviction"; then
        log_warn "Attempting final drain of $node with eviction disabled and grace-period=0"
        if kubectl --request-timeout="$KUBECTL_TIMEOUT" drain "$node" --ignore-daemonsets --delete-emptydir-data --force --disable-eviction --grace-period=0 --timeout=3m >/dev/null 2>&1; then
            log_warn "Node $node drained via disable-eviction fallback"
            return 0
        fi
    fi

    log_warn "kubectl drain returned non-zero for $node after $DRAIN_MAX_RETRIES attempts"
    return 1
}

reset_worker_node() {
    if [[ "$ENABLE_WORKER_JOIN" != "1" ]]; then
        log_info "Worker automation disabled; skipping worker reset"
        return 0
    fi

    local endpoint="${WORKER_NODE_SSH_USER}@${WORKER_NODE_SSH_TARGET}"
    log_info "Connecting to worker $WORKER_NODE_NAME at $endpoint..."
    if ! worker_ssh true >/dev/null 2>&1; then
        log_warn "Unable to reach $endpoint; skipping remote cleanup"
        return 1
    fi

    worker_ssh "sudo bash -s" <<EOF
set -euo pipefail
systemctl stop kubelet >/dev/null 2>&1 || true
kubeadm reset -f >/dev/null 2>&1 || true

if ip -o -4 addr show dev "$WORKER_NODE_INTERFACE" | awk '{print \$4}' | grep -q "$WORKER_NODE_IP"; then
    ip addr del "$WORKER_NODE_CIDR" dev "$WORKER_NODE_INTERFACE" >/dev/null 2>&1 || true
fi

if ip route show "$WORKER_NODE_NETWORK" >/dev/null 2>&1; then
    ip route del "$WORKER_NODE_NETWORK" >/dev/null 2>&1 || true
fi

systemctl disable kubelet >/dev/null 2>&1 || true
EOF

    log_info "Worker $WORKER_NODE_NAME reset"
}

delete_worker_node_resource() {
    if worker_node_exists; then
        kubectl delete node "$WORKER_NODE_NAME" >/dev/null 2>&1 && \
            log_info "Deleted node object $WORKER_NODE_NAME" || true
    fi
}

delete_all_pdbs() {
    if [[ "$FORCE_PDB_REMOVAL" != "1" ]]; then
        log_warn "FORCE_PDB_REMOVAL=0; not deleting PodDisruptionBudgets"
        return 1
    fi

    if ! kubectl_available; then
        log_warn "kubectl unavailable; cannot delete PodDisruptionBudgets"
        return 1
    fi

    local pdbs
    pdbs=$(kubectl --request-timeout="$KUBECTL_TIMEOUT" get pdb -A -o name 2>/dev/null || true)
    if [[ -z "$pdbs" ]]; then
        log_info "No PodDisruptionBudgets present"
        return 0
    fi

    while IFS= read -r pdb; do
        [[ -z "$pdb" ]] && continue
        kubectl --request-timeout="$KUBECTL_TIMEOUT" delete "$pdb" --wait=false >/dev/null 2>&1 || true
    done <<< "$pdbs"

    log_info "Deleted PodDisruptionBudgets: $pdbs"
    return 0
}

delete_blocking_pods_from_log() {
    local log_file="$1"
    if [[ ! -s "$log_file" ]]; then
        return 1
    fi

    local pods
    pods=$(awk -F'"' '/error when evicting/ { if ($4 != "" && $2 != "") print $4" "$2 }' "$log_file" | sort -u)
    if [[ -z "$pods" ]]; then
        return 1
    fi

    local deleted_list=()
    while read -r ns pod; do
        [[ -z "$pod" || -z "$ns" ]] && continue
        if kubectl --request-timeout="$KUBECTL_TIMEOUT" delete pod "$pod" -n "$ns" --force --grace-period=0 --wait=false >/dev/null 2>&1; then
            deleted_list+=("$ns/$pod")
        fi
    done <<< "$pods"

    if [[ ${#deleted_list[@]} -gt 0 ]]; then
        log_warn "Force-deleted pods blocking drain: ${deleted_list[*]}"
        return 0
    fi

    return 1
}

purge_longhorn_instance_managers() {
    if [[ "$PURGE_LONGHORN" != "1" ]]; then
        return 0
    fi

    if ! kubectl_available; then
        return 1
    fi

    local pods
    pods=$(kubectl --request-timeout="$KUBECTL_TIMEOUT" get pods -n longhorn-system -l longhorn.io/component=instance-manager -o name 2>/dev/null || true)
    if [[ -z "$pods" ]]; then
        return 0
    fi

    log_info "Force deleting longhorn instance-manager pods before drain..."
    while read -r pod; do
        [[ -z "$pod" ]] && continue
        kubectl --request-timeout="$KUBECTL_TIMEOUT" delete "$pod" -n longhorn-system --force --grace-period=0 --wait=false >/dev/null 2>&1 || true
    done <<< "$pods"

    log_info "Requested deletion of: $pods"
    return 0
}

cordon_node() {
    local node="$1"
    if ! kubectl_available; then
        return 1
    fi

    if kubectl get node "$node" >/dev/null 2>&1; then
        if kubectl cordon "$node" >/dev/null 2>&1; then
            log_info "Cordoned node $node"
            return 0
        fi
    fi

    log_warn "Failed to cordon node $node"
    return 1
}

stop_control_plane() {
    log_info "Stopping kubelet on control plane..."
    if systemctl is-active --quiet kubelet; then
        systemctl stop kubelet && log_info "kubelet stopped" || log_warn "Failed to stop kubelet"
    else
        log_warn "kubelet already stopped"
    fi
}

cleanup_control_plane_network() {
    remove_interface_address "Control-plane API" "$INTERFACE" "$K8S_API_CIDR" "$CONNECTION_NAME"
    if [[ -n "$FABRIC_CTRL_INTERFACE" && -n "$FABRIC_CTRL_CIDR" ]]; then
        remove_interface_address "200G fabric" "$FABRIC_CTRL_INTERFACE" "$FABRIC_CTRL_CIDR" "$FABRIC_CTRL_CONNECTION"
    fi
}

pre_drain_cleanup() {
    # Try once up front so drains do not thrash on PDB/Longhorn instance managers
    purge_longhorn_instance_managers || true
    delete_all_pdbs || true
}

main() {
    log_info "Stopping Kubernetes cluster..."
    check_root
    ensure_kubeconfig || true
    pre_drain_cleanup

    if worker_node_exists; then
        drain_node "$WORKER_NODE_NAME" || true
        reset_worker_node || true
        delete_worker_node_resource || true
    else
        log_info "Worker node $WORKER_NODE_NAME not registered; skipping worker cleanup"
    fi

    if kubectl_available; then
        if ! drain_node "$(hostname)"; then
            log_warn "Drain of local node timed out; cordoning and continuing."
            cordon_node "$(hostname)" || true
        fi
    fi

    stop_control_plane
    cleanup_control_plane_network

    log_info "Cluster stop sequence complete."
    log_info "You can re-run start-k8s-cluster.sh to bring the cluster back online."
}

main "$@"
