#!/usr/bin/env bash
# =============================================================================
# scripts/k3s-master.sh – Configure the K3s Server (Master) node for EdgeKit
#
# Architecture : x86/AMD64 only
# Usage        : bash scripts/k3s-master.sh [--verbose] [--skip-firewall]
#
# Flags:
#   --verbose / -v       Print all command output to the terminal (no spinner).
#                        Useful for debugging if the spinner freezes.
#   --skip-firewall      Do NOT modify UFW/iptables rules or sysctl IP forwarding.
#                        Use this if you manage your own firewall configuration.
#
# Environment variables (all optional):
#   NAMESPACE            – Kubernetes namespace          (default: edgekit)
#   RELEASE_NAME         – Helm release name             (default: edgekit)
#   IMAGE_TAG            – Docker image tag              (default: k3s-local)
#   CLIENT_REPLICAS      – Number of client replicas     (default: 1)
#   PUBLISH_INTERVAL_MS  – Client publish interval (ms)  (default: 5000)
#   LOG_DIR              – Directory for log files        (default: <repo>/logs)
#   DOCKER_BIN           – Docker binary override        (default: docker)
#   VERBOSE              – Set to 1 to disable spinner    (same as --verbose)
#   SKIP_FIREWALL        – Set to 1 to skip firewall      (same as --skip-firewall)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# =============================================================================
# Flag parsing  (must happen before the exec-level tee redirect below)
# =============================================================================

VERBOSE="${VERBOSE:-0}"
SKIP_FIREWALL="${SKIP_FIREWALL:-0}"

_master_usage() {
  echo ""
  echo "Usage: bash scripts/k3s-master.sh [--verbose] [--skip-firewall]"
  echo ""
  echo "  --verbose,        -v   Show full command output in the terminal (debug mode)"
  echo "  --skip-firewall,  -F   Skip UFW/iptables configuration"
  echo "  --help,           -h   Show this help message"
  echo ""
  exit 0
}

for _arg in "$@"; do
  case "${_arg}" in
    --verbose|-v)        VERBOSE=1 ;;
    --skip-firewall|-F)  SKIP_FIREWALL=1 ;;
    --help|-h)           _master_usage ;;
    *) echo "ERROR: Unknown argument: ${_arg}" >&2; _master_usage ;;
  esac
done
export VERBOSE SKIP_FIREWALL

# Prevent apt-get / dpkg from opening interactive prompts (e.g. service restart
# dialogs) that would be hidden behind the spinner and stall the script.
export DEBIAN_FRONTEND=noninteractive

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
# All script-level echo / print_section output goes to terminal + log via tee.
# run_with_spinner bypasses this by writing command output directly to LOG_FILE.
exec > >(tee -a "${LOG_FILE}") 2>&1

# =============================================================================
# Load spinner library and register signal traps
# =============================================================================

# shellcheck source=scripts/lib/spinner.sh
source "${REPO_ROOT}/scripts/lib/spinner.sh"
spinner_register_traps

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
# Firewall configuration (UFW / IP forwarding)
# =============================================================================

# K3s master required open ports:
#   6443/TCP  – K3s API Server  (workers call in, kubectl calls in)
#   8472/UDP  – Flannel VXLAN   (inter-node pod traffic)
#  10250/TCP  – Kubelet API     (metrics, exec, log streaming)

