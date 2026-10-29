#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Agent presentation policy tests require macOS/Darwin." >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_file="${script_dir}/../../Peel-Host/AgentBridge/PeelAgentPresentationPolicy.swift"
test_file="${script_dir}/PeelAgentPresentationPolicyTests.swift"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/peel-agent-presentation-tests.XXXXXX")"
trap 'rm -rf "${build_dir}"' EXIT

xcrun swiftc \
    -parse-as-library \
    -swift-version 5 \
    -default-isolation MainActor \
    -strict-concurrency=complete \
    -warnings-as-errors \
    "${source_file}" \
    "${script_dir}/../../Peel-Host/AgentBridge/PeelAgentWindowDelivery.swift" \
    "${script_dir}/../../Peel-Host/PeelSharedMessages.swift" \
    "${test_file}" \
    -o "${build_dir}/PeelAgentPresentationPolicyTests"

"${build_dir}/PeelAgentPresentationPolicyTests"
