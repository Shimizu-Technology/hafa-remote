# Hafa Remote

Hafa Remote is a native iPhone remote for compatible Samsung, Sony, and Vizio smart TVs on the same local network. The product is intentionally local-first: no account, backend, advertising, tracking, or subscription.

## Status

The native SwiftUI personal alpha includes automatic nearby-TV search, brand-specific secure pairing, saved-TV switching, connection recovery, capability-driven controls, and a Control Center/Lock Screen/Action Button launcher for the remembered remote. Samsung wake uses a verified Wake-on-LAN target; Sony and Vizio use their local standby controls. Manual IP entry remains available only as a troubleshooting fallback.

## Documents

- [Product requirements](PRD.md)
- [Build plan](BUILD_PLAN.md)

## Intended stack

- SwiftUI
- WidgetKit and App Intents for the stateless system launcher
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

The gate and archive use `scripts/xcode-clang-probe.sh` for Xcode's compiler discovery. It runs the selected Apple clang with unchanged arguments, captures only the verbose preprocessing/macro probe, and replays its outputs without Xcode's sequential-pipe deadlock. Ordinary compilation and linking execute clang directly. `scripts/test-xcode-clang-probe.sh` verifies large-output draining, argument forwarding, and exit-status preservation.

Simulator gate products use ad hoc code signing and verify the bundle seal before the install/launch smoke check. This needs no distribution credential and avoids leaving modern simulator runtimes with an executable signature but an unsigned resource bundle. Device archives continue to use the configured Apple team and provisioning profile.

The approved October improvement tickets and their release boundaries are in [the App Store readiness plan](docs/APP-STORE-READINESS-PLAN.md).

The repository is public so its hosted macOS workflow can run on pull requests without paid private-repository Actions minutes. GitHub's active `Protect Main` ruleset enforces pull-request-only changes and blocks force-pushes and branch deletion. Before merging, the maintainer separately verifies a passing hosted workflow, a passing local gate, CodeRabbit review of the current head with a passing status, and review threads resolved after fixes or evidence-backed replies. Material findings remain blockers even after several review rounds.

## Distribution boundary

The app relies on local control interfaces whose third-party distribution basis and model compatibility vary by manufacturer. Internal household testing can proceed, but external TestFlight or public App Store submission remains behind the authorization, hardware, and reliability gates documented in the PRD and build plan.
