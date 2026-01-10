# Qwen-Image-2512 Text-to-Image Generation Setup Guide

A comprehensive tutorial for deploying Qwen-Image-2512 on NVIDIA DGX Spark clusters with Kubernetes orchestration.

---

## Table of Contents

1. [Introduction](#introduction)
2. [Understanding Qwen-Image-2512](#understanding-qwen-image-2512)
3. [Architecture Overview](#architecture-overview)
4. [Prerequisites](#prerequisites)
5. [Deployment Options](#deployment-options)
6. [Option 1: Kubernetes Cluster Deployment](#option-1-kubernetes-cluster-deployment)
7. [Option 2: Standalone Docker Deployment](#option-2-standalone-docker-deployment)
8. [Option 3: Local Python Environment](#option-3-local-python-environment)
9. [Using the Image Generation API](#using-the-image-generation-api)
10. [Integration with Cluster Control UI](#integration-with-cluster-control-ui)
11. [Performance Tuning](#performance-tuning)
12. [Troubleshooting](#troubleshooting)
13. [Example Gallery](#example-gallery)

---

## Introduction

This guide walks you through deploying **Qwen-Image-2512**, a state-of-the-art text-to-image generation model from Alibaba's Qwen team. By the end of this tutorial, you'll have a fully operational image generation service running on your DGX Spark cluster.

### What You'll Learn

- The theory behind diffusion-based image generation
- How to deploy Qwen-Image across multiple GPU nodes
- Best practices for model caching and performance optimization
- How to integrate image generation into your applications

---

## Understanding Qwen-Image-2512

### What is Qwen-Image-2512?

Qwen-Image-2512 is a **text-to-image diffusion model** that generates high-quality 2512×2512 pixel images from natural language descriptions. It's part of the Qwen family of models developed by Alibaba Cloud.

### Key Specifications

| Specification | Value |
|---------------|-------|
| **Model ID** | `Qwen/Qwen-Image-2512` |
| **Max Resolution** | 2512 × 2512 pixels (requires A100/H100) |
| **Practical Max on GB10** | 1536 × 1536 pixels |
| **Model Size** | ~15GB (weights) |
| **GPU Memory Required** | 24GB+ dedicated VRAM, or 128GB+ unified |
| **Inference Time (GB10)** | 10s (512px) to 190s (1536px) |
| **Inference Time (A100)** | ~3-4× faster than GB10 |

### How Diffusion Models Work

Diffusion models generate images through an iterative **denoising process**:

```
Random Noise → [Denoising Step 1] → [Denoising Step 2] → ... → [Final Image]
                     ↑                    ↑
              Text Embedding        Text Embedding
              (your prompt)         (your prompt)
```

1. **Forward Diffusion**: Training phase where clean images are gradually corrupted with Gaussian noise
2. **Reverse Diffusion**: Inference phase where the model learns to reverse this process, guided by text embeddings
3. **Text Conditioning**: A text encoder (typically CLIP or similar) converts your prompt into embeddings that guide the denoising

### Qwen-Image vs. Other Models

| Feature | Qwen-Image-2512 | Stable Diffusion XL | FLUX.1 |
|---------|-----------------|---------------------|--------|
| Native Resolution | 2512×2512 | 1024×1024 | 1024×1024 |
| Model Size | ~15GB | ~6.5GB | ~12GB |
| Speed | Medium | Fast | Medium |
| Quality | High | High | Very High |
| License | Research | Open | Gated |

> **Note**: Qwen-Image-2512 is distinct from Qwen2-VL (vision-language model for image *understanding*). This model is for image *generation*.

---

## Architecture Overview

### Deployment Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────┐         ┌──────────────────┐             │
│  │   Node 1 (Head)  │         │   Node 2 (Worker)│             │
│  │  ┌────────────┐  │         │  ┌────────────┐  │             │
│  │  │ image-gen  │  │         │  │ image-gen  │  │             │
│  │  │   Pod      │  │         │  │   Pod      │  │             │
│  │  │ ┌────────┐ │  │         │  │ ┌────────┐ │  │             │
│  │  │ │ GPU    │ │  │         │  │ │ GPU    │ │  │             │
│  │  │ │(Cached │ │  │         │  │ │(Cached │ │  │             │
│  │  │ │ Model) │ │  │         │  │ │ Model) │ │  │             │
│  │  │ └────────┘ │  │         │  │ └────────┘ │  │             │
│  │  └────────────┘  │         │  └────────────┘  │             │
│  │        ↓         │         │        ↓         │             │
│  │  /data/models/   │         │  /data/models/   │             │
│  │  (hostPath)      │         │  (hostPath)      │             │
│  └──────────────────┘         └──────────────────┘             │
│            │                           │                        │
│            └───────────┬───────────────┘                        │
│                        ↓                                        │
│              ┌─────────────────┐                                │
│              │  LoadBalancer   │                                │
│              │ 192.168.86.210  │                                │
│              └─────────────────┘                                │
│                        ↓                                        │
└────────────────────────┼────────────────────────────────────────┘
                         ↓
              ┌─────────────────┐
              │  Cluster Control│
              │       UI        │
              │  (Flask App)    │
              └─────────────────┘
```

### Component Breakdown

| Component | Purpose |
|-----------|---------|
| **FastAPI Server** | Handles HTTP requests, manages model lifecycle |
| **Diffusers Pipeline** | Loads and runs the Qwen-Image model |
| **LoadBalancer** | Distributes requests across pods |
| **hostPath Volume** | Persistent model cache across restarts |

---

## Prerequisites

### Hardware Requirements

- **GPU**: NVIDIA GPU with 24GB+ VRAM (DGX Spark, A100, H100, RTX 4090)
- **RAM**: 32GB+ system memory
- **Storage**: 50GB+ free space for model weights

### Software Requirements

```bash
# Verify NVIDIA drivers and CUDA
nvidia-smi

# Verify Kubernetes cluster
kubectl get nodes

# Verify container runtime
docker info | grep -i runtime
```

### Required Access

- HuggingFace account with accepted model license
- HuggingFace token with read access

```bash
# Set your HuggingFace token
export HF_TOKEN="hf_your_token_here"
```

---

## Deployment Options

Choose the deployment method that best fits your use case:

| Option | Best For | Complexity | Scalability |
|--------|----------|------------|-------------|
| **Kubernetes Cluster** | Production, multi-user | Medium | High |
| **Standalone Docker** | Development, testing | Low | Single node |
| **Local Python** | Quick experiments | Low | Single GPU |

---

## Option 1: Kubernetes Cluster Deployment

This is the **recommended production deployment** for DGX Spark clusters.

### Step 1: Clone the Repository

```bash
git clone https://github.com/your-org/dgx-spark-toolkit.git
cd dgx-spark-toolkit/deployments/image-gen
```

### Step 2: Review Configuration

Examine the model configuration:

```bash
cat model-configs.yaml
```

```yaml
# Model configurations for image generation
models:
  qwen-image-2512:
    name: "Qwen Image 2512"
    huggingface_id: "Qwen/Qwen-Image-2512"
    type: "text-to-image"
    default_resolution: 2512
    gpu_memory_required: "24GB"
    description: "High-resolution text-to-image generation"
```

### Step 3: Create Namespace and Deploy

```bash
# Deploy the image generation service
./deploy.sh --deploy

# Monitor deployment progress
kubectl get pods -n image-gen -w
```

### Step 4: Verify Deployment

```bash
# Check pod status (wait for Ready 1/1)
kubectl get pods -n image-gen

# Expected output:
# NAME                        READY   STATUS    RESTARTS   AGE
# image-gen-xxxxx-aaaaa       1/1     Running   0          5m
# image-gen-xxxxx-bbbbb       1/1     Running   0          5m

# Check service endpoint
kubectl get svc -n image-gen

# Expected output:
# NAME        TYPE           CLUSTER-IP     EXTERNAL-IP      PORT(S)
# image-gen   LoadBalancer   10.x.x.x       192.168.86.210   80:xxxxx/TCP
```

### Step 5: Test the Endpoint

```bash
# Health check
curl http://192.168.86.210/api/health

# Expected response:
# {"status":"healthy","model":"Qwen/Qwen-Image-2512","device":"cuda"}
```

### Step 6: Generate Your First Image

```bash
# Generate and decode base64 response to PNG
curl -s -X POST http://192.168.86.210/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "A serene Japanese garden with cherry blossoms, koi pond, wooden bridge, soft morning light",
    "negative_prompt": "blurry, low quality, distorted",
    "steps": 30,
    "guidance_scale": 7.5,
    "width": 1024,
    "height": 1024
  }' | jq -r '.image_base64' | base64 -d > test-image.png

# View the generated image
xdg-open test-image.png  # Linux
# open test-image.png    # macOS
```

### Managing the Deployment

```bash
# Scale down (stop pods, preserve config)
kubectl scale deployment image-gen -n image-gen --replicas=0

# Scale up (restart pods)
kubectl scale deployment image-gen -n image-gen --replicas=2

# View logs
kubectl logs -n image-gen -l app=image-gen --tail=100 -f

# Full cleanup
./deploy.sh --delete
```

---

## Option 2: Standalone Docker Deployment

For single-node deployments or development environments.

### Step 1: Build the Docker Image

```bash
cd dgx-spark-toolkit/deployments/image-gen

docker build -t qwen-image-server:latest -f - . <<'EOF'
FROM nvcr.io/nvidia/pytorch:25.04-py3

WORKDIR /app

RUN pip install --no-cache-dir \
    fastapi \
    uvicorn \
    diffusers \
    transformers \
    accelerate \
    safetensors \
    pillow

COPY server.py /app/

EXPOSE 8000

CMD ["python", "server.py"]
EOF
```

### Step 2: Run the Container

```bash
docker run -d \
  --name qwen-image \
  --gpus all \
  --runtime nvidia \
  -p 8000:8000 \
  -v /data/models/image-gen:/root/.cache/huggingface \
  -e HF_TOKEN=$HF_TOKEN \
  -e MODEL_ID="Qwen/Qwen-Image-2512" \
  qwen-image-server:latest
```

### Step 3: Monitor Startup

```bash
# Watch logs (model download can take 10-15 minutes first time)
docker logs -f qwen-image

# Check container status
docker ps | grep qwen-image
```

---

## Option 3: Local Python Environment

For quick experiments without containerization.

### Step 1: Create Virtual Environment

```bash
cd dgx-spark-toolkit/comfyui-docker

# Create and activate virtual environment
python3 -m venv qwen-image-venv
source qwen-image-venv/bin/activate

# Install dependencies
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu121
pip install diffusers transformers accelerate gradio pillow
```

### Step 2: Run the Generation Script

```bash
# Interactive mode (single image)
python qwen-image-generate.py \
  --prompt "A futuristic cityscape at sunset, flying cars, neon lights" \
  --output my-image.png

# Web UI mode (Gradio interface)
python qwen-image-generate.py --server --port 7860
```

### Step 3: Access the Web UI

Open your browser to `http://localhost:7860`

---

## Using the Image Generation API

### API Reference

#### Health Check

```bash
GET /api/health
```

Response:
```json
{
  "status": "healthy",
  "model": "Qwen/Qwen-Image-2512",
  "device": "cuda"
}
```

#### Generate Image

```bash
POST /api/generate
Content-Type: application/json
```

Request body:
```json
{
  "prompt": "Your image description",
  "negative_prompt": "Things to avoid (optional)",
  "steps": 30,
  "guidance_scale": 7.5,
  "width": 1024,
  "height": 1024,
  "seed": 42
}
```

Response (JSON with base64-encoded image):
```json
{
  "success": true,
  "image_base64": "iVBORw0KGgoAAAANSUhEUgAA...",
  "format": "png"
}
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `prompt` | string | required | Text description of the image |
| `negative_prompt` | string | "" | What to avoid in the image |
| `steps` | int | 30 | More steps = higher quality, slower |
| `guidance_scale` | float | 7.5 | How closely to follow the prompt (1-20) |
| `width` | int | 1024 | Output width in pixels (max ~1536 on GB10) |
| `height` | int | 1024 | Output height in pixels (max ~1536 on GB10) |
| `seed` | int | random | Random seed for reproducibility |

### Python Client Example

```python
import requests
import base64
from io import BytesIO
from PIL import Image

def generate_image(prompt, width=1024, height=1024, steps=30, endpoint="http://192.168.86.210"):
    """Generate an image from a text prompt."""
    response = requests.post(
        f"{endpoint}/api/generate",
        json={
            "prompt": prompt,
            "negative_prompt": "blurry, low quality, distorted, watermark",
            "steps": steps,
            "guidance_scale": 7.5,
            "width": width,
            "height": height,
        },
        timeout=300  # 5 min timeout for large images
    )
    
    if response.status_code == 200:
        data = response.json()
        if data.get("success"):
            # Decode base64 image
            image_bytes = base64.b64decode(data["image_base64"])
            return Image.open(BytesIO(image_bytes))
        else:
            raise Exception(f"Generation failed: {data.get('error')}")
    else:
        raise Exception(f"Request failed: {response.text}")

# Usage
image = generate_image("A majestic eagle soaring over mountain peaks at dawn")
image.save("eagle.png")
print(f"Saved eagle.png ({image.size[0]}×{image.size[1]})")
```

### Batch Generation Script

```python
import requests
import base64
from concurrent.futures import ThreadPoolExecutor, as_completed

ENDPOINT = "http://192.168.86.210/api/generate"

prompts = [
    "A cozy cabin in snowy mountains",
    "An underwater coral reef with tropical fish",
    "A steampunk airship flying through clouds",
    "A mystical forest with glowing mushrooms",
]

def generate_and_save(prompt, index):
    """Generate image and save to file."""
    try:
        resp = requests.post(
            ENDPOINT,
            json={
                "prompt": prompt,
                "negative_prompt": "blurry, low quality, distorted",
                "steps": 25,
                "guidance_scale": 7.5,
                "width": 1024,
                "height": 1024,
            },
            timeout=300
        )
        
        if resp.status_code == 200:
            data = resp.json()
            if data.get("success"):
                image_bytes = base64.b64decode(data["image_base64"])
                filename = f"batch_image_{index:03d}.png"
                with open(filename, "wb") as f:
                    f.write(image_bytes)
                print(f"✓ Generated: {filename} - '{prompt[:30]}...'")
                return filename
    except Exception as e:
        print(f"✗ Error [{index}]: {e}")
    return None

# Generate images in parallel (2 workers = 2 pods)
print(f"Generating {len(prompts)} images...")
with ThreadPoolExecutor(max_workers=2) as executor:
    futures = {executor.submit(generate_and_save, p, i): i for i, p in enumerate(prompts)}
    results = [f.result() for f in as_completed(futures) if f.result()]

print(f"✅ Done! Generated {len(results)}/{len(prompts)} images")
```

---

## Integration with Cluster Control UI

The Cluster Control UI provides a web-based interface for image generation.

### Accessing the UI

1. Start the Cluster Control UI:
   ```bash
   cd dgx-spark-toolkit/cluster-control-ui
   python app.py
   ```

2. Open `http://your-head-node:5000` in your browser

3. Navigate to the **🎨 Image Gen** tab

### UI Features

- **Model Status**: View deployment status and health
- **Deploy/Delete**: One-click deployment management
- **Generate Interface**: Enter prompts and generate images
- **History**: View previously generated images

---

## Performance Tuning

### Benchmark Results on NVIDIA GB10 (DGX Spark)

Real-world performance data from testing on DGX Spark cluster with GB10 GPUs:

| Resolution | Steps | Time | Quality | Use Case |
|------------|-------|------|---------|----------|
| 512×512 | 10 | **~10s** | Preview | Quick iterations, drafts |
| 768×768 | 20 | **~38s** | Decent | Social media, thumbnails |
| 1024×1024 | 20 | **~69s** | Good | General purpose, balanced |
| 1024×1024 | 30 | **~99s** | High | Final renders |
| 1280×1280 | 25 | **~130s** | Very Good | Higher detail needed |
| 1536×1536 | 25 | **~190s** | Excellent | Max practical on GB10 |

> ⚠️ **Note**: 2512×2512 causes OOM on GB10 (128GB unified memory). For native 2512×2512, use A100/H100 GPUs with dedicated VRAM.

### Inference Speed Optimization

| Setting | Impact | Recommendation |
|---------|--------|----------------|
| `steps` | ↓ steps = ↑ speed, ↓ quality | 20-30 for balance |
| `guidance_scale` | Minimal impact | 7-8 typical |
| Resolution | ↓ resolution = ↑ speed | 1024×1024 recommended for GB10 |

### Memory Optimization

```python
# Enable attention slicing for lower VRAM usage
pipe.enable_attention_slicing()

# Enable VAE tiling for high-resolution outputs
pipe.enable_vae_tiling()

# Use float16 precision
pipe = pipeline.from_pretrained(model_id, torch_dtype=torch.float16)
```

### Caching Best Practices

1. **Pre-download models** before deployment:
   ```bash
   ./manage-cache.sh preload qwen-image-2512
   ```

2. **Sync cache across nodes**:
   ```bash
   ./manage-cache.sh sync
   ```

3. **Verify cache status**:
   ```bash
   ./manage-cache.sh list
   ```

---

## Troubleshooting

### Common Issues

#### Pod stuck in "ContainerCreating"

```bash
# Check events
kubectl describe pod -n image-gen <pod-name>

# Common causes:
# - GPU not available
# - Image pull issues
# - Volume mount problems
```

#### Out of Memory (OOM)

```bash
# Reduce batch size or resolution
# Enable memory optimizations in server.py
pipe.enable_attention_slicing()
```

#### Slow First Generation

The first generation is slow because:
1. Model needs to download (~15GB)
2. Model needs to load into GPU memory
3. CUDA kernels need to compile

**Solution**: Pre-cache the model:
```bash
./manage-cache.sh preload qwen-image-2512
```

#### Connection Refused

```bash
# Check if pods are running
kubectl get pods -n image-gen

# Check service endpoint
kubectl get svc -n image-gen

# Check logs for errors
kubectl logs -n image-gen -l app=image-gen
```

### Debug Commands

```bash
# Full diagnostic
./deploy.sh --status

# Pod shell access
kubectl exec -it -n image-gen <pod-name> -- /bin/bash

# GPU status inside pod
kubectl exec -n image-gen <pod-name> -- nvidia-smi
```

---

## Example Gallery

Below are example prompts and their generated images.

### Example 1: Nature Landscape

**Prompt:**
```
A breathtaking mountain landscape at golden hour, snow-capped peaks reflecting 
in a crystal-clear alpine lake, wildflowers in the foreground, dramatic clouds, 
professional photography, 8k resolution
```

**Parameters:**
- Steps: 30
- Guidance: 7.5
- Seed: 12345

**Generated Image:**

<!-- PLACEHOLDER: Insert generated image here -->
![Mountain Landscape](./images/example-mountain-landscape.png)

---

### Example 2: Sci-Fi Scene

**Prompt:**
```
A massive space station orbiting a gas giant planet, multiple rings, 
spacecraft docking, stars and nebula in background, cinematic lighting, 
concept art style, highly detailed
```

**Parameters:**
- Steps: 35
- Guidance: 8.0
- Seed: 67890

**Generated Image:**

<!-- PLACEHOLDER: Insert generated image here -->
![Space Station](./images/example-space-station.png)

---

### Example 3: Portrait

**Prompt:**
```
Portrait of an elegant woman with flowing silver hair, wearing ornate 
golden jewelry, soft studio lighting, shallow depth of field, 
Renaissance painting style, masterpiece quality
```

**Parameters:**
- Steps: 40
- Guidance: 7.0
- Seed: 11111

**Generated Image:**

<!-- PLACEHOLDER: Insert generated image here -->
![Portrait](./images/example-portrait.png)

---

### Example 4: Architecture

**Prompt:**
```
A futuristic eco-city with vertical gardens, solar panels integrated into 
glass buildings, suspended walkways, clean energy vehicles, blue sky, 
architectural visualization, photorealistic
```

**Parameters:**
- Steps: 30
- Guidance: 7.5
- Seed: 22222

**Generated Image:**

<!-- PLACEHOLDER: Insert generated image here -->
![Eco City](./images/example-eco-city.png)

---

### Example 5: Fantasy Art

**Prompt:**
```
An ancient dragon perched on a cliff overlooking a medieval kingdom, 
scales shimmering with iridescent colors, sunset sky, epic fantasy art, 
detailed scales and wings, dramatic composition
```

**Parameters:**
- Steps: 35
- Guidance: 8.5
- Seed: 33333

**Generated Image:**

<!-- PLACEHOLDER: Insert generated image here -->
![Dragon](./images/example-dragon.png)

---

## Prompt Engineering Tips

### Structure Your Prompts

```
[Subject] + [Style] + [Lighting] + [Composition] + [Quality modifiers]
```

### Effective Quality Modifiers

- `highly detailed`, `intricate details`
- `professional photography`, `8k resolution`
- `masterpiece`, `award-winning`
- `cinematic lighting`, `dramatic lighting`
- `sharp focus`, `bokeh background`

### Negative Prompts

Always include negative prompts to avoid common artifacts:

```
blurry, low quality, distorted, watermark, text, logo, signature, 
cropped, out of frame, duplicate, deformed, ugly, mutated
```

---

## Conclusion

You now have a fully operational Qwen-Image-2512 deployment on your DGX Spark cluster. Key takeaways:

1. **Use Kubernetes deployment** for production multi-user scenarios
2. **Pre-cache models** to minimize startup time
3. **Scale replicas** based on demand
4. **Tune inference steps** for speed vs. quality tradeoff

### Next Steps

- Explore other models (SDXL, FLUX.1) in `model-configs.yaml`
- Integrate with your applications via the REST API
- Set up monitoring and alerting for production use

---

## References

- [Qwen-Image Model Card](https://huggingface.co/Qwen/Qwen-Image-2512)
- [Diffusers Documentation](https://huggingface.co/docs/diffusers)
- [DGX Spark Toolkit Repository](https://github.com/dorangao/dgx-spark-toolkit)
- [Kubernetes GPU Scheduling](https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/)

---

*Last updated: January 2026*
