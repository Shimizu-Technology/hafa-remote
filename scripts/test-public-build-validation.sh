#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${1:?Pass the actual public app}"
derived_data="${2:?Pass its actual DerivedData}"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/hafa-public-validator.XXXXXX")"
trap 'rm -rf -- "$fixture_dir"' EXIT
validator="$repo_root/scripts/validate-public-build.sh"

# A real valid artifact must pass in both modes even when Python optimization is enabled.
PYTHONOPTIMIZE=1 "$validator" "$app" "$derived_data"
PYTHONOPTIMIZE=1 "$validator" --binary-only "$app"

# Harmless, ad-hoc-signed simulator binaries exercise the executable check, not a broken seal.
# They are never installed or run, and never contain credentials or household data.
for kind in clean forbidden; do
  fixture_app="$fixture_dir/$kind.app"
  mkdir -p "$fixture_app"
  cp "$app/Info.plist" "$fixture_app/Info.plist"
  if [[ "$kind" == forbidden ]]; then
    cat > "$fixture_dir/$kind.c" <<'C'
volatile const char *synthetic_marker="_viziocast._tcp";
int main(void) { return synthetic_marker[0]=='_' ? 0 : 1; }
C
  else
    printf 'int main(void) { return 0; }\n' > "$fixture_dir/$kind.c"
  fi
  executable="$(plutil -extract CFBundleExecutable raw "$fixture_app/Info.plist")"
  xcrun --sdk iphonesimulator clang -target arm64-apple-ios18.4-simulator \
    "$fixture_dir/$kind.c" -o "$fixture_app/$executable"
  codesign --force --sign - "$fixture_app" >/dev/null 2>&1
  codesign --verify --deep --strict "$fixture_app"
done

expect_rejection() {
  local expected="$1"
  shift
  if PYTHONOPTIMIZE=1 "$validator" "$@" > "$fixture_dir/rejection.log" 2>&1; then
    echo "Optimized public validator incorrectly accepted: $expected" >&2
    exit 1
  fi
  if ! grep -Fq -- "$expected" "$fixture_dir/rejection.log"; then
    cat "$fixture_dir/rejection.log" >&2
    echo "The fixture failed before its intended boundary: $expected" >&2
    exit 1
  fi
}
expect_rejection 'Experimental protocol or executable catalog found in public binary' \
  --binary-only "$fixture_dir/forbidden.app"
expect_rejection 'Experimental protocol or executable catalog found in public binary' \
  "$fixture_dir/forbidden.app" "$derived_data"
mkdir -p "$fixture_dir/EmptyDerivedData"
expect_rejection 'No actual app compiler input list was found' \
  "$fixture_dir/clean.app" "$fixture_dir/EmptyDerivedData"

# Synthetic input/map files are negative fixtures only; actual positive proof uses the real build.
inputs="$fixture_dir/NegativeDerivedData/Build/Intermediates.noindex"
mkdir -p "$inputs"
printf 'SamsungPairingCoordinator.swift\nTVBuildFlavor.swift\n/Protocols/Sony/SonyTLSChannel.swift\n' \
  > "$inputs/Hafa Remote.SwiftFileList"
expect_rejection 'Experimental source entered public compilation' \
  "$fixture_dir/clean.app" "$fixture_dir/NegativeDerivedData"
printf 'SamsungPairingCoordinator.swift\nTVBuildFlavor.swift\n' > "$inputs/Hafa Remote.SwiftFileList"
expect_rejection 'No public app link map was found' \
  "$fixture_dir/clean.app" "$fixture_dir/NegativeDerivedData"
printf 'VizioHTTPSClient.o\n' > "$inputs/Hafa Remote-LinkMap-normal-arm64.txt"
expect_rejection 'Experimental driver object entered public linking' \
  "$fixture_dir/clean.app" "$fixture_dir/NegativeDerivedData"
echo 'Optimized public artifact validation fixtures passed.'