ensure_firewall_rules() {
  if [ "${SKIP_FIREWALL:-0}" = "1" ]; then
    echo "==> --skip-firewall set: skipping firewall configuration"
    return
  fi

  print_section "CONFIGURING FIREWALL RULES FOR K3s (MASTER)"

  # 1. Enable IP forwarding – required for Flannel to route packets between pods
  local sysctl_conf="/etc/sysctl.d/99-k3s-edgekit.conf"
  if [ -f "${sysctl_conf}" ] && grep -q "net.ipv4.ip_forward=1" "${sysctl_conf}" 2>/dev/null; then
    echo "==> IP forwarding already configured (${sysctl_conf})"
  else
    echo "==> Enabling IP forwarding..."
    echo "net.ipv4.ip_forward=1" | as_root tee "${sysctl_conf}" >/dev/null
    as_root sysctl --system >/dev/null 2>&1 || true
    echo "    Done."
  fi

  # 2. UFW rules
  # --- Check A: does the ufw binary exist? ---
  if ! command -v ufw >/dev/null 2>&1; then
    echo "==> UFW is not installed or not in PATH – skipping UFW configuration"
    echo "    (K3s ports to open manually if needed: 6443/tcp, 8472/udp, 10250/tcp)"
  else
    # --- Check B: is ufw currently active? ---
    # IMPORTANT: we run 'ufw status' first with '|| true' so that ANY failure
    # (permission denied, ufw daemon not running, etc.) is silently swallowed
    # and never triggers 'set -e'. Only then do we grep the captured output.
    local _ufw_raw
    _ufw_raw=$(as_root ufw status 2>/dev/null || true)

    if ! echo "${_ufw_raw}" | grep -q "Status: active"; then
      echo "==> UFW is installed but not active – skipping UFW rules"
      echo "    (Tip: if you activate UFW later, rerun this script or open ports manually)"
    else
      echo "==> UFW is active – adding K3s required port rules..."
      # Each rule uses '|| true': adding an already-existing rule exits 0 in newer
      # UFW but may exit 1 on older versions, so we never let it abort the script.
      as_root ufw allow 6443/tcp  comment 'K3s API Server'    >/dev/null 2>&1 || true
      as_root ufw allow 8472/udp  comment 'K3s Flannel VXLAN' >/dev/null 2>&1 || true
      as_root ufw allow 10250/tcp comment 'K3s Kubelet API'   >/dev/null 2>&1 || true
      as_root ufw reload >/dev/null 2>&1 || true
      echo "    Rules applied (6443/tcp, 8472/udp, 10250/tcp) and UFW reloaded."
    fi
  fi

  # 3. iptables FORWARD rules for Flannel pod CIDR (belt-and-suspenders)
  # UFW's DEFAULT_FORWARD_POLICY=DROP can override K3s/Flannel's own FORWARD rules.
  # We insert explicit ACCEPT entries for the K3s pod CIDR (10.42.0.0/16).
  # 'if ! iptables -C ...' is safe with set -e because 'if' conditions are exempt.
  if ! command -v iptables >/dev/null 2>&1; then
    echo "==> iptables not found – skipping FORWARD rules"
  else
    if ! as_root iptables -C FORWARD -s 10.42.0.0/16 -j ACCEPT >/dev/null 2>&1; then
      as_root iptables -I FORWARD -s 10.42.0.0/16 -j ACCEPT >/dev/null 2>&1 || true
      as_root iptables -I FORWARD -d 10.42.0.0/16 -j ACCEPT >/dev/null 2>&1 || true
      echo "==> iptables FORWARD rules added for K3s pod CIDR (10.42.0.0/16)"
    else
      echo "==> iptables FORWARD rules already present – skipping"
    fi
  fi

  echo "==> Firewall configuration complete."
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

  echo "==> Installing: ${packages[*]}"
  run_with_spinner "Updating apt package index" \
    as_root apt-get update -qq
  run_with_spinner "Installing: ${packages[*]}" \
    as_root apt-get install -y -qq \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" \
      "${packages[@]}"
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
    echo "==> K3s is already installed – ensuring service is running"
  else
    ensure_download_tools

    # _do_install_k3s_server is a helper so run_with_spinner can wrap the pipe
    _do_install_k3s_server() {
      curl -sfL https://get.k3s.io | sh -s - server \
        --write-kubeconfig-mode=644 \
        --cluster-init
    }
    run_with_spinner "Installing K3s server" _do_install_k3s_server
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

  _do_install_helm() {
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  }
  run_with_spinner "Installing Helm" _do_install_helm
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
  # Helper wrapped by the spinner so the retry loop output goes to the log
  _wait_for_cluster() {
    local retries=10
    local wait_secs=6
    for i in $(seq 1 "${retries}"); do
      if "${KUBECTL_CMD[@]}" get nodes >/dev/null 2>&1; then
        echo "Cluster reachable after ${i} attempt(s)."
        return 0
      fi
      echo "  Waiting for k3s to be ready... (${i}/${retries})"
      sleep "${wait_secs}"
      if [ "${i}" -eq "${retries}" ]; then
        echo "ERROR: kubectl cannot reach the local k3s cluster after ${retries} attempts." >&2
        return 1
      fi
    done
  }

  run_with_spinner "Waiting for K3s cluster to be ready (up to 60s)" _wait_for_cluster

  if ! as_root k3s ctr images list >/dev/null 2>&1; then
    echo "ERROR: k3s containerd is not reachable via 'k3s ctr'." >&2
    exit 1
  fi
  echo "==> Cluster and containerd are reachable"
}

