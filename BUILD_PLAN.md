# Hafa Remote
## Build Plan

**Version:** 0.1  
**Last updated:** September 4, 2026  
**Current status:** HR-001 and the no-billing CI change are merged; HR-002 remains pending on physical Q70AA pairing evidence; HR-003 through HR-007 are implemented in the review stack; HR-015 release acceptance remains pending
**Current execution frontier:** Q70AA hardware acceptance, automatic-discovery validation, ordered merge, and internal TestFlight

## Delivery targets

| Target | Outcome | Active build time | Elapsed time |
|---|---|---:|---:|
| Protocol decision | Q70AA pairing, commands, token persistence, and reconnect are proven | 3 days | 3 days |
| Personal alpha | Daily-driver remote for Leon's Samsung TVs | 3–5 more days | 1–2 weeks |
| External TestFlight | Tested setup, diagnostics, and multi-model evidence | 3–5 more days | Only after Samsung authorization gate |
| App Store 1.0 | Free Samsung-only public release | 2–4 more days | Only after beta and authorization gates |

Estimates assume focused build sessions. Hardware testing and entitlement/App Review waits determine calendar time.

## Working agreements

- Every ticket delivers a demoable vertical slice and has explicit acceptance evidence.
- Keep one writing session per worktree/branch.
- Build forward in small PRs; do not mix protocol, UI polish, and release metadata in one change.
- Run `./scripts/gate.sh` before reporting any ticket complete.
- Hardware-dependent tickets include the TV model, firmware, iOS version, network condition, and observed result.
- A passing unit test does not replace a real-TV check.
- Each session owns and cleans the exact simulator/device logs or processes it starts.
- No push, PR, TestFlight upload, App Store change, or merge without Leon's authorization for that action.

## Phase 0 — Repository and protocol proof

### HR-001 — Create the native project foundation

**Blockers:** None

- [x] Create a private `hafa-remote` GitHub repository under Shimizu Technology.
- [x] Create the SwiftUI iPhone app, unit-test target, and UI-test target in the existing Shimizu Apple developer team.
- [x] Set product name to **Hafa Remote**, bundle ID to `com.shimizutechnology.hafaremote`, Swift 6 language mode, and minimum iOS 18.4.
- [x] Add `AGENTS.md`, `README.md`, `PRD.md`, `BUILD_PLAN.md`, `.gitignore`, and `scripts/gate.sh`.
- [x] Make the gate compile the app for an explicit simulator destination, run unit/UI tests that do not require hardware, and reject committed secrets/debug leftovers.
- [x] Add CI that runs the same gate or equivalent build/test steps on pull requests.
- [x] Add build configurations for Debug and Release without secrets or environment files.

**Acceptance evidence:** Clean checkout builds; the gate passes; the empty app launches in one owned simulator; no server or backend exists.

### HR-002 — Prove one Q70AA connection and command

**Blockers:** HR-001

- [ ] Add the local-network purpose string and a development-only manual IP field.
- [ ] Fetch and parse the TV's non-secret device-information response.
- [ ] Implement the Samsung secure WebSocket handshake behind `SamsungCommandTransport`.
- [ ] Put the app name in the protocol handshake without leaking user or device details.
- [ ] Trigger the television approval prompt and parse the pairing token.
- [ ] Store the token in Keychain and reconnect with it after app relaunch.
- [ ] Send one semantic `.select` command through `TVDriver`; do not expose Samsung key strings to the UI.
- [ ] Record the Q70AA model, firmware, iOS version, pairing result, certificate behavior, and connection timing in a local hardware-test fixture/document without household IP/MAC/token values.

**Acceptance evidence:** A screen recording shows first pairing, TV approval, one command, app force-quit, relaunch, and reconnection without another approval prompt.

**Stop condition:** If secure pairing cannot be implemented without a global TLS bypass, leaked credentials, or private entitlement misuse, stop and redesign before HR-003.

