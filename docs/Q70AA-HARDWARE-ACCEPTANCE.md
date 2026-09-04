# Samsung Q70AA hardware acceptance

Record results without IP addresses, MAC addresses, tokens, certificate
fingerprints, Wi-Fi names, or typed private content.

## Test environment

- Date:
- TV model: Samsung Q70AA
- TV firmware:
- iPhone model:
- iOS version:
- Network condition: same private non-guest Wi-Fi

## HR-002 pairing proof

- [ ] First launch reached the TV approval prompt.
- [ ] Choosing Allow completed secure pairing.
- [ ] Select changed the focused TV item.
- [ ] Force-quit and relaunch reconnected without another approval prompt.
- Connection time:
- Notes:

## HR-004 control soak

- [ ] D-pad/select
- [ ] Home/back
- [ ] Volume up/down and mute
- [ ] Play/pause, rewind, and fast-forward
- [ ] Power-off confirmation and command
- [ ] Fifty mixed commands without a crash, stuck repeat, or lost session
- Notes:

## HR-005 lifecycle

- [ ] Ten background/lock cycles completed
- Healthy reconnects within two seconds: __ / 10 (10 / 10 required; any lower result blocks release)
- [ ] TV restart recovery
- [ ] App force-quit/relaunch recovery
- [ ] Wi-Fi loss and recovery
- [ ] Pairing-token invalidation and repair
- Notes:

## HR-006 text and power truth

- [ ] Text sent into a normal TV search field.
- [ ] A screen that ignores remote text was explained honestly.
- [ ] Text was not echoed into logs, screenshots, or diagnostics.
- [x] Power on remains unavailable in this build.
- [x] No MAC address is collected while Wake-on-LAN is unavailable.
- [x] No multicast entitlement or broadcast sender is included.
- Notes: Apple requires the multicast networking entitlement for broadcast
  Wake-on-LAN. Request and physical wake testing are separate gates.

## Go/no-go

- Decision: Pending physical evidence
- Open P0/P1 defects:
- Tester:
