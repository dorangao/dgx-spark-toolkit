#!/usr/bin/env bash
set -euo pipefail

# ==== adjust if your names differ ====
IFACES=("enp1s0f0np0" "enP2p1s0f0np0")
RDMA_DEVS=("rocep1s0f0" "roceP2p1s0f0")
PORT=1
# =====================================

echo "== NIC status =="
for ifc in "${IFACES[@]}"; do
  [[ -d "/sys/class/net/$ifc" ]] || { echo "skip $ifc (not present)"; continue; }
  ip -br addr show "$ifc" || true
  echo -n "MTU($ifc): "; cat "/sys/class/net/$ifc/mtu" || true
  sudo ethtool "$ifc" | awk '/Speed:|Duplex:|Link detected:/'
  echo
done

echo "== RDMA/RoCE status =="
for dev in "${RDMA_DEVS[@]}"; do
  [[ -d "/sys/class/infiniband/$dev/ports/$PORT" ]] || { echo "skip $dev (no port $PORT)"; continue; }
  echo "-- $dev --"
  echo -n "state:        "; sudo cat "/sys/class/infiniband/$dev/ports/$PORT/state" || true
  echo -n "active_mtu:   "; sudo cat "/sys/class/infiniband/$dev/ports/$PORT/active_mtu" || true
  if [[ -f "/sys/class/infiniband/$dev/ports/$PORT/gid_attrs/roce_version" ]]; then
    echo -n "roce_version: "; sudo cat "/sys/class/infiniband/$dev/ports/$PORT/gid_attrs/roce_version"
  fi
  echo "GIDs:"
  if [[ -d "/sys/class/infiniband/$dev/ports/$PORT/gids" ]]; then
    for i in $(seq 0 7); do
      printf "  %2d: " "$i"
      sudo cat "/sys/class/infiniband/$dev/ports/$PORT/gids/$i" 2>/dev/null || echo "-"
    done
  fi
  echo
done

echo "== Quick connectivity =="
# replace peer IP with the other node's 200G IP
PEER="${1:-}"
if [[ -n "$PEER" ]]; then
  ping -c2 -I "${IFACES[0]}" "$PEER" || true
  command -v iperf3 >/dev/null && echo "Tip: iperf3 -s (on peer) / iperf3 -c $PEER -P 8 -t 10"
fi
