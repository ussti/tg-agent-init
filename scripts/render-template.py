#!/usr/bin/env python3
"""Fill {{KEY}} placeholders from the environment.

Usage:
    render-template.py SRC DST     render one file; any placeholder left
                                   unfilled (unset env var) is an error
    render-template.py --tree DIR  fill the core identity keys in every .md /
                                   .json under DIR, skipping skills/ (third-party
                                   skills keep their own braces)
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

PLACEHOLDER = re.compile(r"\{\{([A-Z][A-Z0-9_]*)\}\}")
TREE_KEYS = (
    "AGENT_NAME", "AGENT_ROLE", "ROLE_DESCRIPTION", "CHARACTER", "OPERATOR_NAME",
    "OPERATOR_ADDRESS", "TIMEZONE", "LANGUAGE", "PRIMARY_MODEL", "SECRETS_DIR",
)
TREE_SUFFIXES = (".md", ".json")


def render_file(src: Path, dst: Path) -> None:
    """Render SRC into DST, failing on any placeholder without an env value.

    Args:
        src: Template path.
        dst: Output path (overwritten).

    Raises:
        SystemExit: A placeholder has no value in the environment.
    """
    text = src.read_text(encoding="utf-8")
    missing = sorted({key for key in PLACEHOLDER.findall(text) if key not in os.environ})
    if missing:
        raise SystemExit(f"render-template: {src.name}: unset {', '.join(missing)}")
    dst.write_text(PLACEHOLDER.sub(lambda m: os.environ[m.group(1)], text), encoding="utf-8")


def render_tree(root: Path) -> None:
    """Fill TREE_KEYS in-place in every .md / .json under ROOT except skills/.

    Args:
        root: Agent workspace directory.
    """
    values = {f"{{{{{key}}}}}": os.environ.get(key, "") for key in TREE_KEYS}
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix not in TREE_SUFFIXES:
            continue
        if "skills" in path.relative_to(root).parts:
            continue
        text = path.read_text(encoding="utf-8")
        new = text
        for token, value in values.items():
            new = new.replace(token, value)
        if new != text:
            path.write_text(new, encoding="utf-8")


def main(argv: list[str]) -> None:
    """Dispatch on the command line.

    Args:
        argv: Arguments without the program name.
    """
    if len(argv) == 2 and argv[0] == "--tree":
        render_tree(Path(argv[1]))
    elif len(argv) == 2:
        render_file(Path(argv[0]), Path(argv[1]))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
