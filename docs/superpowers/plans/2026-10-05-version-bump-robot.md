# Version Bump Robot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A weekly GitHub Actions job finds newer versions of the kit's pinned third-party programs, bumps the pins, proves the kit still installs and starts on a clean runner, and opens one PR with an old→new table, changelog links and check results.

**Architecture:** All pins move into one file, `kit/versions.env`, read (never executed) by the installer, `agent-login`, the tests and the robot. `scripts/bump-versions.py` (stdlib only) asks npm, PyPI and git for the latest stable versions, rewrites the file and writes a Markdown report. `scripts/smoke-kit.sh` runs the real `kit/install-kit.sh` into a throwaway HOME and checks every tool. `.github/workflows/versions.yml` wires them together and opens the PR with `gh`.

**Tech Stack:** bash, Python 3.10+ stdlib (`urllib`, `json`, `subprocess`, `unittest`), GitHub Actions on `ubuntu-latest`, `gh` CLI, npm, pipx, git.

**Spec:** the design Kris approved in Telegram on 2026-10-05 (msg «Давай» to the design message). Its points, verbatim in meaning:
1. GitHub Actions, every Monday morning plus a manual run button.
2. All pins in one versions file.
3. Checked items: agent-browser, vercel CLI, gws-cli, crawl4ai, last30days; yt-dlp is unpinned and only reported.
4. When something is newer: bump the pin, run the tests and a real install on the runner, smoke each tool, run a trial last30days search.
5. Open a PR with an old→new table, changelog links and check results. No PR when nothing is newer.
6. The runner is not a client server: it proves install and launch, not quality. Before merge the operator's agent re-checks on the real server.
7. Plugins (superpowers, vercel, document-skills) are out: they come unpinned from the marketplace.

## Global Constraints

- Pinned items and their current values (copy exactly): `AGENT_BROWSER_VERSION=0.38.2`, `VERCEL_CLI_VERSION=62.2.0`, `GWS_CLI_VERSION=1.5.0`, `CRAWL4AI_VERSION=0.9.4`, `LAST30DAYS_REPO=https://github.com/mvanhorn/last30days-skill`, `LAST30DAYS_COMMIT=e93c8249d8ba073e8e88c388ed1f0fc403ffd86e`.
- Package names: npm `agent-browser`, npm `vercel`, PyPI `gws-cli`, PyPI `crawl4ai`, PyPI `yt-dlp`.
- Changelog URLs: agent-browser `https://github.com/vercel-labs/agent-browser/releases`, vercel `https://github.com/vercel/vercel/blob/main/packages/cli/CHANGELOG.md`, gws-cli `https://github.com/andmarios/google-workspace-skill/releases`, crawl4ai `https://github.com/unclecode/crawl4ai/releases`, yt-dlp `https://github.com/yt-dlp/yt-dlp/releases`, last30days compare `https://github.com/mvanhorn/last30days-skill/compare/<OLD>...<NEW>`.
- `kit/versions.env` is parsed as `KEY=VALUE` lines, never `source`d or `eval`ed. Blank lines and `#` comments allowed; CRLF tolerated.
- The robot never downgrades and never takes a pre-release (npm `latest` dist-tag; PyPI `info.version`; git tags matching `^v\d+\.\d+\.\d+$` only).
- last30days is bumped only to the commit of its highest semver tag, and only when the current pin is an ancestor of it.
- The trial last30days search is informational: it is reported but never fails the run (keyless Reddit is blocked from many datacenter IPs).
- Robot PR branch: `bot/versions-YYYY-MM-DD-<run_id>`; never force-pushed; older open PRs with label `versions-bot` are closed with a comment pointing at the new one.
- Workflow permissions: `contents: write`, `pull-requests: write`; no other secrets than the default `GITHUB_TOKEN`.
- Schedule: `cron: '0 1 * * 1'` (Monday 01:00 UTC = 09:00 Asia/Makassar).
- Repo setting «Allow GitHub Actions to create and approve pull requests» must be on; changing it is the operator's decision, not a task step.
- Public repo: no operator, agent, host or chat names in any file (enforced by `scripts/leak-scan.sh`).
- Commit messages in Russian, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Python: type hints, Google docstrings, pathlib, f-strings, dataclasses, `logging` for diagnostics (the report and `changed=` line go to files/stdout by design). Bash: `set -euo pipefail`, quoted variables. Max line 100.

## Review Focus

1. One registry is down or answers garbage (HTTP 5xx, bad JSON, timeout): the other items are still checked, that row says `error: …`, its pin stays, and the run does not crash.
2. A registry reports a lower or non-numeric version (yanked release, odd tag): no downgrade, the row says `skipped: …`.
3. last30days history was rewritten or the newest tag is not a descendant of the pin: no bump, the row says so.
4. Install succeeds but a tool does not start (or reports a different version than pinned): the PR is still opened, as a draft, with a `[checks failed]` title prefix, and the job ends red.
5. The robot fires again before the previous PR is merged: a new PR on a new branch, the old one closed with a comment, no force push, no duplicate open bot PRs.

---

### Task 1: One versions file

**Files:**
- Create: `kit/versions.env`
- Delete: `kit/skills/research/last30days/UPSTREAM`
- Modify: `kit/install-kit.sh:75-77` (constants), `kit/install-kit.sh:97-107` (`read_last30_pin`), `kit/install-kit.sh:160` (warning text)
- Modify: `kit/bin/agent-login:31` and `:191`
- Modify: `kit/README.md:55-66`
- Modify: `tests/run-tests.sh:281-302`
- Test: `kit/tests/test_agent_login.py` (new test class), `tests/run-tests.sh`

