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
SITE_LOGIN = SKILLS / "office" / "site-login" / "site-login"
SECRET = "sk-test-SECRET-123"

# skill -> skills its "Not for ... use X" lines must point to.
DISAMBIGUATION = {
    "groq-voice": ["youtube-transcript"],
    "youtube-transcript": ["groq-voice"],
    "markdown-new": ["crawl4ai", "agent-browser"],
    "crawl4ai": ["agent-browser"],
    "agent-browser": ["markdown-new", "crawl4ai", "site-login"],
    "site-login": ["agent-browser"],
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


class SiteLoginTest(unittest.TestCase):
    """site-login wraps agent-browser with a per-site profile and a desktop User-Agent."""

    COOKIES = (
        '{"success": true, "data": {"cookies": ['
        '{"domain": ".trip.com", "name": "cticket", "value": "SECRET-VALUE", "expires": 1799625600, "session": false},'
        '{"domain": ".trip.com", "name": "tmp", "value": "x", "expires": 1700000000, "session": false},'
        '{"domain": "www.trip.com", "name": "s", "value": "y", "expires": -1, "session": true}'
        ']}}'
    )

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.bin = root / "bin"
        self.bin.mkdir()
        self.argv_log = root / "ab.argv"
        self.profiles = root / ".local" / "share" / "agent-browser" / "profiles"
        self.browsers = root / ".agent-browser" / "browsers"
        for version in ("155.0.1.2", "158.0.8200.1", "99.0.0.0"):
            (self.browsers / f"chrome-{version}").mkdir(parents=True)
        write_exe(
            self.bin / "agent-browser",
            f'printf "%s\\n" "$@" > "{self.argv_log}"\n'
            f'case " $* " in *" cookies "*) echo \'{self.COOKIES}\' ;; esac\n',
        )

    def run_tool(self, *args: str) -> subprocess.CompletedProcess:
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin", "HOME": self.tmp.name,
            "SITE_LOGIN_PROFILES": "/", "XDG_DATA_HOME": "/",  # ignored: root stays under HOME
        }
        return subprocess.run(["bash", str(SITE_LOGIN), *args], env=env,
                              capture_output=True, text=True, timeout=30)

    def argv(self) -> list[str]:
        return self.argv_log.read_text().splitlines()

    def test_run_uses_site_profile_session_and_desktop_ua(self) -> None:
        res = self.run_tool("run", "tripcom", "open", "https://www.trip.com/")
        self.assertEqual(res.returncode, 0, res.stderr)
        argv = self.argv()
        profile = self.profiles / "tripcom"
        self.assertEqual(argv[argv.index("--session") + 1], "site-tripcom")
        self.assertEqual(argv[argv.index("--profile") + 1], str(profile))
        ua = argv[argv.index("--user-agent") + 1]
        self.assertIn("Chrome/158.0.0.0", ua)
        self.assertNotIn("Headless", ua)
        self.assertEqual(argv[-2:], ["open", "https://www.trip.com/"])
        self.assertEqual(stat.S_IMODE(profile.stat().st_mode), 0o700)

    def test_fallback_chrome_major_without_downloaded_chrome(self) -> None:
        for d in self.browsers.iterdir():
            d.rmdir()
        res = self.run_tool("run", "x", "snapshot")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertRegex(" ".join(self.argv()), r"Chrome/\d+\.0\.0\.0")

    def test_rejects_unsafe_site_names(self) -> None:
        for name in ("../etc", "Trip", "a b", ""):
            res = self.run_tool("run", name, "open", "x")
            self.assertNotEqual(res.returncode, 0, name)
        self.assertFalse(self.argv_log.exists())
        self.assertFalse(self.profiles.exists())

    def test_run_without_command_fails(self) -> None:
        self.assertNotEqual(self.run_tool("run", "tripcom").returncode, 0)

    def test_expiry_lists_login_cookies_without_values(self) -> None:
        (self.profiles / "tripcom").mkdir(parents=True)
        res = self.run_tool("expiry", "tripcom")
        self.assertEqual(res.returncode, 0, res.stderr)
        lines = res.stdout.strip().splitlines()
        self.assertIn("login-like cookies", lines[0])
        self.assertEqual(lines[1].split(), ["2027-01-11", "trip.com", "cticket"])
        self.assertEqual(len(lines), 2)  # "tmp" is not a login cookie, "s" is a session one
        self.assertNotIn("SECRET-VALUE", res.stdout + res.stderr)

    def test_expiry_falls_back_to_all_cookies(self) -> None:
        self.COOKIES = self.COOKIES.replace("cticket", "prefs")
        self.setUp()
        (self.profiles / "tripcom").mkdir(parents=True)
        res = self.run_tool("expiry", "tripcom")
        self.assertIn("no cookie looks like a login", res.stdout)
        self.assertIn("2027-01-11", res.stdout)

    def test_expiry_needs_a_profile(self) -> None:
        res = self.run_tool("expiry", "nosite")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("log in first", res.stderr)

    def test_list_and_forget(self) -> None:
        for site in ("tripcom", "ozon"):
            (self.profiles / site).mkdir(parents=True)
        self.assertEqual(self.run_tool("list").stdout.split(), ["ozon", "tripcom"])
        res = self.run_tool("forget", "ozon")
        self.assertNotEqual(res.returncode, 0)
        self.assertTrue((self.profiles / "ozon").exists())
        res = self.run_tool("forget", "ozon", "--yes")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertFalse((self.profiles / "ozon").exists())
        self.assertTrue((self.profiles / "tripcom").exists())
        self.assertIn("close", self.argv())

    def test_refuses_symlinked_profile(self) -> None:
        outside = Path(self.tmp.name) / "workspace"
        outside.mkdir()
        self.profiles.mkdir(parents=True)
        (self.profiles / "evil").symlink_to(outside)
        self.assertNotEqual(self.run_tool("run", "evil", "open", "x").returncode, 0)
        self.assertNotEqual(self.run_tool("forget", "evil", "--yes").returncode, 0)
        self.assertTrue(outside.exists())
        self.assertFalse(self.argv_log.exists())

    def test_forget_keeps_profile_when_browser_does_not_close(self) -> None:
        (self.profiles / "ozon").mkdir(parents=True)
        write_exe(self.bin / "agent-browser", "exit 1\n")
        res = self.run_tool("forget", "ozon", "--yes")
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("profile kept", res.stderr)
        self.assertTrue((self.profiles / "ozon").exists())

    def test_list_without_profiles_is_empty(self) -> None:
        res = self.run_tool("list")
        self.assertEqual((res.returncode, res.stdout), (0, ""))


if __name__ == "__main__":
    unittest.main()
