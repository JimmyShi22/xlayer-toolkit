#!/bin/bash
set -euo pipefail

# Compiles and predeploys the test-only TxBlacklist contract
# (contracts/TxBlacklistTestable.sol — an owner-stripped fork of the production contract)
# into config-op/genesis.json at the fixed address used by the Rust devnet blacklist logic.
#
# The runtime bytecode is built inside OP_CONTRACTS_IMAGE_TAG and cached by source, compiler
# configuration, image ID, and cache schema. The cache is local-only and survives clean.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVNET_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$DEVNET_DIR"

source .env

CACHE_SCHEMA="txblacklist-runtime-v1"
REQUIRED_ADDRESS="b1ac000000000000000000000000000000000001"
requested_address="${BLACKLIST_TEST_ADDRESS:-$REQUIRED_ADDRESS}"
requested_address=$(printf '%s' "$requested_address" | tr '[:upper:]' '[:lower:]')
requested_address="${requested_address#0x}"
if [ "$requested_address" != "$REQUIRED_ADDRESS" ]; then
    echo "❌ TxBlacklist address must be 0x${REQUIRED_ADDRESS}; got 0x${requested_address}" >&2
    exit 1
fi
BLACKLIST_TEST_ADDRESS="$REQUIRED_ADDRESS"
GENESIS_PATH="${GENESIS_PATH:-$DEVNET_DIR/config-op/genesis.json}"
SOURCE_PATH="${SOURCE_PATH:-$DEVNET_DIR/contracts/TxBlacklistTestable.sol}"
CONFIG_PATH="${CONFIG_PATH:-$DEVNET_DIR/contracts/txblacklist.foundry.toml}"
CACHE_DIR="${TXBLACKLIST_CACHE_DIR:-$DEVNET_DIR/.cache/txblacklist}"
BUILD_IMAGE="${OP_CONTRACTS_IMAGE_TAG:?OP_CONTRACTS_IMAGE_TAG must be set in .env}"

test -f "$GENESIS_PATH" || { echo "❌ Missing genesis: $GENESIS_PATH" >&2; exit 1; }
test -f "$SOURCE_PATH" || { echo "❌ Missing TxBlacklist source: $SOURCE_PATH" >&2; exit 1; }
test -f "$CONFIG_PATH" || { echo "❌ Missing TxBlacklist Foundry config: $CONFIG_PATH" >&2; exit 1; }

image_id=$(docker image inspect --format '{{.Id}}' "$BUILD_IMAGE" 2>/dev/null) || {
    echo "❌ Missing local OP contracts image: $BUILD_IMAGE" >&2
    exit 1
}
source_hash=$(shasum -a 256 "$SOURCE_PATH" | awk '{print $1}')
config_hash=$(shasum -a 256 "$CONFIG_PATH" | awk '{print $1}')
cache_key=$(printf '%s\n%s\n%s\n%s\n' "$CACHE_SCHEMA" "$image_id" "$source_hash" "$config_hash" | shasum -a 256 | awk '{print $1}')
cache_file="$CACHE_DIR/$cache_key.deployedBytecode.hex"

normalize_bytecode() {
    local value
    value=$(tr -d '[:space:]' < "$1" | tr '[:upper:]' '[:lower:]')
    case "$value" in 0x*) ;; *) value="0x$value" ;; esac
    if ! [[ "$value" =~ ^0x([0-9a-f][0-9a-f])+$ ]]; then
        return 1
    fi
    printf '%s' "$value"
}

mkdir -p "$CACHE_DIR"
if [ -f "$cache_file" ] && bytecode=$(normalize_bytecode "$cache_file"); then
    echo "♻️  Using cached TxBlacklist runtime bytecode: $cache_file"
else
    if [ -f "$cache_file" ]; then
        echo "⚠️  Invalid TxBlacklist cache entry; rebuilding: $cache_file" >&2
    else
        echo "🔨 Compiling TxBlacklist runtime bytecode with $BUILD_IMAGE ..."
    fi

    build_dir=$(mktemp -d "$CACHE_DIR/.build.XXXXXX")
    trap 'rm -rf "$build_dir"' EXIT
    mkdir -p "$build_dir/src"
    cp "$SOURCE_PATH" "$build_dir/src/TxBlacklistTestable.sol"
    cp "$CONFIG_PATH" "$build_dir/foundry.toml"

    docker run --rm \
        -e HOST_UID="$(id -u)" \
        -e HOST_GID="$(id -g)" \
        -v "$build_dir:/workspace" \
        -w /workspace \
        "$BUILD_IMAGE" \
        sh -c 'build_status=0
            forge build --contracts src --out out || build_status=$?
            chown -R "$HOST_UID:$HOST_GID" /workspace
            exit "$build_status"'

    compiled_artifact="$build_dir/out/TxBlacklistTestable.sol/TxBlacklistTestable.json"
    test -f "$compiled_artifact" || { echo "❌ TxBlacklist build did not produce $compiled_artifact" >&2; exit 1; }
    bytecode_json="$build_dir/deployedBytecode.hex"
    jq -r '.deployedBytecode.object // empty' "$compiled_artifact" > "$bytecode_json"
    bytecode=$(normalize_bytecode "$bytecode_json") || {
        echo "❌ TxBlacklist compiler produced invalid deployed bytecode" >&2
        exit 1
    }

    cache_tmp=$(mktemp "$CACHE_DIR/.bytecode.XXXXXX")
    printf '%s\n' "$bytecode" > "$cache_tmp"
    mv "$cache_tmp" "$cache_file"
    echo "✅ Cached TxBlacklist runtime bytecode: $cache_file"
fi

echo "🔧 Predeploying test-only TxBlacklist contract at 0x${BLACKLIST_TEST_ADDRESS} ..."

python3 - "$BLACKLIST_TEST_ADDRESS" "$GENESIS_PATH" "$bytecode" <<'PYEOF'
import json
import sys

address, genesis_path, bytecode = sys.argv[1], sys.argv[2], sys.argv[3]
address = address.lower()
if address.startswith("0x"):
    address = address[2:]

with open(genesis_path) as f:
    genesis = json.load(f)

genesis.setdefault("alloc", {})[address] = {"code": bytecode, "balance": "0x0", "nonce": "0x1"}

with open(genesis_path, "w") as f:
    json.dump(genesis, f, indent=2)

print(f"  -> wrote {address} into {genesis_path}'s alloc")
PYEOF
