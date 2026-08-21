#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$REPO_DIR"
# shellcheck source=scripts/lib/rcs-services.sh
source "$SCRIPT_DIR/lib/rcs-services.sh"

CLUSTER_DIR="$REPO_DIR/config-op/cluster"
source "$CLUSTER_DIR/cluster.env"

OUT="$REPO_DIR/docker-compose.cluster.yml"
echo "services:" > "$OUT"
cat >> "$OUT" <<EOF
  mempool-rebroadcaster:
    image: xlayerdev/mempool-rebroadcaster
    container_name: mempool-rebroadcaster
    command:
      - --geth-mempool-endpoint=${MEMPOOL_REBROADCASTER_GETH_ENDPOINT}
      - --reth-mempool-endpoint=${MEMPOOL_REBROADCASTER_RETH_ENDPOINT}
EOF

# Build this node's full P2P peer address list for the OTHER N-1 nodes, used
# for reth flashblocks known-peers and op-node --p2p.static. $1=field to read
# (FB_PEER_ID or OPNODE_PEER_ID), $2=hostname prefix (op-reth-seq or op-seq),
# $3=internal port (9009 or 9223), $4=this node's own index (excluded).
other_peers() {
    local peer_id_field=$1 host_prefix=$2 internal_port=$3 self_index=$4
    local list=""
    for ((j = 1; j <= SEQ_EFFECTIVE_COUNT; j++)); do
        [ "$j" -eq "$self_index" ] && continue
        source "$CLUSTER_DIR/seq$j/identity.env"
        local peer_id="${!peer_id_field}"
        local entry="/dns4/${host_prefix}${SUFFIX}/tcp/${internal_port}/p2p/${peer_id}"
        if [ -z "$list" ]; then
            list="$entry"
        else
            list="${list},${entry}"
        fi
    done
    echo "$list"
}

for ((i = 1; i <= SEQ_EFFECTIVE_COUNT; i++)); do
    source "$CLUSTER_DIR/seq$i/identity.env"

    FB_KNOWN_PEERS=$(other_peers FB_PEER_ID op-reth-seq 9009 "$i")
    OPNODE_STATIC_PEERS=$(other_peers OPNODE_PEER_ID op-seq 9223 "$i")
    RCS_ENV_YAML=$(rcs_seq_environment_yaml "$i")

    # --- Selected execution layer ---
    if [ "$SEQ_TYPE" = "geth" ]; then
        cat >> "$OUT" <<EOF

  op-geth-seq${SUFFIX}:
    image: "\${OP_GETH_IMAGE_TAG}"
    container_name: op-geth-seq${SUFFIX}
    entrypoint: /entrypoint/geth-seq.sh
    env_file:
      - .env
    volumes:
      - ./data/op-geth-seq${SUFFIX}:/datadir
      - ./config-op/jwt.txt:/jwt.txt
      - ./config-op/cluster/seq${i}/geth.toml:/config.toml:ro
      - ./config-op/cluster/seq${i}/identity.env:/identity.env:ro
      - ./entrypoint:/entrypoint:ro
      - ./.env:/.env:ro
    ports:
      - "${EL_HTTP_PORT}:8545"
      - "${EL_P2P_PORT}:30303"
      - "${EL_P2P_PORT}:30303/udp"
$([ "$i" -eq 1 ] && printf '      - "%s:7546"\n      - "%s:8552"\n      - "%s:9092" # pprof\n' "$EL_WS_HOST_PORT" "$EL_AUTHRPC_HOST_PORT" "$EL_PPROF_HOST_PORT")
    healthcheck:
      test: ["CMD", "wget", "--spider", "--quiet", "http://localhost:8545"]
      interval: 3s
      timeout: 3s
      retries: 10
      start_period: 3s
    networks:
      default:
        aliases:
          - op-seq-el${SUFFIX}
