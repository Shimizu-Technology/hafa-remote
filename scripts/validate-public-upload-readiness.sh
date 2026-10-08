#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
evidence="${1:-}"
export_path="${2:-}"
archive_path="${3:-}"
[[ -f "$evidence" && -d "$export_path" && -d "$archive_path" ]] || { echo 'Public upload requires the actual release-evidence receipt, validated export and archive.' >&2; exit 1; }
source_commit="$(git -C "$repo_root" rev-parse HEAD)"
source_tree="$(git -C "$repo_root" rev-parse HEAD^{tree})"
ruby -rjson -rdigest -rtime -r "$repo_root/scripts/archive-content-sha256" - "$evidence" "$export_path" "$archive_path" "$source_commit" "$source_tree" <<'RUBY'
def require_fact(value, message)
  abort message unless value
end
receipt_path, export_path, archive_path, source_commit, source_tree = ARGV
begin
  r = JSON.parse(File.read(receipt_path, encoding: "UTF-8"))
rescue JSON::ParserError, SystemCallError
  abort "Public release evidence is unreadable or invalid."
end
require_fact(r.is_a?(Hash), "Public release evidence must be a record.")
require_fact(r["schemaVersion"] == 1, "Unknown public release evidence schema.")
require_fact(r.values_at("appId", "bundleId", "version", "build", "audience") == ["6808899369", "com.shimizutechnology.hafaremote", "1.0", "9", "public"], "Public release evidence does not match this app/build/audience.")
require_fact(r["sourceCommit"] == source_commit && r["sourceTree"] == source_tree, "Public release evidence does not match the exact source commit/tree.")
ipas = Dir.glob(File.join(export_path, "*.ipa")).select { |path| File.file?(path) }
require_fact(ipas.length == 1, "Public release evidence requires exactly one validated IPA.")
require_fact(r["exportSHA256"] == Digest::SHA256.file(ipas.first).hexdigest, "Public release evidence does not match the validated IPA bytes.")
begin
  archive_digest = ArchiveContentDigest.sha256(archive_path)
rescue ArgumentError, SystemCallError
  abort "Public release archive content is invalid."
end
require_fact(r["archiveSHA256"] == archive_digest, "Public release evidence does not match the validated archive contents.")
def verified_time(record)
  return false unless record.is_a?(Hash) && record["verifiedAt"].is_a?(String)
  checked = Time.iso8601(record["verifiedAt"])
  now = Time.now
  checked <= now && now - checked <= 86_400
rescue ArgumentError
  false
end
policy = r["policy"]
require_fact(verified_time(policy) && policy["state"] == "LIVE" && policy["url"] == "https://shimizu-technology.com/hafa-remote/privacy" && policy["retentionText"].is_a?(String) && !policy["retentionText"].strip.empty?, "Public upload requires the verified live privacy policy and actual retention statement.")
privacy = r["privacy"]
types = %w[Name EmailAddress CustomerSupport ProductInteraction PerformanceData OtherDiagnosticData].sort
require_fact(verified_time(privacy) && privacy["state"] == "PUBLISHED" && privacy["types"].is_a?(Array) && privacy["types"].all? { |type| type.is_a?(String) } && privacy["types"].sort == types && privacy["linked"] == true && privacy["tracking"] == false && privacy["purposes"] == ["AppFunctionality"], "Public upload requires the actual published six-type privacy label matching the binary.")
store = r["store"]
require_fact(verified_time(store) && store["releaseType"] == "MANUAL", "Public upload requires verified manual release configuration.")
puts "Public upload receipt claims match source, validated archive and export; current live policy/privacy verification remains the owner's responsibility."
RUBY
