#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DEVNET_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin"
printf '%s\n' \
  '#!/bin/bash' \
  'if [ "${1:-}" = node ] && [ "${2:-}" = --help ]; then exit 0; fi' \
  'printf "%s\\n" "${RCS_BASE_URL:-unset}"' \
  > "$TMP_DIR/bin/op-reth"
chmod +x "$TMP_DIR/bin/op-reth"

printf '%s\n' \
  'SEQ_TYPE=reth' \
  'FLASHBLOCK_ENABLED=false' \
  'ENABLE_GASLESS=false' \
  'RCS_BASE_URL=http://host.docker.internal:9195' \
  > "$TMP_DIR/shared.env"

actual=$(
  PATH="$TMP_DIR/bin:$PATH" \
  ENV_FILE="$TMP_DIR/shared.env" \
  RCS_BASE_URL="http://rcs2:9195" \
  bash "$DEVNET_DIR/entrypoint/reth-seq.sh" 2
)

expected="http://rcs2:9195"
if [ "$actual" != "$expected" ]; then
  echo "FAIL: expected compose RCS_BASE_URL=$expected, got $actual" >&2
  exit 1
fi

echo "PASS: compose RCS_BASE_URL keeps precedence over the shared env file"
