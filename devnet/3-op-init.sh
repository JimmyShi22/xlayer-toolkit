#!/bin/bash

set -eo pipefail

set -a
source .env
set +a

# shellcheck source=scripts/lib/reth-init.sh
source ./scripts/lib/reth-init.sh

./scripts/generate-cluster.sh
source config-op/cluster/cluster.env

sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Check if FORK_BLOCK is set
if [ -z "$FORK_BLOCK" ]; then
    echo " ❌ FORK_BLOCK environment variable is not set"
    echo "Please set FORK_BLOCK in your .env file"
    exit 1
fi

echo "🔧 Setting fork block and parent hash in genesis.json ..."
FORK_BLOCK_HEX=$(printf "0x%x" "$FORK_BLOCK")
sed_inplace '/"config": {/,/}/ s/"optimism": {/"legacyXLayerBlock": '"$((FORK_BLOCK + 1))"',\n    "optimism": {/' ./config-op/genesis.json
sed_inplace 's/"parentHash": "0x0000000000000000000000000000000000000000000000000000000000000000"/"parentHash": "'"$PARENT_HASH"'"/' ./config-op/genesis.json
sed_inplace '/"70997970c51812dc3a010c7d01b50e0d17dc79c8": {/,/}/ s/"balance": "[^"]*"/"balance": "0x446c3b15f9926687d2c40534fdb564000000000000"/' ./config-op/genesis.json
sed_inplace 's/"eip1559DenominatorCanyon": [0-9]*/"eip1559DenominatorCanyon": '"$(jq -r '.config.optimism.eip1559Denominator' ./config-op/genesis.json)"'/' ./config-op/genesis.json

# Seed both genesis allocations before deriving genesis-reth.json.
./scripts/inject-deploy-factory.sh
./scripts/inject-txblacklist-genesis-alloc.sh

NEXT_BLOCK_NUMBER=$((FORK_BLOCK + 1))
NEXT_BLOCK_NUMBER_HEX=$(printf "0x%x" "$NEXT_BLOCK_NUMBER")
sed_inplace 's/"number": 0/"number": '"$NEXT_BLOCK_NUMBER"'/' ./config-op/rollup.json
sed_inplace 's/"eip1559Elasticity": [0-9]*/"eip1559Elasticity": '"$(jq -r '.config.optimism.eip1559Elasticity' ./config-op/genesis.json)"'/' ./config-op/rollup.json
sed_inplace 's/"eip1559Denominator": [0-9]*/"eip1559Denominator": '"$(jq -r '.config.optimism.eip1559Denominator' ./config-op/genesis.json)"'/' ./config-op/rollup.json
sed_inplace 's/"eip1559DenominatorCanyon": [0-9]*/"eip1559DenominatorCanyon": '"$(jq -r '.config.optimism.eip1559DenominatorCanyon' ./config-op/genesis.json)"'/' ./config-op/rollup.json

# Only after injection: derive genesis-reth.json and initialize/copy node datadirs.
if [ "$MERGE_RETH_GENESIS" = "true" ]; then
    echo "🔧 Merging genesis files..."

    if [ -z "$MERGE_RETH_DATADIR_PATH" ]; then
        echo " ❌ MERGE_RETH_DATADIR_PATH environment variable is not set"
        echo "Please set MERGE_RETH_DATADIR_PATH in your .env file"
        exit 1
    fi

    docker run --rm -v "./config-op:/config-op" -v "$MERGE_RETH_DATADIR_PATH:/reth-datadir" $XLAYER_RETH_TOOLS_IMAGE_TAG \
        gen-genesis --datadir /reth-datadir --chain $MERGE_RETH_CHAIN \
        --template-genesis /config-op/genesis.json --output /config-op/genesis-reth.json --output-chainspec /config-op/xlayer-devnet.json
    FORK_BLOCK=$(($(cast to-dec $(jq .number config-op/xlayer-devnet.json | tr -d '"')) - 1))
    echo "FORK_BLOCK=$FORK_BLOCK"
    sed_inplace "s/FORK_BLOCK=.*/FORK_BLOCK=$FORK_BLOCK/" .env
    jq '.genesis.l2.number = '"$((FORK_BLOCK + 1))" ./config-op/rollup.json > tmp.json && mv tmp.json ./config-op/rollup.json
