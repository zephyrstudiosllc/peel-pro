#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
workspace_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/peel-purchase-checks.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    "$workspace_dir/Sources/PeelApple/Shared/Client/PeelLegacyPurchasePolicy.swift" \
    "$script_dir/PeelLegacyPurchasePolicyChecks.swift" \
    -o "$work_dir/purchase-checks"
"$work_dir/purchase-checks"
python3 "$script_dir/check-startup-boundary.py"
python3 "$script_dir/check-scene-startup.py"
