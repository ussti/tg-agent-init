#!/usr/bin/env python3
"""Check the kit's pinned third-party programs for newer stable releases.

Reads kit/versions.env (KEY=VALUE data), asks npm, PyPI and git for the latest
stable versions, rewrites newer pins in place (unless --dry-run) and writes a
Markdown report. The last stdout line is `changed=true|false` for GITHUB_OUTPUT.
"""

from __future__ import annotations

import argparse
import io
import json
import logging
import re
import subprocess
import sys
import tempfile
import urllib.request
from contextlib import redirect_stdout
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Protocol

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_VERSIONS = REPO_ROOT / "kit" / "versions.env"
DEFAULT_DASHI_PIN = REPO_ROOT / "vendor" / "UPSTREAM_COMMIT"
DASHI_REPO = "https://github.com/qwwiwi/dashi-plugin-claude-code"
HTTP_TIMEOUT_S = 30
GIT_TIMEOUT_S = 300
STABLE_VERSION = re.compile(r"^\d+(\.\d+)+$")
STABLE_TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
SHA = re.compile(r"^[0-9a-f]{40}$")
SHORT_SHA = 12

log = logging.getLogger("bump-versions")

FetchJson = Callable[[str], dict]


class Git(Protocol):
    """The two git questions the checker needs."""

    def latest_tag(self, repo: str) -> tuple[str, str] | None: ...

    def is_ancestor(self, repo: str, old: str, new: str) -> bool: ...


@dataclass(frozen=True)
class Source:
    """One pinned (or report-only) registry item."""

    item: str
    key: str  # versions.env key; "" for report-only items
    url: str
    field: tuple[str, ...]  # path to the version inside the JSON answer
    changelog: str


SOURCES: tuple[Source, ...] = (
    Source("agent-browser", "AGENT_BROWSER_VERSION",
           "https://registry.npmjs.org/agent-browser/latest", ("version",),
           "https://github.com/vercel-labs/agent-browser/releases"),
    Source("vercel CLI", "VERCEL_CLI_VERSION",
           "https://registry.npmjs.org/vercel/latest", ("version",),
           "https://github.com/vercel/vercel/blob/main/packages/cli/CHANGELOG.md"),
    Source("gws-cli", "GWS_CLI_VERSION",
           "https://pypi.org/pypi/gws-cli/json", ("info", "version"),
           "https://github.com/andmarios/google-workspace-skill/releases"),
    Source("crawl4ai", "CRAWL4AI_VERSION",
           "https://pypi.org/pypi/crawl4ai/json", ("info", "version"),
           "https://github.com/unclecode/crawl4ai/releases"),
    Source("yt-dlp", "",
           "https://pypi.org/pypi/yt-dlp/json", ("info", "version"),
           "https://github.com/yt-dlp/yt-dlp/releases"),
)


@dataclass
class Row:
    """One line of the report."""

    item: str
    key: str
    pinned: str
    latest: str
    status: str
    changes: str


def read_pins(path: Path) -> dict[str, str]:
    """Parse KEY=VALUE lines; comments and blank lines ignored, CRLF tolerated."""
    pins: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            pins[key.strip()] = value.strip()
    return pins


def write_pins(path: Path, updates: dict[str, str]) -> None:
    """Replace the values of the given keys, keeping every other line as it was."""
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    out = []
    for line in lines:
        key = line.split("=", 1)[0].strip() if "=" in line else ""
        if key in updates and not line.lstrip().startswith("#"):
            ending = "\r\n" if line.endswith("\r\n") else "\n"
            line = f"{key}={updates[key]}{ending}"
        out.append(line)
    path.write_text("".join(out), encoding="utf-8")


def version_key(version: str) -> tuple[int, ...] | None:
    """Numeric sort key for a stable dotted version, None for anything else."""
    if not STABLE_VERSION.match(version):
        return None
    return tuple(int(part) for part in version.split("."))


