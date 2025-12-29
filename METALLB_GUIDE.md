# MetalLB LoadBalancer Guide for DGX Spark Cluster

This guide explains how we exposed the Kubernetes services (like OpenWebUI) to the local network (LAN) using MetalLB in Layer 2 mode. This allows access from external devices (e.g., your Mac) using a standard IP address on the `192.168.86.x` subnet.

## Cluster Architecture & Network Separation

The cluster consists of two nodes configured to separate internal high-performance traffic from external access:

1.  **Control Plane (`spark-2959`)**: Running Ollama.
2.  **Worker Node (`spark-ba63`)**: Running OpenWebUI.

**Network interfaces:**
*   **200G Link (`10.10.10.x`)**: Used for internal Pod-to-Pod communication (CNI/Calico) to ensure high bandwidth between Ollama and OpenWebUI.
*   **LAN Link (`192.168.86.x`)**: Used for external access/management. MetalLB uses this interface to broadcast Service IPs.

## How It Works (Layer 2 Mode)

In Layer 2 mode, one of the MetalLB speaker pods (running on every node) "claims" the Service IP by responding to ARP requests from the local network.

**The Flow:**
1.  You request `http://192.168.86.200` from your Mac.
2.  Your Mac asks the network: *"Who has 192.168.86.200?"* (ARP Request).
3.  The **MetalLB Speaker** on `spark-ba63` (hosting the OpenWebUI pod) replies: *"I have it!"*
4.  Your Mac sends the traffic to `spark-ba63`'s LAN interface.
5.  `kube-proxy` on the node routes the packet to the OpenWebUI container.

## Configuration Steps

### 1. Install MetalLB
MetalLB was installed via the native manifest:
```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml
```

### 2. Enable Strict ARP
This is **critical** for MetalLB to work correctly with `kube-proxy`. It ensures the node kernel doesn't block ARP requests for IPs it doesn't technically "own".
```bash
kubectl get configmap kube-proxy -n kube-system -o yaml | \
sed -e "s/strictARP: false/strictARP: true/" | \
kubectl apply -f - -n kube-system

kubectl rollout restart daemonset kube-proxy -n kube-system
```

### 3. Configure IP Pool & Advertisement
We configured a dedicated IP pool (`lan-pool`) avoiding the DHCP range and other static IPs (like the `.50` conflict we encountered).

File: `deployments/metallb-config.yaml`
```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lan-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.86.200-192.168.86.220  # Safe range
  autoAssign: true
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lan-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - lan-pool
```
Apply with: `kubectl apply -f deployments/metallb-config.yaml`

### 4. Expose a Service
To make a service accessible, change its type to `LoadBalancer`.

**Example (OpenWebUI):**
```bash
kubectl expose deployment openwebui --type=LoadBalancer --name=openwebui --port=80 --target-port=8080
```
*Or patch an existing service:*
```bash
kubectl patch svc openwebui -p '{"spec": {"type": "LoadBalancer"}}'
```

## Troubleshooting

### Check IP Assignment
Ensure the service has an `EXTERNAL-IP`:
```bash
kubectl get svc openwebui
# NAME        TYPE           EXTERNAL-IP      PORT(S)
# openwebui   LoadBalancer   192.168.86.200   80:30777/TCP
```

### Check for IP Conflicts
If the service is unreachable, check if another device is stealing the IP.
Run this on a cluster node:
```bash
arp -n | grep 192.168.86.200
```
If the MAC address returned **does not match** any of the cluster nodes, you have a conflict (as happened with `.50`). Use a different IP range in the Pool configuration.

### Verify MetalLB Speakers
Ensure speakers are running on all nodes:
```bash
kubectl get pods -n metallb-system -l component=speaker
```
Check logs to see which node is announcing the IP:
```bash
kubectl logs -n metallb-system -l component=speaker | grep "announcing"
```



