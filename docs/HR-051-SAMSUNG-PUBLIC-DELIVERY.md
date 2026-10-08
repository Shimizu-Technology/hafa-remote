# Samsung public candidate delivery

This ticket advances the reviewed source to Hafa Remote 1.0 (9), with matching app/control extension versions in both audiences. An authenticated read of Hafa's build and upload inventories at 2026-10-08T23:29:00Z showed only numbers 1–8; 9 was absent. That read authorizes this source selection, not a permanent reservation. Recheck before native packaging and again before upload. Existing Internal Only build 8 is separate and cannot serve as the new App Store candidate.

The owner explicitly authorized this Samsung submission. No additional generic permission is required. Source review, code/artifact integrity and truthful policy/store conditions remain necessary. The current source packet and owner-directed scope are documented in [HR-050](HR-050-SAMSUNG-SUBMISSION-DECISION.md); this ticket does not invent model, firmware, soak or legal-clearance evidence.

## Source and native phases

Run the complete current-commit gate for internal and public audiences, current source review and hosted CI; resolve material findings and merge. Archive/export from that exact merged source using `--audience public`, automatic signing and only existing authorized credentials. Native signing must actually be attempted. Keep private keys, JWTs and protected signing/delivery logs outside Git and tool output.

The archive/export preflight retains iPhone/iOS 18.4, current iOS 26 SDK, Samsung-only compiled flavor and service/source/binary checks, correct app/control/team/build identities, reviewed privacy declarations, strict signatures/provisioning and nondebuggable distribution export. Public packaging has Internal Only false; internal packaging remains true. No new app runtime behavior, SDK, recipient or outreach is introduced.

Archive/export may proceed while the external support-period decision and website publication wait. Export can create an awaiting-upload entry in App Store Connect: prove its exact native delivery provenance before resuming that same number. Do not blindly bump, duplicate an upload, or substitute an old archive. Archive/export success is not an upload or processing receipt.

## Public upload factual receipt

`HAFA_PUBLIC_RELEASE_EVIDENCE` names a private, reviewable JSON receipt assembled from actual owner-verified live policy/privacy/store facts and the current artifact. It is not an override switch or a new permission request. `ios-release.sh --audience public upload` first rejects missing evidence or dirty tracked source, then runs strict archive/export preflight and validates the receipt before invoking native upload.

Required schema version 1 (verification timestamps must be no more than 24 hours old and must not be in the future):

- Identity: appId `6808899369`, bundleId `com.shimizutechnology.hafaremote`, version `1.0`, build `9`, audience `public`.
- `sourceCommit` and `sourceTree`: exact merged checkout; `exportSHA256`: SHA256 of the single validated IPA in the export directory; `archiveSHA256`: deterministic content fingerprint from `scripts/archive-content-sha256.rb <archive>`. It includes all relative paths, file kinds/modes, file bytes and internal symlink targets, rejects external link dependencies, and excludes only timestamps/absolute output locations. No archive content or private values are printed; receipts remain private.
- `policy`: state `LIVE`, the source privacy URL, ISO `verifiedAt`, and nonempty `retentionText` recording the actual published policy. The website is the duration source of truth; no fixed number is invented here.
- `privacy`: state `PUBLISHED`, ISO `verifiedAt`, the exact six categories Name/EmailAddress/CustomerSupport/ProductInteraction/PerformanceData/OtherDiagnosticData, linked true for voluntary support, tracking false, and purposes exactly `["AppFunctionality"]`.
- `store`: ISO `verifiedAt` and releaseType `MANUAL`.

The helper validates receipt claims and source/artifact binding; it does not contact the website or App Store Connect or authenticate an arbitrary JSON record. Root generates the receipt from actual live checks, with private supporting API/UI/policy receipts. The 24-hour bound only rejects stale/future records; Root still repeats the live checks immediately before upload. A syntactically valid file is not permission to fabricate those facts. Root must verify the current live policy and published privacy label immediately before delivery. Tests use clearly synthetic exports/statements solely to exercise this boundary, never as upload evidence. Missing/draft policy or privacy, wrong source/tree/build/audience/archive/export, changed types/linkage/purposes/tracking or automatic release are rejected.

## Processing and submission

Do not mutate the archive/export between validation and native upload. Upload the same validated merged archive/export only after those factual conditions are met. Preserve native upload and owned-reservation receipts privately. Wait for the current build to become valid and App Store eligible; an Internal Only, awaiting-upload or processing entry is insufficient. Root owns final App Store Connect selected-build/listing/contact/age/rights/territory checks and actual submission, with manual release after approval. Do not describe an uploaded file or saved screenshot as submitted, approved, published or installed on the phone.
