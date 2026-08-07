#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_ENV_PATH="${CLUSTER_ENV_PATH:-$(dirname "$SCRIPT_DIR")/config-op/cluster/cluster.env}"
[ -f "$CLUSTER_ENV_PATH" ] || { echo "❌ Missing generated cluster environment: $CLUSTER_ENV_PATH" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CLUSTER_ENV_PATH"
# shellcheck source=scripts/lib/cluster-services.sh
source "$SCRIPT_DIR/lib/cluster-services.sh"
require_conductor_utility_topology transfer-leader
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

# Find leader
for ((i = 1; i <= SEQ_EFFECTIVE_COUNT; i++)); do
    PORT_VAR="CONDUCTOR_RPC_PORT_$i"
    PORT="${!PORT_VAR:-}"
    [ -n "$PORT" ] || { echo "❌ Missing generated $PORT_VAR" >&2; exit 1; }
    IS_LEADER=$(query_leader "$PORT")
    if [ "$IS_LEADER" = "true" ]; then
        LEADER_PORT=$PORT
        OLD_LEADER=$i
        echo "conductor-$OLD_LEADER is leader (port $PORT)"
        break
    fi
done

[ "$LEADER_PORT" != "0" ] || { echo "❌ No conductor leader found" >&2; exit 1; }

# Transfer leadership
echo "Transferring leadership..."
if [ -n "${1:-}" ]; then
    if ! [[ "$1" =~ ^[1-9][0-9]*$ ]] || [ "$1" -gt "$SEQ_EFFECTIVE_COUNT" ]; then
        echo "❌ Target conductor must be between 1 and $SEQ_EFFECTIVE_COUNT; got $1" >&2
        exit 1
    fi
    # Transfer to specific node
    TARGET_NUM=$1
    # Check if target is current leader
    if [ "$TARGET_NUM" = "$OLD_LEADER" ]; then
        echo "Error: conductor-$TARGET_NUM is already the leader"
        exit 1
    fi
    ADDR="op-conductor"
    [ "$TARGET_NUM" != "1" ] && ADDR="${ADDR}${TARGET_NUM}"
    if ! curl --fail --silent --show-error -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"conductor_transferLeaderToServer","params":["conductor-'$TARGET_NUM'", "'$ADDR':50050"],"id":1}' "http://localhost:$LEADER_PORT" | jq -e 'type == "object" and (.error == null) and has("result")' >/dev/null; then
        echo "❌ Failed to request leadership transfer to conductor-$TARGET_NUM" >&2
        exit 1
    fi
    # Check if leader transferred to target node
    sleep 1
    TARGET_PORT_VAR="CONDUCTOR_RPC_PORT_$TARGET_NUM"
    TARGET_PORT="${!TARGET_PORT_VAR:-}"
    [ -n "$TARGET_PORT" ] || { echo "❌ Missing generated $TARGET_PORT_VAR" >&2; exit 1; }
    NEW_LEADER=$(query_leader "$TARGET_PORT")
    if [ "$NEW_LEADER" = "true" ]; then
        echo "Leadership transferred: conductor-$OLD_LEADER -> conductor-$TARGET_NUM"
    else
        echo "❌ Failed to transfer leadership from conductor-$OLD_LEADER to conductor-$TARGET_NUM" >&2
        exit 1
    fi
else
    # Auto select target node
    if ! curl --fail --silent --show-error -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"conductor_transferLeader","params":[],"id":1}' "http://localhost:$LEADER_PORT" | jq -e 'type == "object" and (.error == null) and has("result")' >/dev/null; then
        echo "❌ Failed to request automatic leadership transfer" >&2
        exit 1
    fi
    # Find new leader
    sleep 1
    echo "Checking new leader..."
    NEW_LEADER=0
    for ((i = 1; i <= SEQ_EFFECTIVE_COUNT; i++)); do
        PORT_VAR="CONDUCTOR_RPC_PORT_$i"
        PORT="${!PORT_VAR:-}"
        [ -n "$PORT" ] || { echo "❌ Missing generated $PORT_VAR" >&2; exit 1; }
        IS_LEADER=$(query_leader "$PORT")

        if [ "$IS_LEADER" = "true" ]; then
            NEW_LEADER=$i
            echo "Leadership transferred: conductor-$OLD_LEADER -> conductor-$i"
            break
        fi
    done
    if [ "$NEW_LEADER" -eq 0 ] || [ "$NEW_LEADER" -eq "$OLD_LEADER" ]; then
        echo "❌ No new conductor leader found after transfer" >&2
        exit 1
    fi
fi
