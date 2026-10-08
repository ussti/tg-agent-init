#!/usr/bin/env python3
"""Prove one agent token works against one G-Brain MCP server.

Does what Claude Code does: ``initialize`` (keeps ``Mcp-Session-Id`` when the
server is stateful), ``notifications/initialized``, then ``tools/call`` on a
read-only tool that authenticates the caller. A bare ``tools/list`` would pass
with any bearer, because the brain checks the token inside tool handlers.
EXPECT_ERROR is a regex: a tool error matching it counts as success, for a
write tool probed with arguments it rejects only after authenticating; the
matched part is printed then, so the caller can tell which case it was.

Usage: mcp-smoke.py URL TOOL [JSON_ARGS] [EXPECT_ERROR]   (bearer token on stdin)
Exit 0 on success (printing the matched expected error, if any); otherwise
prints one short reason, never the token.
"""

from __future__ import annotations

import json
import re
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


def smoke(url: str, token: str, tool: str, args: dict, expect_error: str = "") -> str:
    """Run the handshake and one authenticated tool call.

    Returns the matched part of an expected tool error, or "" on a clean result.
    Raises SmokeError on failure.
    """
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
        text = str(content[0].get("text", "tool error"))
        match = re.search(expect_error, text) if expect_error else None
        if match:
            return match.group(0)
        raise SmokeError(f"{tool}: {text}")
    return ""


def main() -> int:
    """Entry point: argv URL TOOL [JSON_ARGS] [EXPECT_ERROR], token on stdin."""
    if len(sys.argv) not in (3, 4, 5):
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2
    url, tool = sys.argv[1], sys.argv[2]
    args = json.loads(sys.argv[3]) if len(sys.argv) >= 4 else {}
    expect_error = sys.argv[4] if len(sys.argv) == 5 else ""
    token = sys.stdin.readline().strip()
    if not token:
        print("no token on stdin", file=sys.stderr)
        return 2
    try:
        matched = smoke(url, token, tool, args, expect_error)
    except SmokeError as exc:
        print(str(exc).replace(token, "***")[:MAX_REASON_CHARS])
        return 1
    if matched:
        print(matched.replace(token, "***")[:MAX_REASON_CHARS])
    return 0


if __name__ == "__main__":
    sys.exit(main())
