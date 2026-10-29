# Peel Pro

Peel Pro is one Windows desktop app with **Host** and **Client** modes for
streaming individual app windows or whole displays between PCs. Manual streaming in
both modes is free; Host remains the default-priority mode. The code is built against Peel wire protocol v2
so Windows can interoperate with the existing Apple client and Mac Host without
creating an unrelated protocol.

This checkpoint contains the protocol/discovery foundation, an exact-profile TLS-PSK
transport, secure Host and Client control/video sessions, exact-HWND and monitor-backed
Windows capture, a bounded authenticated Host listener owner, a low-latency Media Foundation
H.264 encoder seam, an authenticated fail-closed input boundary, a current-user Windows
Credential Manager paired-client store, a bounded intended-contract PIN pairing listener,
a production lifecycle owner that starts both secure listeners and DNS-SD, a unified
Host-first WPF shell with a rotating PIN, visible paired-device revocation, and a
fail-closed input gate, generation-safe client-visibility ownership that releases its
Windows power request when a capable client reports background, a bounded
Client H.264 decoder seam, a latest-frame WPF
bitmap surface, and contract tests. It is
intentionally not presented as a working remote-desktop release yet. See
[`docs/PROJECT_OVERVIEW.md`](docs/PROJECT_OVERVIEW.md) for the architecture and honest
implementation status.

The Host and Client remain separate implementation projects so their platform pipelines
can move in parallel. The end-user GUI composes them as one `Peel.Windows.exe` with a
free Host tab selected by default and a Client tab; see
[`docs/PRODUCT_DIRECTION.md`](docs/PRODUCT_DIRECTION.md).

The October 2026 receiving checkpoint composes real discovery, PIN pairing, saved
private/VPN endpoints, TLS control/video, native H.264 decoding, desktop/app selection,
and explicitly enabled remote input. Manual receiving remains free. See
[`docs/CLIENT_PARITY.md`](docs/CLIENT_PARITY.md) for exact evidence and the physical
Mac-to-Windows acceptance checklist. This is a development checkpoint, not a signed release.
## Toolchain

- Windows 11 development machine
- Visual Studio with .NET desktop development and Windows SDK workloads
- .NET 10 SDK
- PowerShell 7 or Windows PowerShell

## Build

```powershell
dotnet restore .\Peel.Windows.slnx
dotnet build .\Peel.Windows.slnx --configuration Debug
dotnet run --project .\tests\Peel.Windows.Client.Tests\Peel.Windows.Client.Tests.csproj
dotnet run --project .\tests\Peel.Windows.Protocol.Tests\Peel.Windows.Protocol.Tests.csproj
dotnet run --project .\tests\Peel.Windows.Host.Tests\Peel.Windows.Host.Tests.csproj
dotnet run --project .\tests\Peel.Windows.Discovery.Tests\Peel.Windows.Discovery.Tests.csproj
dotnet run --project .\tests\Peel.Windows.Transport.Tests\Peel.Windows.Transport.Tests.csproj
```

macOS can cross-build the Windows targets but cannot execute their native paths. Do not
interpret a cross-build as proof that capture, hardware-selected encoding/decoding,
input injection, pairing, or end-to-end streaming works on Windows.

The current display-parity candidate advertises each online monitor as a
Mac-compatible synthetic `Peel Display` source in the existing window list, opens WGC
with that monitor handle, and maps normalized input across the display without trying to
focus a synthetic HWND. It cross-builds with zero warnings; on the Surface, 54/54 Host
boundary tests passed and the native monitor path produced a nonzero 2880x1920 BGRA8
frame. Apple-client presentation and physical remote input remain pending.

The current checkpoint has also been self-contained-published for `win-x64` and verified
to emit the end-user GUI `Peel.Windows.exe` plus a console-only window-discovery
diagnostic, `Peel.Windows.Host.exe`. Production hosting runs only in the unified GUI app;
the diagnostic is not a second product. These are unsigned development artifacts, not
distribution packages.

## Physical Windows checkpoints — 2026-08-01 through 2026-08-02

Self-contained `win-x64` artifacts were exercised on a Surface Pro 8 without installing
an SDK or runtime machine-wide:

- 15/15 protocol, 50/50 Host control/capture/video/input/pairing/runtime-boundary, 32/32 Client
  control/video-orchestration, and 7/7 TLS-PSK tests passed.
- Host input remained disabled by default. Its SSH service session correctly saw no
  interactive windows; a limited task in the signed-in user session enumerated two.
- The unified WPF app created a 2640x1640 physical-pixel window at Surface DPI. UI
  Automation verified nonzero on-screen bounds for the default Host heading, live secure
  status, and paid Client tab. It also verified a visible six-digit pairing surface and
  the enabled master remote-input control defaulting off. A full attended visual review
  is still pending.
