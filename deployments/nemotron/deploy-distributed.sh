#!/usr/bin/env bash
set -euo pipefail

# Deploy LLM models in distributed mode using KubeRay
# Uses Ray cluster with pipeline parallelism across 2 DGX Spark nodes
# Supports multiple models via --model flag

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_CONFIG_FILE="$SCRIPT_DIR/model-configs.yaml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

# Get available models from config
get_available_models() {
    if command -v yq &> /dev/null; then
        yq -r '.models | keys | .[]' "$MODEL_CONFIG_FILE" 2>/dev/null || echo "nemotron-nano-30b"
    else
        # Fallback: parse YAML manually
        grep -E '^\s{2}[a-z0-9-]+:$' "$MODEL_CONFIG_FILE" | sed 's/://g' | tr -d ' ' 2>/dev/null || echo "nemotron-nano-30b"
    fi
}

# Get model config value using yq or fallback
get_model_config() {
    local model="$1"
    local key="$2"
    local default="${3:-}"
    
    if command -v yq &> /dev/null; then
        local value
        value=$(yq -r ".models[\"$model\"].$key // \"\"" "$MODEL_CONFIG_FILE" 2>/dev/null)
        if [[ -n "$value" && "$value" != "null" ]]; then
            echo "$value"
        else
            echo "$default"
        fi
    else
        echo "$default"
    fi
}

# Get default model
get_default_model() {
    if command -v yq &> /dev/null; then
        yq -r '.default_model // "nemotron-nano-30b"' "$MODEL_CONFIG_FILE" 2>/dev/null || echo "nemotron-nano-30b"
    else
        echo "nemotron-nano-30b"
    fi
}

usage() {
    local default_model
    default_model=$(get_default_model)
    local available_models
    available_models=$(get_available_models | tr '\n' ', ' | sed 's/,$//')
    
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Deploy LLM models with distributed inference using KubeRay.
Uses Pipeline Parallelism to split model layers across spark-2959 and spark-ba63.

Options:
    --model NAME        Model to deploy (default: $default_model)
    --hf-token TOKEN    HuggingFace token for model download
    --dry-run           Show what would be applied without making changes
    --delete            Delete the distributed deployment
    --single            Switch back to single-node deployment
    --status            Show status of Ray cluster and vLLM
    --list-models       List available model presets
    -h, --help          Show this help message

Available Models:
    $available_models

Architecture:
    - spark-2959 (10.10.10.1): Ray Head + vLLM API Server (layers 0-N/2)
    - spark-ba63 (10.10.10.2): Ray Worker (layers N/2-N)
    - Communication: 200GbE fabric network via KubeRay

Requirements:
    - KubeRay operator installed (helm install kuberay-operator kuberay/kuberay-operator)
    - Both nodes must be Ready in the cluster
    - HuggingFace token with model access
    - yq (recommended) for YAML parsing: sudo snap install yq

Environment Variables:
    HF_TOKEN            HuggingFace token (alternative to --hf-token)
    VLLM_MODEL          Model to deploy (alternative to --model)

Examples:
    # Deploy default model (Nemotron)
    export HF_TOKEN=hf_xxxxxxxxxxxxx
    ./deploy-distributed.sh

    # Deploy Qwen Image model
    ./deploy-distributed.sh --model qwen-image-2512

    # Deploy Qwen2.5-32B
    ./deploy-distributed.sh --model qwen2.5-32b

    # List available models
    ./deploy-distributed.sh --list-models

    # Check status
    ./deploy-distributed.sh --status

    # Remove distributed deployment
    ./deploy-distributed.sh --delete
EOF
}

list_models() {
    echo -e "${CYAN}Available Model Presets:${NC}"
    echo ""
    
    if command -v yq &> /dev/null; then
        yq -r '.models | to_entries[] | "\(.key):\n  Name: \(.value.display_name)\n  HF ID: \(.value.huggingface_id)\n  Size: \(.value.size_gb)GB\n  Distributed: \(.value.distributed)\n  Min GPUs: \(.value.min_gpus)\n  Description: \(.value.description)\n"' "$MODEL_CONFIG_FILE" 2>/dev/null
    else
        echo "Install yq for detailed model info: sudo snap install yq"
        echo ""
        echo "Available models:"
        get_available_models
    fi
    
    echo -e "${GREEN}Default model:${NC} $(get_default_model)"
}

