# Hafa Remote
## Build Plan

**Version:** 0.2
**Last updated:** September 6, 2026
**Current status:** Internal TestFlight build 2 is installed and under household testing; Vizio parsing and Sony power defects are repaired, and the multi-TV library is being made visible and editable
**Current execution frontier:** Ship the field-feedback fixes in internal build 3, then repeat Samsung, Sony, and Vizio pairing, commands, reconnect, switching, persistence, and power tests on Leon's exact household TVs

## Delivery targets

| Target | Outcome | Active build time | Elapsed time |
|---|---|---:|---:|
| Protocol decision | Q70AA pairing, commands, token persistence, and reconnect are proven | 3 days | 3 days |
| Personal alpha | Daily-driver remote for Leon's Samsung, Sony, and Vizio TVs | 6–10 more days | 2–3 weeks |
| External TestFlight | Tested setup, diagnostics, and multi-model evidence | 3–5 more days | Only after Samsung authorization gate |
| App Store 1.0 | Free mixed-brand public release | 3–5 more days | Only after beta and per-brand authorization gates |

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

- [x] Create the public `hafa-remote` GitHub repository under Shimizu Technology with `main` protected by required pull requests and blocked deletion/non-fast-forward updates.
- [x] Create the SwiftUI iPhone app, unit-test target, and UI-test target in the existing Shimizu Apple developer team.
- [x] Set product name to **Hafa Remote**, bundle ID to `com.shimizutechnology.hafaremote`, Swift 6 language mode, and minimum iOS 18.4.
- [x] Add `AGENTS.md`, `README.md`, `PRD.md`, `BUILD_PLAN.md`, `.gitignore`, and `scripts/gate.sh`.
- [x] Make the gate compile the app for an explicit simulator destination, run unit/UI tests that do not require hardware, and reject committed secrets/debug leftovers.
- [x] Add CI that runs the same gate or equivalent build/test steps on pull requests.
- [x] Add build configurations for Debug and Release without secrets or environment files.

**Acceptance evidence:** Clean checkout builds; the gate passes; the empty app launches in one owned simulator; no server or backend exists.

### HR-002 — Prove one Q70AA connection and command

**Blockers:** HR-001

- [x] Add the local-network purpose string and a development-only manual IP field.
- [x] Fetch and parse the TV's non-secret device-information response.
- [x] Implement the Samsung secure WebSocket handshake behind `SamsungCommandTransport`.
- [x] Put the app name in the protocol handshake without leaking user or device details.
- [x] Trigger the television approval prompt and parse the pairing token.
- [x] Store the token in Keychain and reconnect with it after app relaunch.
- [x] Send one semantic `.select` command through `TVDriver`; do not expose Samsung key strings to the UI.
- [x] Record the Q70AA model, iOS version, pairing result, certificate behavior, and connection timing in a local hardware-test fixture/document without household IP/MAC/token values. Firmware remains intentionally blank until it can be captured without adding it to discovery or logs.

**Acceptance evidence:** A screen recording shows first pairing, TV approval, one command, app force-quit, relaunch, and reconnection without another approval prompt.

**Stop condition:** If secure pairing cannot be implemented without a global TLS bypass, leaked credentials, or private entitlement misuse, stop and redesign before HR-003.

### HR-003 — Establish the session state machine

**Blockers:** HR-002

- [x] Implement `RemoteSessionState` with idle, pairing, connecting, connected, reconnecting, offline, denied, unsupported, and failed states.
- [x] Own WebSocket state and command serialization inside an actor.
- [x] Add timeouts and cancellation for pair, connect, disconnect, and send paths.
- [x] Ensure only one connection attempt and one active TV session can exist.
- [x] Add bounded foreground-only reconnect with immediate retry on meaningful network-path changes.
- [x] Create a mock driver and deterministic clock so every transition is testable without a TV.

**Acceptance evidence:** State-transition and cancellation tests pass, including rapid foreground/background and TV-switch scenarios.

## Phase 1 — Three-day personal MVP

### Day 1 — Pair and control

#### HR-004 — Build the first usable remote

**Blockers:** HR-003

