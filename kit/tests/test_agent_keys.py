"""Tests for kit/bin/agent-keys."""

import http.server
import importlib.machinery
import importlib.util
import os
import stat
import sys
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

KIT = Path(__file__).resolve().parents[1]


def load_module():
    """Load the extension-less agent-keys script as a module."""
    loader = importlib.machinery.SourceFileLoader("agent_keys", str(KIT / "bin" / "agent-keys"))
    spec = importlib.util.spec_from_loader("agent_keys", loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules["agent_keys"] = module  # dataclasses resolves string annotations via it
    loader.exec_module(module)
    return module


ak = load_module()


class Handler(http.server.BaseHTTPRequestHandler):
    """Answers by path: /cNNN gives code NNN (302 points at Handler.redirect_to),
    /boom gives 500, anything else 200 for a "good" key and 401 otherwise.
    Every request is recorded in Handler.seen."""

    seen: list = []
    redirect_to: str = ""

    def _answer(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        Handler.seen.append((self.path, dict(self.headers.items()), body))
        if self.path.startswith("/boom"):
            code = 500
        elif self.path[2:5].isdigit() and self.path.startswith("/c"):
            code = int(self.path[2:5])
        elif "good" in (self.headers.get("Authorization", "") + self.headers.get("x-api-key", "")):
            code = 200
        else:
            code = 401
        self.send_response(code)
        if code == 302:
            self.send_header("Location", Handler.redirect_to)
        self.send_header("Content-Length", "0")
        self.end_headers()

    do_GET = _answer
    do_POST = _answer

    def log_message(self, *args: object) -> None:
        return


class KeysFileTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp())
        self.path = self.dir / "keys.env"

    def test_save_creates_600_file(self) -> None:
        ak.save_key(self.path, "GROQ_API_KEY", "gsk_1")
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertEqual(ak.load_keys(self.path), {"GROQ_API_KEY": "gsk_1"})

    def test_replace_does_not_duplicate(self) -> None:
        ak.save_key(self.path, "GROQ_API_KEY", "a")
        ak.save_key(self.path, "CAL_API_KEY", "c")
        ak.save_key(self.path, "GROQ_API_KEY", "b")
        text = self.path.read_text()
        self.assertEqual(text.count("GROQ_API_KEY="), 1)
        self.assertEqual(ak.load_keys(self.path)["GROQ_API_KEY"], "b")

    def test_value_is_stripped(self) -> None:
        self.assertEqual(ak.clean_value("  gsk_1 \r\n"), "gsk_1")

    def test_save_rejects_unsafe_value_and_leaves_file_alone(self) -> None:
        ak.save_key(self.path, "GROQ_API_KEY", "gsk_1")
        before = self.path.read_text()
        for bad in ('a"b', "a$(touch pwned)b", "a`b`", "a\\b", "a b", "a'b", "a\nb"):
            with self.assertRaises(ValueError):
                ak.save_key(self.path, "CAL_API_KEY", bad)
        self.assertEqual(self.path.read_text(), before)

    def test_bad_name_rejected(self) -> None:
        for bad in ("lower", "A B", 'A"; touch x; "', "1A", ""):
            with self.assertRaises(ValueError):
                ak.save_key(self.path, bad, "v")

    def test_file_is_safe_to_source(self) -> None:
        value = "Ab0._:/+=-"  # every character a key may contain
        ak.save_key(self.path, "GROQ_API_KEY", value)
        ak.save_key(self.path, "CAL_API_KEY", "cal_1")
        out = subprocess.run(
            ["bash", "-c", f'set -eu; . "{self.path}"; printf %s "$GROQ_API_KEY|$CAL_API_KEY"'],
            capture_output=True, text=True, check=True, cwd=self.dir,
        ).stdout
        self.assertEqual(out, f"{value}|cal_1")

    def test_hand_edited_unsafe_line_is_dropped_not_kept(self) -> None:
        self.path.write_text('X_KEY="a$(touch pwned)"\nOK_KEY="fine"\n')
        ak.save_key(self.path, "GROQ_API_KEY", "g")
        self.assertNotIn("touch", self.path.read_text())
        self.assertEqual(ak.load_keys(self.path), {"OK_KEY": "fine", "GROQ_API_KEY": "g"})

    def test_shell_unsafe_value_rejected(self) -> None:
        for bad in ('a"b', "a$b", "a`b", "a\\b", "a b"):
            with self.assertRaises(ValueError):
                ak.clean_value(bad)


class ValidateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()

    def svc(self, path: str = "/check") -> "ak.Service":
        return ak.Service("t", "T_KEY", "test", "here", "GET", self.base + path, "bearer")

    def test_good_key_ok(self) -> None:
        self.assertEqual(ak.validate(self.svc(), "good"), "ok")

    def test_bad_key_invalid(self) -> None:
        self.assertEqual(ak.validate(self.svc(), "bad"), "invalid")

    def test_server_error_unverified(self) -> None:
        self.assertEqual(ak.validate(self.svc("/boom"), "good"), "unverified")

    def test_status_mapping(self) -> None:
        expected = {"/c401": "invalid", "/c403": "invalid", "/c402": "ok", "/c429": "ok",
                    "/c404": "ok", "/c400": "ok", "/c500": "unverified", "/c503": "unverified",
                    "/c200": "ok"}
        for path, status in expected.items():
            with self.subTest(path=path):
                self.assertEqual(ak.validate(self.svc(path), "good"), status)

    def test_brave_422_is_invalid_but_other_services_422_is_not(self) -> None:
        brave = next(s for s in ak.SERVICES if s.id == "brave")
        stub = ak.Service("brave", brave.env, "t", "here", "GET", self.base + "/c422",
                          brave.auth, reject=brave.reject)
        self.assertEqual(ak.validate(stub, "good"), "invalid")
        other = next(s for s in ak.SERVICES if s.id == "groq")
        stub = ak.Service("groq", other.env, "t", "here", "GET", self.base + "/c422",
                          other.auth, reject=other.reject)
        self.assertEqual(ak.validate(stub, "good"), "ok")

    def test_credit_and_limit_notes(self) -> None:
        status, note = ak.check(self.svc("/c402"), "good")
        self.assertEqual(status, "ok")
        self.assertIn("no credit", note)
        status, note = ak.check(self.svc("/c429"), "good")
        self.assertEqual(status, "ok")
        self.assertIn("rate limit", note)

    def test_redirect_not_followed_and_credentials_not_forwarded(self) -> None:
        other = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=other.serve_forever, daemon=True).start()
        try:
            Handler.redirect_to = f"http://127.0.0.1:{other.server_port}/landing"
            Handler.seen.clear()
            status, note = ak.check(self.svc("/c302"), "good")
            self.assertEqual(status, "unverified")
            self.assertIn("redirect", note)
            self.assertEqual([p for p, _, _ in Handler.seen], ["/c302"])
        finally:
            other.shutdown()

    def test_headers_and_body_reach_server(self) -> None:
        cases = (("bearer", "Authorization", "Bearer good"),
                 ("x-api-key", "x-api-key", "good"),
                 ("x-subscription-token", "X-Subscription-Token", "good"))
        for auth, header, want in cases:
            Handler.seen.clear()
            svc = ak.Service("t", "T_KEY", "test", "here", "GET", self.base + "/c200", auth)
            ak.validate(svc, "good")
            sent = {k.lower(): v for k, v in Handler.seen[0][1].items()}
            self.assertEqual(sent.get(header.lower()), want, auth)
        Handler.seen.clear()
        post = ak.Service("t", "T_KEY", "test", "here", "POST", self.base + "/c200", "bearer",
                          body='{"ping": 1}', extra=(("cal-api-version", "x"),))
        ak.validate(post, "good")
        _, headers, body = Handler.seen[0]
        self.assertEqual(body, '{"ping": 1}')
        lowered = {k.lower(): v for k, v in headers.items()}
        self.assertEqual(lowered.get("content-type"), "application/json")
        self.assertEqual(lowered.get("cal-api-version"), "x")

    def test_no_live_check_note(self) -> None:
        jina = next(s for s in ak.SERVICES if s.id == "jina")
        status, note = ak.check(jina, "good")
        self.assertEqual(status, "unverified")
        self.assertIn("no live check", note)

    def test_http_exception_unverified(self) -> None:
        import http.client
        from unittest import mock
        with mock.patch.object(ak.OPENER, "open", side_effect=http.client.BadStatusLine("x")):
            self.assertEqual(ak.validate(self.svc(), "good"), "unverified")

    def test_unreachable_unverified(self) -> None:
        dead = ak.Service("t", "T_KEY", "test", "here", "GET", "http://127.0.0.1:9/x", "bearer")
        self.assertEqual(ak.validate(dead, "good", timeout=1.0), "unverified")


