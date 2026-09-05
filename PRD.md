# Hafa Remote
## Product Requirements Document

**Version:** 0.2
**Date:** September 5, 2026
**Owner:** Shimizu Technology
**Status:** Samsung internal alpha available; mixed-brand expansion in progress

## Executive summary

Hafa Remote is an iPhone-only remote control for compatible Samsung, Sony, and Vizio smart TVs on the same local network. It should replace the physical remote for ordinary daily use without an account, advertising, a subscription, or a cloud service. Each brand is a separately tested capability: Samsung remains the proven baseline, while Sony and Vizio stay internal-only until Leon's exact household models complete pairing, command, reconnect, and power testing. A public App Store release is a later decision that depends on real-device reliability and a defensible authorization basis for every local-control protocol distributed in the binary.

## Product classification

- **Profile:** Public consumer utility, beginning as a personal/internal alpha
- **Platform:** iPhone only
- **Initial TV platforms:** Compatible Samsung Tizen, Sony BRAVIA/Google TV, and Vizio SmartCast televisions, enabled only after per-model validation
- **Connectivity:** Local Wi-Fi only
- **Backend:** None
- **Account:** None
- **Initial price:** Free
- **Privacy posture:** Commands and device information stay on the phone and local network

## Guiding principles

1. **The remote must be immediate.** Opening the app, reconnecting, and pressing a button should feel like using hardware.
2. **Never fake success.** The UI distinguishes connected, reconnecting, sleeping, unsupported, denied, and failed states. A sent command is not described as completed when the TV protocol provides no acknowledgement.
3. **Local by default.** No account, backend, third-party analytics, advertising SDK, or cloud dependency in version one.
4. **Reliability before compatibility.** A brand is not called supported until its exact pairing, controls, reconnect, and power behavior pass on real hardware.
5. **Capabilities drive the interface.** The app only exposes controls a paired television is known or observed to support.
6. **Be honest about power-on.** Power-off and network wake are separate capabilities. Wake-on-LAN will not be promised for unsupported televisions or networks.
7. **Accessible without setup knowledge.** Pairing instructions, button labels, touch targets, haptics, VoiceOver, Dynamic Type, dark mode, and reduced-motion behavior are part of the product.

## Audience and core job

The primary user owns a mixed-brand set of smart TVs, has misplaced or does not want to use the physical remotes, and wants one immediate control surface from an iPhone on the same Wi-Fi network.

The core job is: **Open Hafa Remote, select the intended television if necessary, and control it within two seconds without encountering an ad, login, or paywall.**

## Version-one scope

### Required controls

- Power off while connected
- Power on through Wake-on-LAN only when setup and testing prove it is supported
- Volume up and volume down
- Mute
- D-pad: up, down, left, right, and select
- Back and home
- Play/pause, rewind, and fast-forward
- Keyboard/text entry when the active TV screen accepts text
- Button-repeat behavior for directional and volume controls
- Haptic feedback for taps and connection-state changes

Commands use a reviewed allowlist. Factory, service-menu, hospitality, reset, and other potentially destructive Samsung keys are never included.

### Compatibility policy

- The first candidate transport is Samsung's secure local WebSocket interface on compatible post-2016 Tizen TVs.
- A model year alone never proves compatibility; the app records the observed transport, token behavior, commands, firmware, and power behavior.
- Samsung 2016 K-series support is excluded unless its distinct encrypted/PIN pairing variants are implemented and tested deliberately.
- Frame TV Art Mode is excluded from the first release unless its power-versus-art semantics receive a separate tested capability profile.
- Sony support prefers Android TV Remote Service v2 when the exact BRAVIA exposes it; IRCC-IP is considered only for a model whose documented authentication flow is verified on hardware.
- Vizio support targets SmartCast televisions whose local HTTPS pairing API can be verified on port 7345 or the legacy 9000 port.
- Public metadata lists only the model/firmware groups demonstrated by the hardware matrix.

### Required device behavior

