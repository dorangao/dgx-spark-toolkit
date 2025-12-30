#!/usr/bin/env bash
set -euo pipefail

# Deploy NVIDIA Nemotron-3 Nano 30B in distributed mode using KubeRay
# Uses Ray cluster with pipeline parallelism across 2 DGX Spark nodes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Deploy NVIDIA Nemotron-3 Nano 30B with distributed inference using KubeRay.
Uses Pipeline Parallelism to split model layers across spark-2959 and spark-ba63.

Options:
    --hf-token TOKEN    HuggingFace token for model download
    --dry-run           Show what would be applied without making changes
    --delete            Delete the distributed deployment
    --single            Switch back to single-node deployment
    --status            Show status of Ray cluster and vLLM
    -h, --help          Show this help message

Architecture:
    - spark-2959 (10.10.10.1): Ray Head + vLLM API Server (layers 0-N/2)
    - spark-ba63 (10.10.10.2): Ray Worker (layers N/2-N)
    - Communication: 200GbE fabric network via KubeRay

Requirements:
    - KubeRay operator installed (helm install kuberay-operator kuberay/kuberay-operator)
    - Both nodes must be Ready in the cluster
    - HuggingFace token with model access

Environment Variables:
    HF_TOKEN            HuggingFace token (alternative to --hf-token)

Examples:
    # Deploy distributed (requires both nodes)
    export HF_TOKEN=hf_xxxxxxxxxxxxx
    ./deploy-distributed.sh

    # Check status
    ./deploy-distributed.sh --status

    # Remove distributed deployment
    ./deploy-distributed.sh --delete

    # Switch back to single-node
    ./deploy-distributed.sh --single
EOF
}

# Parse arguments
DRY_RUN=""
DELETE_MODE=false
SINGLE_MODE=false
STATUS_MODE=false
HF_TOKEN="${HF_TOKEN:-}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --hf-token)
            HF_TOKEN="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN="--dry-run=client"
            shift
            ;;
        --delete)
            DELETE_MODE=true
            shift
            ;;
        --single)
            SINGLE_MODE=true
            shift
            ;;
        --status)
            STATUS_MODE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Check kubectl
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found. Please install kubectl first."
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    log_error "Cannot connect to Kubernetes cluster."
    exit 1
fi

