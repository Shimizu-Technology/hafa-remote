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

for prohibited_fixture in \
  Info-arbitrary-web-content.plist \
  Info-arbitrary-media.plist \
  Info-insecure-exception-domain.plist; do
  if "$validator" "$fixtures/$prohibited_fixture" >/dev/null 2>&1; then
    echo "Expected $prohibited_fixture to fail." >&2
    exit 1
  fi
done

if "$validator" "$fixtures/Info-does-not-exist.plist" >/dev/null 2>&1; then
  echo "Expected a missing property list to fail." >&2
  exit 1
fi

echo "iOS release preflight fixture tests passed"