- Discover compatible TVs on the current local network and identify their brand before pairing
- Provide manual IP entry as a recovery path, not the primary setup path
- Show the brand-appropriate approval or PIN prompt during initial pairing
- Store the resulting token, PSK, or client identity securely in Keychain
- Save non-secret TV metadata locally
- Remember multiple TVs without crossing brand-specific identity or credentials
- Rename TVs and assign an optional room
- Choose a default or most-recent TV
- Rediscover a saved TV when DHCP changes its IP address
- Reconnect after app backgrounding, phone lock, TV restart, Wi-Fi interruption, and app relaunch
- Forget a TV and delete its pairing token
- Explain guest-network/client-isolation failures without claiming the TV is unsupported

### Required product states

The main session state machine must represent at least:

- Idle
- Discovering
- Awaiting TV approval
- Connecting
- Connected
- Reconnecting
- TV asleep or offline
- Local-network permission denied
- Pairing denied or expired
- Unsupported device
- Failure with a useful recovery action

## Explicitly out of scope for version one

- Android, iPad-specific, Mac, Apple Watch, or Apple TV apps
- LG, Roku, Fire TV, generic infrared remotes, casting, or devices that cannot complete a supported local pairing flow
- Casting, screen mirroring, media browsing, or content recommendations
- User accounts, cloud sync, remote-outside-the-home control, or a backend
- Siri, widgets, Shortcuts, Live Activities, or home-screen controls
- Custom layouts, macros, scenes, or automations
- Subscription billing, advertising, telemetry, or behavioral analytics
- Claims of universal Samsung compatibility

## Primary user flows

### First launch and pairing

1. Hafa Remote explains that the iPhone and TV must be on the same non-guest Wi-Fi network.
2. The user taps **Add TV**; the setup sheet immediately searches and this user action triggers the iOS local-network permission request.
3. The app shows verified Samsung, Sony, and Vizio devices with their reported name, brand, and model when available.
4. The user chooses a TV.
5. The app establishes the brand-specific secure local connection and requests on-TV approval or a short PIN when that protocol requires it.
6. Hafa Remote stores only the resulting brand-scoped credential in Keychain.
7. The app confirms the session through the protocol handshake, opens the remote, and explains any unavailable controls.

### Everyday control

1. The app opens to the last-used TV.
2. It reconnects automatically in the foreground.
3. The status control shows the actual connection state.
4. Supported controls become active only when their command path is available.
5. If reconnecting takes longer than expected, the user sees **Retry**, **Find TV**, and troubleshooting actions.

### Power-on

1. When a saved TV is offline and has a known MAC address plus verified wake support, the power control sends a Wake-on-LAN packet.
2. Hafa Remote displays **Waking TV…**, searches for the TV, and connects when it becomes available.
3. If wake support is unknown or has failed, the app explains the TV/network limitation and does not imply success.

### Text entry

1. The user opens the keyboard from the remote.
2. The app shows a native text field and sends supported text-entry commands.
3. The app clearly handles TV screens that do not accept text and always provides a way to dismiss the keyboard.

### Multiple TVs

1. The last-used TV appears at the top of the remote.
2. Tapping it opens a compact TV chooser with room, name, connection state, and model.
3. Selecting another TV cancels the old session cleanly and establishes one session with the new TV.

## Interface requirements

### Remote screen

- TV selector and truthful connection state at the top
- Deliberate power control separated from frequently tapped navigation controls
- Large circular D-pad with a distinct select target
- Home/back and playback controls grouped by purpose
- Volume controls reachable one-handed
- Keyboard entry available without crowding the primary layout
- Minimum 44-by-44-point interactive targets
- Visible pressed states and subtle haptics
- No Samsung logo, copied trade dress, or physical-remote imitation

### Accessibility

- Every control has a concise VoiceOver label and useful hint
- Directional controls preserve their meaning outside visual position
- Dynamic Type does not obscure the remote or connection recovery actions
- Color never carries connection state alone
- Reduced Motion disables unnecessary animation
- Contrast is verified in light and dark appearances

## Technical architecture

### Stack

