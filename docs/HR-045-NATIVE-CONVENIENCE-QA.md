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