def parse_ls_remote(output: str) -> dict[str, str]:
    """Map tag name -> commit sha from `git ls-remote --tags`, peeled sha winning."""
    tags: dict[str, str] = {}
    peeled: dict[str, str] = {}
    for line in output.splitlines():
        sha, _, ref = line.partition("\t")
        if not ref.startswith("refs/tags/"):
            continue
        name = ref[len("refs/tags/"):]
        if name.endswith("^{}"):
            peeled[name[:-3]] = sha
        else:
            tags[name] = sha
    tags.update(peeled)
    return tags


def pick_latest_tag(tags: dict[str, str]) -> tuple[str, str] | None:
    """Highest vX.Y.Z tag and its commit; pre-releases and other names ignored."""
    best: tuple[tuple[int, int, int], str, str] | None = None
    for name, sha in tags.items():
        match = STABLE_TAG.match(name)
        if match:
            key = (int(match[1]), int(match[2]), int(match[3]))
            if best is None or key > best[0]:
                best = (key, name, sha)
    return None if best is None else (best[1], best[2])


class RealGit:
    """git over the network: ls-remote for tags, a blobless clone for ancestry."""

    def latest_tag(self, repo: str) -> tuple[str, str] | None:
        out = subprocess.run(["git", "ls-remote", "--tags", repo], capture_output=True,
                             text=True, check=True, timeout=GIT_TIMEOUT_S).stdout
        return pick_latest_tag(parse_ls_remote(out))

    def is_ancestor(self, repo: str, old: str, new: str) -> bool:
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(["git", "clone", "--quiet", "--filter=blob:none", "--no-checkout",
                            repo, tmp], check=True, timeout=GIT_TIMEOUT_S)
            result = subprocess.run(["git", "-C", tmp, "merge-base", "--is-ancestor", old, new],
                                    timeout=GIT_TIMEOUT_S)
            return result.returncode == 0


def real_fetch_json(url: str) -> dict:
    """GET a JSON document."""
    request = urllib.request.Request(url, headers={"User-Agent": "tg-agent-init-versions-bot"})
    with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_S) as response:
        return json.load(response)


def dig(data: dict, field: tuple[str, ...]) -> str:
    """Walk a JSON path and return a string, or raise ValueError."""
    node: object = data
    for part in field:
        if not isinstance(node, dict) or part not in node:
            raise ValueError(f"no {'.'.join(field)} in answer")
        node = node[part]
    if not isinstance(node, str):
        raise ValueError(f"{'.'.join(field)} is not a string")
    return node


def check_registry(src: Source, pins: dict[str, str], fetch: FetchJson) -> Row:
    """Compare one registry item with its pin."""
    pinned = pins.get(src.key, "") if src.key else "unpinned"
    try:
        latest = dig(fetch(src.url), src.field)
    except Exception as exc:  # one broken registry must not stop the others
        log.warning("%s: %s", src.item, exc)
        return Row(src.item, src.key, pinned, "?", f"error: {exc}"[:120], src.changelog)
    if not src.key:
        return Row(src.item, "", pinned, latest, "report only", src.changelog)
    new_key, old_key = version_key(latest), version_key(pinned)
    if new_key is None:
        return Row(src.item, src.key, pinned, latest, "skipped: not a stable version",
                   src.changelog)
    if old_key is not None and new_key < old_key:
        return Row(src.item, src.key, pinned, latest, "skipped: older than pin", src.changelog)
    status = "bumped" if new_key != old_key else "up to date"
    return Row(src.item, src.key, pinned, latest, status, src.changelog)


def check_last30days(pins: dict[str, str], git: Git) -> Row:
    """Compare the last30days commit pin with the commit of its newest stable tag."""
    repo, old = pins.get("LAST30DAYS_REPO", ""), pins.get("LAST30DAYS_COMMIT", "")
    base = Row("last30days", "LAST30DAYS_COMMIT", old[:SHORT_SHA], "?", "", repo)
    if not repo or not SHA.match(old):
        base.status = "error: no valid LAST30DAYS_REPO/COMMIT pin"
        return base
    try:
        found = git.latest_tag(repo)
        if found is None:
            base.status = "skipped: no vX.Y.Z tags"
            return base
        tag, new = found
        base.latest = f"{tag} ({new[:SHORT_SHA]})"
        if new == old:
            base.status = "up to date"
            return base
        if not git.is_ancestor(repo, old, new):
            base.status = "skipped: pin is not an ancestor of the newest tag"
            return base
    except Exception as exc:
        log.warning("last30days: %s", exc)
        base.status = f"error: {exc}"[:120]
        return base
    base.status = "bumped"
    base.changes = f"{repo}/compare/{old[:SHORT_SHA]}...{new[:SHORT_SHA]}"
    base.latest = f"{tag} ({new})"
    return base