- The exact-current Host surface exposes stable accessibility names and automation
  identities for its mode tabs, available-window refresh/list, PIN refresh,
  paired-device list, remote-input gate, and launch-at-sign-in control. The signed-in
  Surface smoke verified their control types and keyboard-focusability at 225% scaling
  while preserving input-off and lock/suspend fail-closed behavior. Screen-reader
  narration, complete Tab traversal, and an attended multi-DPI visual review remain
  pending.
- A controlled temporary Win32 window was captured through the real
  Windows.Graphics.Capture/D3D11 backend: 692x546 BGRA8 pixels, 2768-byte packed stride,
  nonzero content, and a valid 100 ns system-relative timestamp. No user window title or
  pixel data was printed.
- That controlled frame was converted to NV12 and encoded through the Windows Media
  Foundation H.264 transform into a nonempty keyframe with a 26-byte SPS and 4-byte PPS.
  The emitted access unit passed Peel's four-byte NAL-length validation.
- A 30-frame controlled-window run traversed WGC capture, latest-raw-frame backpressure,
  the H.264 encoder, and the Peel packet writer. It emitted one config plus 30 bounded
  frames with strictly increasing timestamps at the WGC surface's real 692x546 pixels,
  rather than the DPI-virtualized 360x280 Win32 bounds.
- A native 64x64 codec round-trip fed deterministic BGRA32 frames through the Host H.264
  encoder, Peel config/frame packets, and the Client Media Foundation decoder. Ten
  decoded BGRA32 frames had 256-byte stride, bounded buffers, and increasing timestamps;
  the latest frame was copied into and read back from one reusable WPF `WriteableBitmap`;
  no pixel data was printed. The isolated unified executable also remained responsive
  for a three-second SSH-session launch check.
- Native Windows DNS-SD passed 2/2 checks: service-type validation plus isolated
  `_peeltest._tcp` register, browse, TXT/port resolve, goodbye removal, deregister, and
  fresh-browser absence.
- The exact TLS-PSK provider passed 7/7 loopback security/lifecycle checks, including
  wrong-key and unknown-identity rejection plus cancellation on both handshake sides.
- The exact-current Host artifact accepted separate authenticated control and video
  connections through the bounded listener owner, advertised only its implemented H.264,
  per-window, binary-video, client-visibility, and expanded-keyboard capabilities,
  returned the real window
  list, captured a controlled 692x546 window, and delivered ten H.264 frames. A control `stopStream`
  then closed the video connection. The temporary interactive task exited 0 and was
  removed; no Host test process remained.
- A separate explicit-gate native input smoke focused one exact controlled HWND and
  delivered pointer movement, left click, wheel, Unicode `Z`, and F2 through `SendInput`;
  disposing the session released a held right button. The run caught and fixed both
  background foreground-policy handling and 225%-scale DPI coordinate virtualization.
  The task exited 0 and was removed with no Host test process left behind.
- A dedicated non-elevated active-window smoke in the signed-in Surface session switched
  foreground ownership between two exact controlled HWNDs through the same
  `clientActiveWindow` focus adapter used by authenticated control. Turning the local
  input gate off then rejected the next switch and left the current foreground window
  unchanged.
- The current-user paired-client store wrote an exact 32-byte PSK to a generic Windows
  Credential Manager entry, kept only bounded non-secret identity/timestamp metadata in
  `%LOCALAPPDATA%\Zephyr Studios\Peel\Host\paired-clients.json`, resolved the exact
  case-sensitive pairing identity, and deleted the credential. The exact artifact passed
  in the signed-in user's limited desktop session; the temporary task exited 0 and was
  removed. The SSH service session was intentionally not accepted as evidence because
  Windows does not expose the interactive user's credential set to that logon session.
- The exact Host pairing artifact then completed the current Apple PIN contract in the
  signed-in session: temporary `peel-pin` TLS-PSK, HKDF-SHA256 derivation, HMAC proof,
  bounded JSON, new paired identity/PSK, current-user credential persist/resolve/delete,
  and cleanup. The task emitted its success boundary, exited 0, and removed itself.
- The production Host runtime then started stable identity, authenticated control/video,
  rotating PIN pairing, `_peel._tcp`, and `_peelpair._tcp` as one owner. A limited
  interactive task discovered both services, paired through the real current-user
  Credential Manager, reconnected for Host hello and a real window list, rotated the
  PIN/listener/TXT generation, kept input off, and observed clean DNS-SD goodbye on
  disposal. Independent macOS `dns-sd` resolution saw the exact padded `pinSalt` on the
  wire. The exact WPF artifact also brought this runtime online, exposed the PIN and
  input gate through UI Automation, and shut down gracefully with no process left.
