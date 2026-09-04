#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

project="HafaRemote.xcodeproj"
scheme="HafaRemote"
info_plist="HafaRemote/Resources/Info.plist"
privacy_manifest="HafaRemote/Resources/PrivacyInfo.xcprivacy"
entitlements="HafaRemote/Resources/HafaRemote.entitlements"
app_icon_set="HafaRemote/Resources/Assets.xcassets/AppIcon.appiconset"

for required in "$project/project.pbxproj" "$info_plist" "$privacy_manifest" "$entitlements"; do
  if [[ ! -f "$required" ]]; then
    echo "Missing release source: $required" >&2
    exit 1
  fi
done

for plist in "$info_plist" "$privacy_manifest" "$entitlements"; do
  plutil -lint "$plist" >/dev/null
done

settings="$(xcodebuild \
  -project "$project" \
  -scheme "$scheme" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -showBuildSettings)"
setting() {
  local key="$1"
  awk -F ' = ' -v key="$key" '$1 ~ "^[[:space:]]*" key "$" { print $2; exit }' <<<"$settings"
}

assert_setting() {
  local key="$1" expected="$2" actual
  actual="$(setting "$key")"
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected $key=$expected, found ${actual:-<missing>}." >&2
    exit 1
  fi
}

assert_setting PRODUCT_BUNDLE_IDENTIFIER com.shimizutechnology.hafaremote
assert_setting PRODUCT_NAME "Hafa Remote"
assert_setting PRODUCT_MODULE_NAME HafaRemote
assert_setting DEVELOPMENT_TEAM 4T358A5S74
assert_setting MARKETING_VERSION 1.0
assert_setting CURRENT_PROJECT_VERSION 1
assert_setting IPHONEOS_DEPLOYMENT_TARGET 18.0
assert_setting TARGETED_DEVICE_FAMILY 1
assert_setting CODE_SIGN_STYLE Automatic

local_network_copy="$(plutil -extract NSLocalNetworkUsageDescription raw "$info_plist")"
if [[ "$local_network_copy" != *"Samsung TVs"* ]]; then
  echo "Local-network permission copy must tell people it controls Samsung TVs." >&2
  exit 1
fi

if [[ "$(plutil -extract ITSAppUsesNonExemptEncryption raw "$info_plist")" != "false" ]]; then
  echo "Export-compliance declaration must remain false for this app's standard TLS use." >&2
  exit 1
fi

if plutil -extract UIBackgroundModes raw "$info_plist" >/dev/null 2>&1; then
  echo "Unexpected background modes are declared." >&2
  exit 1
fi

if [[ "$(plutil -extract NSPrivacyTracking raw "$privacy_manifest")" != "false" ]]; then
  echo "Hafa Remote must not declare tracking." >&2
  exit 1
fi

collected_count="$(plutil -extract NSPrivacyCollectedDataTypes json -o - "$privacy_manifest" | ruby -rjson -e 'puts JSON.parse(STDIN.read).length')"
if [[ "$collected_count" != "0" ]]; then
  echo "Privacy manifest unexpectedly declares collected data." >&2
  exit 1
fi

entitlement_count="$(plutil -convert json -o - "$entitlements" | ruby -rjson -e 'puts JSON.parse(STDIN.read).length')"
if [[ "$entitlement_count" != "0" ]]; then
  echo "Unexpected app entitlements are present." >&2
  exit 1
fi

app_icon_name="$(ruby -rjson -e '
  contents = JSON.parse(File.read(ARGV.fetch(0)))
  icon = contents.fetch("images").find do |image|
    image["idiom"] == "universal" && image["platform"] == "ios" && image["size"] == "1024x1024"
  end
  abort "Missing universal iOS app-icon declaration" unless icon&.key?("filename")
  puts icon.fetch("filename")
' "$app_icon_set/Contents.json")"
app_icon="$app_icon_set/$app_icon_name"
if [[ ! -f "$app_icon" ]]; then
  echo "Declared app icon does not exist: $app_icon" >&2
  exit 1
fi

icon_size="$(sips -g pixelWidth -g pixelHeight "$app_icon" 2>/dev/null | awk '/pixelWidth/ { width=$2 } /pixelHeight/ { height=$2 } END { print width "x" height }')"
if [[ "$icon_size" != "1024x1024" ]]; then
  echo "App icon must be 1024x1024, found $icon_size." >&2
  exit 1
fi

if [[ "$(sips -g hasAlpha "$app_icon" 2>/dev/null | awk '/hasAlpha/ { print $2 }')" != "no" ]]; then
  echo "App icon must be opaque." >&2
  exit 1
fi

echo "iOS release source preflight passed"
