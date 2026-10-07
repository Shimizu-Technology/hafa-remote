# HR-044 — Warm teal native design

Hafa Remote should feel welcoming on first launch and immediate during everyday control. This ticket implements the approved Warm teal direction in SwiftUI for iPhone users controlling their TV on the home network.

## Scope

- Semantic ivory/teal colors in light appearance and graphite/mint colors in dark appearance, including stronger Increased Contrast values.
- Rounded remote controls with quick press feedback that respects Reduce Motion, a coherent navigation pad, and a distinct OK control.
- A clear TV heading, nearby volume and utility groups, separate Play and Pause commands, and a keyboard row with truthful focus guidance.
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
- [ ] Inspect light/dark, largest accessibility text, Increased Contrast, and Reduce Motion on native simulator screens; repair any issues found.
- [ ] Complete current-head reviewer coverage before merge.

## Verification at implementation handoff

Swift syntax parsing, strict formatting across all targets, credential scanning, release preflight fixtures, release preflight, and diff whitespace checks passed. Palette contrast was calculated from sRGB values: light primary text 13.88:1, secondary text 6.02:1, action label 6.64:1, and control border 3.66:1; dark values 15.59:1, 7.84:1, 8.75:1, and 4.20:1 respectively.

Native UI tests and the full gate remain pending coordinated Xcode verification. Static parsing does not prove type checking or runtime behavior. No simulator, browser, server, or other persistent development resource was started by this ticket's implementation agent.
