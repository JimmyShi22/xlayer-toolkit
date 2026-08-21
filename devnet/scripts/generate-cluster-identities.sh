#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$REPO_DIR"
# shellcheck source=scripts/lib/rcs-services.sh
source "$SCRIPT_DIR/lib/rcs-services.sh"

# --- Validate SEQ_COUNT ---
SEQ_COUNT="${SEQ_COUNT:-3}"
if ! [[ "$SEQ_COUNT" =~ ^[0-9]+$ ]] || [ "$SEQ_COUNT" -lt 1 ]; then
    echo "❌ SEQ_COUNT must be a positive integer, got: '$SEQ_COUNT'" >&2
    exit 1
fi

RPC_COUNT="${RPC_COUNT:-1}"
if ! [[ "$RPC_COUNT" =~ ^[0-9]+$ ]] || [ "$RPC_COUNT" -lt 1 ]; then
    echo "❌ RPC_COUNT must be a positive integer, got: '$RPC_COUNT'" >&2
    exit 1
fi

# --- Resolve effective node count ---
if [ "${CONDUCTOR_ENABLED:-false}" = "true" ]; then
    N=$SEQ_COUNT
    if [ "$N" -eq 1 ]; then
        echo "❌ CONDUCTOR_ENABLED=true requires SEQ_COUNT >= 2; got SEQ_COUNT=1" >&2
        exit 1
    fi
    if [ "$N" -eq 2 ]; then
        echo "⚠️  SEQ_COUNT=2: a 2-node raft cluster has no majority-quorum fault tolerance." >&2
    fi
else
    if [ "$SEQ_COUNT" -gt 1 ]; then
        echo "⚠️  CONDUCTOR_ENABLED=false: ignoring SEQ_COUNT=$SEQ_COUNT, using a single sequencer." >&2
    fi
    N=1
fi

if [ "${LAUNCH_RPC_NODE:-false}" = "true" ]; then
    RPC_N=$RPC_COUNT
else
    RPC_N=0
fi

# Flashblocks requires Reth for each selected role. RPC_TYPE is intentionally
# ignored when no RPC node is launched, because it is stale/inactive config.
if [ "${FLASHBLOCK_ENABLED:-false}" = "true" ]; then
    if [ "${SEQ_TYPE:-reth}" != "reth" ]; then
        echo "❌ FLASHBLOCK_ENABLED=true requires selected SEQ_TYPE=reth; got SEQ_TYPE=${SEQ_TYPE:-reth}" >&2
        exit 1
    fi
    if [ "$RPC_N" -gt 0 ] && [ "${RPC_TYPE:-reth}" != "reth" ]; then
        echo "❌ FLASHBLOCK_ENABLED=true requires selected RPC_TYPE=reth when RPC nodes are launched; got RPC_TYPE=${RPC_TYPE:-reth}" >&2
        exit 1
    fi
fi

SEQ_CL="${SEQ_CL:-opnode}"
RPC_CL="${RPC_CL:-opnode}"
SEQ_TYPE="${SEQ_TYPE:-reth}"
RPC_TYPE="${RPC_TYPE:-reth}"
case "$SEQ_TYPE" in reth|geth) ;; *) echo "❌ SEQ_TYPE must be 'reth' or 'geth', got: '$SEQ_TYPE'" >&2; exit 1 ;; esac
case "$RPC_TYPE" in reth|geth) ;; *) echo "❌ RPC_TYPE must be 'reth' or 'geth', got: '$RPC_TYPE'" >&2; exit 1 ;; esac
case "$SEQ_CL" in opnode|kona) ;; *) echo "❌ SEQ_CL must be 'opnode' or 'kona', got: '$SEQ_CL'" >&2; exit 1 ;; esac
case "$RPC_CL" in opnode|kona) ;; *) echo "❌ RPC_CL must be 'opnode' or 'kona', got: '$RPC_CL'" >&2; exit 1 ;; esac
if [ "$SEQ_CL" = "kona" ] && { [ "${CONDUCTOR_ENABLED:-false}" = "true" ] || [ "$N" -ne 1 ]; }; then
    echo "❌ SEQ_CL=kona requires CONDUCTOR_ENABLED=false and one effective sequencer" >&2
    exit 1
