"""Unit tests for scripts/migrate-ws-settings.py (workspace settings.json migration)."""

import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

KIT = Path(__file__).resolve().parent.parent.parent
SCRIPT = KIT / "scripts" / "migrate-ws-settings.py"
TEMPLATE = KIT / "core" / "templates" / "settings.json.template"
CROSS = "cross-surface.mjs"


def old_template() -> dict:
    """The workspace template as it was before the cross-surface hooks."""
    data = json.loads(TEMPLATE.read_text(encoding="utf-8"))
    for group in data["hooks"]["Stop"]:
        for hook in group["hooks"]:
            if CROSS in hook["command"]:
                hook["command"] = "$CLAUDE_PROJECT_DIR/.claude/hooks/write-handoff.sh"
    for group in data["hooks"]["UserPromptSubmit"]:
        group["hooks"] = [h for h in group["hooks"] if CROSS not in h["command"]]
    return data


def commands(data: dict, event: str) -> list[str]:
    """Every hook command of an event."""
    return [h["command"] for g in data["hooks"].get(event, []) for h in g["hooks"]]


class MigrateTest(unittest.TestCase):
    """Behaviour of the migration on the files an owner may have."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "settings.json"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_migrate(self, data: object) -> subprocess.CompletedProcess:
        text = data if isinstance(data, str) else json.dumps(data, indent=2)
        self.path.write_text(text, encoding="utf-8")
        return subprocess.run([sys.executable, str(SCRIPT), str(self.path)],
                              capture_output=True, text=True, check=False)

    def load(self) -> dict:
        return json.loads(self.path.read_text(encoding="utf-8"))

    def test_old_template_gets_both_hooks(self) -> None:
        res = self.run_migrate(old_template())
        self.assertEqual((res.returncode, res.stdout.strip()), (0, "changed"))
        data = self.load()
        stop = [c for c in commands(data, "Stop") if CROSS in c]
        self.assertEqual(len(stop), 1)
        self.assertLess(stop[0].index(f"{CROSS} stop"), stop[0].index("write-handoff.sh"))
        self.assertEqual(sum("write-handoff.sh" in c for c in commands(data, "Stop")), 1)
        self.assertIn("node $CLAUDE_PROJECT_DIR/.claude/hooks/cross-surface.mjs prompt --self "
                      "claude-code", commands(data, "UserPromptSubmit"))

    def test_old_template_migrates_to_the_current_template(self) -> None:
        self.run_migrate(old_template())
        self.assertEqual(self.load(), json.loads(TEMPLATE.read_text(encoding="utf-8")))

    def test_second_run_unchanged(self) -> None:
        self.run_migrate(old_template())
        before = self.path.read_text(encoding="utf-8")
        res = subprocess.run([sys.executable, str(SCRIPT), str(self.path)],
                             capture_output=True, text=True, check=False)
        self.assertEqual(res.stdout.strip(), "unchanged")
        self.assertEqual(self.path.read_text(encoding="utf-8"), before)

    def test_current_template_unchanged(self) -> None:
        res = self.run_migrate(TEMPLATE.read_text(encoding="utf-8"))
        self.assertEqual(res.stdout.strip(), "unchanged")

    def test_keeps_custom_keys(self) -> None:
        data = old_template()
        data["env"]["MY_VAR"] = "1"
        data["permissions"]["allow"] = ["Bash(ls *)"]
        data["hooks"]["Stop"][0]["hooks"].append({"type": "command", "command": "my-stop.sh"})
        data["hooks"]["PostToolUse"].append({"matcher": "Write", "hooks": [
            {"type": "command", "command": "my-post.sh"}]})
        expected = copy.deepcopy(data)
        self.run_migrate(data)
        got = self.load()
        self.assertEqual(got["env"]["MY_VAR"], "1")
        self.assertEqual(got["permissions"]["allow"], ["Bash(ls *)"])
        self.assertIn("my-stop.sh", commands(got, "Stop"))
        self.assertEqual(got["hooks"]["PostToolUse"], expected["hooks"]["PostToolUse"])

    def test_without_write_handoff_gets_a_new_stop_group(self) -> None:
        data = {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "mine.sh"}]}]}}
        self.run_migrate(data)
        got = self.load()
        self.assertEqual(len(got["hooks"]["Stop"]), 2)
        self.assertIn("mine.sh", commands(got, "Stop"))
        self.assertTrue(any(CROSS in c for c in commands(got, "Stop")))
        self.assertTrue(any(CROSS in c for c in commands(got, "UserPromptSubmit")))

    def test_keeps_owner_additions_to_the_handoff_command(self) -> None:
        data = old_template()
        data["hooks"]["Stop"][0]["hooks"][0]["command"] += " && notify.sh"
        self.run_migrate(data)
        stop = [c for c in commands(self.load(), "Stop") if CROSS in c]
        self.assertEqual(len(stop), 1)
        self.assertTrue(stop[0].endswith("write-handoff.sh && notify.sh"), stop[0])

    def test_odd_layout_exit_1_file_untouched(self) -> None:
        for bad in ({"hooks": {"Stop": "oops"}},
                    {"hooks": {"Stop": [{"hooks": [{"command": "write-handoff.sh",
                                                    "timeout": "10s"}]}]}}):
            res = self.run_migrate(bad)
            self.assertEqual(res.returncode, 1, bad)
            self.assertEqual(json.loads(self.path.read_text(encoding="utf-8")), bad)
            self.assertNotIn("Traceback", res.stderr)

    def test_bad_json_exit_1_file_untouched(self) -> None:
        res = self.run_migrate("{ not json")
        self.assertEqual(res.returncode, 1)
        self.assertEqual(self.path.read_text(encoding="utf-8"), "{ not json")

    def test_keeps_file_mode(self) -> None:
        self.path.write_text(json.dumps(old_template()), encoding="utf-8")
        self.path.chmod(0o640)
        subprocess.run([sys.executable, str(SCRIPT), str(self.path)], check=True,
                       capture_output=True)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o640)


if __name__ == "__main__":
    unittest.main()