# Status mode
if $STATUS_MODE; then
    echo -e "${BLUE}=== KubeRay Operator ===${NC}"
    kubectl get pods -n ray-system 2>/dev/null || echo "KubeRay not installed"
    echo ""
    
    echo -e "${BLUE}=== Ray Cluster ===${NC}"
    kubectl get raycluster -n llm-inference 2>/dev/null || echo "No RayCluster found"
    echo ""
    
    echo -e "${BLUE}=== Ray Pods ===${NC}"
    kubectl get pods -n llm-inference -l ray-cluster=vllm-cluster -o wide 2>/dev/null || echo "No Ray pods"
    echo ""
    
    echo -e "${BLUE}=== Ray Jobs ===${NC}"
    kubectl get rayjob -n llm-inference 2>/dev/null || echo "No RayJobs"
    echo ""
    
    echo -e "${BLUE}=== Services ===${NC}"
    kubectl get svc -n llm-inference 2>/dev/null || echo "No services"
    echo ""
    
    # Check if vLLM is responding
    LB_IP=$(kubectl get svc vllm-distributed-service -n llm-inference -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [[ -n "$LB_IP" ]]; then
        echo -e "${BLUE}=== vLLM Health ===${NC}"
        curl -s --connect-timeout 5 "http://${LB_IP}:8000/health" 2>/dev/null && echo "" || echo "vLLM not responding"
    fi
    exit 0
fi

# Delete mode
if $DELETE_MODE; then
    log_step "Deleting distributed Nemotron deployment..."
    
    kubectl delete rayjob vllm-serve -n llm-inference --ignore-not-found $DRY_RUN || true
    kubectl delete raycluster vllm-cluster -n llm-inference --ignore-not-found $DRY_RUN || true
    kubectl delete svc vllm-distributed-service -n llm-inference --ignore-not-found $DRY_RUN || true
    
    # Also delete old manual deployment if exists
    kubectl delete -f "$SCRIPT_DIR/deployment-multi-node.yaml" --ignore-not-found $DRY_RUN 2>/dev/null || true
    
    log_info "Distributed deployment deleted."
    log_info "Note: Single-node deployment and shared resources (namespace, PVC, secret) retained."
    log_info "To remove KubeRay operator: helm uninstall kuberay-operator -n ray-system"
    exit 0
fi

# Single mode - switch back to single node
if $SINGLE_MODE; then
    log_step "Switching to single-node deployment..."
    
    # Delete distributed deployment
    kubectl delete rayjob vllm-serve -n llm-inference --ignore-not-found $DRY_RUN || true
    kubectl delete raycluster vllm-cluster -n llm-inference --ignore-not-found $DRY_RUN || true
    kubectl delete svc vllm-distributed-service -n llm-inference --ignore-not-found $DRY_RUN || true
    
    # Apply single-node deployment
    kubectl apply -f "$SCRIPT_DIR/deployment-single-node.yaml" $DRY_RUN
    kubectl apply -f "$SCRIPT_DIR/service.yaml" $DRY_RUN
    
    log_info "Switched to single-node deployment on spark-2959."
    exit 0
fi

# Validate HuggingFace token
if [[ -z "$HF_TOKEN" ]]; then
    log_error "HuggingFace token is required!"
    log_info "Set HF_TOKEN environment variable or use --hf-token flag."
    exit 1
fi

# Check KubeRay operator is installed
log_step "Checking KubeRay operator..."
if ! kubectl get deployment kuberay-operator -n ray-system &>/dev/null; then
    log_error "KubeRay operator not found!"
    log_info "Install with: helm install kuberay-operator kuberay/kuberay-operator -n ray-system --create-namespace"
    exit 1
fi
log_info "KubeRay operator is running."

# Check both nodes are Ready
log_step "Checking cluster nodes..."
NODE_COUNT=$(kubectl get nodes --no-headers | grep -c "Ready" || echo "0")
if [[ "$NODE_COUNT" -lt 2 ]]; then
    log_error "Distributed deployment requires 2 Ready nodes. Found: $NODE_COUNT"
    log_info "Check node status with: kubectl get nodes"
    exit 1
fi

if ! kubectl get node spark-ba63 | grep -q "Ready"; then
    log_error "spark-ba63 is not Ready. Cannot deploy distributed mode."
    exit 1
fi
log_info "Both nodes are Ready."
echo ""

log_info "Deploying NVIDIA Nemotron-3 Nano 30B in DISTRIBUTED mode (KubeRay)"
log_info "Pipeline Parallelism: 2 nodes"
echo ""

# Step 1: Ensure namespace exists
log_step "1/6 Ensuring namespace exists..."
kubectl apply -f "$SCRIPT_DIR/namespace.yaml" $DRY_RUN

# Step 2: Ensure PVC exists
log_step "2/6 Ensuring PVC exists..."
kubectl apply -f "$SCRIPT_DIR/pvc.yaml" $DRY_RUN

# Step 3: Ensure secret exists
log_step "3/6 Ensuring HuggingFace token secret..."
if [[ -z "$DRY_RUN" ]]; then
    kubectl create secret generic hf-token-secret \
        --namespace=llm-inference \
        --from-literal=HF_TOKEN="$HF_TOKEN" \
        --dry-run=client -o yaml | kubectl apply -f -
fi

# Step 4: Delete single-node deployment if exists
log_step "4/6 Removing single-node deployment (if any)..."
kubectl delete deployment nemotron-vllm -n llm-inference --ignore-not-found $DRY_RUN || true

# Step 5: Deploy RayCluster
log_step "5/6 Deploying RayCluster..."
kubectl apply -f "$SCRIPT_DIR/raycluster-vllm.yaml" $DRY_RUN

# Step 6: Wait for cluster and start vLLM
if [[ -z "$DRY_RUN" ]]; then
    log_step "6/6 Waiting for Ray cluster to be ready..."
    
    # Wait for head pod to be ready
    echo "Waiting for Ray head pod..."
    for i in $(seq 1 60); do
        HEAD_READY=$(kubectl get pods -n llm-inference -l ray-node-type=head -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
        if [[ "$HEAD_READY" == "true" ]]; then
            echo "Head pod is ready."
            break
        fi
        echo "Waiting for head pod... ($i/60)"
        sleep 5
    done
    
    # Wait for worker pod to be ready
    echo "Waiting for Ray worker pod..."
    for i in $(seq 1 60); do
        WORKER_READY=$(kubectl get pods -n llm-inference -l ray-node-type=worker -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
        if [[ "$WORKER_READY" == "true" ]]; then
            echo "Worker pod is ready."
            break
        fi
        echo "Waiting for worker pod... ($i/60)"
        sleep 5
    done
    
    # Submit vLLM job
    log_info "Submitting vLLM serve job..."
    kubectl apply -f "$SCRIPT_DIR/vllm-serve-job.yaml"
fi

echo ""
log_info "Distributed deployment initiated!"
echo ""

if [[ -z "$DRY_RUN" ]]; then
    sleep 5
    
    echo -e "${BLUE}Ray Cluster Status:${NC}"
    kubectl get raycluster -n llm-inference
    echo ""
    
    echo -e "${BLUE}Ray Pods:${NC}"
    kubectl get pods -n llm-inference -l ray-cluster=vllm-cluster -o wide
    echo ""
    
    echo -e "${GREEN}Next Steps:${NC}"
    echo ""
    echo -e "1. Monitor Ray cluster:"
    echo -e "   ${YELLOW}./deploy-distributed.sh --status${NC}"
    echo ""
    echo -e "2. Monitor vLLM startup:"
    echo -e "   ${YELLOW}kubectl logs -f -n llm-inference -l ray-node-type=head${NC}"
    echo ""
    echo -e "3. Check RayJob status:"
    echo -e "   ${YELLOW}kubectl get rayjob -n llm-inference${NC}"
    echo ""
    echo -e "4. Once ready, test the API (may take 10-15 minutes for first download):"
    echo -e "   ${YELLOW}curl http://10.10.10.1:8000/v1/models${NC}"
    echo ""
    echo -e "   Or via LoadBalancer (when assigned):"
    echo -e "   ${YELLOW}LB_IP=\$(kubectl get svc vllm-distributed-service -n llm-inference -o jsonpath='{.status.loadBalancer.ingress[0].ip}')${NC}"
    echo -e "   ${YELLOW}curl http://\$LB_IP:8000/v1/models${NC}"
    echo ""
    echo -e "5. Ray Dashboard (for monitoring):"
    echo -e "   ${YELLOW}http://10.10.10.1:8265${NC}"
fi
