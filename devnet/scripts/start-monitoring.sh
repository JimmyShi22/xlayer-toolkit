#!/bin/bash
set -euo pipefail

DEVNET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DEVNET_DIR"
ENV_FILE="${ENV_FILE:-.env}"
[ -f "$ENV_FILE" ] || { echo "❌ Missing devnet environment: $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

echo "🚀 Starting monitoring stack (Prometheus + Grafana)..."
MONITOR_INIT_IMAGE="${OP_RETH_IMAGE_TAG:-alpine}"
docker run --rm --user 0:0 -v "$(pwd)/data:/data" --entrypoint sh "$MONITOR_INIT_IMAGE" -c '
  mkdir -p /data/grafana /data/prometheus &&
  chown 472:472 /data/grafana &&
  chown 65534:65534 /data/prometheus
' || echo " ⚠️  could not pre-chown monitoring data dirs; grafana/prometheus may fail on permissions"
docker compose up -d prometheus grafana
echo "✅ Grafana available at http://localhost:3000 (admin/admin)"
