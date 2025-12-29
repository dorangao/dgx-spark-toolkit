#!/usr/bin/env bash
set -euo pipefail

# Script to start/fix Kubernetes cluster by adding the required IP address
# This fixes the issue where the API server advertises 10.10.10.1 but it's not assigned

# Allow users to provide overrides via ~/.config/dgx-spark-toolkit/network.env (or DGX_SPARK_NETWORK_CONFIG)
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
DEFAULT_INTERFACE="enp1s0f1np1"
DEFAULT_CONNECTION_NAME="Wired connection 3"

CONTROL_PLANE_API_IP="${CONTROL_PLANE_API_IP:-${K8S_API_IP:-$DEFAULT_K8S_API_IP}}"
CONTROL_PLANE_API_CIDR="${CONTROL_PLANE_API_CIDR:-${K8S_API_CIDR:-$DEFAULT_K8S_API_CIDR}}"
CONTROL_PLANE_INTERFACE="${CONTROL_PLANE_INTERFACE:-${INTERFACE:-$DEFAULT_INTERFACE}}"
CONTROL_PLANE_CONNECTION="${CONTROL_PLANE_CONNECTION:-${CONNECTION_NAME:-$DEFAULT_CONNECTION_NAME}}"

# Keep legacy variable names available for downstream overrides/logging
K8S_API_IP="$CONTROL_PLANE_API_IP"
K8S_API_CIDR="$CONTROL_PLANE_API_CIDR"
INTERFACE="$CONTROL_PLANE_INTERFACE"
CONNECTION_NAME="$CONTROL_PLANE_CONNECTION"

# Optional fabric (200G) control-plane link. Leave unset unless you want a dedicated interconnect.
FABRIC_CTRL_IP="${FABRIC_CTRL_IP:-${CONTROL_PLANE_FABRIC_IP:-}}"
FABRIC_CTRL_CIDR="${FABRIC_CTRL_CIDR:-${CONTROL_PLANE_FABRIC_CIDR:-}}"
FABRIC_CTRL_INTERFACE="${FABRIC_CTRL_INTERFACE:-${CONTROL_PLANE_FABRIC_INTERFACE:-}}"
FABRIC_CTRL_CONNECTION="${FABRIC_CTRL_CONNECTION:-${CONTROL_PLANE_FABRIC_CONNECTION:-}}"

# Worker/secondary node defaults (override via environment variables if needed)
WORKER_NODE_NAME="${WORKER_NODE_NAME:-spark-ba63}"
WORKER_NODE_IP="${WORKER_NODE_IP:-10.10.10.2}"
WORKER_NODE_CIDR="${WORKER_NODE_CIDR:-10.10.10.2/24}"
WORKER_NODE_NETWORK="${WORKER_NODE_NETWORK:-10.10.10.0/24}"
WORKER_NODE_INTERFACE="${WORKER_NODE_INTERFACE:-enp1s0f1np1}"
# Space-delimited list of worker interfaces to try (first with carrier wins)
WORKER_NODE_INTERFACE_CANDIDATES="${WORKER_NODE_INTERFACE_CANDIDATES:-}"
if [[ -z "$WORKER_NODE_INTERFACE_CANDIDATES" ]]; then
    WORKER_NODE_INTERFACE_CANDIDATES="$WORKER_NODE_INTERFACE enP2p1s0f1np1 enp1s0f0np0 enP2p1s0f0np0"
fi
WORKER_NODE_SSH_TARGET="${WORKER_NODE_SSH_TARGET:-192.168.86.39}"
WORKER_NODE_SSH_USER="${WORKER_NODE_SSH_USER:-${SUDO_USER:-$USER}}"
WORKER_NODE_SSH_PORT="${WORKER_NODE_SSH_PORT:-22}"
ENABLE_WORKER_JOIN="${ENABLE_WORKER_JOIN:-1}"
SSH_WORKER_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)
WORKER_KUBEADM_RESET_TIMEOUT="${WORKER_KUBEADM_RESET_TIMEOUT:-120}"
WORKER_KUBEADM_JOIN_TIMEOUT="${WORKER_KUBEADM_JOIN_TIMEOUT:-420}"
WORKER_RESET_FALLBACK="${WORKER_RESET_FALLBACK:-1}" # 1: on kubeadm reset timeout, do a fast manual cleanup reset and continue
GPU_STATUS_MAX_RETRIES="${GPU_STATUS_MAX_RETRIES:-5}"
GPU_STATUS_RETRY_DELAY="${GPU_STATUS_RETRY_DELAY:-6}"
ENABLE_K8S_DASHBOARD="${ENABLE_K8S_DASHBOARD:-1}"
ENABLE_LONGHORN="${ENABLE_LONGHORN:-1}"
WORKSPACE_DEPLOY_DIR="${WORKSPACE_DEPLOY_DIR:-$HOME/workspace/deployments}"
LONGHORN_VALUES_FILE="${LONGHORN_VALUES_FILE:-$WORKSPACE_DEPLOY_DIR/longhorn-2node.yaml}"
SERVICE_STATUS_NAMESPACES=(${SERVICE_STATUS_NAMESPACES:-default kubernetes-dashboard longhorn-system})
GPU_STATUS_MAX_RETRIES="${GPU_STATUS_MAX_RETRIES:-5}"
GPU_STATUS_RETRY_DELAY="${GPU_STATUS_RETRY_DELAY:-6}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