# Generate vllm-serve-job.yaml for the selected model
generate_vllm_serve_job() {
    local model="$1"
    local output_file="$SCRIPT_DIR/vllm-serve-job-generated.yaml"
    
    # Get model configuration
    local hf_id display_name trust_remote dtype tp_size pp_size max_model_len gpu_util enforce_eager
    
    hf_id=$(get_model_config "$model" "huggingface_id" "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16")
    display_name=$(get_model_config "$model" "display_name" "$model")
    trust_remote=$(get_model_config "$model" "requires_trust_remote_code" "true")
    dtype=$(get_model_config "$model" "vllm_args.dtype" "bfloat16")
    tp_size=$(get_model_config "$model" "vllm_args.tensor_parallel_size" "1")
    pp_size=$(get_model_config "$model" "vllm_args.pipeline_parallel_size" "2")
    max_model_len=$(get_model_config "$model" "vllm_args.max_model_len" "4096")
    gpu_util=$(get_model_config "$model" "vllm_args.gpu_memory_utilization" "0.85")
    enforce_eager=$(get_model_config "$model" "vllm_args.enforce_eager" "true")
    
    # Build trust-remote-code flag
    local trust_flag=""
    if [[ "$trust_remote" == "true" ]]; then
        trust_flag="'--trust-remote-code',"
    fi
    
    # Build enforce-eager flag
    local eager_flag=""
    if [[ "$enforce_eager" == "true" ]]; then
        eager_flag="'--enforce-eager'"
    fi
    
    # Log to stderr so stdout only contains the filename
    log_info "Generating vLLM serve job for: $display_name" >&2
    log_info "  HuggingFace ID: $hf_id" >&2
    log_info "  Pipeline Parallel: $pp_size, Tensor Parallel: $tp_size" >&2
    log_info "  Max Model Len: $max_model_len, GPU Util: $gpu_util" >&2
    
    cat > "$output_file" << YAML
# RayJob to start vLLM server on the Ray cluster
# Auto-generated for model: $display_name
# Model: $hf_id
#
apiVersion: ray.io/v1
kind: RayJob
metadata:
  name: vllm-serve
  namespace: llm-inference
  labels:
    app.kubernetes.io/name: vllm-distributed
    app.kubernetes.io/component: inference-server
    vllm.model: "$model"
  annotations:
    vllm.model-id: "$hf_id"
    vllm.display-name: "$display_name"
spec:
  # Don't delete cluster when job finishes - we want it to keep serving
  shutdownAfterJobFinishes: false
  
  # Use existing cluster instead of creating new one
  clusterSelector:
    ray.io/cluster: vllm-cluster
  
  # vLLM serve command as entrypoint
  entrypoint: |
    python -c "
    import ray
    import subprocess
    import sys
    import time
    
    # Initialize Ray connection
    ray.init(address='auto')
    
    # Wait for all nodes to be ready
    print('Waiting for Ray cluster to be ready...')
    min_gpus = $pp_size  # Need at least pipeline_parallel_size GPUs
    for i in range(60):
        nodes = ray.nodes()
        ready_nodes = [n for n in nodes if n['Alive']]
        gpu_count = sum(n.get('Resources', {}).get('GPU', 0) for n in ready_nodes)
        print(f'Ready nodes: {len(ready_nodes)}, GPUs: {gpu_count}')
        if gpu_count >= min_gpus:
            print('Cluster ready! Starting vLLM...')
            break
        time.sleep(5)
    else:
        print('Timeout waiting for cluster')
        sys.exit(1)
    
    # Start vLLM server
    cmd = [
        'vllm', 'serve', '$hf_id',
        '--host', '0.0.0.0',
        '--port', '8081',
        $trust_flag
        '--dtype', '$dtype',
        '--distributed-executor-backend', 'ray',
        '--tensor-parallel-size', '$tp_size',
        '--pipeline-parallel-size', '$pp_size',
        '--max-model-len', '$max_model_len',
        '--gpu-memory-utilization', '$gpu_util',
        '--download-dir', '/models',
        $eager_flag
    ]
    # Remove empty strings from cmd
    cmd = [c for c in cmd if c]
    
    print(f'Running: {\" \".join(cmd)}')
    subprocess.run(cmd)
    "
  
  # Runtime environment
  runtimeEnvYAML: |
    env_vars:
      HF_HOME: /models/.cache
      TRANSFORMERS_CACHE: /models/.cache
      HF_HUB_CACHE: /models/.cache/hub
      VLLM_USE_CUDA_GRAPH: "0"
      # NCCL configuration for fabric network
      NCCL_SOCKET_IFNAME: "^lo,docker"
      NCCL_IB_DISABLE: "1"
      NCCL_DEBUG: "WARN"
      NCCL_P2P_DISABLE: "1"
      GLOO_SOCKET_IFNAME: "enP7s7,enp1s0f1np1"
      NCCL_NET: "Socket"
  
  # Job runs on head node
  submitterPodTemplate:
    spec:
      containers:
        - name: job-submitter
          image: avarok/vllm-dgx-spark:v11
          imagePullPolicy: IfNotPresent
          env:
            - name: HF_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hf-token-secret
                  key: HF_TOKEN
          resources:
            requests:
              cpu: "1"
              memory: "4Gi"
            limits:
              cpu: "2"
              memory: "8Gi"
      restartPolicy: Never
YAML

    echo "$output_file"
}

