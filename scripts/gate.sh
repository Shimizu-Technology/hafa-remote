#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# The full gate runs every phase. CI runs "checks internal" and "public" as two
# concurrent jobs; together they cover exactly the same work.
phases=" ${HAFA_GATE_PHASES:-checks internal public} "
for phase in $phases; do
  case "$phase" in
    checks | internal | public) ;;
    *)
      echo "Unknown gate phase: $phase" >&2
      exit 1
      ;;
  esac
done
if [[ -z "${phases// /}" ]]; then
  echo "HAFA_GATE_PHASES must name at least one phase." >&2
  exit 1
fi
runs_phase() { [[ "$phases" == *" $1 "* ]]; }

# Internal UI tests are split by test method across this many simulators.
ui_workers="${HAFA_GATE_UI_WORKERS:-2}"
if [[ ! "$ui_workers" =~ ^[1-4]$ ]]; then
  echo "HAFA_GATE_UI_WORKERS must be between 1 and 4." >&2
  exit 1
fi

if [[ "$(uname -s)" != "Darwin" ]] || ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Xcode is required to run the Hafa Remote gate." >&2
  exit 1
fi

created_simulator_ids=()
boot_pids=()
shard_pids=()
created_work_dir=0
work_dir="${HAFA_GATE_WORK_DIR:-}"
if [[ -z "$work_dir" ]]; then
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/hafa-remote-gate.XXXXXX")"
  created_work_dir=1
else
  mkdir -p "$work_dir"
fi
cleanup() {
  local pid simulator
  for pid in ${boot_pids[@]+"${boot_pids[@]}"} ${shard_pids[@]+"${shard_pids[@]}"}; do
    pkill -P "$pid" >/dev/null 2>&1 || true
    kill "$pid" >/dev/null 2>&1 || true
  done
  for simulator in ${created_simulator_ids[@]+"${created_simulator_ids[@]}"}; do
    xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator" >/dev/null 2>&1 || true
  done
  if [[ "$created_work_dir" == "1" && "${HAFA_PRESERVE_GATE_ARTIFACTS:-0}" != "1" ]]; then
    rm -rf -- "$work_dir"
  fi
}
trap cleanup EXIT