has_timeout() {
    command -v timeout >/dev/null 2>&1
}

ensure_interface_address() {
    local label="$1"
    local interface="$2"
    local cidr="$3"
    local connection="$4"
    local ip="${cidr%/*}"

    if [[ -z "$interface" || -z "$cidr" ]]; then
        log_warn "Missing interface or CIDR for $label; skipping IP configuration"
        return 1
    fi

    if ! ip link show "$interface" >/dev/null 2>&1; then
        log_error "$label interface $interface not found"
        return 1
    fi

    if [[ -f "/sys/class/net/$interface/carrier" ]]; then
        if [[ "$(cat "/sys/class/net/$interface/carrier" 2>/dev/null)" == "0" ]]; then
            log_warn "$label interface $interface has NO-CARRIER (check cable/port); assigning IP anyway"
        fi
    fi

    if ip -o -4 addr show dev "$interface" | awk '{print $4}' | grep -q "^${ip}/"; then
        log_info "$label IP $ip already assigned to $interface"
    else
        log_info "Adding $label IP $cidr to $interface (temporary assignment)"
        if ip addr add "$cidr" dev "$interface" 2>/dev/null; then
            log_info "Successfully added $label IP to $interface"
        else
            log_warn "Failed to add $label IP $cidr to $interface (may already exist elsewhere)"
        fi
    fi

    if [[ -z "$connection" ]]; then
        return 0
    fi

    if ! nmcli connection show "$connection" &>/dev/null; then
        log_warn "NetworkManager connection '$connection' not found while persisting $label IP"
        nmcli connection show | grep -E "NAME|ethernet" || true
        return 1
    fi

    if nmcli connection show "$connection" | grep -q "$ip"; then
        log_info "$label IP already configured in NetworkManager connection $connection"
        return 0
    fi

    if nmcli connection modify "$connection" +ipv4.addresses "$cidr"; then
        log_info "Persisted $label IP $cidr to NetworkManager connection $connection"
        nmcli connection up "$connection" &>/dev/null || true
        return 0
    fi

    log_error "Failed to persist $label IP $cidr in NetworkManager connection $connection"
    return 1
}

# Detect or set a kubeconfig so kubectl works when running as root
ensure_kubeconfig() {
    local first candidate sudo_home
    local -a candidates=()

    # Honor pre-set KUBECONFIG if it points to an existing file
    if [[ -n "${KUBECONFIG:-}" ]]; then
        first=${KUBECONFIG%%:*}
        if [[ -f "$first" ]]; then
            log_info "Using kubeconfig specified by KUBECONFIG: $KUBECONFIG"
            return 0
        else
            log_warn "KUBECONFIG is set to '$KUBECONFIG' but the file is missing; trying auto-detect."
        fi
    fi

    # Probe common kubeconfig locations
    if [[ -n "${SUDO_USER:-}" ]]; then
        sudo_home=$(getent passwd "$SUDO_USER" | cut -d: -f6 2>/dev/null || true)
        if [[ -n "$sudo_home" && -f "$sudo_home/.kube/config" ]]; then
            candidates=("$sudo_home/.kube/config")
        fi
    fi

    [[ -f "$HOME/.kube/config" ]] && candidates+=("$HOME/.kube/config")
    candidates+=("/etc/kubernetes/admin.conf" \
        "/etc/rancher/k3s/k3s.yaml" \
        "/var/lib/rancher/k3s/server/cred/admin.kubeconfig")

    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            export KUBECONFIG="$candidate"
            log_info "Using kubeconfig: $KUBECONFIG"
            return 0
        fi
    done

    log_warn "Unable to locate a kubeconfig automatically; kubectl commands may fail."
    return 1
}

worker_ssh() {
    local endpoint
    endpoint="${WORKER_NODE_SSH_USER}@${WORKER_NODE_SSH_TARGET}"
    sudo -u "$WORKER_NODE_SSH_USER" ssh "${SSH_WORKER_OPTS[@]}" -p "$WORKER_NODE_SSH_PORT" "$endpoint" "$@"
}

