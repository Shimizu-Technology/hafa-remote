#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$repo_root/scripts/validate-no-arbitrary-loads.sh"
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

echo "iOS release preflight fixture tests passed"