### HR-003 — Establish the session state machine

**Blockers:** HR-002

- [ ] Implement `RemoteSessionState` with idle, pairing, connecting, connected, reconnecting, offline, denied, unsupported, and failed states.
- [ ] Own WebSocket state and command serialization inside an actor.
- [ ] Add timeouts and cancellation for pair, connect, disconnect, and send paths.
- [ ] Ensure only one connection attempt and one active TV session can exist.
- [ ] Add bounded foreground-only reconnect with immediate retry on meaningful network-path changes.
- [ ] Create a mock driver and deterministic clock so every transition is testable without a TV.

**Acceptance evidence:** State-transition and cancellation tests pass, including rapid foreground/background and TV-switch scenarios.

## Phase 1 — Three-day personal MVP

### Day 1 — Pair and control

#### HR-004 — Build the first usable remote

**Blockers:** HR-003

- [ ] Create the remote screen with TV name, connection state, power, D-pad/select, home/back, playback, volume, mute, and keyboard controls.
- [ ] Implement semantic Samsung mappings for D-pad, select, home, back, play/pause, rewind, fast-forward, volume up/down, mute, and power off.
- [ ] Disable unsupported or unavailable controls instead of sending speculative commands.
- [ ] Add pressed states, haptics, and button-repeat behavior with serialized writes and safe rate limits.
- [ ] Add unit tests proving every semantic control maps to exactly the intended Samsung command.

**Acceptance evidence:** Every required control is exercised on the Q70AA, with a fifty-command soak and no crash, stuck direction, or corrupted session.

### Day 2 — Persist and recover

#### HR-005 — Survive ordinary iPhone and TV lifecycle events

**Blockers:** HR-004

- [ ] Add `SavedTV` persistence in SwiftData and Keychain-backed pairing credentials.
- [ ] Reconnect to the last-used TV at foreground activation.
- [ ] Handle app background, phone lock, app force-quit, TV restart, Wi-Fi loss, and token invalidation.
- [ ] Use `NWPathMonitor` only as a network hint; verify the actual TV connection before showing connected.
- [ ] Add recovery actions for retry, find TV, re-pair, and iOS local-network Settings.
- [ ] Redact addresses, identifiers, pairing tokens, and typed text from logs.

**Acceptance evidence:** Complete ten lock/background cycles, a TV reboot, an app relaunch, and a Wi-Fi transition. At least nine of ten healthy-network cycles reconnect without re-pairing, normally within two seconds.

### Day 3 — Text, power-on truth, and go/no-go

#### HR-006 — Finish the personal-MVP capability test

**Blockers:** HR-005

- [ ] Implement native keyboard presentation and Samsung text-entry behavior.
- [ ] Detect and explain screens that do not accept text.
- [ ] Capture or enter the TV MAC address without putting it in logs or screenshots.
- [ ] Implement Wake-on-LAN behind a capability flag and user-initiated power action.
- [ ] Test power-off and wake repeatedly with the relevant Samsung network/power settings enabled.
- [ ] Exercise the complete three-day gate in `PRD.md` and record results.
- [ ] Make an explicit decision: stop, redesign the protocol layer, or proceed to personal alpha.

**Acceptance evidence:** A dated protocol report records every gate result. Wake is either proven repeatedly or honestly marked unavailable.

## Phase 2 — Personal and household alpha

### HR-007 — Add automatic discovery with a safe fallback

**Blockers:** HR-006 go decision; Apple multicast-entitlement path understood

- [x] Identify which Samsung discovery mechanism works across target TVs without subnet scanning.
- [x] Confirm that Bonjour discovery does not require Apple's restricted multicast entitlement; retain that gate for future Wake-on-LAN only.
- [x] Trigger discovery after the explanatory empty state and the user's Add Samsung TV action.
- [x] Deduplicate responses using reported device identity, not IP address alone.
- [x] Retain manual IP pairing under troubleshooting.
- [x] Handle local-network denial, guest Wi-Fi, client isolation, no results, duplicate names, and non-Samsung devices.

