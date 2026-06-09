# EdgeKit — Local K3s Deployment Guide (Master & Worker)

> **Goal:** Deploy and test a full EdgeKit cluster on real hardware — an x86 Master and an ARM Worker (e.g. a Raspberry Pi) — using two automated, self-contained Bash scripts.

---

## Architecture

```
                    YOUR LOCAL NETWORK (LAN / Ethernet)
   ┌──────────────────────────────────────────────────────┐
   │                                                      │
   │  ┌────────────────────────┐   ┌──────────────────┐  │
   │  │   MASTER NODE (x86)    │   │  WORKER NODE     │  │
   │  │                        │   │  (ARM or x86)    │  │
   │  │  ┌──────────────────┐  │   │                  │  │
   │  │  │ K3s Server       │◄─┼───┤ K3s Agent        │  │
   │  │  │  (control plane) │  │   │  (label:         │  │
   │  │  └──────────────────┘  │   │   edgekit.io/    │  │
   │  │                        │   │   role=worker)   │  │
   │  │  ┌──────────────────┐  │   │                  │  │
   │  │  │ edgekit-server   │  │   │  ┌────────────┐  │  │
   │  │  │ (Mosquitto MQTT) │◄─┼───┼──┤edgekit-    │  │  │
   │  │  │ port 1883 / 9001 │  │   │  │client      │  │  │
   │  │  └──────────────────┘  │   │  │(edge agent)│  │  │
   │  │                        │   │  └────────────┘  │  │
   │  │  k3s-master.sh             │   │  k3s-worker.sh   │  │
   │  └────────────────────────┘   └──────────────────┘  │
   │                                                      │
   └──────────────────────────────────────────────────────┘
```

| Node | Role | Architecture | Script |
|---|---|---|---|
| **Master** | K3s server · MQTT broker · Helm manager | x86_64 / AMD64 only | `k3s-master.sh` |
| **Worker** | K3s agent · Edge agent | ARM64, ARMv7, or x86_64 | `k3s-worker.sh` |

> [!IMPORTANT]
> The **Master** must be x86_64. The **Worker** can be ARM (Raspberry Pi) or x86_64. Both must be on the same network with IP reachability.

---

## The Zero-Touch Deployment

This is the key concept. You run both scripts independently — you never need to manually upgrade the Helm chart or restart anything.

```
MASTER (k3s-master.sh)              WORKER (k3s-worker.sh)
──────────────────────────          ──────────────────────────────────────
[1] Open firewall ports             [1] Open firewall ports
[2] Install K3s server              [2] Install K3s agent
[3] Build & import server image         └── with label edgekit.io/role=worker
[4] helm install edgekit            [3] Build & import client image
    ├── server pod  ──► Running     [4] Validate connection to master
    └── client pod  ──► Pending (waiting)
                         │
                         │   ← Kubernetes scheduler detects
                         │     the new labelled worker node
                         │
                         └──────────────────────────► Running [OK]
```

**Why `Pending` is intentional:**
The Helm chart is deployed with `nodeSelector: {"edgekit.io/role": "worker"}` injected at install time. Since the Master node does not have that label, Kubernetes cannot schedule the client pod there — it waits. The moment the Worker joins the cluster with the correct label, the scheduler picks it up automatically. **No `helm upgrade`, no manual intervention.**

---

## Compatibility Matrix

| | Master | Worker |
|---|---|---|
| **Architecture** | x86_64 / AMD64 only | ARM64, ARMv7, x86_64 |
| **Tested OS** | Ubuntu Server 22.04, Debian 12 | Raspberry Pi OS 64-bit, Ubuntu Server ARM64/AMD64 |
| **Auto-install** | `apt`-based systems | `apt`-based systems |
| **Docker** | Required (auto-installed) | Required (auto-installed) |
| **K3s** | Auto-installed (server mode) | Auto-installed (agent mode) |
| **Helm** | Auto-installed (master only) | Not required |

---

## Quick Start

