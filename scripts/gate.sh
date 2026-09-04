#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

echo "Running credential scan"
./scripts/scan-secrets.sh

echo "Checking Swift formatting"
xcrun swift-format lint --strict --recursive HafaRemote HafaRemoteTests HafaRemoteUITests

echo "Checking release configuration"
./scripts/ios-release-preflight.sh

if [[ "$(uname -s)" != "Darwin" ]] || ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Xcode is required to run the Hafa Remote gate." >&2
  exit 1
fi

created_simulator_id=""
created_work_dir=0
work_dir="${HAFA_GATE_WORK_DIR:-}"
if [[ -z "$work_dir" ]]; then
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/hafa-remote-gate.XXXXXX")"
  created_work_dir=1
else
  mkdir -p "$work_dir"
fi
cleanup() {
  if [[ -n "$created_simulator_id" ]]; then
    xcrun simctl shutdown "$created_simulator_id" >/dev/null 2>&1 || true
    xcrun simctl delete "$created_simulator_id" >/dev/null 2>&1 || true
  fi
  if [[ "$created_work_dir" == "1" && "${HAFA_PRESERVE_GATE_ARTIFACTS:-0}" != "1" ]]; then
    rm -rf -- "$work_dir"
  fi
}
trap cleanup EXIT

simulator_id="${IOS_SIMULATOR_ID:-}"
if [[ -z "$simulator_id" ]]; then
  runtime_id="$(xcrun simctl list runtimes available -j | ruby -rjson -e '
    runtimes = JSON.parse(STDIN.read).fetch("runtimes")
    ios = runtimes.select { |runtime| runtime.fetch("platform", "") == "iOS" }
    selected = ios.max_by { |runtime| Gem::Version.new(runtime.fetch("version")) }
    abort "No available iOS runtime found" unless selected
    puts selected.fetch("identifier")
  ')"
  created_simulator_id="$(xcrun simctl create \
    "Hafa Remote Gate" \
    "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro" \
    "$runtime_id")"
  simulator_id="$created_simulator_id"
fi

xcrun simctl boot "$simulator_id" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$simulator_id" -b

derived_data="$work_dir/DerivedData"
result_bundle="$work_dir/HafaRemoteTests.xcresult"

echo "Building and testing Hafa Remote"
xcodebuild \
  -project HafaRemote.xcodeproj \
  -scheme HafaRemote \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  -parallel-testing-enabled NO \
  -quiet \
  test \
  CODE_SIGNING_ALLOWED=NO

app_path="$derived_data/Build/Products/Debug-iphonesimulator/Hafa Remote.app"
bundle_id="$(plutil -extract CFBundleIdentifier raw "$app_path/Info.plist")"
if [[ "$bundle_id" != "com.shimizutechnology.hafaremote" ]]; then
  echo "Unexpected app bundle identifier: $bundle_id" >&2
  exit 1
fi

echo "Installing and launching the built app"
xcrun simctl install "$simulator_id" "$app_path"
xcrun simctl launch --terminate-running-process "$simulator_id" "$bundle_id"
xcrun simctl terminate "$simulator_id" "$bundle_id"

echo "Gate passed"
