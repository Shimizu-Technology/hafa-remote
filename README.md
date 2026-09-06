# Hafa Remote

Hafa Remote is a native iPhone remote for compatible Samsung, Sony, and Vizio smart TVs on the same local network. The product is intentionally local-first: no account, backend, advertising, tracking, or subscription.

## Status

The native SwiftUI personal alpha includes one automatic nearby-TV search, brand-specific secure pairing, saved-TV switching, connection recovery, everyday remote controls, text entry where supported, and power controls for saved TVs. Samsung wake uses a verified Wake-on-LAN target; Sony and Vizio use their local standby controls. Manual IP entry remains available only as a troubleshooting fallback.

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

Simulator checks prove interface and deterministic state behavior. Pairing, TV certificate trust, command delivery, and standby power behavior require a signed build on a physical iPhone and the target TV.

The repository is public so its hosted macOS workflow can run on pull requests without paid private-repository Actions minutes. GitHub's active `Protect Main` ruleset enforces pull-request-only changes and blocks force-pushes and branch deletion. Before merging, the maintainer separately verifies a passing hosted workflow, a passing local gate, exact-head CodeRabbit approval, and zero unresolved review threads.

## Distribution boundary

The app relies on local control interfaces whose third-party distribution basis and model compatibility vary by manufacturer. Internal household testing can proceed, but external TestFlight or public App Store submission remains behind the authorization, hardware, and reliability gates documented in the PRD and build plan.