- [x] Create the remote screen with TV name, connection state, power, D-pad/select, home/back, playback, volume, mute, and keyboard controls.
- [x] Implement semantic Samsung mappings for D-pad, select, home, back, play/pause, rewind, fast-forward, volume up/down, mute, and power off.
- [x] Disable unsupported or unavailable controls instead of sending speculative commands.
- [x] Add pressed states, haptics, and button-repeat behavior with serialized writes and safe rate limits.
- [x] Add unit tests proving every semantic control maps to exactly the intended Samsung command.

**Acceptance evidence:** Every required control is exercised on the Q70AA, with a fifty-command soak and no crash, stuck direction, or corrupted session.

### Day 2 — Persist and recover

#### HR-005 — Survive ordinary iPhone and TV lifecycle events

**Blockers:** HR-004

- [x] Add `SavedTV` persistence in SwiftData and Keychain-backed pairing credentials.
- [x] Reconnect to the last-used TV at foreground activation.
- [x] Handle app background, phone lock, app force-quit, TV restart, Wi-Fi loss, and token invalidation.
- [x] Use `NWPathMonitor` only as a network hint; verify the actual TV connection before showing connected.
- [x] Add recovery actions for retry, find TV, re-pair, and iOS local-network Settings.
- [x] Redact addresses, identifiers, pairing tokens, and typed text from logs.

**Acceptance evidence:** Complete ten lock/background cycles, a TV reboot, an app relaunch, and a Wi-Fi transition. At least nine of ten healthy-network cycles reconnect without re-pairing, normally within two seconds.

### Day 3 — Text, power-on truth, and go/no-go

#### HR-006 — Finish the personal-MVP capability test

**Blockers:** HR-005

- [x] Implement native keyboard presentation and Samsung text-entry behavior.
- [x] Detect and explain screens that do not accept text.
- [x] Capture a valid wireless TV MAC automatically without putting it in logs or screenshots.
- [x] Implement unicast Wake-on-LAN behind a capability flag and user-initiated power action; keep broadcast gated on Apple's restricted entitlement.
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

### HR-008 — Support multiple saved TVs

**Blockers:** HR-005; HR-007

- [x] Save multiple TVs and restore the last-used selection.
- [x] Add an optional room and editable display name.
- [x] Add a visible My TVs library with one-tap switching and a prominent Add TV action.
- [x] Cancel the previous session before connecting to another TV.
- [x] Refresh a saved TV's address when discovery finds its stable identity after a DHCP change.
- [x] Add forget/re-pair actions that delete the associated Keychain token.
- [x] Add deterministic tests for duplicate discovery, credential deletion, address refresh, and rapid switching.
- [ ] Complete the ten-switch household hardware soak.

**Acceptance evidence:** Automated coverage proves that multiple TVs can be saved, switched rapidly, restored, rediscovered at a changed address, renamed, and forgotten without crossing brand identity, credentials, or commands. Only the ten-switch household soak remains pending.

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

### HR-020 — Establish brand-neutral device identity and routing

**Blockers:** Samsung internal alpha merged

- [x] Add `TVBrand`, a brand-neutral connected-TV record, and a brand-scoped stable identity.
- [x] Migrate existing saved records safely to Samsung; discard unsafe address-keyed alpha credentials and require fresh approval.
- [x] Persist an optional brand-specific control port without treating it as stable identity.
- [x] Present one automatic Add TV experience with brand-scoped results and no address entry in the normal path.
- [x] Route commands and credential deletion only to the selected brand driver.
- [x] Keep all existing Samsung tests and behavior green.

**Acceptance evidence:** Existing Samsung records restore as Samsung, identical reported identifiers from different brands cannot collide, and the complete gate passes without changing the Samsung UI flow.

### HR-021 — Add Sony BRAVIA/Google TV support

**Blockers:** HR-020; exact household Sony is powered on for discovery and model capture

- [x] Prefer zero-entry Bonjour discovery and require the selected service to complete Sony's authenticated handshake before saving it.
- [x] Use Android TV Remote Service v2 for compatible Google/Android TV models; keep IRCC-IP out of build 2.
- [x] Implement on-TV code pairing with a per-device credential stored only in Keychain.
- [x] Map the approved semantic command allowlist; never expose raw Android keycodes to UI code.
- [x] Implement power off and the network-standby power command with truthful reconnect state.
- [ ] Run pairing, relaunch, 50-command, reconnect, and power tests on the household Sony.

