"""Fixtures for Peel's Claude hook emitter and setup helper.

Temporary directories and a local test socket only; real ~/.claude settings,
Claude, transcripts and the Peel runtime are never touched.
Run: python3 -I -m unittest discover -s Tools/PeelAgentHooks -p 'test_*.py'
"""
import json
import os
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
EMITTER = os.path.join(HERE, "claude_hook.py")
SETUP = os.path.join(HERE, "setup_claude_hooks.py")
sys.path.insert(0, HERE)
import claude_hook  # noqa: E402
import setup_claude_hooks  # noqa: E402

SECRET_PAYLOAD = {
    "hook_event_name": "PreToolUse", "session_id": "abc-123", "tool_name": "Bash", "tool_use_id": "toolu_1",
    "cwd": "/Users/x/Project", "transcript_path": "/Users/x/.claude/projects/p/t.jsonl",
    "prompt": "SECRET PROMPT", "message": "SECRET MESSAGE", "tool_input": {"command": "cat ~/.ssh/id_rsa"},
    "tool_response": {"output": "SECRET OUTPUT"}, "last_assistant_message": "SECRET", "unknown_field": "x",
}


class Receiver:
    """Minimal stand-in for the runtime socket: reads to EOF, then closes."""

    def __init__(self, directory):
        self.path = os.path.join(directory, "events.sock")
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        os.chmod(self.path, 0o600)
        self.server.listen(1)
        self.server.settimeout(3)
        self.received = None
        self.thread = threading.Thread(target=self._accept)
        self.thread.start()

    def _accept(self):
        try:
            client, _ = self.server.accept()
        except OSError:
            return
        chunks = []
        while True:
            chunk = client.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
        self.received = b"".join(chunks)
        client.close()

    def close(self):
        self.thread.join(4)
        self.server.close()


def run_emitter(payload_bytes, socket_path):
    return subprocess.run([sys.executable, "-I", "-B", EMITTER, "--socket", socket_path],
                          input=payload_bytes, capture_output=True, timeout=10)


class EmitterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.chmod(self.tmp, 0o700)

    def test_filters_content_and_sends_one_line(self):
        receiver = Receiver(self.tmp)
        result = run_emitter(json.dumps(SECRET_PAYLOAD).encode(), receiver.path)
        receiver.close()
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))
        envelope = json.loads(receiver.received)
        text = receiver.received.decode()
        for secret in ["SECRET", "id_rsa", "transcript", "t.jsonl", "unknown_field", "tool_input"]:
            self.assertNotIn(secret, text)
        self.assertEqual(envelope["provider"], "claude")
        self.assertEqual(envelope["integration"]["id"], "peel.claude-hook")
        self.assertEqual(set(envelope["line"]) - {"logged_at"},
                         {"hook_event_name", "session_id", "tool_name", "tool_use_id", "cwd"})

    def test_model_only_when_reported(self):
        start = {"hook_event_name": "SessionStart", "session_id": "s", "source": "startup", "model": "claude-opus-5-5"}
        self.assertEqual(claude_hook.filter_event(start)["line"]["model"], "claude-opus-5-5")
        self.assertNotIn("model", claude_hook.filter_event({"hook_event_name": "Stop", "session_id": "s"})["line"])

    def test_rejects_missing_session_unknown_event_and_bad_values(self):
        self.assertIsNone(claude_hook.filter_event({"hook_event_name": "Stop"}))
        self.assertIsNone(claude_hook.filter_event({"hook_event_name": "Evil", "session_id": "s"}))
        line = claude_hook.filter_event({"hook_event_name": "Notification", "session_id": "s",
                                         "notification_type": "rm -rf", "tool_name": "a b"})["line"]
        self.assertNotIn("notification_type", line)
        self.assertNotIn("tool_name", line)

    def test_fail_open_silently(self):
        missing = os.path.join(self.tmp, "absent.sock")
        for data in [b"not json", b"[]", json.dumps(SECRET_PAYLOAD).encode(), b"x" * (1024 * 1024 + 2)]:
            result = run_emitter(data, missing)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))

    def test_refuses_group_writable_socket_directory(self):
        os.chmod(self.tmp, 0o777)
        receiver = Receiver(self.tmp)
        run_emitter(json.dumps(SECRET_PAYLOAD).encode(), receiver.path)
        receiver.server.close()  # unblocks accept
        receiver.close()
        self.assertIsNone(receiver.received)


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.settings = os.path.join(self.tmp, "settings.json")
        self.install = os.path.join(self.tmp, "install")
        self.original = {
            "env": {"ANTHROPIC_API_KEY": "sk-secret"}, "permissions": {"allow": ["Bash(ls)"]},
            "hooks": {"Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "/usr/local/bin/other"}]}]},
            "model": "opus",
        }
        self.write(self.original)

    def write(self, value):
        with open(self.settings, "w") as handle:
            json.dump(value, handle)
        os.chmod(self.settings, 0o600)

    def read(self):
        with open(self.settings) as handle:
            return json.load(handle)

    def call(self, *args):
        return subprocess.run([sys.executable, "-I", SETUP, *args, "--settings", self.settings,
                               "--install-dir", self.install], capture_output=True, text=True, timeout=20)

    def test_plan_changes_nothing_and_prints_no_secrets(self):
        before = open(self.settings, "rb").read()
        result = self.call("plan")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(open(self.settings, "rb").read(), before)
        self.assertNotIn("sk-secret", result.stdout)
        self.assertNotIn("/usr/local/bin/other", result.stdout)
        self.assertEqual(len(json.loads(result.stdout)["insert"]), 12)

    def test_apply_is_idempotent_and_preserves_everything(self):
        self.assertEqual(self.call("apply").returncode, 0)
        after = self.read()
        self.assertEqual(after["env"], self.original["env"])
        self.assertEqual(after["permissions"], self.original["permissions"])
        self.assertEqual(after["hooks"]["Stop"][0], self.original["hooks"]["Stop"][0], "existing order kept")
        self.assertEqual(len(after["hooks"]["Stop"]), 2)
        self.assertEqual(stat.S_IMODE(os.stat(self.settings).st_mode), 0o600)
        first = open(self.settings, "rb").read()
        self.assertEqual(self.call("apply").returncode, 0)
        self.assertEqual(open(self.settings, "rb").read(), first, "second apply changes nothing")
        receipt = json.load(open(os.path.join(self.install, "receipt.json")))
        self.assertNotIn("sk-secret", json.dumps(receipt), "receipt never stores settings")

    def test_rollback_keeps_unrelated_later_edits(self):
        self.call("apply")
        edited = self.read()
        edited["theme"] = "dark"
        edited["hooks"]["Stop"].append({"matcher": "", "hooks": [{"type": "command", "command": "/bin/new"}]})
        self.write(edited)
        self.assertEqual(self.call("rollback").returncode, 0)
        final = self.read()
        self.assertEqual(final["theme"], "dark")
        self.assertEqual([g["hooks"][0]["command"] for g in final["hooks"]["Stop"]], ["/usr/local/bin/other", "/bin/new"])
        self.assertNotIn("SessionStart", final["hooks"], "containers the installer created are removed when empty")
        self.assertFalse(os.path.exists(os.path.join(self.install, "receipt.json")))

    def test_refuses_duplicate_keys_symlinks_and_disabled_hooks(self):
        with open(self.settings, "w") as handle:
            handle.write('{"hooks": {}, "hooks": {}}')
        self.assertEqual(self.call("apply").returncode, 2)
        self.write(self.original)
        link = os.path.join(self.tmp, "link.json")
        os.symlink(self.settings, link)
        result = subprocess.run([sys.executable, "-I", SETUP, "apply", "--settings", link, "--install-dir", self.install],
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 2)
        self.write(dict(self.original, disableAllHooks=True))
        self.assertEqual(self.call("apply").returncode, 2)

    def test_legacy_migration_exact_only(self):
        legacy = "/Users/x/.local/share/sidepulse/venv/bin/python -m sidepulse.hook_entry"
        value = dict(self.original)
        value["hooks"] = {
            "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": legacy}]}],
            "SessionEnd": [{"matcher": "", "hooks": [{"type": "command", "command": legacy},
                                                     {"type": "command", "command": "/bin/extra"}]}],
        }
        self.write(value)
        result = self.call("apply", "--migrate-legacy-command", legacy)
        report = json.loads(result.stdout)
        self.assertEqual(report["replaceLegacy"], ["Stop"])
        self.assertEqual(report["legacyConflicts"], ["SessionEnd"], "mixed groups are preserved and reported")
        self.assertNotIn(legacy, result.stdout)
        commands = [g["hooks"][0]["command"] for g in self.read()["hooks"]["Stop"]]
        self.assertNotIn(legacy, commands)
        self.assertEqual(self.call("rollback").returncode, 0)
        self.assertIn(legacy, [g["hooks"][0]["command"] for g in self.read()["hooks"]["Stop"]])

    def test_concurrent_edit_aborts_write(self):
        data, _ = setup_claude_hooks.read_regular(self.settings)
        with self.assertRaises(setup_claude_hooks.SetupError):
            setup_claude_hooks.atomic_write(self.settings, b"{}", "0" * 64, 0o600)
        self.assertEqual(open(self.settings, "rb").read(), data)


if __name__ == "__main__":
    unittest.main()
