#!/usr/bin/env python3
"""Find and fill the `<!-- onboard: ... -->` slots of an agent workspace.

Usage:
    onboard_slots.py list [--root DIR]      JSON list of open slots, in asking order
    onboard_slots.py fill ID [--root DIR]   replace slot ID with the text on stdin

The workspace root is the directory holding `core/USER.md`. Without --root it is
found by walking up from the current directory (a local agent runs in the folder
above `.claude/`, a server agent in a plugin folder below the workspace).

Exit codes: 0 ok, 2 bad usage / slot not found, 3 answer refused (secret-shaped).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

# Asking order: the operator's profile first, then the agent's style, then tools.
SLOT_FILES = ("core/USER.md", "CLAUDE.md", "core/rules.md", "tools/TOOLS.md")
SLOT = re.compile(r"<!-- onboard:(.*?)-->\n?", re.S)
HEADING = re.compile(r"^(#{1,6} .+|\*\*[^*]+:\*\*)", re.M)
SECRET_SHAPES = (
    re.compile(r"[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}"),   # Telegram bot token
    re.compile(r"sk-[A-Za-z0-9_-]{20,}"),              # Anthropic / OpenAI style key
    re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}"),         # GitHub token
    re.compile(r"gsk_[A-Za-z0-9]{20,}"),               # Groq key
    re.compile(r"AKIA[0-9A-Z]{16}"),                   # AWS access key id
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),  # PEM private key
)
EXIT_USAGE = 2
EXIT_REFUSED = 3


@dataclass
class Slot:
    """One open slot."""

    id: str
    file: str
    heading: str
    question: str


def find_root(start: Path) -> Path | None:
    """Return the workspace root above START, or None.

    Args:
        start: Directory to start from.

    Returns:
        The directory that holds `core/USER.md`.
    """
    for base in (start, *start.parents):
        for cand in (base, base / ".claude"):
            if (cand / "core" / "USER.md").is_file():
                return cand
    return None


def slug(text: str) -> str:
    """Lower-case dash slug of a heading."""
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def open_slots(root: Path) -> list[Slot]:
    """List open slots in asking order.

    Args:
        root: Workspace root.

    Returns:
        Slots, each identified as `<file>#<heading-slug>`.
    """
    slots: list[Slot] = []
    for rel in SLOT_FILES:
        path = root / rel
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8")
        for match in SLOT.finditer(text):
            headings = HEADING.findall(text[:match.start()])
            heading = headings[-1].lstrip("#* ").rstrip(":*") if headings else "top"
            question = " ".join(match.group(1).split())
            slots.append(Slot(f"{rel}#{slug(heading)}", rel, heading, question))
    return slots


def fill(root: Path, slot_id: str, answer: str) -> int:
    """Replace one slot with ANSWER.

    Args:
        root: Workspace root.
        slot_id: Id from `list`.
        answer: Text to put where the slot comment was.

    Returns:
        Process exit code.
    """
    if any(shape.search(answer) for shape in SECRET_SHAPES):
        sys.stderr.write("refused: the answer looks like a key or token; store a path instead\n")
        return EXIT_REFUSED
    slot = next((s for s in open_slots(root) if s.id == slot_id), None)
    if slot is None:
        sys.stderr.write(f"no open slot {slot_id}\n")
        return EXIT_USAGE
    path = root / slot.file
    text = path.read_text(encoding="utf-8")
    for match in SLOT.finditer(text):
        if " ".join(match.group(1).split()) == slot.question:
            body = answer.strip() + "\n"
            path.write_text(text[:match.start()] + body + text[match.end():], encoding="utf-8")
            return 0
    return EXIT_USAGE


def main() -> int:
    """CLI entry point."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=("list", "fill"))
    parser.add_argument("slot_id", nargs="?")
    parser.add_argument("--root", type=Path)
    args = parser.parse_args()
    root = args.root or find_root(Path.cwd())
    if root is None or not (root / "core" / "USER.md").is_file():
        sys.stderr.write("workspace not found (no core/USER.md); pass --root\n")
        return EXIT_USAGE
    if args.command == "list":
        sys.stdout.write(json.dumps([asdict(s) for s in open_slots(root)], ensure_ascii=False,
                                    indent=2) + "\n")
        return 0
    if not args.slot_id:
        sys.stderr.write("fill needs a slot id\n")
        return EXIT_USAGE
    return fill(root, args.slot_id, sys.stdin.read())


if __name__ == "__main__":
    sys.exit(main())
