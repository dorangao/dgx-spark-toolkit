# NVIDIA Nemotron-3 Nano 30B Deployment on DGX Spark

Deploy NVIDIA's Nemotron-3 Nano 30B model on a DGX Spark Kubernetes cluster using vLLM.

## Overview

Nemotron-3 Nano 30B is a 30-billion-parameter open LLM with ~3 billion "active" MoE (Mixture of Experts) parameters per inference. It's optimized for NVIDIA DGX Spark, H100, and B200 GPUs.

**Key Features:**
- FP8 precision (~30GB weights) for efficient inference
- OpenAI-compatible API (chat completions, text completions)
- Optimized for DGX Spark Blackwell architecture
- ~65+ tokens/second with CUDA graphs enabled

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

### Deploy with Script

```bash
# Set your HuggingFace token
export HF_TOKEN=hf_xxxxxxxxxxxxx

# Deploy
./deploy.sh

# Or pass token as argument
./deploy.sh --hf-token hf_xxxxxxxxxxxxx
```

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

# Deploy vLLM server
kubectl apply -f deployment-single-node.yaml

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

```bash
# Get LoadBalancer IP
LB_IP=$(kubectl get svc nemotron-service -n llm-inference -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# List models
curl http://${LB_IP}:8000/v1/models

# Chat completion
curl http://${LB_IP}:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8",
    "messages": [{"role": "user", "content": "Explain quantum computing in simple terms."}],
    "max_tokens": 200,
    "temperature": 0.7
  }'
```

### Using with Python

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://<LB_IP>:8000/v1",
    api_key="not-needed"  # vLLM doesn't require API key
)

response = client.chat.completions.create(
    model="nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8",
    messages=[
        {"role": "user", "content": "What is the capital of France?"}
    ],
    max_tokens=100
)

print(response.choices[0].message.content)
```

## Configuration Options

### Deployment Parameters

Key parameters in `deployment-single-node.yaml`:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--tensor-parallel-size` | 1 | Number of GPUs for tensor parallelism |
| `--max-model-len` | 8192 | Maximum context length |
| `--gpu-memory-utilization` | 0.90 | GPU memory fraction to use |
| `--kv-cache-dtype` | fp8 | KV cache precision |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `VLLM_FLASHINFER_MOE_BACKEND` | `throughput` or `latency` for MoE optimization |
| `VLLM_USE_CUDA_GRAPH` | Enable CUDA graphs (1=enabled) |

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
  https://huggingface.co/api/models/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8
```

### Out of Memory

If GPU runs out of memory:
- Reduce `--max-model-len` (e.g., 4096)
- Reduce `--gpu-memory-utilization` (e.g., 0.85)
- Consider using the FP4 quantized variant

### Slow inference

- Ensure CUDA graphs are enabled (`VLLM_USE_CUDA_GRAPH=1`)
- Check `VLLM_FLASHINFER_MOE_BACKEND=throughput`
- Verify using the optimized DGX Spark image

## Cleanup

```bash
# Remove deployment
./deploy.sh --delete

# Or manually
kubectl delete -f service.yaml
kubectl delete -f deployment-single-node.yaml
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
| `deployment-single-node.yaml` | vLLM server deployment (single node) |
| `service.yaml` | LoadBalancer + ClusterIP services |
| `deploy.sh` | Automated deployment script |

## Next Steps

- **Multi-node deployment**: See `deployment-multi-node.yaml` (coming soon) for distributed inference across 2 DGX Spark nodes using Ray + tensor/pipeline parallelism.
- **Monitoring**: Add Prometheus metrics scraping from vLLM's `/metrics` endpoint.
- **Autoscaling**: Configure HPA based on request queue length.

## References

- [NVIDIA Nemotron-3 Nano Model](https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8)
- [vLLM Documentation](https://docs.vllm.ai/)
- [vLLM Distributed Inference](https://docs.vllm.ai/en/latest/serving/distributed_serving.html)
- [DGX Spark vLLM Image](https://huggingface.co/nologik/vllm-dgx-spark)


