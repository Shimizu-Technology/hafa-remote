#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

archive_path=""
export_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive)
      archive_path="${2:-}"
      [[ -n "$archive_path" ]] || { echo "--archive requires a path" >&2; exit 1; }
      shift 2
      ;;
    --export)
      export_path="${2:-}"
      [[ -n "$export_path" ]] || { echo "--export requires a path" >&2; exit 1; }
      shift 2
      ;;
    *)
      echo "Usage: $0 [--archive /path/to/HafaRemote.xcarchive] [--export /path/to/AppStoreExport]" >&2
      exit 1
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iOS release preflight requires macOS." >&2
  exit 1
fi

for command_name in xcodebuild xcrun plutil ruby sips codesign security unzip; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

project="HafaRemote.xcodeproj"
scheme="HafaRemote"
info_plist="HafaRemote/Resources/Info.plist"
privacy_manifest="HafaRemote/Resources/PrivacyInfo.xcprivacy"
entitlements="HafaRemote/Resources/HafaRemote.entitlements"
app_icon_set="HafaRemote/Resources/Assets.xcassets/AppIcon.appiconset"
metadata_path="ios/app-store/en-US"
export_options="ios/app-store/ExportOptions.plist"

for required in "$project/project.pbxproj" "$info_plist" "$privacy_manifest" "$entitlements" "$metadata_path" "$export_options"; do
  if [[ ! -e "$required" ]]; then
    echo "Missing release source: $required" >&2
    exit 1
  fi
done

xcode_version="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
xcode_major="${xcode_version%%.*}"
sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
sdk_major="${sdk_version%%.*}"
if (( xcode_major < 26 || sdk_major < 26 )); then
  echo "App Store uploads require Xcode/iOS SDK 26 or later; found Xcode $xcode_version and iOS SDK $sdk_version." >&2
  exit 1
fi

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
assert_setting IPHONEOS_DEPLOYMENT_TARGET 18.4
assert_setting TARGETED_DEVICE_FAMILY 1
assert_setting CODE_SIGN_STYLE Automatic

local_network_copy="$(plutil -extract NSLocalNetworkUsageDescription raw "$info_plist")"
if [[ "$local_network_copy" != *"Samsung TVs"* ]]; then
  echo "Local-network permission copy must tell people it controls Samsung TVs." >&2
  exit 1
fi

bonjour_services="$(plutil -extract NSBonjourServices json -o - "$info_plist" | ruby -rjson -e 'puts JSON.parse(STDIN.read).join(",")')"
if [[ "$bonjour_services" != "_samsungmsf._tcp" ]]; then
  echo "Bonjour declarations must contain only Samsung TV discovery." >&2
  exit 1
fi

if [[ "$(plutil -extract NSAppTransportSecurity.NSAllowsLocalNetworking raw -expect bool "$info_plist")" != "true" ]]; then
  echo "Local-only HTTP capability lookup must be declared explicitly." >&2
  exit 1
fi

./scripts/validate-no-arbitrary-loads.sh "$info_plist"

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

if [[ "$(plutil -extract method raw "$export_options")" != "app-store-connect" ]]; then
  echo "Export method must be app-store-connect." >&2
  exit 1
fi
if [[ "$(plutil -extract teamID raw "$export_options")" != "4T358A5S74" ]]; then
  echo "Export options use the wrong Apple team." >&2
  exit 1
fi
if [[ "$(plutil -extract manageAppVersionAndBuildNumber raw -expect bool "$export_options")" != "false" ]]; then
  echo "Release export must not silently change the reviewed build number." >&2
  exit 1
fi

METADATA_PATH="$metadata_path" ruby <<'RUBY'
require "uri"

path = ENV.fetch("METADATA_PATH")
limits = {
  "name.txt" => 30,
  "subtitle.txt" => 30,
  "promotional_text.txt" => 170,
  "description.txt" => 4_000,
  "keywords.txt" => 100,
  "review_notes.txt" => 4_000
}

limits.each do |filename, limit|
  value = File.read(File.join(path, filename), encoding: "UTF-8").strip
  measured = %w[keywords.txt review_notes.txt].include?(filename) ? value.bytesize : value.length
  abort "#{filename} is empty" if value.empty?
  abort "#{filename} exceeds #{limit}" if measured > limit
end

%w[support_url.txt marketing_url.txt privacy_url.txt privacy_choices_url.txt].each do |filename|
  value = File.read(File.join(path, filename), encoding: "UTF-8").strip
  begin
    uri = URI.parse(value)
  rescue URI::InvalidURIError
    abort "#{filename} must be a valid HTTPS URL with a host"
  end
  unless uri.is_a?(URI::HTTPS) && uri.host && !uri.host.empty?
    abort "#{filename} must be a valid HTTPS URL with a host"
  end
end
RUBY

