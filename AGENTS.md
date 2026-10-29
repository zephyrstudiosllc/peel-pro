# Peel Pro contributor guidance

Read README.md, components.json and THIRD_PARTY_NOTICES.md before changing code.
This is a flat monorepo. Sources/* are ordinary directories, not submodules.
Do not initialize or reset component repositories or copy private workspace pins.

The integrated Mac target is Sources/PeelHost/Peel-Host.xcodeproj, scheme Peel-Host.
Integration and Apps/Peel/Integration are build inputs for that target.

Keep protocol, pairing, input-authority and consent boundaries intact. Separate
source checks, builds and physical runtime evidence. Do not claim that a build
proves streaming latency or parity. Preserve third-party license notices.

Never commit credentials, pairing stores, accounts, personal device identifiers,
signing keys, runtime captures, logs, build products or Xcode user state.
