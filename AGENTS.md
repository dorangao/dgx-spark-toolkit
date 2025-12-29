# Agent Guidelines for DGX Spark Toolkit

This document provides guidance for AI coding agents working on this repository.

## Project Overview

**DGX Spark Toolkit** is a collection of scripts, Kubernetes manifests, and Docker configurations for managing a two-node DGX Spark cluster. The cluster consists of:

- **spark-2959**: Control plane node (Kubernetes master)
- **spark-ba63**: Worker node

Both machines are NVIDIA DGX Spark systems with:
- ARM64 architecture (aarch64)
- NVIDIA GPUs (1 per node)
- 200 GbE high-speed fabric interconnect (MLX5/ConnectX)
- Ubuntu 24.04 with NVIDIA kernel (6.14.0-1013-nvidia)

## Repository Structure

```
dgx-spark-toolkit/
├── scripts/              # Bash scripts for cluster management
│   ├── start-k8s-cluster.sh    # Main cluster startup/repair script
│   ├── stop-k8s-cluster.sh     # Graceful cluster shutdown
│   ├── check-k8s-cluster.sh    # Health check script
│   ├── sleep-cluster.sh        # Power management - suspend cluster
│   ├── wake-cluster.sh         # Power management - Wake-on-LAN
│   ├── check_roce.sh           # RoCE/RDMA network validation
│   ├── run_nccl_200g.sh        # NCCL multi-node GPU tests
│   └── ensure-fabric-ip.sh     # Fabric network setup
├── deployments/          # Kubernetes YAML manifests
│   ├── ollama-*.yaml           # Ollama LLM service
│   ├── openwebui-*.yaml        # Open WebUI frontend
│   ├── metallb-config.yaml     # LoadBalancer configuration
│   ├── dashboard-*.yaml        # Kubernetes dashboard
│   └── rdma-*.yaml             # RDMA/GPU test pods
├── stacks/               # Docker Compose stacks
│   └── openwebui/              # Ollama + OpenWebUI + nginx
├── comfyui-docker/       # ComfyUI container setup
├── model-manager/        # Python Flask app for model management
├── cluster-control-ui/   # Python Flask cluster control UI
├── config/               # Configuration templates
│   └── network.env.example     # Network configuration template
└── projects/             # Standalone projects
    └── nanochat/               # Nanochat training pipeline
```

## Coding Conventions

### Bash Scripts

