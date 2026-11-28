#!/usr/bin/env python3
"""Bring an agent's workspace settings.json up to the kit's hook layout, in place.

Used by update.sh: the workspace settings.json belongs to the owner (she may have edited it), so
it is never replaced, only migrated. Each step adds or rewrites one kit hook command and leaves
every other key, group and hook as it was. Idempotent.

Steps:
  cross-surface  Stop: "node cross-surface.mjs stop; " is prepended to the command that runs
                 write-handoff.sh, whatever else the owner put in it (Stop hooks of one
                 group run in parallel, so the writer must run before the merge in one command).
                 UserPromptSubmit: add "cross-surface.mjs prompt --self claude-code".

Usage: migrate-ws-settings.py <settings.json>
Prints "changed" or "unchanged". Exit 1 (file untouched) when the file is not valid JSON or
its hooks are not laid out the way Claude Code reads them.
"""

from __future__ import annotations

import json
import logging
import os
import sys
import tempfile
from pathlib import Path
from typing import Any

HOOKS_DIR = "$CLAUDE_PROJECT_DIR/.claude/hooks"
CROSS_SURFACE = "cross-surface.mjs"
WRITE_HANDOFF = "write-handoff.sh"
STOP_PREFIX = f"node {HOOKS_DIR}/{CROSS_SURFACE} stop; "
STOP_CHAIN = f"{STOP_PREFIX}{HOOKS_DIR}/{WRITE_HANDOFF}"
PROMPT_CMD = f"node {HOOKS_DIR}/{CROSS_SURFACE} prompt --self claude-code"
STOP_TIMEOUT_S = 10
LOG = logging.getLogger("migrate-ws-settings")
PROMPT_TIMEOUT_S = 5


def _commands(groups: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """All hook entries of an event, across its groups."""
    return [
        h
        for g in groups
        if isinstance(g, dict)
        for h in g.get("hooks", [])
        if isinstance(h, dict)
    ]


def migrate_cross_surface(settings: dict[str, Any]) -> bool:
    """Add the cross-surface hooks. Returns True when something changed."""
    hooks = settings.setdefault("hooks", {})
    changed = False

    stop = hooks.setdefault("Stop", [])
    if not any(CROSS_SURFACE in str(h.get("command", "")) for h in _commands(stop)):
        handoff = [h for h in _commands(stop) if WRITE_HANDOFF in str(h.get("command", ""))]
        if handoff:
            handoff[0]["command"] = STOP_PREFIX + str(handoff[0]["command"])
            handoff[0]["timeout"] = max(int(handoff[0].get("timeout", 0) or 0), STOP_TIMEOUT_S)
        else:
            entry = {"type": "command", "command": STOP_CHAIN, "timeout": STOP_TIMEOUT_S}
            stop.append({"hooks": [entry]})
        changed = True

    ups = hooks.setdefault("UserPromptSubmit", [])
    if not any(CROSS_SURFACE in str(h.get("command", "")) for h in _commands(ups)):
        entry = {"type": "command", "command": PROMPT_CMD, "timeout": PROMPT_TIMEOUT_S}
        groups = [g for g in ups if isinstance(g, dict) and "matcher" not in g]
        if groups:
            groups[0].setdefault("hooks", []).append(entry)
        else:
            ups.append({"hooks": [entry]})
        changed = True
    return changed


def write_atomic(path: Path, text: str) -> None:
    """Replace the file through a same-dir temp file, keeping its mode."""
    mode = path.stat().st_mode & 0o7777
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def main(argv: list[str]) -> int:
    """Migrate the settings file given as the only argument."""
    if len(argv) != 2:
        LOG.error("usage: migrate-ws-settings.py <settings.json>")
        return 2
    path = Path(argv[1])
    try:
        settings = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as err:
        LOG.error("cannot read %s: %s", path, err)
        return 1
    if not isinstance(settings, dict) or not isinstance(settings.get("hooks", {}), dict):
        LOG.error("unexpected layout in %s", path)
        return 1
    try:
        changed = migrate_cross_surface(settings)
    except (TypeError, ValueError, AttributeError) as err:
        LOG.error("unexpected hook layout in %s: %s", path, err)
        return 1
    if changed:
        write_atomic(path, json.dumps(settings, indent=2, ensure_ascii=False) + "\n")
        sys.stdout.write("changed\n")
    else:
        sys.stdout.write("unchanged\n")
    return 0


if __name__ == "__main__":
    logging.basicConfig(format="%(name)s: %(message)s")
    sys.exit(main(sys.argv))
