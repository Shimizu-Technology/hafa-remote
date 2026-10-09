#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

usage() {
  echo "Usage: $0 [--audience internal|public] archive [output.xcarchive] | export <archive.xcarchive> [output-directory] | upload <archive.xcarchive> <validated-export-directory> [upload-output-directory]" >&2
  exit 1
}

audience="internal"
configuration="Release"
scheme="HafaRemote"
export_options="ios/app-store/ExportOptions.plist"
if [[ "${1:-}" == "--audience" ]]; then
  audience="${2:-}"
  [[ "$audience" == internal || "$audience" == public ]] || usage
  shift 2
fi
if [[ "$audience" == public ]]; then
  configuration="ReleasePublic"
  scheme="HafaRemotePublic"
  export_options="ios/app-store/PublicExportOptions.plist"
fi

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
    ./scripts/ios-release-preflight.sh --audience "$audience"
    xcodebuild \
      -project HafaRemote.xcodeproj \
      -scheme "$scheme" \
      -configuration "$configuration" \
      -destination "generic/platform=iOS" \
      -archivePath "$archive_path" \
      -allowProvisioningUpdates \
      ${authentication_args[@]+"${authentication_args[@]}"} \
      archive \
      "CC=$repo_root/scripts/xcode-clang-probe.sh"
    ./scripts/ios-release-preflight.sh --audience "$audience" --archive "$archive_path"
    echo "Validated archive: $archive_path"
    ;;
  export)
    archive_path="${2:-}"
    [[ -n "$archive_path" ]] || usage
    export_path="${3:-$repo_root/build/AppStoreExport}"
    mkdir -p "$export_path"
    ./scripts/ios-release-preflight.sh --audience "$audience" --archive "$archive_path"
    xcodebuild \
      -exportArchive \
      -archivePath "$archive_path" \
      -exportPath "$export_path" \
      -exportOptionsPlist "$export_options" \
      -allowProvisioningUpdates \
      ${authentication_args[@]+"${authentication_args[@]}"}
    ./scripts/ios-release-preflight.sh --audience "$audience" --archive "$archive_path" --export "$export_path"
    echo "Validated App Store export: $export_path"
    ;;
  upload)
    archive_path="${2:-}"
    export_path="${3:-}"
    [[ -n "$archive_path" && -n "$export_path" ]] || usage
    default_upload_path="$repo_root/build/InternalUpload"
    if [[ "$audience" == public ]]; then default_upload_path="$repo_root/build/PublicUpload"; fi
    upload_path="${4:-$default_upload_path}"
    if [[ "$audience" == public ]]; then
      [[ -f "${HAFA_PUBLIC_RELEASE_EVIDENCE:-}" ]] || { echo "Public upload requires actual verified release evidence; preparation alone is insufficient." >&2; exit 1; }
      git diff --quiet && git diff --cached --quiet || { echo "Public upload source must be tracked clean." >&2; exit 1; }
    fi
    ./scripts/ios-release-preflight.sh --audience "$audience" --archive "$archive_path" --export "$export_path"
    if [[ "$audience" == public ]]; then
      ./scripts/validate-public-upload-readiness.sh "$HAFA_PUBLIC_RELEASE_EVIDENCE" "$export_path" "$archive_path"
      [[ -f "${HAFA_ASC_KEY_PATH:-}" && -n "${HAFA_ASC_KEY_ID:-}" && -n "${HAFA_ASC_ISSUER_ID:-}" ]] || {
        echo "Public IPA delivery requires the existing authorized App Store Connect API key parameters." >&2
        exit 1
      }
      ipa_path="$(ruby -e 'puts Dir.glob(File.join(ARGV.first, "*.ipa")).select { |path| File.file?(path) }.fetch(0)' "$export_path")"
      # Deliver these exact validated bytes; archive/export signing remains native Xcode.
      xcrun altool --upload-package "$ipa_path" \
        --api-key "$HAFA_ASC_KEY_ID" --api-issuer "$HAFA_ASC_ISSUER_ID" \
        --p8-file-path "$HAFA_ASC_KEY_PATH" --output-format json
      echo "Validated public IPA delivery completed; verify Apple processing and App Store eligibility separately."
      exit 0
    fi
    mkdir -p "$upload_path"
    upload_options="$upload_path/UploadOptions.plist"
    cp "$export_options" "$upload_options"
    plutil -replace destination -string upload "$upload_options"
    ./scripts/validate-export-options.sh "$upload_options" upload "$audience"
    # Xcode packages the same validated archive, preserving its build and explicitly selected audience.
    # Its delivery receipt is separate from the earlier local IPA's hash.
    xcodebuild \
      -exportArchive \
      -archivePath "$archive_path" \
      -exportPath "$upload_path" \
      -exportOptionsPlist "$upload_options" \
      -allowProvisioningUpdates \
      ${authentication_args[@]+"${authentication_args[@]}"}
    echo "Xcode upload completed; verify Apple processing and the selected audience separately."
    ;;
  *)
    usage
    ;;
esac
