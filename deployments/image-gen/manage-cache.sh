#!/bin/bash
#
# Model Cache Management Script
# Pre-downloads models to local cache on cluster nodes
#
# Usage:
#   ./manage-cache.sh download qwen-image-2512
#   ./manage-cache.sh download-all
#   ./manage-cache.sh list
#   ./manage-cache.sh clear MODEL
#

set -e

CACHE_DIR="/data/models/image-gen/huggingface"
NODES=("dgx-spark-1" "dgx-spark-2")

# Model definitions
declare -A MODELS
MODELS["qwen-image-2512"]="Qwen/Qwen-Image-2512"
MODELS["stable-diffusion-xl"]="stabilityai/stable-diffusion-xl-base-1.0"
MODELS["flux-schnell"]="black-forest-labs/FLUX.1-schnell"

log_info() { echo -e "\033[0;34m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[0;32m[SUCCESS]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

download_model() {
    local model="$1"
    local repo="${MODELS[$model]}"
    
    if [[ -z "$repo" ]]; then
        log_error "Unknown model: $model"
        echo "Available models: ${!MODELS[*]}"
        exit 1
    fi
    
    log_info "Downloading $model ($repo) to cache..."
    
    for node in "${NODES[@]}"; do
        log_info "Downloading on $node..."
        
        ssh "$node" << EOF
mkdir -p $CACHE_DIR
docker run --rm \
    -v $CACHE_DIR:/cache \
    -e HF_HOME=/cache \
    ${HF_TOKEN:+-e HF_TOKEN=$HF_TOKEN} \
    python:3.11-slim \
    bash -c "
        pip install -q huggingface_hub
        python -c \"
from huggingface_hub import snapshot_download
import os
os.environ['HF_HOME'] = '/cache'
print('Downloading $repo...')
snapshot_download('$repo', cache_dir='/cache')
print('Done!')
\"
    "
EOF
    done
    
    log_success "Model $model downloaded to all nodes"
}

download_all() {
    log_info "Downloading all models to cache..."
    for model in "${!MODELS[@]}"; do
        download_model "$model"
    done
    log_success "All models downloaded"
}

list_cache() {
    log_info "Cache contents:"
    
    for node in "${NODES[@]}"; do
        echo ""
        echo "=== $node ==="
        ssh "$node" "du -sh $CACHE_DIR/models--* 2>/dev/null || echo 'No models cached'"
    done
}

clear_cache() {
    local model="$1"
    
    if [[ -z "$model" ]]; then
        log_error "Specify model to clear"
        exit 1
    fi
    
    local repo="${MODELS[$model]}"
    local cache_name="models--${repo//\//-}"
    
    log_info "Clearing cache for $model..."
    
    for node in "${NODES[@]}"; do
        log_info "Clearing on $node..."
        ssh "$node" "rm -rf $CACHE_DIR/$cache_name"
    done
    
    log_success "Cache cleared for $model"
}

show_help() {
    cat << EOF
Model Cache Management

Usage: $0 COMMAND [MODEL]

Commands:
  download MODEL    Download specific model to all nodes
  download-all      Download all models
  list              List cached models
  clear MODEL       Clear cache for specific model

Models:
EOF
    for model in "${!MODELS[@]}"; do
        echo "  $model -> ${MODELS[$model]}"
    done
}

case "${1:-help}" in
    download)
        download_model "$2"
        ;;
    download-all)
        download_all
        ;;
    list)
        list_cache
        ;;
    clear)
        clear_cache "$2"
        ;;
    *)
        show_help
        ;;
esac