fi
rcs_validate_settings "$N" "$SEQ_TYPE"

# Reject impossible topologies before generating any cryptographic identity.
# The highest preferred families are conductor consensus (50049 + seq index),
# RPC Kona (9545 + 10 * RPC index), and RPC metrics (37000 + RPC index).
# The allocator also checks every chosen candidate after collision skips.
if [ "$N" -gt 15486 ]; then
    echo "❌ SEQ_COUNT=$N cannot fit generated host ports within the 1..65535 range" >&2
    exit 1
fi
if [ "$RPC_N" -gt 5599 ]; then
    echo "❌ RPC_COUNT=$RPC_N cannot fit generated host ports within the 1..65535 range" >&2
    exit 1
fi

CLUSTER_DIR="$REPO_DIR/config-op/cluster"
rm -rf "$CLUSTER_DIR"
mkdir -p "$CLUSTER_DIR"

# --- Global, protocol-aware host-port allocator ---
# These are all host ports published by the static docker-compose.yml. TCP and
# UDP are tracked independently; a devp2p port reserves the same number once
# for each protocol, which is valid and intentional.
ALLOCATED_PORT_KEYS=""

port_key_is_allocated() {
    local key="$1"
    case " $ALLOCATED_PORT_KEYS " in
        *" $key "*) return 0 ;;
        *) return 1 ;;
    esac
}

reserve_port_key() {
    local port="$1" protocol="$2" owner="$3"
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "❌ Host port for $owner is outside 1..65535: $port/$protocol" >&2
        exit 1
    fi
    local key="${protocol}:${port}"
    if port_key_is_allocated "$key"; then
        echo "❌ Host port collision while reserving $owner: $port/$protocol" >&2
        exit 1
    fi
    ALLOCATED_PORT_KEYS="${ALLOCATED_PORT_KEYS:+$ALLOCATED_PORT_KEYS }$key"
}

for static_tcp_port in 3000 3500 4000 6060 8545 8546 8551 9000 9001 9090 18080 19090; do
    reserve_port_key "$static_tcp_port" tcp "docker-compose.yml"
done
rcs_reserve_host_ports "$N"

# Set the named output variable to the first globally free port at or after
# base+index. Using printf -v avoids command-substitution subshells, so every
# family participates in the same allocation registry.
allocate_port() {
    local output_variable="$1" base="$2" index="$3" protocol="$4" owner="$5"
    local port=$((base + index))
    while [ "$port" -le 65535 ] && port_key_is_allocated "${protocol}:${port}"; do
        port=$((port + 1))
    done
    if [ "$port" -gt 65535 ]; then
        echo "❌ Could not allocate an in-range host port for $owner near $((base + index)); maximum is 65535" >&2
        exit 1
    fi
    reserve_port_key "$port" "$protocol" "$owner"
    printf -v "$output_variable" '%s' "$port"
}

allocate_dual_protocol_port() {
    local output_variable="$1" base="$2" index="$3" owner="$4"
    local port=$((base + index))
    while [ "$port" -le 65535 ] && { port_key_is_allocated "tcp:${port}" || port_key_is_allocated "udp:${port}"; }; do
        port=$((port + 1))
    done
    if [ "$port" -gt 65535 ]; then
        echo "❌ Could not allocate an in-range TCP/UDP host port for $owner near $((base + index)); maximum is 65535" >&2
        exit 1
    fi
    reserve_port_key "$port" tcp "$owner"
    reserve_port_key "$port" udp "$owner"
    printf -v "$output_variable" '%s' "$port"
}

