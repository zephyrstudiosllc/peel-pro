#!/bin/bash
set -euo pipefail
module_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/peel-shell-core.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/Sources/PeelShellCore" "$scratch/Tests/PeelShellCoreTests"
cp "$module_root"/Sources/PeelShellCore/*.swift "$scratch/Sources/PeelShellCore/"
cp "$module_root"/Tests/PeelShellCoreTests/*.swift "$scratch/Tests/PeelShellCoreTests/"
cat > "$scratch/Package.swift" <<'MANIFEST'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "PeelShellCoreChecks", platforms: [.macOS(.v14)],
  targets: [.target(name: "PeelShellCore"), .testTarget(name: "PeelShellCoreTests", dependencies: ["PeelShellCore"])],
  swiftLanguageModes: [.v5])
MANIFEST
xcrun swift test --package-path "$scratch" --jobs 2
