#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ─────────────────────────────────────────
REPO="ghcr.io/itdirectory/domain-worker"   
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
echo ""
echo "    If prisma/schema.prisma changed, run migrations BEFORE deploying:"
echo "      export DATABASE_URL=\"postgresql://...\""
echo "      ./scripts/migrate.sh --yes"
echo ""
echo "    Then on server: docker compose pull && docker compose up -d"