# --- Per-node identity + port generation ---
for ((i = 1; i <= N; i++)); do
    NODE_DIR="$CLUSTER_DIR/seq$i"
    mkdir -p "$NODE_DIR"

    SUFFIX=""
    [ "$i" -ne 1 ] && SUFFIX="$i"

    DISCOVERY_SECRET=$(openssl rand -hex 32)
    ENODE_PUBKEY=$(cast wallet public-key --raw-private-key "0x$DISCOVERY_SECRET" | sed 's/^0x//')

    FB_PEM=$(mktemp)
    openssl genpkey -algorithm ED25519 -out "$FB_PEM" 2>/dev/null
    FB_PRIV=$(openssl pkey -in "$FB_PEM" -text -noout | awk '/priv:/{flag=1;next}/pub:/{flag=0}flag' | tr -d ' \n:')
    FB_PUB=$(openssl pkey -in "$FB_PEM" -text -noout | awk '/pub:/{flag=1;next}flag' | tr -d ' \n:')
    rm -f "$FB_PEM"
    FB_KEYPAIR="${FB_PRIV}${FB_PUB}"
    FB_PEER_ID=$(python3 "$SCRIPT_DIR/lib/derive-peer-id.py" ed25519 "$FB_PUB")

    OPNODE_P2P_PRIV=$(openssl rand -hex 32)
    OPNODE_UNCOMPRESSED_PUBKEY=$(cast wallet public-key --raw-private-key "0x$OPNODE_P2P_PRIV" | sed 's/^0x//')
    OPNODE_COMPRESSED_PUBKEY=$(python3 -c "
pub = bytes.fromhex('$OPNODE_UNCOMPRESSED_PUBKEY')
x, y = pub[:32], pub[32:]
prefix = 0x02 if y[-1] % 2 == 0 else 0x03
print((bytes([prefix]) + x).hex())
")
    OPNODE_PEER_ID=$(python3 "$SCRIPT_DIR/lib/derive-peer-id.py" secp256k1 "$OPNODE_COMPRESSED_PUBKEY")

    RAFT_SERVER_ID="conductor-$i"

    allocate_port EL_HTTP_PORT 8122 "$i" tcp "seq$i EL HTTP"
    allocate_dual_protocol_port EL_P2P_PORT 31000 "$i" "seq$i EL devp2p"
    allocate_port FLASHBLOCKS_WS_PORT 32000 "$i" tcp "seq$i flashblocks WS"
    allocate_port OPNODE_RPC_PORT 9544 "$i" tcp "seq$i CL RPC"
    allocate_dual_protocol_port OPNODE_P2P_HOST_PORT 9222 "$i" "seq$i CL P2P"
    allocate_port CONDUCTOR_RPC_PORT 8546 "$i" tcp "seq$i conductor RPC"
    allocate_port CONDUCTOR_CONSENSUS_PORT 50049 "$i" tcp "seq$i conductor consensus"

    EL_WS_HOST_PORT=""
    EL_AUTHRPC_HOST_PORT=""
    EL_METRICS_HOST_PORT=""
    EL_PPROF_HOST_PORT=""
    CL_DEBUG_HOST_PORT=""
    CL_METRICS_HOST_PORT=""
    if [ "$i" -eq 1 ]; then
        allocate_port EL_WS_HOST_PORT 7546 0 tcp "seq1 EL WebSocket"
        allocate_port EL_AUTHRPC_HOST_PORT 8552 0 tcp "seq1 EL auth RPC"
        if [ "$SEQ_TYPE" = "reth" ]; then
            allocate_port EL_METRICS_HOST_PORT 9001 0 tcp "seq1 Reth metrics"
        else
            allocate_port EL_PPROF_HOST_PORT 9092 0 tcp "seq1 Geth pprof"
        fi
        if [ "$SEQ_CL" = "opnode" ]; then
            allocate_port CL_DEBUG_HOST_PORT 7070 0 tcp "seq1 op-node debug"
        fi
        allocate_port CL_METRICS_HOST_PORT 9091 0 tcp "seq1 CL metrics/pprof"
    fi

    cat > "$NODE_DIR/identity.env" <<EOF
INDEX=$i
SUFFIX=$SUFFIX
DISCOVERY_SECRET=$DISCOVERY_SECRET
ENODE_PUBKEY=$ENODE_PUBKEY
FB_KEYPAIR=$FB_KEYPAIR
FB_PEER_ID=$FB_PEER_ID
OPNODE_P2P_PRIV=$OPNODE_P2P_PRIV
OPNODE_PEER_ID=$OPNODE_PEER_ID
RAFT_SERVER_ID=$RAFT_SERVER_ID
EL_HTTP_PORT=$EL_HTTP_PORT
EL_P2P_PORT=$EL_P2P_PORT
FLASHBLOCKS_WS_PORT=$FLASHBLOCKS_WS_PORT
OPNODE_RPC_PORT=$OPNODE_RPC_PORT
OPNODE_P2P_HOST_PORT=$OPNODE_P2P_HOST_PORT
CONDUCTOR_RPC_PORT=$CONDUCTOR_RPC_PORT
CONDUCTOR_CONSENSUS_PORT=$CONDUCTOR_CONSENSUS_PORT
EL_WS_HOST_PORT=$EL_WS_HOST_PORT
EL_AUTHRPC_HOST_PORT=$EL_AUTHRPC_HOST_PORT
EL_METRICS_HOST_PORT=$EL_METRICS_HOST_PORT
EL_PPROF_HOST_PORT=$EL_PPROF_HOST_PORT
CL_DEBUG_HOST_PORT=$CL_DEBUG_HOST_PORT
CL_METRICS_HOST_PORT=$CL_METRICS_HOST_PORT
EOF
done

# --- Per-RPC-node identity + port generation ---
# RPC identities include a Reth devp2p enode so strict trusted-peer topology
# can admit every EL node. RPC nodes do not need an op-node libp2p peer ID.
for ((i = 1; i <= RPC_N; i++)); do
    NODE_DIR="$CLUSTER_DIR/rpc$i"
    mkdir -p "$NODE_DIR"

    SUFFIX=""
    [ "$i" -ne 1 ] && SUFFIX="$i"

    RPC_DISCOVERY_SECRET=$(openssl rand -hex 32)
    RPC_ENODE_PUBKEY=$(cast wallet public-key --raw-private-key "0x$RPC_DISCOVERY_SECRET" | sed 's/^0x//')
    RPC_OPNODE_P2P_PRIV=$(openssl rand -hex 32)

    allocate_port RPC_EL_HTTP_PORT 8222 "$i" tcp "rpc$i EL HTTP"
    allocate_dual_protocol_port RPC_EL_P2P_PORT 33000 "$i" "rpc$i EL devp2p"
    allocate_port RPC_FLASHBLOCKS_WS_PORT 34000 "$i" tcp "rpc$i flashblocks WS"
    allocate_port RPC_EL_WS_PORT 35000 "$i" tcp "rpc$i EL WebSocket"
    allocate_port RPC_EL_METRICS_PORT 36000 "$i" tcp "rpc$i EL metrics"
    allocate_port RPC_OPNODE_RPC_PORT 9644 "$i" tcp "rpc$i CL RPC"
    allocate_dual_protocol_port RPC_OPNODE_P2P_HOST_PORT 9322 "$i" "rpc$i CL P2P"
    allocate_port RPC_KONA_RPC_PORT 9545 "$((10 * i))" tcp "rpc$i Kona RPC"
    allocate_port RPC_KONA_METRICS_PORT 37000 "$i" tcp "rpc$i Kona metrics"

    # Flashblocks pairing: rpc{i} subscribes to seq{paired_seq_index}, round-robin
    # when RPC_N > SEQ_COUNT.
    PAIRED_SEQ_INDEX=$(( (i - 1) % SEQ_COUNT + 1 ))
    PAIRED_SEQ_SUFFIX=""
    if [ -f "$CLUSTER_DIR/seq$PAIRED_SEQ_INDEX/identity.env" ]; then
        PAIRED_SEQ_SUFFIX=$(grep '^SUFFIX=' "$CLUSTER_DIR/seq$PAIRED_SEQ_INDEX/identity.env" | cut -d= -f2)
    fi
    FB_URL="ws://op-reth-seq${PAIRED_SEQ_SUFFIX}:1111"

    cat > "$NODE_DIR/identity.env" <<EOF
INDEX=$i
SUFFIX=$SUFFIX
RPC_DISCOVERY_SECRET=$RPC_DISCOVERY_SECRET
RPC_ENODE_PUBKEY=$RPC_ENODE_PUBKEY
RPC_OPNODE_P2P_PRIV=$RPC_OPNODE_P2P_PRIV
RPC_EL_HTTP_PORT=$RPC_EL_HTTP_PORT
RPC_EL_P2P_PORT=$RPC_EL_P2P_PORT
RPC_FLASHBLOCKS_WS_PORT=$RPC_FLASHBLOCKS_WS_PORT
RPC_EL_WS_PORT=$RPC_EL_WS_PORT
RPC_EL_METRICS_PORT=$RPC_EL_METRICS_PORT
RPC_OPNODE_RPC_PORT=$RPC_OPNODE_RPC_PORT
RPC_OPNODE_P2P_HOST_PORT=$RPC_OPNODE_P2P_HOST_PORT
RPC_KONA_RPC_PORT=$RPC_KONA_RPC_PORT
RPC_KONA_METRICS_PORT=$RPC_KONA_METRICS_PORT
FB_URL=$FB_URL
EOF
done

# --- Aggregate values ---
TRUSTED_PEERS=""
for ((i = 1; i <= N; i++)); do
    source "$CLUSTER_DIR/seq$i/identity.env"
    ENTRY="enode://${ENODE_PUBKEY}@op-${SEQ_TYPE}-seq${SUFFIX}:30303"
    if [ -z "$TRUSTED_PEERS" ]; then
        TRUSTED_PEERS="$ENTRY"
    else
        TRUSTED_PEERS="${TRUSTED_PEERS},${ENTRY}"
    fi
done

if [ "${TRUSTED_NODES_ONLY:-false}" = "true" ]; then
    for ((i = 1; i <= RPC_N; i++)); do
        source "$CLUSTER_DIR/rpc$i/identity.env"
        ENTRY="enode://${RPC_ENODE_PUBKEY}@op-${RPC_TYPE}-rpc${SUFFIX}:30303"
        TRUSTED_PEERS="${TRUSTED_PEERS},${ENTRY}"
    done
fi

if [ "$N" -gt 1 ]; then
    OP_BATCHER_L2_ETH_RPC=""
    for ((i = 1; i <= N; i++)); do
        source "$CLUSTER_DIR/seq$i/identity.env"
        ENTRY="http://op-conductor${SUFFIX}:8547"
        if [ -z "$OP_BATCHER_L2_ETH_RPC" ]; then
            OP_BATCHER_L2_ETH_RPC="$ENTRY"
        else
            OP_BATCHER_L2_ETH_RPC="${OP_BATCHER_L2_ETH_RPC},${ENTRY}"
        fi
    done
    OP_BATCHER_ROLLUP_RPC="$OP_BATCHER_L2_ETH_RPC"
else
    OP_BATCHER_L2_ETH_RPC="http://op-${SEQ_TYPE}-seq:8545"
    OP_BATCHER_ROLLUP_RPC="http://op-seq:9545"
fi

# Export each dependency layer separately. Startup creates and starts every
# selected EL first, waits for readiness, then starts CL peer managers and only
# then Conductors. CLUSTER_UP_SERVICES remains for compatibility with existing
# helper scripts, but 4-op-start-service.sh uses the ordered lists below.
SEQ_EL_SERVICES=""
SEQ_CL_SERVICES=""
CONDUCTOR_SERVICES=""
for ((i = 1; i <= N; i++)); do
    source "$CLUSTER_DIR/seq$i/identity.env"
    EL_ENTRY="op-${SEQ_TYPE}-seq${SUFFIX}"
    if [ "$SEQ_CL" = "kona" ]; then
        CL_ENTRY="op-kona-seq${SUFFIX}"
    else
        CL_ENTRY="op-seq${SUFFIX}"
    fi
    SEQ_EL_SERVICES="${SEQ_EL_SERVICES:+$SEQ_EL_SERVICES }$EL_ENTRY"
    SEQ_CL_SERVICES="${SEQ_CL_SERVICES:+$SEQ_CL_SERVICES }$CL_ENTRY"
    if [ "$N" -gt 1 ]; then
        CONDUCTOR_ENTRY="op-conductor${SUFFIX}"
        CONDUCTOR_SERVICES="${CONDUCTOR_SERVICES:+$CONDUCTOR_SERVICES }$CONDUCTOR_ENTRY"
    fi
done
if [ -n "$CONDUCTOR_SERVICES" ]; then
    CLUSTER_UP_SERVICES="$CONDUCTOR_SERVICES"
else
    CLUSTER_UP_SERVICES="$SEQ_EL_SERVICES $SEQ_CL_SERVICES"
fi

# ALL_SEQ_OPNODE_PEERS: every seq op-node's libp2p peer address, used verbatim
# as --p2p.static on every RPC node (RPC fans out to the whole seq cluster,
# it never excludes itself the way seq's own mesh does).
ALL_SEQ_OPNODE_PEERS=""
for ((j = 1; j <= N; j++)); do
    source "$CLUSTER_DIR/seq$j/identity.env"
    ENTRY="/dns4/op-seq${SUFFIX}/tcp/9223/p2p/${OPNODE_PEER_ID}"
    if [ -z "$ALL_SEQ_OPNODE_PEERS" ]; then
        ALL_SEQ_OPNODE_PEERS="$ENTRY"
    else
        ALL_SEQ_OPNODE_PEERS="${ALL_SEQ_OPNODE_PEERS},${ENTRY}"
    fi
done

# Render a per-node Geth config from the selected service identities. Static
# configs committed in config-op contain historical fixed enodes and cannot
# represent arbitrary or mixed Reth/Geth topologies.
write_geth_config() {
    local output="$1" own_host="$2"
    local static_lines="" trusted_lines="" peer
    local old_ifs="$IFS"
    IFS=','
    for peer in $TRUSTED_PEERS; do
        [ -z "$peer" ] && continue
        case "$peer" in *"@${own_host}:"*) continue ;; esac
        static_lines="${static_lines}  \"${peer}\",\n"
        if [ "${TRUSTED_NODES_ONLY:-false}" = "true" ]; then
            trusted_lines="${trusted_lines}  \"${peer}\",\n"
        fi
    done
    IFS="$old_ifs"

    cat > "$output" <<EOF
[Node]
HTTPHost = "0.0.0.0"
HTTPPort = 8545
HTTPCors = ["*"]
HTTPVirtualHosts = ["*"]
HTTPModules = ["web3", "debug", "eth", "txpool", "net", "engine", "miner", "admin"]
WSHost = "0.0.0.0"
WSPort = 7546
WSOrigins = ["*"]
WSModules = ["debug", "eth", "txpool", "net", "engine"]
AuthAddr = "0.0.0.0"
AuthPort = 8552
AuthVirtualHosts = ["*"]
JWTSecret = "/jwt.txt"

[Node.P2P]
MaxPeers = 100
DiscoveryV5 = false
TrustedNodes = [
$(printf '%b' "$trusted_lines")]
StaticNodes = [
$(printf '%b' "$static_lines")]

[Eth]
SyncMode = "full"

[Eth.TxPool]
GlobalSlots = 500000
GlobalQueue = 100000
AccountSlots = 50000
AccountQueue = 10000

[Eth.GPO]
MinSuggestedPriorityFee = 1
EOF
}

