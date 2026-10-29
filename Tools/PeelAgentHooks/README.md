# Peel Claude Code hooks

Claude Code sessions appear in Peel (and on paired Macs) only when Claude Code
reports hook events to this Mac's Peel event socket. `claude_hook.py` is the
source-owned emitter: it keeps only the event name, session ID, tool name/ID,
notification type, sub-agent ID, model (only when the event reports it) and
cwd (owner-local project label), and sends them to
`~/.local/state/sidepulse/agent-monitor/events.sock`. Prompts, messages,
tool input/output, transcript paths and unknown fields are dropped. It exits 0
with no output and never makes a hook decision.

```sh
python3 Tools/PeelAgentHooks/setup_claude_hooks.py plan       # dry run (default)
python3 Tools/PeelAgentHooks/setup_claude_hooks.py apply      # copy emitter + add handlers
python3 Tools/PeelAgentHooks/setup_claude_hooks.py status
python3 Tools/PeelAgentHooks/setup_claude_hooks.py rollback   # remove only what apply added
```

`apply` copies the emitter to `~/.local/share/peel/integrations/claude/v1/`
and appends one handler per event (`/usr/bin/python3 -I -B <emitter>`; change
with `--python`) to `~/.claude/settings.json`, preserving every other key,
hook, permission and credential. Existing legacy SidePulse hooks are kept;
pass `--migrate-legacy-command '<exact command>'` to replace exact matches.
Restart Claude Code (or check `/hooks`) after applying.

Tests (temporary files only): `python3 -I -m unittest discover -s Tools/PeelAgentHooks -p 'test_*.py'`
