#!/usr/bin/env python3
"""Install, inspect or roll back Peel's Claude Code hook handlers.

  setup_claude_hooks.py plan      # default; dry run, changes nothing
  setup_claude_hooks.py apply
  setup_claude_hooks.py rollback
  setup_claude_hooks.py status

Options: --settings PATH (default ~/.claude/settings.json)
         --install-dir PATH (default ~/.local/share/peel/integrations/claude/v1)
         --python PATH (default /usr/bin/python3; fixed absolute interpreter)
         --events E1,E2,... (default: the 12 events already used by SidePulse hooks)
         --migrate-legacy-command CMD (repeatable; remove only exact matches)

Output is a summary only: paths, hashes, counts and event names. It never
prints the settings file, existing hook commands or credentials, and never
writes a backup of the settings. The receipt stores only the handler groups
this tool inserted (and any exact legacy groups it replaced) plus hashes.
Unrelated hooks, keys, permissions and order are preserved. Writes are
atomic and abort if the file changed since it was read.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shlex
import stat
import sys
import tempfile

DEFAULT_EVENTS = [
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
    "PermissionRequest", "Notification", "PreCompact", "PostCompact", "SubagentStop", "Stop", "SessionEnd",
]
EMITTER_NAME = "claude_hook.py"
RECEIPT_NAME = "receipt.json"
SOURCE_EMITTER = os.path.join(os.path.dirname(os.path.abspath(__file__)), EMITTER_NAME)


class SetupError(Exception):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise SetupError("settings contain a duplicate JSON key; refusing to edit")
        result[key] = value
    return result


def read_regular(path: str):
    """Return (bytes, stat) or (None, None) if absent. Refuse symlinks/foreign files."""
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return None, None
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise SetupError(f"{path} is not a regular file (symlinks are refused)")
    if info.st_uid != os.getuid():
        raise SetupError(f"{path} is not owned by this user")
    with open(path, "rb") as handle:
        return handle.read(), info


def parse_settings(data):
    if data is None:
        return {}
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=_no_duplicates)
    except (ValueError, UnicodeDecodeError) as error:
        raise SetupError(f"settings are not valid JSON ({type(error).__name__})")
    if not isinstance(value, dict):
        raise SetupError("settings root is not an object")
    hooks = value.get("hooks")
    if hooks is not None and not isinstance(hooks, dict):
        raise SetupError("settings 'hooks' is not an object")
    for event, groups in (hooks or {}).items():
        if not isinstance(groups, list) or not all(isinstance(group, dict) for group in groups):
            raise SetupError(f"hooks.{event} has an unexpected shape")
    return value


def atomic_write(path: str, data: bytes, original_hash, mode: int) -> None:
    directory = os.path.dirname(path)
    current, _ = read_regular(path)
    current_hash = sha256(current) if current is not None else None
    if current_hash != original_hash:
        raise SetupError("settings changed while this tool was running; nothing written")
    fd, temp = tempfile.mkstemp(prefix=".peel-hooks-", dir=directory)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp, mode)
        os.replace(temp, path)
    except BaseException:
        if os.path.exists(temp):
            os.unlink(temp)
        raise


def ensure_private_dir(path: str) -> None:
    os.makedirs(path, mode=0o700, exist_ok=True)
    info = os.lstat(path)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise SetupError(f"{path} must be a real directory owned by this user")


def handler_command(python: str, install_dir: str) -> str:
    return f"{shlex.quote(python)} -I -B {shlex.quote(os.path.join(install_dir, EMITTER_NAME))}"


def handler_group(command: str) -> dict:
    return {"matcher": "", "hooks": [{"type": "command", "command": command, "timeout": 2}]}


def group_commands(group: dict):
    return [hook.get("command") for hook in group.get("hooks", []) if isinstance(hook, dict)]


def plan_changes(settings: dict, command: str, events, legacy_commands):
    """Return (new_settings, inserted, removed_legacy, conflicts, already, created_hooks, created_events)."""
    new = json.loads(json.dumps(settings))  # deep copy; key order preserved
    created_hooks = "hooks" not in new
    hooks = new.setdefault("hooks", {})
    inserted, removed, conflicts, already, created_events = [], [], [], [], []
    for event in events:
        groups = hooks.get(event)
        if groups is None:
            groups = hooks[event] = []
            created_events.append(event)
        kept = []
        for group in groups:
            commands = group_commands(group)
            legacy_hits = [c for c in commands if c in legacy_commands]
            if legacy_hits:
                if len(commands) == 1 and set(group) <= {"matcher", "hooks"}:
                    removed.append({"event": event, "group": group})
                    continue
                conflicts.append(event)  # legacy command mixed with other handlers: preserved
            kept.append(group)
        groups[:] = kept
        if any(command in group_commands(group) for group in groups):
            already.append(event)
            continue
        group = handler_group(command)
        groups.append(group)
        inserted.append({"event": event, "group": group})
    return new, inserted, removed, conflicts, already, created_hooks, created_events


def count_marked(settings: dict, marker: str) -> int:
    total = 0
    for groups in (settings.get("hooks") or {}).values():
        for group in groups:
            total += sum(1 for c in group_commands(group) if isinstance(c, str) and marker in c.lower())
    return total


def run(args) -> dict:
    settings_path = os.path.abspath(os.path.expanduser(args.settings))
    install_dir = os.path.abspath(os.path.expanduser(args.install_dir))
    receipt_path = os.path.join(install_dir, RECEIPT_NAME)
    if not os.path.isabs(args.python):
        raise SetupError("--python must be an absolute path")
    command = handler_command(args.python, install_dir)
    events = [e for e in args.events.split(",") if e] if args.events else DEFAULT_EVENTS
    data, info = read_regular(settings_path)
    original_hash = sha256(data) if data is not None else None
    settings = parse_settings(data)
    with open(SOURCE_EMITTER, "rb") as handle:
        emitter = handle.read()
    report = {"action": args.action, "settings": settings_path, "settingsSHA256": original_hash,
              "emitterSHA256": sha256(emitter), "installDir": install_dir,
              "disableAllHooks": bool(settings.get("disableAllHooks")),
              "legacySidePulseHandlers": count_marked(settings, "sidepulse"),
              "peelHandlers": count_marked(settings, "peel/integrations/claude/")}

    if args.action == "status":
        report["receipt"] = os.path.exists(receipt_path)
        return report

    if args.action == "rollback":
        receipt_data, _ = read_regular(receipt_path)
        if receipt_data is None:
            raise SetupError("no receipt; nothing to roll back")
        receipt = json.loads(receipt_data.decode("utf-8"))
        if receipt.get("settings") != settings_path:
            raise SetupError("receipt belongs to a different settings file")
        new = json.loads(json.dumps(settings))
        hooks = new.get("hooks") or {}
        removed = 0
        for item in receipt.get("inserted", []):
            groups = hooks.get(item["event"], [])
            for index, group in enumerate(groups):
                if group == item["group"]:  # only unchanged receipt-owned groups
                    del groups[index]
                    removed += 1
                    break
        restored = 0
        for item in receipt.get("removedLegacy", []):
            groups = hooks.setdefault(item["event"], [])
            if item["group"] not in groups:
                groups.append(item["group"])
                restored += 1
        for event in receipt.get("createdEvents", []):
            if event in hooks and not hooks[event]:
                del hooks[event]
        if receipt.get("createdHooks") and "hooks" in new and not new["hooks"]:
            del new["hooks"]
        report.update(removed=removed, restoredLegacy=restored)
        if not args.dry_run:
            atomic_write(settings_path, (json.dumps(new, indent=2, ensure_ascii=False) + "\n").encode("utf-8"),
                         original_hash, stat.S_IMODE(info.st_mode) if info else 0o600)
            installed = os.path.join(install_dir, EMITTER_NAME)
            existing, _ = read_regular(installed)
            if existing is not None and sha256(existing) == receipt.get("emitterSHA256"):
                os.unlink(installed)
            os.unlink(receipt_path)
        return report

    new, inserted, removed, conflicts, already, created_hooks, created_events = plan_changes(
        settings, command, events, set(args.migrate_legacy_command or []))
    report.update(insert=[i["event"] for i in inserted], alreadyPresent=already,
                  replaceLegacy=[r["event"] for r in removed], legacyConflicts=conflicts)
    if args.action == "plan" or args.dry_run:
        return report
    if settings.get("disableAllHooks"):
        raise SetupError("disableAllHooks is set; not installing (user policy preserved)")
    if os.path.exists(receipt_path) and inserted:
        raise SetupError("a receipt already exists; roll back first or keep the current install")
    ensure_private_dir(install_dir)
    target = os.path.join(install_dir, EMITTER_NAME)
    fd, temp = tempfile.mkstemp(prefix=".peel-emitter-", dir=install_dir)
    with os.fdopen(fd, "wb") as handle:
        handle.write(emitter)
    os.chmod(temp, 0o600)
    os.replace(temp, target)
    if inserted or removed:
        settings_dir = os.path.dirname(settings_path)
        if data is None:
            ensure_private_dir(settings_dir)
        atomic_write(settings_path, (json.dumps(new, indent=2, ensure_ascii=False) + "\n").encode("utf-8"),
                     original_hash, stat.S_IMODE(info.st_mode) if info else 0o600)
        receipt = {"schema": 1, "settings": settings_path, "emitterSHA256": sha256(emitter),
                   "inserted": inserted, "removedLegacy": removed, "createdHooks": created_hooks,
                   "createdEvents": created_events}
        fd, temp = tempfile.mkstemp(prefix=".peel-receipt-", dir=install_dir)
        with os.fdopen(fd, "w") as handle:
            json.dump(receipt, handle, indent=2)
        os.chmod(temp, 0o600)
        os.replace(temp, receipt_path)
    return report


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("action", nargs="?", default="plan", choices=["plan", "apply", "rollback", "status"])
    parser.add_argument("--settings", default="~/.claude/settings.json")
    parser.add_argument("--install-dir", default="~/.local/share/peel/integrations/claude/v1")
    parser.add_argument("--python", default="/usr/bin/python3")
    parser.add_argument("--events", default="")
    parser.add_argument("--migrate-legacy-command", action="append")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    try:
        print(json.dumps(run(args), indent=2))
        return 0
    except SetupError as error:
        print(json.dumps({"action": args.action, "error": str(error)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
