"""Tests for kit/bin/agent-login."""

import http.server
import importlib.machinery
import importlib.util
import threading
import unittest
from pathlib import Path
from unittest import mock

KIT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader("agent_login", str(KIT / "bin" / "agent-login"))
spec = importlib.util.spec_from_loader("agent_login", loader)
al = importlib.util.module_from_spec(spec)
loader.exec_module(al)


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

    def test_unreachable_listener_exits(self) -> None:
        with self.assertRaises(SystemExit):
            al.hand_code_to_listener(1, "code=c")


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
        with mock.patch("shutil.which", return_value=None):
            with self.assertRaises(SystemExit) as ctx:
                al.need("gws-cli", "Install it")
        self.assertIn("Install it", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