else
    # Create genesis-reth.json from genesis.json
    echo "🔧 Creating genesis-reth.json from genesis.json ..."
    cp ./config-op/genesis.json ./config-op/genesis-reth.json
    sed_inplace 's/"number": "0x0"/"number": "'"$NEXT_BLOCK_NUMBER_HEX"'"/' ./config-op/genesis-reth.json
fi

# Extract contract addresses from state.json and update .env file
echo "🔧 Extracting contract addresses from state.json..."
PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_JSON="$PWD_DIR/config-op/state.json"

if [ -f "$STATE_JSON" ]; then
    # Extract contract addresses from state.json
    DEPLOYMENTS_TYPE=$(jq -r 'type' "$STATE_JSON")
    if [ "$DEPLOYMENTS_TYPE" = "object" ]; then
        OPCD_TYPE=$(jq -r '.opChainDeployments | type' "$STATE_JSON" 2>/dev/null)
        if [ "$OPCD_TYPE" = "object" ]; then
            DISPUTE_GAME_FACTORY_ADDRESS=$(jq -r '.opChainDeployments.DisputeGameFactoryProxy // empty' "$STATE_JSON")
            L2OO_ADDRESS=$(jq -r '.opChainDeployments.L2OutputOracleProxy // empty' "$STATE_JSON")
            OPCM_IMPL_ADDRESS=$(jq -r '.appliedIntent.opcmAddress // empty' "$STATE_JSON")
            SYSTEM_CONFIG_PROXY_ADDRESS=$(jq -r '.opChainDeployments.SystemConfigProxy // empty' "$STATE_JSON")
            OPTIMISM_PORTAL_PROXY_ADDRESS=$(jq -r '.opChainDeployments.OptimismPortalProxy // empty' "$STATE_JSON")
            PROXY_ADMIN=$(jq -r '.superchainContracts.SuperchainProxyAdminImpl // empty' "$STATE_JSON")
        elif [ "$OPCD_TYPE" = "array" ]; then
            DISPUTE_GAME_FACTORY_ADDRESS=$(jq -r '.opChainDeployments[0].DisputeGameFactoryProxy // empty' "$STATE_JSON")
            L2OO_ADDRESS=$(jq -r '.opChainDeployments[0].L2OutputOracleProxy // empty' "$STATE_JSON")
            OPCM_IMPL_ADDRESS=$(jq -r '.appliedIntent.opcmAddress // empty' "$STATE_JSON")
            SYSTEM_CONFIG_PROXY_ADDRESS=$(jq -r '.opChainDeployments[0].SystemConfigProxy // empty' "$STATE_JSON")
            OPTIMISM_PORTAL_PROXY_ADDRESS=$(jq -r '.opChainDeployments[0].OptimismPortalProxy // empty' "$STATE_JSON")
            PROXY_ADMIN=$(jq -r '.superchainContracts.SuperchainProxyAdminImpl // empty' "$STATE_JSON")
        else
            DISPUTE_GAME_FACTORY_ADDRESS=""
            L2OO_ADDRESS=""
            OPCM_IMPL_ADDRESS=""
            SYSTEM_CONFIG_PROXY_ADDRESS=""
            OPTIMISM_PORTAL_PROXY_ADDRESS=""
            PROXY_ADMIN=""
        fi

        # Update .env if found
        if [ -n "$DISPUTE_GAME_FACTORY_ADDRESS" ]; then
            echo " ✅ Found DisputeGameFactoryProxy address: $DISPUTE_GAME_FACTORY_ADDRESS"
            sed_inplace "s/DISPUTE_GAME_FACTORY_ADDRESS=.*/DISPUTE_GAME_FACTORY_ADDRESS=$DISPUTE_GAME_FACTORY_ADDRESS/" .env
        else
            echo " ⚠️ DisputeGameFactoryProxy address not found in opChainDeployments"
        fi

        if [ -n "$L2OO_ADDRESS" ]; then
            echo " ✅ Found L2OutputOracleProxy address: $L2OO_ADDRESS"
            sed_inplace "s/L2OO_ADDRESS=.*/L2OO_ADDRESS=$L2OO_ADDRESS/" .env
        else
            echo " ⚠️ L2OutputOracleProxy address not found in opChainDeployments"
        fi

        if [ -n "$OPCM_IMPL_ADDRESS" ]; then
            echo " ✅ Found opcmAddress address: $OPCM_IMPL_ADDRESS"
            sed_inplace "s/OPCM_IMPL_ADDRESS=.*/OPCM_IMPL_ADDRESS=$OPCM_IMPL_ADDRESS/" .env
        else
            echo " ⚠️ opcmAddress address not found in opChainDeployments"
        fi

        if [ -n "$SYSTEM_CONFIG_PROXY_ADDRESS" ]; then
            echo " ✅ Found SystemConfigProxy address: $SYSTEM_CONFIG_PROXY_ADDRESS"
            sed_inplace "s/SYSTEM_CONFIG_PROXY_ADDRESS=.*/SYSTEM_CONFIG_PROXY_ADDRESS=$SYSTEM_CONFIG_PROXY_ADDRESS/" .env
        else
            echo " ⚠️ SystemConfigProxy address not found in opChainDeployments"
        fi

        if [ -n "$OPTIMISM_PORTAL_PROXY_ADDRESS" ]; then
            echo " ✅ Found OptimismPortalProxy address: $OPTIMISM_PORTAL_PROXY_ADDRESS"
            sed_inplace "s/OPTIMISM_PORTAL_PROXY_ADDRESS=.*/OPTIMISM_PORTAL_PROXY_ADDRESS=$OPTIMISM_PORTAL_PROXY_ADDRESS/" .env
        else
            echo " ⚠️ OptimismPortalProxy address not found in opChainDeployments"
        fi

        if [ -n "$PROXY_ADMIN" ]; then
            echo " ✅ Found ProxyAdmin address: $PROXY_ADMIN"
            sed_inplace "s/PROXY_ADMIN=.*/PROXY_ADMIN=$PROXY_ADMIN/" .env
        else
            echo " ⚠️ ProxyAdmin address not found in opChainDeployments"
        fi

        # Show summary
        echo " 📄 Contract addresses updated in .env:"
        echo "   DISPUTE_GAME_FACTORY_ADDRESS=$DISPUTE_GAME_FACTORY_ADDRESS"
        echo "   L2OO_ADDRESS=$L2OO_ADDRESS"
        echo "   OPCM_IMPL_ADDRESS=$OPCM_IMPL_ADDRESS"
        echo "   SYSTEM_CONFIG_PROXY_ADDRESS=$SYSTEM_CONFIG_PROXY_ADDRESS"
        echo "   OPTIMISM_PORTAL_PROXY_ADDRESS=$OPTIMISM_PORTAL_PROXY_ADDRESS"
        echo "   PROXY_ADMIN=$PROXY_ADMIN"
    else
        echo " ❌ $STATE_JSON is not a valid JSON object"
    fi