if [ "$SEQ_TYPE" = "geth" ]; then
    for ((i = 1; i <= N; i++)); do
        source "$CLUSTER_DIR/seq$i/identity.env"
        write_geth_config "$CLUSTER_DIR/seq$i/geth.toml" "op-geth-seq${SUFFIX}"
    done
fi
if [ "$RPC_TYPE" = "geth" ]; then
    for ((i = 1; i <= RPC_N; i++)); do
        source "$CLUSTER_DIR/rpc$i/identity.env"
        write_geth_config "$CLUSTER_DIR/rpc$i/geth.toml" "op-geth-rpc${SUFFIX}"
    done
fi

RPC_EL_SERVICES=""
RPC_OPNODE_SERVICES=""
RPC_CL_SERVICES=""
KONA_RPC_URLS=""
for ((i = 1; i <= RPC_N; i++)); do
    source "$CLUSTER_DIR/rpc$i/identity.env"
    EL_ENTRY="op-${RPC_TYPE}-rpc${SUFFIX}"
    OPNODE_ENTRY="op-rpc${SUFFIX}"
    if [ "$RPC_CL" = "kona" ]; then
        RPC_CL_ENTRY="op-kona-rpc${SUFFIX}"
        KONA_URL_ENTRY="http://localhost:${RPC_KONA_RPC_PORT}"
    else
        RPC_CL_ENTRY="op-rpc${SUFFIX}"
        KONA_URL_ENTRY=""
    fi
    if [ -z "$RPC_EL_SERVICES" ]; then
        RPC_EL_SERVICES="$EL_ENTRY"
        RPC_OPNODE_SERVICES="$OPNODE_ENTRY"
        RPC_CL_SERVICES="$RPC_CL_ENTRY"
    else
        RPC_EL_SERVICES="${RPC_EL_SERVICES} ${EL_ENTRY}"
        RPC_OPNODE_SERVICES="${RPC_OPNODE_SERVICES} ${OPNODE_ENTRY}"
        RPC_CL_SERVICES="${RPC_CL_SERVICES} ${RPC_CL_ENTRY}"
    fi
    if [ -n "$KONA_URL_ENTRY" ]; then
        if [ -z "$KONA_RPC_URLS" ]; then
            KONA_RPC_URLS="$KONA_URL_ENTRY"
        else
            KONA_RPC_URLS="${KONA_RPC_URLS} ${KONA_URL_ENTRY}"
        fi
    fi
