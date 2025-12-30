# NVIDIA Nemotron-3 Nano 30B Deployment on DGX Spark

Deploy NVIDIA's Nemotron-3 Nano 30B model on a DGX Spark Kubernetes cluster using vLLM.

## Overview

Nemotron-3 Nano 30B is a 30-billion-parameter open LLM with ~3 billion "active" MoE (Mixture of Experts) parameters per inference. It's optimized for NVIDIA DGX Spark, H100, and B200 GPUs.

**Deployment Modes:**
| Mode | Nodes | Description |
|------|-------|-------------|
| **Single-Node** | 1 | Run entire model on spark-2959 with BF16 precision |
| **Distributed** | 2 | Split model layers across both nodes using Pipeline Parallelism |

**Key Features:**
- BF16 precision for stable inference on Blackwell GPUs
- OpenAI-compatible API (chat completions, text completions)
- Optimized for DGX Spark Blackwell (SM12.1) architecture
- ~65+ tokens/second with single node
- Distributed mode enables larger context lengths

## Prerequisites

1. **Kubernetes cluster** with NVIDIA GPU Operator installed
2. **Longhorn storage** (or other CSI driver) for persistent volumes
3. **MetalLB** (optional) for LoadBalancer service
4. **HuggingFace token** with access to the Nemotron model

### Get HuggingFace Token

