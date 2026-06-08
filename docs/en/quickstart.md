# Quick Start Guide

This guide walks you through running EdgeKit locally and then deploying it to a k3s cluster.

---

## Running locally with Docker Compose

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) ≥ 24 (with Compose v2)
- Git

### Steps

#### 1. Clone the repository

```bash
git clone https://github.com/perspikapps/edgekit.git
cd edgekit
```

#### 2. (Optional) Build images manually

```bash
./scripts/build.sh
```

#### 3. Start the full stack

```bash
./scripts/start-local.sh
```

Expected output:

```
==> Starting edgekit stack (builds images if needed)…
[+] Building …
[+] Running 2/2
 ✔ Container edgekit-server  Started
 ✔ Container edgekit-client  Started

✅ edgekit is running!

   MQTT broker:       mqtt://localhost:1883
   MQTT over WS:      ws://localhost:9001

   View logs:         docker compose logs -f
   Stop:              ./scripts/stop-local.sh
```

#### 4. Verify metrics are flowing

Open a second terminal and subscribe to all topics:

```bash
docker run --rm --network host eclipse-mosquitto:2.0 \
  mosquitto_sub -h localhost -t "edgekit/#" -v
```

You should see JSON payloads arriving every 5 seconds:

```
edgekit/edge-local-1/metrics {"clientId":"edge-local-1","timestamp":"2024-01-15T10:30:00.000Z","cpu":{"loadPercent":5.12},...}
```

#### 5. Stop the stack

```bash
./scripts/stop-local.sh
```

---

## Deploying on k3s

### Prerequisites

- A k3s cluster (single node is fine for testing)
- [Helm](https://helm.sh/docs/intro/install/) ≥ 3.14
- `kubectl` configured for the cluster

### Option A – Install from GHCR (recommended)

```bash
helm install edgekit oci://ghcr.io/perspikapps/charts/edgekit \
  --namespace edgekit \
  --create-namespace \
  --wait
```

### Option B – Install from local chart

```bash
helm install edgekit ./helm/edgekit \
  --namespace edgekit \
  --create-namespace \
  --wait
```

### Verify the deployment

```bash
kubectl -n edgekit get pods
# NAME                               READY   STATUS    RESTARTS
# edgekit-server-xxxxxxxxxx-xxxxx   1/1     Running   0
# edgekit-client-xxxxxxxxxx-xxxxx   1/1     Running   0

kubectl -n edgekit logs -f -l app.kubernetes.io/component=client
# [edgekit-client] Starting — id=edgekit-client-xxxxx broker=ws://edgekit-server:9001
# [edgekit-client] Connected to ws://edgekit-server:9001
# [edgekit-client] Published to edgekit/edgekit-client-xxxxx/metrics
```

### Scale to multiple clients

```bash
helm upgrade edgekit ./helm/edgekit \
  --namespace edgekit \
  --set client.replicaCount=3
```

### Change publish interval

```bash
helm upgrade edgekit ./helm/edgekit \
  --namespace edgekit \
  --set client.publishIntervalMs=10000
```

### Uninstall

```bash
helm uninstall edgekit --namespace edgekit
kubectl delete namespace edgekit
```

---

## Subscribing to metrics from outside the cluster

Forward the WebSocket port to your local machine:

```bash
kubectl -n edgekit port-forward svc/edgekit-server 9001:9001
```

Then connect any MQTT-over-WebSocket client to `ws://localhost:9001`.

Example using `mosquitto_sub` with WebSocket support:

```bash
docker run --rm --network host eclipse-mosquitto:2.0 \
  mosquitto_sub -h localhost -p 9001 -t "edgekit/#" -v
```

---

## Environment variable reference

| Variable | Default | Description |
|---|---|---|
| `MQTT_BROKER_URL` | `ws://edgekit-server:9001` | Full WebSocket URL of the broker |
| `MQTT_TOPIC_PREFIX` | `edgekit` | Prefix for all published topics |
| `CLIENT_ID` | pod name (k8s) / `edge-local-1` (compose) | Unique agent identifier |
| `PUBLISH_INTERVAL_MS` | `5000` | Metrics publish interval (ms) |