done

ALL_EL_SERVICES="${SEQ_EL_SERVICES}${RPC_EL_SERVICES:+ $RPC_EL_SERVICES}"
ALL_CL_SERVICES="${SEQ_CL_SERVICES}${RPC_CL_SERVICES:+ $RPC_CL_SERVICES}"

# The rebroadcaster compares one selected Geth pool with one selected Reth
# pool. Prefer sequencer node 1 for its selected client and fall back to RPC
# node 1 when it supplies the other client type.
MEMPOOL_REBROADCASTER_GETH_ENDPOINT=""
MEMPOOL_REBROADCASTER_RETH_ENDPOINT=""
case "$SEQ_TYPE" in
    geth) MEMPOOL_REBROADCASTER_GETH_ENDPOINT="http://op-geth-seq:8545" ;;
    reth) MEMPOOL_REBROADCASTER_RETH_ENDPOINT="http://op-reth-seq:8545" ;;
esac
if [ "$RPC_N" -gt 0 ]; then
    case "$RPC_TYPE" in
        geth) [ -n "$MEMPOOL_REBROADCASTER_GETH_ENDPOINT" ] || MEMPOOL_REBROADCASTER_GETH_ENDPOINT="http://op-geth-rpc:8545" ;;
        reth) [ -n "$MEMPOOL_REBROADCASTER_RETH_ENDPOINT" ] || MEMPOOL_REBROADCASTER_RETH_ENDPOINT="http://op-reth-rpc:8545" ;;
    esac