| Layer | Choice | Reason |
|---|---|---|
| UI | SwiftUI | Native iPhone interface and accessibility |
| Language | Swift 6 language mode | Concurrency safety for socket/session state |
| Minimum OS | iOS 18.4 | Modern SwiftUI, Observation, SwiftData, and current Shimizu iOS baseline |
| Networking | Network.framework | Apple-native TCP, UDP, WebSocket/TLS, and path monitoring |
| Device metadata | SwiftData | Small local collection of saved TVs |
| Secrets | Keychain Services | Pairing tokens never enter SwiftData, logs, or backups unintentionally |
| Logging | OSLog | Privacy-redacted local diagnostics |
| Tests | Swift Testing/XCTest and XCUITest | Fast domain tests plus launch and interaction coverage |
| External dependencies | None initially | Keep protocol behavior inspectable and reduce supply-chain/review risk |

### Runtime topology

```text
SwiftUI screens
    |
RemoteSessionStore (@MainActor)
    |
TVDriverRouter (actor)
    |-- SamsungLocalDriver (actor)
    |-- SonyRemoteDriver (actor)
    |-- VizioSmartCastDriver (actor)
    |
Brand-specific discovery + pairing + command + wake services
    |
DeviceRepository (SwiftData) + PairingTokenStore (Keychain)
```

There is no web service, database server, authentication provider, background worker, or production hosting bill in version one.

### Suggested project structure

```text
HafaRemote/
  App/
  Features/
    Onboarding/
    Discovery/
    Remote/
    Devices/
    Settings/
  Core/
    Models/
    Networking/
    Persistence/
    Diagnostics/
  Protocols/
    TVDriver.swift
    Samsung/
  DesignSystem/
  Resources/
HafaRemoteTests/
HafaRemoteUITests/
scripts/gate.sh
AGENTS.md
README.md
```

### Core types

- `TVDriver`: send semantic commands, send text, and disconnect without leaking protocol keys into UI code; brand-specific session coordinators own discovery, pairing, connection, wake, and capability evaluation
- `TVBrand` and brand-scoped stable identity: prevent credential or command crossover between televisions that report similar identifiers
- `RemoteCommand`: semantic commands such as `.move(.up)`, `.select`, `.volume(.up)`, and `.powerOff`
- `TVCapability`: navigation, playback, volume, mute, text input, power off, and wake
- `RemoteSessionState`: the explicit connection states defined above
- `SavedTV`: stable local ID, reported device identifier when available, display name, room, model, last-known host, optional MAC address, last-seen time, capabilities, and trust metadata
- `PairingTokenStore`: Keychain-only access keyed by the stable local device ID

The UI must never send raw protocol keys directly. Only the active brand driver maps semantic commands to its television protocol.

## Networking and security requirements

- Use user-initiated local-network access with `NSLocalNetworkUsageDescription`.
- Declare only Bonjour service types actually used and validate every advertisement through the selected brand's local endpoint before presenting it as compatible.
- Bonjour discovery declares only verified services such as Samsung's `_samsungmsf._tcp`, Android TV Remote Service's `_androidtvremote2._tcp`, and a Vizio candidate service proven on the household model. If a future discovery or Wake-on-LAN path requires arbitrary multicast or broadcast, request Apple's multicast entitlement before adding it; keep manual address pairing only as a troubleshooting fallback.
- Use a narrow local-network transport policy; do not enable arbitrary network loads globally.
- Restrict connections to local/link-local targets and reject redirects or unexpected internet hosts.
- Isolate each brand's device-certificate handling. Trust must be tied to an explicit pairing action and saved device; do not install a global accept-all TLS policy.
- Consider certificate fingerprint pinning per paired TV. If firmware rotates the certificate, show a deliberate re-verification flow.
- Serialize socket state and command writes in an actor.
- Keep only one active TV session.
- Reconnect only while the app is foreground-active. Do not declare an unrelated background mode to keep a socket alive.
- Use bounded exponential backoff with immediate retry on foreground or meaningful network-path changes.
- Redact IP addresses, MAC addresses, tokens, device IDs, and text-entry content from production logs and diagnostic exports.
- Never claim a command succeeded when the transport lacks a device acknowledgement.

## Local data model

### SavedTV