### Step 1 — Run the Master

On your x86 machine, from the repository root:

```bash
bash scripts/k3s-master.sh
```

The script takes a few minutes and runs through these phases:

```
[1/6] Configuring firewall (UFW + IP forwarding)
[2/6] Installing prerequisites (Docker, K3s, kubectl, Helm)
[3/6] Printing system info
[4/6] Building & importing edgekit-server image
[5/6] Deploying Helm chart (server Running, client Pending)
[6/6] Running validation tests
```

At the end, the script prints the **connection block** you'll need for the Worker:

```
╔══════════════════════════════════════════════════════════════╗
║  WORKER NODE CONNECTION INFO                                 ║
╠══════════════════════════════════════════════════════════════╣
║  MASTER_IP  = 192.168.1.50                                   ║
║  K3S_TOKEN  = K1077e6...::server:a4c5b...                    ║
╠══════════════════════════════════════════════════════════════╣
║  On the Worker machine, run:                                 ║
║                                                              ║
║    bash scripts/k3s-worker.sh \                              ║
║      --master-ip "192.168.1.50" \                            ║
║      --token "K1077e6...::server:a4c5b..."                   ║
╚══════════════════════════════════════════════════════════════╝
```

> [!NOTE]
> At this point, `kubectl -n edgekit get pods` will show the client pod as `Pending`. **This is correct and expected** — it's waiting for the Worker to join.

---

### Step 2 — Run the Worker

Copy the repository to your Worker machine (Raspberry Pi, VM, etc.):

```bash
# Option A: git clone
git clone https://github.com/perspikapps/edgekit.git && cd edgekit

# Option B: rsync from your dev machine
rsync -av /path/to/edgekit/ pi@<WORKER_IP>:~/edgekit/
```

Then run the worker script with the credentials from the Master's output:

```bash
bash scripts/k3s-worker.sh \
  --master-ip "192.168.1.50" \
  --token "K1077e6...::server:a4c5b..."
```

The Worker script:
1. Configures the firewall (UFW / iptables)
2. Fixes Raspberry Pi cgroups if needed (and reboots if required)
3. Installs the K3s agent with `edgekit.io/role=worker` baked into the systemd service
4. Builds and imports the `edgekit-client` image
5. Runs 5 automated validation tests

> [!TIP]
> **Watch the magic happen in real time.** On the Master, run this before starting the Worker script:
> ```bash
> watch -n 2 kubectl -n edgekit get pods -o wide
> ```
> You'll see the client pod switch from `Pending` → `Running` the moment the Worker joins.

---

### Step 3 — Verify

On the **Master node**, confirm everything is healthy:

```bash
# All nodes should be Ready, Worker should have the label
kubectl get nodes -o wide --show-labels

# Pods should be distributed across nodes
kubectl -n edgekit get pods -o wide
```

Expected output:

```
NAME                        READY   STATUS    NODE
edgekit-server-b4b44d57d    1/1     Running   master-node     ← x86 Master
edgekit-client-7f9c8b6d4    1/1     Running   raspberry-pi    <- ARM Worker
```

```bash
# Stream live MQTT telemetry from the edge agents
kubectl -n edgekit logs -f -l app.kubernetes.io/component=client

# Monitor the MQTT broker
kubectl -n edgekit logs -f -l app.kubernetes.io/component=server
```

---

## Firewall Management

Both scripts automatically configure the firewall on first run. No manual `ufw allow` commands needed.

### What gets opened

| Port | Protocol | Direction | Purpose |
|---|---|---|---|
| `6443` | TCP | Workers → Master | K3s API Server |
| `8472` | UDP | Bidirectional | Flannel VXLAN overlay network |
| `10250` | TCP | Master → Workers | Kubelet metrics & exec |

Additionally, `net.ipv4.ip_forward=1` is written to `/etc/sysctl.d/99-k3s-edgekit.conf` and applied immediately.

### Behavior by environment