else
    echo " ❌ state.json not found at $STATE_JSON"
fi

# Setup System Config Parameters after extracting addresses and updating .env
echo ""
echo "🔧 Setting up System Config Parameters..."
"$PWD_DIR/scripts/setup-system-config-params.sh"

# Initialize only selected Geth roles. Cleanup and genesis writes happen inside
# the service container as root so Linux bind mounts never depend on host-side
# ownership of a previous root-created datadir.
initialize_geth_service() {
    local service="$1"
    echo " 🔧 Initializing selected Geth service $service..."
    docker compose run --no-deps --rm \
      -v "$(pwd)/$CONFIG_DIR/genesis.json:/genesis.json:ro" \
      --entrypoint sh \
      "$service" \
      -euc 'find /datadir -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; geth --datadir=/datadir --gcmode=archive --db.engine="${DB_ENGINE:-pebble}" init --state.scheme=hash /genesis.json'
}

if [ "$SEQ_TYPE" = "geth" ]; then
    for ((i = 1; i <= SEQ_EFFECTIVE_COUNT; i++)); do
        GETH_SUFFIX=""
        [ "$i" -ne 1 ] && GETH_SUFFIX="$i"
        initialize_geth_service "op-geth-seq${GETH_SUFFIX}"
    done
fi
if [ "$LAUNCH_RPC_NODE" = "true" ] && [ "$RPC_TYPE" = "geth" ]; then
    for ((i = 1; i <= RPC_EFFECTIVE_COUNT; i++)); do
        GETH_SUFFIX=""
        [ "$i" -ne 1 ] && GETH_SUFFIX="$i"
        initialize_geth_service "op-geth-rpc${GETH_SUFFIX}"
    done