| Field | Storage | Notes |
|---|---|---|
| `id` | SwiftData | App-generated stable ID |
| `brand` + `reportedDeviceID` | SwiftData, protected | Brand-scoped identity used for rediscovery |
| `name` | SwiftData | User-editable display name |
| `room` | SwiftData | Optional |
| `model` | SwiftData | Reported model when available |
| `lastKnownHost` | SwiftData, protected | Cache, never the sole identity |
| `macAddress` | SwiftData, protected | Optional; required for Wake-on-LAN |
| `capabilities` | SwiftData | Last verified capability set |
| `certificateFingerprint` | SwiftData, protected | Optional per-device trust record |
| `lastSeenAt` | SwiftData | Diagnostics and UI |
| `isDefault` | SwiftData | At most one default TV |
| pairing token, client identity, or PSK | Keychain | Brand-scoped, stored separately under `id`; never logged |

No data is synced or transmitted to Shimizu Technology in version one.

## Reliability rules

- A remembered IP is a cache, not device identity.
- Pair once, retain the token, rediscover the device, then reconnect.
- Cancel discovery, reconnect timers, and socket tasks when their owner disappears or a different TV is selected.
- Do not allow overlapping connection attempts.
- Coalesce or serialize button-repeat commands so rapid input cannot corrupt the WebSocket stream.
- Reset stale connection state after network changes, TV reboot, denied pairing, or invalid token.
- Make every indefinite operation cancellable and time-bounded.
- Treat text input as capability- and screen-dependent.

## Testing requirements

### P0 automated coverage

- Samsung request/command encoding from semantic commands
- Pairing URL construction and returned-token parsing
- Pairing approved, denied, timed out, and invalid-token state transitions
- Reconnect policy, cancellation, and no-overlap guarantees
- Device identity and DHCP host replacement
- Keychain save/read/delete behavior
- Wake-on-LAN packet construction and capability gating
- Log/diagnostic redaction
- Capability-driven button availability

### P0 hardware journeys

- Fresh install, permission approval, discovery, pairing, and first command
- Pairing denial followed by successful retry
- Fifty-command D-pad/volume/playback soak without crash, corruption, or obvious loss
- Ten background/foreground and phone lock/unlock reconnect cycles
- TV reboot, app force-quit, iPhone reboot, and router/DHCP host change
- Wi-Fi to cellular to Wi-Fi transition
- Power off; conditional Wake-on-LAN from the same subnet
- Two saved TVs and repeated switching between them
- TV not found on guest Wi-Fi/client-isolated network
- Token revoked from the TV and clean re-pairing

### Accessibility and UI journeys

- VoiceOver can pair, choose a TV, use every command, and recover from disconnect
- Largest practical Dynamic Type size keeps critical controls and recovery actions usable
- Light mode, dark mode, increased contrast, and reduced motion
- Smallest supported iPhone display and current large iPhone display
- System permission denied, then enabled through Settings

## Three-day personal-MVP acceptance gate

Proceed beyond the spike only when all of the following are true on the Q70AA:

- Initial pairing completes and the token survives app relaunch.
- D-pad, select, home, back, playback, volume, mute, power-off, and supported text entry work.
- A fifty-command manual soak shows no crash, stuck direction, duplicated command, or persistent disconnect.
- At least nine of ten background/foreground cycles reconnect without manual re-pairing, normally within two seconds on healthy Wi-Fi.
- TV and app restarts do not lose the pairing token.
- Power-on is either demonstrated repeatedly or marked unsupported without damaging the rest of the experience.
- No secret or household network identifier appears in ordinary logs.

Failure of this gate means document the protocol limitation and stop or redesign before building polished UI.

## TestFlight gate

Before inviting external testers:

- The Samsung distribution-authorization gate has passed; personal development success alone does not authorize external distribution.
- Unit, integration, UI, lint/build, and secret scans pass through one gate command.
- The app has survived seven days of ordinary use in Leon's house.
- Setup and troubleshooting copy has been tested by someone who did not build the app.
- Diagnostics export is user-triggered, redacted, and previewable before sharing.
- Privacy policy and support pages are public.
- The compatibility list contains only observed models/firmware.

## Public App Store gate

Do not submit until:

