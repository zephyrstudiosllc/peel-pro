#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
repo_dir=${script_dir:h}
if [[ -n "${SIDEPULSE_NOTIFICATION_TEST_OUTPUT_DIR:-}" ]]; then
    test_dir="$SIDEPULSE_NOTIFICATION_TEST_OUTPUT_DIR"
    mkdir -p "$test_dir"
else
    test_dir=$(mktemp -d /tmp/sidepulse-notifications.XXXXXX)
    trap 'rm -rf "$test_dir"' EXIT
fi
cd "$repo_dir"
app_dir="$test_dir/PeelNotificationFixture.app"
mkdir -p "$app_dir/Contents/MacOS"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.peel.notification-fixture</string>
<key>CFBundleName</key><string>PeelNotificationFixture</string>
<key>CFBundleExecutable</key><string>PeelNotificationFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun swiftc -D SIDEPULSE_TESTING \
    sidepuls-z-swift/*.swift Tests/AgentNotificationSmoke.swift \
    -o "$app_dir/Contents/MacOS/PeelNotificationFixture"
"$app_dir/Contents/MacOS/PeelNotificationFixture" --peel-preview "$@"