fi

# TRUSTED_PEERS is written directly into .env by scripts/generate-cluster-identities.sh
sed_inplace "s|TRUSTED_PEERS=.*|TRUSTED_PEERS=$TRUSTED_PEERS|" .env

TRUSTED_NODES_ONLY="${TRUSTED_NODES_ONLY:-false}"
sed_inplace "s/^trusted_nodes_only = .*/trusted_nodes_only = ${TRUSTED_NODES_ONLY}/" ./config-op/test.reth.seq.config.toml
sed_inplace "s/^trusted_nodes_only = .*/trusted_nodes_only = ${TRUSTED_NODES_ONLY}/" ./config-op/test.reth.rpc.config.toml

# Initialize Reth only when at least one selected role uses it. In a mixed
# Geth-sequencer/Reth-RPC topology, rpc1 is the initialization service.
RETH_INIT_REQUIRED=false
RETH_INIT_SERVICE=""
RETH_BASE_DATADIR_NAME=""
if [ "$SEQ_TYPE" = "reth" ]; then
    RETH_INIT_REQUIRED=true
    RETH_INIT_SERVICE="op-reth-seq"
    RETH_BASE_DATADIR_NAME="op-reth-seq"
elif [ "$LAUNCH_RPC_NODE" = "true" ] && [ "$RPC_TYPE" = "reth" ]; then
    RETH_INIT_REQUIRED=true
    RETH_INIT_SERVICE="op-reth-rpc"
    RETH_BASE_DATADIR_NAME="op-reth-rpc"
fi

# Build storage flags for op-reth init so the DB is initialized with the
# correct storage_v2 setting (it is written at genesis time and cannot be
# changed later without a full re-sync).
RETH_INIT_STORAGE_FLAGS=""
if [ "$RETH_INIT_REQUIRED" = "true" ]; then
    if [ "${RETH_STORAGE_V2:-false}" = "true" ]; then
        if [ -n "${RETH_ROCKSDB_PATH:-}" ]; then
            RETH_INIT_STORAGE_FLAGS="$RETH_INIT_STORAGE_FLAGS --datadir.rocksdb=$RETH_ROCKSDB_PATH"
        fi
    else
        # Newer upstream Reth defaults to storage v2, so explicitly opt out when
        # requested. Older XLayer builds do not expose this flag and would reject
        # it, so probe the init command exposed by the configured image first.
        if docker run --rm --entrypoint op-reth "$OP_RETH_IMAGE_TAG" init --help 2>/dev/null | grep -q -- '--storage.v2'; then
            RETH_INIT_STORAGE_FLAGS="--storage.v2=false"
        else
            echo " ℹ️ op-reth build has no --storage.v2 flag; skipping it"
        fi
    fi
fi