- Shimizu Technology has written permission, applicable partner terms, or a qualified legal basis covering every brand-specific control protocol distributed in the binary. If any brand remains unresolved, exclude that driver from the distributed build or stop at personal/internal distribution.
- Testing covers every advertised brand, at least three model years overall, and at least three home networks; one household unit is evidence for that exact model, not a universal compatibility claim.
- Pairing and reconnection results are recorded for each model/firmware combination.
- Each advertised model group completes a 500-command soak with at least 99% observed delivery, zero duplicate commands, and no stuck repeat state.
- Each advertised model group completes at least 20 foreground reconnect cycles, with at least 19 reconnecting without re-pairing and normally within two seconds on healthy Wi-Fi.
- Power-on is advertised for a model only after repeated wake tests succeed after at least 30 minutes powered off.
- No unresolved P0 or P1 defect remains.
- Unsupported power-on behavior is described per model rather than hidden.
- The exact App Store name and Shimizu Technology bundle identifier have been reserved.
- A basic trademark/name check is complete. A preliminary web search found no exact App Store match for **Hafa Remote**, but this is not formal clearance.
- App Review receives a short pairing/usage video and clear hardware-review notes.
- A clearly labeled offline demo mode lets App Review inspect the interface and state transitions without pretending to control a television.
- App metadata says the product is independently developed and not affiliated with Samsung.
- The icon and screenshots contain no Samsung logo or copied remote trade dress.
- App Privacy answers match the shipped binary; version one should qualify as **Data Not Collected** only if no SDK or feature changes that fact.

## Product success measures

Because version one has no analytics, success is measured through an explicit beta log:

- Pairing completed without developer assistance
- Reconnected after foregrounding without re-pairing
- Commands felt immediate during ordinary use
- Power-off result and power-on capability by TV/network
- Model, firmware, router/network, and iOS version
- Tester-reported disconnects, failed commands, and crashes

The public-release decision is based on the device matrix and TestFlight crash data, not download projections.

## Branding and App Store positioning

- **Product name:** Hafa Remote
- **Working subtitle:** TV Remote — No Subscription
- **Promise:** Fast local control without an account, ads, or a weekly subscription
- **Tone:** Calm, trustworthy, direct, and local—not a loud “universal remote” clone
- **Bundle ID:** `com.shimizutechnology.hafaremote`
- **Category:** Utilities
- **Age rating:** Expected 4+, subject to final App Store questionnaire

The listing may use Samsung descriptively to explain compatibility, but the product name, icon, and visual system remain Hafa Remote.

## Release sequence

1. Q70AA protocol spike
2. Personal alpha on Leon's iPhone
3. Multi-TV household alpha
4. Internal TestFlight
5. Small external TestFlight and compatibility matrix
6. App Store readiness decision
7. Public free 1.0 if the reliability and policy gates pass

## Decisions still open

These do not block the protocol spike:

- Final icon, palette, and visual identity
- Public privacy-policy and support URLs
- Final App Store subtitle and keywords
- Whether a later one-time Supporter purchase is worth adding
- The exact Samsung model/firmware compatibility claims, which must come from testing
- Whether Apple grants the multicast entitlement needed for future Wake-on-LAN
- Whether Samsung will authorize public use of its local-control protocol; this is the largest release blocker

## Reference material

- Prior research: `/Users/leonshimizu/Desktop/smart-tv-remote-research/output/pdf/smart-tv-remote-research.pdf`
- Apple local-network privacy: <https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy>
- Apple multicast entitlement: <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast>
- Apple transport security: <https://developer.apple.com/documentation/security/preventing-insecure-network-connections>
- Apple Network.framework WebSocket guidance: <https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api>
- Apple App Review Guidelines: <https://developer.apple.com/app-store/review/guidelines/>
- Samsung Consumer TV IP Control worksheet: <https://image-us.samsung.com/SamsungUS/samsungbusiness/tv-ci-resources/Samsung-IP-Control.pdf>
- Samsung SmartThings integration documentation: <https://developer.smartthings.com/docs/service-integrations/app-setup>
- Community protocol reference, not an official Samsung contract: <https://github.com/xchwarze/samsung-tv-ws-api>
