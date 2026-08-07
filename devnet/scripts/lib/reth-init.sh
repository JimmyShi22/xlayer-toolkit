#!/bin/bash

run_reth_init_logged() {
    local log_path="$1"
    shift
    "$@" 2>&1 | tee "$log_path"
    local statuses=("${PIPESTATUS[@]}")
    if [ "${statuses[0]}" -ne 0 ]; then
        echo "❌ Reth init command failed with status ${statuses[0]}; see $log_path" >&2
        return "${statuses[0]}"
    fi
    if [ "${statuses[1]}" -ne 0 ]; then
        echo "❌ Could not write Reth init log $log_path (tee status ${statuses[1]})" >&2
        return "${statuses[1]}"
    fi
}

extract_reth_init_hash() {
    local log_path="$1"
    python3 - "$log_path" <<'PY'
import json
import re
import sys

path = sys.argv[1]
pattern = re.compile(r"^0x[0-9a-fA-F]{64}$")
found = []
with open(path, encoding="utf-8", errors="replace") as handle:
    for line in handle:
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(value, dict):
            continue
        fields = value.get("fields")
        candidate = fields.get("hash") if isinstance(fields, dict) else None
        if isinstance(candidate, str) and pattern.fullmatch(candidate):
            found.append(candidate)

if not found:
    print(f"no non-null bytes32 fields.hash found in {path}", file=sys.stderr)
    raise SystemExit(1)
print(found[-1])
PY
}

validate_bytes32() {
    local value="${1:-}"
    [[ "$value" =~ ^0x[0-9a-fA-F]{64}$ ]]
}
