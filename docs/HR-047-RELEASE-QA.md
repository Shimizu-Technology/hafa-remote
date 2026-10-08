# HR-047 integrated internal-candidate release QA

The three icon/metadata commits are integrated onto actual HR-046 squash
`1e6898c891475a7120cca5be9e5029007f19d399`, which includes HR-041 through HR-046.
The ticket also applies the approved semantic text, canvas and concrete row surfaces
to More Controls. Full current-head gate, native Release QA, review and hosted CI
are required before merge; their final evidence will be recorded on the ticket PR.
Build numbers stay at 7 until
HR-048 checks App Store Connect. No upload, metadata publication, or website
change is performed by this ticket.

## Source-based notes

- First-launch Help → Try the Remote Offline enters the explicitly simulated,
  Release-compatible demo without discovery, credentials, real-TV persistence,
  or network commands.
- Help → Diagnostics is off by default, holds at most 100 semantic events/coarse
  timings in memory, and provides Preview Support Report before Share This Report.
  ShareLink exports an immutable preview only through the user's chosen system
  share destination. Clear/disable clears live events; an open preview is unchanged.
- Sony keyboard and configured links depend on feature negotiation. Text also
  needs the per-TV setting and current focus/counters. Links are configured
  shortcuts rather than installed inventory. Vizio provides returned inputs and
  ordinary current-app favorites, without guide, digits, or text.
- Production reconnect uses five delays and does not repeat the last indefinitely.
  Recovery presents available wake, Retry Connection, and Find TV. Saved identity
  is distinct from cached addresses/aliases; collisions and saved-pairing repair
  require deliberate selection or My TVs → Forget TV → Add TV.
- Native Warm teal accessibility and the original icon are described without
  claiming physical-TV delivery or universal compatibility.

## Exact live URLs

Read-only curl checks on October 8, 2026 (Guam) returned HTTP 200 for:

