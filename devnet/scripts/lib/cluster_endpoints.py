"""Resolve local devnet endpoints from the generated cluster inventory."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Mapping


def load_cluster_env(path: Path) -> dict[str, str]:
    """Load the simple KEY=VALUE inventory emitted by the cluster generator."""
    values: dict[str, str] = {}
    if not path.is_file():
        return values

    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        values[key.strip()] = value
    return values


def resolve_flashblock_endpoints(
    cluster_env_path: Path,
    environ: Mapping[str, str] | None = None,
) -> tuple[list[str], str]:
    """Resolve flashblock WebSockets and the canonical RPC endpoint."""
    env = os.environ if environ is None else environ
    cluster = load_cluster_env(cluster_env_path)

    ws_override = env.get("FLASHBLOCK_REORG_WS_URLS", "")
    if ws_override:
        ws_urls = [url for value in ws_override.split(",") for url in value.split() if url]
    else:
        try:
            sequencer_count = int(cluster.get("SEQ_EFFECTIVE_COUNT", "0"))
        except ValueError:
            sequencer_count = 0
        ws_urls = [
            f"ws://localhost:{cluster[f'FLASHBLOCKS_WS_PORT_{index}']}"
            for index in range(1, sequencer_count + 1)
            if cluster.get(f"FLASHBLOCKS_WS_PORT_{index}")
        ]
        if not ws_urls:
            ws_urls = ["ws://localhost:32001"]

    rpc_override = env.get("FLASHBLOCK_REORG_RPC_URL", "")
    if rpc_override:
        rpc_url = rpc_override
    elif cluster.get("RPC_EFFECTIVE_COUNT") not in (None, "0") and cluster.get(
        "RPC_EL_HTTP_PORT_1"
    ):
        rpc_url = f"http://localhost:{cluster['RPC_EL_HTTP_PORT_1']}"
    else:
        rpc_url = f"http://localhost:{cluster.get('EL_HTTP_PORT_1', '8123')}"

    return ws_urls, rpc_url
