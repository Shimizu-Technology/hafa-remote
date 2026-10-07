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

- Add the four new app sources and two test sources to the Xcode project source
  lists. This project uses explicit PBX groups rather than synchronized folders.
- Keep one DiagnosticRecorder owned by the app/session store, default disabled.
- Add a Help NavigationLink to DiagnosticsView(recorder: recorder,
  metadata: .current(tvModel: verifiedModel, tvFirmware: verifiedFirmware)).
- Record reviewed events at session/discovery boundaries. Map known typed state
  and failures to DiagnosticEventKind; never interpolate an Error or raw protocol
  response. Provide measured monotonic operation duration only when available.
- Add NavigationLink("Try the Remote", destination: DemoRemoteView()) to first
  launch and Help. Opening it must not call real setup/discovery or alter saved
  TV selection. A modal entry should wrap the demo in NavigationStack with Done.
- Both screens use HafaTheme; the new shared native palette applies automatically.
- Clear the recorder when changing selected TVs if report metadata identifies the
  current model. Otherwise events from more than one TV can be grouped under the
  current model, which would mislead support.

## Acceptance and evidence

Automated coverage verifies opt-in behavior, bounded collection, disable/clear,
coarse timings including invalid numbers, rejected sensitive-shaped metadata,
snapshot immutability, demo isolation, offline power restrictions, navigation and
volume limits, and absence of retained text in the demo status.

Isolated verification passed: all four app modules and their existing core/theme
dependencies typechecked against the iOS simulator SDK in Swift 6 mode. A
temporary macOS 14 Swift package compiled the unchanged core/model sources and
ran nine tests in two suites, including 13 metadata rejection cases; all passed.
The temporary package was removed. This checks the same models and tests without
booting a simulator; it does not replace the integrated gate or UI checks.

Root integration must run the complete gate on the integrated current head and
exercise these flows with computer use: first launch → demo → navigate/volume/
mute/playback/power/keyboard → dismiss; Help → enable diagnostics → reproduce a
connection flow → preview → share sheet → cancel; clear/disable; compact iPhone,
largest practical Dynamic Type, light/dark, increased contrast, VoiceOver, and
Reduce Motion. Verify Release availability and no local-network prompt in demo.

No physical-TV behavior or release readiness is certified by this module. No
simulator, service, or browser resource was started during isolated development.