EOF
    fi
    if [ "$SEQ_TYPE" = "reth" ]; then
        cat >> "$OUT" <<EOF

  op-reth-seq${SUFFIX}:
    image: "\${OP_RETH_IMAGE_TAG}"
    container_name: op-reth-seq${SUFFIX}
    entrypoint: /entrypoint/reth-seq.sh ${SUFFIX}
    env_file:
      - .env
    privileged: true
    cap_add:
      - SYS_ADMIN
      - SYS_PTRACE
    security_opt:
      - seccomp=unconfined
    volumes:
      - ./data/op-reth-seq${SUFFIX}:/datadir
      - ./config-op/jwt.txt:/jwt.txt
      - ./config-op/genesis-reth.json:/genesis.json
      - ./entrypoint:/entrypoint:ro
      - ./.env:/.env:ro
      - ./config-op/test.reth.seq.config.toml:/config.toml:ro
      - ./config-op/cluster/seq${i}/identity.env:/identity.env:ro
      - ./logs/op-reth-seq${SUFFIX}:/logs/reth
      - ./profiling/op-reth-seq${SUFFIX}:/profiling
      - /sys/kernel/tracing:/sys/kernel/tracing:ro
    ports:
      - "${EL_HTTP_PORT}:8545"
      - "${EL_P2P_PORT}:30303"
      - "${EL_P2P_PORT}:30303/udp"
      - "${FLASHBLOCKS_WS_PORT}:1111" # outbound flashblocks ws port
$([ "$i" -eq 1 ] && printf '      - "%s:7546"\n      - "%s:8552"\n      - "%s:9001" # metrics\n' "$EL_WS_HOST_PORT" "$EL_AUTHRPC_HOST_PORT" "$EL_METRICS_HOST_PORT")
    environment:
      - FB_KNOWN_PEERS=${FB_KNOWN_PEERS}
$RCS_ENV_YAML
    healthcheck:
      test: [ "CMD", "curl", "-f", "-X", "POST", "-H", "Content-Type: application/json", "-d", "{\\"jsonrpc\\":\\"2.0\\",\\"method\\":\\"eth_blockNumber\\",\\"params\\":[],\\"id\\":1}", "http://localhost:8545" ]
      interval: 3s
      timeout: 3s
      retries: 10
      start_period: 3s
    networks:
      default:
        aliases:
          - op-seq-el${SUFFIX}
EOF
    fi

    # --- op-node ---
    if [ "$CONDUCTOR_MODE" = "true" ]; then
        SEQUENCER_STOPPED_FLAG="      - --sequencer.stopped"
        CONDUCTOR_ENABLED_FLAG="true"
        CONDUCTOR_RPC_FLAG="      - --conductor.rpc=http://op-conductor${SUFFIX}:8547"
    else
        SEQUENCER_STOPPED_FLAG=""
        CONDUCTOR_ENABLED_FLAG="false"
        CONDUCTOR_RPC_FLAG="      - --conductor.rpc=http://op-conductor:8547"
    fi

    if [ "$SEQ_CL_EFFECTIVE" = "opnode" ]; then
        cat >> "$OUT" <<EOF

  op-seq${SUFFIX}:
    image: "\${OP_STACK_IMAGE_TAG}"
    container_name: op-seq${SUFFIX}
    volumes:
      - ./config-op/rollup.json:/rollup.json
      - ./config-op/jwt.txt:/jwt.txt
      - ./data/op-seq${SUFFIX}:/data
      - ./l1-geth/execution/genesis.json:/l1-genesis.json
    ports:
      - "${OPNODE_RPC_PORT}:9545"
      - "${OPNODE_P2P_HOST_PORT}:9223"
      - "${OPNODE_P2P_HOST_PORT}:9223/udp"
