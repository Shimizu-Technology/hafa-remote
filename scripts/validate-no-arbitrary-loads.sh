#!/usr/bin/env bash

set -euo pipefail

plist="${1:?usage: validate-no-arbitrary-loads.sh INFO_PLIST}"

if [[ ! -f "$plist" ]] || ! plutil -lint "$plist" >/dev/null 2>&1; then
  echo "ATS validation requires a readable property list." >&2
  exit 1
fi

for key in \
  NSAppTransportSecurity.NSAllowsArbitraryLoads \
  NSAppTransportSecurity.NSAllowsArbitraryLoadsInWebContent \
  NSAppTransportSecurity.NSAllowsArbitraryLoadsForMedia; do
  if value="$(plutil -extract "$key" raw -expect bool "$plist" 2>/dev/null)"; then
    if [[ "$value" != "false" ]]; then
      echo "$key must not be enabled." >&2
      exit 1
    fi
  elif plutil -extract "$key" raw "$plist" >/dev/null 2>&1; then
    echo "$key must be a boolean when declared." >&2
    exit 1
  fi
done

local_networking_key="NSAppTransportSecurity.NSAllowsLocalNetworking"
if ! plutil -extract "$local_networking_key" raw -expect bool "$plist" >/dev/null 2>&1 \
  && plutil -extract "$local_networking_key" raw "$plist" >/dev/null 2>&1; then
  echo "$local_networking_key must be a boolean when declared." >&2
  exit 1
fi

if plutil -extract NSAppTransportSecurity.NSExceptionDomains raw "$plist" >/dev/null 2>&1; then
  echo "ATS exception domains are not allowed." >&2
  exit 1
fi
