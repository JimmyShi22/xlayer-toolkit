#!/bin/sh
set -eu

ENV_FILE="${ENV_FILE:-/.env}"
IDENTITY_FILE="${IDENTITY_FILE:-/identity.env}"

[ -f "$ENV_FILE" ] || { echo "Missing Geth environment file: $ENV_FILE" >&2; exit 1; }
[ -f "$IDENTITY_FILE" ] || { echo "Missing generated Geth identity: $IDENTITY_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"
# shellcheck disable=SC1090
. "$IDENTITY_FILE"

[ -n "${DISCOVERY_SECRET:-}" ] || { echo "Generated sequencer DISCOVERY_SECRET is empty" >&2; exit 1; }

GETH_HELP=$(geth --help 2>/dev/null || true)
set -- \
    "--networkid=${CHAIN_ID}" \
    --verbosity=3 \
    --datadir=/datadir \
    "--db.engine=${DB_ENGINE:-pebble}" \
    --config=/config.toml \
    --gcmode=archive \
    --rollup.disabletxpoolgossip=false \
    "--nodekeyhex=${DISCOVERY_SECRET}"

if [ "${INDEX:-1}" = "1" ]; then
    set -- "$@" --pprof=true --pprof.addr=0.0.0.0 --pprof.port=9092
fi
if printf '%s' "$GETH_HELP" | grep -q -- '--rollup.allow-gasless'; then
    set -- "$@" "--rollup.allow-gasless=${ENABLE_GASLESS:-false}"
fi
if printf '%s' "$GETH_HELP" | grep -q -- '--rollup.gasless-mock-gas-price-percentile'; then
    set -- "$@" "--rollup.gasless-mock-gas-price-percentile=${GASLESS_MOCK_GAS_PRICE_PERCENTILE:-0.1}"
fi

exec geth "$@"