$([ "$i" -eq 1 ] && printf '      - "%s:7070"\n      - "%s:9091" # pprof\n' "$CL_DEBUG_HOST_PORT" "$CL_METRICS_HOST_PORT")
    command:
      - /app/op-node/bin/op-node
      - --log.level=debug
      - --log.format=logfmtms
      - --l2=http://op-\${SEQ_TYPE}-seq${SUFFIX}:8552
      - --l2.jwt-secret=/jwt.txt
      - --sequencer.enabled
$SEQUENCER_STOPPED_FLAG
      - --sequencer.l1-confs=5
      - --verifier.l1-confs=1
      - --l1.epoch-poll-interval=10s
      - --rollup.config=/rollup.json
      - --rpc.addr=0.0.0.0
      - --p2p.listen.tcp=9223
      - --p2p.listen.udp=9223
      - --p2p.priv.raw=${OPNODE_P2P_PRIV}
      - --p2p.peerstore.path=/data/p2p/opnode_peerstore_db
      - --p2p.discovery.path=/data/p2p/opnode_discovery_db
      - --p2p.static=${OPNODE_STATIC_PEERS}
      - --p2p.no-discovery
      - --rpc.enable-admin
      - --p2p.sequencer.key=\${SEQUENCER_P2P_KEY}
      - --l1=\${L1_RPC_URL_IN_DOCKER}
      - --l1.beacon=\${L1_BEACON_URL_IN_DOCKER}
      - --l1.rpckind=standard
      - --rollup.l1-chain-config=/l1-genesis.json
      - --safedb.path=/data/safedb
      - --conductor.enabled=$CONDUCTOR_ENABLED_FLAG
