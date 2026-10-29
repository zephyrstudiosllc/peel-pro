#!/bin/sh
set -eu
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_dir=$(CDPATH= cd -- "$test_dir/../../Peel-Host/PeelHost" && pwd)
check_dir=$(mktemp -d /tmp/peel-pointer-input.XXXXXX)
trap 'rm -rf "$check_dir"' EXIT HUP INT TERM
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
    -strict-concurrency=complete -warnings-as-errors \
    "$source_dir/PeelPointerInput.swift" "$test_dir/PointerInputChecks.swift" -o "$check_dir/checks"
"$check_dir/checks"
