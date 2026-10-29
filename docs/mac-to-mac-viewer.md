# Remote Desktop on the Mac (embedded desktop client)

**Remote Desktop** is the Mac Host's single place for both directions:

- **Connect** — choose another computer running Peel Pro (Mac, or Windows where
  its host is installed), then open one of its desktops or app windows. The
  current connection is shown first; Desktops are listed before App Windows;
  other nearby computers and saved private-network/VPN addresses follow, folded
  under **Other computers** while connected. An operating-system label appears
  only from the connected host's authenticated hello; saved names never imply
  an OS.
- **Share This Mac** — this Mac's availability, permissions, pairing code,
  **Pair With Another Computer** (the trusted host-to-host PIN pairing),
  direct connections, paired devices, Mac audio/microphone/Mac Status sharing
  and AI agent access. **Peel Pro Settings** keeps streaming, startup, update
  and appearance options and links back here.

The menu bar and notch offer **Remote Desktop**, **Share This Mac…** and **Copy
Pairing Code**. Navigating between pages or tabs never connects, disconnects or
selects a stream.

## Stream window

A selected desktop or app window opens in its own native window, aspect-fitted
to the decoded stream. One remote window is streamed at a time. Choosing
another window while one is open releases input, ends the connection and keeps
the window as a paused placeholder; select **Reconnect**, then choose from the
fresh list. A previously open window is highlighted in that list as a hint
only — it is never reopened automatically. Hiding or minimizing the stream
window also ends the connection with the same explicit reconnect path, and
closing it disconnects. Unhiding never connects, reads credentials or selects
a window.

The viewer uses Peel's existing TLS control and dedicated video sockets, H.264
or hardware HEVC decoding, and a bounded latest-frame renderer. Bonjour TXT
records select an exact stored host identity; the service name is not
authority. It uses the same pairing UUID/key/order stored for the paired
computer, with no second account or separate client trust database. Forgetting
or replacing that pairing ends the connection. Device discovery and connections
are disabled in `--peel-preview`.

## Control

Keyboard and pointer control start off. The **Control** switch in the stream
window applies only to that remote window while its input surface is active.
Pointer coordinates account for video letterboxing. Keyboard events use the
host's HID mapping; Command-Q stays local and Control-Option-Escape releases
control. Held input is released on focus/selection changes and normal viewer
closure. The remote host's control setting and permissions remain
authoritative. Screen Recording permission is required on a publishing Mac.

Control/frame buffers, packet sizes and pending sends are bounded. Malformed
packets close the session. Video keyframe recovery reuses the host capability.
Keychain reads occur at connection/trust/liveness boundaries rather than on
each frame fragment or pointer event. Sleep, locking, revocation and closing the
viewer require an explicit reconnection.

## Saved addresses

The computer list saves up to 16 direct private-network/VPN addresses for
existing pairings, matching the Apple clients. On a publishing Mac, **Remote
Desktop › Share This Mac › Direct Connections** shows its actual TLS port and
can keep that port fixed. Automatic allocation remains the default. Applying a
fixed port disconnects the current session and replaces pending handshakes; an
occupied port reports an error instead of switching to another destination. No
router or VPN setup is changed. Adding or editing a saved address does not
connect. Select its Connect action explicitly; control and video use that exact
endpoint and pairing, without a discovery fallback. Editing/removing an active
address disconnects it. Removing a pairing prunes its saved addresses. Only
address metadata is stored in defaults; keys remain in Peel's Keychain. The
inert preview does not save addresses or open network connections.

**Connection options › Allow AI Window Opening** lets an agent on the connected
computer request one of its listed windows here while Peel Pro is visible;
control stays off until you enable it. The Mac viewer does not embed the Apple
audio or notification receivers; those remain on iPad/iPhone/Vision. No managed
internet relay is included.

## AI on this Mac itself

**Share This Mac › AI Agents on This Mac › Allow AI to use apps on this Mac**
is a separate, runtime-only permission (off at every launch) for the local
computer route described in [the MCP adapter](../Tools/PeelMCP/README.md). It
needs no receiving device and no paired session. Peel shows a floating Stop
panel and a Stop control in the menu bar/notch while it is on.

## Status

Source and focused fixtures only in this revision. The unified Host build,
stream-window lifecycle, both Remote Desktop tabs, and two-computer video, input,
reconnect and latency still require build, runtime and physical acceptance.
