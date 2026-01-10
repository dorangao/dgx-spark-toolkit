#!/usr/bin/env bash
set -euo pipefail

# Manage vLLM model cache on DGX Spark nodes
# Models are cached at /var/lib/vllm-models on each node

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="/var/lib/vllm-models"
WORKER_HOST="${WORKER_HOST:-spark-ba63}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

usage() {
    cat << EOF
Usage: $(basename "$0") [COMMAND] [OPTIONS]

Manage vLLM model cache on DGX Spark nodes.
Models are cached at: $CACHE_DIR

Commands:
    status              Show cache status on both nodes
    list                List cached models
    preload MODEL       Pre-download a model (runs on head node)
    sync                Sync cache from head to worker node
    clear               Clear cache on both nodes
    size                Show cache size on both nodes

Options:
    --model MODEL       Model to preload (HuggingFace ID)
    -h, --help          Show this help

Examples:
    # Check cache status
    ./manage-cache.sh status

    # Pre-download Nemotron
    ./manage-cache.sh preload nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16

    # Sync cache to worker (after preloading)
    ./manage-cache.sh sync

    # List cached models
    ./manage-cache.sh list

Environment:
    HF_TOKEN            HuggingFace token (required for some models)
    WORKER_HOST         Worker node hostname (default: spark-ba63)
EOF
}

check_cache_status() {
    log_step "Checking cache status..."
    
    echo -e "\n${BLUE}=== Head Node ($(hostname)) ===${NC}"
    if [[ -d "$CACHE_DIR" ]]; then
        local size=$(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1 || echo "unknown")
        echo "Cache directory: $CACHE_DIR"
        echo "Total size: $size"
        
        if [[ -d "$CACHE_DIR/.cache/hub" ]]; then
            local models=$(ls -1 "$CACHE_DIR/.cache/hub/models--"* 2>/dev/null | wc -l || echo "0")
            echo "Cached models: $models"
        else
            echo "HuggingFace cache: Not initialized"
        fi
    else
        echo "Cache directory does not exist yet."
    fi
    
    echo -e "\n${BLUE}=== Worker Node ($WORKER_HOST) ===${NC}"
    if ssh -o ConnectTimeout=5 "$WORKER_HOST" "test -d $CACHE_DIR" 2>/dev/null; then
        local size=$(ssh "$WORKER_HOST" "du -sh $CACHE_DIR 2>/dev/null | cut -f1" || echo "unknown")
        echo "Cache directory: $CACHE_DIR"
        echo "Total size: $size"
        
        local models=$(ssh "$WORKER_HOST" "ls -1 $CACHE_DIR/.cache/hub/models--* 2>/dev/null | wc -l" || echo "0")
        echo "Cached models: $models"
    else
        echo "Cache directory does not exist or worker unreachable."
    fi
}

