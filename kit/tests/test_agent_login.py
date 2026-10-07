"""Tests for kit/bin/agent-login."""

import contextlib
import http.server
import importlib.machinery
import importlib.util
import io
import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
import urllib.parse
import urllib.request
from pathlib import Path
from unittest import mock

KIT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader("agent_login", str(KIT / "bin" / "agent-login"))
spec = importlib.util.spec_from_loader("agent_login", loader)
al = importlib.util.module_from_spec(spec)
loader.exec_module(al)


def _serve_once(received: list[str], status: int = 200) -> http.server.HTTPServer:
    """Loopback server that answers one request, recording its path."""

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            received.append(self.path)
            self.send_response(status)
            self.end_headers()
            self.wfile.write(b"ok")

        def log_message(self, *args: object) -> None:
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    server.timeout = 10
    threading.Thread(target=server.handle_request, daemon=True).start()
    return server


class ParseRedirectTest(unittest.TestCase):
    def test_localhost_url(self) -> None:
        port, query = al.parse_redirect("http://localhost:43123/?state=s1&code=4/abc&scope=x")
        self.assertEqual(port, 43123)
        self.assertEqual(query, "state=s1&code=4/abc&scope=x")

    def test_loopback_ip_and_spaces(self) -> None:
        port, _ = al.parse_redirect("  http://127.0.0.1:5000/?code=c&state=s \n")
        self.assertEqual(port, 5000)

    def test_rejects_foreign_host(self) -> None:
        with self.assertRaises(ValueError):
            al.parse_redirect("http://evil.example:5000/?code=c")

    def test_rejects_url_without_code(self) -> None:
        with self.assertRaises(ValueError):
            al.parse_redirect("http://localhost:5000/?error=access_denied")

    def test_rejects_garbage_port(self) -> None:
        with self.assertRaises(ValueError):
            al.parse_redirect("http://localhost:notaport/?code=c")

    def test_extract_consent_url(self) -> None:
        text = "===\nGoogle OAuth Authorization Required\n\nhttps://accounts.google.com/o/oauth2/auth?x=1\n\n==="
        self.assertEqual(al.extract_consent_url(text), "https://accounts.google.com/o/oauth2/auth?x=1")

    def test_extract_consent_url_none(self) -> None:
        self.assertIsNone(al.extract_consent_url("Waiting for authorization..."))


class HandoffTest(unittest.TestCase):
    def test_pasted_url_reaches_local_listener(self) -> None:
        received: list[str] = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                received.append(self.path)
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"ok")

            def log_message(self, *args: object) -> None:
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.handle_request)
        thread.start()
        try:
            pasted = f"http://localhost:{server.server_port}/?state=s1&code=4/abc&scope=a%20b"
            al.hand_code_to_listener(*al.parse_redirect(pasted))
        finally:
            thread.join(5)
            server.server_close()
        self.assertEqual(received, ["/?state=s1&code=4/abc&scope=a%20b"])

    def test_unreachable_listener_raises_handoff_error(self) -> None:
        with self.assertRaises(al.HandoffError):
            al.hand_code_to_listener(1, "code=c")

    def test_handoff_goes_to_loopback_ip_even_if_localhost_was_pasted(self) -> None:
        urls: list[str] = []
        original = urllib.request.OpenerDirector.open

        def spy(opener: object, url: str, *args: object, **kwargs: object) -> object:
            urls.append(url)
            return original(opener, url, *args, **kwargs)

        with mock.patch.object(urllib.request.OpenerDirector, "open", spy):
            with self.assertRaises(al.HandoffError):
                al.hand_code_to_listener(*al.parse_redirect("http://localhost:1/?code=c"))
        self.assertEqual(urls, ["http://127.0.0.1:1/?code=c"])

    def test_handoff_ignores_proxy_environment(self) -> None:
        received: list[str] = []
        server = _serve_once(received)
        env = {"http_proxy": "http://127.0.0.1:9", "HTTP_PROXY": "http://127.0.0.1:9"}
        try:
            with mock.patch.dict(os.environ, env):
                al.hand_code_to_listener(server.server_port, "code=c")
        finally:
            server.server_close()
        self.assertEqual(received, ["/?code=c"])

    def test_handoff_does_not_follow_redirect(self) -> None:
        hits: list[str] = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                hits.append(self.path)
                self.send_response(302)
                self.send_header("Location", "/elsewhere")
                self.end_headers()

            def log_message(self, *args: object) -> None:
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            al.hand_code_to_listener(server.server_port, "code=c")
        finally:
            server.shutdown()
            server.server_close()
        self.assertEqual(hits, ["/?code=c"])

    def test_http_error_status_is_handoff_error(self) -> None:
        server = _serve_once([], status=500)
        try:
            with self.assertRaises(al.HandoffError):
                al.hand_code_to_listener(server.server_port, "code=c")
        finally:
            server.server_close()


