#!/usr/bin/env bash
set -euo pipefail

# Deploy NVIDIA Nemotron-3 Nano 30B on DGX Spark with vLLM
# Single-node deployment

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

Deploy NVIDIA Nemotron-3 Nano 30B with vLLM on Kubernetes.

Options:
    --hf-token TOKEN    HuggingFace token for model download
    --dry-run           Show what would be applied without making changes
    --delete            Delete the deployment instead of creating it
    -h, --help          Show this help message

Environment Variables:
    HF_TOKEN            HuggingFace token (alternative to --hf-token)

Examples:
    # Deploy with token from environment
    export HF_TOKEN=hf_xxxxxxxxxxxxx
    ./deploy.sh

    # Deploy with token as argument
    ./deploy.sh --hf-token hf_xxxxxxxxxxxxx

    # Preview deployment
    ./deploy.sh --dry-run

    # Remove deployment
    ./deploy.sh --delete
EOF
}

# Parse arguments
DRY_RUN=""
DELETE_MODE=false
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

# Check kubectl is available
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found. Please install kubectl first."
    exit 1
fi

# Check cluster connectivity
if ! kubectl cluster-info &> /dev/null; then
    log_error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
    exit 1
fi

if $DELETE_MODE; then
    log_step "Deleting Nemotron deployment..."
    
    kubectl delete -f "$SCRIPT_DIR/service.yaml" --ignore-not-found $DRY_RUN || true
    kubectl delete -f "$SCRIPT_DIR/deployment-single-node.yaml" --ignore-not-found $DRY_RUN || true
    kubectl delete secret hf-token-secret -n llm-inference --ignore-not-found $DRY_RUN || true
    kubectl delete -f "$SCRIPT_DIR/pvc.yaml" --ignore-not-found $DRY_RUN || true
    kubectl delete -f "$SCRIPT_DIR/namespace.yaml" --ignore-not-found $DRY_RUN || true
    
    log_info "Nemotron deployment deleted."
    exit 0
fi

# Validate HuggingFace token
if [[ -z "$HF_TOKEN" ]]; then
    log_error "HuggingFace token is required!"
    log_info "Set HF_TOKEN environment variable or use --hf-token flag."
    log_info "Get your token at: https://huggingface.co/settings/tokens"
    exit 1
fi

if [[ ! "$HF_TOKEN" =~ ^hf_ ]]; then
    log_warn "Token doesn't start with 'hf_' - make sure this is a valid HuggingFace token."
fi

log_info "Deploying NVIDIA Nemotron-3 Nano 30B with vLLM"
echo ""

# Step 1: Create namespace
log_step "1/5 Creating namespace..."
kubectl apply -f "$SCRIPT_DIR/namespace.yaml" $DRY_RUN

# Step 2: Create PVC
log_step "2/5 Creating persistent volume claim..."
kubectl apply -f "$SCRIPT_DIR/pvc.yaml" $DRY_RUN

# Step 3: Create secret
log_step "3/5 Creating HuggingFace token secret..."
if [[ -z "$DRY_RUN" ]]; then
    kubectl create secret generic hf-token-secret \
        --namespace=llm-inference \
        --from-literal=HF_TOKEN="$HF_TOKEN" \
        --dry-run=client -o yaml | kubectl apply -f -
else
    log_info "(dry-run) Would create secret hf-token-secret in llm-inference namespace"
fi

# Step 4: Create deployment
log_step "4/5 Creating vLLM deployment..."
kubectl apply -f "$SCRIPT_DIR/deployment-single-node.yaml" $DRY_RUN

# Step 5: Create service
log_step "5/5 Creating services..."
kubectl apply -f "$SCRIPT_DIR/service.yaml" $DRY_RUN

echo ""
log_info "Deployment initiated successfully!"
echo ""

if [[ -z "$DRY_RUN" ]]; then
    log_info "Checking deployment status..."
    echo ""
    
    # Wait a moment for resources to be created
    sleep 2
    
    # Show pod status
    echo -e "${BLUE}Pod Status:${NC}"
    kubectl get pods -n llm-inference -l app=nemotron-vllm
    echo ""
    
    # Show service status
    echo -e "${BLUE}Service Status:${NC}"
    kubectl get svc -n llm-inference
    echo ""
    
    # Get LoadBalancer IP
    LB_IP=$(kubectl get svc nemotron-service -n llm-inference -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    echo -e "${GREEN}Next Steps:${NC}"
    echo ""
    echo -e "1. Monitor pod startup (model download may take several minutes):"
    echo -e "   ${YELLOW}kubectl logs -f -n llm-inference deployment/nemotron-vllm${NC}"
    echo ""
    echo -e "2. Check when pod is ready:"
    echo -e "   ${YELLOW}kubectl get pods -n llm-inference -w${NC}"
    echo ""
    echo -e "3. Once ready, test the API:"

    if [[ -n "$LB_IP" ]]; then
        echo -e "   ${YELLOW}curl http://${LB_IP}:8000/v1/models${NC}"
        echo ""
        echo -e "   ${YELLOW}curl http://${LB_IP}:8000/v1/chat/completions \\"
        echo -e "     -H \"Content-Type: application/json\" \\"
        echo -e "     -d '{"
        echo -e "       \"model\": \"nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8\","
        echo -e "       \"messages\": [{\"role\": \"user\", \"content\": \"Hello, what is Nemotron?\"}],"
        echo -e "       \"max_tokens\": 100"
        echo -e "     }'${NC}"
    else
        echo -e "   (LoadBalancer IP pending - run: ${YELLOW}kubectl get svc -n llm-inference${NC})"
        echo -e "   ${YELLOW}curl http://<LOAD_BALANCER_IP>:8000/v1/models${NC}"
    fi
fi

