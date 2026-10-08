# Hafa Remote submission source of truth

## Release identity

- Version: `1.0`
- Source build: `8`; authenticated App Store Connect build and upload inventories confirmed version 1.0 builds 1–7 already used. Recheck immediately before upload.
- App Store Connect Apple ID: `6808899369`
- SKU: `hafa-remote-ios`
- Bundle ID: `com.shimizutechnology.hafaremote`
- Apple team: `4T358A5S74`
- Minimum OS: iOS 18.4
- Platforms: iPhone only
- Category: Utilities
- Price: Free; no in-app purchases or subscriptions
- Copyright: `2026 Shimizu Technology`
- Release: Manual
- Account/backend/ads/tracking: None
- Export compliance: No non-exempt encryption

The localized metadata in `en-US/` prepares the next integrated internal candidate,
including HR-045 conveniences and HR-046 support/demo. Reconcile it against the
final merged binary before upload. These notes do not certify household hardware
or approve public submission. The support and privacy URLs responded successfully
on October 8, 2026 (Guam), but their deployed wording still needs reconciliation
with voluntary diagnostic sharing; see [release QA evidence](../../docs/HR-047-RELEASE-QA.md).

## App privacy

Ordinary control sends commands, text, and requests only between the iPhone and
selected TV on the local network. Pairing credentials remain in Keychain;
non-secret TV metadata and per-TV preferences stay on the phone. There is no
backend or automatic diagnostic upload.

Diagnostics are off by default. When enabled, at most 100 semantic events and
coarse timings remain in memory. A preview includes app/iOS versions and optional
model/firmware, excluding addresses, credentials, identifiers, TV/Wi-Fi names, and
entered text. The system share sheet sends the immutable preview only to a
destination the user chooses. If that destination is Shimizu Technology support,
support may receive the report and accompanying message/contact details. Do not
say that Shimizu can never receive data from the app.

**App Privacy answers remain an owner verification gate.** On-device processing
alone is not collection under Apple's definition, but retained support reports
must be evaluated separately. Choosing to share does not by itself establish the
optional-disclosure exception: all of Apple's conditions must apply, including
the submission-interface conditions. Check actual support receipt/retention,
data types (such as Customer Support and diagnostic data), purpose, and linkage
against the final binary before retaining or changing a **Data Not Collected**
answer. Apple's opt-in operating-system/TestFlight handling is separate from any
data the developer receives. No App Store Connect answer is changed by this file.

Sources checked October 8, 2026 (Guam):
[Apple App Privacy details](https://developer.apple.com/app-store/app-privacy-details/)
and [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy).

## Internal TestFlight checklist

1. Pass `./scripts/gate.sh` on the exact release commit.
2. Pass `./scripts/ios-release-preflight.sh`.
3. Create the signed archive with `./scripts/ios-release.sh archive`.
4. Validate it with `./scripts/ios-release-preflight.sh --archive <path>`.
5. Export with `./scripts/ios-release.sh export <archive-path>`.
6. Validate the export with both `--archive` and `--export`.
7. Recheck that build `8` is still unused in the correct App Store Connect record
   and that only Leon receives internal builds. Match both app and extension
   identities/build numbers to the reviewed commit and validated artifacts.
8. Upload the same validated archive with `./scripts/ios-release.sh upload <archive-path> <validated-export-path> <upload-output-path>`.
   Xcode packages it with the reviewed build number and TestFlight Internal Only
   option; its receipt is separate from the earlier local IPA hash. Wait for
   processing, verify export compliance, and confirm the processed build is
   available to Leon through his existing internal group without new invitations.

## Public-review gates

Do not submit for external TestFlight or public review until all of these are
complete:

- Shimizu Technology has documented an authorization basis for distributing each Samsung, Sony,
  and Vizio local-control integration, or a qualified attorney has documented why the planned use
  is permitted.
- The household Samsung Q70AA, Sony, and Vizio pairing, command, relaunch, text-capability, and
  power evidence is complete.
- Testing covers the advertised model/firmware range across several home networks.
- Each advertised model group passes a 500-command soak with at least 99% observed delivery, zero
  duplicate commands, and no stuck repeat state.
- Each advertised model group passes at least 20 foreground reconnect cycles, with at least 19
  reconnecting without re-pairing and normally within two seconds on healthy Wi-Fi.
- Support and privacy pages are live at the exact metadata URLs.
- Current screenshots match the final binary; the Release offline demo is reachable
  through first-launch Help → Try the Remote Offline and is verified without TV contact.
- App Privacy, age rating, content rights, contact, and trader answers are
  verified in App Store Connect by the owner.

Hafa Remote must be described as independent and unaffiliated. Never claim universal brand or
power-on support without device evidence.

## Build 8 delivery safeguards

The existing internal group has one tester, Leon, and no external group. Verify
that scope again before upload. Export and upload options enforce the Apple team,
automatic signing, internal-only distribution and unchanged build numbering.
Optional existing API authentication uses `HAFA_ASC_KEY_PATH`, `HAFA_ASC_KEY_ID`
and `HAFA_ASC_ISSUER_ID` together. Keep key files private outside this repository;
never commit or print keys or JWTs. Archive/export is not an upload receipt, and
an upload is not proof of successful processing or owner availability.
