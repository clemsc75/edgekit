# Architecture

## Overview

EdgeKit is a lightweight IoT edge platform composed of two types of containers:

| Component | Image | Role |
|---|---|---|
| **server** | `edgekit-server` | Central Eclipse Mosquitto MQTT broker |
| **client** | `edgekit-client` | Edge agent – collects metrics, streams to server |

---

## Server

The server is a single [Eclipse Mosquitto](https://mosquitto.org/) instance configured with two listeners:

| Port | Protocol | Usage |
|------|----------|-------|
| 1883 | MQTT (TCP) | Internal cluster communication |
| 9001 | MQTT over WebSocket | Browser clients, external tooling |

**Configuration file**: `server/mosquitto.conf`

Mosquitto is the de-facto standard lightweight MQTT broker for IoT workloads. It handles all pub/sub routing; no custom server code is required.

### Data persistence

When deployed via Helm, broker state (retained messages, etc.) is stored in a `PersistentVolumeClaim`. In local Docker Compose mode, a named Docker volume is used.

---

## Client

The client is a Node.js application that:

1. Connects to the MQTT broker via WebSocket (`MQTT_BROKER_URL`)
2. Periodically collects system metrics using the [`systeminformation`](https://systeminformation.io/) library
3. Serialises metrics as JSON and publishes them to `<MQTT_TOPIC_PREFIX>/<CLIENT_ID>/metrics`

### Published payload format

```json
{
  "clientId": "edge-local-1",
  "timestamp": "2024-01-15T10:30:00.000Z",
  "uptime": 123456,
  "cpu": {
    "loadPercent": 12.34,
    "cores": 4
  },
  "memory": {
    "totalBytes": 8589934592,
    "usedBytes": 3221225472,
    "freeBytes": 5368709120,
    "usedPercent": 37.50
  },
  "filesystems": [
    {
      "mount": "/",
      "type": "ext4",
      "totalBytes": 107374182400,
      "usedBytes": 21474836480,
      "usedPercent": 20.00
    }
  ],
  "network": [
    {
      "iface": "eth0",
      "rxBytesTotal": 104857600,
      "txBytesTotal": 52428800
    }
  ]
}
```

### Reconnect behaviour

The MQTT client uses exponential-back-off reconnection (built into the `mqtt` npm package) with a 5-second base period. The container exits cleanly on SIGTERM/SIGINT, draining in-flight publishes first.

---

## Topic structure

```
edgekit/
└── <client-id>/
    └── metrics      ← JSON telemetry (QoS 1)
```

Consumers can subscribe to `edgekit/#` to receive all metrics from all clients, or `edgekit/<client-id>/metrics` for a specific agent.

---

## Kubernetes / k3s deployment

```
Namespace: edgekit
│
├── Deployment: edgekit-server     (replicas: 1)
│   └── Container: mosquitto
├── Service: edgekit-server
│   ├── ClusterIP :1883 (mqtt)
│   └── ClusterIP :9001 (websockets)
├── PersistentVolumeClaim: edgekit-server-data
│
└── Deployment: edgekit-client     (replicas: N)
    └── Container: edge-agent
```

The Helm chart at `helm/edgekit/` provisions all of the above resources. The client pods use the Kubernetes downward API to set `CLIENT_ID` from `metadata.name`, ensuring each replica has a unique identifier.

---

## Extending EdgeKit

The architecture is intentionally minimal. Common extensions:

- **Add authentication**: Configure Mosquitto password files or TLS certificates via a Kubernetes Secret mounted into the server container.
- **Add a dashboard**: Deploy [MQTT Explorer](https://mqtt-explorer.com/) or [Grafana + EMQX](https://docs.emqx.com/en/emqx/latest/dashboard/introduction.html) as additional pods.
- **Custom metrics**: Extend `client/src/index.js` to publish additional data (GPIO readings, custom sensors, application logs, etc.).
- **Multiple namespaces**: Deploy the chart multiple times with different `MQTT_TOPIC_PREFIX` values.
