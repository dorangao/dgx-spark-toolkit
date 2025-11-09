#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# DGX Spark + nanochat: hardware/ports verification + speedrun launcher
# - Verifies the system matches DGX Spark specs you provided
# - Inventories rear-panel ports (10GbE RJ-45, ConnectX-7 QSFP, USB-C, HDMI, Wi-Fi 7)
# - Proceeds with nanochat tokenizer → pretrain → midtrain → SFT as in your script
# - Run-only verification: NANOCHAT_VERIFY_ONLY=1 bash speedrun.sh
# ==============================================================================

# ----------------------------- UI helpers -------------------------------------
log()  { printf "\033[1;36m[INFO]\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m[ OK ]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[FAIL]\033[0m %s\n" "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# ----------------------- DGX Spark verification block --------------------------
verify_dgx_spark() {
  log "Verifying DGX Spark feature set…"

  # Arch / CPU
  ARCH=$(uname -m || true)
  CPU_CORES=$(nproc 2>/dev/null || echo "")

  if [[ "${ARCH:-}" != "aarch64" ]]; then
    warn "Expected aarch64 (Arm64), detected: ${ARCH:-unknown}"
  else
    ok "Architecture: aarch64 (Arm64)"
  fi

  if have lscpu; then
    CPU_MODEL=$(lscpu | awk -F: '/Model name/{sub(/^ +/,"",$2);print $2}')
    if [[ "${CPU_CORES}" =~ ^[0-9]+$ ]] && [[ "${CPU_CORES}" -ge 20 ]]; then
      ok "CPU cores: ${CPU_CORES} (target ≈ 20)"
    else
      warn "CPU cores reported: ${CPU_CORES:-unknown} (target ≈ 20)"
    fi
    [[ -n "${CPU_MODEL}" ]] && ok "CPU model: ${CPU_MODEL}"
  else
    warn "lscpu not found; skipping CPU model/cores check."
  fi

  # Unified memory ~128 GB
  MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo "")
  if [[ -n "${MEM_KB}" ]]; then
    MEM_GB=$(( MEM_KB / 1024 / 1024 ))
    if [[ "${MEM_GB}" -ge 120 ]]; then
      ok "Unified system memory: ~${MEM_GB} GB (target 128 GB)"
    else
      warn "Unified memory low (~${MEM_GB} GB). Target is 128 GB."
    fi
  else
    warn "Could not read /proc/meminfo."
  fi

  # Storage inventory (NVMe 1 TB or 4 TB)
  if have lsblk; then
    log "NVMe storage devices:"
    lsblk -ndo NAME,SIZE,TYPE,MODEL | awk '{printf "  - %-12s %-8s %-6s %s\n",$1,$2,$3,$4}'
  else
    warn "lsblk not found; skipping NVMe inventory."
  fi

  # GPU / accelerator info
  if have nvidia-smi; then
    log "NVIDIA GPU inventory:"
    nvidia-smi --query-gpu=index,name,compute_cap,driver_version --format=csv,noheader || true
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || true)
    CCAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n1 || true)
    [[ -n "${GPU_NAME}" ]] && ok "GPU: ${GPU_NAME}"
    [[ -n "${CCAP}" ]] && ok "Compute capability: ${CCAP}"
  else
    warn "nvidia-smi not found; ensure NVIDIA stack is installed."
  fi

  # Network / I/O: RJ-45 10GbE, ConnectX-7 QSFP, Wi-Fi 7
  log "Network devices:"
  if have ip; then
    ip -o link show | awk -F': ' '{print "  - iface: "$2}'
  else
    warn "ip utility not found."
  fi

  # 10GbE / speed report
  if have ethtool; then
    for IF in $(ls /sys/class/net 2>/dev/null | grep -E '^(en|eth)'); do
      SPD=$(ethtool "$IF" 2>/dev/null | awk -F': ' '/Speed:/{print $2}')
      DRV=$(ethtool -i "$IF" 2>/dev/null | awk -F': ' '/driver:/{print $2}')
      [[ -n "${SPD}" ]] && printf "  - %s: speed=%s driver=%s\n" "$IF" "$SPD" "${DRV:-unknown}"
      if [[ "${SPD}" == 10*G* || "${SPD}" == 100*G* || "${SPD}" == 200*G* ]]; then
        ok "High-speed Ethernet detected on $IF (${SPD})."
      fi
    done
  else
    warn "ethtool not found; skipping link speed checks."
  fi

  # ConnectX-7 presence (QSFP ports)
  if have lspci; then
    if lspci | grep -qi 'ConnectX-7'; then
      ok "Mellanox/NVIDIA ConnectX-7 NIC detected (QSFP ports present)."
      lspci | grep -i 'Mellanox\|ConnectX-7' | sed 's/^/  - /'
    else
      warn "ConnectX-7 NIC not found via lspci; ensure NIC is present/visible."
    fi
  else
    warn "lspci not found; skipping NIC PCI scan."
  fi

  # Wi-Fi 7 / Bluetooth presence
  if have nmcli; then
    WIFI_STATE=$(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | grep -E ':wifi:' || true)
    if [[ -n "${WIFI_STATE}" ]]; then
      ok "Wi-Fi interface detected:"
      echo "  ${WIFI_STATE}"
    else
      warn "Wi-Fi interface not detected by NetworkManager."
    fi
  else
    warn "nmcli not found; skipping Wi-Fi check."
  fi

  if have lsusb; then
    BT_LINE=$(lsusb | grep -i bluetooth || true)
    [[ -n "${BT_LINE}" ]] && ok "Bluetooth device present: ${BT_LINE}" || warn "Bluetooth not visible via lsusb."
  fi

  # Rear-panel I/O sanity (observable subset)
  log "Rear-panel I/O (observable subset):"
  # USB-C ports count is not reliably detectable; list current USB devices
  if have lsusb; then
    echo "  USB devices:"
    lsusb | sed 's/^/    - /'
  else
    warn "lsusb not found; skipping USB inventory."
  fi
  # HDMI presence (if X/DRM available)
  if have modetest; then
    echo "  DRM connectors (for HDMI 2.1a check):"
    modetest -c | sed 's/^/    /' || true
  else
    warn "modetest not found; skipping DRM connector listing (HDMI)."
  fi

  ok "DGX Spark verification pass completed."
}

