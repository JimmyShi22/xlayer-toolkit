#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$SCRIPT_DIR")/config-op/cluster/cluster.env"

# Function to detect leader conductor and set ports
detect_leader() {
    echo "Detecting leader conductor..."

    for ((i = 1; i <= SEQ_EFFECTIVE_COUNT; i++)); do
        CONDUCTOR_PORT_VAR="CONDUCTOR_RPC_PORT_$i"
        SEQUENCER_PORT_VAR="OPNODE_RPC_PORT_$i"
        CONDUCTOR_PORT="${!CONDUCTOR_PORT_VAR}"
        SEQUENCER_PORT="${!SEQUENCER_PORT_VAR}"

        IS_LEADER=$(curl -sS -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"conductor_leader","params":[],"id":1}' \
            http://localhost:$CONDUCTOR_PORT 2>/dev/null | jq -r '.result' 2>/dev/null)

        if [ "$IS_LEADER" = "true" ]; then
            LEADER_CONDUCTOR_PORT=$CONDUCTOR_PORT
            LEADER_SEQUENCER_PORT=$SEQUENCER_PORT
            echo "Found leader: Conductor $i (conductor port: $LEADER_CONDUCTOR_PORT, sequencer port: $LEADER_SEQUENCER_PORT)"
            return 0
        else
            echo "Conductor $i (port $CONDUCTOR_PORT): not leader (result: $IS_LEADER)"
        fi
    done

    echo "Error: No leader conductor found!"
    exit 1
}

# Detect leader conductor and set ports
detect_leader

# 1. check connected peers
CONNECTED=$(curl -sS -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"opp2p_peerStats","params":[],"id":1}' http://localhost:$LEADER_SEQUENCER_PORT | jq .result.connected)
if (( CONNECTED < 2 )); then
    echo "$CONNECTED peers connected, which is less than 2"
    echo 1
fi

# 2. try to resume conductor if it is paused
PAUSED=$(curl -sS -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"conductor_paused","params":[],"id":1}' http://localhost:$LEADER_CONDUCTOR_PORT | jq -r .result)
if [ $PAUSED = "true" ]; then
    curl -sS -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"conductor_resume","params":[],"id":1}' http://localhost:$LEADER_CONDUCTOR_PORT
    PAUSED=$(curl -sS -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"conductor_paused","params":[],"id":1}' http://localhost:$LEADER_CONDUCTOR_PORT | jq -r .result)
    if [ $PAUSED = "true" ]; then
        echo "conductor is paused due to resume failure"
        exit 1
    fi
fi

# 3. try to start sequencer if it is stopped
ACTIVE=$(curl -sS -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"admin_sequencerActive","params":[],"id":1}' http://localhost:$LEADER_CONDUCTOR_PORT | jq -r .result)
if [ $ACTIVE = "false" ]; then
    source config-op/cluster/seq1/identity.env
    BLOCK_HASH=$(curl -sS -X POST -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}'  http://localhost:$EL_HTTP_PORT | jq -r .result.hash)
    if [ -z "$BLOCK_HASH" ] || [ "$BLOCK_HASH" = "null" ]; then
        echo "Failed to get latest block hash"
        exit 1
    fi
    echo "Got latest block hash: $BLOCK_HASH"

    # 3. Start sequencer with the block hash
    curl -sS -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"admin_startSequencer","params":["'"$BLOCK_HASH"'"],"id":1}' http://localhost:$LEADER_SEQUENCER_PORT
    if [ $? -ne 0 ]; then
        echo "Failed to start sequencer"
        exit 1
    fi
fi

# 4. verify sequencer is active
sleep 1
ACTIVE=$(curl -sS -X POST -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","method":"admin_sequencerActive","params":[],"id":1}' http://localhost:$LEADER_SEQUENCER_PORT | jq -r .result)
if [ "$ACTIVE" != "true" ]; then
    echo "Failed to activate sequencer"
    exit 1
fi

echo "Sequencer successfully activated"

# 5. try to add the remaining conductors to raft consensus cluster
SERVER_COUNT=$(curl -sS -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"conductor_clusterMembership","params":[],"id":1}' http://localhost:$LEADER_CONDUCTOR_PORT  | jq '.result.servers | length')
if (( $SERVER_COUNT < SEQ_EFFECTIVE_COUNT )); then
    for ((i = 2; i <= SEQ_EFFECTIVE_COUNT; i++)); do
        curl -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"conductor_addServerAsVoter","params":["conductor-'"$i"'", "op-conductor'"$i"':50050", 0],"id":1}' http://localhost:$LEADER_CONDUCTOR_PORT
    done
    SERVER_COUNT=$(curl -sS -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"conductor_clusterMembership","params":[],"id":1}' http://localhost:$LEADER_CONDUCTOR_PORT  | jq '.result.servers | length')
    if (( $SERVER_COUNT != SEQ_EFFECTIVE_COUNT )); then
        echo "unexpected server count, expected: $SEQ_EFFECTIVE_COUNT, real: $SERVER_COUNT"
        exit 1
    fi

    echo "add $((SEQ_EFFECTIVE_COUNT - 1)) new voter(s) to raft consensus cluster successfully!"
fi
