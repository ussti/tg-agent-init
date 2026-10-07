"""Unit tests for scripts/bump-versions.py; no network (fetch and git are injected)."""

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "bump-versions.py"
_spec = importlib.util.spec_from_file_location("bump_versions", SCRIPT)
bv = importlib.util.module_from_spec(_spec)
sys.modules["bump_versions"] = bv  # dataclasses look the module up
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


    def run_dashi(self, pin_text: str | None, tags: dict[str, str]):
        dashi = Path(self.tmp.name) / "UPSTREAM_COMMIT"
        if pin_text is not None:
            dashi.write_text(pin_text)
        git = FakeGit({"v3.9.4": OLD})  # last30days stays on its pin
        git.latest_tag = lambda repo: bv.pick_latest_tag(  # type: ignore[method-assign]
            tags if repo == bv.DASHI_REPO else {"v3.9.4": OLD})
        return bv.check_all(self.path, fake_fetch(registry()), git, dashi_pin=dashi)

    def test_dashi_newer_tag_is_report_only_and_changes_nothing(self) -> None:
        rows, changed = self.run_dashi(f"{OLD}\n", {"v1.3.0": OLD, "v1.4.0": NEW})
        self.assertFalse(changed)
        row = next(r for r in rows if r.item == "Dashi plugin")
        self.assertEqual(row.status, "report only")
        self.assertIn("v1.4.0", row.latest)
        self.assertIn(f"compare/{OLD[:12]}...v1.4.0", row.changes)
        self.assertIn("update-vendor.sh v1.4.0", row.changes)

    def test_dashi_on_newest_tag_is_up_to_date(self) -> None:
        rows, _ = self.run_dashi(f"{NEW}\n", {"v1.3.0": OLD, "v1.4.0": NEW})
        row = next(r for r in rows if r.item == "Dashi plugin")
        self.assertEqual(row.status, "up to date")

    def test_dashi_missing_pin_is_an_error_row(self) -> None:
        rows, changed = self.run_dashi(None, {"v1.4.0": NEW})
        self.assertFalse(changed)
        row = next(r for r in rows if r.item == "Dashi plugin")
        self.assertTrue(row.status.startswith("error"))

    def test_without_dashi_pin_there_is_no_dashi_row(self) -> None:
        rows, _ = self.run_check(registry(), FakeGit({"v3.9.4": OLD}))
        self.assertNotIn("Dashi plugin", {r.item for r in rows})

if __name__ == "__main__":
    unittest.main()
