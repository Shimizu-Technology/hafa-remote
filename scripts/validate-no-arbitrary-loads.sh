#!/usr/bin/env bash

set -euo pipefail

plist="${1:?usage: validate-no-arbitrary-loads.sh INFO_PLIST}"
key="NSAppTransportSecurity.NSAllowsArbitraryLoads"

if value="$(plutil -extract "$key" raw -expect bool "$plist" 2>/dev/null)"; then
  if [[ "$value" != "false" ]]; then
    echo "Arbitrary network loads are not allowed." >&2
    exit 1
  fi
elif plutil -extract "$key" raw "$plist" >/dev/null 2>&1; then
  echo "NSAllowsArbitraryLoads must be a boolean when declared." >&2
  exit 1
fi
