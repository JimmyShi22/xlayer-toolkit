#!/usr/bin/env bash

is_nonzero_contract_address() {
    local address="${1:-}"
    [[ "$address" =~ ^0x[[:xdigit:]]{40}$ ]] &&
        [ "$address" != "0x0000000000000000000000000000000000000000" ]
}

select_opcm_address() {
    local implementations_json="$1"
    local opcm_v2 opcm_legacy

    opcm_v2=$(jq -r '.opcmV2Address // empty' "$implementations_json")
    if is_nonzero_contract_address "$opcm_v2"; then
        printf '%s\n' "$opcm_v2"
        return 0
    fi

    opcm_legacy=$(jq -r '.opcmAddress // empty' "$implementations_json")
    if is_nonzero_contract_address "$opcm_legacy"; then
        printf '%s\n' "$opcm_legacy"
        return 0
    fi

    return 1
}