list_cached_models() {
    log_step "Listing cached models..."
    
    echo -e "\n${BLUE}=== Head Node ===${NC}"
    if [[ -d "$CACHE_DIR/.cache/hub" ]]; then
        for dir in "$CACHE_DIR/.cache/hub"/models--*; do
            if [[ -d "$dir" ]]; then
                local model=$(basename "$dir" | sed 's/models--//' | sed 's/--/\//g')
                local size=$(du -sh "$dir" 2>/dev/null | cut -f1 || echo "?")
                echo "  $model ($size)"
            fi
        done
    else
        echo "  No models cached"
    fi
    
    echo -e "\n${BLUE}=== Worker Node ===${NC}"
    if ssh -o ConnectTimeout=5 "$WORKER_HOST" "test -d $CACHE_DIR/.cache/hub" 2>/dev/null; then
        ssh "$WORKER_HOST" "for dir in $CACHE_DIR/.cache/hub/models--*; do
            if [ -d \"\$dir\" ]; then
                model=\$(basename \"\$dir\" | sed 's/models--//' | sed 's/--/\\\//g')
                size=\$(du -sh \"\$dir\" 2>/dev/null | cut -f1 || echo '?')
                echo \"  \$model (\$size)\"
            fi
        done" || echo "  No models cached"
    else
        echo "  Worker unreachable or no cache"
    fi
}

preload_model() {
    local model="$1"
    
    if [[ -z "$model" ]]; then
        log_error "No model specified"
        usage
        exit 1
    fi
    
    log_step "Pre-downloading model: $model"
    
    # Check HF_TOKEN
    if [[ -z "${HF_TOKEN:-}" ]]; then
        log_warn "HF_TOKEN not set. Some models may require authentication."
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # Ensure cache directory exists
    sudo mkdir -p "$CACHE_DIR"
    sudo chmod 755 "$CACHE_DIR"
    
    # Download using huggingface-cli or Python
    log_info "Downloading to $CACHE_DIR..."
    
    if command -v huggingface-cli &> /dev/null; then
        HF_HOME="$CACHE_DIR/.cache" huggingface-cli download "$model" \
            --local-dir "$CACHE_DIR/downloads/$model" \
            --local-dir-use-symlinks True \
            ${HF_TOKEN:+--token "$HF_TOKEN"}
    else
        # Fallback to Python
        python3 << EOF
import os
os.environ['HF_HOME'] = '$CACHE_DIR/.cache'
os.environ['TRANSFORMERS_CACHE'] = '$CACHE_DIR/.cache'
os.environ['HF_HUB_CACHE'] = '$CACHE_DIR/.cache/hub'
${HF_TOKEN:+os.environ['HF_TOKEN'] = '$HF_TOKEN'}

from huggingface_hub import snapshot_download
print(f"Downloading $model...")
snapshot_download("$model", local_dir_use_symlinks=True)
print("Download complete!")
EOF
    fi
    
    log_info "Model downloaded successfully!"
    echo ""
    log_info "To cache on worker node, run: ./manage-cache.sh sync"
}

sync_cache() {
    log_step "Syncing cache from head to worker..."
    
    if [[ ! -d "$CACHE_DIR" ]]; then
        log_error "Cache directory doesn't exist on head node"
        exit 1
    fi
    
    local size=$(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1 || echo "unknown")
    log_info "Syncing $size to $WORKER_HOST..."
    
    # Ensure directory exists on worker
    ssh "$WORKER_HOST" "sudo mkdir -p $CACHE_DIR && sudo chmod 755 $CACHE_DIR"
    
    # Sync using rsync
    rsync -avz --progress "$CACHE_DIR/" "$WORKER_HOST:$CACHE_DIR/"
    
    log_info "Sync complete!"
}

clear_cache() {
    log_warn "This will delete ALL cached models on BOTH nodes!"
    read -p "Are you sure? [y/N] " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Cancelled."
        exit 0
    fi
    
    log_step "Clearing cache on head node..."
    sudo rm -rf "$CACHE_DIR"/*
    
    log_step "Clearing cache on worker node..."
    ssh "$WORKER_HOST" "sudo rm -rf $CACHE_DIR/*" || log_warn "Worker clear failed (may be offline)"
    
    log_info "Cache cleared!"
}

show_size() {
    log_step "Cache sizes..."
    
    echo -e "\n${BLUE}Head Node:${NC}"
    du -sh "$CACHE_DIR" 2>/dev/null || echo "  Cache not initialized"
    
    echo -e "\n${BLUE}Worker Node:${NC}"
    ssh "$WORKER_HOST" "du -sh $CACHE_DIR 2>/dev/null" || echo "  Cache not initialized or unreachable"
}

# Parse command
COMMAND="${1:-status}"
shift || true

case "$COMMAND" in
    status)
        check_cache_status
        ;;
    list)
        list_cached_models
        ;;
    preload)
        preload_model "${1:-}"
        ;;
    sync)
        sync_cache
        ;;
    clear)
        clear_cache
        ;;
    size)
        show_size
        ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        log_error "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