fi

{
    echo "SEQ_EFFECTIVE_COUNT=$N"
    echo "RPC_EFFECTIVE_COUNT=$RPC_N"
    echo "SEQ_CL_EFFECTIVE=$SEQ_CL"
    echo "RPC_CL_EFFECTIVE=$RPC_CL"
    echo "SEQ_TYPE_EFFECTIVE=$SEQ_TYPE"
    echo "RPC_TYPE_EFFECTIVE=$RPC_TYPE"
    echo "CONDUCTOR_MODE=${CONDUCTOR_ENABLED:-false}"
    echo "TRUSTED_PEERS=$TRUSTED_PEERS"
    echo "ALL_SEQ_OPNODE_PEERS=$ALL_SEQ_OPNODE_PEERS"
    echo "OP_BATCHER_L2_ETH_RPC=$OP_BATCHER_L2_ETH_RPC"
    echo "OP_BATCHER_ROLLUP_RPC=$OP_BATCHER_ROLLUP_RPC"
    echo "CLUSTER_UP_SERVICES=\"$CLUSTER_UP_SERVICES\""
    echo "SEQ_EL_SERVICES=\"$SEQ_EL_SERVICES\""
    echo "SEQ_CL_SERVICES=\"$SEQ_CL_SERVICES\""
    echo "CONDUCTOR_SERVICES=\"$CONDUCTOR_SERVICES\""
    echo "RPC_EL_SERVICES=\"$RPC_EL_SERVICES\""
    echo "RPC_OPNODE_SERVICES=\"$RPC_OPNODE_SERVICES\""
    echo "RPC_CL_SERVICES=\"$RPC_CL_SERVICES\""
    echo "ALL_EL_SERVICES=\"$ALL_EL_SERVICES\""
    echo "ALL_CL_SERVICES=\"$ALL_CL_SERVICES\""
    echo "MEMPOOL_REBROADCASTER_GETH_ENDPOINT=$MEMPOOL_REBROADCASTER_GETH_ENDPOINT"
    echo "MEMPOOL_REBROADCASTER_RETH_ENDPOINT=$MEMPOOL_REBROADCASTER_RETH_ENDPOINT"
    echo "KONA_RPC_URLS=\"$KONA_RPC_URLS\""
    rcs_emit_inventory "$N" "$RPC_N" "$RPC_TYPE" "$SEQ_TYPE"
    for ((i = 1; i <= N; i++)); do
        source "$CLUSTER_DIR/seq$i/identity.env"
        echo "EL_HTTP_PORT_$i=$EL_HTTP_PORT"
        echo "FLASHBLOCKS_WS_PORT_$i=$FLASHBLOCKS_WS_PORT"
        echo "CONDUCTOR_RPC_PORT_$i=$CONDUCTOR_RPC_PORT"
        echo "OPNODE_RPC_PORT_$i=$OPNODE_RPC_PORT"
        [ -n "$EL_WS_HOST_PORT" ] && echo "EL_WS_HOST_PORT_$i=$EL_WS_HOST_PORT"
        [ -n "$EL_AUTHRPC_HOST_PORT" ] && echo "EL_AUTHRPC_HOST_PORT_$i=$EL_AUTHRPC_HOST_PORT"
        [ -n "$EL_METRICS_HOST_PORT" ] && echo "EL_METRICS_HOST_PORT_$i=$EL_METRICS_HOST_PORT"
        [ -n "$EL_PPROF_HOST_PORT" ] && echo "EL_PPROF_HOST_PORT_$i=$EL_PPROF_HOST_PORT"
        [ -n "$CL_DEBUG_HOST_PORT" ] && echo "CL_DEBUG_HOST_PORT_$i=$CL_DEBUG_HOST_PORT"
        [ -n "$CL_METRICS_HOST_PORT" ] && echo "CL_METRICS_HOST_PORT_$i=$CL_METRICS_HOST_PORT"
    done
    for ((i = 1; i <= RPC_N; i++)); do
        source "$CLUSTER_DIR/rpc$i/identity.env"
        echo "RPC_EL_HTTP_PORT_$i=$RPC_EL_HTTP_PORT"
    done
} > "$CLUSTER_DIR/cluster.env"

echo "✅ Prepared identities and cluster.env for $N seq node(s) and $RPC_N RPC node(s) in $CLUSTER_DIR"