worker_ssh_timeout() {
    local seconds="$1"
    shift
    local endpoint
    endpoint="${WORKER_NODE_SSH_USER}@${WORKER_NODE_SSH_TARGET}"

    if has_timeout; then
        timeout --preserve-status "${seconds}s" sudo -u "$WORKER_NODE_SSH_USER" ssh "${SSH_WORKER_OPTS[@]}" -p "$WORKER_NODE_SSH_PORT" "$endpoint" "$@"
        return $?
    fi

    sudo -u "$WORKER_NODE_SSH_USER" ssh "${SSH_WORKER_OPTS[@]}" -p "$WORKER_NODE_SSH_PORT" "$endpoint" "$@"
}

worker_fast_reset() {
    # Fallback for when `kubeadm reset` hangs (often in kubelet/pod cleanup).
    # Removes Kubernetes state on the worker and restarts container runtime so join can proceed.
    log_warn "Performing fast reset fallback on ${WORKER_NODE_NAME} (manual cleanup)..."

    worker_ssh "sudo -n bash -s" <<'EOF'
set -euo pipefail

systemctl stop kubelet >/dev/null 2>&1 || true

# Stop common container runtimes to release sandboxes/mounts.
for svc in containerd docker crio; do
  systemctl stop "$svc" >/dev/null 2>&1 || true
done

# Kill any in-flight kubeadm reset/join processes.
pids="$(pgrep -f 'kubeadm (reset|join)' 2>/dev/null || true)"
if [[ -n "$pids" ]]; then
  kill -TERM $pids >/dev/null 2>&1 || true
  sleep 2
  kill -KILL $pids >/dev/null 2>&1 || true
fi

# Best-effort unmount anything under /var/lib/kubelet (lazy/force).
if command -v findmnt >/dev/null 2>&1; then
  (findmnt -R -n -o TARGET /var/lib/kubelet 2>/dev/null || true) | sort -r | while read -r m; do
    [[ -z "$m" ]] && continue
    umount -lf "$m" >/dev/null 2>&1 || true
  done
else
  (grep -E ' /var/lib/kubelet' /proc/mounts 2>/dev/null || true) | awk '{print $2}' | sort -r | while read -r m; do
    [[ -z "$m" ]] && continue
    umount -lf "$m" >/dev/null 2>&1 || true
  done
fi

# Remove kubeadm/kubelet state.
rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd /etc/cni/net.d /var/lib/cni
mkdir -p /var/lib/kubelet

# Bring runtime back so kubeadm join can start kubelet cleanly.
for svc in containerd docker crio; do
  systemctl start "$svc" >/dev/null 2>&1 || true
done
EOF
}

ensure_helm_repo() {
    local repo_name="$1"
    local repo_url="$2"

    if ! command -v helm >/dev/null 2>&1; then
        log_warn "Helm not installed; cannot manage repo $repo_name"
        return 1
    fi

    if ! helm repo list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$repo_name"; then
        if ! helm repo add "$repo_name" "$repo_url" >/dev/null 2>&1; then
            log_warn "Failed to add Helm repo $repo_name"
            return 1
        fi
    fi

    if ! helm repo update "$repo_name" >/dev/null 2>&1; then
        helm repo update >/dev/null 2>&1 || true
    fi

    return 0
}

ensure_kubernetes_dashboard() {
    if [[ "$ENABLE_K8S_DASHBOARD" != "1" ]]; then
        log_info "Skipping Kubernetes dashboard deployment (ENABLE_K8S_DASHBOARD=$ENABLE_K8S_DASHBOARD)"
        return 0
    fi

    if ! command -v helm >/dev/null 2>&1; then
        log_warn "Helm not installed; cannot manage Kubernetes dashboard"
        return 1
    fi

    ensure_helm_repo kubernetes-dashboard https://kubernetes.github.io/dashboard/ || true

    if ! helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
        --namespace kubernetes-dashboard --create-namespace \
        --set metricsScraper.enabled=true --set metrics-server.enabled=true >/dev/null 2>&1; then
        log_warn "Failed to deploy Kubernetes dashboard via Helm"
        return 1
    fi

    local admin_manifest="$WORKSPACE_DEPLOY_DIR/dashboard-admin.yaml"
    if [[ -f "$admin_manifest" ]]; then
        kubectl apply -f "$admin_manifest" >/dev/null 2>&1 || log_warn "Failed to apply dashboard admin manifest"
    fi

    local ingress_manifest="$WORKSPACE_DEPLOY_DIR/dashboard-ingress.yaml"
    if [[ -f "$ingress_manifest" ]]; then
        kubectl apply -f "$ingress_manifest" >/dev/null 2>&1 || log_warn "Failed to apply dashboard ingress manifest"
    fi

    kubectl -n kubernetes-dashboard rollout status deployment/kubernetes-dashboard-web --timeout=180s >/dev/null 2>&1 || \
        log_warn "Dashboard web deployment not ready yet"

    return 0
}

