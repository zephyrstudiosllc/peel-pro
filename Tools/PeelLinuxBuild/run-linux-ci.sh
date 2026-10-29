#!/usr/bin/env bash
set -euo pipefail
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || { echo 'This reviewed build route requires Linux x86_64.' >&2; exit 2; }
peel_ci_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
peel_ci_source="$peel_ci_root/source"
peel_ci_out="$peel_ci_root/out"
[[ ! -e "$peel_ci_out" ]] || { echo 'Fresh output directory required.' >&2; exit 2; }
mkdir -p "$peel_ci_out"
finish_evidence() {
  local peel_exit=$?
  trap - EXIT
  # Preserve an existing build/test failure; evidence failures turn success into failure.
  if ! python3 "$peel_ci_root/verify-inputs.py" > "$peel_ci_out/source-after.txt" 2>&1; then
    if [[ "$peel_exit" -eq 0 ]]; then peel_exit=1; fi
  fi
  if [[ -d "$peel_ci_source/build" ]]; then
    if ! find "$peel_ci_source/build" -type f -name '*.log' -exec cp --parents -t "$peel_ci_out/" '{}' +; then
      if [[ "$peel_exit" -eq 0 ]]; then peel_exit=1; fi
    fi
  fi
  if ! find "$peel_ci_source" -name packages.lock.json -type f -exec cp --parents -t "$peel_ci_out/" '{}' +; then
    if [[ "$peel_exit" -eq 0 ]]; then peel_exit=1; fi
  fi
  # Record the effective status only after verification and evidence-copy outcomes.
  if ! printf '%s\n' "$peel_exit" > "$peel_ci_out/process-exit.txt"; then
    if [[ "$peel_exit" -eq 0 ]]; then peel_exit=1; fi
  fi
  # Failed jobs retain diagnostics, never a final distributable archive/hash.
  if [[ "$peel_exit" -ne 0 ]]; then
    rm -f -- "$peel_ci_out/PeelPro-Linux-x64-build-only.tar.gz" "$peel_ci_out/package.sha256" || true
  fi
  exit "$peel_exit"
}
trap finish_evidence EXIT
python3 "$peel_ci_root/verify-inputs.py" > "$peel_ci_out/source-before.txt"
{
  printf 'Source commit: %s\n' "${GITHUB_SHA:-local-unpublished}"
  uname -sm
  cat /etc/os-release
  dotnet --info
  dpkg-query -W -f='${Package} ${Version}\n'
} > "$peel_ci_out/environment.txt"
# CMake uses --parallel 1; no application, portal, network listener or Secret Service is launched.
timeout --signal=TERM --kill-after=15s 900s bash "$peel_ci_source/tools/build-linux.sh" > "$peel_ci_out/build-driver.log" 2>&1
# These suites are independent after successful compilation. Preserve the first
# failure, collect all four logs/statuses, then stop before packaging on any failure.
peel_first_check_exit=0
collect_check() {
  local peel_check_name="$1"
  shift
  local peel_check_status=0
  if "$@"; then
    peel_check_status=0
  else
    peel_check_status=$?
  fi
  if [[ "$peel_check_status" -ne 0 && "$peel_first_check_exit" -eq 0 ]]; then peel_first_check_exit="$peel_check_status"; fi
  # Evidence write failure cannot turn a failed suite into success or suppress
  # the remaining independent suites. Preserve an earlier nonzero status.
  if ! printf '%s\n' "$peel_check_status" > "$peel_ci_out/$peel_check_name-exit.txt"; then
    if [[ "$peel_first_check_exit" -eq 0 ]]; then peel_first_check_exit=1; fi
  fi
  return 0
}
run_codec_checks() {
  cd "$peel_ci_source" || return 2
  timeout --signal=TERM --kill-after=15s 180s dotnet run --project tests/Peel.Linux.Tests.csproj -c Release
}
run_host_checks() {
  cd "$peel_ci_source" || return 2
  timeout --signal=TERM --kill-after=15s 120s dotnet run --project tests-host/Peel.Linux.Host.Tests.csproj -c Release -p:RestorePackagesWithLockFile=true
}
run_ui_checks() {
  cd "$peel_ci_source" || return 2
  timeout --signal=TERM --kill-after=15s 120s dotnet run --project tests-ui/Peel.Linux.UI.Tests.csproj -c Release -p:RestorePackagesWithLockFile=true
}
collect_check native timeout --signal=TERM --kill-after=15s 60s ctest --test-dir "$peel_ci_source/build/native-linux-x64" --output-on-failure --no-tests=error > "$peel_ci_out/native-encoder-tests.log" 2>&1
collect_check codec run_codec_checks > "$peel_ci_out/codec-boundaries.log" 2>&1
collect_check host run_host_checks > "$peel_ci_out/host-boundaries.log" 2>&1
collect_check ui run_ui_checks > "$peel_ci_out/ui-discovery-boundaries.log" 2>&1
if [[ "$peel_first_check_exit" -ne 0 ]]; then exit "$peel_first_check_exit"; fi
file "$peel_ci_source/build/package-linux-x64/app/libpeel_linux.so" "$peel_ci_source/build/package-linux-x64/app/Peel.Pro.Linux" > "$peel_ci_out/binary-types.txt"
ldd "$peel_ci_source/build/package-linux-x64/app/libpeel_linux.so" > "$peel_ci_out/native-linkage.txt"
if grep -q 'not found' "$peel_ci_out/native-linkage.txt"; then exit 1; fi
(
  cd "$peel_ci_source/build"
  tar -czf "$peel_ci_out/PeelPro-Linux-x64-build-only.tar.gz" package-linux-x64 package-linux-x64.sha256
)
sha256sum "$peel_ci_out/PeelPro-Linux-x64-build-only.tar.gz" > "$peel_ci_out/package.sha256"
printf '%s\n' 'Build, synthetic native H264, fake managed host/codec/UI and native-source guard checks only; reachable hosting, typing, portals, Secret Service, latency and garage parity remain unproved.' > "$peel_ci_out/LIMITS.txt"