def check_dashi(pin_path: Path, git: Git) -> Row:
    """Report a newer Dashi plugin tag; never bumped here (patches need update-vendor.sh)."""
    base = Row("Dashi plugin", "", "?", "?", "", DASHI_REPO)
    try:
        pinned = pin_path.read_text(encoding="utf-8").strip()
        if not SHA.match(pinned):
            raise ValueError(f"no commit sha in {pin_path.name}")
        base.pinned = pinned[:SHORT_SHA]
        found = git.latest_tag(DASHI_REPO)
    except Exception as exc:
        log.warning("Dashi plugin: %s", exc)
        base.status = f"error: {exc}"[:120]
        return base
    if found is None:
        base.status = "skipped: no vX.Y.Z tags"
        return base
    tag, new = found
    base.latest = f"{tag} ({new[:SHORT_SHA]})"
    if new == pinned:
        base.status = "up to date"
        return base
    base.status = "report only"
    base.changes = (f"{DASHI_REPO}/compare/{pinned[:SHORT_SHA]}...{tag}; "
                    f"by hand: `scripts/update-vendor.sh {tag}`")
    return base


def check_all(path: Path, fetch: FetchJson, git: Git, dry_run: bool = False,
              dashi_pin: Path | None = None) -> tuple[list[Row], bool]:
    """Check every item, write newer pins unless dry_run, return rows and whether any changed.

    The Dashi plugin row (only when dashi_pin is given) is informational and never
    counts as a change.
    """
    pins = read_pins(path)
    rows = [check_registry(src, pins, fetch) for src in SOURCES]
    rows.append(check_last30days(pins, git))
    if dashi_pin is not None:
        rows.append(check_dashi(dashi_pin, git))
    updates: dict[str, str] = {}
    for row in rows:
        if row.status == "bumped":
            updates[row.key] = row.latest.split(" (")[-1].rstrip(")") \
                if row.key == "LAST30DAYS_COMMIT" else row.latest
    if updates and not dry_run:
        write_pins(path, updates)
    return rows, bool(updates)


def render_report(rows: list[Row]) -> str:
    """Markdown table for the PR body."""
    lines = ["| Item | Pinned | Latest | Status | Changes |", "|---|---|---|---|---|"]
    for r in rows:
        lines.append(f"| {r.item} | {r.pinned} | {r.latest} | {r.status} | {r.changes} |")
    return "\n".join(lines) + "\n"


def run_cli(argv: list[str], fetch: FetchJson, git: Git) -> tuple[int, str]:
    """Testable entry point: returns (exit code, captured stdout)."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--versions", type=Path, default=DEFAULT_VERSIONS)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--dashi-pin", type=Path, default=DEFAULT_DASHI_PIN)
    args = parser.parse_args(argv)
    buffer = io.StringIO()
    with redirect_stdout(buffer):
        try:
            rows, changed = check_all(args.versions, fetch, git, dry_run=args.dry_run,
                                      dashi_pin=args.dashi_pin)
        except OSError as exc:
            log.error("cannot read %s: %s", args.versions, exc)
            return 2, buffer.getvalue()
        report = render_report(rows)
        if args.report:
            args.report.write_text(report, encoding="utf-8")
        print(report, end="")
        print(f"changed={'true' if changed else 'false'}")
    return 0, buffer.getvalue()


def main() -> int:
    """CLI entry."""
    logging.basicConfig(level=logging.INFO, format="%(name)s: %(message)s")
    code, out = run_cli(sys.argv[1:], real_fetch_json, RealGit())
    sys.stdout.write(out)
    return code


if __name__ == "__main__":
    sys.exit(main())
