# HR-056 — Review-facing remote clarity

These are small changes from the November 1, 2026 design audit. They affect what an App Review tester or a first-time user sees in the first minute. The larger remote redesign items are deferred to a later release: Back and Home placement, haptics, motion, and building the demo from the real remote controls.

## Changes

- **Standby:** the remote shows a "Your TV is in standby" card. When power-on is available, the card includes a prominent **Turn On TV** button. The status line uses a standby glyph in the warning color instead of a green check.
- **Offline:** when power-on is available, **Turn On TV** is the primary recovery action and Retry becomes secondary. Otherwise Retry stays primary.
- **Reconnecting:** the recovery text no longer says the TV is offline while a reconnect is in progress.
- **Connected with unknown power:** the explicit power-on link reads "Screen dark? Turn On TV". It no longer looks like the opposite of the red power-off key beside it.
- **Status glyph by state:** a check when connected; a moon in standby; the rotating-arrows glyph while reconnecting or approving; an alert glyph for the other states.
- **Accent color:** the asset AccentColor was a low-contrast cyan (about 1.85:1 on white) and leaked into system-tinted controls such as the My TVs "•••" menus. It now uses the theme teal, with dark and high-contrast variants.
- **First-launch demo:** **Try Without a TV** on the first-launch screen opens the labelled offline demo. Before, the demo was only reachable through Help.

## Verification

- A public UI test opens the demo from the first-launch screen.
- Existing recovery UI tests still find the Retry and Find TV actions.
- Required: the full gate passes for both audiences. Results are recorded on the PR.
- Simulator screenshots of standby, offline and first launch are captured for the release packet in HR-057.
