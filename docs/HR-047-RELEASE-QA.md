# HR-047 internal-candidate release preparation

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

Physical execution of that discovery test and final integrated gate/review remain
pending. Simulator compilation does not certify household hardware acceptance.

## Historical preparation evidence

- Signed simulator build-for-testing passed on owned iPhone 16 Pro, iOS 18.5;
  bundle seal verification passed. Build log and DerivedData are preserved under
  `/tmp/hafa-hr047-validation/`.
- Release preflight and its fixture tests, strict Swift formatting, shell syntax,
  secret scanning, and diff checks passed. Metadata stays within release-validator
  limits; source app and extension remain version 1.0, build 7.
- Computer use inspected the installed original icon on SpringBoard and
  Settings → Apps; screenshot paths are recorded in HR-047-APP-ICON.md. The
  source PNG hash remains `22feaff50af5677b7a6b96a1743f2c14aa86a4bf87429a6b9029dd6d59b6c2ec`.
- The existing native My TVs → Add TV regression passed with
  `-collect-test-diagnostics never`; ordinary results are retained in
  `/tmp/hafa-hr047-validation/LibraryRouteUITests.xcresult`. The physical discovery
  test itself was not run.
- Final integration must repeat the full gate/current-head review, verify the
  support/privacy wording and App Privacy answers, and complete the physical-TV
  matrix. These local checks do not close those gates.

The exact owned simulator `F0B487C5-9A60-4CEC-BA76-21B9EE05CFF2` was shut down
after QA, its window closed, and owned build/test wrappers released. Lifecycle
status reports no active resources for this task owner. Shared infrastructure and
other agents' simulators were left unchanged; inert evidence files are retained.
