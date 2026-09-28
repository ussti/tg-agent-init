#!/usr/bin/env python3
"""Prove one agent token works against one G-Brain MCP server.

Does what Claude Code does: ``initialize`` (keeps ``Mcp-Session-Id`` when the
server is stateful), ``notifications/initialized``, then ``tools/call`` on a
read-only tool that authenticates the caller. A bare ``tools/list`` would pass
with any bearer, because the brain checks the token inside tool handlers.

Usage: mcp-smoke.py URL TOOL [JSON_ARGS]   (bearer token on stdin)
Exit 0 on success; otherwise prints one short reason, never the token.
"""

from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request

TIMEOUT_S = 15
PROTOCOL_VERSION = "2025-03-26"
MAX_REASON_CHARS = 200


class SmokeError(Exception):
    """A step of the handshake or the tool call failed."""


def _parse(body: str) -> dict:
    """Decode a plain JSON or SSE response body into a JSON-RPC envelope."""
    for line in body.splitlines():
        if line.startswith("data: ") and line[6:].strip():
            return json.loads(line[6:])
    return json.loads(body) if body.strip() else {}


def _post(url: str, token: str, session: str | None, message: dict) -> tuple[dict, str | None]:
    """POST one JSON-RPC message; return (envelope, session id header)."""
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "Authorization": f"Bearer {token}",
    }
    if session:
        headers["Mcp-Session-Id"] = session
    req = urllib.request.Request(url, data=json.dumps(message).encode(), headers=headers,
                                 method="POST")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            return _parse(body), resp.headers.get("Mcp-Session-Id") or session
    except urllib.error.HTTPError as exc:
        raise SmokeError(f"HTTP {exc.code} on {message.get('method')}") from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise SmokeError(f"cannot reach {url}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise SmokeError(f"unreadable reply to {message.get('method')}") from exc


def smoke(url: str, token: str, tool: str, args: dict) -> None:
    """Run the handshake and one authenticated tool call; raise SmokeError on failure."""
    init = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": PROTOCOL_VERSION, "capabilities": {},
        "clientInfo": {"name": "tg-agent-fleet-smoke", "version": "1"}}}
    envelope, session = _post(url, token, None, init)
    if "result" not in envelope:
        raise SmokeError("initialize returned no result")
    _post(url, token, session, {"jsonrpc": "2.0", "method": "notifications/initialized"})
    call = {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": tool, "arguments": args}}
    envelope, _ = _post(url, token, session, call)
    if envelope.get("error"):
        raise SmokeError(f"{tool}: {envelope['error'].get('message', 'error')}")
    result = envelope.get("result")
    if not isinstance(result, dict):
        raise SmokeError(f"{tool}: no result")
    if result.get("isError"):
        content = result.get("content") or [{}]
        raise SmokeError(f"{tool}: {content[0].get('text', 'tool error')}")


def main() -> int:
    """Entry point: argv URL TOOL [JSON_ARGS], token on stdin."""
    if len(sys.argv) not in (3, 4):
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2
    url, tool = sys.argv[1], sys.argv[2]
    args = json.loads(sys.argv[3]) if len(sys.argv) == 4 else {}
    token = sys.stdin.readline().strip()
    if not token:
        print("no token on stdin", file=sys.stderr)
        return 2
    try:
        smoke(url, token, tool, args)
    except SmokeError as exc:
        print(str(exc).replace(token, "***")[:MAX_REASON_CHARS])
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
