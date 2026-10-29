#!/usr/bin/env python3
"""Peel's Claude Code hook emitter (source-owned, filtered metadata only).

Reads one hook JSON object from stdin, keeps only whitelisted non-content
fields, and sends one line to the local SidePulse/Peel event socket. It keeps
the connection open until the receiver closes it (bounded), so the receiver
can read this process's kernel credentials/ancestry while it is alive.

Always exits 0 with no output: it never returns a decision, context or
error to Claude, never logs, never stores the payload, never opens a file
named in the payload, and never reads/copies the environment beyond HOME and
XDG_STATE_HOME for locating the socket.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import socket
import stat
import sys
import time
import uuid

SCHEMA = 1
INTEGRATION_ID = "peel.claude-hook"
VERSION = "1"
MAX_INPUT = 1024 * 1024
MAX_OUTPUT = 8 * 1024
SOCKET_DEADLINE = 0.25

EVENTS = {
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
    "PermissionRequest", "PermissionDenied", "Notification", "PreCompact", "PostCompact",
    "SubagentStart", "SubagentStop", "Stop", "StopFailure", "SessionEnd",
}
NOTIFICATION_TYPES = {"permission_prompt", "idle_prompt", "elicitation_dialog", "auth_success"}
SESSION_SOURCES = {"startup", "resume", "clear", "compact"}
END_REASONS = {"clear", "logout", "prompt_input_exit", "other", "bypass_permissions_disabled"}

_ID = re.compile(r"^[A-Za-z0-9._:\-]{1,128}$")
_TOOL = re.compile(r"^[A-Za-z0-9._:\-]{1,64}$")
_MODEL = re.compile(r"^[A-Za-z0-9._:\-\[\]/]{1,96}$")


def _source_sha256() -> str:
    try:
        with open(os.path.abspath(__file__), "rb") as handle:
            return hashlib.sha256(handle.read()).hexdigest()
    except OSError:
        return ""


def _pick(value, pattern):
    return value if isinstance(value, str) and pattern.match(value) else None


def filter_event(payload: dict):
    """Return the filtered envelope or None. Content fields are dropped."""
    if not isinstance(payload, dict):
        return None
    event = payload.get("hook_event_name")
    session = _pick(payload.get("session_id"), _ID)
    if event not in EVENTS or session is None:
        return None
    line = {"hook_event_name": event, "session_id": session,
            "logged_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    for key, pattern in (("tool_name", _TOOL), ("tool_use_id", _ID), ("agent_id", _ID)):
        value = _pick(payload.get(key), pattern)
        if value is not None:
            line[key] = value
    notification = payload.get("notification_type")
    if notification in NOTIFICATION_TYPES:
        line["notification_type"] = notification
    if event == "SessionStart" and payload.get("source") in SESSION_SOURCES:
        line["source"] = payload["source"]
    if event == "SessionEnd" and payload.get("reason") in END_REASONS:
        line["reason"] = payload["reason"]
    model = payload.get("model")
    if isinstance(model, dict):
        model = model.get("id")
    model = _pick(model, _MODEL)
    if model is not None:  # only when the event actually reports it
        line["model"] = model
    cwd = payload.get("cwd")
    if isinstance(cwd, str) and cwd.startswith("/") and len(cwd) <= 1024 and "\x00" not in cwd:
        line["cwd"] = cwd  # owner-local project label only; never forwarded to paired Macs
    return {
        "provider": "claude",
        "line": line,
        "integration": {"schema": SCHEMA, "id": INTEGRATION_ID, "version": VERSION,
                        "sourceSHA256": _source_sha256(), "eventID": str(uuid.uuid4())},
    }


def default_socket_path() -> str:
    state = os.environ.get("XDG_STATE_HOME", "")
    if not state.startswith("/"):
        state = os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(state, "sidepulse", "agent-monitor", "events.sock")


def socket_is_owned(path: str) -> bool:
    """Owner-only checks: real directory and socket, same uid, no group/other write."""
    try:
        uid = os.getuid()
        directory = os.lstat(os.path.dirname(path))
        target = os.lstat(path)
    except OSError:
        return False
    if not stat.S_ISDIR(directory.st_mode) or directory.st_uid != uid or directory.st_mode & 0o022:
        return False
    return stat.S_ISSOCK(target.st_mode) and target.st_uid == uid and not target.st_mode & 0o077


def send(envelope: dict, path: str) -> None:
    data = json.dumps(envelope, separators=(",", ":"), ensure_ascii=True).encode("ascii")
    if len(data) > MAX_OUTPUT or not socket_is_owned(path):
        return
    deadline = time.monotonic() + SOCKET_DEADLINE
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        client.settimeout(SOCKET_DEADLINE)
        client.connect(path)
        client.sendall(data)
        client.shutdown(socket.SHUT_WR)
        # Stay connected until the receiver closes, so it can read this
        # process's kernel credentials while it is still alive.
        while time.monotonic() < deadline:
            client.settimeout(max(0.01, deadline - time.monotonic()))
            if not client.recv(64):
                break
    finally:
        client.close()


def main(argv) -> int:
    try:
        path = default_socket_path()
        if len(argv) == 3 and argv[1] == "--socket":  # tests only; settings never pass it
            path = argv[2]
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        if len(raw) > MAX_INPUT:
            return 0
        envelope = filter_event(json.loads(raw.decode("utf-8")))
        if envelope is not None:
            send(envelope, path)
    except BaseException:  # fail open, silently
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
