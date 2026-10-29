#!/bin/sh
set -eu
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_file=$(CDPATH= cd -- "$test_dir/../../Peel-Host/PeelHost" && pwd)/AccessibilityManager.swift
check_dir=$(mktemp -d /tmp/peel-local-pointer-hit-test.XXXXXX)
trap 'rm -rf "$check_dir"' EXIT HUP INT TERM
# Compile the production policy section verbatim, without the AX/AppKit manager.
{
    printf 'import Foundation\nimport CoreGraphics\n'
    sed -n '/^\/\/ BEGIN PeelLocalPointerHitTestPolicy/,/^\/\/ END PeelLocalPointerHitTestPolicy/p' "$source_file"
} > "$check_dir/Policy.swift"
grep -q 'enum PeelLocalPointerHitTestPolicy' "$check_dir/Policy.swift"
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
    -strict-concurrency=complete -warnings-as-errors \
    "$check_dir/Policy.swift" "$test_dir/Checks.swift" -o "$check_dir/checks"
"$check_dir/checks"
