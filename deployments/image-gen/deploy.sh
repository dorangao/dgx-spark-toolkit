#!/bin/bash
#
# Image Generation Model Deployment Script
# Deploys image generation models to Kubernetes with load balancing
#
# Usage:
#   ./deploy.sh                          # Deploy default model (qwen-image-2512)
#   ./deploy.sh --model stable-diffusion-xl
#   ./deploy.sh --list-models
#   ./deploy.sh --delete
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="image-gen"
MODEL_CONFIG_FILE="$SCRIPT_DIR/model-configs.yaml"

# Available models
declare -A MODELS
MODELS["qwen-image-2512"]="Qwen/Qwen-Image-2512"
MODELS["stable-diffusion-xl"]="stabilityai/stable-diffusion-xl-base-1.0"
MODELS["flux-schnell"]="black-forest-labs/FLUX.1-schnell"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_help() {
    cat << EOF
Image Generation Deployment Script

Usage: $0 [OPTIONS]

Options:
  --model NAME       Model to deploy (default: qwen-image-2512)
  --replicas N       Number of replicas (default: 2)
  --list-models      List available models
  --delete           Delete deployment
  --status           Show deployment status
  --logs             Show logs from pods
  --help             Show this help

Available Models:
EOF
    for model in "${!MODELS[@]}"; do
        echo "  $model -> ${MODELS[$model]}"
    done
}

list_models() {
    echo -e "\n${BLUE}Available Image Generation Models:${NC}\n"
    printf "%-25s %-50s\n" "NAME" "HUGGINGFACE ID"
    printf "%-25s %-50s\n" "----" "-------------"
    for model in "${!MODELS[@]}"; do
        printf "%-25s %-50s\n" "$model" "${MODELS[$model]}"
    done
    echo ""
}

create_namespace() {
    log_info "Creating namespace: $NAMESPACE"
    kubectl apply -f "$SCRIPT_DIR/namespace.yaml"
}

create_configmap() {
    local model="$1"
    
    log_info "Creating ConfigMap with server code..."
    
    # Create ConfigMap from server.py
    kubectl create configmap image-gen-server \
        --namespace="$NAMESPACE" \
        --from-file=server.py="$SCRIPT_DIR/server.py" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Update model config
    kubectl create configmap image-gen-config \
        --namespace="$NAMESPACE" \
        --from-literal=MODEL_NAME="$model" \
        --dry-run=client -o yaml | kubectl apply -f -
}

create_secret() {
    local hf_token="${HF_TOKEN:-}"
    
    if [[ -n "$hf_token" ]]; then
        log_info "Creating HuggingFace token secret..."
        kubectl create secret generic hf-token \
            --namespace="$NAMESPACE" \
            --from-literal=token="$hf_token" \
            --dry-run=client -o yaml | kubectl apply -f -
    else
        log_warn "HF_TOKEN not set - some models may require authentication"
    fi
}

update_deployment() {
    local model="$1"
    local replicas="$2"
    
    log_info "Updating deployment for model: $model with $replicas replicas"
    
    # Generate deployment with updated model name
    cat "$SCRIPT_DIR/deployment.yaml" | \
        sed "s/value: \"qwen-image-2512\"/value: \"$model\"/g" | \
        sed "s/replicas: 2/replicas: $replicas/g" | \
        kubectl apply -f -
}

deploy() {
    local model="${1:-qwen-image-2512}"
    local replicas="${2:-2}"
    
    if [[ -z "${MODELS[$model]}" ]]; then
        log_error "Unknown model: $model"
        list_models
        exit 1
    fi
    
    log_info "Deploying image generation service..."
    log_info "  Model: $model"
    log_info "  HuggingFace ID: ${MODELS[$model]}"
    log_info "  Replicas: $replicas"
    
    # Create resources
    create_namespace
    create_secret
    create_configmap "$model"
    update_deployment "$model" "$replicas"
    
    # Apply service
    kubectl apply -f "$SCRIPT_DIR/service.yaml"
    
    log_success "Deployment initiated!"
    echo ""
    show_status
    
    echo ""
    log_info "Waiting for pods to be ready (this may take 5-10 minutes for first deployment)..."
    echo "  Run: kubectl get pods -n $NAMESPACE -w"
}

delete_deployment() {
    log_info "Deleting image generation deployment..."
    
    kubectl delete -f "$SCRIPT_DIR/service.yaml" --ignore-not-found
    kubectl delete -f "$SCRIPT_DIR/deployment.yaml" --ignore-not-found
    kubectl delete configmap image-gen-server -n "$NAMESPACE" --ignore-not-found
    kubectl delete configmap image-gen-config -n "$NAMESPACE" --ignore-not-found
    kubectl delete secret hf-token -n "$NAMESPACE" --ignore-not-found
    
    log_success "Deployment deleted"
}

show_status() {
    echo -e "\n${BLUE}=== Image Generation Deployment Status ===${NC}\n"
    
    echo -e "${YELLOW}Pods:${NC}"
    kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null || echo "  No pods found"
    
    echo -e "\n${YELLOW}Services:${NC}"
    kubectl get svc -n "$NAMESPACE" 2>/dev/null || echo "  No services found"
    
    echo -e "\n${YELLOW}Endpoints:${NC}"
    local lb_ip=$(kubectl get svc image-gen -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [[ -n "$lb_ip" ]]; then
        echo "  Web UI: http://$lb_ip/"
        echo "  API: http://$lb_ip/api/generate"
        echo "  Health: http://$lb_ip/api/health"
    else
        echo "  LoadBalancer IP pending..."
    fi
}

show_logs() {
    log_info "Fetching logs from image-gen pods..."
    
    pods=$(kubectl get pods -n "$NAMESPACE" -l app=image-gen -o jsonpath='{.items[*].metadata.name}')
    
    for pod in $pods; do
        echo -e "\n${YELLOW}=== Logs from $pod ===${NC}"
        kubectl logs -n "$NAMESPACE" "$pod" --tail=50
    done
}

# Parse arguments
MODEL="qwen-image-2512"
REPLICAS=2
ACTION="deploy"

while [[ $# -gt 0 ]]; do
    case $1 in
        --model|-m)
            MODEL="$2"
            shift 2
            ;;
        --replicas|-r)
            REPLICAS="$2"
            shift 2
            ;;
        --list-models)
            list_models
            exit 0
            ;;
        --delete)
            ACTION="delete"
            shift
            ;;
        --status)
            ACTION="status"
            shift
            ;;
        --logs)
            ACTION="logs"
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Execute action
case $ACTION in
    deploy)
        deploy "$MODEL" "$REPLICAS"
        ;;
    delete)
        delete_deployment
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs
        ;;
esac
