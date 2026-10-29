#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
workspace_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)
client_dir="$workspace_dir/Sources/PeelApple/Shared/Client"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/peel-capability-checks.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    "$client_dir/PeelAISubscriptionPolicy.swift" \
    "$client_dir/PeelCapabilityPolicy.swift" \
    "$script_dir/PeelCapabilityPolicyChecks.swift" \
    -o "$work_dir/policy-checks"
"$work_dir/policy-checks"
