# Samsung Q70AA hardware acceptance

Record results without IP addresses, MAC addresses, tokens, certificate
fingerprints, Wi-Fi names, or typed private content.

## Test environment

- Date: September 5, 2026
- TV model: Samsung Q70AA
- TV firmware:
- iPhone model: iPhone 15 Pro Max; iPhone 17 Pro simulator used for the separate discovery check
- iOS version: 18.7.8 on iPhone; 26.5 on simulator
- App version:
- Build number:
- Release commit:
- Validated archive application identifier:
- Network condition: same private non-guest Wi-Fi

## HR-002 pairing proof

Repeat the automated discovery check with the iPhone and TV awake on the same Wi-Fi:

```bash
xcodebuild test \
  -project HafaRemote.xcodeproj \
  -scheme HafaRemote \
  -destination 'platform=iOS,id=<IPHONE_UDID>' \
  -only-testing:HafaRemoteUITests/HafaRemoteUITests/testHardwareDiscoveryFindsSamsungTV
```

The test grants the expected Local Network prompt and fails unless a verified Samsung TV row
appears within 15 seconds. On a connected iPhone it continues through physical approval, sends
Select, relaunches the app, and requires the saved pairing to reconnect. The deterministic gate
explicitly skips it because it requires the household TV; run it separately against either a
simulator on the same LAN or a connected iPhone.

- [x] Add Samsung TV found the Q70AA without entering an address.
- [x] The discovered row showed a useful TV name and model.
- [x] First launch reached the TV approval flow.
- [x] Choosing Allow completed secure pairing.
- [x] The physical iPhone sent Select over the active Q70AA connection.
- [ ] A tester visually confirmed the focused TV item changed after Select.
- [x] Force-quit and relaunch reconnected without another approval prompt.
- Connection time: 5.6 seconds from tapping the discovered Q70AA to the Connected remote.
- Notes: The selected physical-device UI test passed in 25.5 seconds. It granted the expected
  Local Network permission, discovered the Q70AA, paired, sent Select, terminated Hafa Remote,
  relaunched it, and required Connected state again. The result bundle is kept locally and the
  committed record omits device identifiers and household network details.

## HR-007 discovery recovery

- [ ] Scan Again finds the Q70AA after a no-result search.
- [ ] Turning the TV off removes it from a fresh search without showing a stale result.
- [x] Manual address entry is hidden under TV not showing up?.
- [x] Discovery requires no multicast entitlement and performs no subnet scan.
- Notes: The hardware-backed UI test discovered and verified the powered-on Q70AA in under seven
  seconds from the simulator on the same LAN. No household network identifier was recorded.

## HR-004 control soak

- [ ] D-pad/select
- [ ] Home/back
- [ ] Volume up/down and mute
- [ ] Play/pause, rewind, and fast-forward
- [ ] Power-off confirmation and command
- [ ] Fifty mixed commands without a crash, stuck repeat, duplicated command, or lost session
- Notes:

## HR-005 lifecycle

### Internal TestFlight acceptance

- [ ] Ten background/lock cycles completed
- Healthy background/lock reconnects within two seconds: __ / 10 (at least 9 / 10 required;
  8 or fewer blocks internal TestFlight)
- [ ] TV restart recovery without manual re-pairing
- [ ] App force-quit/relaunch recovery without manual re-pairing
- [ ] Wi-Fi loss and recovery without losing the saved pairing token
- [ ] Pairing-token invalidation rejects the old token and completes re-pairing
- Notes:

### Public-review evidence

- [ ] Twenty foreground reconnect cycles completed
- Foreground reconnects without re-pairing: __ / 20 (at least 19 / 20 required)
- Healthy foreground reconnects normally completed within two seconds
- Notes:

## HR-006 text and power truth

- [ ] Text sent into a normal TV search field.
- [ ] A screen that ignores remote text was explained honestly.
- [ ] Text was not echoed into logs, screenshots, or diagnostics.
- [ ] Pairing tokens, network identifiers, and certificate fingerprints are absent from ordinary app logs.
- [x] Power on remains unavailable in this build.
- [x] No MAC address is collected while Wake-on-LAN is unavailable.
- [x] No multicast entitlement or broadcast sender is included.
- Notes: Apple requires the multicast networking entitlement for broadcast
  Wake-on-LAN. Request and physical wake testing are separate gates.

## Go/no-go

- Decision: Pending physical evidence
- Open P0/P1 defects:
- Go is allowed only when every required check passes, physical evidence is complete, and Open P0/P1 defects is `None`.
- Tester:
