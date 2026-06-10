#!/usr/bin/env bash
# =============================================================================
# scripts/k3s-worker.sh – Configure a K3s Worker node and join an EdgeKit cluster
#
# Architecture : ARM (aarch64/arm64/armv7l) or x86/AMD64
# Usage        : bash scripts/k3s-worker.sh --master-ip <IP> --token <TOKEN> [OPTIONS]
#
# Required arguments:
#   --master-ip <IP>     IP address of the K3s master node
#   --token <TOKEN>      Node token from the master (k3s-master.sh output)
#
# Optional flags:
#   --verbose, -v        Print all command output to the terminal (no spinner).
#                        Useful for debugging if the spinner freezes.
#   --skip-firewall, -F  Do NOT modify UFW/iptables rules or sysctl IP forwarding.
#                        Use this if you manage your own firewall configuration.
#
# Optional environment variables:
#   NAMESPACE            – Kubernetes namespace          (default: edgekit)
#   RELEASE_NAME         – Helm release name             (default: edgekit)
#   IMAGE_TAG            – Docker image tag for client   (default: k3s-local)
#   LOG_DIR              – Directory for log files        (default: <repo>/logs)
#   DOCKER_BIN           – Docker binary override        (default: docker)
#   VERBOSE              – Set to 1 to disable spinner    (same as --verbose)
#   SKIP_FIREWALL        – Set to 1 to skip firewall      (same as --skip-firewall)
#
# Note: CLIENT_REPLICAS and PUBLISH_INTERVAL_MS are Helm values set by the
# Master script (k3s-master.sh). They have no effect on the Worker script.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# =============================================================================
# Flag & argument parsing  (must happen before the exec-level tee redirect)
# =============================================================================

VERBOSE="${VERBOSE:-0}"
SKIP_FIREWALL="${SKIP_FIREWALL:-0}"
MASTER_IP=""
K3S_TOKEN=""

usage() {
  echo ""
  echo "Usage: bash scripts/k3s-worker.sh --master-ip <IP> --token <TOKEN> [--verbose] [--skip-firewall]"
  echo ""
  echo "Required arguments:"
  echo "  --master-ip <IP>     IP address of the K3s master node"
  echo "  --token <TOKEN>      Join token from the master (shown by k3s-master.sh)"
  echo ""
  echo "Optional flags:"
  echo "  --verbose,       -v  Show full command output (debug mode, no spinner)"
  echo "  --skip-firewall, -F  Skip UFW/iptables configuration"
  echo ""
  echo "Optional environment variables:"
  echo "  NAMESPACE, RELEASE_NAME, IMAGE_TAG,"
  echo "  LOG_DIR, DOCKER_BIN, VERBOSE, SKIP_FIREWALL"
  echo "  (CLIENT_REPLICAS and PUBLISH_INTERVAL_MS are Helm values; set them on the Master)"
  echo ""
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --master-ip)
      MASTER_IP="$2"
      shift 2
      ;;
    --token)
      K3S_TOKEN="$2"
      shift 2
      ;;
    --verbose|-v)
      VERBOSE=1
      shift
      ;;
    --skip-firewall|-F)
      SKIP_FIREWALL=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage
      ;;
  esac
done

export VERBOSE SKIP_FIREWALL

if [ -z "${MASTER_IP}" ] || [ -z "${K3S_TOKEN}" ]; then
  echo "ERROR: --master-ip and --token are both required." >&2
  usage
fi

# Prevent apt-get / dpkg from opening interactive prompts hidden by the spinner.
export DEBIAN_FRONTEND=noninteractive

NAMESPACE="${NAMESPACE:-edgekit}"
RELEASE_NAME="${RELEASE_NAME:-edgekit}"
IMAGE_TAG="${IMAGE_TAG:-k3s-local}"
LOG_DIR="${LOG_DIR:-${REPO_ROOT}/logs}"
DOCKER_BIN="${DOCKER_BIN:-docker}"

