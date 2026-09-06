#!/usr/bin/env bash

set -euo pipefail

profile_path="${1:-}"
expected_application_identifier="${2:-}"
allow_team_wildcard="${3:-false}"

[[ -n "$profile_path" && -n "$expected_application_identifier" ]] || {
  echo "Usage: $0 <embedded.mobileprovision> <application-identifier> [allow-team-wildcard]" >&2
  exit 1
}
[[ -f "$profile_path" ]] || {
  echo "Archive is missing embedded.mobileprovision." >&2
  exit 1
}

profile_tmp="$(mktemp "${TMPDIR:-/tmp}/hafa-provisioning-profile.XXXXXX")"
cleanup() { rm -f -- "$profile_tmp"; }
trap cleanup EXIT

security cms -D -i "$profile_path" >"$profile_tmp"
profile_application_identifier="$(
  /usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$profile_tmp"
)"

if [[ "$profile_application_identifier" == "$expected_application_identifier" ]]; then
  exit 0
fi

expected_team_identifier="${expected_application_identifier%%.*}"
if [[ "$allow_team_wildcard" == "true" && "$profile_application_identifier" == "$expected_team_identifier.*" ]]; then
  echo "Notice: development-signed archive uses the team wildcard; the App Store export must prove the explicit app identifier."
  exit 0
fi

echo "Provisioning profile app identifier does not match." >&2
exit 1
