#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$repo_root/scripts/validate-no-arbitrary-loads.sh"
fixtures="$repo_root/scripts/fixtures"

"$validator" "$fixtures/Info-arbitrary-loads-false.plist"

if "$validator" "$fixtures/Info-arbitrary-loads-true.plist" >/dev/null 2>&1; then
  echo "Expected true NSAllowsArbitraryLoads fixture to fail." >&2
  exit 1
fi

if "$validator" "$fixtures/Info-arbitrary-loads-string.plist" >/dev/null 2>&1; then
  echo "Expected non-boolean NSAllowsArbitraryLoads fixture to fail." >&2
  exit 1
fi

echo "iOS release preflight fixture tests passed"