| Condition | Behavior |
|---|---|
| UFW installed + active | Ports are opened, `ufw reload` is triggered |
| UFW installed + inactive | Logged, skipped — no change to UFW state |
| UFW not installed | Logged, skipped |
| iptables available | FORWARD ACCEPT rules added for pod CIDR `10.42.0.0/16` |

### Skipping firewall (advanced users)

If you manage your own firewall or use `nftables`, pass `--skip-firewall`:

```bash
# Master
bash scripts/k3s-master.sh --skip-firewall

# Worker
bash scripts/k3s-worker.sh --master-ip <IP> --token <TOKEN> --skip-firewall
```

> [!WARNING]
> If you skip the firewall configuration, you must manually ensure the ports above are open and that `net.ipv4.ip_forward=1` is set, otherwise Flannel networking between pods will fail silently.

---

## Advanced Options & Environment Variables

All environment variables are optional. They can be combined freely and passed inline before the script call.

### Master script variables

| Variable | Default | Description |
|---|---|---|
| `CLIENT_REPLICAS` | `1` | Number of client (edge agent) pod replicas to schedule on Workers |
| `PUBLISH_INTERVAL_MS` | `5000` | How often (ms) each edge agent publishes metrics to the MQTT broker |
| `IMAGE_TAG` | `k3s-local` | Docker image tag used for build and import |
| `NAMESPACE` | `edgekit` | Kubernetes namespace for the Helm release |
| `RELEASE_NAME` | `edgekit` | Helm release name |
| `VERBOSE` | `0` | Set to `1` to disable the spinner and print raw command output |
| `SKIP_FIREWALL` | `0` | Set to `1` to skip UFW/iptables configuration |
| `DOCKER_BIN` | `docker` | Override the Docker binary (e.g. `podman`) |
| `LOG_DIR` | `<repo>/logs` | Directory where timestamped log files are written |

### Worker script variables

| Variable | Default | Description |
|---|---|---|
| `IMAGE_TAG` | `k3s-local` | Must match the tag used on the Master |
| `VERBOSE` | `0` | Set to `1` to disable the spinner |
| `SKIP_FIREWALL` | `0` | Set to `1` to skip firewall configuration |
| `DOCKER_BIN` | `docker` | Override the Docker binary |
| `LOG_DIR` | `<repo>/logs` | Directory where log files are written |

### Usage examples

```bash
# Deploy 3 client replicas instead of 1
CLIENT_REPLICAS=3 bash scripts/k3s-master.sh

# Publish metrics every 10 seconds
PUBLISH_INTERVAL_MS=10000 bash scripts/k3s-master.sh

# Use a custom image tag (must match on both nodes)
IMAGE_TAG=dev-v2 bash scripts/k3s-master.sh
IMAGE_TAG=dev-v2 bash scripts/k3s-worker.sh --master-ip <IP> --token <TOKEN>

# Full debug mode: see every command, every output line
VERBOSE=1 bash scripts/k3s-master.sh
# same as:
bash scripts/k3s-master.sh --verbose

# Combine multiple variables
CLIENT_REPLICAS=2 IMAGE_TAG=sprint-4 VERBOSE=1 bash scripts/k3s-master.sh
```

> [!TIP]
> Use `--verbose` (or `VERBOSE=1`) whenever a spinner appears to freeze. It disables the progress indicator and prints the raw stdout/stderr of every command directly to the terminal, making it trivial to spot what's hanging.

---

## Reboots, Re-runs & IP Changes

Both scripts are **fully idempotent** — safe to run multiple times on the same machine.

### After a system reboot

You do **not** need to rerun the scripts. All services are registered with systemd and start automatically:

| Service | Node | Starts on boot? |
|---|---|---|
| `k3s` | Master | Yes |
| `k3s-agent` | Worker | Yes |
| `docker` | Both | Yes |

The Worker's node label (`edgekit.io/role=worker`) is embedded in the `k3s-agent` systemd service unit via `INSTALL_K3S_EXEC` and is **re-applied on every agent start** — no kubectl access required on the Worker.

