"""Behaviour tests for kit skills: yt-transcript fallback, reminders path, descriptions."""
import os
import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

SKILLS = Path(__file__).resolve().parents[1] / "skills"
YT = SKILLS / "media" / "youtube-transcript" / "scripts" / "yt-transcript.sh"
REMINDERS = SKILLS / "system" / "quick-reminders" / "scripts" / "reminders.sh"
SECRET = "sk-test-SECRET-123"

# skill -> skills its "Not for ... use X" lines must point to.
DISAMBIGUATION = {
    "groq-voice": ["youtube-transcript"],
    "youtube-transcript": ["groq-voice"],
    "markdown-new": ["crawl4ai", "agent-browser"],
    "crawl4ai": ["agent-browser"],
    "agent-browser": ["markdown-new", "crawl4ai"],
    "perplexity-research": ["last30days"],
    "last30days": ["perplexity-research"],
    "learnings": ["agent-introspection"],
    "agent-introspection": ["learnings"],
    "skill-creator": ["skill-finder"],
    "skill-finder": ["skill-creator"],
}


def write_exe(path: Path, body: str) -> None:
    path.write_text("#!/usr/bin/env bash\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class YtTranscriptTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bin = Path(self.tmp.name) / "bin"
        self.bin.mkdir()
        self.argv_log = Path(self.tmp.name) / "curl.argv"
        # yt-dlp always fails (no subtitles written); curl logs argv and serves JSON.
        write_exe(self.bin / "yt-dlp", "exit 1\n")
        write_exe(
            self.bin / "curl",
            f'printf "%s\\n" "$@" > "{self.argv_log}"\n'
            'while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done\n'
            'printf \'{"transcript": "hello from api"}\' > "$out"\n',
        )

    def run_script(self, key: str | None) -> subprocess.CompletedProcess:
        env = {"PATH": f"{self.bin}:/usr/bin:/bin", "HOME": self.tmp.name}
        if key:
            env["TRANSCRIPT_API_KEY"] = key
        return subprocess.run(
            ["bash", str(YT), "https://youtu.be/abc", "en"],
            env=env, capture_output=True, text=True, timeout=30,
        )

    def test_api_fallback_used_and_key_not_in_argv(self) -> None:
        res = self.run_script(SECRET)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("hello from api", res.stdout)
        argv = self.argv_log.read_text()
        self.assertNotIn(SECRET, argv)
        self.assertIn("transcriptapi.com/api/v2/youtube/transcript", argv)
        self.assertIn("video_url=https://youtu.be/abc", argv)
        self.assertNotIn(SECRET, res.stdout + res.stderr)

    def test_no_key_gives_clear_error(self) -> None:
        res = self.run_script(None)
        self.assertEqual(res.returncode, 1)
        self.assertIn("no subtitles", res.stderr)
        self.assertIn("TRANSCRIPT_API_KEY", res.stderr)
        self.assertFalse(self.argv_log.exists())

    def test_api_failure_exits_nonzero(self) -> None:
        write_exe(self.bin / "curl", "exit 22\n")
        res = self.run_script(SECRET)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("transcriptapi request failed", res.stderr)
        self.assertNotIn(SECRET, res.stdout + res.stderr)


class RemindersPathTest(unittest.TestCase):
    def run_reminders(self, env_extra: dict, cwd: str) -> subprocess.CompletedProcess:
        env = {"PATH": "/usr/bin:/bin", "HOME": cwd, **env_extra}
        return subprocess.run(
            ["bash", str(REMINDERS), "add", "call dentist"],
            env=env, cwd=cwd, capture_output=True, text=True, timeout=30,
        )

    def test_store_under_agent_ws_core(self) -> None:
        with tempfile.TemporaryDirectory() as ws:
            res = self.run_reminders({"AGENT_WS": ws}, ws)
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertIn("call dentist", (Path(ws) / "core" / "reminders.md").read_text())

    def test_reminders_file_overrides(self) -> None:
        with tempfile.TemporaryDirectory() as ws:
            target = Path(ws) / "custom.md"
            self.run_reminders({"AGENT_WS": ws, "REMINDERS_FILE": str(target)}, ws)
            self.assertIn("call dentist", target.read_text())
            self.assertFalse((Path(ws) / "core").exists())

    def test_without_agent_ws_falls_back_to_project_dir(self) -> None:
        with tempfile.TemporaryDirectory() as ws:
            res = self.run_reminders({"CLAUDE_PROJECT_DIR": ws}, ws)
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertTrue((Path(ws) / ".claude" / "core" / "reminders.md").exists())


class DescriptionTest(unittest.TestCase):
    @staticmethod
    def description(skill: str) -> str:
        path = next(SKILLS.glob(f"*/{skill}/SKILL.md"))
        front = path.read_text().split("---")[1]
        match = re.search(r"^description:\s*(.*?)(?=^\S|\Z)", front, re.S | re.M)
        assert match, skill
        return " ".join(match.group(1).replace(">", "", 1).split())

    def test_every_disambiguation_line_points_to_its_target(self) -> None:
        for skill, targets in DISAMBIGUATION.items():
            desc = self.description(skill)
            for target in targets:
                pattern = (rf"not for [^.]*?(use|используй) (?:\w+ (?:or|/) )?{re.escape(target)}\b"
                           rf"|не для [^.]*?(use|используй) (?:\w+ (?:or|/) )?{re.escape(target)}\b")
                self.assertRegex(desc, re.compile(pattern, re.I), f"{skill} -> {target}")

    def test_learnings_description_is_fully_russian_in_disambiguation(self) -> None:
        desc = self.description("learnings")
        self.assertNotIn("Not for", desc)
        self.assertIn("Не для", desc)


if __name__ == "__main__":
    unittest.main()