INIT_LOG="init.log"
if [ "$RETH_INIT_REQUIRED" = "true" ]; then
    echo " 🔧 Initializing selected Reth service $RETH_INIT_SERVICE..."
    docker compose run --no-deps --rm --entrypoint sh "$RETH_INIT_SERVICE" \
      -euc 'find /datadir -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +'

    if ! run_reth_init_logged "$INIT_LOG" \
      docker compose run --no-deps --rm \
        -v "$(pwd)/$CONFIG_DIR/genesis-reth.json:/genesis.json:ro" \
        --entrypoint op-reth \
        "$RETH_INIT_SERVICE" \
        init \
        --datadir=/datadir \
        --chain=/genesis.json \
        $RETH_INIT_STORAGE_FLAGS \
        --log.stdout.format=json; then
        exit 1
    fi

    if ! NEW_BLOCK_HASH=$(extract_reth_init_hash "$INIT_LOG"); then
        echo " ❌ Reth init completed but did not emit a valid genesis block hash" >&2
        exit 1
    fi
    if ! validate_bytes32 "$NEW_BLOCK_HASH"; then
        echo " ❌ Reth init hash is not a non-null bytes32: $NEW_BLOCK_HASH" >&2
        exit 1
    fi
    echo "NEW_BLOCK_HASH=$NEW_BLOCK_HASH"
    sed_inplace "s/NEW_BLOCK_HASH=.*/NEW_BLOCK_HASH=$NEW_BLOCK_HASH/" .env

    if [ "${USE_CHAINSPEC:-false}" = "true" ]; then
        if [ -z "$OP_RETH_LOCAL_DIRECTORY" ]; then
            echo " ❌ OP_RETH_LOCAL_DIRECTORY environment variable is not set."
            echo "This is required to re-build op-reth with chainspec."
            echo "Please set OP_RETH_LOCAL_DIRECTORY in your .env file"
            exit 1
        fi
        cd "$OP_RETH_LOCAL_DIRECTORY"
        if [ ! -f "crates/chainspec/res/genesis/xlayer-devnet-genesis-hash.txt" ]; then
            echo " ❌ crates/chainspec/res/genesis/xlayer-devnet-genesis-hash.txt not found."
            echo "This is required to re-build op-reth with chainspec."
            echo "Please run 'just build-docker' to build op-reth with chainspec."
            exit 1
        fi
        printf '%s\n' "$NEW_BLOCK_HASH" > crates/chainspec/res/genesis/xlayer-devnet-genesis-hash.txt
        cp "$PWD_DIR/config-op/xlayer-devnet.json" crates/chainspec/res/genesis/xlayer-devnet.json
        just build-docker
        cd "$PWD_DIR"
    fi

    clone_reth_datadir() {
        local source_name="$1" target_name="$2"
        [ "$source_name" = "$target_name" ] && return 0
        echo " 🔄 Copying initialized Reth database from $source_name to $target_name..."
        docker run --rm --user 0:0 \
          -e SOURCE_DATADIR_NAME="$source_name" \
          -e TARGET_DATADIR_NAME="$target_name" \
          -v "$(pwd)/data:/data" \
          --entrypoint sh "$OP_RETH_IMAGE_TAG" \
          -euc 'target="/data/$TARGET_DATADIR_NAME"; source="/data/$SOURCE_DATADIR_NAME"; find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true; mkdir -p "$target"; cp -a "$source"/. "$target"/'
    }

    write_reth_datadir_file() {
        local datadir_name="$1" filename="$2" contents="$3"
        docker run --rm --user 0:0 \
          -e TARGET_DATADIR_NAME="$datadir_name" \
          -e TARGET_FILENAME="$filename" \
          -e TARGET_CONTENTS="$contents" \
          -v "$(pwd)/data:/data" \
          --entrypoint sh "$OP_RETH_IMAGE_TAG" \
          -euc 'mkdir -p "/data/$TARGET_DATADIR_NAME"; printf %s "$TARGET_CONTENTS" > "/data/$TARGET_DATADIR_NAME/$TARGET_FILENAME"'
    }

    if [ "$SEQ_TYPE" = "reth" ]; then
        for ((i = 1; i <= SEQ_EFFECTIVE_COUNT; i++)); do
            source "config-op/cluster/seq$i/identity.env"
            SUFFIX_FOR_I=""
            [ "$i" -ne 1 ] && SUFFIX_FOR_I="$i"
            DATADIR_NAME="op-reth-seq${SUFFIX_FOR_I}"
            clone_reth_datadir "$RETH_BASE_DATADIR_NAME" "$DATADIR_NAME"
            write_reth_datadir_file "$DATADIR_NAME" discovery-secret "$DISCOVERY_SECRET"
            if [ "$FLASHBLOCK_ENABLED" = "true" ] && [ "$SEQ_EFFECTIVE_COUNT" -gt 1 ]; then
                write_reth_datadir_file "$DATADIR_NAME" fb-p2p-key "$FB_KEYPAIR"
            fi
        done
        echo "✅ Prepared $SEQ_EFFECTIVE_COUNT Reth sequencer datadir(s) with generated identities"
    fi

    if [ "$LAUNCH_RPC_NODE" = "true" ] && [ "$RPC_TYPE" = "reth" ]; then
        for ((i = 1; i <= RPC_EFFECTIVE_COUNT; i++)); do
            source "config-op/cluster/rpc$i/identity.env"
            RPC_SUFFIX=""
            [ "$i" -ne 1 ] && RPC_SUFFIX="$i"
            DATADIR_NAME="op-reth-rpc${RPC_SUFFIX}"
            clone_reth_datadir "$RETH_BASE_DATADIR_NAME" "$DATADIR_NAME"
            write_reth_datadir_file "$DATADIR_NAME" discovery-secret "$RPC_DISCOVERY_SECRET"
        done
        echo "✅ Prepared $RPC_EFFECTIVE_COUNT Reth RPC datadir(s) with generated identities"
    fi
