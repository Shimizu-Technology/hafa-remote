#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

usage() {
  echo "Usage: $0 archive [output.xcarchive] | export <archive.xcarchive> [output-directory]" >&2
  exit 1
}

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
      archive
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
      -allowProvisioningUpdates
    ./scripts/ios-release-preflight.sh --archive "$archive_path" --export "$export_path"
    echo "Validated App Store export: $export_path"
    ;;
  *)
    usage
    ;;
esac