class ParseRedirectStrictTest(unittest.TestCase):
    def test_rejects_port_above_65535(self) -> None:
        with self.assertRaises(ValueError):
            al.parse_redirect("http://localhost:70000/?code=c")

    def test_rejects_port_zero(self) -> None:
        with self.assertRaises(ValueError):
            al.parse_redirect("http://localhost:0/?code=c")

    def test_accepts_highest_port(self) -> None:
        self.assertEqual(al.parse_redirect("http://localhost:65535/?code=c")[0], 65535)

    def test_rejects_userinfo_trick(self) -> None:
        with self.assertRaises(ValueError):
            al.parse_redirect("http://localhost:80@evil.example:5000/?code=c")

    def test_rejects_wrong_port(self) -> None:
        with self.assertRaises(ValueError):
            al.parse_redirect("http://localhost:5000/?code=c", expected_port=5001)

    def test_accepts_expected_port(self) -> None:
        self.assertEqual(al.parse_redirect("http://localhost:5000/?code=c", 5000)[0], 5000)

    def test_rejects_wrong_state(self) -> None:
        with self.assertRaises(ValueError):
            al.parse_redirect("http://localhost:5000/?code=c&state=x", 5000, "y")

    def test_state_missing_in_paste_is_rejected_when_consent_url_had_one(self) -> None:
        with self.assertRaises(ValueError):
            al.parse_redirect("http://localhost:5000/?code=c", 5000, "y")

    def test_state_missing_is_fine_when_consent_url_had_none(self) -> None:
        self.assertEqual(al.parse_redirect("http://localhost:5000/?code=c", 5000, None)[0], 5000)

    def test_rejects_inner_whitespace_and_control_chars(self) -> None:
        for bad in ("http://localhost:5000/?code=a b", "http://localhost:5000/?code=a\nb",
                    "http://localhost:5000/?code=a\x00b"):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    al.parse_redirect(bad)

    def test_consent_params(self) -> None:
        url = ("https://accounts.google.com/o/oauth2/auth?state=S1&redirect_uri="
               + urllib.parse.quote("http://localhost:4444/", safe=""))
        self.assertEqual(al.consent_params(url), (4444, "S1"))
        self.assertEqual(al.consent_params("https://accounts.google.com/x"), (None, None))


class ReadConsentUrlTest(unittest.TestCase):
    @staticmethod
    def _proc(code: str) -> subprocess.Popen:
        return subprocess.Popen([sys.executable, "-u", "-c", code], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True)

    def test_waits_for_slow_url(self) -> None:
        proc = self._proc("import time; time.sleep(0.7); "
                          "print('https://accounts.google.com/o/oauth2/auth?x=1'); time.sleep(5)")
        try:
            url, _ = al.read_consent_url(proc, wait_s=10)
        finally:
            proc.kill()
        self.assertEqual(url, "https://accounts.google.com/o/oauth2/auth?x=1")

    def test_returns_early_when_process_exits_without_url(self) -> None:
        proc = self._proc("print('boom')")
        started = time.monotonic()
        url, text = al.read_consent_url(proc, wait_s=20)
        self.assertLess(time.monotonic() - started, 10)
        self.assertIsNone(url)
        self.assertIn("boom", text)


