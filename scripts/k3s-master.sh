#!/usr/bin/env bash
# =============================================================================
# scripts/k3s-master.sh – Configure the K3s Server (Master) node for EdgeKit
#
# Architecture : x86/AMD64 only
# Usage        : bash scripts/k3s-master.sh
#
# Environment variables (all optional):
#   NAMESPACE            – Kubernetes namespace          (default: edgekit)
#   RELEASE_NAME         – Helm release name             (default: edgekit)
#   IMAGE_TAG            – Docker image tag              (default: k3s-local)
#   CLIENT_REPLICAS      – Number of client replicas     (default: 1)
#   PUBLISH_INTERVAL_MS  – Client publish interval (ms)  (default: 5000)
#   LOG_DIR              – Directory for log files        (default: <repo>/logs)
#   DOCKER_BIN           – Docker binary override        (default: docker)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NAMESPACE="${NAMESPACE:-edgekit}"
RELEASE_NAME="${RELEASE_NAME:-edgekit}"
IMAGE_TAG="${IMAGE_TAG:-k3s-local}"
CLIENT_REPLICAS="${CLIENT_REPLICAS:-1}"
PUBLISH_INTERVAL_MS="${PUBLISH_INTERVAL_MS:-5000}"
LOG_DIR="${LOG_DIR:-${REPO_ROOT}/logs}"
DOCKER_BIN="${DOCKER_BIN:-docker}"

SERVER_IMAGE="edgekit-server:${IMAGE_TAG}"
CLIENT_IMAGE="edgekit-client:${IMAGE_TAG}"
LOG_FILE="${LOG_DIR}/k3s-master-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "${LOG_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

# =============================================================================
# Utility helpers
# =============================================================================

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    echo "ERROR: this command needs root privileges and 'sudo' is not installed: $*" >&2
    exit 1
  fi
}

print_section() {
  echo ""
  echo "============================================================"
  echo "  $*"
  echo "============================================================"
}

# =============================================================================
# Architecture check (x86/AMD64 only for master)
# =============================================================================

verify_architecture() {
  local arch
  arch="$(uname -m)"

  echo "==> Detected architecture: ${arch}"
  case "${arch}" in
    x86_64|amd64)
      echo "==> Architecture OK (x86/AMD64)"
      ;;
    *)
      echo "ERROR: This master script is intended for x86/AMD64 machines only." >&2
      echo "       Detected: ${arch}" >&2
      echo "       For ARM nodes, use k3s-worker.sh instead." >&2
      exit 1
      ;;
  esac
}

# =============================================================================
# Package / tool installation helpers
# =============================================================================

install_apt_packages() {
  local packages=("$@")

  if [ "${#packages[@]}" -eq 0 ]; then
    return
  fi

  if ! command_exists apt-get; then
    echo "ERROR: missing required tools: ${packages[*]}" >&2
    echo "Automatic installation is only implemented for apt-based Linux systems." >&2
    echo "Install the missing tools manually, then rerun ./scripts/k3s-master.sh." >&2
    exit 1
  fi

  echo "==> Installing missing apt packages: ${packages[*]}"
  as_root apt-get update -qq
  as_root apt-get install -y "${packages[@]}"
}

ensure_download_tools() {
  local packages=()

  command_exists curl || packages+=(curl)

  if command_exists apt-get && ! dpkg-query -W -f='${Status}' ca-certificates >/dev/null 2>&1; then
    packages+=(ca-certificates)
  fi

  install_apt_packages "${packages[@]}"
}

ensure_base_packages() {
  local packages=()

  command_exists docker || packages+=(docker.io)

  if [ "${#packages[@]}" -gt 0 ] && command_exists apt-get && ! dpkg-query -W -f='${Status}' ca-certificates >/dev/null 2>&1; then
    packages+=(ca-certificates)
  fi

  install_apt_packages "${packages[@]}"
}

