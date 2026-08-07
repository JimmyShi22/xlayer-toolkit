#!/bin/bash
set -e
set -x

# Load environment variables early
source .env
# shellcheck source=scripts/lib/reth-init.sh
source ./scripts/lib/reth-init.sh

sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR=$PWD_DIR/scripts
source config-op/cluster/cluster.env

# Establish every selected EL container/DNS identity up front, but start only
# Sequencer ELs until the Sequencer/Conductor cluster is active.
"$SCRIPTS_DIR/start-cluster-services.sh" prepare
"$SCRIPTS_DIR/start-cluster-services.sh" seq-el

if [ "$SEQ_TYPE" = "geth" ]; then
    # Get the block hash at FORK_BLOCK+1
    TARGET_BLOCK=$((FORK_BLOCK + 1))
    echo "⏳ Waiting for block height to reach $TARGET_BLOCK..."
    while true; do
        CURRENT_BLOCK=$(cast bn -r "http://localhost:${EL_HTTP_PORT_1}" 2>/dev/null || echo "0")
        if [ "$CURRENT_BLOCK" -ge "$TARGET_BLOCK" ]; then
            echo "ok"
            break
        fi
        echo "   Current block height: $CURRENT_BLOCK, waiting for block $TARGET_BLOCK..."
        sleep 1
    done

    NEW_BLOCK_HASH=$(cast block "$TARGET_BLOCK" -r "http://localhost:${EL_HTTP_PORT_1}" --json | jq -r .hash)
    echo "New block hash: $NEW_BLOCK_HASH"
    if ! validate_bytes32 "$NEW_BLOCK_HASH"; then
        echo " ❌ Failed to get a non-null bytes32 block hash at block $TARGET_BLOCK"
        exit 1
    fi

    echo " ✅ Got block hash at block $TARGET_BLOCK: $NEW_BLOCK_HASH"
    sed_inplace "s/NEW_BLOCK_HASH=.*/NEW_BLOCK_HASH=$NEW_BLOCK_HASH/" .env
else
    echo "✅ Using existing NEW_BLOCK_HASH from .env for reth mode"
    if ! validate_bytes32 "${NEW_BLOCK_HASH:-}"; then
        echo "❌ NEW_BLOCK_HASH must be a non-null bytes32 in .env for reth mode"
        exit 1
    fi
    echo "New block hash: $NEW_BLOCK_HASH"
fi

# update genesis block hash in rollup.json
jq ".genesis.l2.hash = \"$NEW_BLOCK_HASH\"" config-op/rollup.json > config-op/rollup.json.tmp
mv config-op/rollup.json.tmp config-op/rollup.json

# Start Sequencer CLs only after the rollup hash is valid, then wait for every
# Conductor RPC plus a leader election before activating a Sequencer.
"$SCRIPTS_DIR/start-cluster-services.sh" seq-cl
"$SCRIPTS_DIR/start-cluster-services.sh" conductors
"$SCRIPTS_DIR/start-cluster-services.sh" activate

sleep 5

# Preserve upstream side-service ordering, then start RPC ELs and selected CLs.
"$SCRIPTS_DIR/start-cluster-services.sh" monitoring
"$SCRIPTS_DIR/start-cluster-services.sh" rpc-el
"$SCRIPTS_DIR/start-cluster-services.sh" rpc-cl

#$SCRIPTS_DIR/add-peers.sh

if [ "${RPC_CL_EFFECTIVE:-opnode}" = "kona" ] && [ -n "${KONA_RPC_URLS:-}" ]; then
    "$SCRIPTS_DIR"/kona-connect-peer.sh $KONA_RPC_URLS
fi

# OP_BATCHER_L2_ETH_RPC / OP_BATCHER_ROLLUP_RPC are computed by
# scripts/generate-cluster-identities.sh (run inside 3-op-init.sh) and
# written to config-op/cluster/cluster.env.
source config-op/cluster/cluster.env
export OP_BATCHER_L2_ETH_RPC
export OP_BATCHER_ROLLUP_RPC
echo "✅ op-batcher configured for $([ "$CONDUCTOR_ENABLED" = "true" ] && echo "conductor" || echo "single-sequencer") mode: $OP_BATCHER_L2_ETH_RPC"

