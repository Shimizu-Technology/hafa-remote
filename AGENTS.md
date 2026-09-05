# AGENTS.md — Hafa Remote

## Product

Hafa Remote is an iPhone-only, local-network remote. The shipped internal alpha supports compatible Samsung Tizen TVs; Sony BRAVIA/Google TV and Vizio SmartCast support must remain separately capability-gated until each household TV passes its hardware matrix. Version one has no backend, account, cloud sync, advertising, tracking, or subscription.

Read `PRD.md` and `BUILD_PLAN.md` before implementation. Implement only the current ticket and its acceptance criteria.

## Architecture rules

- Use SwiftUI and Swift 6 concurrency.
- Keep every brand's protocol details behind `TVDriver` and its own protocol module.
- Scope saved identity and credentials by brand plus stable device identifier; an address alone is never identity.
- Do not let one brand's driver read, reuse, or delete another brand's credential.
- UI code sends semantic `RemoteCommand` values; it never sends Samsung key strings.
- One actor owns each mutable network session and serialized command stream.
- A remembered IP is a cache, not stable TV identity.
- Pairing tokens live only in Keychain.
- Do not add third-party runtime dependencies without a documented decision.
- Do not add a backend, analytics, tracking, account, ad, or payment SDK.
- Never globally bypass TLS validation or enable arbitrary network loads.
- Never include factory, service-menu, hospitality, reset, or undocumented destructive keys.
- Do not claim a command succeeded when the protocol provides no acknowledgement.
- Do not claim universal Samsung support or guaranteed power-on.

## Interface rules

- Optimize for immediate one-handed control and truthful connection recovery.
- Use Apple-native symbols or original vector artwork; no emoji UI.
- Interactive targets are at least 44 by 44 points.
- Every control needs a useful VoiceOver label and pressed/disabled state.
- Support Dynamic Type, dark mode, increased contrast, and Reduce Motion.
- Color is never the only indication of connection state.
- Do not use Samsung logos or copy a physical Samsung remote's trade dress.

## Privacy and logging

- Commands and device records stay on the phone and local network.
- Redact IPs, MAC addresses, tokens, device identifiers, Wi-Fi names, and entered text from logs and diagnostic exports.
- Test fixtures may contain only clearly synthetic identifiers and RFC 5737 documentation addresses.
- No household address, MAC, pairing token, certificate, or device identifier may enter Git history, screenshots, CI logs, or PR text.

## Development lifecycle

- Record the simulator/device baseline before testing.
- Claim an exact simulator UDID if this session boots it; shut down only that owned simulator.
- Treat physical iPhones and TVs as borrowed hardware; never reset or unpair unrelated apps/devices.
- Clean only resources started by the current session.
- No server, container, or persistent local service is required.

## Git and review

- Default branch: `main`.
- Use one worktree and branch per independently writable ticket.
- Branch names: `feature/HR-NNN-short-description` or `fix/HR-NNN-short-description`.
- Commit titles: `HR-NNN: concise imperative description`.
- PRs must include intent, acceptance criteria, gate output, hardware evidence when applicable, visual evidence for UI changes, privacy/security impact, and resource cleanup status.
- CodeRabbit is an additional reviewer. Resolve every actionable finding, rerun the complete gate, and obtain a current-head clean review before merging.
- Do not push, open a PR, merge, upload to TestFlight, or change App Store Connect unless Leon has authorized it. Leon authorized those actions for the initial full delivery request on September 4, 2026.

## Completion gate

`./scripts/gate.sh` is the single code-level gate once introduced. A ticket is not complete unless:

- the full gate passes on the current commit;
- affected simulator flows were exercised;
- physical-TV behavior was tested when the ticket depends on it;
- the diff matches the PRD and ticket without widening scope;
- CodeRabbit has no unresolved actionable finding on the current PR head;
- owned development resources were cleaned or explicitly handed off.
