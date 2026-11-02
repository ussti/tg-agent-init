"""Tests for core/scripts/rotate-warm.sh: date-based rotation of warm/decisions.md."""

import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "rotate-warm.sh"
TODAY = "2026-11-01"  # cut-off is 2026-10-18: entries dated earlier rotate


def _md(text: str) -> str:
    return textwrap.dedent(text).lstrip("\n")


class RotateWarmTest(unittest.TestCase):
    def setUp(self) -> None:
        self.ws = Path(tempfile.mkdtemp(prefix="rotate-warm-test-"))
        self.addCleanup(shutil.rmtree, self.ws)
        (self.ws / "core" / "warm").mkdir(parents=True)
        self.decisions = self.ws / "core" / "warm" / "decisions.md"
        self.memory = self.ws / "core" / "MEMORY.md"
        self.archive = self.ws / "core" / "archive"

    def run_script(self) -> subprocess.CompletedProcess:
        env = dict(os.environ, AGENT_WS=str(self.ws), ROTATE_TODAY=TODAY)
        return subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True,
                              check=True)

    def test_template_style_entries_rotate_by_date(self) -> None:
        self.decisions.write_text(_md("""
            # WARM — Decisions (last ~14 days)

            _Key decisions._

            ### 2026-10-25 [fresh]
            Keep me.

            ### 2026-10-01 [stale]
            Move me.
            """))
        self.run_script()
        warm = self.decisions.read_text()
        self.assertIn("### 2026-10-25 [fresh]\nKeep me.", warm)
        self.assertNotIn("stale", warm)
        self.assertTrue(warm.startswith("# WARM — Decisions (last ~14 days)\n\n_Key decisions._"))
        self.assertIn("### 2026-10-01 [stale]\nMove me.", (self.archive / "2026-10.md").read_text())

    def test_entry_takes_its_subheadings_along(self) -> None:
        self.decisions.write_text(_md("""
            ## 2026-09-02 [old-topic]

            ### Rule
            Body one.

            ### Files
            - a.ts

            ---

            ## 2026-10-30 [new-topic]
            Body two.
            """))
        self.run_script()
        warm = self.decisions.read_text()
        self.assertNotIn("Body one", warm)
        self.assertNotIn("a.ts", warm)
        self.assertIn("## 2026-10-30 [new-topic]\nBody two.", warm)
        moved = (self.archive / "2026-09.md").read_text()
        self.assertIn("## 2026-09-02 [old-topic]", moved)
        self.assertIn("### Files\n- a.ts", moved)

    def test_order_in_file_does_not_matter(self) -> None:
        self.decisions.write_text(_md("""
            ## 2026-08-01 [oldest-first]
            A.

            ## 2026-10-31 [newest]
            B.

            # Trailing header
            _note_

            ## 2026-07-15 [old-at-bottom]
            C.
            """))
        self.run_script()
        warm = self.decisions.read_text()
        self.assertEqual(warm, _md("""
            ## 2026-10-31 [newest]
            B.

            # Trailing header
            _note_
            """))
        self.assertIn("[old-at-bottom]", (self.archive / "2026-07.md").read_text())
        self.assertIn("[oldest-first]", (self.archive / "2026-08.md").read_text())

    def test_memory_gets_one_index_line_per_entry(self) -> None:
        self.memory.write_text("# MEMORY\n\n- [Earlier](archive/2026-01.md) — kept\n")
        self.decisions.write_text(_md("""
            ### 2026-10-01 [stale-one]
            Decision about the payment flow.

            ### 2026-09-20 [stale-two]
            - first bullet

            ### 2026-10-29 [fresh]
            x
            """))
        self.run_script()
        lines = self.memory.read_text().splitlines()
        self.assertEqual(lines[:3], ["# MEMORY", "", "- [Earlier](archive/2026-01.md) — kept"])
        self.assertEqual(lines[3:], [
            "- [2026-09-20 stale-two](archive/2026-09.md) — first bullet",
            "- [2026-10-01 stale-one](archive/2026-10.md) — Decision about the payment flow.",
        ])

    def test_index_hook_is_plain_text(self) -> None:
        self.decisions.write_text(_md("""
            ## 2026-09-01 [with-subheading]
            ### Default delivery path
            Body.

            ## 2026-09-02 [bold-bullet]
            - **Expenses (11):** food, rent
            """))
        self.run_script()
        self.assertEqual(self.memory.read_text().splitlines()[-2:], [
            "- [2026-09-01 with-subheading](archive/2026-09.md) — Default delivery path",
            "- [2026-09-02 bold-bullet](archive/2026-09.md) — Expenses (11): food, rent",
        ])

    def test_cutoff_day_stays_and_undated_sections_stay(self) -> None:
        text = _md("""
            ## Conventions
            Undated, permanent.

            ### 2026-10-18 [edge]
            Exactly 14 days old.

            <!-- ### 2026-01-01 [template example] -->
            """)
        self.decisions.write_text(text)
        self.run_script()
        self.assertEqual(self.decisions.read_text(), text)
        self.assertFalse(self.archive.exists())

    def test_undated_heading_ends_the_entry_above_it(self) -> None:
        self.decisions.write_text(_md("""
            ### 2026-10-02 [stale]
            Gone.

            ## Conventions
            Stays.
            """))
        self.run_script()
        self.assertEqual(self.decisions.read_text(), "## Conventions\nStays.\n")

    def test_second_run_changes_nothing(self) -> None:
        self.decisions.write_text("### 2026-10-02 [stale]\nGone.\n\n### 2026-10-30 [fresh]\nx\n")
        self.run_script()
        snapshot = (self.decisions.read_text(), self.memory.read_text(),
                    (self.archive / "2026-10.md").read_text())
        self.run_script()
        self.assertEqual(snapshot, (self.decisions.read_text(), self.memory.read_text(),
                                    (self.archive / "2026-10.md").read_text()))

    def test_missing_decisions_is_a_noop(self) -> None:
        self.run_script()
        self.assertFalse(self.decisions.exists())
        self.assertFalse(self.archive.exists())


if __name__ == "__main__":
    unittest.main()
