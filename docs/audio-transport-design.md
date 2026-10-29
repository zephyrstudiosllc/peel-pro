# Peel Host bidirectional audio transport design

## Scope and conclusion

This audit is pinned to checkpoint `99035ca` on `peel/unified-host`. Source references
below are `path:line-line` at that checkpoint.

The minimum safe transport is one session-scoped, full-duplex audio connection over
the existing TLS-PSK listener. It must be separate from both the NDJSON control
connection and the per-window video connections. Mac-to-iPad audio should come from
one dedicated ScreenCaptureKit audio owner, not from every window stream. iPad-to-Mac
audio should use the same audio connection in the reverse direction.

That transport alone does **not** make the iPad microphone an input to another Mac
application. Playing received audio through `AVAudioEngine` reaches the Mac's selected
output device. A target application receives it as microphone input only if:

1. that application has an explicit audio-input API that Peel integrates with; or
2. Peel ships a real Core Audio virtual input device, writes the received samples to
   it, and the user selects that device in the target application.

For a general “speak to the Mac agent” feature, the virtual input device is required.
Apple recommends an Audio Server Driver Plug-in for a purely virtual device;
AudioDriverKit is intended for physical audio devices. The transport should not
advertise successful microphone routing when that device is absent, unhealthy, or
not selected by the target application.

## Integration binding decision — September 6

The later integration proved that TLS metadata exposes configured PSKs, not the
selected peer key. Agent presentation now uses a pairing-key challenge bound to
its current control-connection generation. The older audio proposal below must
not be implemented using only a self-reported pairing ID and public session ID.

Before promoting an audio socket, require a one-time random attachment ticket
issued over the already proved control connection after explicit audio opt-in.
Bind the ticket to that exact pairing/control generation, a short monotonic
expiry, allowed audio directions, and the intended source. Consume it atomically
on promotion. An expired, reused or stale-generation ticket cannot attach a new
socket; a replacement control connection invalidates outstanding tickets and all
audio state. Treat ticket bytes as secrets: never log, persist or expose them via
MCP device listings. Audio capability/consent needs its own explicit negotiation;
turning on audio must not silently opt the user into agent-opened screens.

This is the chosen next transport boundary, not implemented authentication yet.
The packet codec validates framing only and cannot authorize a media connection.
The capture helper already integrated in Host owns one display/system-audio
source and excludes this process; per-app audio attribution remains unimplemented.

## Current source audit

### Protocol and sockets

- The wire contract is protocol v2. It says additive features should use
  capabilities, while stream startup/teardown or binary layout changes require
  protocol consideration (`Peel-Host/PeelSharedMessages.swift:31-80`).
- `PeelProtocol.capabilities` and `PeelCapability` contain video, input, state, and
  clipboard features, but no audio capability
  (`Peel-Host/PeelSharedMessages.swift:82-146`).
- `ClientHelloMessage` and `HostHelloMessage` already exchange optional capability
  arrays and protocol ranges (`Peel-Host/PeelSharedMessages.swift:760-831`).
- A dedicated video connection starts with an NDJSON `videoStreamHello`, then becomes
  binary-only for one `windowId` (`Peel-Host/PeelSharedMessages.swift:857-881`).
  Binary packet types and framing are video-only
  (`Peel-Host/PeelSharedMessages.swift:883-1053`).
- The main listener uses parameters built from the paired-peer PSKs
  (`Peel-Host/PeelHost/HostNetworkServer.swift:539-550`). New TLS connections are
  classified from a bounded first NDJSON line; only `videoStreamHello` is promoted
  to media and every other type is treated as a control connection
  (`Peel-Host/PeelHost/HostNetworkServer.swift:672-775`).
- The accepted `clientHello.pairingID` is checked against the pairing store and saved
  as `connectedClientPairingID`
  (`Peel-Host/PeelHost/HostNetworkServer.swift:1309-1339`). A video hello is rejected
  only when it supplies a nonempty pairing ID that differs from that connected ID
  (`Peel-Host/PeelHost/HostNetworkServer.swift:819-840`). This is an application-level
  check in addition to TLS; the audited files do not expose the PSK identity selected
  by TLS to connection classification.