FAKE_GWS = """\
#!{python}
import http.server, os, pathlib, sys, urllib.parse
home = pathlib.Path(os.environ["HOME"])
args = sys.argv[1:]
if args[:2] == ["auth", "status"]:
    sys.exit(0 if (home / "token").exists() else 1)
if args[:2] == ["auth", "import-credentials"]:
    if "BADJSON" in args[2]:
        print("invalid client file", file=sys.stderr)
        sys.exit(2)
    (home / "imported").write_text(args[2])
    sys.exit(0)
if args == ["auth"]:
    (home / "env").write_text(
        os.environ.get("PYTHONUNBUFFERED", "") + "|" + os.environ.get("BROWSER", ""))
    got = []
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            got.append(self.path)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"done")
        def log_message(self, *a):
            pass
    srv = http.server.HTTPServer(("127.0.0.1", 0), H)
    srv.timeout = 25
    redirect = urllib.parse.quote("http://localhost:%d" % srv.server_port, safe="")
    # Buffered unless -u / PYTHONUNBUFFERED, like the real tool through a pipe.
    out = sys.stdout if os.environ.get("PYTHONUNBUFFERED") else open(os.devnull, "w")
    print("Waiting header", file=out, flush=True)
    print("https://accounts.google.com/o/oauth2/auth?response_type=code&redirect_uri="
          + redirect + "&state=ST1", file=out, flush=True)
    while not got:
        srv.handle_request()
        if srv.timeout and not got:
            sys.exit(3)
    (home / "token").write_text(got[0])
    sys.exit(0)
sys.exit(9)
"""


