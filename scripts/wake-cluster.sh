#!/usr/bin/env bash
set -euo pipefail

# Power Management Script - Wake Cluster
# Wakes up suspended DGX Spark machines using Wake-on-LAN
# Run this from a machine on the same network (e.g., your laptop)

# Configuration - MAC addresses for Wake-on-LAN
CONTROL_PLANE_NAME="spark-2959"
CONTROL_PLANE_MAC="${CONTROL_PLANE_MAC:-4c:bb:47:2e:29:59}"
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-192.168.86.38}"

WORKER_NAME="spark-ba63"
WORKER_MAC="${WORKER_MAC:-4c:bb:47:2c:ba:63}"
WORKER_IP="${WORKER_IP:-192.168.86.39}"

# Broadcast address for Wake-on-LAN
BROADCAST="${BROADCAST:-192.168.86.255}"

# Timing
CONTROL_PLANE_BOOT_WAIT="${CONTROL_PLANE_BOOT_WAIT:-90}"
WORKER_BOOT_WAIT="${WORKER_BOOT_WAIT:-60}"
K8S_READY_TIMEOUT="${K8S_READY_TIMEOUT:-300}"

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

# Find a working WoL tool
find_wol_tool() {
    if command -v wakeonlan &>/dev/null; then
        echo "wakeonlan"
    elif command -v wol &>/dev/null; then
        echo "wol"
    elif command -v etherwake &>/dev/null; then
        echo "etherwake"
    else
        echo ""
    fi
}

send_wol() {
    local mac="$1"
    local name="$2"
    local tool
    tool=$(find_wol_tool)
    
    if [[ -z "$tool" ]]; then
        log_error "No Wake-on-LAN tool found. Install one of: wakeonlan, wol, etherwake"
        log_info "  Ubuntu/Debian: sudo apt install wakeonlan"
        log_info "  macOS: brew install wakeonlan"
        return 1
    fi
    
    log_info "Sending Wake-on-LAN magic packet to $name ($mac) using $tool..."
    
    case "$tool" in
        wakeonlan)
            wakeonlan -i "$BROADCAST" "$mac"
            ;;
        wol)
            wol "$mac"
            ;;
        etherwake)
            sudo etherwake "$mac"
            ;;
    esac
}

# Send WoL using raw netcat (fallback if no WoL tool)
send_wol_netcat() {
    local mac="$1"
    local name="$2"
    
    log_info "Sending Wake-on-LAN via netcat to $name ($mac)..."
    
    # Build magic packet: 6 bytes of 0xFF followed by MAC address repeated 16 times
    local mac_bytes
    mac_bytes=$(echo "$mac" | tr -d ':' | sed 's/../\\x&/g')
    
    # Create magic packet
    local magic_packet
    magic_packet=$(printf '\xff\xff\xff\xff\xff\xff')
    for _ in {1..16}; do
        magic_packet+=$(printf "$mac_bytes")
    done
    
    # Send via UDP broadcast
    echo -ne "$magic_packet" | nc -w1 -u -b "$BROADCAST" 9 2>/dev/null || \
    echo -ne "$magic_packet" | nc -w1 -u "$BROADCAST" 9 2>/dev/null || \
        log_warn "netcat WoL may have failed"
}

wait_for_host() {
    local ip="$1"
    local name="$2"
    local timeout="$3"
    local elapsed=0
    local interval=5
    
    log_info "Waiting for $name ($ip) to come online (timeout: ${timeout}s)..."
    
    while [[ $elapsed -lt $timeout ]]; do
        if ping -c 1 -W 2 "$ip" &>/dev/null; then
            log_info "✓ $name is responding to ping"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        echo -n "."
    done
    echo ""
    
    log_warn "$name did not respond within ${timeout}s"
    return 1
}

wait_for_ssh() {
    local ip="$1"
    local name="$2"
    local timeout=60
    local elapsed=0
    
    log_info "Waiting for SSH on $name..."
    
    while [[ $elapsed -lt $timeout ]]; do
        if nc -z -w 2 "$ip" 22 &>/dev/null; then
            log_info "✓ SSH is available on $name"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    log_warn "SSH not available on $name after ${timeout}s"
    return 1
}

wait_for_k8s() {
    local timeout="$K8S_READY_TIMEOUT"
    local elapsed=0
    
    log_info "Waiting for Kubernetes API to be ready (timeout: ${timeout}s)..."
    
    while [[ $elapsed -lt $timeout ]]; do
        if ssh -o BatchMode=yes -o ConnectTimeout=5 "doran@$CONTROL_PLANE_IP" \
            "kubectl cluster-info &>/dev/null" 2>/dev/null; then
            log_info "✓ Kubernetes API is responding"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        echo -n "."
    done
    echo ""
    
    log_warn "Kubernetes API not ready after ${timeout}s"
    return 1
}

