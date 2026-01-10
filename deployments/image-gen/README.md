# Image Generation Deployment

Deploy image generation models (Qwen-Image-2512, Stable Diffusion XL, FLUX) to your Kubernetes cluster with load balancing.

## Quick Start

```bash
# Deploy Qwen-Image-2512 (default)
./deploy.sh

# Deploy a specific model
./deploy.sh --model stable-diffusion-xl

# List available models
./deploy.sh --list-models
```

## Available Models

| Model | HuggingFace ID | VRAM Required |
|-------|---------------|---------------|
| qwen-image-2512 | Qwen/Qwen-Image-2512 | ~48GB |
| stable-diffusion-xl | stabilityai/stable-diffusion-xl-base-1.0 | ~16GB |
| flux-schnell | black-forest-labs/FLUX.1-schnell | ~24GB |

## Architecture

```
                    ┌─────────────────┐
                    │  LoadBalancer   │
                    │  192.168.1.205  │
                    └────────┬────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
       ┌──────▼──────┐              ┌───────▼─────┐
       │  Pod #1     │              │  Pod #2     │
       │  Node 1     │              │  Node 2     │
       │  GPU: GB10  │              │  GPU: GB10  │
       └─────────────┘              └─────────────┘
```

## Features

- **Load Balanced**: Requests distributed across both nodes
- **Anti-Affinity**: Pods spread across different nodes automatically
- **Persistent Cache**: Models cached on host filesystem
- **REST API**: JSON API at `/api/generate`
- **Web UI**: Gradio interface for interactive use

## API Usage

### Generate Image

```bash
curl -X POST http://192.168.1.205/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "a beautiful sunset over mountains",
    "steps": 30,
    "guidance_scale": 7.5,
    "return_base64": true
  }'
```

### Health Check

```bash
curl http://192.168.1.205/api/health
```

### Model Info

```bash
curl http://192.168.1.205/api/model-info
```

## Pre-download Models

To avoid download times during deployment:

```bash
# Download specific model to all nodes
./manage-cache.sh download qwen-image-2512

# Download all models
./manage-cache.sh download-all

# List cached models
./manage-cache.sh list
```

## Configuration

### Change Model

```bash
# Update to different model
./deploy.sh --model flux-schnell --replicas 2
```

### Scale Replicas

```bash
kubectl scale deployment image-gen -n image-gen --replicas=1
```

### View Logs

```bash
./deploy.sh --logs
# or
kubectl logs -n image-gen -l app=image-gen -f
```

## Cleanup

```bash
./deploy.sh --delete
```

## Adding New Models

1. Add model to `model-configs.yaml`
2. Add model configuration to `server.py`
3. Update `deploy.sh` MODELS array
4. Deploy with `./deploy.sh --model your-new-model`

## Troubleshooting

### Pods not starting

```bash
kubectl describe pods -n image-gen
kubectl logs -n image-gen -l app=image-gen
```

### Model download slow

Pre-download using `manage-cache.sh download MODEL`

### Out of memory

- Reduce replicas to 1
- Use smaller model (stable-diffusion-xl)
- Check GPU memory with `nvidia-smi`