if [[ -n "$archive_path" ]]; then
  [[ -d "$archive_path" ]] || { echo "Archive not found: $archive_path" >&2; exit 1; }
  application_path="$(plutil -extract ApplicationProperties.ApplicationPath raw "$archive_path/Info.plist")"
  archived_app="$archive_path/Products/$application_path"
  archived_info="$archived_app/Info.plist"
  [[ -d "$archived_app" ]] || { echo "Archived app not found: $archived_app" >&2; exit 1; }

  [[ "$(plutil -extract CFBundleIdentifier raw "$archived_info")" == "$(setting PRODUCT_BUNDLE_IDENTIFIER)" ]] || { echo "Archived bundle ID does not match." >&2; exit 1; }
  [[ "$(plutil -extract CFBundleShortVersionString raw "$archived_info")" == "$(setting MARKETING_VERSION)" ]] || { echo "Archived marketing version does not match." >&2; exit 1; }
  [[ "$(plutil -extract CFBundleVersion raw "$archived_info")" == "$(setting CURRENT_PROJECT_VERSION)" ]] || { echo "Archived build number does not match." >&2; exit 1; }
  [[ "$(plutil -extract DTSDKName raw "$archived_info")" == iphoneos26.* ]] || { echo "Archive was not built with the iOS 26 SDK." >&2; exit 1; }
  [[ -f "$archived_app/PrivacyInfo.xcprivacy" ]] || { echo "Archive is missing PrivacyInfo.xcprivacy." >&2; exit 1; }

  preflight_tmp="$(mktemp -d "${TMPDIR:-/tmp}/hafa-release-preflight.XXXXXX")"
  cleanup_preflight() { rm -rf -- "$preflight_tmp"; }
  trap cleanup_preflight EXIT
  codesign --verify --deep --strict "$archived_app"
  if [[ -f "$archived_app/embedded.mobileprovision" ]]; then
    security cms -D -i "$archived_app/embedded.mobileprovision" >"$preflight_tmp/profile.plist"
    profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$preflight_tmp/profile.plist")"
    if [[ "$profile_app_id" == "4T358A5S74.*" ]]; then
      echo "Notice: development-signed archive uses the team wildcard; the App Store export must prove the explicit app identifier."
    elif [[ "$profile_app_id" != "4T358A5S74.com.shimizutechnology.hafaremote" ]]; then
      echo "Provisioning profile app identifier does not match." >&2
      exit 1
    fi
  fi
fi

if [[ -n "$export_path" ]]; then
  [[ -d "$export_path" ]] || { echo "Export not found: $export_path" >&2; exit 1; }
  mapfile_supported=0
  if builtin help mapfile >/dev/null 2>&1; then mapfile_supported=1; fi
  if [[ "$mapfile_supported" == "1" ]]; then
    mapfile -t ipa_files < <(find "$export_path" -maxdepth 1 -type f -name '*.ipa')
  else
    ipa_files=()
    while IFS= read -r ipa; do ipa_files+=("$ipa"); done < <(find "$export_path" -maxdepth 1 -type f -name '*.ipa')
  fi
  [[ "${#ipa_files[@]}" == "1" ]] || { echo "Expected exactly one IPA in $export_path." >&2; exit 1; }
  unzip -tq "${ipa_files[0]}" >/dev/null

  export_tmp="$(mktemp -d "${TMPDIR:-/tmp}/hafa-release-export.XXXXXX")"
  cleanup_export() { rm -rf -- "$export_tmp"; }
  trap 'cleanup_export; [[ -z "${preflight_tmp:-}" ]] || cleanup_preflight' EXIT
  unzip -q "${ipa_files[0]}" -d "$export_tmp"
  exported_app="$(find "$export_tmp/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
  [[ -n "$exported_app" ]] || { echo "Exported app bundle is missing." >&2; exit 1; }
  exported_info="$exported_app/Info.plist"
  [[ "$(plutil -extract CFBundleIdentifier raw "$exported_info")" == "com.shimizutechnology.hafaremote" ]] || { echo "Exported bundle ID does not match." >&2; exit 1; }
  [[ "$(plutil -extract CFBundleShortVersionString raw "$exported_info")" == "1.0" ]] || { echo "Exported marketing version does not match." >&2; exit 1; }
  [[ "$(plutil -extract CFBundleVersion raw "$exported_info")" == "1" ]] || { echo "Exported build number does not match." >&2; exit 1; }
  [[ -f "$exported_app/PrivacyInfo.xcprivacy" ]] || { echo "Exported app is missing PrivacyInfo.xcprivacy." >&2; exit 1; }
  codesign --verify --deep --strict "$exported_app"
  codesign -d --entitlements :- "$exported_app" >"$export_tmp/entitlements.plist" 2>/dev/null
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :application-identifier' "$export_tmp/entitlements.plist")" == "4T358A5S74.com.shimizutechnology.hafaremote" ]] || { echo "Exported application identifier does not match." >&2; exit 1; }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :get-task-allow' "$export_tmp/entitlements.plist")" == "false" ]] || { echo "Exported app is debuggable." >&2; exit 1; }
fi

echo "iOS release preflight passed for Hafa Remote 1.0 (1) with Xcode $xcode_version / iOS SDK $sdk_version"
