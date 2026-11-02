"""Tests for core/scripts/memory-rotate.sh: MEMORY.md keeps its index, prose goes to archive/."""

import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "memory-rotate.sh"
TODAY = "2026-11-01"
HEADER = textwrap.dedent("""\
    # MEMORY — Cold Archive Index

    _Canonical topic index. One line per archived topic; full content lives in `archive/`._

    """)
PAD = "x" * 5200  # pushes a section's body past the 5KB threshold


def index_lines(n: int) -> str:
    return "".join(f"- [2026-09-{i % 28 + 1:02d} [topic-{i}]](archive/2026-09.md) — hook "
                   f"number {i} with some canonical keywords for recall\n" for i in range(n))


class MemoryRotateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.ws = Path(tempfile.mkdtemp(prefix="memory-rotate-test-"))
        self.addCleanup(shutil.rmtree, self.ws)
        (self.ws / "core").mkdir()
        self.memory = self.ws / "core" / "MEMORY.md"
        self.archive = self.ws / "core" / "archive"

    def run_script(self) -> subprocess.CompletedProcess:
        env = dict(os.environ, AGENT_WS=str(self.ws), ROTATE_TODAY=TODAY)
        return subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True,
                              check=True)

    def test_big_index_is_never_archived(self) -> None:
        text = HEADER + index_lines(60)
        self.assertGreater(len(text.encode()), 5120)
        self.memory.write_text(text)
        self.run_script()
        self.assertEqual(self.memory.read_text(), text)
        self.assertFalse(self.archive.exists() and any(self.archive.iterdir()))

    def test_legacy_section_moves_and_leaves_an_index_line(self) -> None:
        self.memory.write_text(HEADER + index_lines(2) + textwrap.dedent(f"""
            ---
            (rotated from decisions.md)
            ## 2026-08-14 [old-decision]

            ### Rule
            **Keep** answers short.
            {PAD}
            """))
        self.run_script()
        mem = self.memory.read_text()
        self.assertTrue(mem.startswith(HEADER + index_lines(2)))
        self.assertIn("- [2026-08-14 old-decision](archive/2026-08.md) — Rule\n", mem)
        self.assertNotIn("rotated from", mem)
        self.assertNotIn(PAD, mem)
        self.assertNotIn("\n---\n", mem)
        moved = (self.archive / "2026-08.md").read_text()
        self.assertIn("## 2026-08-14 [old-decision]\n\n### Rule\n**Keep** answers short.", moved)
        self.assertIn(PAD, moved)

    def test_undated_section_goes_to_this_month(self) -> None:
        self.memory.write_text(HEADER + f"## Server notes\nThe box runs Ubuntu.\n{PAD}\n")
        self.run_script()
        self.assertEqual(self.memory.read_text(),
                         HEADER + "- [Server notes](archive/2026-11.md) — The box runs Ubuntu.\n")
        self.assertIn("## Server notes\nThe box runs Ubuntu.",
                      (self.archive / "2026-11.md").read_text())

    def test_sections_keep_their_place_among_index_lines(self) -> None:
        self.memory.write_text(HEADER + "- [A](archive/2026-01.md) — a\n"
                               + f"## 2026-02-01 B\nbee {PAD}\n"
                               + "- [C](archive/2026-03.md) — c\n")
        self.run_script()
        mem = self.memory.read_text()
        self.assertEqual(mem, HEADER + "- [A](archive/2026-01.md) — a\n"
                         "- [2026-02-01 B](archive/2026-02.md) — " + ("bee " + PAD)[:99] + "…\n"
                         "- [C](archive/2026-03.md) — c\n")

    def test_small_file_is_untouched(self) -> None:
        text = HEADER + "## Notes\nshort\n"
        self.memory.write_text(text)
        self.run_script()
        self.assertEqual(self.memory.read_text(), text)

    def test_missing_memory_is_fine(self) -> None:
        self.run_script()
        self.assertFalse(self.memory.exists())


if __name__ == "__main__":
    unittest.main()