docker compose up -d op-batcher

# Check if MIN_RUN mode is enabled
if [ "$MIN_RUN" = "true" ]; then
    echo ""
    echo "🎉 MIN_RUN deployment completed successfully!"
    echo ""
    exit 0
fi

PWD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd $PWD_DIR
EXPORT_DIR="$PWD_DIR/data/cannon-data"
mkdir -p $EXPORT_DIR

echo "Adding game type to DisputeGameFactory via op-deployer..."

# Retrieve existing values from chain for reference
# Get permissioned game implementation
PERMISSIONED_GAME=$(cast call --rpc-url $L1_RPC_URL $DISPUTE_GAME_FACTORY_ADDRESS "gameImpls(uint32)(address)" 1)

# Get prestate value from prestate-proof-mt64.json
ABSOLUTE_PRESTATE=$(jq -r '.pre' "$EXPORT_DIR/prestate-proof-mt64.json")
MAX_GAME_DEPTH=$(cast call --rpc-url $L1_RPC_URL $PERMISSIONED_GAME "maxGameDepth()")
SPLIT_DEPTH=$(cast call --rpc-url $L1_RPC_URL $PERMISSIONED_GAME "splitDepth()")
VM_RAW=$(cast call --rpc-url $L1_RPC_URL $PERMISSIONED_GAME "vm()")
VM="0x${VM_RAW: -40}"
ANCHOR_STATE_REGISTRY=$(cast call --rpc-url $L1_RPC_URL $PERMISSIONED_GAME "anchorStateRegistry()")
L2_CHAIN_ID=$(cast call --rpc-url $L1_RPC_URL $PERMISSIONED_GAME "l2ChainId()")

echo "✅ Game type 1 (permissioned) already deployed by op-deployer at: $PERMISSIONED_GAME"

echo "🔧 Adding new game type 1 with correct prestate..."
# Add new game type 1 using the correct prestate from file
"$SCRIPTS_DIR/add-game-type.sh" 1 true $CLOCK_EXTENSION $MAX_CLOCK_DURATION $ABSOLUTE_PRESTATE
NEW_GAME_TYPE_1=$(cast call --rpc-url $L1_RPC_URL $DISPUTE_GAME_FACTORY_ADDRESS "gameImpls(uint32)(address)" 1)
if [ "$NEW_GAME_TYPE_1" != "$PERMISSIONED_GAME" ] && [ "$NEW_GAME_TYPE_1" != "0x0000000000000000000000000000000000000000" ]; then
    echo " ✅ Game type 1 updated with correct prestate: $NEW_GAME_TYPE_1"
    PERMISSIONED_GAME=$NEW_GAME_TYPE_1
else
    echo " ⚠️  Game type 1 may not have been updated, using original: $PERMISSIONED_GAME"
fi

export GAME_TYPE=1
docker compose up -d op-proposer

echo "Waiting for op-proposer to create a game..."
GAME_CREATED=false
MAX_WAIT_TIME=600  # 10 minutes timeout
WAIT_COUNT=0

while [ "$GAME_CREATED" = false ] && [ $WAIT_COUNT -lt $MAX_WAIT_TIME ]; do
    # Check if a game was created by op-proposer
    GAME_COUNT=$(cast call --rpc-url $L1_RPC_URL $DISPUTE_GAME_FACTORY_ADDRESS "gameCount()(uint256)")
    if [ "$GAME_COUNT" -gt 0 ]; then
        echo " ✅ Game created! Game count: $GAME_COUNT"
        GAME_CREATED=true
    else
        echo " ⏳ Waiting for game creation... ($WAIT_COUNT/$MAX_WAIT_TIME seconds)"
        sleep 1
        WAIT_COUNT=$((WAIT_COUNT + 1))
    fi
done

if [ "$GAME_CREATED" = false ]; then
    echo " ❌ Timeout waiting for game creation"
    exit 1