$CONDUCTOR_RPC_FLAG
$([ "$i" -eq 1 ] && echo '      - --pprof.enabled
      - --pprof.addr=0.0.0.0
      - --pprof.port=9091')
      - --l2.enginekind=\${SEQ_TYPE}
    depends_on:
      op-${SEQ_TYPE}-seq${SUFFIX}:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9545"]
      interval: 3s
      timeout: 3s
      retries: 10
      start_period: 3s
EOF
    else
        cat >> "$OUT" <<EOF

  op-kona-seq${SUFFIX}:
    image: "\${KONA_IMAGE_TAG:-kona:latest}"
    container_name: op-kona-seq${SUFFIX}
    user: "\${UID:-0}:\${GID:-0}"
    networks:
      default:
        aliases:
          - op-seq${SUFFIX}
    volumes:
      - ./config-op/rollup.json:/rollup.json
      - ./config-op/jwt.txt:/jwt.txt
      - ./data/op-kona-seq${SUFFIX}:/data
      - ./l1-geth/execution/genesis.json:/l1-genesis.json
    ports:
      - "${OPNODE_RPC_PORT}:9545"
      - "${OPNODE_P2P_HOST_PORT}:9223"
      - "${OPNODE_P2P_HOST_PORT}:9223/udp"
      - "${CL_METRICS_HOST_PORT}:9091"
    command:
      - --chain=\${CHAIN_ID}
      - --metrics.enabled
      - --metrics.addr=0.0.0.0
      - --metrics.port=9091
      - -vvvv
      - --logs.stdout.format=logfmt
      - node
      - --mode=Sequencer
      - --l1-eth-rpc=\${L1_RPC_URL_IN_DOCKER}
      - --l1-beacon=\${L1_BEACON_URL_IN_DOCKER}
      - --l1-config-file=/l1-genesis.json
      - --l2-engine-rpc=http://op-${SEQ_TYPE}-seq${SUFFIX}:8552
      - --l2-engine-jwt-secret=/jwt.txt
      - --l2-config-file=/rollup.json
      - --sequencer.l1-confs=5
      - --rpc.addr=0.0.0.0
      - --rpc.port=9545
      - --rpc.enable-admin
      - --p2p.listen.tcp=9223
      - --p2p.listen.udp=9223
      - --p2p.priv.raw=${OPNODE_P2P_PRIV}
      - --p2p.no-discovery
      - --p2p.no-bootstore
      - --p2p.sequencer.key=\${SEQUENCER_P2P_KEY}
    depends_on:
      op-${SEQ_TYPE}-seq${SUFFIX}:
        condition: service_healthy
EOF
    fi

    # --- op-conductor (conductor mode only) ---
    if [ "$CONDUCTOR_MODE" = "true" ]; then
        BOOTSTRAP="false"
        [ "$i" -eq 1 ] && BOOTSTRAP="true"
        cat >> "$OUT" <<EOF

  op-conductor${SUFFIX}:
    image: "\${OP_STACK_IMAGE_TAG}"
    container_name: op-conductor${SUFFIX}
    volumes:
      - ./data/op-conductor${SUFFIX}:/data
      - ./config-op/rollup.json:/rollup.json
    ports:
      - "${CONDUCTOR_RPC_PORT}:8547"
      - "${CONDUCTOR_CONSENSUS_PORT}:50050"
    command:
      - /app/op-conductor/bin/op-conductor
      - --log.level=debug
      - --node.rpc=http://op-seq${SUFFIX}:9545
      - --execution.rpc=http://op-\${SEQ_TYPE}-seq${SUFFIX}:8545
      - --raft.server.id=${RAFT_SERVER_ID}
      - --raft.storage.dir=/data/raft
      - --raft.bootstrap=$BOOTSTRAP
      - --raft.snapshot-threshold=2048
      - --consensus.addr=0.0.0.0
      - --consensus.port=50050
      - --consensus.advertised=op-conductor${SUFFIX}:50050
      - --rpc.addr=0.0.0.0
      - --rpc.port=8547
      - --rpc.enable-proxy=true
      - --healthcheck.interval=1
      - --healthcheck.unsafe-interval=3
      - --healthcheck.min-peer-count=1
      - --rollup.config=/rollup.json
      - --rpc.http-body-limit-mb=64
    depends_on:
      op-seq${SUFFIX}:
        condition: service_healthy
EOF
    fi
done

for ((i = 1; i <= RPC_EFFECTIVE_COUNT; i++)); do
    source "$CLUSTER_DIR/rpc$i/identity.env"

    # --- Execution layer (geth or reth) ---
    if [ "$RPC_TYPE" = "geth" ]; then
        cat >> "$OUT" <<EOF

  op-geth-rpc${SUFFIX}:
    image: "\${OP_GETH_IMAGE_TAG}"
    container_name: op-geth-rpc${SUFFIX}
    entrypoint: /entrypoint/geth-rpc.sh
    env_file:
      - .env
    volumes:
      - ./data/op-geth-rpc${SUFFIX}:/datadir
      - ./config-op/jwt.txt:/jwt.txt
      - ./config-op/cluster/rpc${i}/geth.toml:/config.toml:ro
      - ./config-op/cluster/rpc${i}/identity.env:/identity.env:ro
      - ./entrypoint:/entrypoint:ro
      - ./.env:/.env:ro
    ports:
      - "${RPC_EL_HTTP_PORT}:8545"
      - "${RPC_EL_P2P_PORT}:30303"
      - "${RPC_EL_P2P_PORT}:30303/udp"
    healthcheck:
      test: ["CMD", "wget", "--spider", "--quiet", "http://localhost:8545"]
      interval: 3s
      timeout: 3s
      retries: 10
      start_period: 3s
    networks:
      default:
        aliases:
          - op-rpc-el${SUFFIX}
EOF
    else
        cat >> "$OUT" <<EOF

  op-reth-rpc${SUFFIX}:
    image: "\${OP_RETH_IMAGE_TAG}"
    container_name: op-reth-rpc${SUFFIX}
    entrypoint: /entrypoint/reth-rpc.sh
    env_file:
      - .env
    privileged: true
    cap_add:
      - SYS_ADMIN
      - SYS_PTRACE
    security_opt:
      - seccomp=unconfined
    volumes:
      - ./data/op-reth-rpc${SUFFIX}:/datadir
      - ./config-op/jwt.txt:/jwt.txt
      - ./config-op/genesis-reth.json:/genesis.json
      - ./config-op/test.reth.rpc.config.toml:/config.toml:ro
      - ./entrypoint:/entrypoint:ro
      - ./.env:/.env:ro
      - ./config-op/cluster/rpc${i}/identity.env:/identity.env:ro
      - ./logs/op-reth-rpc${SUFFIX}:/logs/reth
      - ./profiling/op-reth-rpc${SUFFIX}:/profiling
      - /sys/kernel/tracing:/sys/kernel/tracing:ro
    ports:
      - "${RPC_EL_HTTP_PORT}:8545"
      - "${RPC_EL_WS_PORT}:7546"
      - "${RPC_FLASHBLOCKS_WS_PORT}:1111"
      - "${RPC_EL_P2P_PORT}:30303"
      - "${RPC_EL_P2P_PORT}:30303/udp"
      - "${RPC_EL_METRICS_PORT}:9001"
    environment:
      - FB_URL=${FB_URL}
    healthcheck:
      test: [ "CMD", "curl", "-f", "-X", "POST", "-H", "Content-Type: application/json", "-d", "{\\"jsonrpc\\":\\"2.0\\",\\"method\\":\\"eth_blockNumber\\",\\"params\\":[],\\"id\\":1}", "http://localhost:8545" ]
      interval: 3s
      timeout: 3s
      retries: 10
      start_period: 3s
    networks:
      default:
        aliases:
          - op-rpc-el${SUFFIX}
EOF
    fi

    # --- Consensus layer (independent full L1 sync, no conductor, no follow-source) ---
    if [ "$RPC_CL_EFFECTIVE" = "opnode" ]; then
        cat >> "$OUT" <<EOF

  op-rpc${SUFFIX}:
    image: "\${OP_STACK_IMAGE_TAG}"
    container_name: op-rpc${SUFFIX}
    volumes:
      - ./data/op-rpc${SUFFIX}:/data
      - ./config-op/rollup.json:/rollup.json
      - ./config-op/jwt.txt:/jwt.txt
      - ./l1-geth/execution/genesis.json:/l1-genesis.json
    ports:
      - "${RPC_OPNODE_RPC_PORT}:9545"
      - "${RPC_OPNODE_P2P_HOST_PORT}:9223"
      - "${RPC_OPNODE_P2P_HOST_PORT}:9223/udp"
    command:
      - /app/op-node/bin/op-node
      - --log.level=debug
      - --log.format=logfmtms
      - --l2=http://op-\${RPC_TYPE}-rpc${SUFFIX}:8552
      - --l2.jwt-secret=/jwt.txt
      - --sequencer.enabled=false
      - --verifier.l1-confs=1
      - --l1.epoch-poll-interval=10s
      - --rollup.config=/rollup.json
      - --rpc.addr=0.0.0.0
      - --rpc.port=9545
      - --p2p.listen.tcp=9223
      - --p2p.listen.udp=9223
      - --p2p.priv.raw=${RPC_OPNODE_P2P_PRIV}
      - --p2p.peerstore.path=/data/p2p/opnode_peerstore_db
      - --p2p.discovery.path=/data/p2p/opnode_discovery_db
      - --p2p.static=${ALL_SEQ_OPNODE_PEERS}
      - --p2p.no-discovery
      - --rpc.enable-admin=true
      - --l1=\${L1_RPC_URL_IN_DOCKER}
      - --l1.beacon=\${L1_BEACON_URL_IN_DOCKER}
      - --l1.rpckind=standard
      - --rollup.l1-chain-config=/l1-genesis.json
      - --safedb.path=/data/safedb
      - --l2.enginekind=\${RPC_TYPE}
      - --syncmode=execution-layer
    depends_on:
      op-${RPC_TYPE}-rpc${SUFFIX}:
        condition: service_healthy
EOF
    else
        cat >> "$OUT" <<EOF

  op-kona-rpc${SUFFIX}:
    image: "\${KONA_IMAGE_TAG:-kona:latest}"
    container_name: op-kona-rpc${SUFFIX}
    user: "\${UID:-0}:\${GID:-0}"
    networks:
      default:
        aliases:
          - op-rpc${SUFFIX}
    volumes:
      - ./config-op/rollup.json:/rollup.json
      - ./config-op/jwt.txt:/jwt.txt
      - ./data/op-kona-rpc${SUFFIX}:/data
      - ./l1-geth/execution/genesis.json:/l1-genesis.json
    ports:
      - "${RPC_KONA_RPC_PORT}:9545"
      - "${RPC_OPNODE_P2P_HOST_PORT}:9223"
      - "${RPC_OPNODE_P2P_HOST_PORT}:9223/udp"
      - "${RPC_KONA_METRICS_PORT}:9091"
    command:
      - --chain=\${CHAIN_ID}
      - --metrics.enabled
      - --metrics.addr=0.0.0.0
      - --metrics.port=9091
      - -vvvv
      - --logs.stdout.format=logfmt
      - node
      - --mode=Validator
      - --l1-eth-rpc=\${L1_RPC_URL_IN_DOCKER}
      - --l1-beacon=\${L1_BEACON_URL_IN_DOCKER}
      - --l1-config-file=/l1-genesis.json
      - --l2-engine-rpc=http://op-${RPC_TYPE}-rpc${SUFFIX}:8552
      - --l2-engine-jwt-secret=/jwt.txt
      - --l2-config-file=/rollup.json
      - --rpc.addr=0.0.0.0
      - --rpc.port=9545
      - --rpc.enable-admin
      - --p2p.listen.tcp=9223
      - --p2p.listen.udp=9223
      - --p2p.priv.raw=${RPC_OPNODE_P2P_PRIV}
      - --p2p.no-discovery
      - --p2p.no-bootstore
    depends_on:
      op-${RPC_TYPE}-rpc${SUFFIX}:
        condition: service_healthy
EOF
    fi
done

rcs_prepare_runtime_config "$REPO_DIR" "$RPC_EFFECTIVE_COUNT" \
    "$RPC_TYPE_EFFECTIVE" "$SEQ_TYPE_EFFECTIVE"
rcs_append_compose "$OUT" "$REPO_DIR"

# Generate monitoring/prometheus.yml with one scrape target per selected Reth
# EL node. Geth roles expose a different metrics interface and are omitted.
PROMETHEUS_OUT="$REPO_DIR/monitoring/prometheus.yml"
cp "$REPO_DIR/monitoring/prometheus.yml.template" "$PROMETHEUS_OUT"
for ((i = 1; i <= SEQ_EFFECTIVE_COUNT; i++)); do
    source "$CLUSTER_DIR/seq$i/identity.env"
    if [ "$SEQ_TYPE" = "reth" ]; then
        cat >> "$PROMETHEUS_OUT" <<EOF

  - job_name: 'op-reth-seq${SUFFIX}'
    static_configs:
      - targets: ['op-reth-seq${SUFFIX}:9001']
    metrics_path: /metrics
EOF
    fi
done
for ((i = 1; i <= RPC_EFFECTIVE_COUNT; i++)); do
    source "$CLUSTER_DIR/rpc$i/identity.env"
    if [ "$RPC_TYPE" = "reth" ]; then
        cat >> "$PROMETHEUS_OUT" <<EOF

  - job_name: 'op-reth-rpc${SUFFIX}'
    static_configs:
      - targets: ['op-reth-rpc${SUFFIX}:9001']
    metrics_path: /metrics
EOF
    fi
done

echo "✅ Prepared $OUT for $SEQ_EFFECTIVE_COUNT seq node(s) and $RPC_EFFECTIVE_COUNT RPC node(s)"