**Acceptance evidence:** A new installation finds and pairs the Q70AA without entering an IP; denied permission and no-result paths are understandable.

### HR-008 — Support multiple saved Samsung TVs

**Blockers:** HR-005; HR-007

- [ ] Save multiple TVs with optional room and editable name.
- [ ] Add a compact TV chooser and one default/last-used selection.
- [ ] Cancel the previous session before connecting to another TV.
- [ ] Rediscover a saved TV after DHCP changes its address.
- [ ] Add forget/re-pair actions that delete the associated Keychain token.
- [ ] Add tests for duplicate discovery, deleted credentials, renamed TVs, and repeated switching.

**Acceptance evidence:** Two Samsung TVs can be paired, renamed, switched ten times, relaunched, and forgotten without crossing credentials or commands.

### HR-009 — Complete the production-quality remote experience

**Blockers:** HR-004; HR-005; HR-008

- [ ] Finalize one-handed layout for the smallest and largest supported iPhones.
- [ ] Add VoiceOver labels/hints, Dynamic Type behavior, contrast, dark mode, and Reduce Motion support.
- [ ] Refine connection-state and troubleshooting copy using observed failure modes.
- [ ] Add first-run education, pairing instructions, settings, about, privacy, and support screens.
- [ ] Create a distinctive Hafa Remote icon and visual system without Samsung logos or copied remote trade dress.
- [ ] Verify that accidental power taps and destructive forget actions are sufficiently deliberate.

**Acceptance evidence:** UI tests pass with the mock driver; a VoiceOver pairing/control walkthrough works; screenshots cover all major states and supported display sizes.

### HR-010 — Add privacy-safe diagnostics

**Blockers:** HR-005

- [ ] Define a small structured event vocabulary for local connection diagnosis.
- [ ] Keep diagnostic history bounded and on-device.
- [ ] Redact host, MAC, token, device ID, Wi-Fi name, and entered text.
- [ ] Let the user preview, copy, or share a diagnostic report explicitly.
- [ ] Add automated redaction tests using realistic secret/address fixtures.

**Acceptance evidence:** A generated report explains a failed connection while automated tests prove that known secrets and household identifiers are absent.

### HR-011 — Run the seven-day household soak

**Blockers:** HR-007 through HR-010

- [ ] Install on Leon's daily iPhone through the approved development/TestFlight path.
- [ ] Use Hafa Remote normally for seven days.
- [ ] Exercise every saved TV, repeated foreground reconnects, text entry, power off, and supported wake.
- [ ] Record failures with model, firmware, iOS version, network condition, state transition, and redacted diagnostics.
- [ ] Fix all P0/P1 defects and rerun the affected scenarios.
- [ ] Decide whether reliability supports external TestFlight.

**Acceptance evidence:** Seven-day log, zero unresolved P0/P1 defects, full gate green, and a written TestFlight go/no-go decision.

## Phase 3 — External TestFlight

### HR-012 — Resolve the Samsung distribution basis

**Blockers:** HR-011 go decision

- [ ] Document exactly which local Samsung interfaces, commands, marks, and device data the app uses.
- [ ] Review Samsung's Consumer TV IP Control worksheet, current device/service terms, developer terms, and partner routes.
- [ ] Ask Samsung for written permission or partner guidance covering an independently distributed iOS remote.
- [ ] If permission is unavailable or unclear, obtain a focused attorney review before external distribution.
- [ ] Save the controlling documents, dates, contacts, and conclusion in a release-only decision record.
- [ ] Treat personal development use as separate from permission to distribute through TestFlight or the App Store.

**Acceptance evidence:** Written Samsung authorization/partner terms or a qualified legal determination supports external distribution. Without that evidence, external TestFlight and App Store work are no-go.

### HR-013 — Prepare beta operations

**Blockers:** HR-012 go decision

