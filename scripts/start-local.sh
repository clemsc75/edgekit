#!/usr/bin/env bash
# =============================================================================
# scripts/start-local.sh – Start the full edgekit stack locally via Docker Compose
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Starting edgekit stack (builds images if needed)…"
docker compose -f "${REPO_ROOT}/docker-compose.yml" up --build -d

echo ""
echo "✅ edgekit is running!"
echo ""
echo "   MQTT broker:       mqtt://localhost:1883"
echo "   MQTT over WS:      ws://localhost:9001"
echo ""
echo "   View logs:         docker compose logs -f"
echo "   Stop:              ./scripts/stop-local.sh"
