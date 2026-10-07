# HR-045 protocol review repairs

Five reviewer leads were checked against the current source. The fixes stay in
protocol code and its tests; Core cancellation/persistence and UI changes are
owned by the integration branches.

## Samsung catalog lifetime

A successful, sanitized catalog now belongs to its socket's query actor. Launch
checks that catalog instead of always issuing another discovery request. A
timeout/failure still permanently closes uncorrelated app queries on that socket;
the last successful catalog remains available for launch. Late responses without
an active query cannot replace the catalog. Disconnect/reconnect creates a new
actor, and reset clears the catalog. An initially empty catalog is still evidence
that no shortcut was returned, rather than permission to launch an arbitrary ID.

The reviewer offered reopening queries after timeout as an alternative. That
option was rejected because the response carries no request identifier. A late
reply could be mistaken for the new query. No Internet catalog or icon is fetched.

## Sony text and retirement

Text checks cancellation/generation, transport liveness, keyboard negotiation,
standby, then focused-field counters. Stale operations throw CancellationError;
a dead transport reports connectionClosed; disabled/unnegotiated text reports
unsupportedTextInput; standby reports unavailable. Only missing/stale focus and
counters report textFieldNotFocused. Tests queue text behind held writes and
change each state before serialized execution, preventing entry-time checks from
falsely covering the private write path.

Teardown always retires both captured owner-scoped channels, even if its generation
was superseded while awaiting another channel. Reset of the observation broadcaster
remains current-generation-only. Real TLS retirement checks owner identity without
requiring a still-valid lease: a revoked matching owner is closed; a replacement
owner is preserved. Tests reproduce the skipped-old-control leak and exercise the
real actor's scoped dispatch using buffered synthetic data without a socket.

The production pairing lookup/save, lease, async dispatch, IME launch/in-flight
focus, and keyboard transaction proofs from the prior repair remain in the suite.

## Vizio same-input requests and allowlist

Selection still validates against the returned list and reads a fresh current
HASHVAL. If current VALUE uniquely matches the selected returned identifier or
returned alias, it returns without PUT. String VALUE and nested NAME/name forms
are supported; ambiguous aliases do not establish a match. Different or missing
values retain the existing fresh-hash PUT behavior. Missing hash, unsuccessful
responses, and unlisted requests remain errors. No speculative input identifiers
or new commands are added. Guide and every digit are explicitly asserted to throw
unsupportedCommand.

The primary interoperability implementation documents a TV rejecting selection
of an already-active input and the string/nested-name variants:
[vizaio set_input](https://github.com/raman325/vizaio/blob/main/src/vizaio/_device.py)
and [input parsing](https://github.com/raman325/vizaio/blob/main/src/vizaio/parse.py),
checked October 8, 2026 (Guam). Those observations inform the bounded no-op check;
they do not certify every Vizio firmware or replace hardware validation. No code
or runtime dependency is imported.

## Evidence and boundary

The baseline real-source run reproduced 11 functional issues across cached launch,
queued text, skipped retirement, and redundant PUT assertions. The codec already
rejected all 11 unsupported Vizio keys; the new assertions protect that contract.
The repaired portable source suite passed 108 tests in 13 suites, including the
prior production pairing/focus proofs. HTTP uses synthetic URLProtocol responses,
RFC 5737 addresses, and isolated request probes; there is no hardware, real network,
or Keychain contact.

Signed generic iOS Simulator Debug build-for-testing and Release compilation pass.
Root will perform the full integrated iPhone gate, native QA, current-head review,
CI, and separate hardware/public-distribution acceptance. Local source proof does
not close those gates.
