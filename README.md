# DGX Spark Toolkit

Curated repo that collects all of the ad-hoc scripts we put together while validating DGX Spark hardware, networking, and app stacks. Everything lives in one place so you can clone/push and share with the rest of the team.

## Layout

| Path | Purpose |
| ---- | ------- |
| `scripts/check_roce.sh` | Quick RoCE/NIC sanity: MTU, link speed, RDMA GIDs, and optional ping/iperf hints. Edit the interface arrays at the top for your nodes. |
| `scripts/run_nccl_200g.sh` | Wrapper around NCCL tests tuned for the dual 200 GbE setup. Update the host/IP variables at the top before running. |
| `projects/nanochat/speedrun.sh` | Full DGX Spark verification + nanochat speedrun pipeline (tokenizer → pretrain → midtrain → SFT). Supports verification-only mode and screen sessions. |
| `deployments/*.yaml` | K8s pods for GPU smoke, RDMA capability checks, and rdma-bw client/server runs (with helper ConfigMap script). |
| `stacks/openwebui/*` | Docker Compose stack (Ollama + Open WebUI + gateway) plus `run-stack.sh` helper and the templated nginx config. |
| `comfyui-docker/*` | ComfyUI Docker setup with auto-download helper. `Dockerfile` builds from NVIDIA PyTorch base; `run-comfyui.sh` pulls models from HuggingFace and launches GPU-enabled container. |

## Getting Started

```bash
cd dgx-spark-toolkit
python3 -m venv .venv && source .venv/bin/activate  # optional, for helper tools
```

Everything is plain bash/yaml, so no build step is required. Make sure scripts are executable:

```bash
chmod +x scripts/*.sh projects/nanochat/speedrun.sh stacks/openwebui/run-stack.sh comfyui-docker/run-comfyui.sh
```

## Highlights & Notes

- **check_roce.sh** prints NIC/RDMA status via sysfs + `ethtool`; pass the peer IP as `$1` to add a quick ping.
- **run_nccl_200g.sh** exports all NCCL knobs (cross-NIC, QPs, channels, sockets) before launching `mpirun`. Edit the `HOSTS`, `IFACES`, `HCAS`, and binary path for your cluster.
- **deployments/rdma-bw.yaml** carries both server/client pods plus the ConfigMap with retry-friendly `run.sh`. Toggle `INSTALL_DEPS` env on the client if you already baked perftest into the image.
- **stacks/openwebui/run-stack.sh** bootstraps the compose stack, optionally pre-pulls Ollama models, waits for readiness, and pings the nginx gateway w/ bearer validation.
- **comfyui-docker/run-comfyui.sh** downloads HuggingFace models (Wan 2.1/2.2, NetaYume), creates persistent volume directories, and runs the ComfyUI container with GPU access on port 13000. Override `HOST_PORT`, `IMAGE`, or `BASE_DIR` via env.
- **projects/nanochat/speedrun.sh** starts with hardware verification (CPU/mem/GPU/network) before dropping into the nanochat training sequence. Set `NANOCHAT_VERIFY_ONLY=1` for a dry run.

## Network configuration (LAN + 200 G fabric)

`start-k8s-cluster.sh`, `stop-k8s-cluster.sh`, and `run_nccl_200g.sh` now read network overrides from `~/.config/dgx-spark-toolkit/network.env` (or any file pointed to by `DGX_SPARK_NETWORK_CONFIG`). Copy [`config/network.env.example`](config/network.env.example) to that location and tweak:

- Set `CONTROL_PLANE_API_*` to the LAN IP/CIDR/interface that should be reachable from your home network (e.g., `192.168.86.x`).
- Keep the 200 G interconnect alive by leaving your private fabric in `FABRIC_CTRL_*` and the worker-specific `WORKER_NODE_*` values (default 10.10.10.x). The start script will add the LAN address for API access and still configure the fabric on both nodes.
- `run_nccl_200g.sh` automatically reuses the same fabric IPs/interfaces so you do not need to edit the script each time.

This split lets the control plane advertise a 192.168.86.x address for the dashboard/UI while the pods and NCCL traffic continue to traverse the dedicated high-speed link between nodes.
