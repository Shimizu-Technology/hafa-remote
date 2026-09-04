# Hafa Remote

Hafa Remote is a native iPhone remote for compatible Samsung Tizen TVs on the same local network. The product is intentionally local-first: no account, backend, advertising, tracking, or subscription.

## Status

The native SwiftUI foundation is in place. The next implementation milestone is a manual-IP proof against Leon's Samsung Q70AA before automatic discovery, Wake-on-LAN, or public distribution work begins.

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

## Distribution boundary

The local Samsung control protocol is not a published general-purpose consumer SDK. Personal development can proceed, but external TestFlight or App Store distribution requires the authorization gate documented in the PRD and build plan.