- The next exact WPF Release artifact was built natively on the Surface with the pinned
  .NET 10.0.302 SDK. UI Automation explicitly enabled remote input, delivered the real
  WTS lock/unlock and power suspend/resume window messages, and verified fail-closed
  lifecycle behavior: two secure listeners became zero while paused and returned to two
  only after resume; input closed immediately and stayed off after each fresh runtime.
  The task and process exited, and its temporary SDK, source, cache, and firewall rules
  were removed while the self-contained validation artifact was retained.
- The strengthened exact Host artifact resized one live WGC stream six consecutive times
  without replacing its video socket. It emitted seven distinct H.264 configurations,
  restarted every encoder generation with a keyframe, kept timestamps increasing, then
  survived minimize/restore and produced five more frames. The retained artifact and
  evidence are at `C:\Users\zschw\Peel-Windows-Repeated-Resize-Validation-20260802`.
- The next exact Host artifact held one authenticated loopback video socket open for 600
  seconds through the real listener, WGC, Media Foundation H.264, and binary packet reader.
  It validated 22,311 frames with increasing timestamps, then closed cleanly through
  `stopStream`. The combined validation process moved from 101.6 to 102.3 MiB private
  memory, 2.9 to 4.8 MiB managed memory, and 633 to 636 handles. The retained artifact and
  evidence are at `C:\Users\zschw\Peel-Windows-Sustained-Stream-Validation-20260802`.
- The following exact Host artifact held two simultaneous authenticated H.264 video
  sockets open for 600 seconds through separate WGC and Media Foundation pipelines. It
  validated 22,492 and 22,513 frames with independent increasing timestamps, then closed
  both streams cleanly through `stopStream`. After both streams warmed up, the combined
  process moved from 171.7 to 171.5 MiB private memory, remained at 6.6 MiB managed
  memory, and moved from 731 to 727 handles; peaks were 175.5 MiB private, 9.6 MiB
  managed, 164.2 MiB working set, and 748 handles. The retained artifact and evidence
  are at
  `C:\Users\zschw\Peel-Windows-Sustained-Multi-Stream-Validation-20260802`.
- The newest exact WPF artifact exercised the production Host lifecycle restart used by
  the Windows network-address monitor. It hid the stale generation immediately, closed
  an enabled input gate before teardown, rebuilt both listeners and both DNS-SD
  registrations, published a new pairing generation, and kept input off. The limited
  interactive task exited 0 and removed itself; no process, task, firewall rule, or
  temporary SDK/source/cache remained. The self-contained validation artifact remains.
- The next exact artifact updated a paired device's last-connected time only after a
  compatible authenticated Host hello, surfaced paired devices without exposing pairing
  IDs or PSKs, and let the local user forget a selected device. Revocation closed an
  enabled input gate, removed metadata and the Credential Manager secret, disconnected
  an active TLS peer, restarted both secure listeners, and kept input off. The direct
  production-lifecycle smoke and the real WPF selection/confirmation path both passed in
  Surface session 3. This run also caught and fixed teardown of established TLS reads
  that ignored cancellation until their owned transports were closed.
- The newest exact WPF Release artifact recovered from a controlled production startup
  failure in Surface session 3. An exclusive read lock on the existing stable Host
  identity made startup fail without modifying that file; the app kept input off, opened
  zero listeners, and surfaced an enabled 270x60 UI Automation-visible **Retry secure
  hosting** action. After the lock was released, invoking Retry created a fresh runtime,
  restored both secure listeners and the visible pairing surface, and kept input off.
  The app then closed gracefully; its task and process exited, and temporary SDK, source,
  cache, and launcher state were removed while the exact artifact and evidence remain.
- The following exact WPF artifact enforced one production app per Windows account. In
  Surface session 3, the primary owned both secure listeners with input off; a second
  launch displayed **Peel is already running for this Windows account**, owned zero
  listeners, and exited without disturbing the primary. After a controlled primary
  process termination, a replacement reclaimed the stale lease file, restored both
  listeners with input off, and preserved the stable Host identity. Its graceful exit
  removed the lease file.
- The next exact WPF artifact added production notification-area ownership. Closing the
  visible window in Surface session 3 kept the process and both secure listeners alive.
  Windows keyboard tray navigation exposed **Peel for Windows**; its **Open Peel** action
  restored the live Host with input still off, and **Exit Peel** performed the real secure
  teardown and removed the process and instance lease.
- The following exact WPF artifact added opt-in, current-user launch at sign-in without
  administrator or installer state. The Host UI wrote the exact quoted executable plus
  `--background` to its owned Windows Run value. Executing that registered command in
  Surface session 3 started the Host hidden with both secure listeners and input off;
  the real tray menu restored it, the UI removed the Run value, and **Exit Peel** cleared
  the process and instance lease. This simulated the exact shell command but did not
  perform a physical Windows sign-out or reboot.
