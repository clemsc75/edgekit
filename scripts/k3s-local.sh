#!/usr/bin/env bash
# =============================================================================
# scripts/k3s-local.sh – Prepare prerequisites and run the local k3s test deploy
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
LOG_FILE="${LOG_DIR}/k3s-local-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "${LOG_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

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

install_apt_packages() {
  local packages=("$@")

  if [ "${#packages[@]}" -eq 0 ]; then
    return
  fi

  if ! command_exists apt-get; then
    echo "ERROR: missing required tools: ${packages[*]}" >&2
    echo "Automatic installation is only implemented for apt-based Linux systems." >&2
    echo "Install the missing tools manually, then rerun ./scripts/k3s-local.sh." >&2
    exit 1
  fi

  echo "==> Installing missing apt packages: ${packages[*]}"
  as_root apt-get update
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
      echo "Start Docker or add your user to the Docker group, then rerun ./scripts/k3s-local.sh." >&2
      exit 1
    fi
  fi
}

ensure_k3s() {
  if command_exists k3s; then
    echo "==> k3s is already installed"
  else
    ensure_download_tools

    echo "==> Installing k3s"
    curl -sfL https://get.k3s.io | sh -s - server --write-kubeconfig-mode=644
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
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

verify_architecture() {
  local arch
  arch="$(uname -m)"

  echo "==> Detected architecture: ${arch}"
  case "${arch}" in
    x86_64|amd64|aarch64|arm64)
      ;;
    *)
      echo "WARNING: architecture '${arch}' is not part of the usual EdgeKit test path."
      echo "This script is intended for amd64/x86_64 and arm64/aarch64 test machines."
      ;;
  esac
}

ensure_pi_cgroups() {
  # --- AUTOMATION: FIX CGROUPS FOR RASPBERRY PI ---
  # 1. Detect the correct path for cmdline.txt
  local cmdline_file="/boot/firmware/cmdline.txt"
  [ ! -f "${cmdline_file}" ] && cmdline_file="/boot/cmdline.txt"

  # 2. Check if cgroups are already configured
  if [ -f "${cmdline_file}" ] && ! grep -q "cgroup_enable=memory" "${cmdline_file}"; then
      echo "==> [Configuration] Automatically enabling cgroups for k3s..."
      
      # Append options to the end of the single line without adding a newline
      as_root sed -i 's/$/ cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1/' "${cmdline_file}"
      
      echo "==> [Configuration] Configuration successful. Automatic reboot required..."
      echo "==> Simply rerun this script after the reboot."
      sleep 3
      as_root reboot
      exit 0
  fi
}

verify_cluster() {
  echo "==> Verifying k3s access"

  if ! "${KUBECTL_CMD[@]}" get nodes >/dev/null 2>&1; then
    echo "ERROR: kubectl cannot reach the local k3s cluster." >&2
    echo "Check k3s status and kubeconfig, then rerun ./scripts/k3s-local.sh." >&2
    exit 1
  fi

  if ! as_root k3s ctr images list >/dev/null 2>&1; then
    echo "ERROR: k3s containerd is not reachable via 'k3s ctr'." >&2
    echo "This local test imports Docker images directly into the k3s image store." >&2
    exit 1
  fi
}

deploy_edgekit() {
  echo ""
  echo "==> Building EdgeKit images for k3s-local"
  echo "==> Writing log to ${LOG_FILE}"

  "${DOCKER_CMD[@]}" build \
    --tag "${SERVER_IMAGE}" \
    --file "${REPO_ROOT}/server/Dockerfile" \
    "${REPO_ROOT}/server"

  "${DOCKER_CMD[@]}" build \
    --tag "${CLIENT_IMAGE}" \
    --file "${REPO_ROOT}/client/Dockerfile" \
    "${REPO_ROOT}/client"

  echo ""
  echo "==> Importing images into k3s containerd"
  "${DOCKER_CMD[@]}" save "${SERVER_IMAGE}" | as_root k3s ctr images import -
  "${DOCKER_CMD[@]}" save "${CLIENT_IMAGE}" | as_root k3s ctr images import -

  echo ""
  echo "==> Deploying EdgeKit with Helm"
  helm upgrade --install "${RELEASE_NAME}" "${REPO_ROOT}/helm/edgekit" \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    --set server.image.repository=edgekit-server \
    --set server.image.tag="${IMAGE_TAG}" \
    --set server.image.pullPolicy=IfNotPresent \
    --set client.image.repository=edgekit-client \
    --set client.image.tag="${IMAGE_TAG}" \
    --set client.image.pullPolicy=IfNotPresent \
    --set client.replicaCount="${CLIENT_REPLICAS}" \
    --set client.publishIntervalMs="${PUBLISH_INTERVAL_MS}" \
    --wait

  echo ""
  echo "==> Deployment status"
  "${KUBECTL_CMD[@]}" -n "${NAMESPACE}" get pods,svc,pvc

  echo ""
  echo "EdgeKit is deployed on k3s-local."
  echo ""
  echo "Useful commands:"
  echo "  ${KUBECTL_DISPLAY} -n ${NAMESPACE} logs -f -l app.kubernetes.io/component=client"
  echo "  ${KUBECTL_DISPLAY} -n ${NAMESPACE} logs -f -l app.kubernetes.io/component=server"
  echo "  ${KUBECTL_DISPLAY} -n ${NAMESPACE} port-forward svc/${RELEASE_NAME}-server 9001:9001"
  echo "  helm uninstall ${RELEASE_NAME} --namespace ${NAMESPACE}"
  echo ""
  echo "Log:"
  echo "  ${LOG_FILE}"
}

KUBECTL_CMD=(kubectl)
KUBECTL_DISPLAY="kubectl"
DOCKER_CMD=("${DOCKER_BIN}")

echo "==> EdgeKit k3s-local test"
verify_architecture
ensure_pi_cgroups
ensure_base_packages
ensure_docker
ensure_k3s
ensure_kubectl
ensure_helm
verify_cluster
deploy_edgekit