- [Support](https://shimizu-technology.com/hafa-remote/support)
- [Privacy](https://shimizu-technology.com/hafa-remote/privacy)

Both responses serve the site's JavaScript application shell. The referenced
deployed bundle contains separate support/privacy page components and maps each
exact pathname to its corresponding component. This verifies route/content
availability from the served source, not a completed browser-rendering check.

The deployed privacy wording broadly says the developer collects no app data,
while also describing support contact. It does not explain the new optional
diagnostic preview/share feature. The support page similarly predates the new
demo, diagnostic, and convenience paths. Before public submission, reconcile
those published pages with the final binary and actual support handling. HTTP
success alone does not close that wording gate. This ticket does not publish
changes to either page.

## Privacy interpretation

Apple distinguishes data processed only on the device from data transmitted and
available to the developer beyond servicing the request. Voluntarily sharing a
report with support can therefore require disclosure even without a backend or
automatic upload. All optional-disclosure criteria must hold; opt-in alone is
insufficient. SUBMISSION.md preserves the owner's final App Privacy verification
gate rather than presuming that Data Not Collected covers every support path.
No collection SDK, backend, automatic uploader, or new consent flow is added.

Primary sources checked October 8, 2026 (Guam):
[Apple App Privacy details](https://developer.apple.com/app-store/app-privacy-details/)
and [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy).

## Test tooling

The canonical gate retains the `-collect-test-diagnostics never` flag introduced by
HR-045, with exactly one copy after integration. The installed Xcode documents it
as suppressing verbose diagnostic collection.
It avoids the previously observed sysdiagnose stall and incidental host-log
collection. Test assertions, ordinary activity/results, and retained screenshot
attachments remain. No new test skip is added. The existing physical discovery
test remains separately executed on borrowed iPhone/TV hardware; its saved-TV
route now uses My TVs → Add TV instead of the removed change-TV button.
Its connected-session assertion accepts either Connected or the explicit
Connected • TV power unknown label; standby still fails the enabled-control check.

Physical execution of that discovery test remains pending. Simulator compilation
does not certify household hardware acceptance.

## Integrated native evidence

The production code in `e8eeda1dbd2da97df7eebd36f0e97e778a8adff0` passed the
complete canonical gate: 427 tests, zero failures and zero skips. The hosted
[iOS gate](https://github.com/Shimizu-Technology/hafa-remote/actions/runs/37706872613)
also passed. The signed Release simulator build and strict bundle-seal validation
passed. The final documentation/screenshots commit changes no production code;
its exact-head gate, reviewer coverage and CI are recorded on [PR 44](https://github.com/Shimizu-Technology/hafa-remote/pull/44)
before merge.

Actual Release computer-use checks used owned iPhone 17 Pro, iPhone 17 Pro Max
and iPhone SE (3rd generation) simulators on iOS 26.5, without TV discovery,
pairing or a real television:

- First launch remained unpaired. Help opened before setup; the offline demo
  showed its simulation label and did not request Local Network permission.
- Right/Select focused and opened the simulated Listen tile. Volume changed
  from 20 to 21; mute, play/pause and power worked in the simulation. Power-off
  disabled ordinary controls; power-on restored them. Native synthetic text
  entry cleared after sending and reported only its 14-character count.
  Returning to the demo reset it to volume 20 and an unmuted initial state.
- Diagnostics started off. Explicit enable plus normal Home/app-switcher cycles
  produced only local lifecycle events. A held two-event preview stayed identical
  while newer events accumulated; a fresh preview showed the later events.
  The real system share sheet opened and was canceled without selecting a
  destination. The preview remained unchanged. Clear produced an empty report;
  disable/re-enable kept it empty; actual terminate/relaunch reset consent to off.
- The compact phone kept navigation, select and volume reachable through native
  scrolling. The large phone kept Help and demo controls usable at the largest
  accessibility text size, in dark appearance with Increased Contrast. Diagnostics
  actions also remained reachable at that size. No TV record was created.
- Actual iPhone Settings showed Reduce Motion and Reduce Transparency enabled.
  Release Help/demo navigation and control remained usable, with readable opaque
  dark surfaces. This is an operational check, not a frame-by-frame animation
  certification. Both preferences were restored to off; appearance, contrast and
  text size were restored to Light, normal contrast and Large before the final gate.
- Accessibility labels, order and exposed actions were inspected. This simulator
  did not expose a VoiceOver setting; a spoken physical-iPhone walkthrough remains
  pending and is not certified by an accessibility-tree inspection.
- The unchanged original icon was inspected in current Settings → Apps and native
  SpringBoard search. Initial grid drag/page-control attempts were ineffective;
  they are not counted as an icon verification result.

The first fresh Pro Max launch did not return an app process while its system
icons were still placeholders. Its scoped SpringBoard log reported an already
pending process, without an app-specific crash. That bounded attempt was stopped
and its device/window cleaned. After the headless gate, the same device rebooted
in 13 seconds and the actual Release launch and large-screen checks passed.
Transient missing accessibility nodes during sheet animations were re-observed
after settling; missing-state assertions were not counted as passes.

More Controls was exercised separately in a clearly synthetic DEBUG fixture,
with no network or Keychain implementation. Source-menu dispatch, the returned
synthetic app list and a launch request retained their semantic behavior. The
result said **Request sent. Check the TV for the result.** It did not claim that
an app opened on hardware. These fixture images are not Release hardware evidence.

### Rendered contrast

Read-only pixel analysis of both 1206 × 2622, untagged synthetic screenshots
confirmed the exact opaque palette colors. Light secondary text `#59665E` appeared
in 37,478 pixels, canvas `#F7F5EF` in 1,406,118 and row surface `#FFFFFF` in
1,315,851. Dark secondary text `#AFBFBA` appeared in 37,478 pixels, canvas
`#111B1C` in 1,454,185 and surface `#1C292B` in 1,325,366. No image was edited
or assigned a color profile for this check.

Standard relative-luminance calculations for these rendered solid pairs give
5.52:1 for light text/canvas, 6.02:1 for light text/row, 9.17:1 for dark
text/canvas and 7.84:1 for dark text/row. This closes the observed 3.29:1 custom
gray-footer pair. It does not certify every system control, disabled state or
anti-aliased edge. Background modifiers are attached to concrete rows, following
[Apple's row-background API](https://developer.apple.com/documentation/swiftui/view/listrowbackground(_:)).

### Safe screenshots

| Evidence | Configuration |
| --- | --- |
| [First launch](evidence/HR-047/release-first-launch-light.png) and [offline demo](evidence/HR-047/release-offline-demo-light.png) | Actual Release, iPhone 17 Pro, Light |
| [Share sheet](evidence/HR-047/release-diagnostics-share-sheet.png) | Actual Release, local lifecycle report, canceled without sending |
| [Largest diagnostics](evidence/HR-047/release-diagnostics-largest-dark.png) | Actual Release, largest text, Dark/Increased Contrast |
| [Large phone](evidence/HR-047/release-large-phone-light.png) and [large demo controls](evidence/HR-047/release-large-demo-largest-dark.png) | Actual Release, iPhone 17 Pro Max |
| [Compact home](evidence/HR-047/release-compact-home-light.png) and [compact controls](evidence/HR-047/release-compact-demo-controls.png) | Actual Release, iPhone SE (3rd generation) |
| [Reduced preferences](evidence/HR-047/release-demo-reduced-motion-transparency.png) | Actual Release, verified Reduce Motion/Transparency enabled |
| [Light More Controls](evidence/HR-047/more-controls-synthetic-light.png) and [Dark More Controls](evidence/HR-047/more-controls-synthetic-dark.png) | Synthetic DEBUG fixture, no TV traffic |
| [Settings icon](evidence/HR-047/icon-settings-apps.png) and [SpringBoard search icon](evidence/HR-047/icon-springboard-search.png) | Current installed original artwork |

Hardware/model coverage, protocol-distribution basis, published support/privacy
reconciliation and owner App Privacy answers remain pending public-release gates.
The numeric grid currently follows the correctly labeled semantic order 0–9;
the more familiar 1–9/0 arrangement is nonblocking future polish, not a hardware
or release defect established by this ticket.

All owned manual-QA simulators were shut down/released and their task windows
closed before this evidence update. Borrowed simulators and protected services
were untouched. Final headless gate resources are separately claimed and cleaned.

## Historical preparation evidence

- Earlier, old-parent simulator build-for-testing and seal validation passed on
  an owned iPhone 16 Pro/iOS 18.5. These checks did not certify the integrated binary.
- Release preflight and its fixture tests, strict Swift formatting, shell syntax,
  secret scanning, and diff checks passed. Metadata stays within release-validator
  limits; source app and extension remain version 1.0, build 7.
- Earlier computer use inspected the original icon on SpringBoard and Settings.
  Current integrated screenshots are linked above. The
  source PNG hash remains `22feaff50af5677b7a6b96a1743f2c14aa86a4bf87429a6b9029dd6d59b6c2ec`.
- The existing native My TVs → Add TV regression previously passed with
  `-collect-test-diagnostics never`. The physical discovery test was not run.
- Final integration must repeat the full gate/current-head review, verify the
  support/privacy wording and App Privacy answers, and complete the physical-TV
  matrix. These local checks do not close those gates.

The earlier preparation simulator was shut down after QA, its window closed,
and owned build/test wrappers released. Lifecycle
status reports no active resources for this task owner. Shared infrastructure and
other agents' simulators were left unchanged; inert evidence files are retained.
