#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
workspace_dir=${script_dir:h}
configuration=${1:-Debug}
build_jobs=${PEEL_BUILD_JOBS:-2}
if [[ "$build_jobs" != <1-16> ]]; then
    print -u2 'PEEL_BUILD_JOBS must be between 1 and 16'
    exit 2
fi
if [[ "$configuration" != Debug && "$configuration" != Release ]]; then
    print -u2 'Usage: scripts/build-host.sh [Debug|Release]'
    exit 2
fi
cd "$workspace_dir"

xcodebuild -project Sources/PeelHost/Peel-Host.xcodeproj -scheme Peel-Host \
    -configuration "$configuration" -destination 'platform=macOS' \
    -derivedDataPath .build/UnifiedHost -jobs "$build_jobs" CODE_SIGNING_ALLOWED=NO build

swift build --package-path Sources/CodexBar -c release -j "$build_jobs" --product CodexBarCLI
helper_dir=$(swift build --package-path Sources/CodexBar -c release --show-bin-path)
app_dir="$workspace_dir/.build/UnifiedHost/Build/Products/$configuration/Peel Pro.app"
[[ ! -L "$app_dir" && ! -L "$app_dir/Contents" && ! -L "$app_dir/Contents/Helpers" && ! -L "$app_dir/Contents/Resources" ]] || exit 1
mkdir -p "$app_dir/Contents/Helpers" "$app_dir/Contents/Resources"
install -m 755 "$helper_dir/CodexBarCLI" "$app_dir/Contents/Helpers/CodexBarCLI"
install -m 644 Tools/PeelMCP/peel_mcp_server.py "$app_dir/Contents/Resources/peel_mcp_server.py"
install -m 644 Sources/PeelHost/Peel-Host/PeelHost.entitlements "$app_dir/Contents/Resources/PeelSigningEntitlements.plist"
# Scripts and resource bundles belong in Resources, outside nested-code slots.
# Remove only the obsolete copies created by earlier versions of this helper.
rm -f "$app_dir/Contents/Helpers/peel_mcp_server.py"
rm -rf "$app_dir/Contents/Helpers/CodexBar_CodexBarCore.bundle"
for bundle_name in CodexBar_CodexBarCore.bundle SweetCookieKit_SweetCookieKit.bundle swift-crypto_Crypto.bundle; do
    [[ -d "$helper_dir/$bundle_name" ]] || { print -u2 "Missing built helper resource: $bundle_name"; exit 1; }
    [[ ! -L "$app_dir/Contents/Resources/$bundle_name" ]] || exit 1
    rm -rf "$app_dir/Contents/Resources/$bundle_name"
    ditto "$helper_dir/$bundle_name" "$app_dir/Contents/Resources/$bundle_name"
done

{
    print 'Peel Pro — component notices'
    print '\nNative SidePulse\n'
    cat Sources/SidePulse/LICENSE Sources/SidePulse/NOTICE
    print '\nCodexBar\n'
    cat Sources/CodexBar/LICENSE
    print '\nQuickJS\n'
    cat Sources/CodexBar/Sources/CQuickJS/LICENSE
    cat Sources/CodexBar/docs/THIRD_PARTY_LICENSES.md
    cat Sources/PeelHost/Notices/WhichSpace-LICENSE.txt
} > "$app_dir/Contents/Resources/COMPONENT_NOTICES.txt"

print "Built $app_dir"
print 'Development build only. This command does not launch, install, or access provider accounts.'
