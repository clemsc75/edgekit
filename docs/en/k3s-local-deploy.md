# EdgeKit – K3s Local Deployment Guide

> **Branch:** `feature/k3s-local-test` | **Topology:** `k3s-local`

This guide documents the **local K3s-based EdgeKit deployment**, simulating a real edge environment with a dedicated master node and one or more worker nodes. 

---

## 1. Architecture Overview

The `k3s-local` deployment follows a two-node model (Master + Worker). It isolates the Control Plane (Server) from the Edge Devices (Clients), replicating a true IoT infrastructure.

```text
 ┌──────────────────────────────────┐      ┌─────────────────────────────────┐
 │          MASTER NODE             │      │         WORKER NODE(S)          │
 │  ┌────────────────────────────┐  │      │  ┌───────────────────────────┐  │
 │  │   K3s Server (API + etcd)  │  │      │  │     K3s Agent             │  │
 │  └────────────────────────────┘  │      │  └───────────────────────────┘  │
 │  ┌────────────────────────────┐  │ MQTT │  ┌───────────────────────────┐  │
 │  │  EdgeKit Server Pod        │◄─┼──────┼──│  EdgeKit Client Pod(s)    │  │
 │  │  (Mosquitto + processor)   │  │      │  │  (telemetry publishers)   │  │
 │  └────────────────────────────┘  │      │  └───────────────────────────┘  │
 │  ┌────────────────────────────┐  │      │                                 │
 │  │  Helm (chart management)   │  │      │  Labels:                        │
 │  └────────────────────────────┘  │      │  edgekit.io/role=worker         │
 └──────────────────────────────────┘      └─────────────────────────────────┘
```

### Key Technical Mechanisms
- **Zero-Touch Deployment:** The Master schedules the EdgeKit Client pods, but they remain `Pending` until a Worker node joins with the `edgekit.io/role=worker` label.
- **Containerd Namespace Isolation:** Docker images are exported and directly imported into K3s's internal `k8s.io` namespace, allowing for fully air-gapped deployments.
- **Automated Firewall:** `ufw` and `iptables` are automatically configured by the scripts to allow K3s communication (Ports: `6443/TCP`, `8472/UDP`, `1883/TCP`).

---

## 2. Prerequisites

| Role | Min. Specs | OS | Required Tools |
|------|-----------|----|----------------|
| **Master** | 2 vCPU, 2GB RAM | Ubuntu/Debian (x86_64 or ARM64) | `bash`, `curl`, `docker` |
| **Worker** | 1 vCPU, 1GB RAM | Ubuntu/Debian/RasPiOS | `bash`, `curl` |

> **⚠️ Critical:** Ensure both nodes have synchronized clocks (NTP). A desynchronized clock on the Worker will cause SSL verification errors (`curl: (60)`) when joining the cluster.

---

## 3. Step-by-Step Provisioning

### Step 1: Provision the Master Node
On your main machine, execute the master script. This will install K3s, configure the firewall, build the Server image, and deploy the Helm chart.

```bash
# Optional: Override default chart values via inline environment variables
CLIENT_REPLICAS=2 PUBLISH_INTERVAL_MS=5000 bash scripts/k3s-master.sh
```

At the end of the script, it will display the `MASTER_IP` and the `K3S_TOKEN`. Keep them handy.

### Step 2: Provision the Worker Node
On your edge device (or secondary VM), export the credentials provided by the Master and run the worker script.

```bash
bash scripts/k3s-worker.sh --master-ip "<IP_FROM_MASTER>" --token "<TOKEN_FROM_MASTER>"
```
This script installs the K3s agent, connects to the Master, builds the Client image locally, and applies the `edgekit.io/role=worker` label so the pending pods can start.

---

## 4. Verification & Observability

All verification commands must be executed on the **Master Node** (which holds the `kubectl` configuration).

### 4.1 Verify Pod Distribution
Check that the server runs on the master and the client runs on the worker.
```bash
kubectl get pods -n edgekit -o wide
```

### 4.2 Monitor Live JSON Telemetry
The Client continually generates IoT metrics. To see the raw JSON data flowing into the MQTT Broker in real-time, subscribe directly inside the Server pod:
```bash
kubectl exec -n edgekit deploy/edgekit-server -- mosquitto_sub -h localhost -p 1883 -t '#' -v
```

### 4.3 Application Logs
To view standard output of the applications:
```bash
# Server Logs
kubectl logs -n edgekit -l app.kubernetes.io/component=server

# Client Logs
kubectl logs -n edgekit -l app.kubernetes.io/component=client
```

---

## 5. Troubleshooting & Help Commands

If something goes wrong, use these commands to diagnose the issue.

### Master Node Debugging
```bash
# Check if K3s server service is healthy
sudo systemctl status k3s
sudo journalctl -u k3s -f

# Check Helm release status
helm list -n edgekit
```

### Worker Node Debugging
```bash
# Check if K3s agent service is healthy
sudo systemctl status k3s-agent
sudo journalctl -u k3s-agent -f

# If worker fails to join due to SSL cert (Code 60), verify time sync:
date
sudo date -s "YYYY-MM-DD HH:MM:SS"
```

---

## 6. Cleanup & Reset

To completely tear down the environment, remove K3s, and reset networking rules, run the uninstall script on **both** nodes:

```bash
bash scripts/uninstall-edgekit.sh
```