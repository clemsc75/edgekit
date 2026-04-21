#!/usr/bin/env bash
# =============================================================================
# scripts/stop-local.sh – Stop the local edgekit Docker Compose stack
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Stopping edgekit stack…"
docker compose -f "${REPO_ROOT}/docker-compose.yml" down

echo "✅ edgekit stopped."
