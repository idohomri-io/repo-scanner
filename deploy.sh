#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ─────────────────────────────────────────
REPO="ghcr.io/idohomri-io/repo-scanner"   
# ─────────────────────────────────────────────────────────

VERSION="${1:-$(git rev-parse --short HEAD)}"
IMAGE="${REPO}:${VERSION}"
LATEST="${REPO}:latest"

echo "▶  Building  ${IMAGE}"
docker build --platform linux/amd64 -t "${IMAGE}" -t "${LATEST}" .

echo "▶  Pushing   ${IMAGE}"
docker push "${IMAGE}"
docker push "${LATEST}"

echo "✓  Done — ${IMAGE}"