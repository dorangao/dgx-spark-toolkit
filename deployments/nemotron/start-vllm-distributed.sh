#!/usr/bin/env bash
set -euo pipefail

# Start vLLM on an existing Ray cluster with pipeline parallelism
# This script waits for the Ray cluster to be ready, then starts vLLM

NAMESPACE="${NAMESPACE:-llm-inference}"
CLUSTER_NAME="${CLUSTER_NAME:-vllm-cluster}"
VLLM_PORT="${VLLM_PORT:-8080}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

# Get head pod name
get_head_pod() {
    kubectl get pods -n "$NAMESPACE" -l ray-node-type=head,ray-cluster="$CLUSTER_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Wait for Ray cluster to be ready with 2 GPUs
wait_for_cluster() {
    log_step "Waiting for Ray cluster to be ready..."
    
    for i in $(seq 1 60); do
        HEAD_POD=$(get_head_pod)
        if [[ -z "$HEAD_POD" ]]; then
            echo "Waiting for head pod... ($i/60)"
            sleep 5
            continue
        fi
        
        # Check if cluster has 2 GPUs
        GPUS=$(kubectl exec -n "$NAMESPACE" "$HEAD_POD" -- ray status 2>/dev/null | grep -E "^.*/2\.0 GPU" | head -1 || echo "")
        if [[ -n "$GPUS" ]]; then
            log_info "Ray cluster ready with 2 GPUs"
            return 0
        fi
        
        echo "Waiting for 2 GPUs in cluster... ($i/60)"
        sleep 5
    done
    
    log_warn "Timeout waiting for cluster. Proceeding anyway..."
    return 0
}

# Start vLLM server
start_vllm() {
    HEAD_POD=$(get_head_pod)
    if [[ -z "$HEAD_POD" ]]; then
        echo "Error: Head pod not found"
        exit 1
    fi
    
    log_step "Starting vLLM on $HEAD_POD (port $VLLM_PORT)..."
    
    kubectl exec -n "$NAMESPACE" "$HEAD_POD" -- bash -c "
        # Kill any existing vLLM process
        pkill -f 'vllm serve' 2>/dev/null || true
        sleep 2
        
        # Start vLLM
        echo 'Starting vLLM with distributed inference...'
        nohup vllm serve nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16 \\
            --host 0.0.0.0 \\
            --port $VLLM_PORT \\
            --trust-remote-code \\
            --dtype bfloat16 \\
            --distributed-executor-backend ray \\
            --tensor-parallel-size 1 \\
            --pipeline-parallel-size 2 \\
            --max-model-len 4096 \\
            --gpu-memory-utilization 0.85 \\
            --download-dir /models \\
            --enforce-eager > /tmp/vllm.log 2>&1 &
        
        echo 'vLLM started in background'
        echo 'Logs: kubectl exec -n $NAMESPACE $HEAD_POD -- tail -f /tmp/vllm.log'
    "
    
    log_info "vLLM starting on 10.10.10.1:$VLLM_PORT"
    echo ""
    echo -e "${GREEN}Monitor vLLM startup:${NC}"
    echo -e "  ${YELLOW}kubectl exec -n $NAMESPACE $HEAD_POD -- tail -f /tmp/vllm.log${NC}"
    echo ""
    echo -e "${GREEN}Test API (once ready):${NC}"
    echo -e "  ${YELLOW}curl http://10.10.10.1:$VLLM_PORT/v1/models${NC}"
}

# Check status
check_status() {
    HEAD_POD=$(get_head_pod)
    if [[ -z "$HEAD_POD" ]]; then
        echo "Head pod not found"
        return 1
    fi
    
    echo "=== Ray Cluster ==="
    kubectl exec -n "$NAMESPACE" "$HEAD_POD" -- ray status 2>/dev/null || echo "Ray not responding"
    echo ""
    
    echo "=== vLLM Process ==="
    kubectl exec -n "$NAMESPACE" "$HEAD_POD" -- bash -c "ps aux | grep 'vllm serve' | grep -v grep || echo 'vLLM not running'"
    echo ""
    
    echo "=== vLLM Health ==="
    kubectl exec -n "$NAMESPACE" "$HEAD_POD" -- curl -s --connect-timeout 5 "http://localhost:$VLLM_PORT/health" 2>/dev/null || echo "vLLM not responding"
    echo ""
}

# Main
case "${1:-start}" in
    start)
        wait_for_cluster
        start_vllm
        ;;
    status)
        check_status
        ;;
    logs)
        HEAD_POD=$(get_head_pod)
        kubectl exec -n "$NAMESPACE" "$HEAD_POD" -- tail -f /tmp/vllm.log
        ;;
    *)
        echo "Usage: $0 [start|status|logs]"
        exit 1
        ;;
esac