### When to rerun the scripts

| Situation | Action |
|---|---|
| You modified `server/` or `client/` source code | Rerun the respective script — it rebuilds and re-imports the image |
| You want to change `CLIENT_REPLICAS` or other Helm values | Rerun `k3s-master.sh` with the new variable |
| The Master's IP changed (DHCP) | See section below |
| Validation tests failed | Rerun the script — it re-runs tests without reinstalling |

### Master IP changed after reboot

The **K3s node token never changes**. It lives at `/var/lib/rancher/k3s/server/node-token` and survives reboots and IP changes. Only the IP needs to be updated.

```bash
# 1. Get the new Master IP (run on Master)
bash scripts/k3s-master.sh
#    → the connection block at the end shows the current IP

# 2. Update the Worker with the new IP and the SAME old token (run on Worker)
bash scripts/k3s-worker.sh \
  --master-ip "<NEW_IP>" \
  --token "<SAME_TOKEN_AS_BEFORE>"
```

The Worker script updates `K3S_URL` in the systemd service and restarts the agent automatically.

---

## Logs & Debugging

Every script run produces a **timestamped log file** with the full output of every command (even in spinner mode):

```
logs/
├── k3s-master-20260609-143012.log
├── k3s-worker-20260609-145523.log
└── uninstall-edgekit-20260609-162201.log
```

### Debugging workflow

```bash
# Step 1: Re-run in verbose mode to see what's happening live
bash scripts/k3s-master.sh --verbose

# Step 2: Inspect the latest log file
tail -100 logs/k3s-master-*.log | less

# Step 3: Check K3s service status on Master
sudo systemctl status k3s
sudo journalctl -u k3s -n 100 --no-pager

# Step 4: Check K3s agent status on Worker
sudo systemctl status k3s-agent
sudo journalctl -u k3s-agent -n 100 --no-pager

# Step 5: Check pod events (scheduling errors, image pull errors)
kubectl -n edgekit describe pod <pod-name>
```

---

## Uninstallation (Clean Slate)

Use the dedicated script to fully reset a node — removes K3s, Helm releases, CNI interfaces, firewall rules, and EdgeKit Docker images.

```bash
# Auto-detect role from installed binaries
bash scripts/uninstall-edgekit.sh

# Or specify explicitly
bash scripts/uninstall-edgekit.sh --role master
bash scripts/uninstall-edgekit.sh --role worker

# Full verbose output
bash scripts/uninstall-edgekit.sh --role master --verbose
```

After cleanup, the machine is in a clean state. You can safely rerun `k3s-master.sh` or `k3s-worker.sh` for a fresh deployment — no reflashing required.

> [!CAUTION]
> Running `uninstall-edgekit.sh` on the Master will **also evict all worker nodes** from the cluster (since the API server is gone). Always uninstall workers **before** the master if you want a graceful teardown.

---

## Reference: Script Flags

### `k3s-master.sh`

```
Usage: bash scripts/k3s-master.sh [OPTIONS]

Flags:
  -v, --verbose         Disable spinner, print raw command output to terminal
  -F, --skip-firewall   Skip UFW/iptables configuration
  -h, --help            Show this help message
```

### `k3s-worker.sh`

```
Usage: bash scripts/k3s-worker.sh --master-ip <IP> --token <TOKEN> [OPTIONS]

Required:
  --master-ip <IP>      IP address of the K3s Master node
  --token <TOKEN>       Join token (printed by k3s-master.sh)

Flags:
  -v, --verbose         Disable spinner, print raw command output to terminal
  -F, --skip-firewall   Skip UFW/iptables configuration
  -h, --help            Show this help message
```

### `uninstall-edgekit.sh`

```
Usage: bash scripts/uninstall-edgekit.sh [--role master|worker] [--verbose]

  --role master|worker  Specify which node type to clean up
                        (auto-detected if omitted)
  --verbose             Print all uninstall command output
```
