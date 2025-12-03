#!/usr/bin/env bash
set -euo pipefail

load_network_overrides() {
    local -a candidates=()
    [[ -n "${DGX_SPARK_NETWORK_CONFIG:-}" ]] && candidates+=("$DGX_SPARK_NETWORK_CONFIG")
    candidates+=("$HOME/.config/dgx-spark-toolkit/network.env" "$HOME/.dgx-spark-network" "$HOME/dgx-spark-network.env")
    for cfg in "${candidates[@]}"; do
        [[ -f "$cfg" ]] || continue
        # shellcheck disable=SC1090
        source "$cfg"
    done
}
load_network_overrides

# ==== cluster + env (edit if needed) ====
FABRIC_CTRL_IP="${FABRIC_CTRL_IP:-${CONTROL_PLANE_FABRIC_IP:-10.10.10.1}}"
FABRIC_WORKER_IP="${FABRIC_WORKER_IP:-${WORKER_NODE_IP:-10.10.10.2}}"
LAUNCHER_LOCAL_IP="${LAUNCHER_LOCAL_IP:-$FABRIC_CTRL_IP}"     # spark-2959 fabric NIC
HOSTS="${HOSTS:-${LAUNCHER_LOCAL_IP}:1,${FABRIC_WORKER_IP}:1}"   # one GPU per node
IFACES="${IFACES:-enp1s0f0np0,enP2p1s0f0np0}"                  # dual functions on same port
HCAS="${HCAS:-rocep1s0f0,roceP2p1s0f0}"
GID_INDEX="${GID_INDEX:-2}"
BINARY="${BINARY:-$HOME/workspace/nccl-tests/build/all_reduce_perf}"
MIN_BYTES="${MIN_BYTES:-64M}"
MAX_BYTES="${MAX_BYTES:-512M}"
GPUS_PER_NODE="${GPUS_PER_NODE:-1}"
# ========================================

# Ensure jumbo MTU (optional safety)
for ifc in ${IFACES//,/ }; do
  sudo ip link set "$ifc" mtu 9000 up || true
done

# NCCL env
export NCCL_SOCKET_IFNAME="$IFACES"
export NCCL_IB_HCA="$HCAS"
export NCCL_IB_GID_INDEX="$GID_INDEX"
export NCCL_CROSS_NIC=1
export NCCL_IB_MERGE_NICS=1
export NCCL_MIN_NCHANNELS=64
export NCCL_IB_QPS_PER_CONNECTION=8
export NCCL_NSOCKS_PERTHREAD=8
export NCCL_SOCKET_NTHREADS=8
export NCCL_DEBUG=INFO
# If you later load nvidia_peermem: export NCCL_NET_GDR_LEVEL=2

echo "Running NCCL all_reduce with:"
echo "  IFACES=$NCCL_SOCKET_IFNAME"
echo "  HCAS=$NCCL_IB_HCA  GID_INDEX=$NCCL_IB_GID_INDEX"
echo "  HOSTS=$HOSTS  BIN=$BINARY"
echo

mpirun -np 2 -H "$HOSTS" \
  --mca btl tcp,self \
  --mca btl_tcp_if_include "$(echo $IFACES | cut -d, -f1)" \
  --mca oob_tcp_if_include "$(echo $IFACES | cut -d, -f1)" \
  --mca plm_rsh_agent "ssh -o BindAddress=$LAUNCHER_LOCAL_IP -l $USER" \
  -x NCCL_SOCKET_IFNAME -x NCCL_IB_HCA -x NCCL_IB_GID_INDEX -x NCCL_DEBUG \
  -x NCCL_MIN_NCHANNELS -x NCCL_IB_QPS_PER_CONNECTION \
  -x NCCL_NSOCKS_PERTHREAD -x NCCL_SOCKET_NTHREADS \
  "$BINARY" -b "$MIN_BYTES" -e "$MAX_BYTES" -f 2 -g "$GPUS_PER_NODE"