ensure_longhorn() {
    if [[ "$ENABLE_LONGHORN" != "1" ]]; then
        log_info "Skipping Longhorn deployment (ENABLE_LONGHORN=$ENABLE_LONGHORN)"
        return 0
    fi

    if ! command -v helm >/dev/null 2>&1; then
        log_warn "Helm not installed; cannot manage Longhorn"
        return 1
    fi

    ensure_helm_repo longhorn https://charts.longhorn.io || true

    local values_args=()
    if [[ -f "$LONGHORN_VALUES_FILE" ]]; then
        values_args=(-f "$LONGHORN_VALUES_FILE")
    fi

    if ! helm upgrade --install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace "${values_args[@]}" >/dev/null 2>&1; then
        log_warn "Failed to deploy Longhorn via Helm"
        return 1
    fi

    kubectl -n longhorn-system rollout status deployment/longhorn-manager --timeout=300s >/dev/null 2>&1 || \
        log_warn "Longhorn manager deployment not ready yet"

    kubectl -n longhorn-system rollout status deployment/longhorn-driver-deployer --timeout=180s >/dev/null 2>&1 || true

    return 0
}

show_service_status() {
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_warn "Skipping service status summary - cluster not accessible"
        return
    fi

    log_info "Service status summary:"

    for ns in "${SERVICE_STATUS_NAMESPACES[@]}"; do
        [[ -z "$ns" ]] && continue
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            log_info "Namespace: $ns"
            kubectl get pods -n "$ns" 2>/dev/null || true
            kubectl get svc -n "$ns" 2>/dev/null || true
        fi
    done

    log_info "Default namespace ingress/endpoints:"
    kubectl get ingress 2>/dev/null || true
    kubectl get svc 2>/dev/null || true
}

ensure_control_plane_network() {
    ensure_interface_address "Control-plane API" "$INTERFACE" "$K8S_API_CIDR" "$CONNECTION_NAME" || true
}

ensure_fabric_network() {
    if [[ -z "$FABRIC_CTRL_INTERFACE" || -z "$FABRIC_CTRL_CIDR" ]]; then
        return 0
    fi
    ensure_interface_address "200G fabric" "$FABRIC_CTRL_INTERFACE" "$FABRIC_CTRL_CIDR" "$FABRIC_CTRL_CONNECTION" || true
}

configure_worker_network() {
    log_info "Ensuring ${WORKER_NODE_NAME} has ${WORKER_NODE_CIDR} on a linked interface (candidates: ${WORKER_NODE_INTERFACE} ${WORKER_NODE_INTERFACE_CANDIDATES})..."
    local endpoint="${WORKER_NODE_SSH_USER}@${WORKER_NODE_SSH_TARGET}"
    local selected_if=""
    local output=""

    if worker_ssh "true" >/dev/null 2>&1; then
        if output=$(worker_ssh "sudo -n bash -s" <<EOF
set -euo pipefail
TARGET_IF="$WORKER_NODE_INTERFACE"
TARGET_CIDR="$WORKER_NODE_CIDR"
TARGET_IP="$WORKER_NODE_IP"
TARGET_ROUTE="$WORKER_NODE_NETWORK"
CANDIDATE_STR="$WORKER_NODE_INTERFACE_CANDIDATES"

read -r -a CANDIDATES <<<"\$CANDIDATE_STR"
if [[ "\${#CANDIDATES[@]}" -eq 0 ]]; then
    CANDIDATES=(\$TARGET_IF)
fi

# Pick first candidate with carrier; otherwise first existing
pick_if=""
for cand in "\${CANDIDATES[@]}"; do
    [[ -z "\$cand" ]] && continue
    if ! ip link show "\$cand" >/dev/null 2>&1; then
        continue
    fi
    [[ -z "\$pick_if" ]] && pick_if="\$cand"
    carrier="\$(cat "/sys/class/net/\$cand/carrier" 2>/dev/null || echo 0)"
    if [[ "\$carrier" == "1" ]]; then
        pick_if="\$cand"
        break
    fi
done

if [[ -z "\$pick_if" ]]; then
    echo "No candidate interfaces found: \$CANDIDATE_STR" >&2
    exit 1
fi

if [[ "\$pick_if" != "\$TARGET_IF" ]]; then
    echo "Using interface \$pick_if (requested \$TARGET_IF)" >&2
fi
TARGET_IF="\$pick_if"
echo "SELECTED_IF=\$TARGET_IF"

if ! ip link show "\$TARGET_IF" >/dev/null 2>&1; then
    echo "Interface \$TARGET_IF not found" >&2
    exit 1
fi

# Fail fast if the link has no carrier so the user can fix cabling/port selection
if [[ -f "/sys/class/net/\$TARGET_IF/carrier" ]]; then
    if [[ "\$(cat "/sys/class/net/\$TARGET_IF/carrier" 2>/dev/null)" == "0" ]]; then
        echo "Interface \$TARGET_IF reports NO-CARRIER. Connect the cable or choose a port with link, then rerun." >&2
        exit 2
    fi
fi

# Ensure link is up so the point-to-point network can come up
ip link set "\$TARGET_IF" up || true

# Remove any stale assignments of the same IP on other interfaces
ip -o -4 addr show | awk '{print \$2" "\$4}' | while read -r iface cidr; do
    addr="\${cidr%/*}"
    if [[ "\$addr" == "\$TARGET_IP" && "\$iface" != "\$TARGET_IF" ]]; then
        ip addr del "\$cidr" dev "\$iface" || true
    fi
done

if ip -o -4 addr show dev "\$TARGET_IF" | awk '{print \$4}' | grep -q "\$TARGET_IP"; then
    echo "IP already configured on \$TARGET_IF"
else
    ip addr add "\$TARGET_CIDR" dev "\$TARGET_IF"
fi

ip route show "\$TARGET_ROUTE" >/dev/null 2>&1 || ip route add "\$TARGET_ROUTE" dev "\$TARGET_IF" || true

# Confirm the worker can reach the control-plane API IP before attempting join
if ! ping -c 2 -W 1 "$K8S_API_IP" >/dev/null 2>&1; then
    echo "Worker cannot reach control-plane at $K8S_API_IP. Check cabling/port and retry." >&2
    exit 3
fi
EOF
        ); then
            printf "%s\n" "$output"
            selected_if=$(printf "%s\n" "$output" | awk -F= '/^SELECTED_IF=/{print $2; exit}')
            if [[ -n "$selected_if" ]]; then
                WORKER_NODE_INTERFACE="$selected_if"
            fi
            log_info "Worker network configured on ${WORKER_NODE_NAME} (${endpoint})"
            return 0
        else
            printf "%s\n" "${output:-}" >&2
        fi
    fi

    log_warn "Failed to configure worker network on ${endpoint}"
    return 1
}