**Acceptance evidence:** The Sony is found without an address, pairs once, survives relaunch, passes the control soak, and either powers on repeatedly or shows an honest unavailable state.

### HR-022 — Add Vizio SmartCast support

**Blockers:** HR-020; exact household Vizio is powered on for discovery and model/firmware capture

- [x] Discover SmartCast candidates without subnet scanning, then verify the local SmartCast endpoint on port 7345 or the legacy 9000 port.
- [x] Implement the TV-displayed PIN flow and store the returned auth token only in Keychain.
- [x] Scope self-signed TLS trust to the selected private endpoint and persist the approved certificate fingerprint; never add a global trust bypass.
- [x] Map the approved semantic command allowlist and check SmartCast response status rather than relying on HTTP status alone.
- [x] Implement explicit power off/on commands with truthful reconnect verification and a documented Quick Start dependency.
- [ ] Run pairing, relaunch, 50-command, reconnect, and power tests on the household Vizio.

**Acceptance evidence:** The Vizio is found without an address, PIN-pairs once, survives relaunch, passes the control soak, and either powers on repeatedly or shows an honest unavailable state.

### HR-030 — Repair modern Vizio identity parsing

**Evidence:** Household TestFlight build 2 discovers the Vizio but cannot begin pairing. Modern SmartCast device-information responses wrap metadata in `ITEMS[0].VALUE`, with serial and firmware fields under `SYSTEM_INFO`; build 2 only accepted a synthetic singular `ITEM` fixture.

- [x] Decode the modern `ITEMS` envelope and nested `SYSTEM_INFO` identity fields.
- [x] Retain the legacy singular `ITEM` response for older firmware.
- [x] Replace the request-level test fixture with the modern wire shape.
- [x] Preserve strict identity validation and privacy-safe synthetic fixtures.
- [x] Give an otherwise unknown Vizio identity response a specific recovery message.
- [ ] Confirm discovery, PIN pairing, first command, relaunch, and reconnect on the household Vizio.

**Acceptance evidence:** Automated coverage proves modern and legacy response compatibility without weakening field validation. Household acceptance remains required before Vizio is described as validated.

### HR-031 — Make power commands explicit and failures truthful

