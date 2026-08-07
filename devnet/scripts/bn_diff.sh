#!/usr/bin/env bash

# usage:
# ./bn_diff.sh [seq_rpc] [rpc] [interval]
#
# default:
# seq_rpc = http://localhost:<generated seq1 EL HTTP port>
# rpc     = http://localhost:<generated rpc1 EL HTTP port>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config-op/cluster/cluster.env"

SEQ_RPC_URL="${1:-http://localhost:${EL_HTTP_PORT_1:-8123}}"
RPC_RPC_URL="${2:-http://localhost:${RPC_EL_HTTP_PORT_1:-8223}}"
INTERVAL="${3:-3}"

while true; do
    bn1=$(cast bn --rpc-url "$SEQ_RPC_URL" 2>/dev/null)
    bn2=$(cast bn --rpc-url "$RPC_RPC_URL" 2>/dev/null)

    if [[ -z "$bn1" || -z "$bn2" ]]; then
        echo "[$(date '+%F %T')] failed to fetch block number"
    else
        diff=$((bn1 - bn2))
        echo "[$(date '+%F %T')] seq=$bn1 rpc=$bn2 diff=$diff"
    fi

    sleep "$INTERVAL"
done
