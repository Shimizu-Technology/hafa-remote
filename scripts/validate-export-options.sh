#!/usr/bin/env bash

set -euo pipefail

options="${1:-}"
destination="${2:-export}"
[[ -f "$options" && ( "$destination" == "export" || "$destination" == "upload" ) ]] || {
  echo "A readable export-options plist and export/upload destination are required." >&2
  exit 1
}
plutil -lint "$options" >/dev/null

require_value() {
  local key="$1" expected="$2" actual
  actual="$(plutil -extract "$key" raw -o - "$options" 2>/dev/null || true)"
  [[ "$actual" == "$expected" ]] || { echo "Unexpected release option: $key." >&2; exit 1; }
}
require_bool() {
  local key="$1" expected="$2" actual
  actual="$(plutil -extract "$key" raw -expect bool -o - "$options" 2>/dev/null || true)"
  [[ "$actual" == "$expected" ]] || { echo "Unexpected boolean release option: $key." >&2; exit 1; }
}

require_value method app-store-connect
require_value destination "$destination"
require_value teamID 4T358A5S74
require_value signingStyle automatic
require_bool manageAppVersionAndBuildNumber false
require_bool testFlightInternalTestingOnly true