fi

echo "🛑 Stopping op-proposer..."
docker compose stop op-proposer

echo "⏰ Sleeping for ($TEMP_MAX_CLOCK_DURATION seconds)..."
sleep $TEMP_MAX_CLOCK_DURATION
sleep 10

echo "🔧 Executing dispute resolution sequence using op-challenger..."

# Get the latest game address
LATEST_GAME_INDEX=$((GAME_COUNT - 1))
GAME_ADDRESS=$(cast call --json --rpc-url $L1_RPC_URL $DISPUTE_GAME_FACTORY_ADDRESS "gameAtIndex(uint256)(uint256,uint256,address)" $LATEST_GAME_INDEX | jq -r '.[-1]')
echo "Latest game address: $GAME_ADDRESS"

# Execute the dispute resolution sequence using op-challenger commands
echo "1. Resolving claim (0,0) using op-challenger..."
docker run --rm \
  --network "$DOCKER_NETWORK" \
  -v "$(pwd)/data/cannon-data:/data" \
  -v "$(pwd)/config-op/rollup.json:/rollup.json" \
  -v "$(pwd)/config-op/genesis.json:/l2-genesis.json" \
  "${OP_STACK_IMAGE_TAG}" \
  /app/op-challenger/bin/op-challenger resolve-claim \
    --l1-eth-rpc=${L1_RPC_URL_IN_DOCKER} \
    --private-key=${OP_CHALLENGER_PRIVATE_KEY} \
    --game-address=$GAME_ADDRESS \
    --claim=0

echo "2. Resolving game using op-challenger..."
docker run --rm \
  --network "$DOCKER_NETWORK" \
  -v "$(pwd)/data/cannon-data:/data" \
  -v "$(pwd)/config-op/rollup.json:/rollup.json" \
  -v "$(pwd)/config-op/genesis.json:/l2-genesis.json" \
  "${OP_STACK_IMAGE_TAG}" \
  /app/op-challenger/bin/op-challenger resolve \
    --l1-eth-rpc=${L1_RPC_URL_IN_DOCKER} \
    --private-key=${OP_CHALLENGER_PRIVATE_KEY} \
    --game-address=$GAME_ADDRESS

sleep $DISPUTE_GAME_FINALITY_DELAY_SECONDS

echo "3. Claiming credit for proposer using cast command..."
TX_OUTPUT=$(cast send --json \
    --legacy \
    --rpc-url $L1_RPC_URL \
    --private-key $OP_CHALLENGER_PRIVATE_KEY \
    $GAME_ADDRESS \
    "claimCredit(address)" \
    $PROPOSER_ADDRESS)

TX_HASH=$(echo "$TX_OUTPUT" | jq -r '.transactionHash // empty')
TX_STATUS=$(echo "$TX_OUTPUT" | jq -r '.status // empty')
if [ "$TX_STATUS" = "0x1" ] || [ "$TX_STATUS" = "1" ]; then
    echo " ✅ Credit claimed successfully"
else
    echo " ❌ Transaction failed with status: $TX_STATUS"
    echo "Full output: $TX_OUTPUT"
    exit 1
fi

echo " ✅ Dispute resolution sequence completed using op-challenger commands!"

# Retrieve existing values from chain for reference
# Get permissioned game implementation
PERMISSIONED_GAME=$(cast call --rpc-url $L1_RPC_URL $DISPUTE_GAME_FACTORY_ADDRESS "gameImpls(uint32)(address)" 1)
ANCHOR_STATE_REGISTRY=$(cast call --rpc-url $L1_RPC_URL $PERMISSIONED_GAME "anchorStateRegistry()")

# Call the function to add game type 0 (permissionless)
"$SCRIPTS_DIR/add-game-type.sh" 0 false $CLOCK_EXTENSION $MAX_CLOCK_DURATION $ABSOLUTE_PRESTATE

export GAME_TYPE=0

sleep $TEMP_GAME_WINDOW
docker compose up -d --remove-orphans op-proposer op-challenger op-dispute-mon