### Queueing, generations, and teardown

- `connectionQueue` owns active control receive/state,
  `remoteControlDispatchQueue` moves latency-sensitive input decode off that queue,
  and **all outbound writes** are initiated on `outboundSendQueue`
  (`Peel-Host/PeelHost/HostNetworkServer.swift:57-68`; `CLAUDE.md:15-21`).
- Control and per-window video send state use connection identity plus monotonically
  changing generations under `sendStateLock`
  (`Peel-Host/PeelHost/HostNetworkServer.swift:70-82,303-379`).
- Video admission is intentionally byte-based: 120,000 bytes to stop and 40,000 bytes
  to resume (`Peel-Host/PeelHost/HostNetworkServer.swift:83-94,450-470`;
  `CLAUDE.md:20-21`). Reservation and completion accounting run through
  `outboundSendQueue` (`Peel-Host/PeelHost/HostNetworkServer.swift:389-429`).
- Video sends snapshot identity/generation before enqueueing and recheck it before
  calling `NWConnection.send`
  (`Peel-Host/PeelHost/HostNetworkServer.swift:277-332`).
- Promoting a new control connection invalidates the prior send generation and closes
  all old video connections before announcing the new session
  (`Peel-Host/PeelHost/HostNetworkServer.swift:779-810`). Control cleanup likewise
  invalidates send state, clears receive data, closes all video connections, and only
  then notifies the coordinator
  (`Peel-Host/PeelHost/HostNetworkServer.swift:919-1004`).
- The control receive loop is NDJSON-only and dispatches complete lines
  (`Peel-Host/PeelHost/HostNetworkServer.swift:1007-1059`). Binary audio therefore
  must not be multiplexed into this parser.

### Coordinator and capture

- `PeelHost` owns the network, input, accessibility, and `WindowStreamer`; its
  `wireControllers()` method is the closure-based boundary between capture and
  transport (`Peel-Host/PeelHost/PeelHost.swift:124-221`).
- Connect and disconnect reset streaming session state. Disconnect also resets input,
  ping, visibility, and awake policy
  (`Peel-Host/PeelHost/PeelHost.swift:406-437`). Lock and sleep use the same control
  disconnect path (`Peel-Host/PeelHost/PeelHost.swift:928-949`).
- Incoming control messages are envelope-dispatched by type
  (`Peel-Host/PeelHost/PeelHost.swift:477-581`). `clientHello` performs protocol
  compatibility, records the pairing ID, and returns host capabilities
  (`Peel-Host/PeelHost/PeelHost.swift:772-846`).
- `WindowStreamer` has authoritative capture state on `captureQueue`, with separate
  video start, frame, and teardown queues
  (`Peel-Host/PeelHost/WindowStreamer.swift:244-330`; `CLAUDE.md:22-30`).
  Session reset stops all SCK video streams and invalidates every encoder
  (`Peel-Host/PeelHost/WindowStreamer.swift:450-499`).
- Each active video window owns an `SCStream`. The configuration specifies video
  dimensions, pixel format, frame interval, queue depth, and cursor, but no audio
  (`Peel-Host/PeelHost/WindowStreamer.swift:1484-1516,1667-1700`).
  Startup registers only a `.screen` output
  (`Peel-Host/PeelHost/WindowStreamer.swift:1735-1809`), and the output callback
  rejects every type except `.screen`
  (`Peel-Host/PeelHost/WindowStreamer.swift:1849-1891`).
- Raw video is deliberately dropped before encode when the video transport is backed
  up (`Peel-Host/PeelHost/WindowStreamer.swift:915-944`); encoded access units use the
  per-window transport (`Peel-Host/PeelHost/WindowStreamer.swift:1002-1033`).
  Audio must not alter either behavior.

