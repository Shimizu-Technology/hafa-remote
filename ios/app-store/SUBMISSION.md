# Hafa Remote submission source of truth

## Release identity

- Version: `1.0`
- TestFlight build: `2`
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

The localized metadata in `en-US/` is the checked-in source of truth. The support,
marketing, and privacy URLs are published at their checked-in production paths.
Verify those exact endpoints again before every public App Review submission.

## App privacy

Choose **Data Not Collected**. The app sends commands, typed text, and device
requests only between the user's iPhone and selected television on the local
network. Pairing credentials remain in Keychain, non-secret TV metadata remains
in SwiftData, and Shimizu Technology receives no data from the app.

Re-audit this answer if analytics, crash reporting beyond Apple's opt-in service,
a backend, advertising, support upload, or any new SDK is added.

## Internal TestFlight checklist

1. Pass `./scripts/gate.sh` on the exact release commit.
2. Pass `./scripts/ios-release-preflight.sh`.
3. Create the signed archive with `./scripts/ios-release.sh archive`.
4. Validate it with `./scripts/ios-release-preflight.sh --archive <path>`.
5. Export with `./scripts/ios-release.sh export <archive-path>`.
6. Validate the export with both `--archive` and `--export`.
7. Create or verify the App Store Connect record before upload.
8. Upload the exact validated build, wait for processing, answer export
   compliance, and add the owner as an internal tester.

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
- Current App Store screenshots and an offline reviewer demo are ready.
- App Privacy, age rating, content rights, contact, and trader answers are
  verified in App Store Connect by the owner.

Hafa Remote must be described as independent and unaffiliated. Never claim universal brand or
power-on support without device evidence.
