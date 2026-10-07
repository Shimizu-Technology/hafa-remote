# HR-046 — Private support diagnostics and offline demo

The support report records a maximum of 100 fixed semantic events in memory after
the user turns collection on. It accepts no event message, network error, command
payload, or device identity. Optional operation duration is reduced to a bucket.
Turning collection off clears the buffer. There is no persistence, upload,
analytics SDK, or network operation in these modules.

The user previews an immutable report before opening ShareLink. The report
contains app/build/iOS versions, optional verified TV model and firmware, and
event order with coarse timing. Metadata fields reject address/identifier shapes
and malformed values. This is defense in depth; callers must supply actual model
and firmware fields, never TV names, room names, IDs, or generic errors.

The offline demo is included in Release builds. Its visible Offline Demo label
and explanatory copy remain present while exploring. Every action changes only
an ephemeral DemoRemoteModel. It never becomes a TVDriver, accesses a repository,
starts discovery, requests local-network permission, or reads credentials. It
does not assert hardware support. Keyboard input is reduced to a character count
and the field is cleared after use and dismissal.

## Integration

The explicit Xcode source lists now compile five support app sources and three
focused test sources in their correct app/test targets. The control extension
contains none of these modules.

Home exposes Help before pairing. Its support menu offers the offline demo,
diagnostics, and the existing TV Help screen. The demo destination receives no
session, driver, repository, or credential object. It remains compiled in Release.
Both screens use HafaTheme and inherit the native palette.

RemoteSessionStore owns one default-disabled DiagnosticRecorder. Typed state,
command/text delivery, lifecycle, discovery, and wake boundaries feed fixed events.
Measured operation durations come from ContinuousClock and are reduced to coarse
buckets. Raw errors, protocol responses, commands, entered text, names, rooms,
addresses, identities, and credentials never enter the event buffer.

Requesting a different saved TV or a new candidate clears previous events before
collection continues. Completed deliveries from an old diagnostic scope are
ignored. Explicitly forgetting/discarding the remembered TV clears its buffer.
Reports attach only the current connected TV's aligned model/firmware metadata;
a Sony model that equals its protocol display name is omitted because that value
may be a certificate-name fallback. User-edited TV names and rooms are never
used as diagnostic metadata.

Diagnostic ownership is stamped when controller state is produced: a process-local
request identifier, controller generation, and monotonic production time accompany
each update. The store rejects queued states from an older request or generation;
initial snapshots retain the ownership of the state that was actually published.
These values never enter diagnostic reports.

Collection has a separate epoch. Clear, disabling/re-enabling collection, and a TV
switch invalidate outstanding collection leases. Commands, text, connection
readiness, discovery, and wake completions retain the enabled lease from their
start; old activity cannot repopulate an erased buffer. Queued states produced
before the current collection epoch likewise cannot reappear as new events.

Connection admission is distinct from provisional UI intent. If a request is
canceled before the controller adopts it, the store reconciles to the controller's
actual producer snapshot, guarded by request and projection revision so an older
canceled call cannot overwrite a newer selection. It never restamps an old state.
Both connectAndWait paths qualify updates by their newly requested producer and
current generation; an initial same-TV, raw-address, or ABA snapshot cannot
satisfy new connection work.

Each asynchronous state outcome carries the initiation time of its causal
activity separately from its publication time. Terminal connection failures,
automatic reconnects, health probes, lifecycle handling, network grace, commands,
and removal outcomes therefore cannot acquire a new collection lease merely by
completing after Clear or renewed consent. A genuinely new health check or retry
started afterward can still record, rather than inheriting an erased lifetime
connection lease. Pending retry status and deferred teardown recovery retain the
failure or waiting attempt's origin; merely scheduling a timer is not a new
activity. The executed attempt obtains a fresh origin when that timer fires.

Integration onto the HR-045 convenience stack preserves expected-TV checks,
controller generations, cancellation recovery, optional-feature errors, and
selection guards. State-changing conveniences retain the device scope and
collection lease captured before delivery. Their failures, optional-query
failures, canceled writes, and selected-TV power teardown carry the originating
activity time into later recovery. Recovery follows each driver's declared
cancellation effect: cooperative cancellation preserves a healthy session, while
transport-invalidating writes enter truthful recovery. The active router forwards
that effect, and the controller rechecks its generation after awaiting it.
Query payloads and launch descriptors never enter diagnostics. The saved-target waiter combines its producer ownership with
the caller's current-selection predicate.