- [ ] Publish a plain-language privacy policy stating exactly what remains on-device and whether Apple crash/TestFlight data is used.
- [ ] Publish a support page with pairing, permission, Wi-Fi, power-on, and reset instructions.
- [ ] Create a beta intake form that records model, firmware, iOS version, and router/network type without requesting tokens, addresses, or unrelated personal data.
- [ ] Create tester instructions and a structured seven-day checklist.
- [ ] Prepare TestFlight description, feedback contact, and known limitations.

**Acceptance evidence:** Someone outside the project can read the materials, pair a TV, and know how to report a failure safely.

### HR-014 — Test across Samsung hardware

**Blockers:** HR-013

- [ ] Recruit testers covering at least five Samsung TVs, three model years, and three home networks.
- [ ] Run first-pair, relaunch, foreground reconnect, fifty-command soak, power, text, and token-revocation tests on each TV.
- [ ] Record supported capabilities and failures by exact model/firmware.
- [ ] Cover at least one 2017–2019 TV, one 2020–2022 TV, and one 2023–2026 TV if the public listing intends to span those generations.
- [ ] Include TV-on-Wi-Fi, TV-on-Ethernet with iPhone on Wi-Fi, offline-internet, DHCP-change, and client-isolated network cases.
- [ ] Run a 500-command soak and 20 foreground reconnect cycles for every model group intended for the listing.
- [ ] Test wake immediately, after one minute, and after 30 minutes powered off before advertising power-on for that model.
- [ ] Remove or disable speculative compatibility behavior.
- [ ] Build the public compatibility list from the evidence.

**Acceptance evidence:** Completed device matrix, no unresolved P0/P1 defect, and known limitations written in user-facing language.

### HR-015 — Complete release engineering

**Blockers:** HR-014

- [ ] Make archive, Release configuration, signing, and symbol generation reproducible.
- [ ] Run static analysis, unit tests, UI tests, secret scan, and Release build in CI.
- [ ] Verify Release logging and diagnostics redaction.
- [ ] Exercise clean install, upgrade from the previous beta, data migration, forget/re-pair, and offline launch.
- [ ] Review all dependency, privacy-manifest, entitlement, and Info.plist declarations against the actual binary.
- [ ] Run CodeRabbit review on the current PR head and resolve actionable findings before merge.

**Acceptance evidence:** Release candidate archive installs through TestFlight, full gate passes, required checks are green, and the signed binary matches the documented privacy behavior.

## Phase 4 — App Store 1.0

### HR-016 — Reserve and clear the product identity

**Blockers:** App Store go decision

- [ ] Confirm **Hafa Remote** availability directly in App Store Connect.
- [ ] Complete a basic trademark/confusion review and document the result.
- [ ] Register the final bundle ID, app record, SKU, category, age rating, and territories.
- [ ] Finalize subtitle, keywords, support URL, privacy-policy URL, copyright, and contact information.
- [ ] Confirm the listing uses Samsung only to describe compatibility and states that Hafa Remote is independent and unaffiliated.

**Acceptance evidence:** Reserved App Store Connect record and a metadata review with no unsupported compatibility, privacy, or affiliation claim.

### HR-017 — Prepare App Review evidence

**Blockers:** HR-015; HR-016

- [ ] Create screenshots from the release candidate on supported iPhone sizes.
- [ ] Record a concise video showing discovery, TV approval, core commands, reconnection, and power-on limitations.
- [ ] Add a clearly labeled offline demo mode that exercises the interface and state/error presentations without sending network commands.
- [ ] Write App Review notes explaining the same-Wi-Fi and physical-Samsung-TV requirements.
- [ ] Provide reviewer contact details and a prompt response plan; there is no test account.
- [ ] Verify App Privacy answers and export-compliance responses against the build.
- [ ] Verify the app makes no “universal” or guaranteed power-on claim.

