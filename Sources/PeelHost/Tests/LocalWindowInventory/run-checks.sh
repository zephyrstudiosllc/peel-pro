#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Local window inventory checks require macOS/Darwin." >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
host_dir="${script_dir}/../../Peel-Host"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/peel-local-window-inventory.XXXXXX")"
trap 'rm -rf "${build_dir}"' EXIT

xcrun swiftc \
    -parse-as-library \
    -swift-version 6 \
    -default-isolation MainActor \
    -strict-concurrency=complete \
    -warnings-as-errors \
    "${host_dir}/PeelSharedMessages.swift" \
    "${host_dir}/PeelStreamDiagnosticsMessages.swift" \
    "${host_dir}/AgentBridge/PeelAgentWindowDelivery.swift" \
    "${host_dir}/AgentBridge/PeelAgentPresentationPolicy.swift" \
    "${host_dir}/AgentBridge/PeelLocalComputerAccess.swift" \
    "${host_dir}/AgentBridge/PeelLocalWindowInventory.swift" \
    "${script_dir}/Checks.swift" \
    -o "${build_dir}/LocalWindowInventoryChecks"

"${build_dir}/LocalWindowInventoryChecks"