# Parse arguments
DRY_RUN=""
DELETE_MODE=false
SINGLE_MODE=false
STATUS_MODE=false
LIST_MODELS=false
HF_TOKEN="${HF_TOKEN:-}"
MODEL="${VLLM_MODEL:-}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --model)
            MODEL="$2"
            shift 2
            ;;
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
        --list-models)
            LIST_MODELS=true
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

# List models mode
if $LIST_MODELS; then
    list_models
    exit 0
fi

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
    
    echo -e "${BLUE}=== Current Model ===${NC}"
    CURRENT_MODEL=$(kubectl get rayjob vllm-serve -n llm-inference -o jsonpath='{.metadata.labels.vllm\.model}' 2>/dev/null || echo "unknown")
    CURRENT_HF_ID=$(kubectl get rayjob vllm-serve -n llm-inference -o jsonpath='{.metadata.annotations.vllm\.model-id}' 2>/dev/null || echo "unknown")
    echo "Model: $CURRENT_MODEL"
    echo "HuggingFace ID: $CURRENT_HF_ID"
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
    log_step "Deleting distributed deployment..."
    
    kubectl delete rayjob vllm-serve -n llm-inference --ignore-not-found $DRY_RUN || true
    kubectl delete raycluster vllm-cluster -n llm-inference --ignore-not-found $DRY_RUN || true
    kubectl delete svc vllm-distributed-service -n llm-inference --ignore-not-found $DRY_RUN || true
    
    # Also delete old manual deployment if exists
    kubectl delete -f "$SCRIPT_DIR/deployment-multi-node.yaml" --ignore-not-found $DRY_RUN 2>/dev/null || true
    
    # Cleanup generated job file
    rm -f "$SCRIPT_DIR/vllm-serve-job-generated.yaml"
    
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

# Set default model if not specified
if [[ -z "$MODEL" ]]; then
    MODEL=$(get_default_model)
fi

# Validate model exists
if ! get_available_models | grep -q "^${MODEL}$"; then
    log_error "Unknown model: $MODEL"
    log_info "Available models:"
    get_available_models | sed 's/^/  - /'
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

# Get model info
MODEL_DISPLAY=$(get_model_config "$MODEL" "display_name" "$MODEL")
MODEL_MIN_GPUS=$(get_model_config "$MODEL" "min_gpus" "2")
MODEL_DISTRIBUTED=$(get_model_config "$MODEL" "distributed" "true")

# Check node requirements based on model
log_step "Checking cluster nodes..."
NODE_COUNT=$(kubectl get nodes --no-headers | grep -c "Ready" || echo "0")

