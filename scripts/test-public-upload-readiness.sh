#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/hafa-public-upload-fixtures.XXXXXX")"
trap 'rm -rf -- "$fixture_dir"' EXIT
mkdir "$fixture_dir/export" "$fixture_dir/archive"
printf 'Synthetic archive payload.\n' > "$fixture_dir/archive/Application"
printf 'Synthetic validated-export bytes; never a shippable artifact.\n' > "$fixture_dir/export/Synthetic.ipa"
# This tests the factual-receipt boundary only; production first runs strict signed artifact preflight.
ruby -rjson -rdigest -rtime -r "$repo_root/scripts/archive-content-sha256" - "$fixture_dir" "$repo_root" <<'RUBY'
folder, repo = ARGV
commit = IO.popen(["git", "-C", repo, "rev-parse", "HEAD"], &:read).strip
tree = IO.popen(["git", "-C", repo, "rev-parse", "HEAD^{tree}"], &:read).strip
now = Time.now.utc.iso8601
receipt = {
  "schemaVersion" => 1, "appId" => "6808899369", "bundleId" => "com.shimizutechnology.hafaremote", "version" => "1.0", "build" => "9", "audience" => "public", "sourceCommit" => commit, "sourceTree" => tree,
  "exportSHA256" => Digest::SHA256.file(File.join(folder, "export", "Synthetic.ipa")).hexdigest,
  "archiveSHA256" => ArchiveContentDigest.sha256(File.join(folder, "archive")),
  "policy" => {"state" => "LIVE", "url" => "https://shimizu-technology.com/hafa-remote/privacy", "verifiedAt" => now, "retentionText" => "Synthetic fixture policy statement; not a real owner period."},
  "privacy" => {"state" => "PUBLISHED", "types" => %w[Name EmailAddress CustomerSupport ProductInteraction PerformanceData OtherDiagnosticData], "linked" => true, "tracking" => false, "purposes" => ["AppFunctionality"], "verifiedAt" => now},
  "store" => {"releaseType" => "MANUAL", "verifiedAt" => now}
}
# Fingerprint is location/timestamp independent but binds every path, byte and link target.
archive = File.join(folder, "archive")
original = ArchiveContentDigest.sha256(archive)
File.utime(Time.now - 3600, Time.now - 3600, File.join(archive, "Application"))
abort "Archive fingerprint incorrectly includes timestamps." unless ArchiveContentDigest.sha256(archive) == original
File.chmod(0o755, File.join(archive, "Application"))
abort "Archive fingerprint missed a permission change." if ArchiveContentDigest.sha256(archive) == original
File.chmod(0o644, File.join(archive, "Application"))
File.rename(File.join(archive, "Application"), File.join(archive, "Renamed"))
abort "Archive fingerprint missed a relative-path change." if ArchiveContentDigest.sha256(archive) == original
File.rename(File.join(archive, "Renamed"), File.join(archive, "Application"))
File.write(File.join(archive, "Secondary"), "Synthetic secondary payload.")
File.symlink("Application", File.join(archive, "Link"))
linked = ArchiveContentDigest.sha256(archive)
File.unlink(File.join(archive, "Link"))
File.symlink("Secondary", File.join(archive, "Link"))
abort "Archive fingerprint missed a symlink target change." if ArchiveContentDigest.sha256(archive) == linked
File.unlink(File.join(archive, "Link"))
File.symlink(File.join(folder, "export", "Synthetic.ipa"), File.join(archive, "Link"))
begin
  ArchiveContentDigest.sha256(archive)
  abort "Archive fingerprint accepted an external link dependency."
rescue ArgumentError
  # Expected: even a readable external file is not part of the archive content boundary.