class RestartHintTest(unittest.TestCase):
    def test_no_sudo_hint_anywhere_and_none_during_install(self) -> None:
        tmp = tempfile.mkdtemp()
        import io
        from unittest import mock
        for env, expect_hint in (({"SECRETS_DIR": tmp}, True),
                                 ({"AGENT_KEYS_FILE": tmp + "/keys.env"}, False)):
            with self.subTest(env=env), mock.patch.dict(os.environ, env), \
                    mock.patch.object(ak.getpass, "getpass", return_value=""), \
                    mock.patch("sys.stdout", new_callable=io.StringIO) as out:
                os.environ.pop("AGENT_KEYS_FILE" if "SECRETS_DIR" in env else "SECRETS_DIR", None)
                ak.main(["add", "jina"])
            text = out.getvalue()
            self.assertNotIn("sudo", text)
            self.assertEqual("Restart the agent" in text, expect_hint)


class ListTest(unittest.TestCase):
    def test_list_never_prints_values(self) -> None:
        path = Path(tempfile.mkdtemp()) / "keys.env"
        ak.save_key(path, "GROQ_API_KEY", "gsk_secret_value")
        out = ak.render_list(path)
        self.assertIn("groq", out)
        self.assertNotIn("gsk_secret_value", out)


if __name__ == "__main__":
    unittest.main()