**Interfaces:**
- Produces: `kit/versions.env` with exactly the six keys from Global Constraints, in that order, under a two-line comment header.
- Produces: bash function `pin KEY` in `install-kit.sh` that prints the value or nothing.
- Produces: Python `read_pins(path: Path) -> dict[str, str]` in `agent-login`; module constants `VERSIONS_FILE: Path` and `VERCEL_CLI_VERSION: str`, `GWS_CLI_VERSION: str` (empty string when the file is missing).

- [ ] **Step 1: Write the failing Python test**

Append to `kit/tests/test_agent_login.py` (it already imports the script as `al`; follow its existing import helper):

```python
class ReadPinsTest(unittest.TestCase):
    """versions.env is parsed as data, never executed."""

    def test_parses_values_comments_and_crlf(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "versions.env"
            path.write_bytes(b"# header\r\n\r\nVERCEL_CLI_VERSION=1.2.3\r\nX = y \n")
            self.assertEqual(al.read_pins(path), {"VERCEL_CLI_VERSION": "1.2.3", "X": "y"})

    def test_missing_file_gives_empty_dict(self) -> None:
        self.assertEqual(al.read_pins(Path("/nonexistent/versions.env")), {})

    def test_shell_syntax_is_not_executed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "versions.env"
            path.write_text("A=$(touch pwned)\n")
            self.assertEqual(al.read_pins(path), {"A": "$(touch pwned)"})

    def test_real_file_has_pins(self) -> None:
        pins = al.read_pins(al.VERSIONS_FILE)
        for key in ("AGENT_BROWSER_VERSION", "VERCEL_CLI_VERSION", "GWS_CLI_VERSION",
                    "CRAWL4AI_VERSION", "LAST30DAYS_REPO", "LAST30DAYS_COMMIT"):
            self.assertTrue(pins.get(key), key)
        self.assertEqual(al.VERCEL_CLI_VERSION, pins["VERCEL_CLI_VERSION"])
        self.assertRegex(pins["LAST30DAYS_COMMIT"], r"^[0-9a-f]{40}$")
```

Add `import tempfile` and `from pathlib import Path` at the top if missing.

- [ ] **Step 2: Run it, expect failure**

Run: `python3 -m unittest kit.tests.test_agent_login.ReadPinsTest -v` (or `python3 -m unittest discover -s kit/tests -k ReadPins -v`)
Expected: FAIL / ERROR — `module 'agent-login' has no attribute 'read_pins'`.

- [ ] **Step 3: Create `kit/versions.env`**

```
# Pinned versions of the kit's third-party programs. The only place they are written.
# Read as KEY=VALUE data (never sourced); the weekly robot bumps these lines via a PR.
AGENT_BROWSER_VERSION=0.38.2
VERCEL_CLI_VERSION=62.2.0
GWS_CLI_VERSION=1.5.0
CRAWL4AI_VERSION=0.9.4
LAST30DAYS_REPO=https://github.com/mvanhorn/last30days-skill
LAST30DAYS_COMMIT=e93c8249d8ba073e8e88c388ed1f0fc403ffd86e
```

`git rm kit/skills/research/last30days/UPSTREAM`.

- [ ] **Step 4: `agent-login` reads the file**

Replace line 31 `VERCEL_CLI_VERSION = "62.2.0"` with:

```python
VERSIONS_FILE = Path(__file__).resolve().parent.parent / "versions.env"


def read_pins(path: Path) -> dict[str, str]:
    """Parse KEY=VALUE lines of versions.env without executing anything.

    Args:
        path: The versions file.

    Returns:
        Key to value; empty when the file is missing or unreadable.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return {}
    pins: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        pins[key.strip()] = value.strip()
    return pins


_PINS = read_pins(VERSIONS_FILE)
VERCEL_CLI_VERSION = _PINS.get("VERCEL_CLI_VERSION", "")
GWS_CLI_VERSION = _PINS.get("GWS_CLI_VERSION", "")
```

Because `read_pins` is defined after other module constants, keep this block right after the existing constants (it uses `Path`, already imported). Line 191 becomes:

```python
    gws = need("gws-cli", f"Install: pipx install gws-cli=={GWS_CLI_VERSION}")
```

In the Vercel login function, before building the `npx` command, add the guard:

```python
    if not VERCEL_CLI_VERSION:
        print(f"agent-login: no VERCEL_CLI_VERSION in {VERSIONS_FILE}; reinstall the kit",
              file=sys.stderr)
        return 1
```

- [ ] **Step 5: Run Python tests, expect pass**

Run: `python3 -m unittest discover -s kit/tests`
Expected: all OK (79 existing + 4 new = 83).

- [ ] **Step 6: Installer reads the file**

In `kit/install-kit.sh` replace the three `readonly …_VERSION` lines with:

```bash
# Pinned versions live in kit/versions.env; read as data, never sourced.
pin() {
  [ -r "$KIT/versions.env" ] || return 0
  sed -n "s/^$1=//p" "$KIT/versions.env" | tr -d '\r' | head -n 1
}
AGENT_BROWSER_VERSION="$(pin AGENT_BROWSER_VERSION)"
CRAWL4AI_VERSION="$(pin CRAWL4AI_VERSION)"
GWS_CLI_VERSION="$(pin GWS_CLI_VERSION)"
readonly AGENT_BROWSER_VERSION CRAWL4AI_VERSION GWS_CLI_VERSION
[ -r "$KIT/versions.env" ] || warn "no $KIT/versions.env: pinned tools will be skipped"
```