## Proposed contract

Keep protocol v2 behavior unchanged for peers that do not advertise audio. Add these
capabilities:

- `audio-transport-v1`
- `mac-system-audio-downlink`
- `ipad-microphone-uplink`
- `virtual-microphone-route` — advertised dynamically only when the route is installed
  and healthy

Add optional `sessionID` to `HostHelloMessage`. Generate a random 128-bit value for
each promoted control connection; do not reuse a persisted host or pairing ID.

Add three NDJSON messages:

1. `AudioSessionRequestMessage` (client to host): `enabled`,
   `sourceWindowId`, `wantsDownlink`, `wantsUplink`, `downlinkMuted`,
   `uplinkMuted`, and requested uplink destination (`monitorOnly` or
   `virtualMicrophone`).
2. `AudioSessionStateMessage` (host to client): the accepted values,
   `routeActive`, and an optional rejection/degradation reason. In particular,
   `routeActive` must be false when another app cannot actually consume the remote
   microphone.
3. `AudioStreamHelloMessage` (first line of the dedicated audio connection):
   required `pairingID`, required `sessionID`, protocol range, and capabilities.

The host must accept `audioStreamHello` only when all of the following hold:

- a current control connection exists;
- a compatible `clientHello` has supplied a nonempty pairing ID known to the pairing
  store;
- the audio hello's pairing ID exactly equals `connectedClientPairingID`;
- the audio hello's session ID exactly equals the current control session ID;
- both peers advertised `audio-transport-v1`; and
- the current session has explicitly enabled at least one audio direction.

The new audio message and packet types are additive. Keep v2 compatibility for
non-audio peers; increment `currentProtocolVersion` if the implementation makes any
audio field mandatory for existing hello or stream behavior.

## Dedicated full-duplex audio connection

Extend first-line classification with `audioStreamHello`. After promotion, the
connection is binary-only in both directions. Feed bytes received after the hello's
newline into the audio parser rather than ignoring them.

Maintain audio state parallel to, but separate from, video:

- `audioConnection` on `connectionQueue`;
- `AudioSendSnapshot(connection, generation, sessionID)` under `sendStateLock`;
- a monotonically increasing audio send generation;
- a bounded audio receive accumulator and its generation;
- independent audio queue counters, never `outstandingVideoBytes`.

Every receive callback, queued packet, send initiation, and send completion must
validate both connection identity and audio generation. A stale completion may clean
up only accounting for its own generation; it must not mutate the next session.

`sendAudioPacket` must still initiate `NWConnection.send` from the existing
`outboundSendQueue`. Preserve invocation order with JSON and video sends, but do not
infer cross-socket delivery order from that queue. Different TCP connections can
arrive independently.

Do not place audio on a per-window video socket. Audio should survive a video-window
reconfiguration, and closing one window must not choose which duplicate audio stream
wins.

## Format and hard bounds

Use an uncompressed v1 format to avoid a new dependency and codec negotiation:

| Direction | Format | Packet duration | Payload |
| --- | --- | ---: | ---: |
| Mac to iPad | 48 kHz, stereo, signed 16-bit little-endian PCM | 20 ms / 960 frames | 3,840 bytes |
| iPad to Mac | 48 kHz, mono, signed 16-bit little-endian PCM | 20 ms / 960 frames | 1,920 bytes |

This is approximately 1.536 Mbit/s down and 0.768 Mbit/s up before framing. It is
larger than compressed speech but simple, deterministic, and small relative to the
existing video budget.

Define an audio format packet sent once at start and after a route/format restart.
Define an audio frame header with packet version, direction, flags, sequence number,
sample-time in 48 kHz frames, frame count, channel count, bytes per sample, and
payload length. Reject rather than allocate for:

- unknown version, direction, channel count, or sample format;
- frame count other than 960 in v1;
- payload over 4,096 bytes or inconsistent with frame count and format;
- an accumulator over 64 KiB; or
- arithmetic overflow while computing a complete packet length.