ensure_worker_api_reachable() {
    log_info "Validating ${WORKER_NODE_NAME} can reach Kubernetes API ${K8S_API_IP}:6443..."

    # Pass variables explicitly to avoid escaping issues in heredoc
    local remote_script
    remote_script=$(cat <<'REMOTE_EOF'
set -euo pipefail
API_IP="$1"
P2P_IF="$2"
SSH_IP="$3"

# If the point-to-point interface has no carrier, route the API IP over the SSH/mgmt interface.
carrier=""
if [[ -r "/sys/class/net/$P2P_IF/carrier" ]]; then
    carrier="$(cat "/sys/class/net/$P2P_IF/carrier" 2>/dev/null || true)"
fi

if [[ "$carrier" == "0" ]]; then
    # Find the interface that has the SSH/management IP
    mgmt_if="$(ip -o -4 addr show | awk -v ip="$SSH_IP" '$4 ~ "^"ip"/" {print $2; exit}')"
    if [[ -n "$mgmt_if" ]]; then
        echo "NO-CARRIER on $P2P_IF; routing API traffic over management interface $mgmt_if" >&2
        ip route replace "${API_IP}/32" dev "$mgmt_if" || true
    fi
fi

for _ in $(seq 1 5); do
    if command -v timeout >/dev/null 2>&1; then
        timeout 2 bash -lc "</dev/tcp/${API_IP}/6443" >/dev/null 2>&1 && exit 0
    else
        bash -lc "</dev/tcp/${API_IP}/6443" >/dev/null 2>&1 && exit 0
    fi
    sleep 1
done

echo "Unable to reach Kubernetes API at ${API_IP}:6443 from worker" >&2
ip route get "$API_IP" >&2 || true
ip -o link show "$P2P_IF" >&2 || true
exit 1
REMOTE_EOF
)

    if worker_ssh "sudo -n bash -s -- '$K8S_API_IP' '$WORKER_NODE_INTERFACE' '$WORKER_NODE_SSH_TARGET'" <<< "$remote_script"; then
        return 0
    fi

    log_error "Worker cannot reach Kubernetes API ${K8S_API_IP}:6443; check cabling/carrier on ${WORKER_NODE_INTERFACE} or override WORKER_NODE_INTERFACE/WORKER_NODE_CIDR."
    return 1
}

