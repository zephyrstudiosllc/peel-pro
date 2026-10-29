#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
build_dir="${TMPDIR:-/tmp}/peel-agent-app-catalog-tests"

mkdir -p "${build_dir}"

xcrun --sdk macosx swiftc \
    -swift-version 5 \
    -default-isolation MainActor \
    "${repo_root}/Peel-Host/AgentBridge/PeelAgentAppCatalog.swift" \
    "${repo_root}/Tests/AgentBridge/AgentAppCatalogHarness.swift" \
    -o "${build_dir}/PeelAgentAppCatalogTests"

"${build_dir}/PeelAgentAppCatalogTests"