# Run verification first; allow verification-only mode
verify_dgx_spark
if [[ "${NANOCHAT_VERIFY_ONLY:-0}" == "1" ]]; then
  log "NANOCHAT_VERIFY_ONLY=1 set — exiting after verification."
  exit 0
fi

# ==============================================================================
# The original nanochat speedrun (with minimal fixes & guards)
# ==============================================================================

# Auto-launch inside GNU screen unless explicitly disabled
if [ -z "${STY:-}" ] && [ "${NANOCHAT_USE_SCREEN:-1}" -eq 1 ]; then
  if have screen; then
    SCREEN_SESSION=${NANOCHAT_SCREEN_SESSION:-speedrun}
    SCREEN_LOGFILE=${NANOCHAT_SCREEN_LOGFILE:-speedrun.log}
    if screen -ls | grep -q "[[:space:]]${SCREEN_SESSION}[[:space:]]"; then
      log "Found existing screen session '${SCREEN_SESSION}', continuing."
    else
      log "Launching inside screen session '${SCREEN_SESSION}' (log: ${SCREEN_LOGFILE})."
      exec screen -L -Logfile "${SCREEN_LOGFILE}" -S "${SCREEN_SESSION}" bash "$0" "$@"
    fi
  else
    warn "screen not found; continuing in foreground."
  fi
fi

export OMP_NUM_THREADS=1
# Fix minor typo: use nanochat (not nonochat)
export NANOCHAT_BASE_DIR="${NANOCHAT_BASE_DIR:-$HOME/.cache/nanochat}"
mkdir -p "$NANOCHAT_BASE_DIR"

# ----------------------------- Python venv (uv) -------------------------------
# install uv if missing
if ! have uv; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
# create and activate venv
[ -d ".venv" ] || uv venv
# shellcheck source=/dev/null
source .venv/bin/activate

ARCH=$(uname -m)
MATURIN_CMD=(uv run maturin)

if [ "$ARCH" = "aarch64" ]; then
  log "Detected aarch64; installing Torch stack for CUDA-enabled Arm."
  python -m ensurepip --upgrade
  python -m pip install --upgrade pip setuptools wheel
  TORCH_REQ=${NANOCHAT_AARCH64_REQUIREMENTS:-requirements-aarch64.txt}
  if [ ! -f "$TORCH_REQ" ]; then
    err "Missing $TORCH_REQ; set NANOCHAT_AARCH64_REQUIREMENTS or provide this file."
    exit 1
  fi
  python -m pip install -r "$TORCH_REQ"

  # Validate Torch + CUDA
  if python - <<'PY'
import sys, torch
sys.exit(0 if torch.cuda.is_available() else 1)
PY
then
    ok "PyTorch with CUDA detected on aarch64."
  else
    if [ -n "${NANOCHAT_TORCH_WHEEL:-}" ]; then
      log "Installing PyTorch from wheel: $NANOCHAT_TORCH_WHEEL"
      python -m pip install --no-cache-dir "$NANOCHAT_TORCH_WHEEL"
    else
      TORCH_SPEC=${NANOCHAT_TORCH_SPEC:-torch==2.5.1}
      TORCH_INDEX=${NANOCHAT_TORCH_INDEX:-}
      EXTRA=()
      [ -n "$TORCH_INDEX" ] && EXTRA=(--extra-index-url "$TORCH_INDEX")
      log "Installing PyTorch ($TORCH_SPEC) ${TORCH_INDEX:+from $TORCH_INDEX}…"
      python -m pip install --no-cache-dir "${EXTRA[@]}" "$TORCH_SPEC"
    fi
    if ! python - <<'PY' >/dev/null 2>&1
