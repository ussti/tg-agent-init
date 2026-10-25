"""Tests for kit/bin/agent-selfcheck: fake tools on PATH, no network, no key values."""

import contextlib
import dataclasses
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import stat
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

KIT = Path(__file__).resolve().parents[1]
REPO = KIT.parent
loader = importlib.machinery.SourceFileLoader("agent_selfcheck",
                                              str(KIT / "bin" / "agent-selfcheck"))
spec = importlib.util.spec_from_loader("agent_selfcheck", loader)
sc = importlib.util.module_from_spec(spec)
sys.modules["agent_selfcheck"] = sc  # dataclasses resolves string annotations via it
loader.exec_module(sc)

# Real system tools the skill scripts call; everything else on PATH is a fake.
SYSTEM_TOOLS = ("bash", "node", "env", "mkdir", "dirname", "date", "grep", "sed", "rm", "cat")
SECRET = "gsk_selfcheck_secret_value_123"
UNREACHABLE = "http://127.0.0.1:9/"
PLUGINS_JSON = {"version": 2, "plugins": {p: [{"scope": "user"}] for p in sc.PLUGINS}}


def _write_exe(path: Path, body: str) -> None:
    path.write_text("#!/usr/bin/env bash\n" + textwrap.dedent(body))
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class SelfcheckTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="selfcheck-test-"))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.ws = self.tmp / "ws"
        self.config = self.tmp / "config"
        self.fake = self.tmp / "fakebin"
        self.sys = self.tmp / "sysbin"
        for d in (self.fake, self.sys, self.config / "plugins", self.ws / "scripts"):
            d.mkdir(parents=True)
        for tool in SYSTEM_TOOLS:
            found = shutil.which(tool)
            if found:
                (self.sys / tool).symlink_to(found)
        shutil.copytree(KIT / "skills", self.ws / "kit" / "skills", symlinks=True)
        shutil.copy(KIT / "manifest.tsv", self.ws / "kit" / "manifest.tsv")
        (self.ws / "skills").mkdir()
        for line in (KIT / "manifest.tsv").read_text().splitlines():
            parts = line.split("\t")
            if len(parts) >= 3 and not parts[0].startswith("#"):
                (self.ws / "skills" / parts[1]).symlink_to(
                    f"../kit/skills/{parts[0]}/{parts[1]}")
        shutil.copy(REPO / "core" / "scripts" / "learnings-engine.mjs", self.ws / "scripts")
        (self.config / "plugins" / "installed_plugins.json").write_text(
            json.dumps(PLUGINS_JSON))
        self.keys = self.tmp / "keys.env"
        self.keys.write_text("")
        env = {"AGENT_WS": str(self.ws), "CLAUDE_CONFIG_DIR": str(self.config),
               "AGENT_KEYS_FILE": str(self.keys), "HOME": str(self.tmp),
               "PATH": f"{self.fake}{os.pathsep}{self.sys}", "SELFCHECK_TIMEOUT": "20"}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)

    def _install_fakes(self, browser_rc: int = 0) -> None:
        _write_exe(self.fake / "agent-browser", f"""\
            case "$3" in open) exit {browser_rc} ;; eval) echo '"Example"' ;; esac
            exit 0
            """)
        _write_exe(self.fake / "crwl", "echo '# Example page'\n")
        _write_exe(self.fake / "yt-dlp", "echo 'Some title'\n")
        _write_exe(self.fake / "gws-cli", "exit 0\n")
        _write_exe(self.fake / "curl", "echo '# page as markdown'\n")

    def _run(self, *args: str) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = sc.main(list(args))
        return code, out.getvalue()

    def _by_name(self) -> dict[str, dict[str, str]]:
        code, out = self._run("--json")
        self.last_code = code
        return {f'{row["group"]}/{row["name"]}': row for row in json.loads(out)}

    def test_everything_installed_works_and_no_keys_are_not_connected(self) -> None:
        self._install_fakes()
        rows = self._by_name()
        self.assertEqual(self.last_code, 0)
        for name in ("tools/agent-browser", "tools/crawl4ai", "tools/markdown-new",
                     "tools/youtube-transcript (yt-dlp)", "tools/gws (Google)",
                     "skills/superpowers", "skills/vercel", "skills/skill-creator",
                     "skills/quick-reminders", "skills/learnings",
                     "skills/quick-reminders round-trip", "skills/learnings round-trip"):
            self.assertEqual(rows[name]["status"], sc.WORKS, (name, rows[name]))
        for key in ("groq", "perplexity", "cal", "brave", "scrapecreators", "jina"):
            self.assertEqual(rows[f"keys/{key}"]["status"], sc.NOT_CONNECTED)
            self.assertEqual(rows[f"keys/{key}"]["fix"], f"agent-keys add {key}")
        # last30days is the stub here: the upstream download is a setup step, not a failure
        self.assertEqual(rows["skills/last30days"]["status"], sc.NOT_CONNECTED)

    def test_missing_tools_and_logout_are_not_connected_with_fix(self) -> None:
        _write_exe(self.fake / "gws-cli", "exit 1\n")
        rows = self._by_name()
        self.assertEqual(rows["tools/agent-browser"]["status"], sc.NOT_CONNECTED)
        self.assertEqual(rows["tools/crawl4ai"]["fix"], sc.FIX_UPDATE)
        self.assertEqual(rows["tools/gws (Google)"]["status"], sc.NOT_CONNECTED)
        self.assertEqual(rows["tools/gws (Google)"]["fix"], "agent-login google")

    def test_failing_call_is_broken_and_exit_1(self) -> None:
        self._install_fakes(browser_rc=3)
        rows = self._by_name()
        self.assertEqual(rows["tools/agent-browser"]["status"], sc.BROKEN)
        self.assertIn("exit 3", rows["tools/agent-browser"]["why"])
        self.assertEqual(self.last_code, 1)

    def test_plugin_switched_off_and_missing(self) -> None:
        self._install_fakes()
        (self.config / "settings.json").write_text(json.dumps(
            {"enabledPlugins": {"vercel@claude-plugins-official": False}}))
        (self.config / "plugins" / "installed_plugins.json").write_text(json.dumps(
            {"version": 2, "plugins": {"vercel@claude-plugins-official": [{}]}}))
        rows = self._by_name()
        self.assertEqual(rows["skills/vercel"]["status"], sc.BROKEN)
        self.assertIn("claude plugin enable", rows["skills/vercel"]["fix"])
        self.assertEqual(rows["skills/superpowers"]["status"], sc.NOT_CONNECTED)

    def test_missing_skill_link_is_broken(self) -> None:
        self._install_fakes()
        (self.ws / "skills" / "cal").unlink()
        rows = self._by_name()
        self.assertEqual(rows["skills/cal"]["status"], sc.BROKEN)

    def test_round_trips_leave_no_files_behind(self) -> None:
        self._install_fakes()
        before = set(Path(tempfile.gettempdir()).glob("selfcheck-*"))
        rows = self._by_name()
        self.assertEqual(rows["skills/quick-reminders round-trip"]["status"], sc.WORKS)
        self.assertEqual(rows["skills/learnings round-trip"]["status"], sc.WORKS)
        self.assertEqual(set(Path(tempfile.gettempdir()).glob("selfcheck-*")) - before, set())
        self.assertFalse((self.ws / "core" / "reminders.md").exists())
        self.assertFalse((self.ws / "core" / "LEARNINGS.md").exists())

    def test_saved_key_value_never_printed(self) -> None:
        self._install_fakes()
        self.keys.write_text(f'GROQ_API_KEY="{SECRET}"\n')
        ak = sc.load_agent_keys()
        # discard port: the live check fails fast, offline, as "unverified"
        ak.SERVICES = tuple(dataclasses.replace(s, check_url=UNREACHABLE) if s.method else s
                            for s in ak.SERVICES)
        with mock.patch.object(sc, "load_agent_keys", return_value=ak):
            code, table = self._run()
            _, as_json = self._run("--json")
        self.assertEqual(code, 0)
        self.assertNotIn(SECRET, table + as_json)
        groq = next(r for r in json.loads(as_json) if r["name"] == "groq")
        self.assertEqual(groq["status"], sc.UNCHECKED)

    def test_no_secrets_dir_means_keys_not_connected(self) -> None:
        self._install_fakes()
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("AGENT_KEYS_FILE")
            os.environ.pop("SECRETS_DIR", None)
            rows = self._by_name()
        self.assertEqual(rows["keys/groq"]["status"], sc.NOT_CONNECTED)

    def _key_rows(self, statuses: dict[str, str]) -> list:
        """agent-keys results with the given statuses; other services not connected."""
        ak = sc.load_agent_keys()
        return [ak.KeyStatus(s.id, s.env, statuses.get(s.id, "not connected"), "", "")
                for s in ak.SERVICES]

    def test_key_saved_after_session_start_needs_restart(self) -> None:
        self._install_fakes()
        self.keys.write_text(f'GROQ_API_KEY="{SECRET}"\n')
        ak = sc.load_agent_keys()
        os.environ.pop("GROQ_API_KEY", None)
        with mock.patch.object(ak, "check_all", return_value=self._key_rows({"groq": "ok"})), \
                mock.patch.object(sc, "load_agent_keys", return_value=ak):
            rows = self._by_name()
            os.environ["GROQ_API_KEY"] = SECRET
            loaded = self._by_name()
        self.assertEqual(rows["keys/groq"]["status"], sc.UNCHECKED)
        self.assertEqual(rows["keys/groq"]["fix"], sc.FIX_RESTART)
        self.assertEqual(loaded["keys/groq"]["status"], sc.WORKS)

    def test_blocked_youtube_is_not_broken_with_transcriptapi(self) -> None:
        self._install_fakes()
        _write_exe(self.fake / "yt-dlp", "echo 'ERROR: Sign in to confirm' >&2; exit 1\n")
        with mock.patch.object(sc, "check_keys", return_value=[
                sc.Check("keys", "transcriptapi", sc.WORKS)]):
            rows = self._by_name()
        self.assertEqual(rows["tools/" + sc.YT_NAME]["status"], sc.UNCHECKED)
        self.assertEqual(self.last_code, 0)
        rows = self._by_name()
        self.assertEqual(rows["tools/" + sc.YT_NAME]["status"], sc.BROKEN)

    def test_unreadable_keys_file_is_one_broken_row(self) -> None:
        self._install_fakes()
        ak = sc.load_agent_keys()
        with mock.patch.object(ak, "load_keys", side_effect=PermissionError(13, "denied")), \
                mock.patch.object(sc, "load_agent_keys", return_value=ak):
            rows = self._by_name()
        self.assertEqual(rows["keys/keys.env"]["status"], sc.BROKEN)
        self.assertEqual(self.last_code, 1)


if __name__ == "__main__":
    unittest.main()
