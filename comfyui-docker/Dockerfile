FROM nvcr.io/nvidia/pytorch:25.04-py3

# basics
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates && rm -rf /var/lib/apt/lists/*

# ComfyUI source - v0.9.1
WORKDIR /workspace
RUN git clone --branch v0.9.1 --depth 1 https://github.com/comfyanonymous/ComfyUI.git
WORKDIR /workspace/ComfyUI

# Python deps - use pre-installed torch/torchvision, skip conflicts
# Filter out torch packages since they're pre-installed in the base image
RUN pip install --upgrade pip \
 && grep -vE '^torch' requirements.txt > /tmp/requirements-filtered.txt \
 && pip install --no-deps -r /tmp/requirements-filtered.txt \
 && pip install einops transformers safetensors aiohttp pyyaml pillow scipy \
        kornia spandrel soundfile sentencepiece huggingface_hub tokenizers \
        mako torchsde alembic sqlalchemy python-dotenv pydantic-settings \
        comfyui-workflow-templates comfyui-frontend-package \
 && pip install --no-deps torchaudio==2.7.0 \
 && pip install "numpy<2"

EXPOSE 8188
CMD ["python", "main.py", "--listen", "0.0.0.0", "--port", "8188"]
