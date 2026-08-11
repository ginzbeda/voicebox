"""Guards on the committed .mcp.json.

Both rules here encode bugs that shipped and cost real debugging time, and neither
is visible by reading the file casually:

* The Streamable HTTP mount answers on ``/mcp/`` but returns 405 on ``/mcp`` —
  the redirect a browser would follow does not happen for POST.
* The port was hardcoded to the native desktop default, so every containerised or
  port-forwarded install silently pointed at nothing.

Deliberately dependency-free: this must keep working in a checkout that has not
installed the TTS stack.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[2]
MCP_CONFIG = REPO_ROOT / ".mcp.json"


@pytest.fixture(scope="module")
def server() -> dict:
    config = json.loads(MCP_CONFIG.read_text(encoding="utf-8"))
    servers = config["mcpServers"]
    assert "voicebox" in servers, f"expected a 'voicebox' server, got {sorted(servers)}"
    return servers["voicebox"]


def test_url_keeps_the_trailing_slash(server: dict) -> None:
    """POST /mcp is a 405; only /mcp/ is routed. Dropping the slash breaks every client."""
    assert server["url"].endswith("/mcp/"), (
        f"url must end with '/mcp/', got {server['url']!r} — "
        "the mount returns 405 for POST without the trailing slash"
    )


def test_port_is_overridable(server: dict) -> None:
    """A bare literal port strands anyone not running the native desktop build."""
    assert "${VOICEBOX_PORT" in server["url"], (
        f"url must take the port from ${{VOICEBOX_PORT:-...}}, got {server['url']!r}"
    )


def test_host_is_overridable(server: dict) -> None:
    """Container clients reach the backend by service DNS, not loopback."""
    assert "${VOICEBOX_HOST" in server["url"], (
        f"url must take the host from ${{VOICEBOX_HOST:-...}}, got {server['url']!r}"
    )


def test_every_expansion_has_a_default(server: dict) -> None:
    """An unset variable with no default loads literally as '${VAR}' and quietly
    produces an unusable URL, so every reference must carry a ':-default'."""
    blob = json.dumps(server)
    bare = [m for m in re.findall(r"\$\{([^}]*)\}", blob) if ":-" not in m]
    assert not bare, f"these expansions lack a ':-default' fallback: {bare}"


def test_client_id_header_present(server: dict) -> None:
    """Per-client voice bindings are keyed on this header; without it every agent
    collapses onto the same default profile."""
    headers = server.get("headers", {})
    assert "X-Voicebox-Client-Id" in headers, f"missing client-id header, got {sorted(headers)}"


def test_transport_is_http(server: dict) -> None:
    assert server["type"] == "http", f"expected the Streamable HTTP transport, got {server['type']!r}"
