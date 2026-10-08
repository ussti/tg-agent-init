#!/usr/bin/env python3
"""Classify how an agent's .mcp.json is wired to a shared brain (G-Brain).

A brain entry is any MCP server that looks like one: "gbrain" in its name, a URL
on a brain port (8766-8768), "gbrain" in its URL path, or "gbrain" in its
command line. Its role (memory, recall, swarm) comes from the name, else the
port. An http entry dials its "url"; a stdio entry (mcp-remote and the like)
dials the URL found in its arguments.

Usage: brain-wiring.py MCP_JSON
Prints one tab-separated line:
  STATUS  HOST_OR_REASON  MEM_URL MEM_AUTH  REC_URL REC_AUTH  SW_URL SW_AUTH  EXTRAS
STATUS is one of:
  local    no brain entries, or every one on this server (kit wiring or none yet)
  remote   memory, recall and swarm all on another server; HOST is its host
  unknown  an entry the kit cannot place (variable host, stdio without URL)
  mixed    local and remote entries together, or a remote wiring with a gap
AUTH is the variable of a "Bearer ${VAR}" key, "-" for none, "!" for a literal
key (never printed). EXTRAS lists brain entries outside the kit's three names
(comma-separated), "-" if none. Missing values are "-".
"""

from __future__ import annotations

import ipaddress
import json
import re
import socket
import subprocess
import sys
from dataclasses import dataclass
from urllib.parse import urlsplit

BRAIN_PORTS = {8767: "memory", 8768: "recall", 8766: "swarm"}
ROLES = ("memory", "recall", "swarm")
ROLE_WORDS = {"memory": {"memory", "mem"}, "recall": {"recall", "rec"},
              "swarm": {"swarm", "sw"}}
KIT_NAMES = {"gbrain-memory", "gbrain-recall", "gbrain-swarm"}
HOSTNAME_TIMEOUT_S = 5
BEARER_VAR = re.compile(r"Bearer\s+\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
BEARER_ANY = re.compile(r"Bearer\s+\S")
NUMERIC_V4 = re.compile(r"(?:0x[0-9a-f]+|[0-9]+)(?:\.(?:0x[0-9a-f]+|[0-9]+)){0,3}")


@dataclass
class Entry:
    """One brain entry of .mcp.json."""

    name: str
    url: str
    role: str | None
    auth: str


def own_addresses() -> set[str]:
    """Names and addresses of this server: its hostname and `hostname -I` (no DNS)."""
    own = {socket.gethostname().lower().rstrip(".")}
    try:
        out = subprocess.run(["hostname", "-I"], capture_output=True, text=True,
                             timeout=HOSTNAME_TIMEOUT_S, check=False).stdout
        own.update(ip.lower() for ip in out.split())
    except (OSError, subprocess.SubprocessError):
        pass
    own.discard("")
    return own


def parse_ip(host: str) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
    """Parse an IP literal, including IPv4 shorthand such as 127.1."""
    try:
        return ipaddress.ip_address(host.split("%", 1)[0])
    except ValueError:
        pass
    if NUMERIC_V4.fullmatch(host):
        try:
            return ipaddress.IPv4Address(socket.inet_aton(host))
        except OSError:
            return None
    return None


def is_local(host: str, own: set[str]) -> bool:
    """True when HOST is this server: loopback, unspecified, its own name or address."""
    host = host.lower().rstrip(".")
    if host == "localhost" or host.endswith(".localhost") or host in own:
        return True
    ip = parse_ip(host)
    if ip is None:
        return False
    mapped = getattr(ip, "ipv4_mapped", None)
    if mapped is not None:
        ip = mapped
    return ip.is_loopback or ip.is_unspecified or str(ip) in own


def url_port(url: str) -> int | None:
    """Port of URL, or None when absent or out of range."""
    try:
        return urlsplit(url).port
    except ValueError:
        return None


def role_of(name: str, url: str) -> str | None:
    """memory / recall / swarm from the entry name, else from the port."""
    words = set(re.split(r"[^a-z0-9]+", name.lower()))
    for role in ROLES:
        if words & ROLE_WORDS[role]:
            return role
    return BRAIN_PORTS.get(url_port(url) or 0)


def auth_of(text: str) -> str:
    """Variable of a "Bearer ${VAR}" key, "!" for a literal key, "-" for none."""
    match = BEARER_VAR.search(text)
    if match:
        return match.group(1)
    return "!" if BEARER_ANY.search(text) else "-"


def classify(servers: dict, own: set[str]) -> list[str]:
    """Return the output fields for the mcpServers mapping SERVERS."""
    entries: list[Entry] = []
    for name, cfg in servers.items():
        if not isinstance(cfg, dict):
            continue
        args = [str(a) for a in cfg.get("args") or []]
        command = " ".join([str(cfg.get("command") or ""), *args])
        if cfg.get("url"):
            url = str(cfg["url"])
            headers = {str(k).lower(): str(v) for k, v in (cfg.get("headers") or {}).items()}
            auth = auth_of(headers.get("authorization", ""))
        else:
            url = next((a for a in args if re.match(r"https?://", a)), "")
            auth = auth_of(" ".join(args))
        brain_like = ("gbrain" in name.lower() or url_port(url) in BRAIN_PORTS
                      or "gbrain" in urlsplit(url).path.lower() or "gbrain" in command.lower())
        if not brain_like:
            continue
        if not url:
            return ["unknown", f"{name}: a brain entry with no URL (stdio?)"]
        if "$" in urlsplit(url).netloc:
            return ["unknown", f"{name}: the brain host is a variable"]
        entries.append(Entry(name, url, role_of(name, url), auth))

    extras = ",".join(e.name for e in entries if e.name not in KIT_NAMES) or "-"
    remote = [e for e in entries if not is_local(urlsplit(e.url).hostname or "", own)]
    if not remote:
        return ["local", "-", "-", "-", "-", "-", "-", "-", extras]
    if len(remote) != len(entries):
        local = ", ".join(e.name for e in entries if e not in remote)
        return ["mixed", f"brain entries on this server ({local}) and on another one "
                         f"({', '.join(e.name for e in remote)})"]
    fields: list[str] = []
    for role in ROLES:
        found = [e for e in remote if e.role == role]
        if len(found) != 1:
            what = "no" if not found else "more than one"
            return ["mixed", f"remote brain wiring has {what} {role} entry"]
        fields += [found[0].url, found[0].auth]
    hosts = sorted({urlsplit(e.url).hostname or "" for e in remote})
    return ["remote", ",".join(hosts), *fields, extras]


def main() -> int:
    """Entry point: argv MCP_JSON."""
    if len(sys.argv) != 2:
        print("usage: brain-wiring.py MCP_JSON", file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8") as fh:
        servers = json.load(fh).get("mcpServers") or {}
    fields = classify(servers, own_addresses())
    fields += ["-"] * (9 - len(fields))
    print("\t".join(f.replace("\t", " ") for f in fields))
    return 0


if __name__ == "__main__":
    sys.exit(main())
