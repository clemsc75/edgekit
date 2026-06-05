# Test EdgeKit on local k3s

This document describes the `k3s-local` test: building EdgeKit images on the current machine, importing them into the k3s containerd, and deploying the local Helm chart.

The test can be run with a single script:

```bash
chmod +x ./scripts/k3s-local.sh
./scripts/k3s-local.sh
```

If Docker, k3s, kubectl, or Helm are missing, the script attempts to install them automatically on Linux systems using `apt`, such as Ubuntu Server, Debian, or Raspberry Pi OS.

On other distributions, the script is still usable, but prerequisites must be installed manually if tools are missing.

---

## What k3s-local means

`k3s-local` means:

- the EdgeKit repository is present locally;
- Docker images are built locally;
- images are imported into the local k3s containerd;
- Helm deploys the local chart `helm/edgekit`;
- no external registry is needed.

This is not tied to a specific Ubuntu Server image. Ubuntu Server is only provided as a practical example to get started quickly.

---

## Supported systems

The script can run the test on any Linux machine or VM having:

- Docker;
- local k3s;
- kubectl configured to access the k3s cluster;
- Helm;
- root access via `sudo` or a root session.

The script can automatically install missing components only if the system uses `apt`.

Automatic installation is tested or planned for:

- Ubuntu Server LTS `amd64`;
- Ubuntu Server LTS `arm64`;
- Debian `amd64` or `arm64`;
- Raspberry Pi OS 64-bit.

Target architectures:

- `x86_64` / `amd64`;
- `aarch64` / `arm64`.

Verify your architecture:

```bash
uname -m
```

---

## Quick start

From the repository:

```bash
chmod +x ./scripts/k3s-local.sh
./scripts/k3s-local.sh
```

The script writes a timestamped log:

```text
logs/k3s-local-YYYYMMDD-HHMMSS.log
```

---

## What the script does

### 1. Detect architecture

Equivalent command:

```bash
uname -m
```

Why:

- The test is designed for AMD64 and ARM64.
- Images are built directly on the target machine.

### 2. Install base packages if necessary

If the system uses `apt`, the script installs what is missing to run the test:

```text
curl
ca-certificates
docker.io
```

Equivalent command:

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates docker.io
```

Why:

- `curl` downloads k3s and Helm scripts.
- `ca-certificates` prevents TLS errors.
- `docker.io` builds local images.

`git` is not installed by the script, as the repository must already be present to run `./scripts/k3s-local.sh`. On a fresh machine, install `git` before cloning the repository.

If the system does not use `apt`, the script does not force an incompatible installation. It displays the missing tools and stops.

### 3. Start Docker

If `systemctl` is available, the script attempts:

```bash
sudo systemctl enable --now docker
```

Then it tests:

```bash
docker info
```

If the current user does not yet have Docker access, the script automatically tries:

```bash
sudo docker info
```

Why:

- On a freshly installed machine, the user might not be in the Docker group yet.
- The test can work without needing to log out and back in.

### 4. Install k3s if necessary

If `k3s` is missing, the script executes:

```bash
curl -sfL https://get.k3s.io | sh -s - server --write-kubeconfig-mode=644
```

Why:

- k3s provides the local Kubernetes cluster.
- `--write-kubeconfig-mode=644` facilitates use by `kubectl` and Helm.

The script then prepares the kubeconfig:

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
```

### 5. Install Helm if necessary

If `helm` is missing, the script executes:

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

Why:

- EdgeKit already provides a local Helm chart in `helm/edgekit`.
- Helm manages deployment installation and updates.

### 6. Verify k3s

Equivalent commands:

```bash
kubectl get nodes
sudo k3s ctr images list
```

Why:

- `kubectl get nodes` confirms that the cluster is reachable.
- `k3s ctr images list` confirms that the k3s containerd is accessible to import images.

### 7. Build images

Equivalent commands:

```bash
docker build --tag edgekit-server:k3s-local --file ./server/Dockerfile ./server
docker build --tag edgekit-client:k3s-local --file ./client/Dockerfile ./client
```

Why:

- Images are built on the machine that will execute them.
- On AMD64, Docker produces AMD64 images.
- On ARM64, Docker produces ARM64 images.

### 8. Import images into k3s

Equivalent commands:

```bash
docker save edgekit-server:k3s-local | sudo k3s ctr images import -
docker save edgekit-client:k3s-local | sudo k3s ctr images import -
```

Why:

- Docker and k3s do not use the same image storage.
- k3s runs pods with containerd.
- The import makes local images visible to k3s without going through GHCR or Docker Hub.

### 9. Deploy with Helm

Equivalent command:

