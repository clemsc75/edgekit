#!/usr/bin/env bash
# =============================================================================
# scripts/uninstall-edgekit.sh – Full cleanup of an EdgeKit K3s node
#
# Usage:
#   bash scripts/uninstall-edgekit.sh --role master [--verbose]
#   bash scripts/uninstall-edgekit.sh --role worker [--verbose]
#   bash scripts/uninstall-edgekit.sh          # auto-detect role
#
# Flags:
#   --verbose, -v   Print all command output to the terminal (no spinner).
#                   Useful for debugging if the spinner freezes.
#
# What it does (master):
#   1. Helm uninstall edgekit + delete namespace
#   2. Run official k3s-uninstall.sh
#   3. Remove ~/.kube
#
# What it does (worker):
#   1. Run official k3s-agent-uninstall.sh
#
# Common cleanup (both roles, after K3s removal):
#   - Remove residual Rancher/K3s/CNI directories
#   - Delete virtual network interfaces (cni0, flannel.1, etc.)
#   - Remove local Docker images containing "edgekit"
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-edgekit}"
RELEASE_NAME="${RELEASE_NAME:-edgekit}"

# =============================================================================
# Flag & role parsing  (before exec redirect so VERBOSE is set early)
# =============================================================================

VERBOSE="${VERBOSE:-0}"
ROLE=""

usage() {
  echo ""
  echo "Usage: bash scripts/uninstall-edgekit.sh [--role master|worker] [--verbose]"
  echo ""
  echo "  --role master   Clean up a K3s Server (Master) node"
  echo "  --role worker   Clean up a K3s Agent (Worker) node"
  echo "  --verbose, -v   Show full command output (debug mode, no spinner)"
  echo ""
  echo "  If --role is omitted, the script tries to auto-detect the role"
  echo "  by checking which K3s uninstall script is present."
  echo ""
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)
      ROLE="$2"
      shift 2
      ;;
    --verbose|-v)
      VERBOSE=1
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
export VERBOSE

# Auto-detect role if not provided
if [ -z "${ROLE}" ]; then
  echo "==> No --role specified, attempting auto-detection..."
  if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
    ROLE="master"
    echo "==> Detected role: master (k3s-uninstall.sh found)"
  elif [ -f /usr/local/bin/k3s-agent-uninstall.sh ]; then
    ROLE="worker"
    echo "==> Detected role: worker (k3s-agent-uninstall.sh found)"
  else
    echo "ERROR: Could not auto-detect role. Neither k3s-uninstall.sh nor" >&2
    echo "       k3s-agent-uninstall.sh found in /usr/local/bin." >&2
    echo "       Please specify --role master or --role worker." >&2
    exit 1
  fi
fi

if [[ "${ROLE}" != "master" && "${ROLE}" != "worker" ]]; then
  echo "ERROR: --role must be 'master' or 'worker' (got: '${ROLE}')" >&2
  usage
fi

