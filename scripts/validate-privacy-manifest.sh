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

# The app writes only its own local preference domain; the extension is stateless.
manifest_role="${2:-app}"
[[ "$manifest_role" == "app" || "$manifest_role" == "extension" ]] || {
  echo "Privacy manifest role must be app or extension." >&2
  exit 1
}
plutil -convert json -o - "$manifest_path" | ruby -rjson -e '
  manifest = JSON.parse(STDIN.read)
  if manifest["NSPrivacyTrackingDomains"] != []
    abort "Privacy manifest unexpectedly declares tracking domains."
  end
  if manifest["NSPrivacyCollectedDataTypes"] != []
    abort "Privacy manifest unexpectedly declares collected data."
  end
  expected = ARGV[0] == "extension" ? [] : [{
    "NSPrivacyAccessedAPIType" => "NSPrivacyAccessedAPICategoryUserDefaults",
    "NSPrivacyAccessedAPITypeReasons" => ["CA92.1"]
  }]
  if manifest["NSPrivacyAccessedAPITypes"] != expected
    abort(ARGV[0] == "extension" ? "Control extension must not declare required-reason APIs." : "Privacy manifest must declare only UserDefaults with own-app reason CA92.1.")
  end
' "$manifest_role"
