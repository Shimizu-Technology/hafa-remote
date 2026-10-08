#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="full"
if [[ "${1:-}" == --binary-only ]]; then mode="binary"; shift; fi
app="${1:-}"
derived_data="${2:-}"
[[ -d "$app" && ( "$mode" == binary || -d "$derived_data" ) ]] || { echo 'Public app and its actual DerivedData are required.' >&2; exit 1; }
"$repo_root/scripts/validate-audience-plist.sh" "$app/Info.plist" public
codesign --verify --deep --strict "$app"
python3 - "$app" "$derived_data" "$mode" <<'PY'
from pathlib import Path
import plistlib, sys

def require(condition, message):
    if not condition:
        raise SystemExit(message)

app, derived = map(Path, sys.argv[1:3])
mode = sys.argv[3]
info = plistlib.loads((app / 'Info.plist').read_bytes())
require(info.get('CFBundleIdentifier') == 'com.shimizutechnology.hafaremote', 'Unexpected public app bundle identifier')
require(info.get('HafaDistributionAudience') == 'public', 'Unexpected public app audience')
require(info.get('NSBonjourServices') == ['_samsungmsf._tcp'], 'Unexpected public Bonjour services')
inputs, maps = [], []
if mode == "full":
    inputs = list((derived / 'Build/Intermediates.noindex').rglob('Hafa Remote.SwiftFileList'))
    require(inputs, 'No actual app compiler input list was found')
    for item in inputs:
        text = item.read_text()
        require('SamsungPairingCoordinator.swift' in text and 'TVBuildFlavor.swift' in text, 'Public compiler inputs lack Samsung composition')
        require(not any(token in text for token in ['/Protocols/Sony/', '/Protocols/Vizio/', 'MultiBrandSessionDriver.swift', 'RemoteConvenienceUITestHarness.swift']), 'Experimental source entered public compilation')
    maps = list((derived / 'Build/Intermediates.noindex').rglob('Hafa Remote-LinkMap-*.txt'))
    require(maps, 'No public app link map was found')
    for item in maps:
        require(not any(token in item.read_text() for token in ['SonyPairingCoordinator.o', 'SonyTLSChannel.o', 'VizioPairingCoordinator.o', 'VizioHTTPSClient.o', 'MultiBrandSessionDriver.o']), 'Experimental driver object entered public linking')
binary = (app / info['CFBundleExecutable']).read_bytes()
for token in [b'_androidtvremote2._tcp', b'_viziocast._tcp', b'SonyPairingCoordinator', b'SonyTLSChannel', b'SonyProtocolCodec', b'VizioPairingCoordinator', b'VizioHTTPSClient', b'VizioProtocolCodec', b'.sony.pairing', b'.vizio.pairing', b'netflix://', b'app.primevideo.com']:
    require(token not in binary, 'Experimental protocol or executable catalog found in public binary')
# Brand tags and app descriptor cases remain as inert Codable data for internal upgrades.
print(f'Public build validated: {len(inputs)} app compiler lists, {len(maps)} link maps, no experimental drivers/services/catalogs.')
PY