```bash
helm upgrade --install edgekit ./helm/edgekit \
  --namespace edgekit \
  --create-namespace \
  --set server.image.repository=edgekit-server \
  --set server.image.tag=k3s-local \
  --set server.image.pullPolicy=IfNotPresent \
  --set client.image.repository=edgekit-client \
  --set client.image.tag=k3s-local \
  --set client.image.pullPolicy=IfNotPresent \
  --set client.replicaCount=1 \
  --set client.publishIntervalMs=5000 \
  --wait
```

Why:

- `helm upgrade --install` installs if missing and updates if already present.
- The `edgekit` namespace isolates the test.
- `image.*` values force the use of imported local images.
- `pullPolicy=IfNotPresent` prevents k3s from looking for these test images on the Internet.

---

## Fresh Raspberry Pi example

After the first SSH login:

```bash
sudo apt-get update
sudo apt-get install -y git
git clone https://github.com/perspikapps/edgekit.git
cd edgekit
chmod +x ./scripts/k3s-local.sh
./scripts/k3s-local.sh
```

The script then installs Docker, k3s, and Helm if necessary.

For Raspberry Pi, preferably use:

- Raspberry Pi OS 64-bit;
- Ubuntu Server arm64;
- a stable power supply;
- a fast SD card or a USB SSD.

---

## Verification

View resources:

```bash
kubectl -n edgekit get pods,svc,pvc
```

View client logs:

```bash
kubectl -n edgekit logs -f -l app.kubernetes.io/component=client
```

View server logs:

```bash
kubectl -n edgekit logs -f -l app.kubernetes.io/component=server
```

The client must connect to:

```text
ws://edgekit-server:9001
```

### Optional: inspect published JSON payloads

This check lets you read the JSON payloads published by `edgekit-client` on MQTT topics.

The `edgekit-server` `Service` is a `ClusterIP`, so it is not directly exposed on the host. Use `kubectl port-forward` to access it locally.

Important:

- port `1883` is plain MQTT over TCP;
- port `9001` is MQTT over WebSocket;
- `mosquitto_sub` uses plain MQTT here, so forward port `1883`.

Terminal 1, keep this command running:

```bash
kubectl -n edgekit port-forward svc/edgekit-server 1883:1883
```

Expected output:

```text
Forwarding from 127.0.0.1:1883 -> 1883
Forwarding from [::1]:1883 -> 1883
```

Terminal 2, install `jq` to format JSON:

```bash
sudo apt-get install -y jq
```

Then subscribe to MQTT topics:

```bash
sudo docker run --rm --network host eclipse-mosquitto:2.0 \
  mosquitto_sub -h 127.0.0.1 -p 1883 -t "edgekit/#" -v \
| while read -r topic payload; do
    echo "TOPIC: $topic"
    echo "$payload" | jq .
  done
```

Why:

- `kubectl port-forward` makes the internal `Service` reachable from `127.0.0.1`;
- `mosquitto_sub` listens to all topics under `edgekit/#`;
- `jq` prints the JSON payload in a readable format.

Example output:

```text
TOPIC: edgekit/edgekit-client-7b68478f8-snhpl/metrics
{
  "clientId": "edgekit-client-7b68478f8-snhpl",
  "timestamp": "2026-06-05T17:27:55.306Z",
  "cpu": {
    "loadPercent": 5.71,
    "cores": 2
  },
  "memory": {
    "usedPercent": 93.67
  }
}
```

---

## Test options

Deploy three clients:

```bash
CLIENT_REPLICAS=3 ./scripts/k3s-local.sh
```

Change the publish interval to 10 seconds:

```bash
PUBLISH_INTERVAL_MS=10000 ./scripts/k3s-local.sh
```

Use a different image tag:

```bash
IMAGE_TAG=test-001 ./scripts/k3s-local.sh
```

Use a different namespace or release:

```bash
NAMESPACE=edgekit-dev RELEASE_NAME=edgekit-dev ./scripts/k3s-local.sh
```

---

## Replay after code modification

```bash
./scripts/k3s-local.sh
```

Why:

- images are rebuilt;
- images are reimported into k3s;
- Helm reapplies the deployment.

If the same tag is reused and Kubernetes does not restart the pods:

```bash
kubectl -n edgekit rollout restart deployment/edgekit-server
kubectl -n edgekit rollout restart deployment/edgekit-client
```

---

## Uninstallation

```bash
helm uninstall edgekit --namespace edgekit
kubectl delete namespace edgekit
```

---

## Important limitation

This mode is designed for a single-machine local test.

For a multi-node cluster or production use, publishing versioned images to a registry is preferable:

```bash
docker build -t ghcr.io/<org>/edgekit-server:1.0.0 ./server
docker build -t ghcr.io/<org>/edgekit-client:1.0.0 ./client
docker push ghcr.io/<org>/edgekit-server:1.0.0
docker push ghcr.io/<org>/edgekit-client:1.0.0
```
