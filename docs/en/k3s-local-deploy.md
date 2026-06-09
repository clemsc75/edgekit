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

# Debug mode (full output, no spinner):
./scripts/k3s-master.sh --verbose
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

# Debug mode (full output, no spinner):
./scripts/k3s-worker.sh --master-ip "<MASTER_IP>" --token "<K3S_TOKEN>" --verbose
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

## Handling Reboots, Rerunning, and IP Changes

Both `k3s-master.sh` and `k3s-worker.sh` are designed to be **idempotent**, meaning they can be run multiple times safely without breaking existing configurations.

### What happens on system reboot?
- **K3s services auto-start**: The K3s server on the Master (`k3s` systemd service) and the K3s agent on the Worker (`k3s-agent` systemd service) are automatically enabled to start on system boot. You do **not** need to rerun the scripts to start K3s after restarting the machines.
- **Docker auto-starts**: The Docker daemon also starts automatically on boot.

### Rerunning the scripts
You can rerun the scripts at any time to:
- Rebuild and re-import the local Docker images if you made code changes.
- Re-run the automated validation tests.
- Re-apply Helm deployments (on Master).

### Handling Master IP Changes (e.g., DHCP changes after reboot)
In a local environment without static/reserved IP addresses, the Master node's IP address might change after a reboot. The scripts make it easy to update the configuration:

1. **The Join Token is Permanent**: The K3s cluster token generated on the Master node is stored persistently in `/var/lib/rancher/k3s/server/node-token` and does **not** change when the Master's IP changes or when the machine reboots. You can always reuse the same token.
2. **Retrieve the New IP**: Rerun the Master script or check the machine's IP address:
   ```bash
   ./scripts/k3s-master.sh
   ```
   This will display the new connection block with the updated IP.
3. **Update the Worker Node**: Run the worker script with the **new Master IP** and the **same token**:
   ```bash
   bash scripts/k3s-worker.sh --master-ip "<NEW_MASTER_IP>" --token "<SAME_TOKEN>"
   ```
   The worker script will automatically update the K3s agent service configuration (`K3S_URL`), restart the agent, and reconnect the Worker node to the Master.

---

## Log Files

Logs are written under the `logs/` directory in the repository root:
- Master log: `logs/k3s-master-YYYYMMDD-HHMMSS.log`
- Worker log: `logs/k3s-worker-YYYYMMDD-HHMMSS.log`
- Uninstall log: `logs/uninstall-edgekit-YYYYMMDD-HHMMSS.log`

> [!TIP]
> If the spinner freezes or you need to debug a failed step, rerun any script with the `--verbose` flag to see the full raw output directly in the terminal.

---

## Uninstallation

Use the dedicated `uninstall-edgekit.sh` script to perform a **complete cleanup** of any node (removes K3s, Helm releases, CNI interfaces, and EdgeKit Docker images):

```bash
# On the Master node
bash scripts/uninstall-edgekit.sh --role master

# On the Worker node
bash scripts/uninstall-edgekit.sh --role worker

# Auto-detect role (checks which k3s uninstall script is present)
bash scripts/uninstall-edgekit.sh
```

After cleanup, the machine will be in a clean state and you can safely rerun `k3s-master.sh` or `k3s-worker.sh`.