CLIENT_IMAGE="edgekit-client:${IMAGE_TAG}"
LOG_FILE="${LOG_DIR}/k3s-worker-$(date +%Y%m%d-%H%M%S).log"

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
# Architecture check (ARM or x86/AMD64 accepted for worker)
# =============================================================================

verify_architecture() {
  local arch
  arch="$(uname -m)"

  echo "==> Detected architecture: ${arch}"
  case "${arch}" in
    x86_64|amd64)
      echo "==> Architecture OK (x86/AMD64)"
      ARCH_LABEL="amd64"
      ;;
    aarch64|arm64)
      echo "==> Architecture OK (ARM64)"
      ARCH_LABEL="arm64"
      ;;
    armv7l|armhf)
      echo "==> Architecture OK (ARMv7)"
      ARCH_LABEL="arm"
      ;;
    *)
      echo "WARNING: Unsupported architecture '${arch}'."
      echo "         This script is intended for x86_64, arm64, or armv7l."
      ARCH_LABEL="unknown"
      ;;
  esac
}

# =============================================================================
# Raspberry Pi cgroup fix (needed for K3s on ARM boards)
# =============================================================================

ensure_pi_cgroups() {
  local arch
  arch="$(uname -m)"

  # Only apply cgroup fix on ARM architectures
  case "${arch}" in
    aarch64|arm64|armv7l|armhf) ;;
    *) return ;;
  esac

  local cmdline_file="/boot/firmware/cmdline.txt"
  [ ! -f "${cmdline_file}" ] && cmdline_file="/boot/cmdline.txt"

  if [ -f "${cmdline_file}" ] && ! grep -q "cgroup_enable=memory" "${cmdline_file}"; then
    echo "==> [ARM] Enabling cgroups in boot configuration for K3s compatibility..."
    as_root sed -i 's/$/ cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1/' "${cmdline_file}"
    echo "==> Cgroup configuration applied. A reboot is required."
    echo "==> Please reboot and rerun this script."
    sleep 3
    as_root reboot
    exit 0
  fi
}

# =============================================================================
# Firewall configuration (UFW / IP forwarding)
# =============================================================================

# K3s worker required open ports:
#   8472/UDP  – Flannel VXLAN   (inter-node pod traffic)
#  10250/TCP  – Kubelet API     (metrics, exec, log streaming from master)
# NOTE: port 6443 is called OUT by the worker to the master; ufw allows
# outbound connections by default, so no rule is needed for it.

ensure_firewall_rules() {
  if [ "${SKIP_FIREWALL:-0}" = "1" ]; then
    echo "==> --skip-firewall set: skipping firewall configuration"
    return
  fi

  print_section "CONFIGURING FIREWALL RULES FOR K3s (WORKER)"

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
    echo "    (K3s ports to open manually if needed: 8472/udp, 10250/tcp)"
  else
    # --- Check B: is ufw currently active? ---
    # IMPORTANT: we run 'ufw status' first with '|| true' so that ANY failure
    # (permission denied, ufw daemon not running, etc.) is silently swallowed
    # and never triggers 'set -e'. Only then do we grep the captured output.
    local _ufw_raw

    if ! echo "${_ufw_raw}" | grep -q "Status: active"; then
      echo "==> UFW is installed but not active – skipping UFW rules"
      echo "    (Tip: if you activate UFW later, rerun this script or open ports manually)"
    else
      echo "==> UFW is active – adding K3s required port rules..."
      # Each rule uses '|| true': adding an already-existing rule exits 0 in newer
      # UFW but may exit 1 on older versions, so we never let it abort the script.
      as_root ufw allow 8472/udp  comment 'K3s Flannel VXLAN' >/dev/null 2>&1 || true
      as_root ufw allow 10250/tcp comment 'K3s Kubelet API'   >/dev/null 2>&1 || true
      as_root ufw reload >/dev/null 2>&1 || true
      echo "    Rules applied (8472/udp, 10250/tcp) and UFW reloaded."
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
    echo "Install the missing tools manually, then rerun ./scripts/k3s-worker.sh." >&2
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
      echo "Start Docker or add your user to the Docker group, then rerun ./scripts/k3s-worker.sh." >&2
      exit 1
    fi
  fi
}

