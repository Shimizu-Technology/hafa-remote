# HR-044 — Warm teal native design

Hafa Remote should feel welcoming on first launch and immediate during everyday control. This ticket implements the approved Warm teal direction in SwiftUI for iPhone users controlling their TV on the home network.

## Scope

- Semantic ivory/teal colors in light appearance and graphite/mint colors in dark appearance, including stronger Increased Contrast values.
- Rounded remote controls with quick press feedback that respects Reduce Motion, a coherent navigation pad, and a distinct OK control.
- A clear TV heading, volume immediately below navigation on compact screens, utility controls below volume, separate Play and Pause commands, and a keyboard row with truthful focus guidance.
- A welcoming first-launch screen and Help accessible before pairing and during Add TV.
- Home-network, Ethernet, guest-network, Samsung approval, Sony code, Vizio PIN, and conditional wake guidance.

Existing command dispatch, repeat behavior, capabilities, credential handling, discovery, and power behavior are preserved. There are no input/app placeholder controls, numeric volume, inferred mute/playback state, new dependencies, or icon changes.

## Acceptance criteria

- [x] Implement the approved palette with semantic colors and separate action-label colors.
- [x] Keep SF Symbols, semantic fonts, and controls at least 44 points.
- [x] Respect Dynamic Type, dark appearance, Increased Contrast, and Reduce Motion in changed controls.
- [x] Expose Help before pairing; explain Wi-Fi/Ethernet and each brand's pairing flow.
- [x] Keep Play/Pause separate and preserve semantic commands and capability visibility.
- [x] Add UI coverage for Help, independent playback dispatch, and target sizes.
- [ ] Pass the full gate on the reviewed commit.
- [ ] Exercise first launch, setup/Help, saved-TV switching, remote control, keyboard, recovery, and power confirmation with computer use.
- [x] Inspect light/dark, largest accessibility text, and Increased Contrast on native simulator screens; repair issues found.
- [ ] Complete the physical VoiceOver and Reduce Motion journeys during the internal beta.
- [ ] Complete current-head reviewer coverage before merge.

## Verification

Swift syntax parsing, strict formatting across all targets, credential scanning, release preflight fixtures, release preflight, and diff whitespace checks passed. Palette contrast was calculated from sRGB values: light primary text 13.88:1, secondary text 6.02:1, action label 6.64:1, and control border 3.66:1; dark values 15.59:1, 7.84:1, 8.75:1, and 4.20:1 respectively.

Signed generic simulator build-for-testing compiled the app, extension, and test targets, and deep/strict codesign verification passed. Computer use on an isolated iPhone SE (3rd generation), iOS 18.5, exercised first launch, Help, setup presentation, Select and volume dispatch, and power confirmation. Native inspection covered light/dark appearance, Increased Contrast, and the largest accessibility text size. UI QA caught and repaired missing first-launch Help, sheet tint scope, and volume initially below the compact viewport.

The primary pressed state uses an opaque semantic color. Its action-label contrast is 7.75:1 in light appearance and 7.49:1 in dark appearance; Increased Contrast variants reach 11.82:1 and 9.84:1. Accessibility-sized controls retain larger targets. The largest text size uses the scrollable layout without truncating the selected TV or truthful power status.

Ten focused native UI tests passed with zero failures or skips, including Add TV, pre-pairing Help, separate Play/Pause dispatch, every remote control's minimum target size and Select dispatch, largest Dynamic Type reachability, keyboard delivery, power confirmation, standby power on, automatic recovery/wake, and My TVs Help. The computer-use tool did not scroll the simulator viewport; the passing XCUI touch-swipe journeys independently verified lower remote/keyboard and large-type reachability. Physical-TV behavior is not inferred from any synthetic UI journey. Root will perform the full integrated gate and reviewer loop before merge.

The initial focused run was interrupted during stalled verbose diagnostic collection and supplied no usable result. The definitive rerun used Xcode's documented `-collect-test-diagnostics never` option and finalized a passing result bundle. This skips sysdiagnose collection and does not suppress assertions or test results. The final integrated full gate remains the parent's responsibility.

The owned simulator was shut down, and build/test process ownership was released. Borrowed simulators and shared services were left running.

An additional compact-screen check during convenience QA found that the largest accessibility size split the volume captions across letters and misaligned the controls. Accessibility sizes now use full-width volume rows with preserved font scaling and button labels; ordinary sizes retain the compact horizontal group. Consistent 96-point accessibility action targets also prevent wider scaled SF Symbols from shifting the action column. The largest-text regression checks alignment, viewport containment, minimum target size, touch-scroll reachability, and all three semantic volume/mute actions. Native screenshot evidence shows intact Down, Mute, and Up captions with aligned action surfaces.

The follow-up signed simulator build and deep/strict codesign verification passed. Eight focused native UI tests passed with zero failures or skips, covering aligned large-text volume, largest-text keyboard reachability, regular remote dispatch/targets, separate playback, keyboard delivery, offline recovery, reconnect/wake, and standby power on. CUA inspected the actual compact dark/largest-text remote, but its drag/wheel/keyboard scroll attempts still did not pan the viewport. The updated largest-text capture therefore comes from actual XCTest touch gestures and was inspected as a native app screenshot. No screenshot is substituted for physical-TV acceptance.

## Visual evidence

These app-only captures show synthetic UI test data, not hardware acceptance or App Store marketing claims:

- [Compact light remote](evidence/HR-044/compact-light.png)
- [Compact dark with Increased Contrast](evidence/HR-044/compact-dark-increased-contrast.png)
- [Largest accessibility text with aligned volume rows](evidence/HR-044/largest-type-dark.png)