register_worker_node() {
    if [[ "$ENABLE_WORKER_JOIN" != "1" ]]; then
        log_info "Worker node setup disabled (ENABLE_WORKER_JOIN=$ENABLE_WORKER_JOIN)"
        return 0
    fi

    local endpoint="${WORKER_NODE_SSH_USER}@${WORKER_NODE_SSH_TARGET}"
    local ready_status=""

    if kubectl get node "$WORKER_NODE_NAME" >/dev/null 2>&1; then
        ready_status=$(kubectl get node "$WORKER_NODE_NAME" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || echo "")
        if [[ "$ready_status" == "True" ]]; then
            log_info "Node ${WORKER_NODE_NAME} already part of the cluster and Ready; skipping worker join"
            return 0
        fi

        log_warn "Node ${WORKER_NODE_NAME} exists but is not Ready; deleting API object to rejoin"
        if ! kubectl delete node "$WORKER_NODE_NAME" --wait=true --timeout=60s 2>/dev/null; then
            kubectl delete node "$WORKER_NODE_NAME" --force --grace-period=0 2>/dev/null || true
        fi

        # Wait for the node object to be fully removed from the API before proceeding
        local delete_wait=0
        local delete_max=30
        while kubectl get node "$WORKER_NODE_NAME" >/dev/null 2>&1; do
            delete_wait=$((delete_wait + 1))
            if [[ $delete_wait -ge $delete_max ]]; then
                log_error "Timed out waiting for node ${WORKER_NODE_NAME} to be deleted from API"
                return 1
            fi
            sleep 1
        done
        log_info "Node ${WORKER_NODE_NAME} removed from cluster API"
    fi

    log_info "Preparing worker node ${WORKER_NODE_NAME} via ${endpoint}..."

    if ! worker_ssh "true" >/dev/null 2>&1; then
        log_warn "Unable to reach ${endpoint}; skipping worker node join"
        return 1
    fi

    if ! worker_ssh "sudo -n true" >/dev/null 2>&1; then
        log_error "Remote sudo on ${WORKER_NODE_NAME} requires a password (non-interactive sudo failed). Configure NOPASSWD sudo for ${WORKER_NODE_SSH_USER} or run the join manually."
        return 1
    fi

    local worker_has_timeout=0
    if worker_ssh "command -v timeout >/dev/null 2>&1"; then
        worker_has_timeout=1
    fi

    if ! configure_worker_network; then
        return 1
    fi

    if ! ensure_worker_api_reachable; then
        return 1
    fi

    local join_cmd
    if ! join_cmd=$(sudo kubeadm token create --print-join-command 2>/dev/null); then
        log_error "Failed to generate kubeadm join command"
        return 1
    fi

    join_cmd+=" --node-name ${WORKER_NODE_NAME}"

    log_info "Resetting kubeadm state on ${WORKER_NODE_NAME} (timeout: ${WORKER_KUBEADM_RESET_TIMEOUT}s)..."
    local reset_rc=0
    local remote_reset_cmd="sudo -n kubeadm reset -f"
    if [[ $worker_has_timeout -eq 1 ]]; then
        remote_reset_cmd="sudo -n timeout --preserve-status ${WORKER_KUBEADM_RESET_TIMEOUT}s kubeadm reset -f"
    fi
    worker_ssh_timeout "$WORKER_KUBEADM_RESET_TIMEOUT" "$remote_reset_cmd" || reset_rc=$?
    if [[ $reset_rc -ne 0 ]]; then
        if has_timeout && [[ $reset_rc -eq 124 ]]; then
            log_error "Timed out after ${WORKER_KUBEADM_RESET_TIMEOUT}s while running kubeadm reset on ${WORKER_NODE_NAME} (adjust WORKER_KUBEADM_RESET_TIMEOUT to override)"
        fi
        if [[ "${WORKER_RESET_FALLBACK}" == "1" ]]; then
            log_warn "kubeadm reset failed on ${WORKER_NODE_NAME} (rc=$reset_rc); attempting fast reset fallback..."
            if worker_fast_reset; then
                log_warn "Fast reset fallback completed; continuing to kubeadm join..."
                reset_rc=0
            fi
        fi

        if [[ $reset_rc -ne 0 ]]; then
            log_error "Failed to reset kubeadm on ${WORKER_NODE_NAME}"
            return 1
        fi
    fi

    log_info "Ensuring container runtime is running on ${WORKER_NODE_NAME}..."
    # kubeadm join requires a functioning CRI socket; attempt to start common runtimes and wait briefly for sockets.
    worker_ssh "sudo -n systemctl start containerd >/dev/null 2>&1 || true; sudo -n systemctl start docker >/dev/null 2>&1 || true; sudo -n systemctl start crio >/dev/null 2>&1 || true" || true
    worker_ssh "sudo -n bash -s" <<'EOF' || true
set -euo pipefail
for _ in $(seq 1 15); do
  if [[ -S /run/containerd/containerd.sock || -S /var/run/containerd/containerd.sock || -S /var/run/cri-dockerd.sock || -S /run/crio/crio.sock || -S /var/run/crio/crio.sock ]]; then
    exit 0
  fi
  sleep 1
done
exit 1
EOF

    # Final check: ensure node doesn't exist before join (handles race conditions)
    if kubectl get node "$WORKER_NODE_NAME" >/dev/null 2>&1; then
        local final_ready
        final_ready=$(kubectl get node "$WORKER_NODE_NAME" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || echo "")
        if [[ "$final_ready" == "True" ]]; then
            log_info "Node ${WORKER_NODE_NAME} became Ready during preparation; skipping join"
            return 0
        fi
        log_warn "Node ${WORKER_NODE_NAME} still exists in API (status: ${final_ready:-Unknown}); force-deleting before join"
        kubectl delete node "$WORKER_NODE_NAME" --force --grace-period=0 2>/dev/null || true
        sleep 3
        if kubectl get node "$WORKER_NODE_NAME" >/dev/null 2>&1; then
            log_error "Cannot remove stale node ${WORKER_NODE_NAME} from cluster API; kubeadm join will likely fail"
        fi
    fi

    log_info "Executing kubeadm join on ${WORKER_NODE_NAME}..."
    local join_rc=0
    local remote_join_cmd="sudo -n $join_cmd"
    if [[ $worker_has_timeout -eq 1 ]]; then
        remote_join_cmd="sudo -n timeout --preserve-status ${WORKER_KUBEADM_JOIN_TIMEOUT}s $join_cmd"
    fi
    worker_ssh_timeout "$WORKER_KUBEADM_JOIN_TIMEOUT" "$remote_join_cmd" || join_rc=$?
    if [[ $join_rc -eq 0 ]]; then
        log_info "kubeadm join completed on ${WORKER_NODE_NAME}"
        worker_ssh "sudo -n systemctl enable --now kubelet" >/dev/null 2>&1 || true
        return 0
    fi

    if has_timeout && [[ $join_rc -eq 124 ]]; then
        log_error "Timed out after ${WORKER_KUBEADM_JOIN_TIMEOUT}s while running kubeadm join on ${WORKER_NODE_NAME} (adjust WORKER_KUBEADM_JOIN_TIMEOUT to override)"
    fi
    log_error "kubeadm join failed on ${WORKER_NODE_NAME}"
    return 1
}