ensure_docker() {
  if ! command_exists docker; then
    install_apt_packages docker.io
  fi

  if command_exists systemctl; then
    as_root systemctl enable --now docker >/dev/null 2>&1 || true
  fi

  DOCKER_CMD=("${DOCKER_BIN}")
  if ! "${DOCKER_CMD[@]}" info >/dev/null 2>&1; then
    if command_exists sudo && sudo docker info >/dev/null 2>&1; then
      DOCKER_CMD=(sudo docker)
    else
      echo "ERROR: Docker is installed but the daemon is not reachable." >&2
      echo "Start Docker or add your user to the Docker group, then rerun ./scripts/k3s-master.sh." >&2
      exit 1
    fi
  fi
}

ensure_k3s_server() {
  if command_exists k3s; then
    echo "==> k3s is already installed"
  else
    ensure_download_tools

    echo "==> Installing k3s (server mode)"
    curl -sfL https://get.k3s.io | sh -s - server \
      --write-kubeconfig-mode=644 \
      --cluster-init
  fi

  if command_exists systemctl; then
    as_root systemctl enable --now k3s >/dev/null 2>&1 || true
  fi

  if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    echo "==> Preparing kubeconfig for the current user"
    mkdir -p "${HOME}/.kube"
    as_root cp /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config"
    as_root chown "$(id -u):$(id -g)" "${HOME}/.kube/config"
  fi
}

ensure_kubectl() {
  if command_exists kubectl; then
    KUBECTL_CMD=(kubectl)
    KUBECTL_DISPLAY="kubectl"
    return
  fi

  if command_exists k3s; then
    KUBECTL_CMD=(k3s kubectl)
    KUBECTL_DISPLAY="k3s kubectl"
    return
  fi

  echo "ERROR: kubectl is missing and k3s is not available." >&2
  exit 1
}

