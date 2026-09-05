# Hafa Remote

Hafa Remote is a native iPhone remote for compatible smart TVs on the same local network. Samsung is implemented; Sony and Vizio household support is in active development. The product is intentionally local-first: no account, backend, advertising, tracking, or subscription.

## Status

The native SwiftUI personal alpha includes secure Samsung pairing, automatic nearby-TV discovery, connection recovery, the complete MVP remote, text entry, persistence, conditional Wake-on-LAN for saved Wi-Fi TVs, and release checks. The current implementation is being generalized into one automatic Add TV flow before Sony and Vizio control are enabled. Manual IP entry remains available only as a troubleshooting fallback.

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

The repository is public so its hosted macOS workflow can run on pull requests without paid private-repository Actions minutes. GitHub's active `Protect Main` ruleset enforces pull-request-only changes and blocks force-pushes and branch deletion. Before merging, the maintainer separately verifies a passing hosted workflow, a passing local gate, exact-head CodeRabbit approval, and zero unresolved review threads.

## Distribution boundary

The local Samsung control protocol is not a published general-purpose consumer SDK. Personal development can proceed, but external TestFlight or App Store distribution requires the authorization gate documented in the PRD and build plan.
