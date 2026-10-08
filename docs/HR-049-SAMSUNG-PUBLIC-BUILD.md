# Samsung public build and internal testing

HR-049 adds `HafaRemotePublic` with `DebugPublic` and `ReleasePublic`. The existing `HafaRemote` Debug/Release scheme retains the three-brand internal product and its complete test targets. Both products keep the app and Control Center bundle identifiers and local storage schema. This ticket does not upload a public candidate or approve submission.

The compiled flavor must match its Info.plist audience. A mismatch constructs no network driver or discovery backend. Public composition uses the Samsung coordinator directly; Sony/Vizio protocol files, transports, discovery backends, the experimental router and its UI harness are excluded from public compilation. The shared discovery coordinator and neutral errors remain available independently. Public Bonjour metadata declares only `_samsungmsf._tcp`.

Persisted brand tags and favorite descriptors remain Codable. They are migration data in the public product; executable Sony link values/names/catalogs are excluded. Public selection, restoration, backfill and pending-removal processing admit only known Samsung records. Experimental and unknown-brand records remain on the phone, with their credentials, pending deletions and favorites intact. A Samsung preference save retains the experimental dictionary entries. Public credential cleanup rejects unsupported brands before changing session ownership or invoking a driver.

The direct Samsung `RemoteSessionDriving` conformance forwards the supplied stable identity when forgetting pairing. Its production existential-dispatch regression first failed without that witness, then passed with the explicit bridge: intended credential A is removed, credential B at the same synthetic cached address remains, and no device-information request occurs. Address-only cleanup remains limited to unsafe legacy address credentials.

Run both audiences with `./scripts/gate.sh`. It runs the retained internal suite, builds the public Release simulator app, checks actual compiler inputs/link maps/executable tokens, then runs dedicated public unit and native UI targets. A zero-match compiler-list selector is rejected. Inert persistence tags are allowed; experimental drivers, services and launch catalogs are not.

Prepare source or artifact checks with `./scripts/ios-release-preflight.sh --audience public`. Internal remains the default. Plist services, compilation conditions, source exclusions, archive/IPA audiences and packaging options must agree. Public export options are separate from the unchanged Internal Only options. `ios-release.sh --audience public upload` remains closed until HR-051's release evidence and decision are complete; selecting a build flavor cannot waive that gate.

## Verification before the final commit gate

| Evidence | Actual result |
| --- | --- |
| Dedicated public unit and five native journeys | 17 declarations /25 executions, zero failures/skips |
| Retained internal unit suite | 386 declarations /515 executions, zero failures/skips |
| Public Release app | Signed simulator build, seal and exclusion validation passed; two architecture compiler lists and two link maps inspected |
| Audience preflight fixtures | Both audiences pass; cross-audience plists/options and experimental public service declarations rejected; public upload remains rejected |
| Native computer use | Actual PublicRelease first launch, Help, Samsung pairing guidance, clearly simulated demo with Select feedback, diagnostics off and report preview inspected |
| PublicDebug fixtures | Non-networking manual picker contains only Samsung; mixed library exposes only Samsung and reports three records retained, one connection attempt, zero credential removals |

The initial public fixture run failed because normal private-address validation correctly rejected RFC5737 documentation addresses. Fixtures now use the explicit DEBUG test constructor and an injected restoration target resolver; production address validation and Codable decoding remain unchanged. The UI test uses the child sheet's disappearance and fresh Help navigation as its transition milestone, then performs a real demo Select tap. No product delay or gesture change was added.

Final canonical gate, current source review and hosted CI are required after the source commit. These targeted results do not replace them. Physical TV behavior, spoken VoiceOver, compatibility/model coverage and the final distribution decision are separate evidence; none is fabricated here.

## Visual evidence

The app-only captures in [evidence/HR-049](evidence/HR-049) are actual PublicRelease 1.0 (8) on an owned iPhone 17 Pro Max simulator at native 1320×2868. Every PNG's pixels were inspected for privacy and truthful labeling. They show an unpaired app, explicitly simulated demo or empty diagnostics; they are not connected-TV or hardware evidence. Final store screenshots and candidate validation belong to HR-050/HR-051.

During manual Release QA the Mac Simulator accessibility bridge did not expose app elements, so computer use relied on fresh screenshots and visible controls. PublicDebug native XCTest assertions and the manual flows passed; this is not a spoken VoiceOver certification. Task-owned QA resources were stopped after this phase; borrowed simulators and other owners' browser resources remain untouched.