# Setup log file
LOG_DIR="${LOG_DIR:-${REPO_ROOT}/logs}"
LOG_FILE="${LOG_DIR}/uninstall-edgekit-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "${LOG_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

# =============================================================================
# Load spinner library and register signal traps
# =============================================================================

# shellcheck source=scripts/lib/spinner.sh
source "${REPO_ROOT}/scripts/lib/spinner.sh"
spinner_register_traps

# =============================================================================
# Helpers
# =============================================================================

print_section() {
  echo ""
  echo "============================================================"
  echo "  $*"
  echo "============================================================"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    echo "ERROR: root privileges required and 'sudo' is not available." >&2
    exit 1
  fi
}

# =============================================================================
# Confirmation prompt
# =============================================================================

echo ""
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║           EdgeKit Uninstall Script                       ║"
echo "  ║                                                          ║"
echo "  ║  Role   : ${ROLE}                                        "
echo "  ║  This will COMPLETELY remove K3s, Helm deployments,      ║"
echo "  ║  CNI interfaces, and EdgeKit Docker images.              ║"
if [ "${VERBOSE}" = "1" ]; then
echo "  ║  Mode   : VERBOSE (full output)                          ║"
else
echo "  ║  Log    : ${LOG_FILE}"
fi
echo "  ╚══════════════════════════════════════════════════════════╝"
echo ""
read -r -p "  Are you sure you want to continue? [y/N] " confirm
if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
  echo "==> Aborted."
  exit 0
fi

# =============================================================================
# MASTER-specific cleanup
# =============================================================================

uninstall_master() {
  print_section "MASTER CLEANUP – Helm & K3s Server"

  # -----------------------------------------------------------------------
  # Helm / kubectl cleanup — BEST-EFFORT with strict timeouts
  #
  # Two layers of timeout protection are used deliberately:
  #
  #   Layer 1 – Native flags:
  #     helm uninstall --timeout 30s   → Helm stops waiting for Pod
  #                                      termination after 30 s.
  #     kubectl delete ns --timeout=20s → kubectl gives up waiting for
  #                                      the namespace Finalizer after 20 s.
  #
  #   Layer 2 – System timeout(1) wrapper on the entire function:
  #     Some helm/kubectl versions ignore their own --timeout flag when
  #     the API server is completely unreachable (TCP connection hangs
  #     at the OS level). The outer `timeout 90` is the absolute wall-
  #     clock limit; if it fires, the sub-process is SIGTERM'd and the
  #     || true prevents set -e from aborting the script.
  #
  # If the cluster is healthy the whole block completes in < 10 s.
  # If the cluster is degraded the block is abandoned in ≤ 90 s and
  # the script moves on to the brute-force k3s-uninstall.sh step.
  # -----------------------------------------------------------------------
  echo "==> Removing Helm release '${RELEASE_NAME}' from namespace '${NAMESPACE}'..."

  if ! command_exists helm || ! command_exists kubectl; then
    echo "    helm or kubectl not found – skipping Helm uninstall."
  else
    _do_helm_uninstall() {
      # --- Step 1: Helm uninstall (30 s hard cap) ---
      # --no-hooks skips pre/post-delete hooks that may themselves block.
      # 2>/dev/null silences "release not found" when already removed.
      echo "    [1/3] helm uninstall (timeout 30s)..."
      timeout 35 helm uninstall "${RELEASE_NAME}" \
        --namespace "${NAMESPACE}" \
        --timeout 30s \
        --no-hooks \
        --ignore-not-found \
        2>/dev/null || true

      # --- Step 2: Delete namespace (20 s hard cap) ---
      echo "    [2/3] kubectl delete namespace (timeout 20s)..."
      timeout 25 kubectl delete namespace "${NAMESPACE}" \
        --ignore-not-found \
        --timeout=20s \
        2>/dev/null || true

      # --- Step 3: Force-clear Finalizer if namespace is stuck Terminating ---
      # When the API server is degraded the garbage-collector never removes
      # the kubernetes Finalizer, leaving the namespace in Terminating forever.
      # We patch it out directly via the REST API, bypassing the controller.
      local ns_phase
      ns_phase=$(kubectl get namespace "${NAMESPACE}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

      if [ "${ns_phase}" = "Terminating" ]; then
        echo "    [3/3] Namespace stuck in Terminating – patching out Finalizer..."
        # Build a minimal JSON body and pipe it to kubectl replace via the
        # /finalize sub-resource. This is the officially documented escape hatch.
        kubectl get namespace "${NAMESPACE}" -o json 2>/dev/null \
          | python3 -c "
import sys, json
ns = json.load(sys.stdin)
ns['spec']['finalizers'] = []
print(json.dumps(ns))
" \
          | timeout 10 kubectl replace --raw \
              "/api/v1/namespaces/${NAMESPACE}/finalize" \
              -f - \
              2>/dev/null || true
        echo "    Finalizer patch applied (or skipped if already gone)."
      else
        echo "    [3/3] Namespace not stuck – no Finalizer patch needed."
      fi
    }

    # Outer wall-clock guard: if _do_helm_uninstall takes more than 90 s
    # in total (e.g. TCP-level hang), abandon it and move on.
    if command_exists timeout; then
      echo "    Running Helm cleanup (wall-clock limit: 90s)..."
      timeout 90 bash -c "$(declare -f _do_helm_uninstall); _do_helm_uninstall" \
        || echo "    WARN: Helm cleanup timed out or failed – continuing with K3s uninstall."
    else
      # timeout(1) not available (very minimal images) — run without outer guard
      echo "    WARN: 'timeout' command not found; running without outer time limit."
      _do_helm_uninstall || true
    fi
  fi

  # 2) Official K3s server uninstall script
  if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
    run_with_spinner "Uninstalling K3s server" \
      as_root /usr/local/bin/k3s-uninstall.sh
    echo "    K3s server uninstalled."
  else
    echo "    /usr/local/bin/k3s-uninstall.sh not found – skipping."
  fi

  # 3) Remove local kubeconfig
  echo "==> Removing local kubeconfig (~/.kube)..."
  rm -rf "${HOME}/.kube" || true
  echo "    Done."
}

# =============================================================================
# WORKER-specific cleanup
# =============================================================================

uninstall_worker() {
  print_section "WORKER CLEANUP – K3s Agent"

  if [ -f /usr/local/bin/k3s-agent-uninstall.sh ]; then
    run_with_spinner "Uninstalling K3s agent" \
      as_root /usr/local/bin/k3s-agent-uninstall.sh
    echo "    K3s agent uninstalled."
  else
    echo "    /usr/local/bin/k3s-agent-uninstall.sh not found – skipping."
  fi
}

# =============================================================================
# COMMON cleanup (runs for both roles after K3s removal)
# =============================================================================

cleanup_residual_dirs() {
  print_section "COMMON CLEANUP – Residual Rancher/K3s/CNI Directories"

  local dirs=(
    /etc/rancher
    /var/lib/rancher
    /var/lib/kubelet
    /var/lib/cni
    /var/run/k3s
  )

  for dir in "${dirs[@]}"; do
    if [ -e "${dir}" ]; then
      echo "==> Removing ${dir}..."
      as_root rm -rf "${dir}" || true
    else
      echo "==> ${dir} – already absent, skipping."
    fi
  done
}

cleanup_network_interfaces() {
  print_section "COMMON CLEANUP – Virtual Network Interfaces (CNI/Flannel)"

  local ifaces=(cni0 flannel.1 flannel-v6.1 kube-ipvs0)

  for iface in "${ifaces[@]}"; do
    if command_exists ip && as_root ip link show "${iface}" >/dev/null 2>&1; then
      echo "==> Deleting network interface: ${iface}..."
      as_root ip link delete "${iface}" 2>/dev/null || true
    else
      echo "==> Interface '${iface}' not found – skipping."
    fi
  done

  # Also clean up any remaining veth/cni interfaces dynamically
  echo "==> Checking for remaining veth/cni interfaces..."
  while IFS= read -r iface_name; do
    echo "    Deleting: ${iface_name}"
    as_root ip link delete "${iface_name}" 2>/dev/null || true
  done < <(as_root ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(veth|cni-)' || true)

  echo "==> Network interface cleanup done."
}

cleanup_docker_images() {
  print_section "COMMON CLEANUP – Local Docker Images (edgekit)"

  if ! command_exists docker; then
    echo "==> Docker not found – skipping image cleanup."
    return
  fi

  local docker_cmd=(docker)
  if ! docker info >/dev/null 2>&1; then
    if sudo docker info >/dev/null 2>&1; then
      docker_cmd=(sudo docker)
    else
      echo "==> Docker daemon not reachable – skipping image cleanup."
      return
    fi
  fi

  echo "==> Searching for EdgeKit Docker images to remove..."
  local images
  images=$("${docker_cmd[@]}" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep "edgekit" || true)

  if [ -z "${images}" ]; then
    echo "    No EdgeKit Docker images found."
    return
  fi

  while IFS= read -r image; do
    echo "    Removing: ${image}"
    "${docker_cmd[@]}" rmi --force "${image}" 2>/dev/null || true
  done <<< "${images}"

  echo "==> Docker image cleanup done."
}

# =============================================================================
# Main execution
# =============================================================================

print_section "STARTING EDGEKIT UNINSTALL – Role: ${ROLE}"

if [ "${ROLE}" = "master" ]; then
  uninstall_master
else
  uninstall_worker
fi

cleanup_residual_dirs
cleanup_network_interfaces
cleanup_docker_images

print_section "UNINSTALL COMPLETE"

echo ""
echo "  The node has been cleaned up successfully."
echo ""
echo "  What was removed:"
if [ "${ROLE}" = "master" ]; then
  echo "    ✓ Helm release '${RELEASE_NAME}' and namespace '${NAMESPACE}'"
  echo "    ✓ K3s server (via k3s-uninstall.sh)"
  echo "    ✓ ~/.kube directory"
else
  echo "    ✓ K3s agent (via k3s-agent-uninstall.sh)"
fi
echo "    ✓ Residual directories: /etc/rancher, /var/lib/rancher, /var/lib/kubelet, /var/lib/cni, /var/run/k3s"
echo "    ✓ CNI/Flannel virtual network interfaces"
echo "    ✓ Local Docker images tagged with 'edgekit'"
echo ""
echo "  The machine is now in a clean state."
echo "  You can safely rerun k3s-master.sh or k3s-worker.sh."
echo "  Log file: ${LOG_FILE}"
echo ""