uncordon_nodes() {
    log_info "Uncordoning cluster nodes..."
    
    ssh -o BatchMode=yes -o ConnectTimeout=10 "doran@$CONTROL_PLANE_IP" bash <<'EOF'
kubectl uncordon spark-2959 2>/dev/null || true
kubectl uncordon spark-ba63 2>/dev/null || true
echo "Nodes uncordoned"
kubectl get nodes
EOF
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Wake up the suspended Kubernetes cluster using Wake-on-LAN.

This script should be run from a machine on the same network as the cluster
(e.g., your laptop or another server that stayed awake).

OPTIONS:
    -h, --help              Show this help message
    -c, --control-only      Only wake the control plane
    -w, --worker-only       Only wake the worker node
    -n, --no-wait           Don't wait for machines to come online
    -s, --start-k8s         Run start-k8s-cluster.sh after wake
    --skip-uncordon         Don't uncordon nodes after wake

ENVIRONMENT VARIABLES:
    CONTROL_PLANE_MAC       MAC address of control plane (default: 4c:bb:47:2e:29:59)
    CONTROL_PLANE_IP        IP address of control plane (default: 192.168.86.38)
    WORKER_MAC              MAC address of worker (default: 4c:bb:47:2c:ba:63)
    WORKER_IP               IP address of worker (default: 192.168.86.39)
    BROADCAST               Broadcast address (default: 192.168.86.255)

REQUIREMENTS:
    One of: wakeonlan, wol, etherwake (or netcat as fallback)
    
    Install on Ubuntu/Debian: sudo apt install wakeonlan
    Install on macOS: brew install wakeonlan

EXAMPLES:
    ./wake-cluster.sh                  # Wake entire cluster
    ./wake-cluster.sh -c               # Wake control plane only
    ./wake-cluster.sh -s               # Wake and run startup script

EOF
    exit 0
}

main() {
    local control_only=false
    local worker_only=false
    local no_wait=false
    local start_k8s=false
    local skip_uncordon=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage ;;
            -c|--control-only) control_only=true; shift ;;
            -w|--worker-only) worker_only=true; shift ;;
            -n|--no-wait) no_wait=true; shift ;;
            -s|--start-k8s) start_k8s=true; shift ;;
            --skip-uncordon) skip_uncordon=true; shift ;;
            *) log_error "Unknown option: $1"; usage ;;
        esac
    done
    
    echo ""
    log_info "=============================================="
    log_info "CLUSTER WAKE SCRIPT"
    log_info "=============================================="
    echo ""
    log_info "Control plane: $CONTROL_PLANE_NAME ($CONTROL_PLANE_MAC)"
    log_info "Worker: $WORKER_NAME ($WORKER_MAC)"
    log_info "Broadcast: $BROADCAST"
    echo ""
    
    local wol_tool
    wol_tool=$(find_wol_tool)
    if [[ -z "$wol_tool" ]]; then
        log_warn "No WoL tool found, will try netcat fallback"
    else
        log_info "Using WoL tool: $wol_tool"
    fi
    echo ""
    
    # Wake control plane first (required for K8s)
    if ! $worker_only; then
        log_step "Waking control plane ($CONTROL_PLANE_NAME)..."
        
        if [[ -n "$wol_tool" ]]; then
            send_wol "$CONTROL_PLANE_MAC" "$CONTROL_PLANE_NAME"
        else
            send_wol_netcat "$CONTROL_PLANE_MAC" "$CONTROL_PLANE_NAME"
        fi
        
        if ! $no_wait; then
            wait_for_host "$CONTROL_PLANE_IP" "$CONTROL_PLANE_NAME" "$CONTROL_PLANE_BOOT_WAIT" || true
            wait_for_ssh "$CONTROL_PLANE_IP" "$CONTROL_PLANE_NAME" || true
        fi
    fi
    
    # Wake worker
    if ! $control_only; then
        log_step "Waking worker ($WORKER_NAME)..."
        
        if [[ -n "$wol_tool" ]]; then
            send_wol "$WORKER_MAC" "$WORKER_NAME"
        else
            send_wol_netcat "$WORKER_MAC" "$WORKER_NAME"
        fi
        
        if ! $no_wait; then
            wait_for_host "$WORKER_IP" "$WORKER_NAME" "$WORKER_BOOT_WAIT" || true
            wait_for_ssh "$WORKER_IP" "$WORKER_NAME" || true
        fi
    fi
    
    if ! $no_wait && ! $worker_only; then
        echo ""
        log_step "Waiting for Kubernetes to initialize..."
        
        if wait_for_k8s; then
            if ! $skip_uncordon; then
                uncordon_nodes || true
            fi
            
            if $start_k8s; then
                log_step "Running start-k8s-cluster.sh..."
                ssh -o BatchMode=yes "doran@$CONTROL_PLANE_IP" \
                    "cd ~/dgx-spark-toolkit/scripts && sudo ./start-k8s-cluster.sh" || true
            fi
        fi
    fi
    
    echo ""
    log_info "=============================================="
    log_info "WAKE SEQUENCE COMPLETE"
    log_info "=============================================="
    echo ""
    
    if ! $no_wait; then
        log_info "You can now SSH to the cluster:"
        echo "  ssh doran@$CONTROL_PLANE_IP  # Control plane"
        echo "  ssh doran@$WORKER_IP         # Worker"
        echo ""
        log_info "Or access services:"
        echo "  http://192.168.86.200        # OpenWebUI"
        echo "  http://192.168.86.201:11434  # Ollama"
    fi
}

main "$@"