# =============================================================================
# Build & deploy EdgeKit server
# =============================================================================

deploy_edgekit_server() {
  print_section "BUILDING & DEPLOYING EDGEKIT SERVER IMAGE"
  echo "  Log file: ${LOG_FILE}"

  # Helper functions so run_with_spinner can wrap pipes and multi-command steps
  _do_docker_build_server() {
    "${DOCKER_CMD[@]}" build \
      --tag "${SERVER_IMAGE}" \
      --file "${REPO_ROOT}/server/Dockerfile" \
      "${REPO_ROOT}/server"
  }

  _do_import_server_image() {
    # Import explicitly into the k8s.io containerd namespace.
    # K3s pulls images for Pods from k8s.io, not from the default namespace.
    # Without -n k8s.io the image lands in 'default' and Test 4 sees an empty
    # list, causing a false-negative FAIL even when the pod starts correctly.
    #
    # IMPORTANT: we deliberately split the pipe into two steps (save to a temp
    # file, then import) instead of using a single pipe
    #   docker save | k3s ctr import -
    # Reason: 'as_root' is a shell function. Piping into a shell function causes
    # bash to run it in a subshell where 'set -e' is active. If k3s ctr import
    # exits non-zero (e.g. disk full, bad format), 'set -e' kills the subshell
    # before the spinner's '|| exit_code=$?' can capture the code, making the
    # failure silent and leaving the spinner running forever.
    local _tmptar
    _tmptar=$(mktemp /tmp/edgekit-server-XXXXXX.tar)
    "${DOCKER_CMD[@]}" save --output "${_tmptar}" "${SERVER_IMAGE}"
    as_root k3s ctr -n k8s.io images import "${_tmptar}"
    rm -f "${_tmptar}"
  }

  _do_helm_deploy_server() {
    # Zero-Touch scheduling is injected entirely via CLI overrides so that
    # values.yaml stays pristine and the chart remains a generic artefact.
    #
    # The nodeSelector key "edgekit.io/role" contains a dot, which Helm's --set
    # normally treats as a YAML path separator. Two safe approaches exist:
    #
    #   A) --set-json  → accepts raw JSON, no escaping needed   (Helm ≥ 3.10)
    #   B) --set with backslash-escaped dot                      (all Helm 3.x)
    #        --set 'client.nodeSelector.edgekit\.io/role=worker'
    #
    # We detect the Helm minor version at runtime and pick the right flag.

    local _helm_minor
    _helm_minor=$(helm version --short 2>/dev/null \
      | grep -oE 'v3\.[0-9]+' | grep -oE '[0-9]+$' || echo "0")

    local _node_selector_flag
    local _node_selector_val
    if [ "${_helm_minor}" -ge 10 ] 2>/dev/null; then
      # --set-json is cleaner and handles special chars natively (Helm ≥ 3.10)
      _node_selector_flag="--set-json"
      _node_selector_val='client.nodeSelector={"edgekit.io/role":"worker"}'
    else
      # Backslash-escaped dot works on ALL Helm 3.x versions
      _node_selector_flag="--set"
      _node_selector_val='client.nodeSelector.edgekit\.io/role=worker'
    fi

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
      "${_node_selector_flag}" "${_node_selector_val}"
    # NOTE: --wait is intentionally omitted.
    # The client pod has nodeSelector: {edgekit.io/role: worker} and will stay
    # Pending on the Master (no matching label). --wait would block until Helm
    # times out waiting for the client Deployment to become Ready, crashing the
    # script. The server pod is verified separately by run_server_tests().
  }

  run_with_spinner "Building Docker server image" _do_docker_build_server
  run_with_spinner "Importing server image into containerd" _do_import_server_image
  run_with_spinner "Deploying Helm chart (server only)" _do_helm_deploy_server

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
  # Because --wait was removed from the Helm deploy (the client pod is
  # intentionally Pending and would cause --wait to time out), we poll
  # here for up to 60 s until the server pod reaches Running state.
  echo "[TEST 1/4] Server pod is running..."
  local server_pod=""
  local pod_status=""
  local _wait_secs=0
  local _max_wait_secs=180

  while [ "${_wait_secs}" -lt "${_max_wait_secs}" ]; do
    server_pod=$("${KUBECTL_CMD[@]}" -n "${NAMESPACE}" get pods \
      -l "app.kubernetes.io/component=server" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "${server_pod}" ]; then
      pod_status=$("${KUBECTL_CMD[@]}" -n "${NAMESPACE}" get pod "${server_pod}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
      if [ "${pod_status}" = "Running" ]; then
        break
      fi
    fi
    echo "    Waiting for server pod... (${_wait_secs}s elapsed)"
    sleep 5
    _wait_secs=$((_wait_secs + 5))
  done

  if [ -z "${server_pod}" ]; then
    echo "  FAIL – No server pod found in namespace '${NAMESPACE}' after ${_max_wait_secs}s"
    failed=$((failed + 1))
  elif [ "${pod_status}" != "Running" ]; then
    echo "  FAIL – Pod '${server_pod}' status is '${pod_status}' after ${_max_wait_secs}s (expected Running)"
    failed=$((failed + 1))
  else
    echo "  PASS – Pod '${server_pod}' is Running"
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

  # Test 4 – Server image is reachable in containerd
  #
  # Root cause of the historic false-negative:
  #   'k3s ctr images import -' (without -n) places the image in the 'default'
  #   containerd namespace. K3s pulls images for Pods from 'k8s.io'. The image
  #   was therefore invisible to Test 4 even though the pod was Running.
  #
  # Fix applied at import time: 'k3s ctr -n k8s.io images import <file>'.
  #   After the fix, the image lands directly in k8s.io → PASS on the first try.
  #
  # Defensive 3-level logic (handles edge cases and prior imports without -n):
  #   Level 1 – PASS   : image found in k8s.io  (expected path post-fix)
  #   Level 2 – WARN   : image NOT in k8s.io but pod is Running right now
  #                       (imported without -n on a previous run, K3s has used it)
  #   Level 3 – FAIL   : image absent from both namespaces AND pod is not Running
  #                       (genuine missing-image situation)
  echo "[TEST 4/4] Server image is present in containerd (k8s.io namespace)..."

  local img_k8s_io
  img_k8s_io=$(as_root k3s ctr -n k8s.io images list 2>/dev/null) || true

  if echo "${img_k8s_io}" | grep -q "edgekit-server"; then
    echo "  PASS – Server image found in containerd (k8s.io namespace)"
  else
    # Fallback: check the default namespace (image imported without -n on a previous run)
    local img_default
    img_default=$(as_root k3s ctr images list 2>/dev/null) || true

    # Re-read the pod status NOW, not from Test 1's stale capture:
    # between Test 1 (up to 180s wait) and Test 4, the pod may have changed state.
    local _current_pod_status=""
    if [ -n "${server_pod}" ]; then
      _current_pod_status=$("${KUBECTL_CMD[@]}" -n "${NAMESPACE}" get pod "${server_pod}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    fi

    if echo "${img_default}" | grep -q "edgekit-server" && [ "${_current_pod_status}" = "Running" ]; then
      echo "  WARN – Image is in containerd 'default' namespace (not k8s.io), but pod is Running."
      echo "         Re-run the script to re-import into k8s.io and clear this warning."
      # Not a failure: the cluster is working correctly.
    else
      echo "  FAIL – Server image not found in containerd (checked k8s.io and default namespaces)"
      failed=$((failed + 1))
    fi
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
if [ "${VERBOSE}" = "1" ]; then
echo "  Mode    : VERBOSE (full output)"
else
echo "  Mode    : Spinner (full log: ${LOG_FILE})"
fi
if [ "${SKIP_FIREWALL}" = "1" ]; then
echo "  Firewall: SKIPPED (--skip-firewall)"
fi
echo "============================================================"

verify_architecture
ensure_firewall_rules
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
