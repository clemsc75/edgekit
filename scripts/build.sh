#!/usr/bin/env bash
# =============================================================================
# scripts/build.sh – Build all edgekit Docker images
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${IMAGE_TAG:-local}"

echo "==> Building edgekit-server (tag: ${TAG})"
docker build \
  --tag "edgekit-server:${TAG}" \
  --file "${REPO_ROOT}/server/Dockerfile" \
  "${REPO_ROOT}/server"

echo "==> Building edgekit-client (tag: ${TAG})"
docker build \
  --tag "edgekit-client:${TAG}" \
  --file "${REPO_ROOT}/client/Dockerfile" \
  "${REPO_ROOT}/client"

echo ""
echo "✅ All images built successfully."
echo "   edgekit-server:${TAG}"
echo "   edgekit-client:${TAG}"