Home's native Help button opens support, with TV Help & About available inside
it. The existing setup and Control Center help routes remain available. The
Release demo handles every semantic RemoteCommand, including input, channel,
guide, and number keys, using only local simulated status.

Model/display-name fallback comparisons normalize both inputs using the same
control-character removal and whitespace trimming before checking equality.
Padded or sanitized household names therefore remain omitted.

Preview creates an immutable snapshot; the ShareLink exports only that snapshot
when the user chooses a destination. There is no automatic submission or persisted
collection preference.

## Acceptance and evidence

Automated coverage verifies opt-in behavior, bounded collection, disable/clear,
coarse timings including invalid numbers, rejected sensitive-shaped metadata,
snapshot immutability, demo isolation, offline power restrictions, navigation and
volume limits, and absence of retained text in the demo status.

Strict formatting, project plist and source-target checks, credential scans,
release fixture checks, and internal release preflight passed. A signed generic
simulator build-for-testing compiled the app, unit tests, and UI tests. A Release
simulator build verifies the demo remains available outside DEBUG configuration.

An isolated macOS 14 Swift package compiled the unchanged real controller, store,
and protocol dependencies and ran 30 repository tests in seven suites. All passed, including
13 sensitive-metadata cases, four normalized-name cases, held candidate A/B state
projection, producer-owned snapshots during teardown, command/text completion
after Clear or consent changes, in-flight connection clearing, and A→B→A wake
lease invalidation. No dependency stubs, TV traffic, or Keychain operations were
used by the fixtures. The independently supplied provisional-cancellation and
terminal-failure probes first reproduced three assertions on unchanged `4de1dde`;
all passed after repair. New coverage includes newer-request wins, canceled and
same-TV/raw-address waiters, old versus fresh health activity, lifecycle and
network-grace completions, and automatic failure after Clear/reconsent. A subsequent
independent review reproduced four pending-retry assertions on unchanged
`efed315`. Expanded tests reproduced eight assertions across connection, health,
command, and deferred teardown after Clear/reconsent. All passed after the causal
scheduling repair, with a new timer-fired retry still recording connection
readiness. Including the unchanged independent retry probes, the final harness
passed 32 tests in eight suites. The temporary packages were removed. The iPhone
UI journeys compiled and still require execution in the integrated gate. These
isolated results do not replace that gate or computer-use verification.

After rebasing the five support commits onto HR-045 `d574163`, the final
real-source harness passed 64 tests in eleven suites. This adds the current
convenience and Sony pairing ownership suites, exhaustive offline command
coverage, held convenience success after Clear/reconsent, and 14 pending-retry
cases spanning connection, health, command, state-changing convenience,
optional-query, and canceled-write paths. Both current signed generic Debug
build-for-testing and Release build passed without warnings; both app seals
verified. Formatting, PBX validation, credential scan, release preflight and
compiler-probe regressions passed. The macOS harness omits the full controller
test file because its restoration test depends on the SwiftUI Home coordinator;
the signed iPhone test build compiles it. The complete iPhone gate remains
required after final integration.

The next interim integration onto HR-045 `eabc2c09` passed 120 real-source tests
in nineteen suites, including current Samsung/Vizio codec and Sony ownership
regressions. The diagnostic cancellation fixtures explicitly declare their
transport effect: invalidating cases enter recovery with the original collection
origin; cooperative cases stay connected and schedule no retry after Clear or
renewed consent. The parent driver's default, Sony override, active-router
forwarding, Vizio optional-rejection handling, and favorites behavior are retained.
This interim parent still requires its final review/merge and a final rebase.

Three focused native support journeys passed on an owned iPhone 16/iOS 18.5
simulator with zero failures or skips. They use the normal no-TV Home flow and
in-memory metadata, not a protocol driver or credential fixture. Diagnostics
coverage exercises default-off collection, lifecycle events, a preview that stays
immutable while collection changes, native share-sheet cancellation, clear,
disable/reconsent, and default-off relaunch. The demo journey covers navigation,
volume/mute, playback, disabled controls while off, text clearing, and fresh
state on re-entry. Largest accessibility text verifies scroll reachability and
44-point controls through the real sheet and keyboard viewport.

