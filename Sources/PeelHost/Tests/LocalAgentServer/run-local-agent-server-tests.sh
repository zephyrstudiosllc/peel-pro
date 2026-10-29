#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "PeelLocalAgentServer tests require macOS/Darwin." >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_file="${script_dir}/../../Peel-Host/AgentBridge/PeelLocalAgentServer.swift"
test_file="${script_dir}/PeelLocalAgentServerTests.swift"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/peel-local-agent-tests.XXXXXX")"
trap 'rm -rf "${build_dir}"' EXIT

xcrun swiftc \
    -parse-as-library \
    -swift-version 5 \
    -default-isolation MainActor \
    -strict-concurrency=complete \
    -D PEEL_LOCAL_AGENT_SERVER_TESTING \
    -warnings-as-errors \
    "${source_file}" \
    "${test_file}" \
    -o "${build_dir}/PeelLocalAgentServerTests"

"${build_dir}/PeelLocalAgentServerTests"