ensure_helm() {
  if command_exists helm; then
    echo "==> Helm is already installed"
    return
  fi

  ensure_download_tools

  echo "==> Installing Helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

# =============================================================================
# Version reporting
# =============================================================================

print_versions() {
  print_section "TECHNOLOGY VERSIONS ON MASTER NODE"

  echo ""
  echo "--- Operating System ---"
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "  OS Name    : ${PRETTY_NAME:-N/A}"
    echo "  OS Version : ${VERSION:-N/A}"
    echo "  OS ID      : ${ID:-N/A}"
  else
    echo "  OS         : $(uname -s) $(uname -r)"
  fi
  echo "  Kernel     : $(uname -r)"
  echo "  Hostname   : $(hostname)"

  echo ""
  echo "--- Hardware ---"
  echo "  Architecture : $(uname -m)"
  if command_exists nproc; then
    echo "  CPU Cores    : $(nproc)"
  fi
  if [ -f /proc/meminfo ]; then
    local total_mem
    total_mem=$(awk '/MemTotal/ { printf "%.0f MB", $2/1024 }' /proc/meminfo)
    echo "  Total RAM    : ${total_mem}"
  fi

  echo ""
  echo "--- Runtime Versions ---"

  if command_exists node; then
    echo "  Node.js    : $(node --version 2>/dev/null || echo 'N/A')"
  else
    echo "  Node.js    : not installed"
  fi

  if command_exists npm; then
    echo "  npm        : $(npm --version 2>/dev/null || echo 'N/A')"
  else
    echo "  npm        : not installed"
  fi

  if command_exists python3; then
    echo "  Python3    : $(python3 --version 2>/dev/null || echo 'N/A')"
  elif command_exists python; then
    echo "  Python     : $(python --version 2>/dev/null || echo 'N/A')"
  else
    echo "  Python     : not installed"
  fi

  echo ""
  echo "--- Container & Orchestration ---"

  if command_exists docker; then
    echo "  Docker     : $(docker --version 2>/dev/null || echo 'N/A')"
    echo "  Docker API : $(docker version --format '{{.Server.APIVersion}}' 2>/dev/null || echo 'N/A')"
  else
    echo "  Docker     : not installed"
  fi

  if command_exists k3s; then
    echo "  K3s        : $(k3s --version 2>/dev/null | head -1 || echo 'N/A')"
  else
    echo "  K3s        : not installed"
  fi

  if command_exists kubectl; then
    echo "  kubectl    : $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1 || echo 'N/A')"
  elif command_exists k3s; then
    echo "  kubectl    : $(k3s kubectl version --client --short 2>/dev/null || echo 'N/A') (via k3s)"
  else
    echo "  kubectl    : not installed"
  fi

  if command_exists helm; then
    echo "  Helm       : $(helm version --short 2>/dev/null || echo 'N/A')"
  else
    echo "  Helm       : not installed"
  fi

  if command_exists containerd; then
    echo "  containerd : $(containerd --version 2>/dev/null || echo 'N/A')"
  fi

  echo ""
  echo "--- Network ---"
  if command_exists ip; then
    echo "  Local IPs  :"
    ip -4 addr show scope global | awk '/inet / { split($2, a, "/"); printf "    - %s\n", a[1] }'
  elif command_exists ifconfig; then
    echo "  Local IPs  :"
    ifconfig | awk '/inet / && !/127.0.0.1/ { print "    -", $2 }'
  fi

  echo ""
}

# =============================================================================
# Cluster verification
# =============================================================================

verify_cluster() {
  echo "==> Verifying k3s cluster access"

  local retries=10
  local wait=6
  for i in $(seq 1 "${retries}"); do
    if "${KUBECTL_CMD[@]}" get nodes >/dev/null 2>&1; then
      echo "==> Cluster is reachable"
      break
    fi
    echo "    Waiting for k3s to be ready... (${i}/${retries})"
    sleep "${wait}"
    if [ "${i}" -eq "${retries}" ]; then
      echo "ERROR: kubectl cannot reach the local k3s cluster after ${retries} attempts." >&2
      exit 1
    fi
  done

  if ! as_root k3s ctr images list >/dev/null 2>&1; then
    echo "ERROR: k3s containerd is not reachable via 'k3s ctr'." >&2
    exit 1
  fi
}

# =============================================================================
# Build & deploy EdgeKit server
# =============================================================================

deploy_edgekit_server() {
  print_section "BUILDING & DEPLOYING EDGEKIT SERVER IMAGE"

  echo "==> Building EdgeKit server image: ${SERVER_IMAGE}"
  echo "==> Writing log to ${LOG_FILE}"

  "${DOCKER_CMD[@]}" build \
    --tag "${SERVER_IMAGE}" \
    --file "${REPO_ROOT}/server/Dockerfile" \
    "${REPO_ROOT}/server"

  echo ""
  echo "==> Importing server image into k3s containerd"
  "${DOCKER_CMD[@]}" save "${SERVER_IMAGE}" | as_root k3s ctr images import -

  echo ""
  echo "==> Deploying EdgeKit with Helm (server only)"
  helm upgrade --install "${RELEASE_NAME}" "${REPO_ROOT}/helm/edgekit" \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    --set server.image.repository=edgekit-server \
    --set server.image.tag="${IMAGE_TAG}" \
    --set server.image.pullPolicy=IfNotPresent \
    --set client.replicaCount=0 \
    --wait

  echo ""
  echo "==> Deployment status"
  "${KUBECTL_CMD[@]}" -n "${NAMESPACE}" get pods,svc,pvc
}

# =============================================================================
# Automated tests
# =============================================================================

run_server_tests() {
  print_section "RUNNING SERVER VALIDATION TESTS"

  local failed=0

  # Test 1 – Server pod is running
  echo "[TEST 1/4] Server pod is running..."
  local server_pod
  server_pod=$("${KUBECTL_CMD[@]}" -n "${NAMESPACE}" get pods \
    -l "app.kubernetes.io/component=server" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [ -z "${server_pod}" ]; then
    echo "  FAIL – No server pod found in namespace '${NAMESPACE}'"
    failed=$((failed + 1))
  else
    local pod_status
    pod_status=$("${KUBECTL_CMD[@]}" -n "${NAMESPACE}" get pod "${server_pod}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [ "${pod_status}" = "Running" ]; then
      echo "  PASS – Pod '${server_pod}' is Running"
    else
      echo "  FAIL – Pod '${server_pod}' status is '${pod_status}' (expected Running)"
      failed=$((failed + 1))
    fi
  fi

  # Test 2 – Server service exists
  echo "[TEST 2/4] Server service exists..."
  if "${KUBECTL_CMD[@]}" -n "${NAMESPACE}" get svc "${RELEASE_NAME}-server" >/dev/null 2>&1; then
    echo "  PASS – Service '${RELEASE_NAME}-server' found"
  else
    echo "  FAIL – Service '${RELEASE_NAME}-server' not found"
    failed=$((failed + 1))
  fi

  # Test 3 – k3s node is in Ready state
  echo "[TEST 3/4] K3s master node is Ready..."
  local node_ready
  node_ready=$("${KUBECTL_CMD[@]}" get nodes \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
  if [ "${node_ready}" = "True" ]; then
    echo "  PASS – Master node is Ready"
  else
    echo "  FAIL – Master node not Ready (status: ${node_ready})"
    failed=$((failed + 1))
  fi

  # Test 4 – Docker image exists in k3s containerd store
  echo "[TEST 4/4] Server image is present in k3s containerd..."
  if as_root k3s ctr images list 2>/dev/null | grep -q "edgekit-server"; then
    echo "  PASS – Server image found in containerd store"
  else
    echo "  FAIL – Server image NOT found in containerd store"
    failed=$((failed + 1))
  fi

  echo ""
  if [ "${failed}" -eq 0 ]; then
    echo "==> All tests PASSED ✓"
  else
    echo "==> ${failed} test(s) FAILED ✗"
    echo "==> Check logs: ${LOG_FILE}"
    exit 1
  fi
}

# =============================================================================
# Print worker connection info
# =============================================================================

print_worker_join_info() {
  print_section "WORKER NODE CONNECTION INFO"

  local token
  token=$(as_root cat /var/lib/rancher/k3s/server/node-token 2>/dev/null || echo "UNAVAILABLE")

  # Prefer the first non-loopback IPv4 address
  local master_ip="UNAVAILABLE"
  if command_exists ip; then
    master_ip=$(ip -4 addr show scope global | awk '/inet / { split($2, a, "/"); print a[1]; exit }')
  elif command_exists hostname; then
    master_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi

  echo ""
  echo "  Share the following information with the Worker node operator:"
  echo ""
  echo "  ┌─────────────────────────────────────────────────────────────┐"
  echo "  │  MASTER_IP    = ${master_ip}"
  echo "  │  K3S_TOKEN    = ${token}"
  echo "  └─────────────────────────────────────────────────────────────┘"
  echo ""
  echo "  On the Worker machine, run:"
  echo ""
  echo "    bash scripts/k3s-worker.sh \\"
  echo "      --master-ip   \"${master_ip}\" \\"
  echo "      --token       \"${token}\""
  echo ""
  echo "  NOTE: Both machines must be on the same network (LAN / Ethernet cable)."
  echo "        Make sure port 6443 (K3s API) is not blocked by a firewall."
  echo ""
  echo "  Useful commands:"
  echo "    ${KUBECTL_DISPLAY} get nodes -o wide        # list all nodes"
  echo "    ${KUBECTL_DISPLAY} -n ${NAMESPACE} get pods,svc"
  echo "    ${KUBECTL_DISPLAY} -n ${NAMESPACE} logs -f -l app.kubernetes.io/component=server"
  echo "    ${KUBECTL_DISPLAY} -n ${NAMESPACE} port-forward svc/${RELEASE_NAME}-server 9001:9001"
  echo "    helm uninstall ${RELEASE_NAME} --namespace ${NAMESPACE}"
  echo ""
  echo "  Log file: ${LOG_FILE}"
}

# =============================================================================
# Main
# =============================================================================

KUBECTL_CMD=(kubectl)
KUBECTL_DISPLAY="kubectl"
DOCKER_CMD=("${DOCKER_BIN}")

echo ""
echo "============================================================"
echo "  EdgeKit – K3s Master (Server) Node Setup"
echo "============================================================"

verify_architecture
ensure_base_packages
ensure_docker
ensure_k3s_server
ensure_kubectl
ensure_helm
print_versions
verify_cluster
deploy_edgekit_server
run_server_tests
print_worker_join_info
