#!/bin/bash

cluster_service_suffix() {
    local index="$1"
    if ! [[ "$index" =~ ^[1-9][0-9]*$ ]]; then
        echo "❌ service index must be a positive integer, got: $index" >&2
        return 1
    fi
    [ "$index" -eq 1 ] || printf '%s' "$index"
}

selected_seq_el_service() {
    local index="$1" suffix
    suffix=$(cluster_service_suffix "$index") || return 1
    case "${SEQ_TYPE_EFFECTIVE:-}" in
        reth|geth) printf 'op-%s-seq%s\n' "$SEQ_TYPE_EFFECTIVE" "$suffix" ;;
        *) echo "❌ unsupported SEQ_TYPE_EFFECTIVE=${SEQ_TYPE_EFFECTIVE:-<unset>}; expected reth or geth" >&2; return 1 ;;
    esac
}

selected_seq_cl_service() {
    local index="$1" suffix
    suffix=$(cluster_service_suffix "$index") || return 1
    case "${SEQ_CL_EFFECTIVE:-}" in
        opnode) printf 'op-seq%s\n' "$suffix" ;;
        kona) printf 'op-kona-seq%s\n' "$suffix" ;;
        *) echo "❌ unsupported SEQ_CL_EFFECTIVE=${SEQ_CL_EFFECTIVE:-<unset>}; expected opnode or kona" >&2; return 1 ;;
    esac
}

require_conductor_utility_topology() {
    local utility_name="$1"
    if [ "${CONDUCTOR_MODE:-false}" != "true" ] || [ "${SEQ_EFFECTIVE_COUNT:-0}" -lt 2 ]; then
        echo "❌ $utility_name requires CONDUCTOR_MODE=true with SEQ_EFFECTIVE_COUNT >= 2" >&2
        return 1
    fi
    if [ "${SEQ_CL_EFFECTIVE:-}" != "opnode" ]; then
        echo "❌ $utility_name requires SEQ_CL_EFFECTIVE=opnode; got ${SEQ_CL_EFFECTIVE:-<unset>}" >&2
        return 1
    fi
    case "${SEQ_TYPE_EFFECTIVE:-}" in
        reth|geth) ;;
        *) echo "❌ $utility_name does not support SEQ_TYPE_EFFECTIVE=${SEQ_TYPE_EFFECTIVE:-<unset>}" >&2; return 1 ;;
    esac
}
