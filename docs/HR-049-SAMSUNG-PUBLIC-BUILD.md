# Samsung public build and internal testing

HR-049 adds `HafaRemotePublic` with `DebugPublic` and `ReleasePublic`. The existing `HafaRemote` Debug/Release scheme retains the three-brand internal product and its complete test targets. Both products keep the app and Control Center bundle identifiers and local storage schema. This ticket does not upload a public candidate or approve submission.

The compiled flavor must match its Info.plist audience. A mismatch constructs no network driver or discovery backend. Public composition uses the Samsung coordinator directly; Sony/Vizio protocol files, transports, discovery backends, the experimental router and its UI harness are excluded from public compilation. The shared discovery coordinator and neutral errors remain available independently. Public Bonjour metadata declares only `_samsungmsf._tcp`.

Persisted brand tags and favorite descriptors remain Codable. They are migration data in the public product; executable Sony link values/names/catalogs are excluded. Public selection, restoration, backfill and pending-removal processing admit only known Samsung records. Experimental and unknown-brand records remain on the phone, with their credentials, pending deletions and favorites intact. A Samsung preference save retains the experimental dictionary entries. Public credential cleanup rejects unsupported brands before changing session ownership or invoking a driver.

The direct Samsung `RemoteSessionDriving` conformance forwards the supplied stable identity when forgetting pairing. Its production existential-dispatch regression first failed without that witness, then passed with the explicit bridge: intended credential A is removed, credential B at the same synthetic cached address remains, and no device-information request occurs. Address-only cleanup remains limited to unsafe legacy address credentials.

Run both audiences with `./scripts/gate.sh`. It runs the retained internal suite, builds the public Release simulator app, checks actual compiler inputs/link maps/executable tokens, then runs dedicated public unit and native UI targets. A zero-match compiler-list selector is rejected. Artifact requirements use explicit failures that remain active with `PYTHONOPTIMIZE=1`. The gate also tests a valid actual artifact and harmless signed negative fixtures for forbidden executable markers, missing compiler inputs/link maps, experimental source and driver objects. Full validation derives architectures from the actual executable and requires compiler and link-map evidence for every slice; removing either evidence type for one slice is rejected. Inert persistence tags are allowed; experimental drivers, services and launch catalogs are not.

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

The first canonical gate on `2b64daf` failed three retained internal native flows (427 declarations/556 executions, three failures, zero skips). Their recorded scroll gestures landed on the navigation-mode picker on the larger iPhone, leaving the More Controls link below the viewport. The test helper now drags at a fixed eight-point margin outside interactive rows; product gestures and all semantic assertions remain unchanged. All seven affected convenience native flows then passed on the same Pro Max, with zero failures/skips. Public stages were not reached in that failed run.

Current review also identified that Python optimization disabled the initial artifact validator's `assert` checks. A valid signed simulator fixture containing an experimental service marker reproduced acceptance in both modes. Explicit checks and optimized-mode rejection fixtures repair this boundary. The internal unit target retains only its Debug/Release configurations; public tests use the dedicated public targets. A discovery fixture now records an unexpected construction failure without force-try or a fabricated product error.

The complete canonical gate passed on `70bf202`: internal 427 declarations/556 executions and public 17/25, zero failures/skips, signed public binary exclusion, optimized-mode fixtures, and both install/launch checks. A later review found that a nonempty evidence set could still omit one executable architecture; a real signed universal app with only its arm64 compiler/link evidence reproduced that gap. The validator now derives the binary's architecture set and requires both evidence types for every slice. That repair still requires a fresh current-commit gate, source review and hosted CI. Final completion receipts are recorded in the PR. These targeted results do not replace those checks. Physical TV behavior, spoken VoiceOver, compatibility/model coverage and the final distribution decision are separate evidence; none is fabricated here.

## Visual evidence

The app-only captures in [evidence/HR-049](evidence/HR-049) are actual PublicRelease 1.0 (8) on an owned iPhone 17 Pro Max simulator at native 1320×2868. Every PNG's pixels were inspected for privacy and truthful labeling. They show an unpaired app, explicitly simulated demo or empty diagnostics; they are not connected-TV or hardware evidence. Final store screenshots and candidate validation belong to HR-050/HR-051.

During manual Release QA the Mac Simulator accessibility bridge did not expose app elements, so computer use relied on fresh screenshots and visible controls. PublicDebug native XCTest assertions and the manual flows passed; this is not a spoken VoiceOver certification. Task-owned QA resources were stopped after this phase; borrowed simulators and other owners' browser resources remain untouched.
