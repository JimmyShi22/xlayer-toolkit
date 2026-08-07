#!/bin/bash
set -e
set -x

# Scheduler to run mempool rebroadcaster at regular intervals for a generated
# mixed Geth/Reth topology.
# Default interval is set at 1 minute (60 seconds)
INTERVAL="${MEMPOOL_REBROADCASTER_INTERVAL_SECONDS:-60}"
CLUSTER_ENV_PATH="${CLUSTER_ENV_PATH:-config-op/cluster/cluster.env}"
[ -f "$CLUSTER_ENV_PATH" ] || { echo "❌ Missing generated cluster environment: $CLUSTER_ENV_PATH" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CLUSTER_ENV_PATH"

if [ -z "${MEMPOOL_REBROADCASTER_GETH_ENDPOINT:-}" ] || [ -z "${MEMPOOL_REBROADCASTER_RETH_ENDPOINT:-}" ]; then
    echo "❌ Mempool rebroadcaster requires one selected Geth EL and one selected Reth EL; got SEQ_TYPE_EFFECTIVE=${SEQ_TYPE_EFFECTIVE:-unset}, RPC_TYPE_EFFECTIVE=${RPC_TYPE_EFFECTIVE:-unset}, RPC_EFFECTIVE_COUNT=${RPC_EFFECTIVE_COUNT:-0}" >&2
    exit 1
fi

echo "Starting mempool rebroadcaster scheduler with ${INTERVAL}s interval."
runs=0
max_runs="${MEMPOOL_REBROADCASTER_MAX_RUNS:-0}"

while true; do
    echo "$(date): Running mempool rebroadcaster..."
    docker compose run --rm mempool-rebroadcaster
    echo "$(date): Mempool rebroadcaster completed."
    runs=$((runs + 1))
    if [ "$max_runs" -gt 0 ] && [ "$runs" -ge "$max_runs" ]; then
        break
    fi
    sleep "$INTERVAL"
done