class LoginGoogleE2ETest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.home = root / "home"
        self.home.mkdir()
        bindir = root / "bin"
        bindir.mkdir()
        fake = bindir / "gws-cli"
        fake.write_text(FAKE_GWS.format(python=sys.executable))
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        self.secret = root / "client.json"
        self.secret.write_text("{}")
        env = {"HOME": str(self.home), "PATH": f"{bindir}{os.pathsep}{os.environ['PATH']}",
               "XDG_CONFIG_HOME": str(root / "xdg")}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        for name in ("PYTHONUNBUFFERED", "BROWSER"):
            os.environ.pop(name, None)
        patcher = mock.patch.object(al, "URL_WAIT_S", 15.0)
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = mock.patch.object(al, "FINISH_WAIT_S", 15.0)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.out = io.StringIO()

    def _pasted(self, *, port_shift: int = 0, state: str = "ST1") -> str:
        text = self.out.getvalue()
        line = next(x for x in text.splitlines() if x.startswith("https://accounts.google.com"))
        port, _ = al.consent_params(line)
        assert port is not None
        return f"http://localhost:{port + port_shift}/?state={state}&code=4/abc"

    def _run(self, answers: list[object], secret: str | None = None) -> int:
        queue = list(answers)

        def fake_input(prompt: str = "") -> str:
            item = queue.pop(0)
            return item() if callable(item) else item

        with contextlib.redirect_stdout(self.out), mock.patch("builtins.input", fake_input):
            return al.login_google(secret or str(self.secret))

    def test_full_flow(self) -> None:
        code = self._run([lambda: self._pasted()])
        self.assertEqual(code, 0)
        self.assertIn("Google: logged in.", self.out.getvalue())
        self.assertEqual((self.home / "token").read_text(), "/?state=ST1&code=4/abc")
        self.assertEqual((self.home / "imported").read_text(), str(self.secret))

    def test_gws_gets_unbuffered_and_no_browser_env(self) -> None:
        self._run([lambda: self._pasted()])
        self.assertEqual((self.home / "env").read_text(), "1|false")

    def test_wrong_port_then_right_one_retries(self) -> None:
        code = self._run([lambda: self._pasted(port_shift=1), lambda: self._pasted()])
        self.assertEqual(code, 0)
        self.assertIn("wrong port", self.out.getvalue())

    def test_wrong_state_then_right_one_retries(self) -> None:
        self._run([lambda: self._pasted(state="OTHER"), lambda: self._pasted()])
        self.assertIn("wrong state", self.out.getvalue())

    def test_failed_handoff_keeps_listener_alive(self) -> None:
        real = al.hand_code_to_listener
        calls: list[int] = []

        def flaky(port: int, query: str) -> None:
            calls.append(port)
            if len(calls) == 1:
                raise al.HandoffError("boom")
            real(port, query)

        with mock.patch.object(al, "hand_code_to_listener", flaky):
            code = self._run([lambda: self._pasted(), lambda: self._pasted()])
        self.assertEqual(code, 0)
        self.assertEqual(len(calls), 2)

    def test_gws_gone_after_failed_handoff_stops_with_message(self) -> None:
        procs: list[subprocess.Popen] = []
        real_popen = subprocess.Popen
        real_hand = al.hand_code_to_listener

        def spy_popen(*args: object, **kwargs: object) -> subprocess.Popen:
            proc = real_popen(*args, **kwargs)
            if args[0][1:] == ["auth"]:  # skip status / import-credentials runs
                procs.append(proc)
            return proc

        def hand_then_die(port: int, query: str) -> None:
            real_hand(port, "finish=1")  # fake gws-cli exits on any request
            procs[0].wait(timeout=10)
            raise al.HandoffError("listener gone")

        with mock.patch.object(subprocess, "Popen", spy_popen), \
                mock.patch.object(al, "hand_code_to_listener", hand_then_die):
            with self.assertRaises(SystemExit) as ctx:
                self._run([lambda: self._pasted()])
        self.assertIn("already stopped", str(ctx.exception))

    def test_quoted_secret_path_is_accepted(self) -> None:
        queue = [f'"{self.secret}"', lambda: self._pasted()]

        def fake_input(prompt: str = "") -> str:
            item = queue.pop(0)
            return item() if callable(item) else item

        with contextlib.redirect_stdout(self.out), mock.patch("builtins.input", fake_input):
            self.assertEqual(al.login_google(None), 0)
        self.assertEqual((self.home / "imported").read_text(), str(self.secret))

    def test_import_failure_is_short_message(self) -> None:
        bad = Path(self.tmp.name) / "BADJSON.json"
        bad.write_text("x")
        with self.assertRaises(SystemExit) as ctx:
            self._run([], secret=str(bad))
        self.assertIn("invalid client file", str(ctx.exception))

    def test_already_logged_in_short_circuits(self) -> None:
        (self.home / "token").write_text("t")
        self.assertEqual(self._run([]), 0)
        self.assertIn("already logged in", self.out.getvalue())
        self.assertFalse((self.home / "imported").exists())


SILENT_GWS = """\
#!{python}
import os, pathlib, sys, time
home = pathlib.Path(os.environ["HOME"])
if sys.argv[1:3] == ["auth", "status"]:
    sys.exit(1)
if sys.argv[1:3] == ["auth", "import-credentials"]:
    sys.exit(0)
(home / "gws.pid").write_text(str(os.getpid()))
time.sleep(60)
"""


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