Bounds per direction:

- one `NWConnection.send` in flight;
- six pending 20 ms packets (120 ms);
- drop the oldest pending packet when the producer gets ahead;
- receiver target of three packets (60 ms), hard cap of six;
- sequence gaps produce silence at the sink; packets older than the active playout
  sequence are discarded.

Insert into the bounded pending ring synchronously on `outboundSendQueue` before
returning from `sendAudioPacket`; merely dispatching one block per captured packet can
allow unbounded blocks to accumulate ahead of the ring. The send completion schedules
the next drain on that same queue. These audio limits are independent of, and must not
change, the 120,000/40,000-byte video hysteresis.

## One ScreenCaptureKit audio owner

Add a session-scoped `HostAudioSessionController` owned by `PeelHost`. Do not add
audio to `SCKVideoBridge`.

For the minimal downlink, `sourceWindowId` identifies the Mac agent window. Resolve
its `SCWindow.owningApplication` and construct one app-scoped `SCContentFilter`.
ScreenCaptureKit audio filtering is application-level, not individual-window-level,
so the UI and state response must say that audio from the selected **application** is
shared. If the selected window or owning application disappears, stop audio and
report the state; do not silently broaden capture to the whole system.

Configure the one audio stream with:

```swift
configuration.capturesAudio = true
configuration.sampleRate = 48_000
configuration.channelCount = 2
configuration.excludesCurrentProcessAudio = true
configuration.captureMicrophone = false
```

Register one `.audio` `SCStreamOutput`. Convert its `CMSampleBuffer` format to the
fixed transport PCM and slice it into 960-frame packets on a dedicated serial audio
processing queue. The callback must never wait for network completion.

`excludesCurrentProcessAudio` prevents Peel's own digital monitor playback from being
included when Peel is otherwise in the filter. It does not promise acoustic echo
cancellation, and it does not exclude audio produced by a different process or audio
driver.

Apple's examples show screen and audio outputs together but do not explicitly
guarantee in the cited material that an audio-only `SCStream` is supported for this
filter on every target release. Verify an `.audio`-only stream on macOS 26. If a
screen output is operationally required, use one discarded, throttled screen output
on this same single owner; do not create a second capture owner or feed those frames
into the video pipeline.

### Local Mac microphone is not the uplink

ScreenCaptureKit's `captureMicrophone`,
`microphoneCaptureDeviceID`, and `.microphone` output capture a microphone attached
to the **Mac**. They do not turn received iPad samples into a Mac microphone. Leave
them disabled for this feature. Enabling them would also add Mac microphone privacy
requirements and can acoustically recapture speaker playback.

The iPad captures its own microphone in the client process and sends uplink packets.
Microphone permission is therefore an iPad-client concern, not a reason to enable
ScreenCaptureKit microphone capture in Peel Host.

## Real Mac microphone routing

Implement two explicit sinks for uplink packets:

### Monitor-only sink

An `AVAudioEngine` player can render received PCM to Peel Host's output node for
diagnostics or intentional speaker playback. Label this `monitorOnly`.

This is **not microphone injection**. Another application will not receive that PCM
from its selected microphone merely because Peel played it. It may hear an acoustic
copy through a physical microphone, which is uncontrolled, delayed, echo-prone, and
must not be treated as a route.

### Virtual microphone sink

For general application input, ship a separately signed and installed Core Audio
Audio Server Driver Plug-in that exposes a mono 48 kHz input device such as
“Peel Remote Microphone.” The host writes decoded PCM to a bounded shared-memory or
IPC ring; the plug-in's real-time I/O callback reads without blocking, emits silence
on underrun, and drops oldest data on overflow. Network, allocation, locks that can
block, logging, and conversion must stay out of the real-time callback.

The target agent application must select “Peel Remote Microphone” as its input.
Peel can report whether the device is installed and producing samples, but it cannot
generally force another application to switch inputs or prove that the application
selected it. The UI and `AudioSessionStateMessage` must preserve that distinction.

