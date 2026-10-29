# Third-party licenses and notices

Original Peel Pro code owned by Zach Schwendiman / Zephyr Studios LLC is licensed under the [BSD Zero Clause License (0BSD)](LICENSE). The following components and third-party material retain their existing licenses. Their licenses apply to those portions; the root 0BSD license does not replace them. No additional attribution condition is imposed on the original 0BSD code.

## Included component source

- **SidePulse native component** — MIT, copyright 2026 Peter Kuhar and Zephyr Studios LLC. Preserve [LICENSE](Sources/SidePulse/LICENSE) and [NOTICE](Sources/SidePulse/NOTICE). This includes native ports/adaptations of the original [SidePulse project](https://github.com/inteliwear/sidepulse).
- **CodexBar maintained component** — MIT, copyright 2026 Peter Steinberger. See [LICENSE](Sources/CodexBar/LICENSE). The component retains that license, including its provider, usage and vendored support code, except where its own bundled material has the separate notices below.
- **QuickJS-ng v0.15.1** — MIT. Included under [Sources/CodexBar/Sources/CQuickJS](Sources/CodexBar/Sources/CQuickJS). Preserve its [LICENSE](Sources/CodexBar/Sources/CQuickJS/LICENSE), [provenance](Sources/CodexBar/Sources/CQuickJS/README.md) and individual source/header copyright notices.
- **Sucrase 3.35.1** — MIT. Included in [sucrase-3.35.1.min.js](Sources/CodexBar/Sources/CodexBarCore/Resources/Plugins/sucrase-3.35.1.min.js), with the complete license at [CodexBar third-party licenses](Sources/CodexBar/docs/THIRD_PARTY_LICENSES.md). Preserve the source banner and complete license.
- **WhichSpace gesture adaptation** — MIT, copyright 2015 George Christou. The Mission Control space-switch gesture in [InputSynthesizer.swift](Sources/PeelHost/Peel-Host/PeelHost/InputSynthesizer.swift) adapts WhichSpace's implementation. See [WhichSpace MIT license](Sources/PeelHost/Notices/WhichSpace-LICENSE.txt) and [upstream](https://github.com/gechr/WhichSpace).

## Apple shell dependencies and retained notices

The Apple manual shell uses pinned SwiftPM dependencies. Their source is fetched during build; the license and NOTICE copies are retained under [Shell/Notices](Sources/PeelApple/Shared/Client/Shell/Notices), and bundled app legal text is [ThirdPartyNotices.txt](Sources/PeelApple/Shared/Client/Shell/Sources/PeelShellUI/Resources/ThirdPartyNotices.txt).

- **SwiftTerm** — MIT; its notice also retains the xterm.js, SourceLair and Christopher Jeffrey notices.
- **swift-nio, swift-nio-ssh, swift-crypto, swift-asn1** — Apache-2.0 with the preserved upstream notices.
- **swift-argument-parser, swift-atomics, swift-collections, swift-system** — Apache-2.0 with the Swift Runtime Library Exception as stated in their retained license files.
- **CNIOAtomics cpp_magic / uSHET Library** — MIT; retained in [swift-nio-cpp_magic-LICENSE.txt](Sources/PeelApple/Shared/Client/Shell/Notices/swift-nio-cpp_magic-LICENSE.txt).

The shell's owner-controlled source was adapted from the owner's OrcheSSHtra / Conductor code. Its provenance is recorded in [ORIGIN.md](Sources/PeelApple/Shared/Client/Shell/ORIGIN.md); this is distinct from the externally licensed dependencies above.

## Other dependencies fetched during build

The SwiftPM package manifests and lockfiles identify dependencies such as Sparkle, Commander, SweetCookieKit, KeyboardShortcuts, Vortex, swift-crypto, swift-asn1 and swift-log. The Windows solution fetches BouncyCastle.Cryptography 2.6.2; its complete MIT notice is preserved in [Windows third-party notices](Sources/PeelWindows/THIRD_PARTY_NOTICES.md). These dependencies retain their own licenses. Binary distributors must preserve the notices required by the actual dependencies they bundle or link.

## Additional included reference/vendor trees

If retained in this snapshot:

- The Apple App Store Server Library 3.1.2 reference copy under `Services/PeelCommerce/references/apple-library-3.1.2` retains [Apple's MIT license](Services/PeelCommerce/references/apple-library-3.1.2/LICENSE.txt).
- Linux build-source vendor notices retain [Bouncy Castle's MIT notice](Tools/PeelLinuxBuild/source/vendor/THIRD_PARTY_NOTICES.md).

Names and logos identify the relevant projects and services. Their inclusion does not imply sponsorship or endorsement.