In `install_deps`, skip an item whose version is empty instead of installing `pkg@` / `pkg==`:

```bash
  if [ -z "$AGENT_BROWSER_VERSION" ]; then
    warn "agent-browser: no pinned version; skipped"
  elif command -v npm > /dev/null; then
```

(the existing `if command -v npm` branch becomes the `elif`, its `else` stays). For pipx, build the list so an empty pin drops that item:

```bash
    local pkg pkgs=()
    [ -n "$GWS_CLI_VERSION" ] && pkgs+=("gws-cli==$GWS_CLI_VERSION")
    [ -n "$CRAWL4AI_VERSION" ] && pkgs+=("crawl4ai==$CRAWL4AI_VERSION")
    pkgs+=(yt-dlp)
    for pkg in "${pkgs[@]}"; do
```

Replace the body of `read_last30_pin`:

```bash
# Read the pinned repo/commit of the last30days skill into LAST30_REPO / LAST30_COMMIT.
read_last30_pin() {
  LAST30_REPO="$(pin LAST30DAYS_REPO)"
  LAST30_COMMIT="$(pin LAST30DAYS_COMMIT)"
  [ -n "$LAST30_REPO" ] && [ -n "$LAST30_COMMIT" ] \
    || warn "last30days: no pin in $KIT/versions.env; the skill stays a stub"
}
```

Line 160 warning text: `"last30days: no pinned repo/commit in versions.env; skipped"`.

- [ ] **Step 7: Tests read pins from the file**

In `tests/run-tests.sh`, right before the `check "last30days UPSTREAM pins…"` block, add:

```bash
V="$KIT/kit/versions.env"
vpin() { sed -n "s/^$1=//p" "$V" | tr -d '\r'; }
```

Replace the UPSTREAM check with:

```bash
check "versions.env pins every third-party item" bash -c \
  "for k in AGENT_BROWSER_VERSION VERCEL_CLI_VERSION GWS_CLI_VERSION CRAWL4AI_VERSION \
   LAST30DAYS_REPO LAST30DAYS_COMMIT; do grep -Eq \"^\$k=.+\" '$V' || exit 1; done"
check "no stray UPSTREAM pin file" test ! -e "$KIT/kit/skills/research/last30days/UPSTREAM"
check "no version literals outside versions.env" bash -c \
  "! grep -rnE '(agent-browser@|gws-cli==|crawl4ai==|vercel@)[0-9]' \
   '$KIT/kit/install-kit.sh' '$KIT/kit/bin' '$KIT/kit/README.md'"
```

and replace the literals in the three install-log checks:

```bash
check "agent-browser from npm, pinned, no root" \
  grep -q "npm install -g --prefix $FAKE_HOME/.local agent-browser@$(vpin AGENT_BROWSER_VERSION)" \
  "$FAKE_TOOLS_LOG"
check "python tools from pipx, pinned" bash -c \
  "grep -q 'pipx install --force gws-cli==$(vpin GWS_CLI_VERSION)' '$FAKE_TOOLS_LOG' && \
  grep -q 'pipx install --force crawl4ai==$(vpin CRAWL4AI_VERSION)' '$FAKE_TOOLS_LOG' && \
  grep -q 'pipx install --force yt-dlp' '$FAKE_TOOLS_LOG'"
check "last30days cloned at the pinned commit and linked" bash -c \
  "grep -q 'git clone $(vpin LAST30DAYS_REPO)' '$FAKE_TOOLS_LOG' && \
   grep -q 'checkout $(vpin LAST30DAYS_COMMIT)' '$FAKE_TOOLS_LOG' && \
   grep -q 'description: upstream' '$WS/skills/last30days/SKILL.md'"
```

Add one negative test right after: installer with a versions.env lacking `CRAWL4AI_VERSION` warns and does not call `pipx install --force crawl4ai==`:

```bash
check "missing pin skips the item instead of installing it unpinned" bash -c "
  W=\$(mktemp -d '$WORK/nopin.XXXX') && mkdir -p \"\$W/ws\" \"\$W/kit\" \
  && cp -R '$KIT/kit/.' \"\$W/kit/\" && sed -i '/^CRAWL4AI_VERSION=/d' \"\$W/kit/versions.env\" \
  && : > '$FAKE_TOOLS_LOG' \
  && HOME='$FAKE_HOME' PATH='$FAKE_BIN':\"\$PATH\" bash \"\$W/kit/install-kit.sh\" \"\$W/ws\" \
     \"\$W/cfg\" >\"\$W/log\" 2>&1 \
  && ! grep -q 'crawl4ai==' '$FAKE_TOOLS_LOG' && grep -q 'pipx install --force yt-dlp' '$FAKE_TOOLS_LOG'"
```

Use the variable names the file already defines for the fake-tools bin dir and log (read lines 82-110 first; rename `FAKE_BIN` to whatever is there). If clearing the shared log would break later checks, log to a copy instead: check that later checks do not read it, else restore it with `cp` before and after.

- [ ] **Step 8: README points at the file**

In `kit/README.md` replace the version-bearing table cells: agent-browser → `npm agent-browser (version: kit/versions.env)`, crawl4ai → `pipx crawl4ai (version: kit/versions.env)`, last30days → ``git `mvanhorn/last30days-skill` at the commit pinned in `versions.env` ``, gws → `pipx gws-cli (version: kit/versions.env)`, Vercel → `plugin vercel@claude-plugins-official, CLI vercel (version: kit/versions.env)`. Add under the table:

