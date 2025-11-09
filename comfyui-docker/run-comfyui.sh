#!/usr/bin/env bash
set -euo pipefail

# ===== Config (override via env) =====
NAME="${NAME:-comfyui}"
IMAGE="${IMAGE:-comfyui:arm64}"      # your locally-built arm64 image
HOST_PORT="${HOST_PORT:-13000}"      # public port on Spark
GPU_FLAG="${GPU_FLAG:---gpus all}"   # "" if no GPU (not typical on Spark)
BASE_DIR="${BASE_DIR:-$HOME/comfyui-data}"

MODELS_DIR="$BASE_DIR/models"
CUSTOM_DIR="$BASE_DIR/custom_nodes"
INPUT_DIR="$BASE_DIR/input"
OUTPUT_DIR="$BASE_DIR/output"

# Built-in models (add more here or via EXTRA_MODELS env)
MODELS=(
  "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors | text_encoders    | umt5_xxl_fp8_e4m3fn_scaled.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan2.2_vae.safetensors                                   | vae              | wan2.2_vae.safetensors"
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_fun_inpaint_5B_bf16.safetensors     | diffusion_models | wan2.2_fun_inpaint_5B_bf16.safetensors"
  "https://huggingface.co/duongve/NetaYume-Lumina-Image-2.0/resolve/main/NetaYumev35_pretrained_all_in_one.safetensors                              | checkpoints      | NetaYumev35_pretrained_all_in_one.safetensors"
)
# Append newline-separated entries in the same "URL | subfolder | filename" format
# export EXTRA_MODELS=$'https://.../file.safetensors | checkpoints | file.safetensors\nhttps://... | loras | my.safetensors'
if [ "${EXTRA_MODELS:-}" != "" ]; then
  # shellcheck disable=SC2206
  MODELS+=($(printf '%s\n' "$EXTRA_MODELS"))
fi
# ====================================

log(){ printf "\033[1;36m[comfyui]\033[0m %s\n" "$*"; }
err(){ printf "\033[1;31m[comfyui]\033[0m %s\n" "$*" >&2; }

command -v docker >/dev/null || { err "Docker not found"; exit 1; }
docker info >/dev/null 2>&1 || { err "Docker daemon not reachable"; exit 1; }
command -v curl >/dev/null || { err "curl not found (sudo apt-get install -y curl)"; exit 1; }

# Create host dirs
mkdir -p \
  "$MODELS_DIR/text_encoders" \
  "$MODELS_DIR/vae" \
  "$MODELS_DIR/diffusion_models" \
  "$MODELS_DIR/checkpoints" \
  "$CUSTOM_DIR" "$INPUT_DIR" "$OUTPUT_DIR"

# Downloader (idempotent, resume)
fetch() {
  local url="$1" sub="$2" file="$3"
  local dst="$MODELS_DIR/$sub/$file"
  mkdir -p "$(dirname "$dst")"
  if [ -f "$dst" ]; then
    log "✓ exists: $sub/$file"
  else
    log "→ downloading: $file → $sub/"
    curl -L --fail --retry 5 --retry-delay 3 --continue-at - "$url" -o "$dst"
    log "✓ saved: $sub/$file"
  fi
}

# Grab all models
for entry in "${MODELS[@]}"; do
  IFS='|' read -r URL SUB FILE <<<"$(echo "$entry")"
  URL="$(echo "$URL" | xargs)"; SUB="$(echo "$SUB" | xargs)"; FILE="$(echo "$FILE" | xargs)"
  fetch "$URL" "$SUB" "$FILE"
done

# If container is already running, keep it and just print the URL
if docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
  log "$NAME already running."
else
  # If requested port is already in use, assume it's OK (Sync/local binding etc.)
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${HOST_PORT}$"; then
    log "Port ${HOST_PORT} already in use — assuming existing tunnel/binding; continuing."
  fi

  if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
    log "Starting existing container $NAME..."
    docker start "$NAME" >/dev/null
  else
    log "Creating container $NAME on port $HOST_PORT..."
    docker run -d --name "$NAME" --restart=unless-stopped \
      $GPU_FLAG \
      -p ${HOST_PORT}:8188 \
      -e CLI_ARGS="--listen 0.0.0.0 --port 8188" \
      -v "$MODELS_DIR:/workspace/ComfyUI/models" \
      -v "$CUSTOM_DIR:/workspace/ComfyUI/custom_nodes" \
      -v "$INPUT_DIR:/workspace/ComfyUI/input" \
      -v "$OUTPUT_DIR:/workspace/ComfyUI/output" \
      "$IMAGE" >/dev/null
  fi
fi

# Wait until reachable
for i in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:${HOST_PORT}" >/dev/null 2>&1; then
    log "ComfyUI is up: http://localhost:${HOST_PORT}"
    break
  fi
  sleep 1
done

log "------------------------------------------------------------------"
log "Open:   http://localhost:${HOST_PORT}"
log "Models: $MODELS_DIR"
log "Custom: $CUSTOM_DIR"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | sed 's/^/[comfyui] /'
log "------------------------------------------------------------------"
