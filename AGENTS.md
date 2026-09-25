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

- Follow the shared `local-dev-lifecycle` skill. Record the lifecycle session and simulator/device baseline before testing.
- Claim exact simulator UDIDs, browser tabs, processes, and containers started by this session. After each QA phase, close owned tabs with the browser tool and clean only claimed resources; verify lifecycle status.
- Treat physical iPhones and TVs as borrowed hardware; never reset or unpair unrelated apps/devices.
- No server, container, or persistent local service is required.
- A held PR keeps its named branch and worktree, but no QA resources run without an explicit resource handoff. After merge, remove only this task's clean worktree and merged branch. Never force-remove a dirty or borrowed worktree.

## Git and review

- Default branch: `main`.
- Use one worktree and branch per independently writable ticket.
- Ticket branch names: `feature/HR-NNN-short-description` or `fix/HR-NNN-short-description`. Use a descriptive `docs/` or `chore/` branch for unticketed maintenance.
- Ticket commit titles: `HR-NNN: concise imperative description`. Use a descriptive conventional title for unticketed maintenance.
- PRs must include intent, acceptance criteria, gate output, hardware evidence when applicable, visual evidence for UI changes, privacy/security impact, and resource cleanup status.
- Follow the shared `shimizu-pr-workflow` skill for implementation, QA, PR review, merge or hold, and cleanup. CodeRabbit is this repository's current reviewer. Check its summary, inline threads, commit status, and review coverage on the current head; a green check alone is insufficient.
- Resolve material findings and rerun the complete gate after code changes. Aim for two substantive review rounds on an ordinary PR, but continue when a new material issue appears. Explain rejected, duplicate, and minor preference findings with evidence. A paused or incomplete review is not a clean review.
- Leon's standing policy is to commit, push, create the PR, and merge when ready unless he says to hold. A task-specific hold overrides this default. Recheck the current head, required CI, CodeRabbit status, and unresolved material findings immediately before merging. Uploads to TestFlight and App Store Connect changes require task-specific authorization.

## Completion gate

`./scripts/gate.sh` is the single code-level gate once introduced. A ticket is not complete unless:

- the full gate passes on the current commit;
- affected simulator flows were exercised;
- physical-TV behavior was tested when the ticket depends on it;
- the diff matches the PRD and ticket without widening scope;
- CodeRabbit has reviewed the current PR head, its required status passes, and no unresolved material finding remains;
- owned development resources were cleaned or explicitly handed off.