ensure_k3s_agent() {
  ensure_download_tools

  if command_exists k3s; then
    echo "==> K3s is already installed – updating agent configuration with Master IP ${MASTER_IP}..."
  else
    echo "==> Installing K3s agent..."
  fi

  # The official K3s install script is idempotent:
  # - First run  → installs the binary and creates the systemd service.
  # - Subsequent runs → updates K3S_URL and K3S_TOKEN in the service and restarts the agent.
  # This means relaunching the script with a new --master-ip automatically reconnects the worker.
  #
  # INSTALL_K3S_EXEC persists the --node-label flag in the K3s systemd service unit.
  # This means the label is re-applied every time the k3s-agent service starts,
  # making it fully idempotent without requiring kubectl access on the Worker node.
  _do_install_k3s_agent() {
    curl -sfL https://get.k3s.io | \
      K3S_URL="https://${MASTER_IP}:6443" \
      K3S_TOKEN="${K3S_TOKEN}" \
      INSTALL_K3S_EXEC="agent --node-label edgekit.io/role=worker" \
      sh -
  }
  run_with_spinner "Installing/updating K3s agent (with node label edgekit.io/role=worker)" _do_install_k3s_agent

  if command_exists systemctl && systemctl is-active --quiet k3s-agent 2>/dev/null; then
    echo "==> k3s agent service is active"
  fi
  echo "==> Node label 'edgekit.io/role=worker' will be applied on agent start."
}

# =============================================================================
# Version reporting
# =============================================================================

print_versions() {
  print_section "TECHNOLOGY VERSIONS ON WORKER NODE"

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
  echo "  Architecture : $(uname -m) [${ARCH_LABEL:-?}]"
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
  echo "  Master IP  : ${MASTER_IP}"
  echo ""
}

# =============================================================================
# Build & deploy EdgeKit client image
# =============================================================================

deploy_edgekit_client() {
  print_section "BUILDING & DEPLOYING EDGEKIT CLIENT IMAGE"
  echo "  Log file: ${LOG_FILE}"

  _do_docker_build_client() {
    "${DOCKER_CMD[@]}" build \
      --tag "${CLIENT_IMAGE}" \
      --file "${REPO_ROOT}/client/Dockerfile" \
      "${REPO_ROOT}/client"
  }

  _do_import_client_image() {
    "${DOCKER_CMD[@]}" save "${CLIENT_IMAGE}" | as_root k3s ctr images import -
  }

  run_with_spinner "Building Docker client image" _do_docker_build_client
  run_with_spinner "Importing client image into containerd" _do_import_client_image

  echo ""
  echo "==> Client image imported successfully"
  echo "    NOTE: The Helm chart (client replicas) is managed by the master node."
  echo "          The client pods will be scheduled on worker nodes automatically."
}

# =============================================================================
# Automated connection & functionality tests
# =============================================================================