end
File.unlink(File.join(archive, "Link"))
File.unlink(File.join(archive, "Secondary"))
abort "Archive fixture restoration changed payload." unless ArchiveContentDigest.sha256(archive) == original
File.write(File.join(folder, "valid.json"), JSON.generate(receipt))
mutations = {
  "wrong-app" => ->(r) { r["appId"] = "synthetic-other-app" },
  "wrong-build" => ->(r) { r["build"] = "8" },
  "wrong-audience" => ->(r) { r["audience"] = "internal" },
  "wrong-source" => ->(r) { r["sourceCommit"] = "0" * 40 },
  "wrong-tree" => ->(r) { r["sourceTree"] = "0" * 40 },
  "wrong-artifact" => ->(r) { r["exportSHA256"] = "0" * 64 },
  "wrong-archive" => ->(r) { r["archiveSHA256"] = "0" * 64 },
  "missing-policy" => ->(r) { r.delete("policy") },
  "draft-policy" => ->(r) { r["policy"]["state"] = "DRAFT" },
  "wrong-policy-url" => ->(r) { r["policy"]["url"] = "https://example.invalid/privacy" },
  "unknown-retention" => ->(r) { r["policy"]["retentionText"] = " " },
  "invalid-policy-time" => ->(r) { r["policy"]["verifiedAt"] = "unknown" },
  "stale-policy" => ->(r) { r["policy"]["verifiedAt"] = (Time.now.utc - 90_000).iso8601 },
  "future-policy" => ->(r) { r["policy"]["verifiedAt"] = (Time.now.utc + 3600).iso8601 },
  "draft-privacy" => ->(r) { r["privacy"]["state"] = "DRAFT" },
  "stale-privacy" => ->(r) { r["privacy"]["verifiedAt"] = (Time.now.utc - 90_000).iso8601 },
  "future-store" => ->(r) { r["store"]["verifiedAt"] = (Time.now.utc + 3600).iso8601 },
  "missing-type" => ->(r) { r["privacy"]["types"].pop },
  "extra-type" => ->(r) { r["privacy"]["types"] << "DeviceID" },
  "tracking" => ->(r) { r["privacy"]["tracking"] = true },
  "tracking-string" => ->(r) { r["privacy"]["tracking"] = "false" },
  "wrong-linkage" => ->(r) { r["privacy"]["linked"] = false },
  "analytics" => ->(r) { r["privacy"]["purposes"] << "Analytics" },
  "automatic-release" => ->(r) { r["store"]["releaseType"] = "AFTER_APPROVAL" },
  "missing-store" => ->(r) { r.delete("store") }
}
mutations.each { |name, mutate| r = JSON.parse(JSON.generate(receipt)); mutate.call(r); File.write(File.join(folder, "#{name}.json"), JSON.generate(r)) }
RUBY
validator="$repo_root/scripts/validate-public-upload-readiness.sh"
"$validator" "$fixture_dir/valid.json" "$fixture_dir/export" "$fixture_dir/archive"
expect_rejection() {
  local name="$1" expected="$2"
  if "$validator" "$fixture_dir/$name.json" "$fixture_dir/export" "$fixture_dir/archive" > "$fixture_dir/rejection.log" 2>&1; then
    echo "Unsafe public upload evidence accepted: $name" >&2
    exit 1
  fi
  if ! grep -Fq -- "$expected" "$fixture_dir/rejection.log"; then
    cat "$fixture_dir/rejection.log" >&2
    echo "Public upload fixture failed before its intended boundary: $name" >&2
    exit 1
  fi
}
for name in wrong-app wrong-build wrong-audience; do expect_rejection "$name" 'does not match this app/build/audience'; done
for name in wrong-source wrong-tree; do expect_rejection "$name" 'does not match the exact source commit/tree'; done
expect_rejection wrong-artifact 'does not match the validated IPA bytes'
expect_rejection wrong-archive 'does not match the validated archive contents'
for name in missing-policy draft-policy wrong-policy-url unknown-retention invalid-policy-time stale-policy future-policy; do expect_rejection "$name" 'verified live privacy policy and actual retention statement'; done
for name in draft-privacy stale-privacy missing-type extra-type tracking tracking-string wrong-linkage analytics; do expect_rejection "$name" 'actual published six-type privacy label matching the binary'; done
for name in automatic-release missing-store future-store; do expect_rejection "$name" 'verified manual release configuration'; done
printf '{invalid' > "$fixture_dir/invalid.json"
expect_rejection invalid 'unreadable or invalid'
expect_rejection missing 'actual release-evidence receipt, validated export and archive'
printf 'Changed archive with unchanged approved IPA.\n' > "$fixture_dir/archive/Application"
expect_rejection valid 'does not match the validated archive contents'
printf 'Synthetic archive payload.\n' > "$fixture_dir/archive/Application"
printf 'Second synthetic artifact.\n' > "$fixture_dir/export/Other.ipa"
expect_rejection valid 'exactly one validated IPA'
if output="$(HAFA_PUBLIC_RELEASE_EVIDENCE= "$repo_root/scripts/ios-release.sh" --audience public upload synthetic-archive synthetic-export 2>&1)"; then echo 'Public upload opened without factual evidence.' >&2; exit 1; fi
if [[ "$output" != *"Public upload requires actual verified release evidence"* ]]; then echo 'Public upload failed before its intended missing-evidence boundary.' >&2; exit 1; fi
echo 'Public upload source/artifact/policy/privacy evidence fixtures passed.'
