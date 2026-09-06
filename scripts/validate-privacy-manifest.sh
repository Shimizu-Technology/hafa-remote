#!/usr/bin/env bash

set -euo pipefail

manifest_path="${1:-}"
[[ -n "$manifest_path" && -f "$manifest_path" ]] || {
  echo "PrivacyInfo.xcprivacy is missing." >&2
  exit 1
}

if [[ "$(plutil -extract NSPrivacyTracking raw -expect bool "$manifest_path")" != "false" ]]; then
  echo "Hafa Remote must not declare tracking." >&2
  exit 1
fi

array_count() {
  plutil -extract "$1" json -o - "$manifest_path" |
    ruby -rjson -e 'puts JSON.parse(STDIN.read).length'
}

if [[ "$(array_count NSPrivacyTrackingDomains)" != "0" ]]; then
  echo "Privacy manifest unexpectedly declares tracking domains." >&2
  exit 1
fi
if [[ "$(array_count NSPrivacyCollectedDataTypes)" != "0" ]]; then
  echo "Privacy manifest unexpectedly declares collected data." >&2
  exit 1
fi
if [[ "$(array_count NSPrivacyAccessedAPITypes)" != "0" ]]; then
  echo "Privacy manifest unexpectedly declares required-reason API use." >&2
  exit 1
fi