1. Create an account at [huggingface.co](https://huggingface.co)
2. Go to [Settings > Tokens](https://huggingface.co/settings/tokens)
3. Create a new token with "Read" access
4. Accept the model license at: [nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8](https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8)

## Quick Start

### Option A: Single-Node Deployment

Run the model on one DGX Spark node (spark-2959):

```bash
# Set your HuggingFace token
export HF_TOKEN=hf_xxxxxxxxxxxxx

# Deploy single-node
./deploy.sh

# Or pass token as argument
./deploy.sh --hf-token hf_xxxxxxxxxxxxx
```

### Option B: Distributed 2-Node Deployment

Split the model across both nodes using Pipeline Parallelism:

```bash
# Set your HuggingFace token
export HF_TOKEN=hf_xxxxxxxxxxxxx

# Deploy distributed (requires both spark-2959 and spark-ba63)
./deploy-distributed.sh

# Switch back to single-node mode
./deploy-distributed.sh --single
```

**Distributed Architecture:**
- **spark-2959** (10.10.10.1): Ray Head + vLLM API Server (layers 0-N/2)
- **spark-ba63** (10.10.10.2): Ray Worker (layers N/2-N)
- Communication via 200GbE fabric network

### Manual Deployment

```bash
# Create namespace
kubectl apply -f namespace.yaml

# Create PVC for model cache
kubectl apply -f pvc.yaml

# Create HuggingFace token secret
kubectl create secret generic hf-token-secret \
  --namespace=llm-inference \
  --from-literal=HF_TOKEN=hf_xxxxxxxxxxxxx

# Deploy vLLM server (single-node)
kubectl apply -f deployment-single-node.yaml

# OR deploy distributed (2-node)
kubectl apply -f deployment-multi-node.yaml

# Create services
kubectl apply -f service.yaml
```

## Monitor Deployment

```bash
# Watch pod status
kubectl get pods -n llm-inference -w

# View logs (model download progress)
kubectl logs -f -n llm-inference deployment/nemotron-vllm

# Check services
kubectl get svc -n llm-inference
```

## Test the API

Once the pod is ready, test the OpenAI-compatible API:

### Single-Node API (via LoadBalancer)

```bash
# Get LoadBalancer IP
LB_IP=$(kubectl get svc nemotron-service -n llm-inference -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# List models
curl http://${LB_IP}:8000/v1/models

# Chat completion
curl http://${LB_IP}:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16",
    "messages": [{"role": "user", "content": "Explain quantum computing in simple terms."}],
    "max_tokens": 200,
    "temperature": 0.7
  }'
```

### Distributed API (via Fabric Network)

For distributed mode, the API is available on the fabric network:

```bash
# List models (from any cluster node)
curl http://10.10.10.1:8000/v1/models

# Chat completion
curl http://10.10.10.1:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 100
  }'
```

### Using with Python

```python
from openai import OpenAI

# For single-node (LoadBalancer)
client = OpenAI(
    base_url="http://<LB_IP>:8000/v1",
    api_key="not-needed"  # vLLM doesn't require API key
)

# For distributed mode (fabric network)
# client = OpenAI(base_url="http://10.10.10.1:8000/v1", api_key="not-needed")

response = client.chat.completions.create(
    model="nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16",
    messages=[
        {"role": "user", "content": "What is the capital of France?"}
    ],
    max_tokens=100
)

print(response.choices[0].message.content)
```

## Configuration Options

### Single-Node Parameters

Key parameters in `deployment-single-node.yaml`:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--dtype` | bfloat16 | Model precision (BF16 for Blackwell stability) |
| `--tensor-parallel-size` | 1 | Number of GPUs for tensor parallelism |
| `--max-model-len` | 2048 | Maximum context length (conservative for single GPU) |
| `--gpu-memory-utilization` | 0.85 | GPU memory fraction to use |
| `--enforce-eager` | enabled | Disable CUDA graph compilation (Blackwell fix) |

### Distributed Mode Parameters

Key parameters in `deployment-multi-node.yaml`:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--pipeline-parallel-size` | 2 | Number of nodes (splits layers across nodes) |
| `--tensor-parallel-size` | 1 | GPUs per node |
| `--max-model-len` | 4096 | Higher context (model split across 2 GPUs) |
| `--gpu-memory-utilization` | 0.85 | GPU memory fraction per node |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `VLLM_FLASHINFER_MOE_BACKEND` | `throughput` or `latency` for MoE optimization |
| `VLLM_USE_CUDA_GRAPH` | Enable CUDA graphs (0=disabled for Blackwell) |
| `VLLM_HOST_IP` | Node IP for Ray cluster (fabric network) |
| `RAY_ADDRESS` | Ray head address for distributed mode |

## Troubleshooting

### Pod stuck in Pending

```bash
# Check events
kubectl describe pod -n llm-inference -l app=nemotron-vllm

# Common issues:
# - No GPU available: Check GPU operator
# - PVC not bound: Check Longhorn status
```

### Model download fails

```bash
# Check HuggingFace token
kubectl get secret hf-token-secret -n llm-inference -o yaml

# Verify token has model access
curl -H "Authorization: Bearer $HF_TOKEN" \
  https://huggingface.co/api/models/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16
```

### Out of Memory

If GPU runs out of memory:
- Reduce `--max-model-len` (e.g., 1024)
- Reduce `--gpu-memory-utilization` (e.g., 0.70)
- Consider using distributed mode (splits model across 2 GPUs)

### FP8 Model Produces Garbled Output

On DGX Spark (Blackwell GB10), the FP8 model may produce incoherent output.
**Solution:** Use the BF16 model instead (`nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16`).

### CUDA Compilation Errors (ptxas sm_121a)

Blackwell SM12.1 architecture requires `--enforce-eager` to disable problematic compilation.
**Solution:** Ensure `--enforce-eager` is in the vLLM command args.

### Slow inference

- Verify using the optimized DGX Spark image (`avarok/vllm-dgx-spark:v11`)
- Check `VLLM_FLASHINFER_MOE_BACKEND=throughput`
- Note: CUDA graphs disabled on Blackwell for stability

## Cleanup

```bash
# Remove single-node deployment
./deploy.sh --delete

# Remove distributed deployment
./deploy-distributed.sh --delete

# Or manually remove everything
kubectl delete -f service.yaml
kubectl delete -f deployment-single-node.yaml
kubectl delete -f deployment-multi-node.yaml
kubectl delete secret hf-token-secret -n llm-inference
kubectl delete -f pvc.yaml
kubectl delete -f namespace.yaml
```

## Files

| File | Description |
|------|-------------|
| `namespace.yaml` | Creates `llm-inference` namespace |
| `pvc.yaml` | 100Gi persistent volume for model cache |
| `secret.yaml.template` | Template for HuggingFace token secret |
| `deployment-single-node.yaml` | vLLM server on single node (spark-2959) |
| `deployment-multi-node.yaml` | Distributed Ray cluster (both nodes) |
| `service.yaml` | LoadBalancer + ClusterIP services |
| `deploy.sh` | Single-node deployment script |
| `deploy-distributed.sh` | Distributed deployment script |

## Architecture

### Single-Node Mode
```
┌─────────────────────────────────┐
│         spark-2959              │
│  ┌───────────────────────────┐  │
│  │    vLLM Server            │  │
│  │    (full model)           │  │
│  │    GB10 GPU - BF16        │  │
│  └───────────────────────────┘  │
│            ↓                    │
│    API: :8000/v1/*              │
└─────────────────────────────────┘
```

### Distributed Mode (Pipeline Parallelism)
```
┌─────────────────────────────────┐     200GbE Fabric     ┌─────────────────────────────────┐
│         spark-2959              │ ←─────────────────→   │         spark-ba63              │
│       (10.10.10.1)              │                       │       (10.10.10.2)              │
│  ┌───────────────────────────┐  │                       │  ┌───────────────────────────┐  │
│  │    Ray Head               │  │     Ray Cluster       │  │    Ray Worker             │  │
│  │    vLLM API Server        │  │                       │  │                           │  │
│  │    Layers 0 → N/2         │  │  ← Layer outputs →    │  │    Layers N/2 → N         │  │
│  │    GB10 GPU               │  │                       │  │    GB10 GPU               │  │
│  └───────────────────────────┘  │                       │  └───────────────────────────┘  │
│            ↓                    │                       │                                 │
│    API: 10.10.10.1:8000         │                       │                                 │
└─────────────────────────────────┘                       └─────────────────────────────────┘
```

## Troubleshooting

### Distributed Mode Issues

**Ray worker not joining:**
```bash
# Check Ray head logs
kubectl logs -f -n llm-inference -l app=nemotron-ray-head

# Check Ray worker logs
kubectl logs -f -n llm-inference -l app=nemotron-ray-worker

# Verify fabric network connectivity
kubectl exec -it -n llm-inference <worker-pod> -- ping 10.10.10.1
```

**Slow distributed inference:**
- Ensure using 200GbE fabric network (10.10.10.x), not standard network
- Check for network congestion with `iperf3`
- Pipeline parallelism has higher latency than tensor parallelism

## Next Steps

- **Monitoring**: Add Prometheus metrics scraping from vLLM's `/metrics` endpoint.
- **Autoscaling**: Configure HPA based on request queue length.
- **Load balancing**: Add ingress for multi-replica serving.

## References

- [NVIDIA Nemotron-3 Nano Model (BF16)](https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16)
- [NVIDIA Nemotron-3 Nano Model (FP8)](https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8)
- [vLLM Documentation](https://docs.vllm.ai/)
- [vLLM Distributed Inference](https://docs.vllm.ai/en/latest/serving/distributed_serving.html)
- [DGX Spark vLLM Image](https://hub.docker.com/r/avarok/vllm-dgx-spark)


