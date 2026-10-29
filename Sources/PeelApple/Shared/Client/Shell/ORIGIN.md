# Source provenance

This is a bounded extraction from the owner's OrcheSSHtra program, internal name Conductor:

- Source repository: `https://github.com/zephyrstudiosllc/Conductor.git`
- Extracted 2026-09-25 for Peel 2. Original checkout and its existing project edit were preserved.

The following original source informed or supplied this module:

| Original Conductor file | PeelShell adaptation |
| --- | --- |
| `SSH/SSHConnectionModels.swift`, `SSH/SSHClientProtocol.swift` | `PeelShellCore/SSHModels.swift`, independent shell protocols and redacted auth |
| `SSH/SSHCredentialStore.swift` | `PeelShellCore/SSHCredentialStore.swift`, Peel-specific namespace |
| `SSH/KnownHostsStore.swift` | `PeelShellCore/SSHTrustStore.swift`, machine+endpoint+key association, bounded records and visible persistence errors |
| `SSH/NIOSSHBridges.swift`, `SSH/OpenSSHPrivateKey.swift` | Transport adapters and key parser, retaining existing supported key formats |
| `SSH/NIOSSHTransport.swift`, `SSH/NIOSSHShellSession.swift` | Independent PTY transport only, cancellation/timeout cleanup, explicit request acceptance, bounded output |
| `Terminal/TerminalTheme.swift`, `Terminal/LiveTerminalView.swift`, `Terminal/TerminalHostView.swift` color extension | Real SwiftTerm UIKit/AppKit renderer, immutable session view identity, bounded ordered input, coalesced resizing |
| `ConductorTests/SSHEndToEndTests.swift` | Disposable loopback server fixtures; actual SSH/PTTY/input protocol verification |

`PeelShellSessionController` and `PeelShellView` are Peel-specific integration code. No Conductor workspace, tmux, startup-command, purchase, cloud, SFTP, agent command, forwarding, or credential data was imported. The owner authorized publication of this extracted owner-controlled code under 0BSD on October 29, 2026. The original Conductor repository is separate and is not included in this publication.

External code remains in its original pinned dependencies. `Notices/` contains the actual inspected license text from each cached dependency, including SwiftTerm's MIT copyright/permission notices and Apple's Apache-2.0 license. Preserve these notices when packaging. `dependency-pins.json` records the exact originating lockfile revisions; it is an audit record, not a second resolver. No current vulnerability-review claim is made from old project notes.

Shipping package resolution and notices inclusion in both built Apple apps must be verified at integration. This public snapshot is authorized by the owner; the extracted original source is covered by the root 0BSD license. Third-party terms remain unchanged.

## App notice additions after integration review

The shipped resource also includes the pinned swift-nio, swift-crypto, and swift-asn1 root NOTICE.txt files. End-of-line whitespace is normalized without changing text. The linked CNIOAtomics target includes `Sources/CNIOAtomics/src/cpp_magic.h`, attributed by swift-nio to uSHET commit `c09e0acafd86720efe42dc15c63e0cc228244c32`. Its MIT copyright and permission notice is retained in `Notices/swift-nio-cpp_magic-LICENSE.txt`, copied from the uSHET Library section of [that exact upstream LICENSE](https://raw.githubusercontent.com/18sg/uSHET/c09e0acafd86720efe42dc15c63e0cc228244c32/LICENSE). The later unrelated jsmn section is excluded.

The selected NIOCore/NIOPosix/NIOSSH graph does not link NIOHTTP1/CNIOLLHTTP or NIOWebSocket/CNIOSHA1. The pinned Crypto product uses CryptoKit on Apple; its vendored BoringSSL/CXKCP targets are conditioned to non-Apple platforms in the unmodified manifest. No third-party sources were changed.
