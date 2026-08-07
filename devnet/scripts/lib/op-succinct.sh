#!/usr/bin/env bash

upsert_env_value() {
    local file="$1" key="$2" value="$3" tmp
    [ -f "$file" ] || { echo "❌ Missing env file: $file" >&2; return 1; }
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
        echo "❌ Invalid env key: $key" >&2
        return 1
    }
    case "$value" in
        *$'\n'*|*$'\r'*) echo "❌ Env value for $key contains a newline" >&2; return 1 ;;
    esac

    tmp="${file}.tmp.$$"
    cp -p "$file" "$tmp"
    if ! awk -v key="$key" -v value="$value" '
        BEGIN { found = 0 }
        index($0, key "=") == 1 { print key "=" value; found = 1; next }
        { print }
        END { if (!found) print key "=" value }
    ' "$file" >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$file"
}

verify_container_running() {
    local container_name="$1" grace="${OP_SUCCINCT_STARTUP_GRACE_SECONDS:-2}" container_status
    sleep "$grace"
    container_status=$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || true)
    if [ "$container_status" != "running" ]; then
        echo "❌ $container_name exited during startup (status: ${container_status:-missing})" >&2
        docker logs "$container_name" 2>&1 | tail -50 >&2 || true
        return 1
    fi
    echo "   ✓ $container_name is running"
}

recreate_and_verify_service() {
    local service_name="$1" container_name="${2:-$1}"
    docker compose up -d --force-recreate "$service_name"
    verify_container_running "$container_name"
}