The plug-in, installer, signing/notarization, sandbox-safe IPC, and target-app route
selection are a separate deliverable from the host transport patch. If that
deliverable is not approved, the honest scope is “hear Mac audio and monitor iPad
speech on the Mac,” not “speak into the Mac agent.”

## Opt-in, mute, and lifecycle

- Audio defaults off on every new control session. Do not persist consent from a
  prior connection.
- Start SCK capture only after compatible capabilities, accepted session opt-in, and
  an authenticated/bound audio connection all exist.
- `downlinkMuted` stops capture (or immediately discards samples while an asynchronous
  stop completes), clears pending downlink packets, and sends state acknowledgement.
  It must not alter Mac system volume.
- `uplinkMuted` makes the iPad stop microphone capture, makes the host reject/ignore
  subsequent uplink frames, clears jitter and IPC rings, and writes silence to any
  active sink.
- Host-side mute or route failure is authoritative even if the client continues
  sending.
- Client invisibility suspends capture and flushes queues; resumption requires the
  same live session and an explicit unmuted state.
- Closing only the audio connection stops the capture owner and both sinks but leaves
  control and video alive. It reports audio disabled/degraded on control.
- Control disconnect, replacement control connection, pairing revocation, ping
  timeout, host lock, sleep, and host stop all: invalidate audio generation first;
  detach receive handlers; clear both bounded rings and parser data; stop SCK capture;
  stop the monitor engine; make the virtual device produce silence; cancel the audio
  connection; then notify higher layers.

This mirrors the existing fresh-media-session rule for video and ensures stale audio
callbacks cannot cross a reconnect.

## Concrete minimal patch plan

1. **Shared wire types — `PeelSharedMessages.swift`.** Add capabilities, optional
   `HostHelloMessage.sessionID`, audio session request/state/hello messages, fixed PCM
   format/frame packet codecs, strict decode bounds, and round-trip parser tests in
   the integration owner's available test target.
2. **Socket state — `HostNetworkServer.swift`.** Classify `audioStreamHello`; require
   pairing ID, current session ID, negotiated capability, and opt-in; add one audio
   connection/generation; parse full-duplex binary frames; add the six-packet
   outbound ring on the existing `outboundSendQueue`; add an independently bounded
   inbound ring; close audio in every control teardown path. Leave all video
   constants and methods unchanged.
3. **Capture and sink — new `HostAudioSessionController.swift`.** Own the sole SCK
   audio stream, converter/packetizer, uplink jitter buffer, and monitor/virtual-route
   sink abstraction. Use a private serial state queue and generation checks around
   every asynchronous SCK/engine callback.
4. **Coordination — `PeelHost.swift`.** Own and wire the audio controller; generate
   the per-control session ID; route audio control messages; negotiate dynamic
   capabilities; suspend on visibility; reset on connect/disconnect; and surface
   exact route state. Do not gate audio on Accessibility's
   `allowControlThisMac`; audio requires its own session opt-in.
5. **Video capture — `WindowStreamer.swift`.** No functional audio changes. Retain
   per-window `.screen` outputs, raw-frame-before-encode dropping, and current
   backpressure. At most add a comment that audio is session-owned elsewhere.
6. **iPad client.** Add matching capabilities and packets, the TLS-PSK audio
   connection/session binding, 48 kHz stereo playout, 48 kHz mono microphone
   packetization, bounded jitter, mute handling, permission/interruption handling,
   and sequence-gap silence. Host-only changes cannot provide bidirectional audio.
7. **True agent input.** Build and sign the Audio Server Driver Plug-in and installer,
   add bounded host-to-plug-in IPC, and expose route health. Do not advertise
   `virtual-microphone-route` until this path is installed and validated.

## macOS/iPadOS validation gates

Linux review can validate framing arithmetic and source invariants only. The
integration owner needs Apple-hardware validation for:

- selected-agent application audio and helper-process audio behavior of the SCK
  filter on macOS 26;