**Evidence:** Household TestFlight build 2 reported a successful-looking Sony power-off transition while the TV remained on. The implementation sent Android `KEYCODE_TV_POWER` (`177`) for both semantic power actions, even though that key toggles state. [Android's KeyEvent reference](https://developer.android.com/reference/android/view/KeyEvent) defines idempotent `KEYCODE_SLEEP` (`223`) and `KEYCODE_WAKEUP` (`224`) actions for explicit off/on behavior.

- [x] Map Sony power off to `SLEEP` and power on to `WAKEUP` instead of the toggle key.
- [x] Keep the semantic command boundary so raw Android keycodes never enter feature code.
- [x] Route confirmed power off through a throwing action and disconnect only after the TV transport accepts the command.
- [x] Show an actionable error when power-off delivery fails instead of silently presenting the TV as offline.
- [x] Expose in-flight power state and cancel its work when the remote leaves the screen.
- [x] Add protocol and UI regression coverage for explicit key mapping, confirmation, success, and failure.
- [ ] Verify Sony sleep/wake with Remote Start or network standby enabled on the household TV.
- [ ] Verify Vizio off/on with Quick Start enabled and Samsung wake with Power On With Mobile enabled.

**Acceptance evidence:** Automated tests prove Sony uses idempotent sleep/wake codes and the UI cannot claim a failed power-off delivery. Household tests still determine whether each TV remains reachable while off; the app must not promise wake where the required standby mode is disabled or unsupported.

### HR-032 — Make multiple saved TVs obvious and editable

**Evidence:** Build 2 already persisted multiple TVs in SwiftData and pairing credentials in Keychain, but switching was hidden inside a compact toolbar menu and new records used generic brand names. Household testing showed the expected mental model is a visible favorites-like list that remembers every paired room and makes switching immediate.

- [x] Replace the hidden chooser with a visible **My TVs** toolbar action and local library.
- [x] Show saved name, optional room, brand, model, selected state, connected state, and switching progress.
- [x] Switch to a saved TV in one tap without rescanning or entering an address.
- [x] Add local name and room editing with bounded, validated fields.
- [x] Keep Add TV prominent from the library.
- [x] Make Forget TV deliberate, remove the brand-specific Keychain credential, delete local metadata, and choose a safe fallback.
- [x] Preserve edited name and room through reconnects and DHCP address refreshes.
- [x] Add SwiftData and UI coverage for persistence, switching, editing, adding, and forgetting.
- [ ] Complete the ten-switch household soak across Samsung, Sony, and Vizio.

**Acceptance evidence:** A user can open My TVs, understand what is saved, switch rooms, rename a TV, add another, or deliberately forget one without an account or backend. All metadata remains on the iPhone and all pairing secrets remain in Keychain.

## Phase 3 — External TestFlight

### HR-012 — Resolve each brand's distribution basis

**Blockers:** HR-011 go decision

- [ ] Document exactly which local Samsung, Sony/Google TV, and Vizio interfaces, commands, marks, and device data the app uses.
- [ ] Review Samsung's Consumer TV IP Control worksheet, current device/service terms, developer terms, and partner routes.
- [ ] Seek written permission, partner guidance, or a qualified legal basis for every brand-specific control protocol included in the distributed build.
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

### HR-014 — Test across every advertised brand

**Blockers:** HR-013

- [ ] Recruit testers covering every advertised brand, at least three model years overall, and three home networks.
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

- [x] Make the archive/export commands, Release configuration, signing settings, and symbol generation reproducible.
- [x] Run formatting, unit tests, UI tests, secret scan, and Release preflight in CI.
- [ ] Validate the signed archive and exported IPA from merged `main` against the reviewed bundle, version, entitlements, profile, and privacy manifest.
- [ ] Verify Release logging and diagnostics redaction.
- [ ] Exercise clean install, upgrade from the previous beta, data migration, forget/re-pair, and offline launch.
- [ ] Review all dependency, privacy-manifest, entitlement, and Info.plist declarations against the actual binary.
- [ ] Run CodeRabbit review on the current PR head and resolve actionable findings before merge.

**Acceptance evidence:** Release candidate archive installs through TestFlight, full gate passes, required checks are green, and the signed binary matches the documented privacy behavior.

## Phase 4 — App Store 1.0

### HR-016 — Reserve and clear the product identity

**Blockers:** App Store go decision

- [x] Confirm **Hafa Remote** availability directly in App Store Connect and reserve Apple ID `6808899369`.
- [ ] Complete a basic trademark/confusion review and document the result.
- [ ] Register the final bundle ID, app record, SKU, category, age rating, and territories.
- [x] Finalize build 2 subtitle, keywords, support URL, privacy-policy URL, copyright, and contact information.
- [x] Confirm the listing uses manufacturer names only to describe compatibility and states that Hafa Remote is independent and unaffiliated.

**Acceptance evidence:** Reserved App Store Connect record and a metadata review with no unsupported compatibility, privacy, or affiliation claim.

### HR-017 — Prepare App Review evidence

**Blockers:** HR-015; HR-016

- [ ] Create screenshots from the release candidate on supported iPhone sizes.
- [ ] Record a concise video showing discovery, TV approval, core commands, reconnection, and power-on limitations.
- [ ] Add a clearly labeled offline demo mode that exercises the interface and state/error presentations without sending network commands.
- [x] Write build 2 review notes explaining the same-Wi-Fi and physical-TV requirements for each brand.
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

- [ ] The tested brand/model scope is explicit.
- [ ] Authorization, partner terms, or a documented qualified legal basis covers every distributed brand protocol.
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

Merge the reviewed build 2 release PR, create the signed archive and exported IPA from `main`, and validate the reviewed bundle, version, entitlements, provisioning profile, and privacy manifest. Only after that validation passes, upload the same artifact to internal TestFlight and run the Samsung, Sony, and Vizio household acceptance journeys.
