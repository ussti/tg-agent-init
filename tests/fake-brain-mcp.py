#!/usr/bin/env python3
"""Fake G-Brain MCP servers for the install-fleet test.

Behaves like the live brain where the smoke depends on it: stateful
streamable-http (no ``Mcp-Session-Id`` -> HTTP 400), the bearer is checked only
inside tool handlers, a bad token yields ``isError`` (not an HTTP error), and
tool-call replies come as SSE frames.

Usage: fake-brain-mcp.py VALID_TOKENS_FILE MEMORY_PORT RECALL_PORT SWARM_PORT
Valid tokens are re-read on every call, one per line.
"""

from __future__ import annotations

import json
import pathlib
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOOLS_BY_ROLE = {"memory": {"slot_list"}, "recall": {"recent"}, "swarm": {"stats"}}


def make_handler(role: str, tokens_file: pathlib.Path) -> type[BaseHTTPRequestHandler]:
    """Build a request handler for one server role."""
    sessions: set[str] = set()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_: object) -> None:
            pass

        def _send(self, code: int, body: str = "", headers: dict[str, str] | None = None,
                  sse: bool = False) -> None:
            self.send_response(code)
            self.send_header("Content-Type", "text/event-stream" if sse else "application/json")
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            payload = (f"event: message\ndata: {body}\n\n" if sse else body).encode()
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_POST(self) -> None:  # noqa: N802 (http.server API)
            msg = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            method = msg.get("method")
            if method == "initialize":
                sid = uuid.uuid4().hex
                sessions.add(sid)
                result = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}},
                          "serverInfo": {"name": f"fake-{role}", "version": "0"}}
                self._send(200, json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result}),
                           {"Mcp-Session-Id": sid})
                return
            if self.headers.get("Mcp-Session-Id") not in sessions:
                self._send(400, json.dumps({"jsonrpc": "2.0", "id": "server-error",
                                            "error": {"code": -32600,
                                                      "message": "Bad Request: Missing session ID"}}))
                return
            if method == "notifications/initialized":
                self._send(202)
                return
            if method != "tools/call":
                self._send(200, json.dumps({"jsonrpc": "2.0", "id": msg.get("id"),
                                            "result": {"tools": []}}), sse=True)
                return
            name = msg["params"]["name"]
            if name not in TOOLS_BY_ROLE[role]:
                result = {"isError": True, "content": [{"type": "text",
                                                        "text": f"Unknown tool: {name}"}]}
            else:
                auth = self.headers.get("Authorization", "")
                token = auth.removeprefix("Bearer ").strip()
                valid = set(tokens_file.read_text().split()) if tokens_file.exists() else set()
                if token in valid:
                    result = {"isError": False, "content": [{"type": "text", "text": "{}"}]}
                else:
                    result = {"isError": True, "content": [{
                        "type": "text",
                        "text": f"Error calling tool '{name}': Invalid or unknown bearer token"}]}
            self._send(200, json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result}),
                       sse=True)

    return Handler


def main() -> int:
    """Serve the three roles until killed."""
    tokens_file = pathlib.Path(sys.argv[1])
    servers = [ThreadingHTTPServer(("127.0.0.1", int(port)), make_handler(role, tokens_file))
               for role, port in zip(["memory", "recall", "swarm"], sys.argv[2:5])]
    for server in servers[1:]:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    print("ready", flush=True)
    servers[0].serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
