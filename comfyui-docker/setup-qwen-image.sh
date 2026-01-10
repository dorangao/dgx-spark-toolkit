#!/usr/bin/env bash
set -euo pipefail

# Setup script for Qwen-Image-2512 in ComfyUI
# Run this AFTER starting ComfyUI with run-comfyui.sh

BASE_DIR="${BASE_DIR:-$HOME/comfyui-data}"
CUSTOM_DIR="$BASE_DIR/custom_nodes"
MODELS_DIR="$BASE_DIR/models"

log(){ printf "\033[1;36m[qwen-image]\033[0m %s\n" "$*"; }
err(){ printf "\033[1;31m[qwen-image]\033[0m %s\n" "$*" >&2; }

# Create directories
mkdir -p "$CUSTOM_DIR" "$MODELS_DIR/diffusion_models" "$MODELS_DIR/text_encoders" "$MODELS_DIR/vae"

log "Installing ComfyUI-QwenVL custom nodes..."
cd "$CUSTOM_DIR"

# Clone custom nodes for Qwen models (if not already present)
if [ ! -d "ComfyUI-QwenVL" ]; then
    git clone https://github.com/ZHO-ZHO-ZHO/ComfyUI-Qwen-VL.git ComfyUI-QwenVL 2>/dev/null || \
    git clone https://github.com/kijai/ComfyUI-KJNodes.git ComfyUI-KJNodes 2>/dev/null || \
    log "Note: May need manual custom node installation"
fi

log ""
log "=============================================="
log "Qwen-Image-2512 Setup Instructions"
log "=============================================="
log ""
log "The Qwen-Image-2512 model uses a custom pipeline that"
log "may require additional setup in ComfyUI."
log ""
log "Option 1: Use HuggingFace Diffusers directly (recommended)"
log "  pip install diffusers transformers accelerate"
log "  See: https://huggingface.co/Qwen/Qwen-Image-2512"
log ""
log "Option 2: ComfyUI with custom workflow"
log "  1. Start ComfyUI: ./run-comfyui.sh"
log "  2. Open http://localhost:13000"
log "  3. Install ComfyUI-Manager from the Manager menu"
log "  4. Search for 'Qwen' nodes and install"
log ""
log "Model files will be downloaded automatically when first used."
log "=============================================="
