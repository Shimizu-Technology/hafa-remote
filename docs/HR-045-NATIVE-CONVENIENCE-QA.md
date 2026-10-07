# HR-045 native convenience acceptance

The convenience acceptance fixture runs the real SwiftUI remote, extra-controls
form, session store, controller, and local preference model with a synthetic
driver. It does not instantiate a network transport, discovery service, or
Keychain store. Every address is RFC 5737 documentation data. The fixture and
its launch route are compiled only with `DEBUG`.

The fixture uses one explicitly disposable UserDefaults suite. Starting the
fixture resets only that suite; the app's standard domain is never cleared.
`RemoteConvenienceContext` accepts an optional preference instance for isolation,
and ordinary application contexts retain the existing shared preference model.
The in-memory app launch flag prevents persisted real TV records from loading.

## Native checks

The six `HafaRemoteConvenienceUITests` flows exercise:

- Samsung source-menu, channel, guide, and digit semantic requests; returned app
  launch; sent feedback without a claim that the TV displayed an app.
- Samsung favorites saved without launching, scoped to the connected TV across
  A/B/A switching, and removable from that TV.
- Vizio returned input selection, saving and naming an ordinary current-app
  descriptor, launch feedback, and absence of guide, digits, and keyboard.
- Sony configured links, negotiated keyboard preference changes, absence of the
  keyboard control after disabling, and a useful focused-field error.
- Sony unnegotiated optional features remaining absent.
- Dark appearance and the largest accessibility text size, a semantic swipe
  movement, and return to the accessible Buttons fallback.

The test trace records synthetic semantic requests and text character count,
never text contents. Launch completion means a local request was sent to the
fake driver; it is not a physical-TV acknowledgement.

## Touch targets

Native accessibility frames exposed that an outer frame did not enlarge the
keypad button's inner label target, and app-name buttons had text-sized targets.
The frame and rectangular content shape now belong to each button label. Native
tests check both keypad dimensions and the app-launch height against 44 points.
The separate app-name and favorite-star buttons use borderless styles, preventing
the form row from dispatching both actions.

## Verified evidence

A signed build-for-testing and all six native UI tests passed on the owned iPhone
SE (3rd generation), iOS 26.5 simulator. Strict Swift formatting, project plist
validation, and diff whitespace checks passed. The final result bundle is
`/tmp/hafa-hr045-native-qa/ConvenienceUITests4.xcresult`; its three retained visual
attachments cover Samsung extra controls, Vizio saved-app feedback, and the dark
large-text Buttons fallback.

Computer use on the same exact simulator confirmed Buttons → Swipe → Buttons,
the compact daily-control layout, Samsung source/channel/guide taps, and Vizio
Refresh Inputs showing the two synthetic returned choices followed by selection
of Synthetic Console. The optional DEBUG `-convenience-start-more` flag opens the
same form directly for manual checking. Initial form queries can run before the
scene becomes active with this flag; use Refresh Inputs/Apps in that case. Normal
UI tests navigate from the active remote and exercise automatic initial queries.

The Simulator computer-use bridge sometimes omitted app accessibility nodes and
did not reliably perform touch scrolling. Manual taps used fresh screenshots;
native XCTest touch swipes exercised the longer forms, favorites, and Sony
keyboard flows. These two forms of evidence are kept distinct. The largest-text
volume captions still wrap Down/Mute across two lines; that existing remote
layout detail was reported to the integration owner rather than widened into
this convenience slice.

## Remaining integration gates

The orchestrating branch must run the full gate, review the integrated current
head, and preserve the remote's D-pad and volume controls before the navigation
picker and extra controls. This fixture establishes native interaction and
capability presentation only. Physical Samsung, Sony, and Vizio protocol behavior
and household hardware acceptance remain separate gates.

## Inspectable visual evidence

These app-only captures contain synthetic QA data. They show presentation and
interaction guidance, not hardware compatibility or App Store marketing claims.
Pixels were inspected before inclusion; no household address, identifier, token,
certificate, Wi-Fi name, or entered text is visible.

- [More Controls and TV-reported synthetic apps](evidence/HR-045/more-controls-synthetic.png), retained from the native convenience run described above.
- [Largest accessibility text in dark Swipe mode](evidence/HR-045/largest-text-swipe-synthetic.png), retained from the integrated native repair's actual touch/CUA QA. Its wrapped instruction and Buttons fallback were exercised; native XCTest additionally proved complete gesture geometry and scrolling.

## Dispatch witness reliability

Hosted CI on `f0b30c7` failed the largest-text swipe test's three-second
`command:right` expectation. The retained screenshot and event show a fully
visible pad and a horizontal drag; the failed accessibility query contained no
matching trace element. The unchanged compiled baseline reproduced a missing
trace after Select in one of three executions; the other two passed. This
evidence identifies an unreliable diagnostic witness, without establishing a
production gesture failure.

That test now enables the existing DEBUG visible-trace flag. The trace occupies
an opaque bottom safe-area inset, uses a bounded diagnostic font, and cannot
receive touches. The test requires its presence before input and records its
baseline and geometry. Failures retain the live observer state, application
hierarchy, and screenshot. Real Right drag, Select tap, and Buttons-Up assertions
retain their exact semantic values and three-second bounds. Production gestures,
drivers, and command dispatch are unchanged.

On the owned iPhone 17 Pro / iOS 26.5 simulator, the instrumented largest-text
case passed six executions with zero failures or skips. Two identical
three-repetition test actions produced that count. The complete seven-case
convenience class then passed with zero failures or skips. Result bundles are
`/tmp/hafa-hr045-swipe-witness/visible.xcresult` and
`/tmp/hafa-hr045-swipe-witness/all-convenience.xcresult`; the complete current-head
gate and hosted CI remain separate integration requirements.
