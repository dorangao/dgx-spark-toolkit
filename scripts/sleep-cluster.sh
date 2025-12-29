#!/usr/bin/env bash
set -euo pipefail

# Power Management Script - Sleep Cluster
# Gracefully suspends both DGX Spark machines to save energy
# Use wake-cluster.sh to wake them up via Wake-on-LAN

# Configuration
CONTROL_PLANE_NAME="spark-2959"
WORKER_NAME="spark-ba63"
WORKER_SSH_TARGET="${WORKER_SSH_TARGET:-192.168.86.39}"
WORKER_SSH_USER="${WORKER_SSH_USER:-${SUDO_USER:-$USER}}"
WORKER_SSH_PORT="${WORKER_SSH_PORT:-22}"

# Network interfaces for Wake-on-LAN
CONTROL_PLANE_WOL_IF="${CONTROL_PLANE_WOL_IF:-enP7s7}"
WORKER_WOL_IF="${WORKER_WOL_IF:-enP7s7}"

# Sleep mode: "mem" (suspend-to-RAM) or "freeze" (suspend-to-idle)
SLEEP_MODE="${SLEEP_MODE:-mem}"

# Drain timeout in seconds
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-120}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

worker_ssh() {
    ssh "${SSH_OPTS[@]}" -p "$WORKER_SSH_PORT" "${WORKER_SSH_USER}@${WORKER_SSH_TARGET}" "$@"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

ensure_wol_enabled() {
    local interface="$1"
    local node="$2"
    
    log_info "Ensuring Wake-on-LAN is enabled on $node ($interface)..."
    
    if [[ "$node" == "$CONTROL_PLANE_NAME" ]]; then
        # Local machine
        if command -v ethtool &>/dev/null; then
            ethtool -s "$interface" wol g 2>/dev/null || log_warn "Could not enable WoL on $interface"
        fi
    else
        # Remote worker
        worker_ssh "sudo ethtool -s $interface wol g 2>/dev/null || true"
    fi
}

drain_node() {
    local node="$1"
    
    if ! kubectl get node "$node" &>/dev/null; then
        log_warn "Node $node not found in cluster, skipping drain"
        return 0
    fi
    
    local ready
    ready=$(kubectl get node "$node" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || echo "Unknown")
    
    if [[ "$ready" != "True" ]]; then
        log_warn "Node $node is not Ready (status: $ready), skipping drain"
        return 0
    fi
    
    log_info "Draining node $node..."
    if ! kubectl drain "$node" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --timeout="${DRAIN_TIMEOUT}s" \
        2>/dev/null; then
        log_warn "Drain had issues but continuing..."
    fi
    
    log_info "Cordoning node $node..."
    kubectl cordon "$node" 2>/dev/null || true
}

suspend_worker() {
    log_step "Suspending worker node ($WORKER_NAME)..."
    
    # Enable WoL before suspending
    ensure_wol_enabled "$WORKER_WOL_IF" "$WORKER_NAME"
    
    # Drain the worker node
    drain_node "$WORKER_NAME"
    
    # Stop kubelet gracefully
    log_info "Stopping kubelet on $WORKER_NAME..."
    worker_ssh "sudo systemctl stop kubelet" 2>/dev/null || true
    
    # Give services time to stop
    sleep 3
    
    # Suspend the worker
    log_info "Sending $WORKER_NAME to sleep (mode: $SLEEP_MODE)..."
    
    # Use nohup and background to avoid SSH hanging
    worker_ssh "nohup sudo bash -c 'sleep 2; echo $SLEEP_MODE > /sys/power/state' &>/dev/null &" || true
    
    log_info "Worker $WORKER_NAME is going to sleep..."
    sleep 5
}

suspend_control_plane() {
    log_step "Suspending control plane ($CONTROL_PLANE_NAME)..."
    
    # Enable WoL before suspending
    ensure_wol_enabled "$CONTROL_PLANE_WOL_IF" "$CONTROL_PLANE_NAME"
    
    # Drain the control plane (move workloads if any)
    drain_node "$CONTROL_PLANE_NAME"
    
    log_info "Sending $CONTROL_PLANE_NAME to sleep (mode: $SLEEP_MODE)..."
    log_warn "System will suspend in 5 seconds..."
    
    # Schedule the suspend
    nohup bash -c "sleep 5; echo $SLEEP_MODE > /sys/power/state" &>/dev/null &
    
    log_info "Control plane going to sleep. Use wake-cluster.sh to wake up."
}

show_wake_info() {
    local cp_mac worker_mac
    cp_mac=$(cat "/sys/class/net/$CONTROL_PLANE_WOL_IF/address" 2>/dev/null || echo "unknown")
    worker_mac=$(worker_ssh "cat /sys/class/net/$WORKER_WOL_IF/address" 2>/dev/null || echo "unknown")
    
    echo ""
    log_info "=============================================="
    log_info "WAKE-ON-LAN INFORMATION"
    log_info "=============================================="
    echo ""
    echo "  Control Plane ($CONTROL_PLANE_NAME):"
    echo "    MAC: $cp_mac"
    echo "    Interface: $CONTROL_PLANE_WOL_IF"
    echo ""
    echo "  Worker ($WORKER_NAME):"
    echo "    MAC: $worker_mac"
    echo "    Interface: $WORKER_WOL_IF"
    echo ""
    echo "  To wake the cluster, run from another machine:"
    echo "    ./wake-cluster.sh"
    echo ""
    echo "  Or manually:"
    echo "    wakeonlan $cp_mac    # Wake control plane first"
    echo "    sleep 60"
    echo "    wakeonlan $worker_mac  # Then wake worker"
    echo ""
    log_info "=============================================="
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Gracefully suspend the Kubernetes cluster to save energy.

OPTIONS:
    -h, --help          Show this help message
    -w, --worker-only   Only suspend the worker node
    -c, --control-only  Only suspend the control plane
    -f, --force         Skip draining nodes
    -m, --mode MODE     Sleep mode: mem (default) or freeze
    --dry-run           Show what would be done without actually sleeping

ENVIRONMENT VARIABLES:
    SLEEP_MODE          Sleep mode (mem or freeze)
    DRAIN_TIMEOUT       Timeout for draining nodes (default: 120s)
    WORKER_SSH_TARGET   Worker SSH address (default: 192.168.86.39)

EXAMPLES:
    sudo ./sleep-cluster.sh              # Sleep entire cluster
    sudo ./sleep-cluster.sh -w           # Sleep worker only
    sudo ./sleep-cluster.sh --dry-run    # Show what would happen

EOF
    exit 0
}

main() {
    local worker_only=false
    local control_only=false
    local force=false
    local dry_run=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage ;;
            -w|--worker-only) worker_only=true; shift ;;
            -c|--control-only) control_only=true; shift ;;
            -f|--force) force=true; shift ;;
            -m|--mode) SLEEP_MODE="$2"; shift 2 ;;
            --dry-run) dry_run=true; shift ;;
            *) log_error "Unknown option: $1"; usage ;;
        esac
    done
    
    check_root
    
    echo ""
    log_info "=============================================="
    log_info "CLUSTER SLEEP SCRIPT"
    log_info "=============================================="
    echo ""
    log_info "Sleep mode: $SLEEP_MODE"
    log_info "Control plane: $CONTROL_PLANE_NAME"
    log_info "Worker: $WORKER_NAME ($WORKER_SSH_TARGET)"
    echo ""
    
    if $dry_run; then
        log_warn "DRY RUN - No actual changes will be made"
        show_wake_info
        exit 0
    fi
    
    # Show wake info before sleeping
    show_wake_info
    
    echo ""
    read -p "Proceed with cluster sleep? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Aborted."
        exit 0
    fi
    
    echo ""
    
    if ! $control_only; then
        # Check if worker is reachable
        if worker_ssh "true" &>/dev/null; then
            suspend_worker
        else
            log_warn "Cannot reach worker $WORKER_NAME, skipping"
        fi
    fi
    
    if ! $worker_only; then
        suspend_control_plane
    fi
    
    echo ""
    log_info "Sleep sequence initiated."
}

main "$@"