wait_for_worker_ready() {
    local attempts=15
    local delay=4
    local count=0

    while [[ $count -lt $attempts ]]; do
        if kubectl get node "$WORKER_NODE_NAME" >/dev/null 2>&1; then
            local ready
            ready=$(kubectl get node "$WORKER_NODE_NAME" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || echo "")
            if [[ "$ready" == "True" ]]; then
                log_info "Node ${WORKER_NODE_NAME} is Ready"
                return 0
            fi
        fi

        count=$((count + 1))
        sleep "$delay"
    done

    log_warn "Node ${WORKER_NODE_NAME} did not become Ready within $((attempts * delay)) seconds"
    return 1
}

label_worker_node() {
    if kubectl get node "$WORKER_NODE_NAME" >/dev/null 2>&1; then
        if kubectl label node "$WORKER_NODE_NAME" node-role.kubernetes.io/worker=worker --overwrite >/dev/null 2>&1; then
            log_info "Applied worker label to ${WORKER_NODE_NAME}"
        fi
    fi
}

ensure_worker_node() {
    if [[ "$ENABLE_WORKER_JOIN" != "1" ]]; then
        log_info "Skipping worker node setup (ENABLE_WORKER_JOIN=$ENABLE_WORKER_JOIN)"
        return 0
    fi

    if register_worker_node; then
        wait_for_worker_ready || true
        label_worker_node || true
        return 0
    fi

    log_warn "Worker node setup encountered issues"
    return 1
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Verify Kubernetes cluster is accessible
verify_cluster() {
    log_info "Verifying Kubernetes cluster accessibility..."
    
    # Wait a moment for network changes to propagate
    sleep 2
    
    # Retry logic - sometimes it takes a moment for network changes to propagate
    local max_retries=5
    local retry_count=0
    local success=false
    
    while [[ $retry_count -lt $max_retries ]]; do
        # Check if kubectl can reach the cluster
        if kubectl cluster-info &>/dev/null; then
            success=true
            break
        fi
        
        retry_count=$((retry_count + 1))
        if [[ $retry_count -lt $max_retries ]]; then
            log_info "Waiting for cluster to become accessible (attempt $retry_count/$max_retries)..."
            sleep 2
        fi
    done
    
    if $success; then
        log_info "✓ Kubernetes cluster is accessible!"
        echo ""
        kubectl cluster-info
        echo ""
        log_info "Cluster nodes:"
        kubectl get nodes
        return 0
    else
        log_warn "Kubernetes cluster may not be fully accessible yet"
        log_info "Trying to check API server health..."
        
        # Try to check API server health endpoint
        if curl -k -s --connect-timeout 5 "https://${K8S_API_IP}:6443/healthz" 2>/dev/null | grep -q "ok"; then
            log_info "✓ API server is responding on $K8S_API_IP:6443"
            log_warn "However, kubectl still cannot connect after $max_retries attempts."
            log_info "The IP address has been configured. Try running 'kubectl cluster-info' manually in a moment."
            return 1
        else
            log_error "API server is not responding on $K8S_API_IP:6443"
            return 1
        fi
    fi
}

# Check if Kubernetes components are running
check_k8s_components() {
    log_info "Checking Kubernetes control plane components..."

    # kubelet manages the control-plane static pods, so ensure it is running first
    if systemctl is-active --quiet kubelet; then
        log_info "✓ kubelet service is running"
    else
        log_warn "kubelet service is not running; attempting to start it..."
        if systemctl start kubelet && systemctl is-active --quiet kubelet; then
            log_info "✓ kubelet service started"
        else
            log_error "✗ kubelet service is not running"
            return 1
        fi
    fi

    local attempt=1
    local max_attempts=5
    local delay=4

    while [[ $attempt -le $max_attempts ]]; do
        local components_ok=true

        if pgrep -f kube-apiserver >/dev/null; then
            log_info "✓ kube-apiserver is running"
        else
            log_error "✗ kube-apiserver is not running"
            components_ok=false
        fi

        if pgrep -f etcd >/dev/null; then
            log_info "✓ etcd is running"
        else
            log_error "✗ etcd is not running"
            components_ok=false
        fi

        if pgrep -f kube-controller-manager >/dev/null; then
            log_info "✓ kube-controller-manager is running"
        else
            log_error "✗ kube-controller-manager is not running"
            components_ok=false
        fi

        if pgrep -f kube-scheduler >/dev/null; then
            log_info "✓ kube-scheduler is running"
        else
            log_error "✗ kube-scheduler is not running"
            components_ok=false
        fi

        if $components_ok; then
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            log_warn "Control plane components not ready yet; retrying in ${delay}s (attempt $attempt/$max_attempts)..."
            sleep "$delay"
        fi

        attempt=$((attempt + 1))
    done

    log_error "Some Kubernetes components are not running. You may need to start them first."
    return 1
}

# Check GPU status on nodes
check_gpu_status() {
    log_info "Checking GPU availability on nodes..."
    
    if ! kubectl cluster-info &>/dev/null; then
        log_warn "Cannot check GPU status - cluster not accessible yet"
        return 1
    fi

    local attempt=1
    while [[ $attempt -le $GPU_STATUS_MAX_RETRIES ]]; do
        local gpu_info
        gpu_info=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null || echo "")

        if [[ -z "$gpu_info" ]]; then
            log_warn "Could not retrieve GPU information from nodes"
            return 1
        fi

        local total_gpus=0
        local nodes_with_gpus=0
        local missing_nodes=()

        while IFS=$'\t' read -r node_name gpu_count; do
            [[ -z "$node_name" ]] && continue
            if [[ -n "$gpu_count" && "$gpu_count" != "<none>" && "$gpu_count" =~ ^[0-9]+$ ]]; then
                log_info "✓ Node $node_name: $gpu_count GPU(s) available"
                total_gpus=$((total_gpus + gpu_count))
                nodes_with_gpus=$((nodes_with_gpus + 1))
            else
                missing_nodes+=("$node_name")
            fi
        done <<< "$gpu_info"

        if [[ ${#missing_nodes[@]} -eq 0 ]]; then
            log_info "Total GPUs available across cluster: $total_gpus"
            return 0
        fi

        if [[ $attempt -eq $GPU_STATUS_MAX_RETRIES ]]; then
            for node in "${missing_nodes[@]}"; do
                log_warn "⚠ Node $node: No GPUs detected"
            done
            if [[ $nodes_with_gpus -gt 0 ]]; then
                log_info "Total GPUs available across cluster: $total_gpus"
                return 0
            fi
            log_warn "No GPUs detected on any nodes"
            log_info "Note: GPUs are managed by the GPU operator and should be automatically detected"
            return 1
        fi

        log_info "GPUs not detected yet on: ${missing_nodes[*]} (attempt $attempt/$GPU_STATUS_MAX_RETRIES). Waiting ${GPU_STATUS_RETRY_DELAY}s..."
        sleep "$GPU_STATUS_RETRY_DELAY"
        attempt=$((attempt + 1))
    done

    return 1
}

# Main execution
main() {
    log_info "Starting Kubernetes cluster setup..."
    echo ""
    
    # Check if running as root
    check_root

    # Ensure kubectl has credentials to talk to the cluster
    ensure_kubeconfig || true

    # Fix control-plane/fabric IPs before we check control-plane processes
    ensure_control_plane_network
    ensure_fabric_network
    echo ""

    # Check Kubernetes components
    if ! check_k8s_components; then
        log_error "Cannot proceed - Kubernetes components are not running"
        exit 1
    fi
    
    echo ""

    # Verify cluster accessibility
    if verify_cluster; then
        echo ""
        ensure_worker_node || true
        echo ""
        ensure_kubernetes_dashboard || true
        ensure_longhorn || true
        echo ""
        show_service_status || true
        echo ""
        # Check GPU status
        check_gpu_status
        echo ""
        log_info "Kubernetes cluster is ready!"
        exit 0
    else
        log_warn "Cluster verification had issues, but IP address has been configured"
        log_info "You may need to wait a few moments and run: kubectl cluster-info"
        exit 1
    fi
}

# Run main function
main "$@"
