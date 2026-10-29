# Paired-Mac agent sessions, owner activation and usage summary

Source implementation (2026-10-21, exact `claude-opus-5-5`, AstraBoard work
`w-335c2e1457bd4b2aa5dd5fd29f91a925`, parent `w-6846607b3c164e1790d1e00a9bebb400`).
Builds, native tests and two-Mac physical acceptance are root-owned and not
claimed here.

## What the user sees

- Agent Hub lists this Mac's sessions (tagged **This Mac** once a paired Mac
  is connected) and, below, one section per paired Mac with its sessions,
  owner tag, freshness (Reconnecting / Offline · last seen) and an honest
  action: **Open session**, **Open app**, **No open action**, **View only**
  or **<Mac> offline**. Results appear on the row ("Opened in Terminal on
  MacBook", "Sent to Codex on MacBook; selection not confirmed", …).
- The notch shows up to three attention-first paired rows with the owner tag,
  including while the LED is following another Mac.
- **Paired Macs** (Agent Hub) holds four switches, all on by default because
  PIN pairing already established these Macs as the user's own: share this
  Mac's sessions, allow paired Macs to open them, share usage limits, show
  paired Macs' sessions. It also lists each paired Mac's link state,
  including "Pairing key unavailable here" and "Update Peel on this Mac".
  LED sharing/following settings are separate and unchanged.

## Transport

The existing `_peel-signal._tcp` endpoint, Peel pairing PSKs, TLS-PSK and
bilateral HMAC proof are reused; no new PIN, key store or listener exists.

- The subscriber's hello carries optional `features`. A publisher that
  understands it answers with a challenge carrying the granted subset and
  both proofs switch to the v2 domains whose transcript binds **both** lists.
  Without a challenge list the exchange is the unchanged v1 and the socket is
  LED-only: no agent message is ever sent or accepted on it. Stripping,
  adding or changing either list fails verification.
- Features: `agents.v1` (snapshots/keepalive, owner → viewer),
  `activate.v1` (requests viewer → owner, results back), `usage.v1`.
  Activation and usage are granted only alongside `agents.v1`, whose
  snapshots/keepalives provide their epoch and liveness.
- The listener runs for LED sharing **or** agent/usage sharing; the browser
  for LED following **or** receiving agents. LED frames from a non-followed
  Mac refresh liveness but never reach SidePulse routing.
- Old ↔ new: an old publisher ignores `features` (v1, LED-only; the new
  viewer shows "Update Peel"). An old viewer gets v1; if this Mac is not LED
  sharing, the socket is refused exactly as before (no listener then).

## Contracts (`Integration/PeelPeerAgentContract.swift`, `…UsageWire.swift`)

- Snapshot: ≤24 sessions, ≤11,264 encoded bytes (lowest-priority rows are
  dropped and counted, never truncated mid-field). Per session: opaque token
  (HMAC under a per-process owner secret), provider id, title ≤96 B, project
  basename ≤64 B, state (unknown values decode to `unknown`), tool ≤40 B, age
  on the owner clock, alert flag, activation capability + reason code,
  optional pair-scoped cloud-task tag. No cwd, message, transcript, URL, path,
  PID, TTY, executable, argument or account field exists.
- Decoding is strict: sizes, identifiers, token format, sanitized text,
  finite non-negative ages and unique tokens are required; the whole message
  is rejected otherwise.
- Activation request: `requestId`, token, `bootEpoch`, `revision` only; any
  extra key is rejected. Results cannot carry viewer-only outcomes.
- Usage summary: ≤16 quota rows (≤3 windows, percent clamped, unknown stays
  nil) and ≤4 per-Mac observed measurements. Account identity only as an
  HMAC under that pairing's PSK; the raw key/email never leaves the Mac.
  Viewers never add quotas or observed token totals across Macs.

## Freshness, epochs, revocation

Owner: one `bootEpoch` per process, revision increments only on change, full
snapshot on change (≥250 ms apart), keepalive every 5 s.
Viewer (`PeelPeerAgentInventory`): an epoch change or revision regression on a
socket, or a lower revision of the same epoch on a new socket, is a violation
and closes the socket. Snapshots are full state; a missing token is removed,
never marked Done. Silence >15 s or a closed socket ⇒ Reconnecting; after 60 s
⇒ Offline (states unchanged, greyed); removed 15 min later. Pairing removal or
key replacement purges the owner's rows, usage and pending requests at once.
Owner names are labels; the routing key is the authenticated host ID.

## Owner activation

Viewer: one pending request per row (≤4 total), sent only on the owner's own
current socket, no automatic retry, first result from that socket only,
25 s ⇒ "No confirmation; it may or may not have opened". Offline/too-old/not
allowed are refused before anything is sent. Nothing opens or is acknowledged
on the viewer.

Owner (`PeelPeerActivationGuard` + `AgentActivationExecutor`): replay of a
request ID returns the cached result without re-executing; stale epoch,
unknown token (resolved against the current inventory only), ≥2/s or ≥4 in
flight are rejected; screen-locked owners refuse; trust, socket generation,
consent and the token→session mapping are rechecked immediately before the
side effect. A successful open acknowledges the owner's alert; failures do not.

| Session | Capability | Mechanism | Reported |
| --- | --- | --- | --- |
| Codex thread / cloud task | exact | owner-built `codex://threads/<id>` or allow-listed task URL via NSWorkspace | "Sent to Codex…; selection not confirmed" (delivery ≠ visual focus) |
| Claude/Grok CLI in Terminal.app with verified binding | exact | fixed AppleScript selects the single tab whose `tty` matches; read-back of the front window's selected tab | "Opened in Terminal" only when the read-back matches |
| CLI in another GUI app (iTerm, editors) | app only | `NSRunningApplication(pid).activate` after PID+birth-time recheck | "Brought iTerm forward; this session's tab can't be selected" |
| Grok Bot | app only | `grokbot://app/v1/open` | app only |
| Headless (`-p`/background), tmux/screen, SSH, no GUI ancestor, superseded or legacy rows without kernel identity | unavailable | — | "No open action" |

Terminal binding: when a hook connects to the 0600 event socket, the runtime
reads kernel `getpeereid` + `LOCAL_PEERPID` before reading the payload, walks
the live ancestry (sender → first non-shell same-user ancestor on the same TTY
= agent → first same-user `.app` ancestor = host), and records PID + kernel
birth time for agent and host plus the `/dev/ttysN` path. JSON-claimed PIDs,
TTYs, titles or cwd are never used. Before acting it re-proves both processes.
The script never launches Terminal, creates windows/tabs, runs commands, or
reads tab `contents`/`history`; zero or multiple TTY matches change nothing.
No `--resume`/`--continue` or new agent/terminal writer is ever started.

Requirements outside this lane: the Host's `Info.plist` needs
`NSAppleEventsUsageDescription` (and Release hardened runtime may need
`com.apple.security.automation.apple-events`) for Terminal tab selection;
without them macOS denies Apple Events and the row reports the Automation
message instead of opening. No user `~/.claude` hook or settings file is
modified; existing hooks that connect to the socket directly gain bindings,
relayed/daemonized hooks fail closed as unavailable.

## State and color

Rows everywhere use the session's actual state color from the saved profile
(Tool Running ≠ Thinking). Simple mode's Tool→Thinking merge applies only to
the combined LED signal and the notch status dot. Hook mapping fixes: explicit
`sidepulse_status`/`sidepulse_mode` wins; free-form message text counts only
`sidepulse:` tags/underscore machine tokens (prose "completed" no longer ends
a tool call); an idle "waiting for your input" notice is a separate latch that
clears when a tool or prompt starts and no longer turns Done into Thinking;
permission waits keep their existing release events.

## Checks (authored, not run in this lane)

```sh
sh Tools/PeelSignalTests/run-checks.sh
sh Tools/PeelPeerAgentTests/run-checks.sh
zsh Sources/SidePulse/scripts/test.sh
```

Physical acceptance remains root-owned: both directions on the existing
pairing; Codex thread and Terminal tab opened on the owner with the viewer
unchanged; Automation consent and denial; owner offline/locked/revoked; old
build peer; sleep/reconnect; zero new agent/terminal processes.
