# EdgeKit

**EdgeKit** is an open-source client/server IoT edge platform designed to run on [k3s](https://k3s.io/).  
It provides a central MQTT broker (server) and lightweight edge agents (clients) that collect telemetry and stream it to the server via MQTT over WebSocket.

---

## Architecture

```
┌─────────────────────────────────────────┐
│            k3s / Kubernetes             │
│                                         │
│  ┌───────────────────────────────────┐  │
│  │         edgekit-server            │  │
│  │   Eclipse Mosquitto MQTT broker   │  │
│  │   • port 1883 – plain MQTT        │  │
│  │   • port 9001 – MQTT over WS      │  │
│  └───────────────────────────────────┘  │
│            ▲              ▲             │
│            │  WebSocket   │             │
│  ┌─────────┴──┐    ┌──────┴─────────┐   │
│  │   client 1 │    │   client N     │   │
│  │ edge agent │    │  edge agent    │   │
│  └────────────┘    └────────────────┘   │
└─────────────────────────────────────────┘
```

Each **client** is a single Docker container that:

- Collects system metrics (CPU, memory, disk, network)
- Publishes JSON payloads to `edgekit/<client-id>/metrics` every 5 seconds (configurable)
- Automatically reconnects to the broker on failure

The **server** is a single Eclipse Mosquitto container with both plain MQTT (1883) and WebSocket (9001) listeners.

For a deeper dive, see [docs/architecture.md](docs/architecture.md).

---

## Quick Start (local)

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) ≥ 24
- [Docker Compose](https://docs.docker.com/compose/) v2

### 1. Clone the repository

```bash
git clone https://github.com/perspikapps/edgekit.git
cd edgekit
```

### 2. Start the stack

```bash
./scripts/start-local.sh
```

This builds and starts:

- `edgekit-server` – MQTT broker (ports 1883 and 9001 exposed on localhost)
- `edgekit-client` – Edge agent publishing metrics every 5 seconds

### 3. Watch metrics flow

```bash
# Subscribe to all edgekit topics
docker run --rm --network host eclipse-mosquitto:2.0 \
  mosquitto_sub -h localhost -t "edgekit/#" -v
```

### 4. Stop the stack

```bash
./scripts/stop-local.sh
```

For a full walkthrough, see [docs/quickstart.md](docs/quickstart.md).

---

## Deploy on k3s

### Prerequisites

- A running k3s cluster
- [Helm](https://helm.sh/docs/intro/install/) ≥ 3.14
- `kubectl` configured to reach the cluster

### Install with Helm

```bash
# Install edgekit (server + 1 client)
helm install edgekit oci://ghcr.io/perspikapps/charts/edgekit \
  --namespace edgekit \
  --create-namespace

# Scale to multiple clients
helm upgrade edgekit oci://ghcr.io/perspikapps/charts/edgekit \
  --namespace edgekit \
  --set client.replicaCount=3
```

Or from the local chart:

```bash
helm install edgekit ./helm/edgekit \
  --namespace edgekit \
  --create-namespace
```

### Local k3s test deploy (Multi-Node Master/Worker)

Run the local K3s test using two separate scripts to simulate a Master (Server) and a Worker (Client) node.

**1. On the Master Node (x86_64 only):**
```bash
chmod +x ./scripts/k3s-master.sh
./scripts/k3s-master.sh

# Debug mode (full output, no spinner):
./scripts/k3s-master.sh --verbose
```
This script will print out the IP and Token parameters to run on the Worker node:

**2. On the Worker Node (ARM or x86_64):**
```bash
chmod +x ./scripts/k3s-worker.sh
./scripts/k3s-worker.sh --master-ip "<MASTER_IP>" --token "<K3S_TOKEN>"

# Debug mode (full output, no spinner):
./scripts/k3s-worker.sh --master-ip "<MASTER_IP>" --token "<K3S_TOKEN>" --verbose
```

Optional variables on Master:
```bash
IMAGE_TAG=test-1 CLIENT_REPLICAS=3 ./scripts/k3s-master.sh
```

**3. Cleanup / Uninstall (on either node):**
```bash
# Auto-detect role and clean up
bash scripts/uninstall-edgekit.sh

# Or specify the role explicitly
bash scripts/uninstall-edgekit.sh --role master
bash scripts/uninstall-edgekit.sh --role worker
```

Logs are written under `logs/`.

For the complete walkthrough and OS compatibility notes, see
[docs/en/k3s-local-deploy.md](docs/en/k3s-local-deploy.md).

### Verify

```bash
kubectl -n edgekit get pods
kubectl -n edgekit logs -f -l app.kubernetes.io/component=client
```

---

## Configuration

All configuration is via environment variables (client) and `values.yaml` (Helm).

| Variable              | Default                    | Description                              |
| --------------------- | -------------------------- | ---------------------------------------- |
| `MQTT_BROKER_URL`     | `ws://edgekit-server:9001` | WebSocket URL of the MQTT broker         |
| `MQTT_TOPIC_PREFIX`   | `edgekit`                  | Topic namespace prefix                   |
| `CLIENT_ID`           | auto-generated             | Unique identifier for this edge agent    |
| `PUBLISH_INTERVAL_MS` | `5000`                     | Metrics publish interval in milliseconds |

See [helm/edgekit/values.yaml](helm/edgekit/values.yaml) for the full Helm configuration reference.

## Image base

The client image now uses the official `node:20-alpine` base image. This change was made to simplify the build and reduce image size. For background, tests and validation details see [ISSUE_03](issue/ISSUE_03_migrate-to-alpine-base-image.md).

---

## Repository Layout

```
edgekit/
├── server/                  # MQTT broker container
│   ├── Dockerfile
│   ├── mosquitto.conf
│   └── entrypoint.sh
├── client/                  # Edge agent container
│   ├── Dockerfile
│   ├── package.json
│   └── src/
│       └── index.js
├── helm/
│   └── edgekit/             # Root Helm chart
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
├── scripts/
│   ├── lib/
│   │   └── spinner.sh       # Shared spinner/progress-indicator utilities
│   ├── build.sh             # Build Docker images
│   ├── k3s-master.sh        # Configure K3s Master/Server node
│   ├── k3s-worker.sh        # Configure K3s Worker/Agent node
│   ├── uninstall-edgekit.sh # Full cleanup of a Master or Worker node
│   ├── start-local.sh       # Start via docker compose
│   └── stop-local.sh        # Stop local stack
├── .github/
│   └── workflows/
│       ├── ci.yml           # CI: lint + build on PR/push to develop|main
│       └── release.yml      # Release: push images + Helm chart on tag
├── docs/
│   ├── architecture.md
│   └── quickstart.md
└── docker-compose.yml       # Local development
```

---

## CI / CD

| Workflow      | Trigger                          | What it does                                                                      |
| ------------- | -------------------------------- | --------------------------------------------------------------------------------- |
| `ci.yml`      | push / PR to `develop` or `main` | Lints Helm chart, builds both Docker images                                       |
| `release.yml` | push of `v*.*.*` tag             | Builds & pushes images to GHCR, packages & pushes Helm chart to GHCR OCI registry |

To release a new version:

```bash
git tag v1.0.0
git push origin v1.0.0
```

---

## Branching strategy

| Branch      | Purpose                                              |
| ----------- | ---------------------------------------------------- |
| `main`      | Production-ready releases only                       |
| `develop`   | Integration branch – all feature branches merge here |
| `feature/*` | Individual features or fixes                         |

---

## Contributing

Pull requests are welcome. Please open an issue first to discuss what you would like to change.

---

## License

[Apache 2.0](LICENSE)