- whether the dedicated SCK stream works with only an `.audio` output;
- Screen Recording denial, revocation, and privacy-indicator behavior;
- 48 kHz format conversion when the source or output hardware uses another format;
- throttled-network queue caps, sequence gaps, reconnects, and stale completions;
- unchanged video admission at 120,000/40,000 bytes under simultaneous audio;
- mute, visibility, audio-socket close, control replacement, lock, sleep, and pairing
  revocation teardown;
- iPad microphone permission, route changes, interruptions, speaker/headset changes,
  and echo behavior;
- virtual-device install/upgrade/uninstall, coreaudiod restart behavior, code signing,
  notarization, sandbox IPC, clock drift, underrun/overflow, and selection in each
  supported agent application.

## Strongest uncertainties

1. **Virtual input is the largest product boundary.** It adds a system audio component,
   installer, real-time ring, signing/notarization, and user/app route selection. It
   is not a small `AVAudioEngine` change inside Peel Host.
2. **SCK filter attribution needs hardware testing.** Apple documents application-level
   audio filtering. An agent whose sound is emitted by a helper process may not be
   attributed to the visible app selected by `sourceWindowId`.
3. **Audio-only SCK operation needs macOS 26 confirmation.** The official examples
   register audio alongside screen output; the cited documentation does not state an
   explicit audio-only guarantee.
4. **TLS identity binding is not visible in the audited files.** The listener is
   created from paired PSKs, but classification compares a client-supplied pairing
   ID. The session nonce prevents cross-session attachment; the implementation owner
   should determine whether `PeelTLS` can also expose the authenticated PSK identity
   and require an exact match.
5. **TCP latency under loss remains.** A dedicated connection and strict bounds avoid
   control/video queue coupling, but reliable delivery can still pause audio during
   Wi-Fi loss. Measure before considering a different authenticated transport.
6. **Echo control is end-to-end.** Excluding Peel Host's process prevents one digital
   feedback path, not acoustic echo or audio emitted by another process. iPad capture,
   Mac monitoring, the agent's output, and the selected virtual input must be tested
   together.

## Official Apple references

- [Meet ScreenCaptureKit (WWDC22)](https://developer.apple.com/videos/play/wwdc2022/10156/)
  — content filters, Screen Recording consent, `CMSampleBuffer` delivery, 48 kHz
  stereo audio, and `.audio` stream output.
- [Take ScreenCaptureKit to the next level (WWDC22)](https://developer.apple.com/videos/play/wwdc2022/10155/)
  — audio filtering is application-level.
- [`SCStreamConfiguration.capturesAudio`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio)
- [`SCStreamConfiguration.sampleRate`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/samplerate)
- [`SCStreamConfiguration.channelCount`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/channelcount)
- [`SCStreamConfiguration.excludesCurrentProcessAudio`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/excludescurrentprocessaudio)
- [Capture HDR content with ScreenCaptureKit (WWDC24)](https://developer.apple.com/videos/play/wwdc2024/10088/)
  — separate local-Mac microphone capture through `captureMicrophone`,
  `microphoneCaptureDeviceID`, and `.microphone`.
- [`AVAudioEngine.outputNode`](https://developer.apple.com/documentation/avfaudio/avaudioengine/outputnode)
  — engine playback renders through an output device.
- [Creating an audio device driver](https://developer.apple.com/documentation/audiodriverkit/creating-an-audio-device-driver)
  — Apple's sample notes that virtual devices should use an Audio Server Driver
  Plug-in and that AudioDriverKit supports physical devices.
- [Create audio drivers with DriverKit (WWDC21)](https://developer.apple.com/videos/play/wwdc2021/10190/)
  — retain the Audio Server Plug-in model when only a virtual device is needed.
- [Creating an Audio Server Driver Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
- [Audio Input Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input)
  and
  [`NSMicrophoneUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription)
  — requirements if a future host feature captures a physical Mac microphone.
