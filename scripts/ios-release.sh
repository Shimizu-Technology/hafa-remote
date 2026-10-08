#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

usage() {
  echo "Usage: $0 archive [output.xcarchive] | export <archive.xcarchive> [output-directory] | upload <archive.xcarchive> <validated-export-directory> [upload-output-directory]" >&2
  exit 1
}

authentication_args=()
if [[ -n "${HAFA_ASC_KEY_PATH:-}${HAFA_ASC_KEY_ID:-}${HAFA_ASC_ISSUER_ID:-}" ]]; then
  [[ -f "${HAFA_ASC_KEY_PATH:-}" && -n "${HAFA_ASC_KEY_ID:-}" && -n "${HAFA_ASC_ISSUER_ID:-}" ]] || {
    echo "All three existing App Store Connect key parameters are required." >&2
    exit 1
  }
  authentication_args=(
    -authenticationKeyPath "$HAFA_ASC_KEY_PATH"
    -authenticationKeyID "$HAFA_ASC_KEY_ID"
    -authenticationKeyIssuerID "$HAFA_ASC_ISSUER_ID"
  )
fi

command_name="${1:-}"
case "$command_name" in
  archive)
    archive_path="${2:-$repo_root/build/HafaRemote.xcarchive}"
    mkdir -p "$(dirname "$archive_path")"
    ./scripts/ios-release-preflight.sh
    xcodebuild \
      -project HafaRemote.xcodeproj \
      -scheme HafaRemote \
      -configuration Release \
      -destination "generic/platform=iOS" \
      -archivePath "$archive_path" \
      -allowProvisioningUpdates \
      ${authentication_args[@]+"${authentication_args[@]}"} \
      archive \
      "CC=$repo_root/scripts/xcode-clang-probe.sh"
    ./scripts/ios-release-preflight.sh --archive "$archive_path"
    echo "Validated archive: $archive_path"
    ;;
  export)
    archive_path="${2:-}"
    [[ -n "$archive_path" ]] || usage
    export_path="${3:-$repo_root/build/AppStoreExport}"
    mkdir -p "$export_path"
    ./scripts/ios-release-preflight.sh --archive "$archive_path"
    xcodebuild \
      -exportArchive \
      -archivePath "$archive_path" \
      -exportPath "$export_path" \
      -exportOptionsPlist ios/app-store/ExportOptions.plist \
      -allowProvisioningUpdates \
      ${authentication_args[@]+"${authentication_args[@]}"}
    ./scripts/ios-release-preflight.sh --archive "$archive_path" --export "$export_path"
    echo "Validated App Store export: $export_path"
    ;;
  upload)
    archive_path="${2:-}"
    export_path="${3:-}"
    [[ -n "$archive_path" && -n "$export_path" ]] || usage
    upload_path="${4:-$repo_root/build/InternalUpload}"
    ./scripts/ios-release-preflight.sh --archive "$archive_path" --export "$export_path"
    mkdir -p "$upload_path"
    upload_options="$upload_path/UploadOptions.plist"
    cp ios/app-store/ExportOptions.plist "$upload_options"
    plutil -replace destination -string upload "$upload_options"
    ./scripts/validate-export-options.sh "$upload_options" upload
    # Xcode packages the same validated archive, preserving its build and internal-only audience.
    # Its delivery receipt is separate from the earlier local IPA's hash.
    xcodebuild \
      -exportArchive \
      -archivePath "$archive_path" \
      -exportPath "$upload_path" \
      -exportOptionsPlist "$upload_options" \
      -allowProvisioningUpdates \
      ${authentication_args[@]+"${authentication_args[@]}"}
    echo "Xcode upload completed; verify Apple processing and owner availability separately."
    ;;
  *)
    usage
    ;;
esac