if [[ "$MODEL_DISTRIBUTED" == "true" || "$MODEL_MIN_GPUS" -ge 2 ]]; then
    if [[ "$NODE_COUNT" -lt 2 ]]; then
        log_error "Model $MODEL_DISPLAY requires distributed deployment (2 nodes). Found: $NODE_COUNT"
        log_info "Check node status with: kubectl get nodes"
        exit 1
    fi
    
    if ! kubectl get node spark-ba63 | grep -q "Ready"; then
        log_error "spark-ba63 is not Ready. Cannot deploy distributed mode for $MODEL_DISPLAY."
        exit 1
    fi
    log_info "Both nodes are Ready."
else
    log_info "$MODEL_DISPLAY can run on single node. Found $NODE_COUNT Ready node(s)."
fi

echo ""
log_info "Deploying $MODEL_DISPLAY in DISTRIBUTED mode (KubeRay)"
log_info "Pipeline Parallelism: $(get_model_config "$MODEL" "vllm_args.pipeline_parallel_size" "2") nodes"
echo ""

# Step 1: Ensure namespace exists
log_step "1/7 Ensuring namespace exists..."
kubectl apply -f "$SCRIPT_DIR/namespace.yaml" $DRY_RUN

# Step 2: Ensure PVC exists
log_step "2/7 Ensuring PVC exists..."
kubectl apply -f "$SCRIPT_DIR/pvc.yaml" $DRY_RUN

# Step 3: Ensure secret exists
log_step "3/7 Ensuring HuggingFace token secret..."
if [[ -z "$DRY_RUN" ]]; then
    kubectl create secret generic hf-token-secret \
        --namespace=llm-inference \
        --from-literal=HF_TOKEN="$HF_TOKEN" \
        --dry-run=client -o yaml | kubectl apply -f -
fi

# Step 4: Delete single-node deployment if exists
log_step "4/7 Removing single-node deployment (if any)..."
kubectl delete deployment nemotron-vllm -n llm-inference --ignore-not-found $DRY_RUN || true

# Step 5: Delete existing RayJob (for model switch)
log_step "5/7 Removing existing RayJob (if switching models)..."
kubectl delete rayjob vllm-serve -n llm-inference --ignore-not-found $DRY_RUN || true

# Step 6: Deploy RayCluster
log_step "6/7 Deploying RayCluster..."
kubectl apply -f "$SCRIPT_DIR/raycluster-vllm.yaml" $DRY_RUN

# Step 7: Wait for cluster and start vLLM
if [[ -z "$DRY_RUN" ]]; then
    log_step "7/7 Waiting for Ray cluster to be ready..."
    
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
    
    # Wait for worker pod if distributed
    if [[ "$MODEL_DISTRIBUTED" == "true" || "$MODEL_MIN_GPUS" -ge 2 ]]; then
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
    fi
    
    # Generate and submit vLLM job
    log_info "Generating vLLM serve job for $MODEL_DISPLAY..."
    JOB_FILE=$(generate_vllm_serve_job "$MODEL")
    
    log_info "Submitting vLLM serve job..."
    kubectl apply -f "$JOB_FILE"
fi

echo ""
log_info "Distributed deployment initiated!"
log_info "Model: $MODEL_DISPLAY"
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
    echo -e "   ${YELLOW}curl http://10.10.10.1:8081/v1/models${NC}"
    echo ""
    echo -e "   Or via LoadBalancer (when assigned):"
    echo -e "   ${YELLOW}LB_IP=\$(kubectl get svc vllm-distributed-service -n llm-inference -o jsonpath='{.status.loadBalancer.ingress[0].ip}')${NC}"
    echo -e "   ${YELLOW}curl http://\$LB_IP:8000/v1/models${NC}"
    echo ""
    echo -e "5. Ray Dashboard (for monitoring):"
    echo -e "   ${YELLOW}http://10.10.10.1:8265${NC}"
    echo ""
    echo -e "6. To switch models:"
    echo -e "   ${YELLOW}./deploy-distributed.sh --model qwen2.5-32b${NC}"
fi
