# Sony control protocol decision

**Decision date:** September 5, 2026  
**Scope:** HR-021 personal/internal alpha only

## Decision

Hafa Remote will use Android TV Remote Service v2 for a Sony BRAVIA/Google TV that advertises `_androidtvremote2._tcp` and completes the secure pairing handshake on the household network. The Sony driver remains capability-gated until Leon's television passes discovery, pairing, relaunch, command-soak, reconnect, power-off, and wake testing.

The app will not silently fall back to subnet scanning or treat an IP address as the television's identity. Sony IRCC-IP remains out of scope unless the exact household model fails the Android TV path and exposes a documented secure IRCC setup.

## Evidence and boundaries

- A sanitized Bonjour probe on Leon's local network found two `_androidtvremote2._tcp` services on the expected control port, 6466. The advertisements did not expose enough non-sensitive metadata to prove which instance is the Sony, so selection still requires a live handshake and on-TV pairing confirmation.
- Android's open-source Google TV pairing implementation defines the Polo pairing state machine used here. The app uses the six-character hexadecimal pairing flow and derives the pairing secret from the client and server RSA public keys.
- The open-source `androidtvremote2` project provides an Apache-2.0 interoperability reference for the service names, ports, message shapes, and current Android TV Remote Service behavior. It is research evidence, not a linked or copied runtime dependency.
- Google does not publish this as a supported consumer-app SDK. That uncertainty is acceptable for a household/internal alpha but remains a distribution review gate.

## Implementation constraints

- Generate one 2048-bit RSA client key on device and keep the private key non-exportable in the iOS Keychain.
- Construct and store the matching self-signed client certificate locally. Never commit or ship a shared private key or certificate.
- Accept the television's self-signed certificate only during an explicit, user-selected pairing flow. After pairing, require the exact saved certificate fingerprint for control connections.
- Store Sony trust material under Sony-specific Keychain services. Samsung and Vizio code cannot read, reuse, or delete it.
- Encode the bounded protocol subset directly in Swift. No protobuf or Android-TV package is added to the app binary.
- Expose only semantic `RemoteCommand` values to the UI. The Sony module alone maps them to Android key codes.
- Treat the current power key as a toggle until hardware behavior is proven. Do not label wake as supported merely because power-off works.

## Sources

- Android Open Source Project, Google TV Pairing Protocol: <https://android.googlesource.com/platform/external/google-tv-pairing-protocol/>
- Android TV Remote Service v2 interoperability reference (Apache-2.0): <https://github.com/tronikos/androidtvremote2>

