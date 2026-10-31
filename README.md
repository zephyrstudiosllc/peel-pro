# Peel Pro

Bring individual app windows from your computer onto the device you're using.

Peel Pro streams app windows and desktops, sends keyboard, pointer and controller
input back to the source computer, and includes source audio and media controls.
It also provides agent status, provider-usage monitoring, system utilities and an
opt-in MCP bridge for AI tools to inspect, control and present app windows.

This is the current development source, published as a new monorepo. Every source
component is included as ordinary files: cloning does not require private repos
or Git submodules. The initial public commit starts here; earlier private Git
history, build artifacts and operational records are not part of this repository.

## What's included

| Path | Component |
|---|---|
| `Sources/PeelHost` | Unified macOS app: pairing, capture, encoding, input and local agent bridge |
| `Sources/PeelApple` | iPhone, iPad, visionOS and Apple Watch apps and shared client code |
| `Sources/PeelWindows` | Windows host and receiver |
| `Sources/SidePulse` | Command Center, agent hub, notch, indicators and hardware integration |
| `Sources/AppMechanic` | System/process monitoring and controls |
| `Sources/CodexBar` | Provider adapters and bundled usage CLI |
| `Integration` | Product composition and Mac receiving viewer |
| `Apps/Peel/Integration` | Usage and system adapters used by the unified Mac app |
| `Tools/PeelMCP` | Python MCP stdio adapter and tests |
| `Tools/PeelLinuxBuild/source` | Linux portal-source host and view-only receiver |
| `Services` | Optional account, purchase-verification and Watch-relay service source |
| `Website` | Product website source |

Platform support differs. macOS is the integrated source/monitoring app; Apple
clients have per-device window and input interfaces. Linux remote input is not
implemented. Watch preview/control is relayed through a foreground iPhone and is
limited to about one frame per second. Controller support maps controls to
pointer/navigation actions; it is not general gamepad passthrough.

## Build

```sh
git clone https://github.com/zephyrstudiosllc/peel-pro.git
cd peel-pro
python3 scripts/check-workspace.py
scripts/build-host.sh Debug
```

The current Mac target requires macOS 26; Apple client targets use iOS/visionOS
26.1 SDKs. Use Xcode with those SDKs and Swift 6.2 or newer, as required by
`Sources/CodexBar/Package.swift`. Public Swift packages are resolved at build
time. The script builds the real `Peel-Host` scheme, bundles the usage CLI and
MCP adapter, and leaves an unsigned development app in `.build/UnifiedHost`.
It does not install or launch the app, configure accounts or grant permissions.

For iPhone/iPad and visionOS, open `Sources/PeelApple/Peel.xcodeproj` and select
the appropriate scheme. Use your own Apple development team for physical-device
signing. For Windows, see [its build instructions](Sources/PeelWindows/README.md).
For Linux, see [the source build instructions](Tools/PeelLinuxBuild/source/README.md).

Screen Recording and Accessibility permission are needed for their respective
Mac features. Manual code/PIN pairing works without an Apple account; sign-in
and iCloud pairing are optional convenience paths. Voice input to a Mac also
requires the separate microphone driver under `Sources/PeelHost/Devices`.

## MCP

The [MCP adapter](Tools/PeelMCP/README.md) uses Python 3's standard library and a
local Unix socket supplied by the running Mac app. It supports window discovery,
inspection, bounded control and presentation on eligible paired devices. Enable
the relevant agent permissions in Peel Pro explicitly. Human input can interrupt
agent control; an agent cannot enable its own permissions.

Peel is an interface above existing AI tools and harnesses. It does not replace
your agent, model provider or development environment.

## Checks

```sh
python3 scripts/check-workspace.py
python3 -m unittest discover -s Tools/PeelMCP -p 'test_*.py'
scripts/test-desktop.sh
```

The last command requires macOS and Swift. Additional focused harnesses live in
`Tools/` and the platform component directories. Source checks and builds do not
establish physical streaming, latency, controller, audio or multi-device parity.

## Development status

Mac build 254 fixes unnecessary dashboard updates while the notch is collapsed.
See the [cause, regression coverage and measured CPU results](docs/macos-build-254.md).

This publication is a source snapshot, not a new signed binary release. Existing
code includes StoreKit and optional hosted integrations, but production service
credentials, signing identities and infrastructure are not included. Configure
those integrations for your own deployment; code being present does not mean a
hosted service is available. Core manual pairing and local streaming are separate
from the optional account and purchase-verification services.

Known areas needing further work include receiver takeover/reconnection behavior,
stream recovery and scene preservation, Apple/Mac media-policy parity, feature
readiness and platform consistency. Some integrated process utilities have
automatic rules; review those settings before using a development build. Hosts
are intended for trusted paired-device networks, not a public internet listener.

## License

Original Zephyr Studios Peel code is available under **[0BSD](LICENSE)**. Use,
modify and redistribute it, including commercially, without an attribution
requirement. There are no extra credit clauses, noncommercial restrictions or
"source available" conditions.

Third-party components keep their existing licenses. In particular, CodexBar and
SidePulse retain MIT licenses and their notices. See
[third-party notices](THIRD_PARTY_NOTICES.md) and the license files alongside
those components. The root license does not replace those third-party terms.