1. **Shebang and safety options**:
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   ```

2. **Color-coded logging functions**:
   ```bash
   RED='\033[0;31m'
   GREEN='\033[0;32m'
   YELLOW='\033[1;33m'
   NC='\033[0m'
   
   log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
   log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
   log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
   ```

3. **Configuration via environment variables** with defaults:
   ```bash
   WORKER_NODE_NAME="${WORKER_NODE_NAME:-spark-ba63}"
   WORKER_NODE_IP="${WORKER_NODE_IP:-10.10.10.2}"
   ```

4. **Network configuration** is loaded from `~/.config/dgx-spark-toolkit/network.env`:
   ```bash
   load_network_overrides() {
       local cfg="$HOME/.config/dgx-spark-toolkit/network.env"
       [[ -f "$cfg" ]] && source "$cfg"
   }
   ```

5. **SSH to worker node** pattern:
   ```bash
   SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
   worker_ssh() {
       ssh "${SSH_OPTS[@]}" -p "$WORKER_SSH_PORT" "${WORKER_SSH_USER}@${WORKER_SSH_TARGET}" "$@"
   }
   ```

6. **Heredocs for remote scripts**: Use quoted heredocs to avoid escaping issues:
   ```bash
   # GOOD - variables passed as arguments, no escaping needed
   local remote_script=$(cat <<'EOF'
   set -euo pipefail
   API_IP="$1"
   echo "Connecting to $API_IP"
   EOF
   )
   worker_ssh "sudo bash -s -- '$K8S_API_IP'" <<< "$remote_script"
   
   # AVOID - complex escaping in heredocs
   worker_ssh "sudo bash -s" << EOF
   API_IP="\$K8S_API_IP"  # Escaping gets messy
   EOF
   ```

7. **Root check** for privileged scripts:
   ```bash
   check_root() {
       if [[ $EUID -ne 0 ]]; then
           log_error "This script must be run as root (use sudo)"
           exit 1
       fi
   }
   ```

### Kubernetes Manifests

1. **Namespace**: Most workloads go in `default` namespace; system components use dedicated namespaces:
   - `longhorn-system` - Storage
   - `metallb-system` - LoadBalancer
   - `kubernetes-dashboard` - Dashboard
   - `gpu-operator` - NVIDIA GPU operator

2. **LoadBalancer IPs**: MetalLB pool is `192.168.86.200-192.168.86.220`:
   ```yaml
   spec:
     type: LoadBalancer
     loadBalancerIP: 192.168.86.201  # Pick unused IP from pool
   ```

3. **GPU workloads**: Request NVIDIA GPUs explicitly:
   ```yaml
   resources:
     limits:
       nvidia.com/gpu: 1
   ```

4. **Node affinity** when workload needs specific node:
   ```yaml
   nodeSelector:
     kubernetes.io/hostname: spark-ba63
   ```

5. **Persistent storage**: Use Longhorn for distributed storage:
   ```yaml
   storageClassName: longhorn
   ```

### Network Architecture

| Network | Subnet | Purpose |
|---------|--------|---------|
| LAN | 192.168.86.0/24 | Management, SSH, LoadBalancer VIPs |
| Fabric | 10.10.10.0/24 | High-speed inter-node (200GbE) |
| Pod CIDR | 192.168.0.0/16 | Kubernetes pod network (Calico) |
| Service CIDR | 10.96.0.0/12 | Kubernetes services |

**Key IPs**:
- spark-2959 LAN: 192.168.86.38
- spark-ba63 LAN: 192.168.86.39
- spark-2959 Fabric: 10.10.10.1
- spark-ba63 Fabric: 10.10.10.2
- K8s API: 10.10.10.1:6443

### Common Issues and Solutions

1. **Network namespace EIO errors**: Clean stale CNI state and reboot:
   ```bash
   sudo rm -rf /var/lib/cni/* /var/run/netns/cni-*
   sudo systemctl restart containerd kubelet
   ```

2. **Multipath interfering with Longhorn**: Blacklist sd devices:
   ```bash
   # /etc/multipath.conf
   blacklist {
       devnode "^sd[a-z][0-9]*"
   }
   ```

3. **Node not Ready after reboot**: Run start-k8s-cluster.sh:
   ```bash
   sudo ./scripts/start-k8s-cluster.sh
   ```

4. **Worker join failures**: Ensure node is deleted from API before rejoin:
   ```bash
   kubectl delete node spark-ba63 --wait=true --timeout=60s
   ```

## Testing Guidelines

1. **Always test scripts with --dry-run** when available
2. **Check cluster health** before and after changes:
   ```bash
   kubectl get nodes
   kubectl get pods -A | grep -v Running
   ```
3. **Verify Longhorn** after storage changes:
   ```bash
   kubectl -n longhorn-system get nodes.longhorn.io
   ```

## Environment Details

- **Kubernetes**: v1.31.x (kubeadm-managed)
- **Container Runtime**: containerd
- **CNI**: Calico
- **Storage**: Longhorn
- **LoadBalancer**: MetalLB
- **GPU Operator**: NVIDIA GPU Operator

## File Modification Checklist

When modifying scripts:
- [ ] Maintain `set -euo pipefail`
- [ ] Use existing logging functions
- [ ] Add --help option for new scripts
- [ ] Test on both nodes if applicable
- [ ] Update README.md if adding new scripts

When modifying Kubernetes manifests:
- [ ] Verify resource limits are set
- [ ] Check nodeSelector if node-specific
- [ ] Test with `kubectl apply --dry-run=client`
- [ ] Verify services have correct selectors

## Quick Reference

```bash
# Cluster management
sudo ./scripts/start-k8s-cluster.sh    # Start/repair cluster
sudo ./scripts/stop-k8s-cluster.sh     # Stop cluster
./scripts/check-k8s-cluster.sh         # Health check

# Power management
sudo ./scripts/sleep-cluster.sh        # Suspend to save power
./scripts/wake-cluster.sh              # Wake via WoL (run from another machine)

# Diagnostics
kubectl get nodes -o wide
kubectl get pods -A
kubectl -n longhorn-system get nodes.longhorn.io
kubectl top nodes
```