fi

echo "✅ Finished init op-$SEQ_TYPE-seq and op-$RPC_TYPE-rpc."

# genesis.json is too large to embed in go, so we compress it now and decompress it in go code
gzip -c config-op/genesis.json > config-op/genesis.json.gz

# Check if MIN_RUN mode is enabled
if [ "$MIN_RUN" = "true" ]; then
    echo "⚡ MIN_RUN mode enabled: Skipping op-program prestate build"
    echo "✅ Initialization completed for minimal run (no dispute game support)"
    exit 0
fi

# Ensure prestate files exist and devnetL1.json is consistent before deploying contracts
EXPORT_DIR="$PWD_DIR/data/cannon-data"
SAVED_CANNON_DATA_DIR="$PWD_DIR/saved-cannon-data"

if [ "$SKIP_BUILD_PRESTATE" = "true" ] && [ -d "$SAVED_CANNON_DATA_DIR" ]; then
    echo "🔄 Skipping building op-program prestate files. Copying saved cannon data from $SAVED_CANNON_DATA_DIR to $EXPORT_DIR..."
    cp -r $SAVED_CANNON_DATA_DIR $EXPORT_DIR
    exit 0
fi

rm -rf $EXPORT_DIR
mkdir -p $EXPORT_DIR

echo "🔨 Building op-program prestate files..."

# Determine if we are using rootless Docker and set the appropriate Docker command
ROOTLESS_DOCKER=$(docker info -f "{{println .SecurityOptions}}" | grep rootless || true)
if ! [ -z "$ROOTLESS_DOCKER" ]; then
echo "Using rootless Docker!"
DOCKER_CMD="docker run --rm --privileged "
DOCKER_TYPE="rootless"
else
DOCKER_CMD="docker run --rm -v /var/run/docker.sock:/var/run/docker.sock "
DOCKER_TYPE="default"
fi

# Run the reproducible-prestate command
$DOCKER_CMD \
    -v "$(pwd)/scripts:/scripts" \
    -v "$(pwd)/config-op/rollup.json:/app/op-program/chainconfig/configs/${CHAIN_ID}-rollup.json" \
    -v "$(pwd)/config-op/genesis.json.gz:/app/op-program/chainconfig/configs/${CHAIN_ID}-genesis-l2.json" \
    -v "$(pwd)/l1-geth/execution/genesis.json:/app/op-program/chainconfig/configs/1337-genesis-l1.json" \
    -v "$EXPORT_DIR:/app/op-program/bin" \
    "${OP_STACK_IMAGE_TAG}" \
    bash -c " \
      /scripts/docker-install-start.sh $DOCKER_TYPE
      find /app/op-program/chainconfig/configs -name '*-genesis.json' -o -name '*-rollup.json' | xargs rm -f
      make -C op-program reproducible-prestate
    "

echo "🔄 Copying built prestate files from $EXPORT_DIR to $SAVED_CANNON_DATA_DIR..."
cp -r $EXPORT_DIR $SAVED_CANNON_DATA_DIR
