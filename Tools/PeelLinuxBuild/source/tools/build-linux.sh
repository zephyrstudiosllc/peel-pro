#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Linux ]] || { echo 'A real Linux build environment is required.' >&2; exit 2; }
peel_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
case "$(uname -m)" in x86_64) peel_rid=linux-x64;; aarch64) peel_rid=linux-arm64;; *) echo 'Unsupported architecture' >&2; exit 2;; esac
peel_output="$peel_root/build/package-$peel_rid"
[[ ! -e "$peel_output" ]] || { echo 'Output already exists; retain previous evidence and select a fresh source folder.' >&2; exit 2; }
mkdir -p "$peel_output"
export DOTNET_GENERATE_ASPNET_CERTIFICATE=false
{
 uname -sm
 dotnet --version
 pkg-config --modversion gtk4 libportal libportal-gtk4 gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0 libsecret-1 json-glib-1.0
 for peel_plugin in pipewiresrc appsrc appsink openh264enc h264parse avdec_h264 videoconvert; do gst-inspect-1.0 "$peel_plugin"; done
} > "$peel_output/dependencies.log" 2>&1
cmake -S "$peel_root/native" -B "$peel_root/build/native-$peel_rid" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo > "$peel_output/configure.log" 2>&1
cmake --build "$peel_root/build/native-$peel_rid" --parallel 1 > "$peel_output/native-build.log" 2>&1
cd "$peel_root"
dotnet publish managed/Peel.Linux.App.csproj -c Release -r "$peel_rid" --self-contained true -o "$peel_output/app" -p:RestorePackagesWithLockFile=true > "$peel_output/managed-build.log" 2>&1
cp "$peel_root/build/native-$peel_rid/libpeel_linux.so" "$peel_output/app/"
cp "$peel_root/build/native-$peel_rid/peel-linux-native-preview" "$peel_output/app/"
cp "$peel_root/packaging/peel-pro" "$peel_output/peel-pro"
cp "$peel_root/packaging/com.zephyrstudiosllc.Peel.Linux.desktop" "$peel_output/"
cp "$peel_root/vendor/THIRD_PARTY_NOTICES.md" "$peel_output/"
find "$peel_output" -type f -print0 | sort -z | xargs -0 sha256sum > "$peel_root/build/package-$peel_rid.sha256"
printf 'Package prepared at %s. No install or launch performed.\n' "$peel_output"