import sys, torch
sys.exit(0 if torch.cuda.is_available() else 1)
PY
    then
      err "Torch installed but CUDA unavailable on aarch64. Provide CUDA-enabled wheel/index."
      exit 1
    fi
  fi
  MATURIN_CMD=(maturin)
else
  # x86_64 path
  uv sync
  if ! uv run python -c "import torch" >/dev/null 2>&1; then
    err "uv sync completed but torch import failed."
    exit 1
  fi
  if ! uv run python - <<'PY' >/dev/null 2>&1
import sys, torch
sys.exit(0 if torch.cuda.is_available() else 1)
PY
then
    err "Torch found but CUDA unavailable; check driver/toolkit."
    exit 1
  fi
fi

# ---------------------------- GPU count export --------------------------------
if [ -n "${NANOCHAT_NUM_GPUS:-}" ]; then
  NUM_GPUS=$NANOCHAT_NUM_GPUS
elif have nvidia-smi; then
  NUM_GPUS=$(nvidia-smi -L 2>/dev/null | wc -l | tr -d ' ') || NUM_GPUS=1
  [ -z "$NUM_GPUS" ] && NUM_GPUS=1
else
  NUM_GPUS=1
fi
export NANOCHAT_NUM_GPUS=$NUM_GPUS
export NUM_GPUS
ok "Using NUM_GPUS=${NUM_GPUS}"

# ------------------------------- W&B logging ----------------------------------
if [ -z "${WANDB_RUN:-}" ]; then
  export WANDB_RUN=dummy
fi

# ------------------------------- Reporting ------------------------------------
python -m nanochat.report reset

# ------------------------------- Tokenizer ------------------------------------
# Rust / Cargo for rustbpe
if ! have cargo; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  # shellcheck source=/dev/null
  source "$HOME/.cargo/env"
fi

"${MATURIN_CMD[@]}" develop --release --manifest-path rustbpe/Cargo.toml

# Dataset shards
python -m nanochat.dataset -n 8
python -m nanochat.dataset -n 240 &
DATASET_DOWNLOAD_PID=$!

python -m scripts.tok_train --max_chars=2000000000
python -m scripts.tok_eval

# ------------------------------ Pretraining -----------------------------------
EVAL_BUNDLE_URL=https://karpathy-public.s3.us-west-2.amazonaws.com/eval_bundle.zip
if [ ! -d "$NANOCHAT_BASE_DIR/eval_bundle" ]; then
  curl -L -o eval_bundle.zip "$EVAL_BUNDLE_URL"
  unzip -q eval_bundle.zip
  rm -f eval_bundle.zip
  mv eval_bundle "$NANOCHAT_BASE_DIR"
fi

log "Waiting for background dataset download to complete…"
wait $DATASET_DOWNLOAD_PID || true

torchrun --standalone --nproc_per_node="$NUM_GPUS" -m scripts.base_train -- --depth=20 --run="$WANDB_RUN"
torchrun --standalone --nproc_per_node="$NUM_GPUS" -m scripts.base_loss
torchrun --standalone --nproc_per_node="$NUM_GPUS" -m scripts.base_eval

# ------------------------------ Midtraining -----------------------------------
torchrun --standalone --nproc_per_node="$NUM_GPUS" -m scripts.mid_train -- --run="$WANDB_RUN"
torchrun --standalone --nproc_per_node="$NUM_GPUS" -m scripts.chat_eval -- -i mid

# --------------------------- Supervised Finetune -------------------------------
torchrun --standalone --nproc_per_node="$NUM_GPUS" -m scripts.chat_sft -- --run="$WANDB_RUN"
torchrun --standalone --nproc_per_node="$NUM_GPUS" -m scripts.chat_eval -- -i sft

# (Optional) RL stage (kept commented, as in your script)
# torchrun --standalone --nproc_per_node="$NUM_GPUS" -m scripts.chat_rl -- --run="$WANDB_RUN"
# torchrun --standalone --nproc_per_node="$NUM_GPUS" -m scripts.chat_eval -- -i rl -a GSM8K

# ------------------------------- Final report ---------------------------------
python -m nanochat.report generate

ok "Run complete. For interactive chat:"
echo "  python -m scripts.chat_cli"
echo "  # or Web UI:"
echo "  python -m scripts.chat_web"
