# Hafa Remote submission source of truth

## Identity and audiences

- Version: `1.0`; app and embedded control extension share the reviewed build number.
- Source build: `8`, already delivered as **Internal Only** TestFlight. It is used, not an unused public candidate.
- Public candidate: HR-051 selects the next number only after a fresh authenticated build **and upload** inventory check. An earlier observation that `9` was unused is not a reservation or current proof.
- App Store Connect Apple ID: `6808899369`; SKU: `hafa-remote-ios`.
- App bundle ID: `com.shimizutechnology.hafaremote`; control extension: `com.shimizutechnology.hafaremote.controls`.
- Apple team: `4T358A5S74`; minimum OS: iOS 18.4; iPhone only.
- Category: Utilities; price: Free; no in-app purchases or subscriptions. Root saved and API-verified the current age declaration as 4+, with all relevant answers false/NONE; future questionnaire changes require another verification.
- Copyright: `2026 Shimizu Technology`; release: Manual after Apple approval.
- No app account, backend, advertising, tracking or subscription; standard local TLS is declared as no non-exempt encryption, subject to final artifact verification.

| Audience | Scheme / archive configuration | Metadata | Packaging |
| --- | --- | --- | --- |
| Public Samsung | `HafaRemotePublic` / `ReleasePublic` | `public/en-US/` | `PublicExportOptions.plist`, Internal Only **false** |
| Internal three-brand testing | `HafaRemote` / `Release` | `en-US/` | `ExportOptions.plist`, Internal Only **true** |

The public source excludes Sony/Vizio protocols, accepts Samsung only and retains experimental saved records/credentials without using or deleting them. Manufacturer names describe compatibility; artwork and identity are original. Hafa Remote is independent and unaffiliated.

## Current scoped decision

Leon confirmed testing **1.0 (8) on Samsung Q70AA**, reported almost all Samsung controls working, and instructed the project to prepare the listing and submit. Firmware, exact unconfirmed controls, command counts and reconnect/wake measurements were not supplied. The report does not certify every feature or the future public artifact.

[HR-050's decision](../../docs/HR-050-SAMSUNG-SUBMISSION-DECISION.md) explicitly replaces the earlier broad project matrix and blanket qualified-basis prerequisite for this initial owner-directed Samsung submission. Historical 500-command/99%, twenty-cycle and multi-model/network targets are not marked achieved. No manufacturer permission, legal clearance, universal compatibility or guaranteed wake is inferred. Applicable terms/rights and any Apple request remain the publisher's responsibility.

`public/en-US/` contains the coordinated final public description, subtitle, keywords, promotional text, review notes and URLs. Internal instructions remain separate. Public screenshots must match the public interface and label simulated scenes; an offline demo is not hardware proof. Do not call a proposed recording a completed App Review video.

## Privacy and support

Ordinary control sends commands, text and requests only between the iPhone and selected TV on the local network. Pairing credentials stay in Keychain; TV metadata/preferences stay on the phone. There is no automatic report upload or backend.

Diagnostics are off by default. When enabled, at most 100 semantic events and coarse timings remain in memory. An immutable preview includes app/iOS versions and optional TV model/firmware, but excludes addresses, credentials, device identifiers, TV/Wi-Fi names and entered text. The user chooses whether and where to share through the system share sheet. Support can receive that report and accompanying message/contact details if chosen as the destination.

The owner selected retained voluntary support reports with a defined retention period; the published website policy is the source of truth for its actual duration and deletion handling. These facts remain a website/public-submission gate, not an invented source constant. The coordinated disclosure covers sender name/email, customer-support content, semantic interaction events, coarse performance timing and other diagnostic metadata, linked only through the chosen support context, for App Functionality and never tracking. The main app manifest declares exactly those six types; the stateless extension declares none. Root configured and verified the App Store Connect draft with exactly these six types, each used only for App Functionality, linked to identity in the support context, and not used for tracking. The draft is not yet published; publication requires the truthful production privacy policy. The final published label must still be verified before submission. Do not invent a period or retain **Data Not Collected** solely because sharing is voluntary. Evaluate actual retained support/contact/diagnostic data, purpose and linkage. Apple's optional-disclosure conditions must all apply; this interface is not presumed to qualify. Apple's own platform collection is separate. [Apple App Privacy details](https://developer.apple.com/app-store/app-privacy-details/) were checked October 9, 2026 (Guam).

## Public candidate and submission checklist — HR-051

1. Finish HR-050's coordinated source packet, factual support/privacy pages, owner handling decision and screenshots. Verify the live support/privacy URLs and actual App Store Connect answers; do not replace unknown facts with flags.
2. Verify the next unused build in the correct app's build and upload inventories. If a native export creates an awaiting-upload reservation, prove it belongs to this exact task/artifact before resuming it; never bump blindly or upload a historical archive.
3. Update the app, extension and preflight together. Pass the complete current-commit gate, affected native QA, current CodeRabbit coverage and hosted CI; resolve material findings and merge the release ticket.
4. Recheck the exact merged release source and audience. Use `./scripts/ios-release-preflight.sh --audience public`, then `./scripts/ios-release.sh --audience public archive <archive-path>`. Automatic signing must actually be attempted with the existing authorized account; absence of a local certificate alone is not a proven blocker.
5. Validate the archive with `--audience public --archive <archive-path>`, export with `--audience public export`, then validate the exact archive and export together. Match bundle/build/team, signatures, entitlements, privacy declarations, public audience and experimental exclusion. App Store packaging must not have Internal Only enabled.
6. After HR-051 explicitly satisfies the recorded eligibility conditions, upload the same validated archive/export through native tools. Public upload remains closed in HR-050; neither owner authorization alone nor a flavor switch is an artifact receipt.
7. Wait for processing and verify the current build is valid and App Store eligible. Complete the selected-build, localized packet/screenshots, privacy, age, rights, contact, territories and export-compliance fields. Keep release manual after approval.
8. Submit the exact selected processed build only when those facts are verified. Retain the actual submission receipt/state; an upload, screenshot save or success-looking API request does not prove review submission or approval. Respond to any review request/rejection with a focused evidence-backed task.

## Internal delivery and credential safeguards

Existing internal TestFlight 1.0 (8) is available through Leon's existing internal group; no current phone installation is implied. Any later internal delivery also needs a new live unused-number check, exact merged source/artifact validation and verified recipient scope. Never reuse build `8` as if it were unused. Default commands select internal; public delivery must pass the explicit public audience and eligibility checks.

Existing API authentication uses `HAFA_ASC_KEY_PATH`, `HAFA_ASC_KEY_ID` and `HAFA_ASC_ISSUER_ID` together. Keep keys private outside Git and never print keys/JWTs. Use only existing authorized credentials; do not create/rotate keys, certificates or access grants. Preserve provenance and processing/submission receipts privately. No external outreach is part of this checklist.
