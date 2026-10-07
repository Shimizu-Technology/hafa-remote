# HR-042 — Keep saved TV identity through reconnect and rediscovery

A remembered address can be reassigned to a different, already paired TV. Connecting the selected saved TV must verify its authenticated identity before using a credential or activating commands.

## Acceptance criteria and implementation

- Saved targets carry an explicit expected device identity. Discovery candidates carry a separate, non-secret discovery identifier; a service-name hash never selects a saved certificate pin.
- Samsung and Vizio reject a mismatched device-info identity before looking up or presenting a credential. A rejected attempt closes its transport and preserves existing credentials.
- Sony selects the remembered certificate pin from the expected saved identity, and keeps its existing pinned TLS connection checks. A remembered identity with no saved pin cannot silently become new pairing.
- The router validates the final brand and expected identity before activating command routing.
- A successful first pairing promotes the controller's reconnect target to the authenticated identity.
- Sony service-name hashes and Vizio fallback identifiers are persisted separately from authenticated device identity. Address recovery matches that discovery alias, then binds the candidate to the selected saved identity. A candidate at the unchanged endpoint cannot cause a retry loop merely because its metadata differs.
- Identity mismatches present a useful Find TV message. Certificate failures can search for a moved endpoint without clearing or bypassing certificate trust.

## Verification

Deterministic regressions cover already-paired wrong targets for Samsung and Vizio, router rejection before commands, Sony hash/fingerprint collisions, preserved expected Sony pins, moved Sony candidates, Sony/Vizio alias rebinding, same-endpoint alias collisions, SwiftData alias persistence, and first-pair foreground reconnect promotion.

Credential scans, strict Swift formatting, release fixture checks, release preflight, and generic simulator `build-for-testing` passed locally. The generic build compiles the app and both test targets; it does not execute tests. The integrating session must run the complete gate, simulator journeys, and current-head code review before merge. Physical DHCP-change and certificate checks remain hardware acceptance work.

New networked-test-double endpoints use RFC 5737 addresses through a DEBUG-only fixture initializer. Normal initialization, decoding, and Release builds retain the strict private/link-local network policy.

## Recovery limits

Old Sony/Vizio records have no discovery alias. Selecting the TV once from discovery associates its current advertisement with its authenticated identity while retaining its credential. A renamed Bonjour service may likewise require selecting the TV again. The implementation never guesses among unrelated candidates or relaxes a saved certificate pin to recover an address.

No simulator, server, browser tab, or device was started by the implementation agent. Generic build processes completed and their lifecycle records were released. The worktree remains available for the integrating session's full gate and review.
