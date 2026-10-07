# HR-043 — Truthful power state and capability evidence

A reachable control service does not prove that its TV screen is awake. Hafa Remote now represents screen power as **unknown**, **on**, or **standby**, independently of connection state.

## Behavior

- Sony preserves the power boolean received during the authenticated handshake and publishes subsequent power changes. Missing or invalid power fields are ignored instead of becoming standby. Configuration and active replies advertise only the intersection of the requested feature bits and the TV's reported bits; key support remains mandatory. Controls not negotiated by Sony are unavailable.
- Vizio reads `GET /state/device/power_mode` with the saved `AUTH` token. A successful numeric `VALUE` of `1` means on and `0` means standby. Missing, malformed, rejected, or unsupported observations mean unknown. This follows the maintained [pyvizio power-state API](https://github.com/raman325/pyvizio/blob/master/pyvizio/__init__.py); Hafa accepts only the two known numeric states.
- Samsung reads optional `PowerState` metadata. Absent, unrecognized, or malformed power metadata stays unknown. Its observed identity must still match the connected saved TV.
- The controller accepts observations only for the active generation and authenticated device identity. Live Sony events update immediately; health checks refresh optional observations for other drivers. Power-on also requests a bounded observation refresh. Disconnect, backgrounding, switching, and cancellation clear observation subscriptions, and the UI stops presenting old screen power.
- A connected TV reporting standby offers Power On and pauses ordinary controls. When power is unknown, the interface says so and offers an explicit power-on action. Eligible wake remains usable during automatic reconnect; pairing approval still blocks unrelated actions.
- Automatic reconnect has five delayed attempts after the initial attempt. Retry, Find TV, and settings actions remain available during recovery and afterward. Certificate and expired-pairing states use deliberate Find TV recovery.
- Samsung wake reconnects to the saved identity rather than an address-only target. A socket reconnect or a power report does not grant hardware wake verification.

## Capability and distribution policy

Capability evidence separates driver implementation, negotiated/reported support, and explicit hardware verification. Sony availability follows negotiation. New saved records retain reported evidence; hardware evidence is never inferred from a connection or legacy automatic wake flags. Previously recorded explicit hardware evidence survives only an unchanged identity, model, and firmware.

The current build explicitly identifies itself as an **internal candidate**. The public runtime policy denies all unresolved brands, and release preflight rejects public distribution until the brand hardware and protocol-rights decisions are approved. Archive and export checks require the same distribution audience as the source. This keeps internal TestFlight testing available without presenting an unvalidated driver as public support.

## Verification and remaining acceptance

Focused regressions cover Sony power and feature negotiation, malformed power fields, authenticated Vizio request paths, Samsung optional power parsing, capability evidence, public-policy rejection, observation identity/generation boundaries, stale-power reset, bounded retry, hardware-evidence provenance, connected-standby controls, and wake during reconnect.

Strict formatting, credential scans, release fixture checks, and internal release preflight passed. Public preflight rejects as intended. Signed generic simulator `build-for-testing` compiled the application and unit/UI test targets. The integrating session must execute the full gate, computer-use simulator journeys, and current-head CodeRabbit review before merge.

Physical power, network standby, DHCP changes, and wake acceptance remain pending for each exact household model and firmware. No hardware capability or successful power action is claimed from simulator evidence. No simulator, browser, server, or device was started by this implementation agent; generic build processes completed and their ownership records were released.