The re-entry regression first observed one visible volume label retaining
“Volume 21, muted.” Resetting the simulated model and text on appearance gives
each visit a fresh demo, and the test verifies Back reaches Help before re-entry.
Custom explanation/activity/footer text now uses semantic secondaryText, and
the report uses the theme canvas and onAccent share-button foreground. These
changes compile in Release-compatible views; final light/dark/increased-contrast
computer-use checks and the full integrated gate are still required.

Root integration must run the complete gate on the integrated current head and
exercise these flows with computer use: first launch → demo → navigate/volume/
mute/playback/power/keyboard → dismiss; Help → enable diagnostics → reproduce a
connection flow → preview → share sheet → cancel; clear/disable; compact iPhone,
largest practical Dynamic Type, light/dark, increased contrast, VoiceOver, and
Reduce Motion. Verify Release availability and no local-network prompt in demo.

No physical-TV behavior or release readiness is certified by this module. No
simulator, service, or browser resource was started during isolated development.

The final integration uses merged HR-045 parent `932070c`. Its hosted job ran
29 minutes 47 seconds, with the canonical gate taking 29 minutes 31 seconds.
The three added native support journeys take about 170 seconds locally, so the
workflow's bounded job allowance increases from 30 to 45 minutes. Commands,
assertions, test coverage, and existing skip policy remain unchanged; no blanket
retries are added.

A bounded computer-use smoke on an owned iPhone 17 Pro/iOS 26.5 observed first
launch Help, the clearly labeled demo at initial volume 20, default-off diagnostics,
report preview, native share presentation, cancellation back to the unchanged
report, and readable light/dark increased-contrast report controls. Only synthetic
and app/version content appears in the accompanying images. The iOS 18.5 CUA
bridge intermittently omitted the iOS accessibility subtree and did not scroll;
its actual three native tests remain the functional evidence. Complete Release
appearance/accessibility coverage belongs to HR-047. Both owned QA simulators
were shut down after the preparation phase.

The first integrated iOS 26.5 local and hosted gates both ran 422 declarations:
418 passed, four failed, none skipped. Three new support journeys exposed a
36-point native Home Help toolbar frame; the nested Help journey also found two
simultaneously exposed Done buttons. These failures are retained as evidence.
The repair uses an explicit plain 44-point label inside the Help button and
scopes dismissal queries to the active navigation bar. Dimension, consent,
immutable-preview, sharing-cancellation, and reset assertions remain in place.

CodeRabbit's first current-head review requested two changes: record successful
discovery completion and make the earlier demo-volume journey tolerate native
scrolling and asynchronous accessibility updates. Discovery now consumes the
scan's original collection lease on its first result or terminal state; further
updates cannot duplicate the event or revive collection after Clear, renewed
consent, or a TV change. Focused tests cover discarded and fresh scan leases.
The volume journey uses bounded gestures inside the visible scroll viewport
and waits for the observed value. The current full gate, hosted CI, and review
must confirm these repairs before merge.

The discovery repair also fences callback ownership at both TVDiscoveryStore
and CompositeTVDiscoveryBackend. Retained old found/finished/denied/failed
callbacks first reproduced six replaced-scan parameter failures plus a direct
composite failure against unchanged production sources. Each producer now
carries a process-local scan generation, invalidated before stop/cancellation;
timeout completion uses that same generation. Restart, explicit stop, Clear,
and renewed consent cannot forward the old scan into the current handler or
consume its token. Tests then require the genuine current scan to finish once.
These internal generations are never exported.

Native delegate origins are fenced before they can reach the upper callback:
Sony and Samsung require the current browser and tracked service; Samsung also
checks the pending validation operation after its awaited fetch. Vizio's local
browser delegate carries the originating browser and compares its identity
before registering a service or ending discovery. A held old-browser fixture
reproduced publication and termination of the replacement scan, then requires
both callbacks to be ignored and genuine replacement discovery to remain usable.
No physical occurrence is asserted by this synthetic regression.

On iOS 26.5 the system activity UI is a popover with a native dismiss region,
rather than the Close button exposed on iOS 18.5. The consent journey verifies
actual activity presentation, dismisses without choosing an export destination,
and verifies the same report plus Clear, disable, renewed consent, and relaunch.
Its native 26.5 run passed after this correction. Support/report Done controls
also use explicit 44-point labels, and Help is exercised by a near-corner tap
inside its rectangular hit region. Final affected-suite and canonical gate
results remain required; earlier failure bundles are preserved separately.
