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
and protocol dependencies and ran 19 tests in three suites. All passed, including
13 sensitive-metadata cases, four normalized-name cases, held candidate A/B state
projection, producer-owned snapshots during teardown, command/text completion
after Clear or consent changes, in-flight connection clearing, and A→B→A wake
lease invalidation. No dependency stubs, TV traffic, or Keychain operations were
used by the fixtures. The temporary package was removed. The iPhone UI journeys
compiled and still require execution in the integrated gate. These isolated results do not replace that gate or
computer-use verification.

Root integration must run the complete gate on the integrated current head and
exercise these flows with computer use: first launch → demo → navigate/volume/
mute/playback/power/keyboard → dismiss; Help → enable diagnostics → reproduce a
connection flow → preview → share sheet → cancel; clear/disable; compact iPhone,
largest practical Dynamic Type, light/dark, increased contrast, VoiceOver, and
Reduce Motion. Verify Release availability and no local-network prompt in demo.

No physical-TV behavior or release readiness is certified by this module. No
simulator, service, or browser resource was started during isolated development.
