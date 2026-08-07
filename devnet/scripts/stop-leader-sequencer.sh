#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_ENV_PATH="${CLUSTER_ENV_PATH:-$(dirname "$SCRIPT_DIR")/config-op/cluster/cluster.env}"
[ -f "$CLUSTER_ENV_PATH" ] || { echo "❌ Missing generated cluster environment: $CLUSTER_ENV_PATH" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CLUSTER_ENV_PATH"
# shellcheck source=scripts/lib/cluster-services.sh
source "$SCRIPT_DIR/lib/cluster-services.sh"
require_conductor_utility_topology stop-leader-sequencer
LEADER_PORT=0
OLD_LEADER=0

query_leader() {
    local port="$1" response
    response=$(curl --fail --silent --show-error -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"conductor_leader","params":[],"id":1}' \
        "http://localhost:$port" 2>/dev/null || true)
    printf '%s' "$response" | jq -r \
        'if (.error == null) and ((.result | type) == "boolean") then (.result | tostring) else empty end' \
        2>/dev/null || true
}

# Find current leader
for ((i = 1; i <= SEQ_EFFECTIVE_COUNT; i++)); do
    PORT_VAR="CONDUCTOR_RPC_PORT_$i"
    PORT="${!PORT_VAR:-}"
    [ -n "$PORT" ] || { echo "❌ Missing generated $PORT_VAR" >&2; exit 1; }
    IS_LEADER=$(query_leader "$PORT")

    if [ "$IS_LEADER" = "true" ]; then
        LEADER_PORT=$PORT
        OLD_LEADER=$i
        echo "conductor-$OLD_LEADER is current leader (port $PORT)"
        break
    fi
done

[ "$LEADER_PORT" != "0" ] || { echo "❌ No conductor leader found" >&2; exit 1; }

# Stop leader's sequencer
SEQUENCER_PORT_VAR="OPNODE_RPC_PORT_$OLD_LEADER"
SEQUENCER_PORT="${!SEQUENCER_PORT_VAR:-}"
[ -n "$SEQUENCER_PORT" ] || { echo "❌ Missing generated $SEQUENCER_PORT_VAR" >&2; exit 1; }
if ! curl --fail --silent --show-error -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"admin_stopSequencer","params":[],"id":1}' "http://localhost:$SEQUENCER_PORT" | jq -e 'type == "object" and (.error == null) and has("result")' >/dev/null; then
    echo "❌ Failed to stop sequencer through $SEQUENCER_PORT_VAR" >&2
    exit 1
fi
echo "sequencer stopped, waiting for leader transfer..."

# Wait and check for leader change every second
echo "Waiting for leader transfer..."
MAX_SECONDS=10
for ((second = 1; second <= MAX_SECONDS; second++)); do
    sleep 1
    NEW_LEADER=0
    for ((i = 1; i <= SEQ_EFFECTIVE_COUNT; i++)); do
        PORT_VAR="CONDUCTOR_RPC_PORT_$i"
        PORT="${!PORT_VAR:-}"
        [ -n "$PORT" ] || { echo "❌ Missing generated $PORT_VAR" >&2; exit 1; }
        IS_LEADER=$(query_leader "$PORT")
        if [ "$IS_LEADER" = "true" ]; then
            NEW_LEADER=$i
            if [ "$NEW_LEADER" != "$OLD_LEADER" ]; then
                echo "Leadership transferred: conductor-$OLD_LEADER -> conductor-$NEW_LEADER in (${second}s)"
                exit 0
            fi
        fi
    done
done
echo "❌ Leader transfer not detected after $MAX_SECONDS seconds" >&2
exit 1