class SigtermDuringUrlWaitTest(unittest.TestCase):
    def test_gws_cli_is_killed_when_agent_login_gets_sigterm(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "home").mkdir()
            (root / "bin").mkdir()
            fake = root / "bin" / "gws-cli"
            fake.write_text(SILENT_GWS.format(python=sys.executable))
            fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
            secret = root / "c.json"
            secret.write_text("{}")
            env = {**os.environ, "HOME": str(root / "home"),
                   "PATH": f"{root / 'bin'}{os.pathsep}{os.environ['PATH']}"}
            proc = subprocess.Popen([sys.executable, str(KIT / "bin" / "agent-login"), "google",
                                     "--client-secret", str(secret)], env=env,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            gws_pid = 0
            try:
                pid_file = root / "home" / "gws.pid"
                deadline = time.monotonic() + 10
                while not pid_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(pid_file.exists(), "fake gws-cli never started")
                time.sleep(0.2)
                gws_pid = int(pid_file.read_text())
                proc.terminate()
                proc.wait(timeout=10)
                deadline = time.monotonic() + 5
                while _pid_alive(gws_pid) and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertFalse(_pid_alive(gws_pid), "gws-cli survived SIGTERM")
            finally:
                if proc.poll() is None:
                    proc.kill()
                if gws_pid and _pid_alive(gws_pid):
                    os.kill(gws_pid, 9)


class SigtermHandlerRestoredTest(unittest.TestCase):
    def test_previous_handler_is_restored(self) -> None:
        import signal
        marker = lambda *a: None  # noqa: E731
        previous = signal.signal(signal.SIGTERM, marker)
        try:
            tests = LoginGoogleE2ETest("test_full_flow")
            tests.setUp()
            try:
                tests.test_full_flow()
            finally:
                tests.doCleanups()
            self.assertIs(signal.getsignal(signal.SIGTERM), marker)
        finally:
            signal.signal(signal.SIGTERM, previous)


class SmallBehaviourTest(unittest.TestCase):
    def test_status_timeout_counts_as_logged_out(self) -> None:
        with mock.patch("subprocess.run", side_effect=subprocess.TimeoutExpired("x", 1)):
            self.assertFalse(al.is_logged_in(["x"]))

    def test_status_uses_bounded_timeout(self) -> None:
        with mock.patch("subprocess.run") as run:
            run.return_value.returncode = 0
            self.assertTrue(al.is_logged_in(["x"]))
        self.assertEqual(run.call_args.kwargs["timeout"], al.STATUS_WAIT_S)

    def test_sigterm_handler_raises_system_exit(self) -> None:
        with self.assertRaises(SystemExit):
            al._on_sigterm(15, None)

    def test_vercel_via_npx_is_pinned(self) -> None:
        with mock.patch("shutil.which", side_effect=lambda t: None if t == "vercel" else f"/x/{t}"):
            with mock.patch("subprocess.run") as run:
                run.return_value.returncode = 0
                al.login_vercel()
        cmd = run.call_args.args[0]
        self.assertIn(f"vercel@{al.VERCEL_CLI_VERSION}", cmd)
        self.assertNotIn("vercel@latest", cmd)
        self.assertRegex(al.VERCEL_CLI_VERSION, r"^\d+\.\d+\.\d+$")

    def test_installed_vercel_wins(self) -> None:
        with mock.patch("shutil.which", side_effect=lambda t: f"/x/{t}"):
            with mock.patch("subprocess.run") as run:
                run.return_value.returncode = 0
                al.login_vercel()
        self.assertEqual(run.call_args.args[0], ["/x/vercel", "login"])

    def test_gh_hint_has_no_sudo_and_points_to_install_page(self) -> None:
        with mock.patch("shutil.which", return_value=None), \
                mock.patch.dict(os.environ, {"HOME": tempfile.mkdtemp()}):
            with self.assertRaises(SystemExit) as ctx:
                al.login_github()
        message = str(ctx.exception)
        self.assertNotIn("sudo", message)
        self.assertIn("https://github.com/cli/cli#installation", message)


class InputTest(unittest.TestCase):
    def test_eof_exits_cleanly(self) -> None:
        with mock.patch("builtins.input", side_effect=EOFError):
            with self.assertRaises(SystemExit):
                al.ask("x: ")

    def test_ctrl_c_exits_cleanly(self) -> None:
        with mock.patch("builtins.input", side_effect=KeyboardInterrupt):
            with self.assertRaises(SystemExit):
                al.ask("x: ")


class NeedTest(unittest.TestCase):
    def test_missing_tool_exits_with_hint(self) -> None:
        with mock.patch("shutil.which", return_value=None), \
                mock.patch.dict(os.environ, {"HOME": tempfile.mkdtemp()}):
            with self.assertRaises(SystemExit) as ctx:
                al.need("gws-cli", "Install it")
        self.assertIn("Install it", str(ctx.exception))

    def test_tool_in_local_bin_is_found_without_path(self) -> None:
        home = Path(tempfile.mkdtemp())
        (home / ".local" / "bin").mkdir(parents=True)
        fake = home / ".local" / "bin" / "gws-cli"
        fake.write_text("#!/bin/sh\nexit 0\n")
        fake.chmod(0o755)
        with mock.patch.dict(os.environ, {"HOME": str(home), "PATH": "/nonexistent"}):
            self.assertEqual(al.need("gws-cli", "Install it"), str(fake))

    def test_non_executable_in_local_bin_is_ignored(self) -> None:
        home = Path(tempfile.mkdtemp())
        (home / ".local" / "bin").mkdir(parents=True)
        (home / ".local" / "bin" / "gws-cli").write_text("x")
        with mock.patch.dict(os.environ, {"HOME": str(home), "PATH": "/nonexistent"}):
            with self.assertRaises(SystemExit):
                al.need("gws-cli", "Install it")

    def test_agent_login_binary_finds_gws_cli_only_in_local_bin(self) -> None:
        home = Path(tempfile.mkdtemp())
        (home / ".local" / "bin").mkdir(parents=True)
        fake = home / ".local" / "bin" / "gws-cli"
        fake.write_text("#!/bin/sh\n[ \"$1\" = auth ] && [ \"$2\" = status ] && exit 0\nexit 1\n")
        fake.chmod(0o755)
        env = {"HOME": str(home), "PATH": "/usr/bin:/bin"}
        res = subprocess.run([sys.executable, str(KIT / "bin" / "agent-login"), "google"],
                             capture_output=True, text=True, env=env, input="")
        self.assertIn("already logged in", res.stdout)


class StatusTest(unittest.TestCase):
    def test_vercel_status_uses_pinned_npx_when_no_binary(self) -> None:
        calls = []

        def fake_logged_in(cmd):
            calls.append(cmd)
            return True

        def fake_which(tool):
            return None if tool in ("vercel", "gws-cli", "gh") else f"/x/{tool}"

        with mock.patch("shutil.which", side_effect=fake_which), \
                mock.patch.dict(os.environ, {"HOME": tempfile.mkdtemp()}), \
                mock.patch.object(al, "is_logged_in", side_effect=fake_logged_in), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            al.show_status()
        self.assertIn(["/x/npx", "--yes", f"vercel@{al.VERCEL_CLI_VERSION}", "whoami"], calls)
        self.assertIn("vercel  logged in", out.getvalue())


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
            self.assertFalse((Path.cwd() / "pwned").exists())

    def test_real_file_has_pins(self) -> None:
        pins = al.read_pins(al.VERSIONS_FILE)
        for key in ("AGENT_BROWSER_VERSION", "VERCEL_CLI_VERSION", "GWS_CLI_VERSION",
                    "CRAWL4AI_VERSION", "LAST30DAYS_REPO", "LAST30DAYS_COMMIT"):
            self.assertTrue(pins.get(key), key)
        self.assertEqual(al.VERCEL_CLI_VERSION, pins["VERCEL_CLI_VERSION"])
        self.assertRegex(pins["LAST30DAYS_COMMIT"], r"^[0-9a-f]{40}$")


if __name__ == "__main__":
    unittest.main()