```markdown
All pins live in `kit/versions.env`. A weekly GitHub Actions job
(`.github/workflows/versions.yml`) checks for newer releases and opens a PR with the
bump and the results of a clean install; merge it only after checking on a real server.
```

- [ ] **Step 9: Full suite**

Run: `bash tests/run-tests.sh` → all pass (209 − 1 replaced + 4 new = 212 expected; report the real number). `python3 -m unittest discover -s kit/tests` → OK. `bash scripts/leak-scan.sh` → clean.

- [ ] **Step 10: Commit**

```bash
git add -A kit tests
git commit -m "refactor(kit): все закреплённые версии в одном файле kit/versions.env

Установщик, agent-login, README и тесты читают версии из versions.env как
данные, без source. UPSTREAM для last30days удалён. Пустой пин пропускает
программу, а не ставит её без версии.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Version checker `scripts/bump-versions.py`

**Files:**
- Create: `scripts/bump-versions.py`
- Create: `scripts/tests/test_bump_versions.py`
- Modify: `tests/run-tests.sh` section 2 (syntax) and a new line running the unit tests

**Interfaces:**
- Consumes: `kit/versions.env` (Task 1).
- Produces CLI: `python3 scripts/bump-versions.py [--versions PATH] [--report PATH] [--dry-run]`. Prints exactly one final stdout line `changed=true` or `changed=false`. Exit 0 unless the versions file is unreadable (exit 2). Network errors per item never change the exit code.
- Produces report (Markdown) consumed verbatim as the PR body top by Task 4: a table `| Item | Pinned | Latest | Status | Changes |`. Status is one of `bumped`, `up to date`, `report only`, `skipped: <reason>`, `error: <reason>`.

- [ ] **Step 1: Write the failing tests**

`scripts/tests/test_bump_versions.py`:

```python
"""Unit tests for scripts/bump-versions.py; no network (fetch and git are injected)."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "bump-versions.py"
_spec = importlib.util.spec_from_file_location("bump_versions", SCRIPT)
bv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bv)

OLD = "e93c8249d8ba073e8e88c388ed1f0fc403ffd86e"
NEW = "5103ba478b380552207a3754b74c7655d64208cd"
PINS_TEXT = (
    "# header\n"
    "AGENT_BROWSER_VERSION=0.38.2\n"
    "VERCEL_CLI_VERSION=62.2.0\n"
    "GWS_CLI_VERSION=1.5.0\n"
    "CRAWL4AI_VERSION=0.9.4\n"
    "LAST30DAYS_REPO=https://github.com/mvanhorn/last30days-skill\n"
    f"LAST30DAYS_COMMIT={OLD}\n"
)


def fake_fetch(answers: dict[str, object]):
    """Return a fetch_json stub: URL -> dict, or raise when the answer is an Exception."""
    def fetch(url: str) -> dict:
        answer = answers[url]
        if isinstance(answer, Exception):
            raise answer
        return answer
    return fetch


def registry(ab: str = "0.38.2", vc: str = "62.2.0", gws: str = "1.5.0",
             c4: str = "0.9.4", yt: str = "2026.8.19") -> dict[str, object]:
    return {
        "https://registry.npmjs.org/agent-browser/latest": {"version": ab},
        "https://registry.npmjs.org/vercel/latest": {"version": vc},
        "https://pypi.org/pypi/gws-cli/json": {"info": {"version": gws}},
        "https://pypi.org/pypi/crawl4ai/json": {"info": {"version": c4}},
        "https://pypi.org/pypi/yt-dlp/json": {"info": {"version": yt}},
    }


class FakeGit:
    """Stub for the git calls: tags listing and ancestry."""

    def __init__(self, tags: dict[str, str], ancestor: bool = True) -> None:
        self.tags = tags
        self.ancestor = ancestor

    def latest_tag(self, repo: str) -> tuple[str, str] | None:
        return bv.pick_latest_tag(self.tags)

    def is_ancestor(self, repo: str, old: str, new: str) -> bool:
        return self.ancestor


class BumpTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "versions.env"
        self.path.write_text(PINS_TEXT)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_check(self, answers, git, dry_run=False):
        return bv.check_all(self.path, fake_fetch(answers), git, dry_run=dry_run)

    def test_nothing_new(self) -> None:
        rows, changed = self.run_check(registry(), FakeGit({"v3.9.4": OLD}))
        self.assertFalse(changed)
        self.assertEqual(self.path.read_text(), PINS_TEXT)
        self.assertEqual({r.status for r in rows if r.key}, {"up to date"})

    def test_newer_npm_and_pypi_are_written_keeping_comments(self) -> None:
        rows, changed = self.run_check(registry(ab="0.39.0", c4="0.10.1"),
                                       FakeGit({"v3.9.4": OLD}))
        self.assertTrue(changed)
        text = self.path.read_text()
        self.assertIn("AGENT_BROWSER_VERSION=0.39.0\n", text)
        self.assertIn("CRAWL4AI_VERSION=0.10.1\n", text)
        self.assertTrue(text.startswith("# header\n"))

    def test_dry_run_does_not_write(self) -> None:
        _, changed = self.run_check(registry(ab="0.39.0"), FakeGit({"v3.9.4": OLD}),
                                    dry_run=True)
        self.assertTrue(changed)
        self.assertEqual(self.path.read_text(), PINS_TEXT)

    def test_no_downgrade(self) -> None:
        rows, changed = self.run_check(registry(vc="61.0.0"), FakeGit({"v3.9.4": OLD}))
        self.assertFalse(changed)
        row = next(r for r in rows if r.key == "VERCEL_CLI_VERSION")
        self.assertTrue(row.status.startswith("skipped"))

    def test_non_numeric_version_is_skipped(self) -> None:
        rows, changed = self.run_check(registry(gws="1.6.0rc1"), FakeGit({"v3.9.4": OLD}))
        self.assertFalse(changed)
        row = next(r for r in rows if r.key == "GWS_CLI_VERSION")
        self.assertTrue(row.status.startswith("skipped"))

    def test_registry_error_keeps_pin_and_other_items(self) -> None:
        answers = registry(c4="0.10.1")
        answers["https://registry.npmjs.org/vercel/latest"] = OSError("HTTP 503")
        rows, changed = self.run_check(answers, FakeGit({"v3.9.4": OLD}))
        self.assertTrue(changed)
        row = next(r for r in rows if r.key == "VERCEL_CLI_VERSION")
        self.assertTrue(row.status.startswith("error"))
        self.assertIn("VERCEL_CLI_VERSION=62.2.0\n", self.path.read_text())

    def test_bad_json_shape_is_an_error_row(self) -> None:
        answers = registry()
        answers["https://pypi.org/pypi/crawl4ai/json"] = {"unexpected": True}
        rows, _ = self.run_check(answers, FakeGit({"v3.9.4": OLD}))
        row = next(r for r in rows if r.key == "CRAWL4AI_VERSION")
        self.assertTrue(row.status.startswith("error"))

    def test_last30days_bumps_to_newest_tag_commit(self) -> None:
        rows, changed = self.run_check(registry(), FakeGit({"v3.9.4": OLD, "v3.26.0": NEW}))
        self.assertTrue(changed)
        self.assertIn(f"LAST30DAYS_COMMIT={NEW}\n", self.path.read_text())
        row = next(r for r in rows if r.key == "LAST30DAYS_COMMIT")
        self.assertIn(f"compare/{OLD[:12]}...{NEW[:12]}", row.changes)

    def test_last30days_not_descendant_is_skipped(self) -> None:
        rows, changed = self.run_check(registry(),
                                       FakeGit({"v3.26.0": NEW}, ancestor=False))
        self.assertFalse(changed)
        row = next(r for r in rows if r.key == "LAST30DAYS_COMMIT")
        self.assertTrue(row.status.startswith("skipped"))

    def test_yt_dlp_is_report_only(self) -> None:
        rows, changed = self.run_check(registry(yt="2027.1.1"), FakeGit({"v3.9.4": OLD}))
        self.assertFalse(changed)
        row = next(r for r in rows if r.item == "yt-dlp")
        self.assertEqual(row.status, "report only")

    def test_pick_latest_tag_ignores_prereleases_and_orders_numerically(self) -> None:
        tags = {"v3.9.4": "a" * 40, "v3.26.0": "b" * 40, "v4.0.0-beta": "c" * 40, "x": "d" * 40}
        self.assertEqual(bv.pick_latest_tag(tags), ("v3.26.0", "b" * 40))

    def test_parse_ls_remote_prefers_peeled_sha(self) -> None:
        out = (f"{'1' * 40}\trefs/tags/v3.26.0\n{NEW}\trefs/tags/v3.26.0^{{}}\n"
               f"{OLD}\trefs/tags/v3.9.4\n")
        self.assertEqual(bv.parse_ls_remote(out), {"v3.26.0": NEW, "v3.9.4": OLD})

    def test_report_table(self) -> None:
        rows, _ = self.run_check(registry(ab="0.39.0"), FakeGit({"v3.9.4": OLD}))
        report = bv.render_report(rows)
        self.assertIn("| Item | Pinned | Latest | Status | Changes |", report)
        self.assertIn("| agent-browser | 0.38.2 | 0.39.0 | bumped |", report)

    def test_cli_prints_changed_line_and_writes_report(self) -> None:
        report = Path(self.tmp.name) / "r.md"
        code, out = bv.run_cli(["--versions", str(self.path), "--report", str(report),
                                "--dry-run"], fake_fetch(registry()), FakeGit({"v3.9.4": OLD}))
        self.assertEqual(code, 0)
        self.assertEqual(out.strip().splitlines()[-1], "changed=false")
        self.assertIn("| Item |", report.read_text())

    def test_cli_missing_versions_file_exits_2(self) -> None:
        code, _ = bv.run_cli(["--versions", "/nonexistent"], fake_fetch({}), FakeGit({}))
        self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run, expect failure**

Run: `python3 -m unittest discover -s scripts/tests -v`
Expected: ERROR — `bump-versions.py` not found.

- [ ] **Step 3: Implement `scripts/bump-versions.py`**

```python
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


def check_all(path: Path, fetch: FetchJson, git: Git,
              dry_run: bool = False) -> tuple[list[Row], bool]:
    """Check every item, write newer pins unless dry_run, return rows and whether any changed."""
    pins = read_pins(path)
    rows = [check_registry(src, pins, fetch) for src in SOURCES]
    rows.append(check_last30days(pins, git))
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
    args = parser.parse_args(argv)
    buffer = io.StringIO()
    with redirect_stdout(buffer):
        try:
            rows, changed = check_all(args.versions, fetch, git, dry_run=args.dry_run)
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
```

Note on `Row.latest` for last30days: on a bump it holds `"<tag> (<full sha>)"`; `check_all` takes the sha from the parentheses. `chmod +x scripts/bump-versions.py`.

- [ ] **Step 4: Run tests, expect pass**

Run: `python3 -m unittest discover -s scripts/tests -v` → all OK.

- [ ] **Step 5: Live dry run (network, read-only)**

Run: `python3 scripts/bump-versions.py --dry-run --report /tmp/vr.md` (use the scratchpad, not `/tmp`, when an agent runs it)
Expected on 2026-10-05: agent-browser/gws-cli/crawl4ai `up to date`, vercel CLI `up to date`, yt-dlp `report only`, last30days `bumped` to v3.26.0 (5103ba4…) — the robot proposes, a human rejects if the trial search regresses. `git diff --exit-code kit/versions.env` → no change.

- [ ] **Step 6: Hook into run-tests**

In `tests/run-tests.sh` section 2 add `check "bump-versions.py compiles" python3 -m py_compile scripts/bump-versions.py` (match how section 2 iterates files; use `$KIT/scripts/...`), and after section 3 add:

```bash
check "bump-versions unit tests" python3 -m unittest discover -s "$KIT/scripts/tests"
```

Run `bash tests/run-tests.sh` → all pass. Make sure `py_compile` writes no `__pycache__` into the repo (`PYTHONDONTWRITEBYTECODE=1`, as the cal check does with `ast.parse`); add `scripts/tests/__pycache__/` to `.gitignore` if unittest creates it.

- [ ] **Step 7: Commit**

```bash
git add scripts/bump-versions.py scripts/tests tests/run-tests.sh .gitignore
git commit -m "feat(versions): скрипт проверки новых версий закреплённых программ

npm, PyPI и теги last30days; без понижений и предрелизов, last30days только
вперёд по истории. Отчёт таблицей для PR, последняя строка changed=true|false.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Smoke check `scripts/smoke-kit.sh`

**Files:**
- Create: `scripts/smoke-kit.sh`
- Modify: `tests/run-tests.sh` (syntax check covers it; one offline test with fake tools)

**Interfaces:**
- Consumes: `kit/versions.env`, `kit/install-kit.sh <AGENT_WS> <CLAUDE_CONFIG_DIR>`.
- Produces CLI: `scripts/smoke-kit.sh <REPORT_MD>`. Installs the kit for real into `$SMOKE_HOME` (default: a new `mktemp -d`), appends a Markdown table `| Check | Result | Detail |` to REPORT_MD, exits 1 if any gate failed, 0 otherwise. Env `SMOKE_SKIP_SEARCH=1` skips the trial search. Never touches the real `$HOME`.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# smoke-kit.sh -- install the kit for real into a throwaway HOME and check every tool.
# Usage: scripts/smoke-kit.sh <REPORT_MD>
# Gates: each pinned tool installed at its pinned version and starts. Informational:
# the trial last30days search (keyless Reddit is often blocked from datacenter IPs).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="${1:?usage: smoke-kit.sh <REPORT_MD>}"
V="$REPO/kit/versions.env"
[ -r "$V" ] || { echo "[smoke] no $V" >&2; exit 2; }
pin() { sed -n "s/^$1=//p" "$V" | tr -d '\r' | head -n 1; }

SMOKE_HOME="${SMOKE_HOME:-$(mktemp -d)}"
export HOME="$SMOKE_HOME"
export PATH="$HOME/.local/bin:$PATH"
WS="$HOME/ws"
mkdir -p "$WS"
failed=0

row() { echo "| $1 | $2 | $3 |" >> "$REPORT"; echo "[smoke] $1: $2 $3"; }
gate() {  # gate <name> <detail-on-success> <cmd...>
  local name="$1" detail="$2"; shift 2
  local out
  if out="$("$@" 2>&1)"; then
    row "$name" ok "$detail"
  else
    row "$name" FAIL "$(printf '%s' "$out" | tail -n 1 | tr '|' '/' | cut -c1-120)"
    failed=1
  fi
}
has_version() {  # has_version <expected> <cmd...>: command output contains the version
  local want="$1"; shift
  "$@" 2>&1 | grep -qF "$want"
}
pipx_version() {  # pipx_version <package> -> installed version
  pipx list --json | python3 -c \
    "import json,sys; v=json.load(sys.stdin)['venvs'].get(sys.argv[1]); \
print(v['metadata']['main_package']['package_version'] if v else '')" "$1"
}

{ echo; echo "| Check | Result | Detail |"; echo "|---|---|---|"; } >> "$REPORT"

echo "[smoke] installing the kit into $WS (HOME=$HOME)"
if bash "$REPO/kit/install-kit.sh" "$WS" "$HOME/.claude-agent-smoke" > "$HOME/install.log" 2>&1
then
  row "kit install" ok "$(grep -c 'WARN' "$HOME/install.log" || true) warnings"
else
  row "kit install" FAIL "exit $?, see job log"; failed=1
fi
grep 'WARN' "$HOME/install.log" || true

ab="$(pin AGENT_BROWSER_VERSION)"; vc="$(pin VERCEL_CLI_VERSION)"
gws="$(pin GWS_CLI_VERSION)"; c4="$(pin CRAWL4AI_VERSION)"
l30="$(pin LAST30DAYS_COMMIT)"

gate "agent-browser $ab" "--version matches" has_version "$ab" agent-browser --version
gate "vercel CLI $vc" "--version matches" has_version "$vc" npx --yes "vercel@$vc" --version
gate "gws-cli $gws" "pipx version matches" test "$(pipx_version gws-cli)" = "$gws"
gate "gws-cli starts" "--help" gws-cli --help
gate "crawl4ai $c4" "pipx version matches" test "$(pipx_version crawl4ai)" = "$c4"
gate "crwl starts" "--help" crwl --help
gate "yt-dlp" "$(yt-dlp --version 2>/dev/null || echo missing)" yt-dlp --version
L30="$WS/kit/vendor/last30days"
gate "last30days ${l30:0:12}" "checkout on pin" test "$(git -C "$L30" rev-parse HEAD)" = "$l30"
gate "last30days skill linked" "SKILL.md present" test -f "$WS/skills/last30days/SKILL.md"
gate "last30days starts" "--help" python3 "$L30/skills/last30days/scripts/last30days.py" --help

if [ "${SMOKE_SKIP_SEARCH:-0}" = 1 ]; then
  row "last30days trial search" skipped "SMOKE_SKIP_SEARCH=1"
else
  out="$(timeout 300 python3 "$L30/skills/last30days/scripts/last30days.py" "claude code" \
    --search reddit --quick --emit compact 2>&1 || true)"
  threads="$(printf '%s' "$out" | grep -oE 'Reddit: [0-9]+ threads' | grep -oE '[0-9]+' \
    | head -n 1 || true)"
  row "last30days trial search (info)" "${threads:-0} Reddit threads" \
    "informational; runner IPs are often blocked"
fi

echo "[smoke] done, failed=$failed"
exit "$failed"
```

`chmod +x scripts/smoke-kit.sh`.

- [ ] **Step 2: Offline test in run-tests (fake tools)**

In `tests/run-tests.sh` section 4 (where the fake npm/pipx/agent-browser/git exist), add a check that runs the smoke script against the fake tools with `SMOKE_SKIP_SEARCH=1` and asserts that it writes the report header and a `kit install | ok` row, and that it never touches the real HOME:

```bash
check "smoke-kit writes a report and stays inside its HOME" bash -c "
  R=\$(mktemp '$WORK/smoke.XXXX.md') && SH=\$(mktemp -d '$WORK/smokehome.XXXX') \
  && SMOKE_HOME=\"\$SH\" SMOKE_SKIP_SEARCH=1 PATH='$FAKE_BIN':\"\$PATH\" \
     bash '$KIT/scripts/smoke-kit.sh' \"\$R\" >/dev/null 2>&1; \
  grep -q '| Check | Result | Detail |' \"\$R\" && grep -q '| kit install | ok |' \"\$R\" \
  && [ -d \"\$SH/ws/kit\" ]"
```

The fakes do not answer `--version` with the pin, so the gates may FAIL here; this test checks only the report and the HOME confinement (exit code ignored by design, hence `;`). Use the real fake-bin variable name from the file.

- [ ] **Step 3: Run**

`bash -n scripts/smoke-kit.sh` → ok. `bash tests/run-tests.sh` → all pass.

- [ ] **Step 4: Real smoke on this host, throwaway HOME**

Run: `SMOKE_HOME=$(mktemp -d -p "$SCRATCH") bash scripts/smoke-kit.sh "$SCRATCH/smoke.md"` where `$SCRATCH` is the session scratchpad. Expected: every gate `ok`, trial search shows a thread count (≥1 from this host on the current pin). Paste the table into the task report. Do not delete the HOME without the operator's go; list its path in the report.

- [ ] **Step 5: Commit**

```bash
git add scripts/smoke-kit.sh tests/run-tests.sh
git commit -m "feat(versions): проверка набора чистой установкой во временный HOME

Каждая закреплённая программа: версия совпадает с пином и запускается.
Пробный поиск last30days только для информации, на ворота не влияет.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Weekly workflow `.github/workflows/versions.yml`

**Files:**
- Create: `.github/workflows/versions.yml`
- Modify: `tests/run-tests.sh` (YAML parse + structure check)
- Modify: `README.md` (one short paragraph about the robot)

**Interfaces:**
- Consumes: `scripts/bump-versions.py` (Task 2: `--report`, `--dry-run`, final `changed=` line), `scripts/smoke-kit.sh` (Task 3: `<REPORT_MD>`, exit 1 on a failed gate), `tests/run-tests.sh`.
- Produces: on schedule/dispatch with changes, a PR labeled `versions-bot` from `bot/versions-YYYY-MM-DD-<run_id>` to `main`. On `pull_request`, a dry run (no push, no PR) whose report goes to the job summary.

- [ ] **Step 1: Write the workflow**

```yaml
name: versions

on:
  schedule:
    - cron: '0 1 * * 1'  # Monday 09:00 Asia/Makassar
  workflow_dispatch:
  pull_request:
    paths:
      - 'kit/versions.env'
      - 'kit/install-kit.sh'
      - 'scripts/bump-versions.py'
      - 'scripts/smoke-kit.sh'
      - '.github/workflows/versions.yml'

permissions:
  contents: write
  pull-requests: write

concurrency:
  group: versions-${{ github.ref }}
  cancel-in-progress: false

jobs:
  bump:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    env:
      DRY_RUN: ${{ github.event_name == 'pull_request' && '1' || '0' }}
      GH_TOKEN: ${{ github.token }}
    steps:
      - uses: actions/checkout@v4

      # The runner context is not available in job-level env, so REPORT is set here.
      - name: Paths
        run: echo "REPORT=$RUNNER_TEMP/report.md" >> "$GITHUB_ENV"

      - uses: actions/setup-node@v4
        with:
          node-version: '22'

      - name: Tools
        run: |
          set -euo pipefail
          command -v pipx || { sudo apt-get update && sudo apt-get install -y pipx; }
          command -v jq
          python3 --version

      - name: Check versions
        id: check
        run: |
          set -euo pipefail
          args=(--report "$REPORT")
          [ "$DRY_RUN" = 1 ] && args+=(--dry-run)
          python3 scripts/bump-versions.py "${args[@]}" | tee "$RUNNER_TEMP/check.out"
          tail -n 1 "$RUNNER_TEMP/check.out" >> "$GITHUB_OUTPUT"

      - name: Tests
        id: tests
        if: steps.check.outputs.changed == 'true' || env.DRY_RUN == '1'
        continue-on-error: true
        run: bash tests/run-tests.sh

      - name: Real install and smoke
        id: smoke
        if: steps.check.outputs.changed == 'true' || env.DRY_RUN == '1'
        continue-on-error: true
        run: bash scripts/smoke-kit.sh "$REPORT"

      - name: Summary
        if: always()
        run: |
          {
            echo "## Versions"; cat "$REPORT" 2>/dev/null || echo "no report"
            echo; echo "tests: ${{ steps.tests.outcome }}, smoke: ${{ steps.smoke.outcome }}"
          } >> "$GITHUB_STEP_SUMMARY"

      - name: Open PR
        if: env.DRY_RUN == '0' && steps.check.outputs.changed == 'true'
        run: |
          set -euo pipefail
          ok=1
          [ "${{ steps.tests.outcome }}" = success ] || ok=0
          [ "${{ steps.smoke.outcome }}" = success ] || ok=0
          branch="bot/versions-$(date -u +%F)-${{ github.run_id }}"
          title="Обновление закреплённых версий $(date -u +%F)"
          [ "$ok" = 1 ] || title="[checks failed] $title"
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git switch -c "$branch"
          git add kit/versions.env
          git commit -m "$title"
          git push origin "$branch"
          body="$RUNNER_TEMP/body.md"
          {
            echo "Автоматическая проверка новых версий набора."
            echo
            cat "$REPORT"
            echo
            echo "Тесты: ${{ steps.tests.outcome }}. Установка и запуск: ${{ steps.smoke.outcome }}."
            echo "Лог: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"
            echo
            echo "Раннер проверяет установку и запуск, не качество. Перед мержем проверить"
            echo "на реальном сервере, особенно пробный поиск last30days."
          } > "$body"
          gh label create versions-bot --color BFD4F2 --force >/dev/null
          draft=(); [ "$ok" = 1 ] || draft=(--draft)
          url="$(gh pr create --base main --head "$branch" --title "$title" \
            --body-file "$body" --label versions-bot "${draft[@]}")"
          echo "opened $url"
          gh pr list --label versions-bot --state open --json number,url \
            --jq ".[] | select(.url != \"$url\") | .number" \
          | while read -r n; do
              gh pr close "$n" --comment "Заменён более свежей проверкой: $url"
            done
          [ "$ok" = 1 ] || { echo "checks failed, PR opened as draft"; exit 1; }

      - name: Fail dry run on failed checks
        if: env.DRY_RUN == '1' && (steps.tests.outcome == 'failure' || steps.smoke.outcome == 'failure')
        run: exit 1
```

`gh pr close` without `--delete-branch`: old bot branches stay (branch deletion needs the operator's go).

- [ ] **Step 2: Structure test in run-tests**

Add to section 2:

```bash
check "versions workflow parses and has the agreed shape" python3 - "$KIT/.github/workflows/versions.yml" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
on = w.get("on") or w.get(True)
assert on["schedule"][0]["cron"] == "0 1 * * 1"
assert "workflow_dispatch" in on and "pull_request" in on
assert w["permissions"] == {"contents": "write", "pull-requests": "write"}
text = open(sys.argv[1]).read()
assert "--force" not in text.replace("gh label create versions-bot --color BFD4F2 --force", "")
assert "--delete-branch" not in text
PY
```

If PyYAML is missing on a machine, the check must say so instead of failing silently: guard with `python3 -c 'import yaml'` and print `skip workflow shape (no PyYAML)` like the existing skips do. ubuntu-latest has PyYAML.

- [ ] **Step 3: README paragraph**

In the root `README.md`, in the section about the kit, add:

```markdown
Versions of third-party programs are pinned in `kit/versions.env`. Every Monday a GitHub
Actions job (`versions`) checks for newer releases; if there are any, it opens a PR with
the old→new table, changelog links, the test results and a clean install on the runner.
Check it on a real server before merging.
```

- [ ] **Step 4: Run tests and leak scan**

`bash tests/run-tests.sh` → all pass. `bash scripts/leak-scan.sh` → clean.

- [ ] **Step 5: Commit, push the feature branch, open the PR**

```bash
git add .github/workflows/versions.yml tests/run-tests.sh README.md
git commit -m "feat(versions): еженедельный робот обновления версий в GitHub Actions

По понедельникам и по кнопке: проверка версий, тесты, чистая установка на
раннере, PR с таблицей старая→новая. В PR этой ветки идёт пробный прогон
без коммита.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -u origin feature/version-bump-robot
```

Open the PR with `gh pr create` (body in Russian, ends with the Claude Code line). The `pull_request` trigger runs the dry run on the PR itself: wait for it (`gh pr checks --watch`), read the job summary. Expected: tests pass, every smoke gate `ok`, trial search informational. If `tests/run-tests.sh` fails on the runner for an environment reason (missing tool, root vs non-root, network), fix the test or the workflow's Tools step in this branch, not by skipping the step; report every such fix.

- [ ] **Step 6: Hand-off to the operator**

The schedule and manual button work only after merge to `main`, and the PR step needs the repo setting «Allow GitHub Actions to create and approve pull requests». Report both to the operator; do not change the setting without an explicit go.
