#!/usr/bin/env bash
set -euo pipefail

# Lightweight health check for an existing Kubernetes deployment.
# The script intentionally reuses logging helpers and kubeconfig detection
# logic from the start/stop scripts so it behaves consistently when
# executed via the Cluster Control UI or manually via CLI.

SERVICE_STATUS_NAMESPACES=(${SERVICE_STATUS_NAMESPACES:-default kubernetes-dashboard longhorn-system})
READYZ_PATH="${READYZ_PATH:-/readyz?verbose}"
READYZ_TIMEOUT="${READYZ_TIMEOUT:-5}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

ensure_kubeconfig() {
    local first candidate sudo_home
    local -a candidates=()

    if [[ -n "${KUBECONFIG:-}" ]]; then
        first=${KUBECONFIG%%:*}
        if [[ -f "$first" ]]; then
            log_info "Using kubeconfig specified by KUBECONFIG: $KUBECONFIG"
            return 0
        fi
        log_warn "KUBECONFIG points to '$KUBECONFIG' but file missing; probing defaults."
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

    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            export KUBECONFIG="$candidate"
            log_info "Using kubeconfig: $KUBECONFIG"
            return 0
        fi
    done

    log_warn "Unable to locate a kubeconfig automatically; kubectl may fail."
    return 1
}

require_kubectl() {
    if ! command -v kubectl >/dev/null 2>&1; then
        log_error "kubectl binary not found in PATH"
        exit 1
    fi
}

check_apiserver() {
    log_info "Verifying API server health endpoint (${READYZ_PATH})..."
    if ! kubectl get --raw "${READYZ_PATH}" --request-timeout="${READYZ_TIMEOUT}s" >/dev/null 2>&1; then
        log_warn "Unable to query /readyz endpoint; cluster may still be initializing."
        return 1
    fi
    log_info "API server readyz endpoint responded successfully."
}

show_nodes() {
    log_info "Cluster nodes:"
    if ! kubectl get nodes -o wide; then
        log_warn "kubectl get nodes failed."
        return 1
    fi
}

show_component_status() {
    log_info "Control plane component readiness:"
    if ! kubectl get --raw='/healthz?verbose' >/dev/null 2>&1; then
        log_warn "Unable to query /healthz endpoint; continuing."
    else
        kubectl get --raw='/healthz?verbose' | sed 's/failed/FAILED/g'
    fi
}

show_service_status() {
    log_info "Service status summary:"
    for ns in "${SERVICE_STATUS_NAMESPACES[@]}"; do
        [[ -z "$ns" ]] && continue
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            log_info "Namespace: $ns"
            kubectl get pods -n "$ns" 2>/dev/null || true
            kubectl get svc -n "$ns" 2>/dev/null || true
        else
            log_warn "Namespace $ns missing"
        fi
    done

    log_info "Default namespace ingress/endpoints:"
    kubectl get ingress 2>/dev/null || true
    kubectl get svc 2>/dev/null || true
}

show_gpu_status() {
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        log_warn "nvidia-smi not found; skipping GPU inventory."
        return
    fi
    log_info "Checking GPUs visible to control-plane host:"
    nvidia-smi --query-gpu=index,name,memory.total,memory.used,temperature.gpu \
        --format=csv,noheader,nounits 2>/dev/null || log_warn "Failed to query GPU state via nvidia-smi."
}

main() {
    log_info "Starting Kubernetes cluster health check..."
    ensure_kubeconfig || true
    require_kubectl
    kubectl config current-context >/dev/null 2>&1 && \
        log_info "kubectl context: $(kubectl config current-context)" || true

    kubectl cluster-info || {
        log_error "kubectl cluster-info failed"
        exit 1
    }

    check_apiserver || true
    show_nodes || true
    show_component_status || true
    show_service_status || true
    show_gpu_status || true

    log_info "Cluster health check complete."
}

main "$@"
