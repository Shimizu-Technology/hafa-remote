#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$repo_root/scripts/validate-no-arbitrary-loads.sh"
profile_validator="$repo_root/scripts/validate-provisioning-profile.sh"
privacy_validator="$repo_root/scripts/validate-privacy-manifest.sh"
fixtures="$repo_root/scripts/fixtures"

assert_rejected() {
  local fixture="$1" expected="$2" output
  if output="$("$validator" "$fixture" 2>&1)"; then
    echo "Expected $(basename "$fixture") to fail." >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "Unexpected rejection for $(basename "$fixture"): $output" >&2
    exit 1
  fi
}

"$validator" "$fixtures/Info-arbitrary-loads-false.plist"
"$validator" "$fixtures/Info-local-networking-true.plist"

assert_rejected "$fixtures/Info-arbitrary-loads-true.plist" "NSAllowsArbitraryLoads must not be enabled."
assert_rejected "$fixtures/Info-arbitrary-loads-string.plist" "NSAllowsArbitraryLoads must be a boolean"
assert_rejected "$fixtures/Info-arbitrary-web-content.plist" "NSAllowsArbitraryLoadsInWebContent must not be enabled."
assert_rejected "$fixtures/Info-arbitrary-media.plist" "NSAllowsArbitraryLoadsForMedia must not be enabled."
assert_rejected "$fixtures/Info-insecure-exception-domain.plist" "ATS exception domains are not allowed."
assert_rejected "$fixtures/Info-local-networking-string.plist" "NSAllowsLocalNetworking must be a boolean"
assert_rejected "$fixtures/Info-does-not-exist.plist" "ATS validation requires a readable property list."

missing_profile="$fixtures/embedded-does-not-exist.mobileprovision"
if output="$(
  "$profile_validator" \
    "$missing_profile" \
    "4T358A5S74.com.shimizutechnology.hafaremote" \
    true 2>&1
)"; then
  echo "Expected a missing archive provisioning profile to fail." >&2
  exit 1
fi
if [[ "$output" != *"Archive is missing embedded.mobileprovision."* ]]; then
  echo "Unexpected missing-profile rejection: $output" >&2
  exit 1
fi

privacy_tmp="$(mktemp -d "${TMPDIR:-/tmp}/hafa-privacy-fixtures.XXXXXX")"
cleanup() { rm -rf -- "$privacy_tmp"; }
trap cleanup EXIT

valid_privacy="$repo_root/HafaRemote/Resources/PrivacyInfo.xcprivacy"
"$privacy_validator" "$valid_privacy"

if output="$("$privacy_validator" "$privacy_tmp/missing.xcprivacy" 2>&1)"; then
  echo "Expected a missing privacy manifest to fail." >&2
  exit 1
fi
if [[ "$output" != *"PrivacyInfo.xcprivacy is missing."* ]]; then
  echo "Unexpected missing-manifest rejection: $output" >&2
  exit 1
fi

tracking_privacy="$privacy_tmp/tracking.xcprivacy"
cp "$valid_privacy" "$tracking_privacy"
plutil -replace NSPrivacyTracking -bool true "$tracking_privacy"
if output="$("$privacy_validator" "$tracking_privacy" 2>&1)"; then
  echo "Expected a tracking privacy manifest to fail." >&2
  exit 1
fi
if [[ "$output" != *"Hafa Remote must not declare tracking."* ]]; then
  echo "Unexpected tracking-manifest rejection: $output" >&2
  exit 1
fi

collected_privacy="$privacy_tmp/collected-data.xcprivacy"
cp "$valid_privacy" "$collected_privacy"
plutil -replace NSPrivacyCollectedDataTypes -json '[{}]' "$collected_privacy"
if output="$("$privacy_validator" "$collected_privacy" 2>&1)"; then
  echo "Expected a collected-data privacy manifest to fail." >&2
  exit 1
fi
if [[ "$output" != *"Privacy manifest unexpectedly declares collected data."* ]]; then
  echo "Unexpected collected-data rejection: $output" >&2
  exit 1
fi

tracking_domains_privacy="$privacy_tmp/tracking-domains.xcprivacy"
cp "$valid_privacy" "$tracking_domains_privacy"
plutil -replace NSPrivacyTrackingDomains -json '["tracking.example"]' "$tracking_domains_privacy"
if output="$("$privacy_validator" "$tracking_domains_privacy" 2>&1)"; then
  echo "Expected a tracking-domain privacy manifest to fail." >&2
  exit 1
fi
if [[ "$output" != *"Privacy manifest unexpectedly declares tracking domains."* ]]; then
  echo "Unexpected tracking-domain rejection: $output" >&2
  exit 1
fi

accessed_api_privacy="$privacy_tmp/accessed-api.xcprivacy"
cp "$valid_privacy" "$accessed_api_privacy"
plutil -replace NSPrivacyAccessedAPITypes -json '[{}]' "$accessed_api_privacy"
if output="$("$privacy_validator" "$accessed_api_privacy" 2>&1)"; then
  echo "Expected a required-reason API privacy manifest to fail." >&2
  exit 1
fi
if [[ "$output" != *"Privacy manifest unexpectedly declares required-reason API use."* ]]; then
  echo "Unexpected required-reason API rejection: $output" >&2
  exit 1
fi

echo "iOS release preflight fixture tests passed"
