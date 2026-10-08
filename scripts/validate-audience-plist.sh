#!/usr/bin/env bash
set -euo pipefail
info="${1:-}"
audience="${2:-internal}"
[[ -f "$info" && ( "$audience" == internal || "$audience" == public ) ]] || { echo 'A readable Info.plist and explicit internal/public audience are required.' >&2; exit 1; }
actual="$(plutil -extract HafaDistributionAudience raw -expect string -o - "$info" 2>/dev/null || true)"
[[ "$actual" == "$audience" ]] || { echo 'Build audience metadata does not match the selected flavor.' >&2; exit 1; }
services="$(plutil -extract NSBonjourServices json -o - "$info" 2>/dev/null || true)"
if [[ "$audience" == public ]]; then
  expected='["_samsungmsf._tcp"]'
else
  expected='["_androidtvremote2._tcp","_samsungmsf._tcp","_viziocast._tcp"]'
fi
[[ "$services" == "$expected" ]] || { echo 'Bonjour services do not match the selected build flavor.' >&2; exit 1; }