**Acceptance evidence:** A reviewer without the TV in hand can understand the hardware dependency, see the complete flow, and reproduce it with a compatible Samsung TV.

### HR-018 — Submit and respond without widening scope

**Blockers:** HR-017; Leon authorization to submit

- [ ] Submit the exact tested build.
- [ ] Answer review questions with protocol, privacy, and test evidence.
- [ ] Treat any rejection as a focused ticket with its own regression coverage.
- [ ] Do not add another TV brand, backend, analytics SDK, or paywall to solve a review concern.
- [ ] Release manually after approval and complete a production smoke test on the Q70AA plus one additional tested model.

**Acceptance evidence:** Public version 1.0 is available, core controls work from a clean install, and support/compatibility pages match the released build.

## App Store 1.0 definition of done

- [ ] Samsung-only scope is explicit.
- [ ] Samsung authorization/partner terms or a documented qualified legal basis covers public distribution.
- [ ] Multiple saved TVs work without credential crossover.
- [ ] Pairing, reconnect, controls, text entry, power-off, and conditional wake pass the documented device matrix.
- [ ] The UI never presents stale socket state as connected.
- [ ] No account, backend, ads, tracking, subscription, or mandatory purchase exists.
- [ ] App Privacy, privacy policy, diagnostics, and actual binary behavior agree.
- [ ] Accessibility checks and supported-device screenshots are complete.
- [ ] CI and `scripts/gate.sh` are green on the release commit.
- [ ] CodeRabbit has reviewed the current PR head with no unresolved actionable finding.
- [ ] App Review notes and the support site document the hardware dependency and known limitations.
- [ ] No P0/P1 defect remains.

## Severity definitions

| Severity | Meaning | Examples |
|---|---|---|
| P0 | Unsafe, privacy-breaking, or core app unusable | Token leak, global TLS bypass, pairing impossible, commands sent to wrong TV |
| P1 | Core daily flow unreliable with no reasonable recovery | Frequent disconnect, token repeatedly lost, stuck repeat command, false connected state |
| P2 | Important but recoverable degradation | Manual retry required, one optional command unsupported, confusing error copy |
| P3 | Polish or low-frequency issue | Minor spacing, animation, non-blocking copy problem |

## Risk register

| Risk | Early proof | Mitigation | Release consequence |
|---|---|---|---|
| Samsung changes or withholds the local protocol | HR-002 and multi-model beta | Isolate driver, document evidence, avoid universal claims | Stop public release if behavior is not defensible |
| Samsung does not authorize third-party distribution | HR-012 | Seek partner guidance or qualified legal review before external distribution | Keep the app personal/internal; do not submit publicly |
| Self-signed device TLS encourages insecure handling | HR-002 security review | Per-device, user-initiated trust; no global bypass | P0 blocker |
| A target TV does not advertise Samsung Bonjour | HR-007 and hardware matrix | Keep manual-IP recovery and test discovery on every supported model | Exclude models that cannot meet zero-entry setup quality |
| Wake-on-LAN varies by TV/router/settings | HR-006 and HR-014 | Capability gate and honest messaging | Never market guaranteed power-on |
| Background suspension causes stale sessions | HR-005 | Foreground reconnect; no background-mode abuse | P1 blocker if recovery is unreliable |
| DHCP changes break saved TVs | HR-008 | Stable device identity and rediscovery | P1 blocker for household use |
| App Review cannot exercise TV hardware | HR-017 | Demo mode, detailed notes, and full review video | Submission delay; no scope expansion |
| Samsung trademark/confusion concern | HR-016 | Hafa identity, descriptive compatibility, unaffiliated statement | Rename metadata before submission if needed |
| No analytics hides field failures | HR-010 through HR-014 | Redacted, opt-in diagnostics and structured beta matrix | Small beta before release |

## Immediate next action

Finish the Q70AA automatic-discovery and secure-pairing acceptance journey, then merge the reviewed PR stack in order and upload a fresh build from `main` to internal TestFlight.