# Simulators boot in the background while the checks and builds run; a first
# boot spends minutes on data migration.
simulator_ids=()
if runs_phase internal || runs_phase public; then
  simulator_count=1
  if runs_phase internal; then
    simulator_count="$ui_workers"
  fi
  runtime_id=""
  for ((index = 0; index < simulator_count; index++)); do
    if [[ "$index" == "0" && -n "${IOS_SIMULATOR_ID:-}" ]]; then
      simulator_ids+=("$IOS_SIMULATOR_ID")
      continue
    fi
    if [[ -z "$runtime_id" ]]; then
      runtime_id="$(xcrun simctl list runtimes available -j | ruby -E UTF-8 -rjson -e '
        runtimes = JSON.parse(STDIN.read).fetch("runtimes")
        ios = runtimes.select { |runtime| runtime.fetch("platform", "") == "iOS" }
        selected = ios.max_by { |runtime| Gem::Version.new(runtime.fetch("version")) }
        abort "No available iOS runtime found" unless selected
        puts selected.fetch("identifier")
      ')"
    fi
    simulator="$(xcrun simctl create \
      "Hafa Remote Gate $((index + 1))" \
      "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro" \
      "$runtime_id")"
    created_simulator_ids+=("$simulator")
    simulator_ids+=("$simulator")
  done
  for ((index = 0; index < ${#simulator_ids[@]}; index++)); do
    (
      xcrun simctl boot "${simulator_ids[index]}" >/dev/null 2>&1 || true
      xcrun simctl bootstatus "${simulator_ids[index]}" -b
    ) >"$work_dir/simulator-boot-$((index + 1)).log" 2>&1 &
    boot_pids+=("$!")
  done
fi
simulator_id="${simulator_ids[0]:-}"

wait_for_simulators() {
  local index
  for ((index = 0; index < ${#boot_pids[@]}; index++)); do
    if ! wait "${boot_pids[index]}"; then
      echo "Simulator ${simulator_ids[index]} failed to boot." >&2
      tail -n 20 "$work_dir/simulator-boot-$((index + 1)).log" >&2
      exit 1
    fi
  done
  boot_pids=()
}

install_and_launch() {
  xcrun simctl install "$simulator_id" "$1"
  xcrun simctl launch --terminate-running-process "$simulator_id" "$2"
  xcrun simctl terminate "$simulator_id" "$2"
}

report_test_counts() {
  local label="$1"
  shift
  ruby -E UTF-8 -rjson -e '
    label = ARGV.shift
    keys = %w[totalTestCount passedTests failedTests skippedTests expectedFailures]
    describe = ->(name, counts) do
      puts "#{name}: #{counts["totalTestCount"]} tests, #{counts["passedTests"]} passed, " \
        "#{counts["failedTests"]} failed, #{counts["skippedTests"]} skipped, #{counts["expectedFailures"]} expected failures"
    end
    totals = Hash.new(0)
    ARGV.each do |path|
      output = IO.popen(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", path], &:read)
      abort "Could not read test results from #{path}" unless $?.success?
      summary = JSON.parse(output)
      abort "No tests ran in #{File.basename(path)}" if summary.fetch("totalTestCount", 0).to_i.zero?
      keys.each { |key| totals[key] += summary.fetch(key, 0).to_i }
      describe.("  #{File.basename(path)}", summary) if ARGV.size > 1
    end
    describe.(label, totals)
  ' "$label" "$@"
}

if runs_phase checks; then
  echo "Running credential scan"
  ./scripts/scan-secrets.sh

  echo "Checking Swift formatting"
  xcrun swift-format lint --strict --recursive HafaRemote HafaRemoteControls HafaRemoteTests HafaRemoteUITests HafaRemotePublicTests HafaRemotePublicUITests

  echo "Checking release configuration"
  ./scripts/test-ios-release-preflight.sh
  (
    umask 077
    ./scripts/test-public-upload-readiness.sh
  )
  ./scripts/ios-release-preflight.sh
  ./scripts/ios-release-preflight.sh --audience public
  ./scripts/test-xcode-clang-probe.sh
fi

if runs_phase internal; then
  derived_data="$work_dir/DerivedData"

  echo "Building Hafa Remote for testing"
  xcodebuild \
    -project HafaRemote.xcodeproj \
    -scheme HafaRemote \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -derivedDataPath "$derived_data" \
    -quiet \
    build-for-testing \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_IDENTITY=- \
    "CC=$repo_root/scripts/xcode-clang-probe.sh"

  xctestrun_files=("$derived_data"/Build/Products/HafaRemote_*.xctestrun)
  if [[ "${#xctestrun_files[@]}" != "1" || ! -f "${xctestrun_files[0]}" ]]; then
    echo "Expected exactly one Hafa Remote test run file." >&2
    exit 1
  fi
  xctestrun="${xctestrun_files[0]}"

  hardware_test="HafaRemoteUITests/HafaRemoteUITests/testHardwareDiscoveryFindsSamsungTV"
  # Shards before the last run an explicit round-robin share of the UI test
  # methods found in source. The last shard runs every remaining UI test, so a
  # test this listing misses still runs instead of being dropped.
  ui_tests=()
  while IFS= read -r test_id; do
    [[ "$test_id" == "$hardware_test" ]] || ui_tests+=("$test_id")
  done < <(ruby -E UTF-8 -e '
    Dir["HafaRemoteUITests/*.swift"].sort.each do |path|
      test_class = nil
      File.foreach(path) do |line|
        test_class = $1 if line =~ /^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\b/
        puts "HafaRemoteUITests/#{test_class}/#{$1}" if test_class && line =~ /^\s*func\s+(test\w*)\s*\(/
      end
    end
  ')

  if ((${#ui_tests[@]} < ui_workers)); then
    echo "Found ${#ui_tests[@]} UI tests in source; running them on one simulator." >&2
    ui_workers=1
  fi

  result_bundles=()
  last_shard=$((ui_workers - 1))
  echo "Running Hafa Remote tests on $ui_workers simulator(s)"
  wait_for_simulators
  for ((shard = 0; shard < ui_workers; shard++)); do
    selection=()
    if [[ "$shard" == "$last_shard" ]]; then
      # Shard 1 runs HafaRemoteTests; any other test target lands here.
      [[ "$ui_workers" == "1" ]] || selection+=("-skip-testing:HafaRemoteTests")
      for ((index = 0; index < ${#ui_tests[@]}; index++)); do
        if ((index % ui_workers != shard)); then
          selection+=("-skip-testing:${ui_tests[index]}")
        fi
      done
      selection+=("-skip-testing:$hardware_test")
    else
      for ((index = shard; index < ${#ui_tests[@]}; index += ui_workers)); do
        selection+=("-only-testing:${ui_tests[index]}")
      done
    fi
    if [[ "$shard" == "0" && "$ui_workers" != "1" ]]; then
      selection+=("-only-testing:HafaRemoteTests")
    fi

    if [[ "$ui_workers" == "1" ]]; then
      result_bundle="$work_dir/HafaRemoteTests.xcresult"
    else
      result_bundle="$work_dir/HafaRemoteTests-shard$((shard + 1)).xcresult"
    fi
    result_bundles+=("$result_bundle")
    xcodebuild \
      -xctestrun "$xctestrun" \
      -destination "platform=iOS Simulator,id=${simulator_ids[shard]}" \
      -resultBundlePath "$result_bundle" \
      -parallel-testing-enabled NO \
      -collect-test-diagnostics never \
      -quiet \
      test-without-building \
      "${selection[@]}" >"$work_dir/test-shard$((shard + 1)).log" 2>&1 &
    shard_pids+=("$!")
  done

  failed_shards=0
  for ((shard = 0; shard < ui_workers; shard++)); do
    if ! wait "${shard_pids[shard]}"; then
      failed_shards=$((failed_shards + 1))
      echo "Test shard $((shard + 1)) of $ui_workers failed:" >&2
      cat "$work_dir/test-shard$((shard + 1)).log" >&2
    fi
  done
  shard_pids=()
  if [[ "$failed_shards" != "0" ]]; then
    exit 1
  fi
  report_test_counts "Hafa Remote tests" "${result_bundles[@]}"

  app_path="$derived_data/Build/Products/Debug-iphonesimulator/Hafa Remote.app"
  codesign --verify --deep --strict "$app_path"
  bundle_id="$(plutil -extract CFBundleIdentifier raw "$app_path/Info.plist")"
  if [[ "$bundle_id" != "com.shimizutechnology.hafaremote" ]]; then
    echo "Unexpected app bundle identifier: $bundle_id" >&2
    exit 1
  fi

  control_path="$app_path/PlugIns/HafaRemoteControls.appex"
  if [[ ! -d "$control_path" ]]; then
    echo "Control Center extension was not embedded." >&2
    exit 1
  fi
  if [[ "$(plutil -extract CFBundleIdentifier raw "$control_path/Info.plist")" != "com.shimizutechnology.hafaremote.controls" ]]; then
    echo "Unexpected Control Center extension bundle identifier." >&2
    exit 1
  fi

  echo "Installing and launching the built app"
  install_and_launch "$app_path" "$bundle_id"
fi

if runs_phase public; then
  if ! runs_phase internal; then
    # The public app is tested over an installed internal app, as in the full
    # gate, so a public-only run installs and launches the internal app first.
    echo "Building and installing the internal app the public flavor replaces"
    internal_data="$work_dir/InternalDerivedData"
    xcodebuild -project HafaRemote.xcodeproj -scheme HafaRemote \
      -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "$internal_data" -quiet build \
      CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- "CC=$repo_root/scripts/xcode-clang-probe.sh"
    wait_for_simulators
    install_and_launch "$internal_data/Build/Products/Debug-iphonesimulator/Hafa Remote.app" "com.shimizutechnology.hafaremote"
  fi

  echo "Building the public Release flavor and validating executable exclusion"
  public_release_data="$work_dir/PublicReleaseDerivedData"
  xcodebuild -project HafaRemote.xcodeproj -scheme HafaRemotePublic -configuration ReleasePublic \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$public_release_data" -quiet build \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- "CC=$repo_root/scripts/xcode-clang-probe.sh"
  ./scripts/validate-public-build.sh "$public_release_data/Build/Products/ReleasePublic-iphonesimulator/Hafa Remote.app" "$public_release_data"
  ./scripts/test-public-build-validation.sh "$public_release_data/Build/Products/ReleasePublic-iphonesimulator/Hafa Remote.app" "$public_release_data"

  echo "Testing the Samsung public product and preserved internal data"
  public_data="$work_dir/PublicDebugDerivedData"
  wait_for_simulators
  xcodebuild -project HafaRemote.xcodeproj -scheme HafaRemotePublic -configuration DebugPublic \
    -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "$public_data" \
    -resultBundlePath "$work_dir/HafaRemotePublicTests.xcresult" -parallel-testing-enabled NO \
    -collect-test-diagnostics never -quiet test CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
    "CC=$repo_root/scripts/xcode-clang-probe.sh"
  report_test_counts "Public flavor tests" "$work_dir/HafaRemotePublicTests.xcresult"
  public_app="$public_data/Build/Products/DebugPublic-iphonesimulator/Hafa Remote.app"
  codesign --verify --deep --strict "$public_app"
  ./scripts/validate-audience-plist.sh "$public_app/Info.plist" public
  public_bundle_id="$(plutil -extract CFBundleIdentifier raw "$public_app/Info.plist")"
  if [[ "$public_bundle_id" != "com.shimizutechnology.hafaremote" ]]; then
    echo "Unexpected public app bundle identifier: $public_bundle_id" >&2
    exit 1
  fi
  install_and_launch "$public_app" "$public_bundle_id"
fi
echo "Gate passed"
