# HR-054 — Keep saved-TV recovery alive after common failures

The November 1, 2026 audit found that ordinary Samsung failures ended in a dead-end state. These fixes keep the remote recovering on its own, which is also what the App Review hardware video needs to show.

## Defects and changes

| Defect | Cause | Change |
| --- | --- | --- |
| A TV that is off, booting or at a new address ends in "Connection issue" with no retry, no address recovery, and a false "Couldn't Turn On TV" after wake | Every Samsung connect starts with the HTTP device-information probe, whose `SamsungDeviceInfoError` was not classified, so the controller chose `.failed(.unexpected)` | `unavailable` and `invalidResponse` are offline for a remembered TV, so the existing bounded retry and `.offline` address recovery run. `invalidResponse` at a new manual address stays `.unsupported` |
| After turning the TV off from the app, a warm reopen stays "Disconnected" until Retry | `powerOffAndDisconnect` cleared the only reconnect target | The target is parked and restored on the next foreground return. It does not reconnect immediately or on network return. Explicit connect, disconnect, forget and unsupported-brand paths clear it |
| Every public saved TV is named "Samsung TV", and the discovery identity is never stored | The public Samsung witness returned `pair(target:)` without `applyingDiscoveryMetadata(from:)` | The public witness applies the advertised name and discovery identifier, as the internal multi-brand driver already does |
| Cancelling Find TV during recovery stops the saved TV's recovery | Setup disconnected any non-connected session when it closed | Setup disconnects only a connection it started itself |
| Forget TV during an in-flight reconnect can restore the credential | The credential was removed before the session stopped | The affected session stops first, then the credential is removed |

The Samsung device-information identifier is intentionally not renormalized. Saved credentials are keyed by it, and changing it would orphan existing pairings. Rediscovery now uses the stored discovery identifier instead.

## Verification

- New controller tests cover both device-information failures, reached through retry, plus fresh-address unsupported, power-off then foreground reconnect, no reconnect on network return after power-off, and disconnect clearing the parked target.
- A new coordinator test covers advertised-name and discovery-identity retention.
- The complete gate covers both audiences.
- Physical behavior is checked by Leon on the public TestFlight candidate: TV off and on with the app open; power off from the app, then reopen; wake from standby; and, where practical, a DHCP address change.