run_worker_tests() {
  print_section "RUNNING WORKER VALIDATION TESTS"

  local failed=0

  # Test 1 – Can reach master API server
  echo "[TEST 1/5] Network connectivity to master (${MASTER_IP}:6443)..."
  if command_exists curl; then
    if curl -sk --max-time 5 "https://${MASTER_IP}:6443/readyz" >/dev/null 2>&1 || \
       curl -sk --max-time 5 "https://${MASTER_IP}:6443" >/dev/null 2>&1; then
      echo "  PASS – Master API is reachable at ${MASTER_IP}:6443"
    else
      echo "  FAIL – Cannot reach master API at ${MASTER_IP}:6443"
      echo "         Check network connectivity and firewall rules."
      failed=$((failed + 1))
    fi
  else
    echo "  SKIP – curl not available for connectivity test"
  fi

  # Test 2 – k3s agent process or service is running
  echo "[TEST 2/5] K3s agent is running..."
  if command_exists systemctl && systemctl is-active --quiet k3s-agent 2>/dev/null; then
    echo "  PASS – k3s-agent systemd service is active"
  elif pgrep -x "k3s" >/dev/null 2>&1 || pgrep -f "k3s agent" >/dev/null 2>&1; then
    echo "  PASS – k3s agent process is running"
  else
    echo "  FAIL – k3s agent does not appear to be running"
    echo "         Check: sudo journalctl -u k3s-agent -n 50"
    failed=$((failed + 1))
  fi

  # Test 3 – This node appears in the cluster
  echo "[TEST 3/5] This node is visible in the K3s cluster..."
  local node_name
  node_name=$(hostname)
  # Give the agent up to 30s to register
  local registered="false"
  for i in $(seq 1 6); do
    if command_exists kubectl && kubectl get node "${node_name}" >/dev/null 2>&1; then
      registered="true"
      break
    elif command_exists k3s && k3s kubectl get node "${node_name}" >/dev/null 2>&1; then
      registered="true"
      break
    fi
    echo "    Waiting for node registration... (${i}/6)"
    sleep 5
  done

  if [ "${registered}" = "true" ]; then
    echo "  PASS – Node '${node_name}' is registered in the cluster"
  else
    # Downgrade to warning since kubectl might not be on the worker
    echo "  WARN – Could not verify node registration from this machine."
    echo "         Run on master: kubectl get nodes -o wide"
  fi

  # Test 4 – Client image is in containerd
  # NOTE: k3s ctr images import places the image in containerd's DEFAULT namespace.
  # K3s only copies it to the k8s.io namespace when it actually pulls the image
  # to schedule a pod. At this point the client pod is Pending on the Master
  # (waiting for a labelled Worker node), so it has never been pulled here.
  # This test is therefore a WARN, not a FAIL: a FAIL would cause exit 1 and
  # prevent print_summary() from running, misleading the operator.
  echo "[TEST 4/5] Client image is present in k3s containerd (k8s.io namespace)..."
  local img_list_worker
  img_list_worker=$(as_root k3s ctr -n k8s.io images list 2>/dev/null) || true
  if echo "${img_list_worker}" | grep -q "edgekit-client"; then
    echo "  PASS – Client image found in containerd store (k8s.io namespace)"
  else
    echo "  WARN – Client image not yet in k8s.io namespace (expected: pod is still Pending on master)"
    echo "         It will appear here once the Master schedules the client pod onto this node."
    echo "         Verify with: sudo k3s ctr -n k8s.io images list | grep edgekit-client"
    # Not counted as a failure: this is the correct Zero-Touch state.
  fi

  # Test 5 – k3s containerd socket is reachable
  echo "[TEST 5/5] K3s containerd is reachable..."
  if as_root k3s ctr images list >/dev/null 2>&1; then
    echo "  PASS – k3s containerd is responding"
  else
    echo "  FAIL – k3s containerd (k3s ctr) is not reachable"
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
# Final summary
# =============================================================================

print_summary() {
  print_section "WORKER NODE SETUP COMPLETE"

  echo ""
  echo "  Worker node has joined the K3s cluster."
  echo ""
  echo "  Master IP  : ${MASTER_IP}"
  echo "  Hostname   : $(hostname)"
  echo "  Log file   : ${LOG_FILE}"
  echo ""
  echo "  Verify from the MASTER node:"
  echo "    kubectl get nodes -o wide"
  echo "    kubectl -n ${NAMESPACE} get pods -o wide"
  echo ""
  echo "  To remove this node from the cluster (run on master):"
  echo "    kubectl drain $(hostname) --ignore-daemonsets --delete-emptydir-data"
  echo "    kubectl delete node $(hostname)"
  echo ""
}

# =============================================================================
# Main
# =============================================================================

KUBECTL_CMD=(kubectl)
KUBECTL_DISPLAY="kubectl"
DOCKER_CMD=("${DOCKER_BIN}")
ARCH_LABEL="unknown"

echo ""
echo "============================================================"
echo "  EdgeKit – K3s Worker Node Setup"
echo "  Master  : ${MASTER_IP}"
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
ensure_pi_cgroups
ensure_firewall_rules
ensure_base_packages
ensure_docker
ensure_k3s_agent
print_versions
deploy_edgekit_client
run_worker_tests
print_summary
