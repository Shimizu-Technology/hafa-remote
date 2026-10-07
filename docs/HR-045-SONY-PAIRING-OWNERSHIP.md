# HR-045 Sony pairing ownership and focus repair

Sony's production pairing path awaited credential lookup/save and then closed a
shared pairing channel. A canceled or superseded attempt could resume after the
next TV began pairing and close that TV's channel. The outer connection-generation
check happened after this destructive operation.

Each attempt now owns a revocable channel lease. Replacement invalidates the old
lease synchronously before teardown or new work. Generation checks cover credential
lookup/save and the nested pairing exchange; scoped TLS connect/send/receive,
readiness, handshake, and disconnect operations check ownership at the channel
actor boundary. A close compares owner identity and can close only its own socket.
Cancellation handlers retain their captured connection, rather than closing a
mutable current connection. The teardown FIFO and existing controller/router
expected-device checks remain in place.

The production TLS actor explicitly implements the asynchronous check/disconnect
requirements, avoiding selection of compatibility defaults. Those defaults retain
existing injected test channels; the real TLS actor additionally checks socket-owner
identity before effects and buffer access.

App-link launch now clears IME focus/counters within the owned serialized write,
before dispatch and again after completion. Evidence arriving during that write
cannot restore the previous screen's field. Navigation, source, guide/channel,
digits, and power actions use the same invalidation rule. Volume/mute and keyboard
configuration keep their existing behavior; failed configuration still preserves
the preference/negotiation transaction. Text requires a new focus and new matching
counters, and an old operation cannot clear a replacement TV's evidence.

## Proof

The new production `connect()` tests enter the real private `pair()` path, hold
its actual credential lookup or save, and start B while A is suspended. B pauses
at its real pairing-code request. Resuming A must leave B's channel open; B then
completes the real codec/secret exchange and remote handshake and accepts an
ordinary command. Both caller cancellation and supersession without caller
cancellation are covered. The older synthetic connection helper is not used by
these regressions.

The identity provider seam uses a generated, in-memory synthetic client
certificate and injected non-network channels. Certificates/private keys use
public Security APIs and the existing certificate factory, are not persisted or
committed, and never reach household hardware. The DEBUG certificate reference
has no `SecIdentity`; the real TLS transport refuses it. Release uses the existing
real identity-store path, and the synthetic certificate initializer is excluded.

The baseline real-source run reproduced both lookup/save channel closures and
stale IME text after app launch/tuner commands. After repair, all 55 tests across
five portable suites passed, including 12 new parameter executions and existing
keyboard transaction, TLS deadline, Unicode, router, and transport-cancellation
regressions. The portable package uses unchanged Core/Protocol source files,
excluding discovery, with no runtime dependencies or production stubs. A stale
Sony handshake expectation was aligned with HR-045's existing tuner/source key
capability mapping; no capability or command was added by that expectation change.

Signed generic iOS Simulator Debug build-for-testing and Release build passed,
along with both bundle-seal checks, strict formatting, project plist validation,
and release preflight. No simulator was booted and no TV was contacted. Root must
integrate this commit, run the complete current-head gate/review, and retain the
separate physical-TV acceptance and public-distribution gates.
