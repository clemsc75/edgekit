# Test EdgeKit on Multi-Node Local K3s (Master & Worker)

This document describes how to deploy and test EdgeKit in a local K3s cluster split into a Master (Server) node and a Worker (Client) node.

Instead of a single script, the setup is split into two distinct scripts to support multi-node configurations (e.g., a x86_64 Master and an ARM-based Raspberry Pi Worker connected via LAN or Ethernet).

---

## Architecture Overview

- **Master Node (Server)**: Runs the K3s server, hosts the Eclipse Mosquitto MQTT broker, and manages the Helm deployment.
- **Worker Node (Client)**: Runs the K3s agent, builds the local EdgeKit client image, and registers with the Master node to run the edge agent pods.

---

## Supported Systems & Architectures

### Master Node (`scripts/k3s-master.sh`)
- **Constraint**: Must run on **x86_64 / AMD64** architectures.
- **OS Support**: Any Linux distribution with Docker and K3s. Automatic installation of missing components is supported on `apt`-based systems (Ubuntu Server, Debian).

### Worker Node (`scripts/k3s-worker.sh`)
- **Constraint**: Supports both **ARM** (aarch64/arm64, armv7l) and **x86_64 / AMD64** architectures.
- **OS Support**: Any Linux distribution. Tested on Raspberry Pi OS (64-bit), Ubuntu Server ARM64/AMD64, and Debian. Automatic installation of missing components is supported on `apt`-based systems.

---

## Quick Start

### 1. Setup the Master Node (Server)

On the Master machine (x86_64):

```bash
chmod +x ./scripts/k3s-master.sh
./scripts/k3s-master.sh
```

#### What the Master script does:
1. **Verifies Architecture**: Ensures the machine is x86_64 / AMD64.
2. **Installs Prerequisites**: Checks and installs `curl`, `ca-certificates`, `docker.io`, `k3s` (in server mode with `--cluster-init`), `kubectl`, and `helm` (on `apt`-based systems).
3. **Displays System/Technology Versions**: Prints OS, Kernel, CPU, RAM, Node.js, Python, Docker, K3s, and network details.
4. **Builds & Imports Server Image**: Builds `edgekit-server:k3s-local` and imports it into the K3s containerd store.
5. **Deploys Helm Chart**: Installs the local chart `helm/edgekit` with client replicas scaled to `0` (client pods will run on the Worker).
6. **Runs Automated Tests**:
   - Verifies the Master node status is `Ready`.
   - Verifies the server pod is running.
   - Verifies the server service is active.
   - Verifies the image exists in containerd.
7. **Generates Worker Connection Parameters**: Displays the exact command and credentials (`MASTER_IP` and `K3S_TOKEN`) needed for the Worker node to join.

At the end of execution, you will see a connection block like this:

```text
  ┌─────────────────────────────────────────────────────────────┐
  │  MASTER_IP    = 192.168.1.50
  │  K3S_TOKEN    = K1077e6...::server:a4c5b...
  └─────────────────────────────────────────────────────────────┘

  On the Worker machine, run:

    bash scripts/k3s-worker.sh \
      --master-ip "192.168.1.50" \
      --token "K1077e6...::server:a4c5b..."
```

---

### 2. Setup the Worker Node (Client)

Copy the repository to the Worker machine (via `git clone`, `rsync`, etc.).
Run the worker script using the IP and Token provided by the Master node:

```bash
chmod +x ./scripts/k3s-worker.sh
./scripts/k3s-worker.sh --master-ip "<MASTER_IP>" --token "<K3S_TOKEN>"
```

#### What the Worker script does:
1. **Verifies Architecture**: Accepts ARM64, ARMv7, and x86_64.
2. **Fixes Raspberry Pi cgroups**: If running on a Raspberry Pi and cgroups memory/cpuset limit options are missing in `/boot/cmdline.txt` or `/boot/firmware/cmdline.txt`, the script configures them and prompts for a system reboot.
3. **Installs Prerequisites**: Installs `docker.io` and `k3s` (configured in agent/worker mode pointing to the Master).
4. **Displays System/Technology Versions**: Prints OS, Hardware, Node.js, Docker, and K3s agent information.
5. **Builds & Imports Client Image**: Builds `edgekit-client:k3s-local` and imports it into the K3s agent containerd store.
6. **Runs Automated Connection & Functionality Tests**:
   - Verifies network connectivity to the Master API server on port 6443.
   - Verifies the K3s agent service/process is active.
   - Verifies the node registers successfully in the K3s cluster.
   - Verifies the client image is correctly imported.
   - Verifies K3s containerd is reachable.

---

## Verification

Once both scripts have completed successfully, run the following verification steps on the **Master Node**:

### Check Nodes status
```bash
kubectl get nodes -o wide
```
You should see both your Master node and Worker node listed as `Ready`.

### Scale and verify Client Pods
The Master Helm deployment has `client.replicaCount=0` by default. You can scale the client pods to run on the Worker nodes:

```bash
helm upgrade edgekit ./helm/edgekit \
  --namespace edgekit \
  --set client.replicaCount=2
```

Check where the pods are running:
```bash
kubectl -n edgekit get pods -o wide
```
The client pods should now be scheduled and running on the Worker node.

### View Logs
To view logs from the server component (running on the Master):
```bash
kubectl -n edgekit logs -f -l app.kubernetes.io/component=server
```

To view logs from the client agents (running on the Worker):
```bash
kubectl -n edgekit logs -f -l app.kubernetes.io/component=client
```

---

## Advanced Options

Both scripts accept optional customization via environment variables.

### Deploying multiple clients
Run this on the Master node to deploy 3 clients by default:
```bash
CLIENT_REPLICAS=3 ./scripts/k3s-master.sh
```

### Changing client publish interval
```bash
PUBLISH_INTERVAL_MS=10000 ./scripts/k3s-master.sh
```

### Using custom tags
Ensure you pass the same `IMAGE_TAG` to both scripts if you want to override the default `k3s-local` tag:
```bash
# On Master
IMAGE_TAG=custom-v1 ./scripts/k3s-master.sh

# On Worker
IMAGE_TAG=custom-v1 ./scripts/k3s-worker.sh --master-ip <IP> --token <TOKEN>
```

---

## Log Files

Logs are written under the `logs/` directory in the repository root:
- Master log: `logs/k3s-master-YYYYMMDD-HHMMSS.log`
- Worker log: `logs/k3s-worker-YYYYMMDD-HHMMSS.log`

---

## Uninstallation

To cleanly stop the cluster and remove EdgeKit:

1. **Uninstall Helm deployment** (on Master):
   ```bash
   helm uninstall edgekit --namespace edgekit
   kubectl delete namespace edgekit
   ```

2. **Clean up Worker Node** (on Worker):
   If you wish to stop the K3s agent service:
   ```bash
   sudo systemctl disable --now k3s-agent
   ```
