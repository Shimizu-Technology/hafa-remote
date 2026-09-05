# Hafa Remote

Hafa Remote is a native iPhone remote for compatible Samsung Tizen TVs on the same local network. The product is intentionally local-first: no account, backend, advertising, tracking, or subscription.

## Status

The native SwiftUI personal alpha includes secure Samsung pairing, automatic nearby-TV discovery, connection recovery, the complete MVP remote, text entry, persistence, conditional Wake-on-LAN for saved Wi-Fi TVs, and release checks. Manual IP entry remains available only as a troubleshooting fallback. Physical Q70AA wake acceptance and internal TestFlight delivery are the active release gates.

## Documents

- [Product requirements](PRD.md)
- [Build plan](BUILD_PLAN.md)

## Intended stack

- SwiftUI
- Swift 6
- Network.framework and Security.framework
- SwiftData for non-secret device metadata
- Keychain Services for pairing credentials
- Swift Testing/XCTest and XCUITest

## Verification

The canonical verification command is:

```bash
./scripts/gate.sh
```

Simulator checks prove interface and deterministic state behavior. Pairing, TV certificate trust, command delivery, and power behavior require a physical iPhone and Samsung TV.

The repository is public so its hosted macOS workflow can run on pull requests without paid private-repository Actions minutes. `main` is protected by the same active `Protect Main` ruleset used across Shimizu Technology: changes require a pull request and cannot force-push or delete the branch. Every PR must record a passing local gate and an exact-head CodeRabbit approval before merge.

## Distribution boundary

The local Samsung control protocol is not a published general-purpose consumer SDK. Personal development can proceed, but external TestFlight or App Store distribution requires the authorization gate documented in the PRD and build plan.
