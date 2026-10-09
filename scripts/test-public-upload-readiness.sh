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
# Exercise the real public command path with isolated external-tool stubs only.
# The real signed preflight has its own suite; no fixture calls Apple or carries a credential.
rm "$fixture_dir/export/Other.ipa"
harness="$fixture_dir/command-harness"
mkdir -p "$harness/scripts" "$harness/bin"
cp "$repo_root/scripts/ios-release.sh" "$repo_root/scripts/validate-public-upload-readiness.sh" "$repo_root/scripts/archive-content-sha256.rb" "$harness/scripts/"
cat > "$harness/scripts/ios-release-preflight.sh" <<'SH'
#!/usr/bin/env bash
printf 'preflight\n' >> "$HR_FIXTURE_ORDER"
if [[ "${HR_FIXTURE_PREFLIGHT_FAIL:-0}" == 1 ]]; then echo 'Synthetic signed preflight rejected.' >&2; exit 1; fi
SH
cat > "$harness/bin/git" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == -C ]]; then shift 2; fi
case "${1:-}" in
  diff) [[ "${HR_FIXTURE_DIRTY:-0}" == 0 ]] ;;
  rev-parse)
    if [[ "${2:-}" == HEAD ]]; then printf '%s\n' "$HR_FIXTURE_COMMIT"; else printf '%s\n' "$HR_FIXTURE_TREE"; fi ;;
  *) exit 1 ;;
esac
SH
cat > "$harness/bin/xcrun" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == --sdk && "${2:-}" == macosx && "${3:-}" == --show-sdk-path ]]; then exec /usr/bin/xcrun "$@"; fi
[[ "${1:-}" == altool ]] || { echo 'Unexpected native fixture command.' >&2; exit 1; }
printf 'native\n' >> "$HR_FIXTURE_ORDER"
printf '%s\0' "$@" > "$HR_FIXTURE_NATIVE_ARGS"
SH
# Bypass local Ruby version-manager startup, which probes xcrun before running Ruby.
ln -s /usr/bin/ruby "$harness/bin/ruby"
chmod +x "$harness/scripts/ios-release-preflight.sh" "$harness/bin/git" "$harness/bin/xcrun"
export HR_FIXTURE_COMMIT="$(git -C "$repo_root" rev-parse HEAD)"
export HR_FIXTURE_TREE="$(git -C "$repo_root" rev-parse HEAD^{tree})"
export HR_FIXTURE_ORDER="$fixture_dir/order.log" HR_FIXTURE_NATIVE_ARGS="$fixture_dir/native-args.json"
printf 'Synthetic auth fixture; not a private key.\n' > "$fixture_dir/SyntheticAuth.p8"
run_public_command() {
  PATH="$harness/bin:$PATH" HAFA_PUBLIC_RELEASE_EVIDENCE="$fixture_dir/${1:-valid}.json" \
    HAFA_ASC_KEY_PATH="$fixture_dir/SyntheticAuth.p8" HAFA_ASC_KEY_ID=synthetic-key HAFA_ASC_ISSUER_ID=synthetic-issuer \
    "$harness/scripts/ios-release.sh" --audience public upload "$fixture_dir/archive" "$fixture_dir/export" "$fixture_dir/unused-upload-directory"
}
run_public_command valid
ruby -rjson - "$fixture_dir" <<'RUBY'
folder = ARGV.first
actual = File.binread(File.join(folder, "native-args.json")).split("\0")
expected = ["altool", "--upload-package", File.join(folder, "export", "Synthetic.ipa"), "--api-key", "synthetic-key", "--api-issuer", "synthetic-issuer", "--p8-file-path", File.join(folder, "SyntheticAuth.p8"), "--output-format", "json"]
abort "Public delivery did not consume the exact receipt-validated IPA." unless actual == expected
abort "Public delivery did not run signed preflight first." unless File.read(File.join(folder, "order.log")) == "preflight\nnative\n"
abort "Public delivery unexpectedly created an Xcode re-export." if File.exist?(File.join(folder, "unused-upload-directory"))
RUBY
expect_command_rejection() {
  local name="$1" expected="$2"
  rm -f "$HR_FIXTURE_ORDER" "$HR_FIXTURE_NATIVE_ARGS"
  if run_public_command "$name" > "$fixture_dir/command-rejection.log" 2>&1; then echo "Unsafe public command accepted: $name" >&2; exit 1; fi
  if ! grep -Fq -- "$expected" "$fixture_dir/command-rejection.log"; then cat "$fixture_dir/command-rejection.log" >&2; exit 1; fi
  if [[ -f "$HR_FIXTURE_NATIVE_ARGS" ]]; then echo 'Rejected public command reached native delivery.' >&2; exit 1; fi
}
expect_command_rejection draft-policy 'verified live privacy policy and actual retention statement'
expect_command_rejection wrong-artifact 'does not match the validated IPA bytes'
expect_command_rejection wrong-archive 'does not match the validated archive contents'
HR_FIXTURE_PREFLIGHT_FAIL=1 expect_command_rejection valid 'Synthetic signed preflight rejected.'
HR_FIXTURE_DIRTY=1 expect_command_rejection valid 'Public upload source must be tracked clean.'
rm "$fixture_dir/SyntheticAuth.p8"
expect_command_rejection valid 'All three existing App Store Connect key parameters are required.'
echo 'Public upload source/artifact/policy/privacy evidence and exact-IPA command fixtures passed.'