- The next exact WPF artifact paired a temporary loopback peer and served two distinct
  controlled HWNDs over two simultaneous authenticated H.264 video sockets. The visible
  Host count moved from two streams to one while the remaining stream continued with
  newer frames, then returned to ready. Input stayed off, and the run removed its
  temporary pairing, process, task, lease, source, and package cache.
- The following exact WPF artifact implemented the existing `client-visibility`
  capability without changing protocol v2. In Surface session 3, a non-elevated
  authenticated peer drove the production shell through foreground, background,
  foreground, and disconnect. The shell reported that both Windows power requests were
  held only in foreground, released them in background, reacquired them on foreground,
  and released them on disconnect. The same run served two independent H.264 windows,
  kept input off, removed its temporary pairing, and exited through the tray. The
  retained exact artifact and evidence are at
  `C:\Users\zschw\Peel-Windows-Awake-Validation-20260802`. A physical idle timeout or
  Modern Standby cycle was not performed, and `powercfg /requests` was not used as
  evidence because it requires elevation on this Surface.
- The exact UIPI artifact ran a controlled Administrator target and a separate limited
  Host task in Surface session 3. The first run caught `SendInput` reporting success while
  the elevated target received zero events. The Host now compares mandatory integrity
  levels before focus or injection and rejects a higher-integrity target explicitly. The
  final artifact rejected the elevated target with zero key/character delivery, while
  same-integrity `Z`/F2 input and exact-HWND focus still passed. The retained artifact and
  evidence are at `C:\Users\zschw\Peel-Windows-UIPI-Validation-20260802`.
- A coordinated Apple/Windows migration now uses Security.framework's documented PSK-key
  then identity order. New Hosts advertise additive Bonjour TXT
  `tlsPSKOrder=psk-identity`; new Apple clients use that marker for the standard order,
  retain a markerless legacy path for old Apple Hosts, and pin a successful standard
  pairing against later downgrade. The exact Surface artifact passed the Release build,
  all five test executables, and the signed-in native runtime smoke. A macOS
  Network.framework probe resolved both live Surface services and validated the new TXT
  marker, then stopped before TLS with POSIX 50 because its process still lacks macOS
  Local Network authorization. The isolated Host, PIN, credential state, and scheduled
  task were removed.

This proves the current native capture, resize/minimize recovery, production Host
startup/network recovery and paired-device-revocation paths, sustained simultaneous H.264
Host streams, native H.264 decode boundary, session boundary, and secure-transport foundations on one Windows
x64 device. It does not prove hardware-MFT selection, an authenticated Apple Peel peer
or signed/authorized Network.framework probe,
attended cross-device PIN entry,
encoded LAN streaming, visible live-frame presentation, or cross-device remote input.
The input proof was local to a controlled window; it does not prove cross-device input,
drag behavior on hardware, secure-desktop/protected-system targets, mixed-DPI monitors, or
toggling the visible production control gate during an authenticated remote session,
capture device-loss recovery,
or minimize/restore while an actual remote client is decoding. The lifecycle proof
delivered the real Windows messages to the app but did not physically enter the lock
screen or Modern Standby.
The network-restart smoke directly invoked the same lifecycle entry point used by the
`NetworkAddressChanged` subscription; it did not toggle a physical adapter, generate a
real Windows address-change event, or prove reconnection by a physical remote peer.
The power-request smoke exercised the exact non-elevated API owner and UI state changes;
it did not wait through a physical display/system idle timeout, enter Modern Standby, or
attempt to prevent user-initiated sleep.

## Repository map

- `src/Peel.Windows.Protocol` — v2 DTOs and control/video framing
- `src/Peel.Windows.Discovery` — `_peel._tcp` / `_peelpair._tcp` DNS-SD boundary
- `src/Peel.Windows.Transport` — exact TLS 1.2 external-PSK client/server transport
- `src/Peel.Windows.Host` — Windows enumeration, input, capture, encoding, and serving
- `src/Peel.Windows.Client` — discovery, connection UI, rendering, and outbound input
- `tests/Peel.Windows.Protocol.Tests` — dependency-free wire contract checks
- `tests/Peel.Windows.Client.Tests` — secure Client session and receiver-readiness checks
- `tests/Peel.Windows.Host.Tests` — dependency-free hostile input-boundary checks
- `tests/Peel.Windows.Discovery.Tests` — dependency-free native DNS-SD lifecycle checks
- `tests/Peel.Windows.Transport.Tests` — hostile TLS-PSK loopback and lifecycle checks
- `docs` — operating rules, design, compatibility, and runtime handoffs

Original Peel Windows source is licensed under the monorepo's
[0BSD license](../../LICENSE). Dependencies retain their own licenses; see
[third-party notices](THIRD_PARTY_NOTICES.md).
