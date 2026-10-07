# HR-045 — Supported remote conveniences

Hafa Remote now offers source and channel controls, per-TV app favorites, optional
discrete swipe navigation, and negotiated Sony keyboard input. Each feature uses
the existing local session and serialized command stream. No app catalog or icon
is downloaded, no developer mode or ADB is used, and no runtime dependency is added.

The first integrated gate passed 367 of 373 tests. It exposed cancellation recovery
being applied to cooperative drivers, old Sony capability fixtures, and two native
gesture/recovery test issues. A semantic driver contract now reports whether a
cancelled write can close its transport. The controller captures that contract
within the command generation and only reconnects for such drivers; Sony reports
the effect, and the multi-brand router forwards the active driver's contract.
Cooperative cancellation retains the connected session. The persistence fixture
now states its observed key-only capabilities explicitly, and preferences are
forgotten from memory only after the bounded encoded update is persisted.

All 145 controller, convenience, and saved-TV tests passed after these repairs,
with no failures or skips. The initial function-filtered verification selected
zero Swift Testing cases and is not passing evidence; the complete suites are the
verified result. The canonical gate now disables verbose sysdiagnose collection
using Xcode's supported option. It retains assertions, test results, screenshots,
and the same tested scope. Native and protocol review repairs, the final full gate,
current-head CodeRabbit coverage, and hosted CI are still required before merge.

## Implemented paths

| Feature | Samsung | Sony Remote Service v2 | Vizio SmartCast |
| --- | --- | --- | --- |
| Source chooser | `KEY_SOURCE` | Key 178 | Code set 7, code 1 |
| Named input selection | Unavailable | Unavailable | Returned input names, fresh `HASHVAL` |
| Channel up/down | `KEY_CHUP` / `KEY_CHDOWN` | Keys 166 / 167 | Code set 8, codes 1 / 0 |
| Guide | `KEY_GUIDE` | Key 172 | Unavailable |
| Number pad | `KEY_0` through `KEY_9` | Keys 7 through 16 | Unavailable |
| App shortcuts | TV-reported app list and launch type | Four configured app links | Save current app ID and namespace |
| Keyboard | Existing local text path | IME feature bit, focused field, matching counters | Unavailable |
| Swipe navigation | Existing semantic D-pad commands | Same | Same |

These paths describe implemented protocol behavior. They do not certify command
delivery on a particular TV, tuner, external device, or streaming application.
Power, identity, certificate trust, and public-distribution gates from HR-042 and
HR-043 remain in force.

Samsung requests `ed.installedApp.get` and parses only bounded, validated app
records. A socket has one pending query, with a three-second deadline. Timeout or
cancellation closes app discovery until the next socket, so a late response cannot
answer a later indistinguishable request. A new socket owns a new query actor. A
favorite launch validates its ID and launch type against the last successful
catalog for the current socket, querying first only when no catalog exists.
A failed refresh preserves that catalog for launches but cannot reopen uncorrelated
queries; late responses cannot replace it. Reconnection starts a fresh catalog.
Service/factory/reset/internal-tool entries are excluded. App support
becomes protocol-available only after a valid response, not from a brand name.

Vizio reads the TV's input list, accepts only returned input `NAME` values, and uses
`VALUE.NAME` or `VALUE` as the optional display nickname. Selecting an input checks
the list again, reads the current input's fresh `HASHVAL`, and then writes
`REQUEST: MODIFY`, that hash, and the returned name. The hash is not persisted.
Favorites retain only validated `APP_ID` and `NAME_SPACE`; non-null, nonempty
`MESSAGE` and casting namespace zero are excluded. Launch always uses a null
message. No stream URL, content state, or token enters a favorite. Input/app
capability evidence comes from successful optional reads.

Sony requests implemented features and always intersects with the reported mask.
IME uses bit 4; app links use bit 512. Configured links are YouTube, Netflix, Prime
Video, and Disney+, represented by a fixed enum. They are not an installed-app
inventory and never open a browser or perform an iPhone HTTP request. The local
launch request passes the selected link to the TV. There is no arbitrary intent,
URL, package action, or settings shortcut.

Sony text requires a focused field and matching IME/field counters each refreshed
within 15 seconds. Focus and counter timestamps are independent: a repeated focus
event cannot renew expired counters, and a counter update cannot renew old focus.
Incoming text, label, and package content is discarded. Text
selection indices count UTF-16 units. Navigation, power-off, standby, disconnect,
reconfiguration, and a completed text send clear focus evidence. After sending,
focus must be established again rather than reusing old counters. A per-TV
keyboard preference is applied during connection and can be disabled if the TV's
onscreen keyboard becomes unavailable. Missing/stale focus produces a useful
focus-field message without declaring the whole remote disconnected.

A keyboard configuration is proposed without changing local state, written through
the serialized stream, and committed only after successful delivery and current
generation/identity checks. Failed or cancelled writes preserve the previous
preference and feature mask. Saved UI preferences change only after the current
controller operation returns successfully. A cancelled state-changing write can
cancel Sony's whole TLS connection, so the controller tears down that generation
and reconnects instead of retaining a connected claim. Unsupported optional reads
remain soft failures. Missing Sony protocol model names use the static label
Sony Google TV; household display names never become diagnostic model data.

Connection attempts also own their cleanup generation. A cancelled attempt whose
TLS callback arrives after another TV connected cannot reset or disconnect the
replacement. Teardown uses a separate serialized FIFO and rechecks ownership
between suspension points; replacement connection work waits for that teardown.
Cancelled TLS sends/receives check cancellation before reading a shared current
connection. A held-callback regression releases cancelled A only after B is ready,
then verifies B remains connected and accepts an ordinary command.

The brand router also owns an attempt generation for both address and target
connection paths. It checks cancellation and ownership after every suspended
preparation/connection and before identity validation or activating a route.
Validation cleanup is limited to the current attempt. Pairing-code brokers are
per attempt, and replacement connections await any captured teardown task, so
late cancellation or cleanup cannot affect the replacement's broker or transport.
Held-result spies cover stale Samsung address completion and stale Sony target
completion, including an invalid identity released only after Samsung is ready.

## Ownership and interaction

Favorites and Sony keyboard preferences are bounded local records keyed by brand
plus authenticated stable TV identity. Up to 12 favorites per TV and 100 TV
preference records are accepted. Forgetting a saved TV removes its preferences.
No pairing credential is stored with a favorite. Launch requests are described as
sent; display execution is never asserted.

The preference blob uses the app's standard UserDefaults domain, rather than an
app group, global domain, or cloud preference store. It contains noncredential
local metadata: app names/launch descriptors, brand-scoped stable TV association,
and a keyboard toggle. It uses the iOS app sandbox and system storage protection;
no custom encryption or file-protection class is claimed. Ordinary device backups
may include these preferences. Pairing tokens, private keys, raw certificates,
addresses, MACs, Wi-Fi names, entered text, and dynamic playback messages are never
written to the blob. Stable associations stay local and are omitted from reports.

The app manifest declares UserDefaults with own-app reason CA92.1. The control
extension remains stateless with no required-reason API declaration; the validator
checks them separately. This declaration covers local API use and is separate
from App Store Connect's Data Not Collected answer. Apple describes CA92.1 for
reading/writing data accessible only to the app itself, excluding other apps' and
system-written data. [Apple required-reason documentation](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons?language=objc).

The remote offers explicit Buttons and Swipe modes. A completed swipe must exceed
24 points and have a dominant axis; diagonal/jitter input is ignored. One swipe
produces at most one ordinary movement, and a tap selects. Buttons remain the
default and accessible fallback. The swipe surface also exposes VoiceOver actions.
There is no mouse protocol, macro, gesture repeat queue, or long-held TV key.

View tasks are cancelled on dismissal, backgrounding, and disconnect. Home actions
carry their captured stable TV key. The controller checks both expected identity
and its connection generation immediately before queued execution, and rejects
stale results after suspension. Power-off sends and conditional teardown share one
controller ownership generation; late A teardown cannot close or clear B. Wake
operations recheck selection revision/cancellation before reconnecting and send
power-on with a captured stable key. Rebound aliases wait for expected authenticated
identity. Unsupported optional-feature errors preserve ordinary remote controls;
uncertain state-changing writes recover the transport. Convenience operations have a ten-second outer deadline; normal command
deadlines remain unchanged.

Manual setup includes an explicit brand chooser: Samsung secure port 8002, Sony
control port 6466 with its separate pairing exchange, and Vizio port 7345. A known
saved Vizio legacy port 9000 is retained during repair; a new legacy-9000 manual
option is not exposed. The factory accepts only an already validated private IP.
The address locates a pairing candidate, never selects credentials or becomes
stable identity. A saved repair retains the expected authenticated ID and discovery
alias; switching brands discards that association. Production validation continues
to reject documentation/public addresses.

## Evidence and remaining acceptance

Strict Swift formatting, project plist validation, and a signed simulator
build-for-testing passed with the Xcode compiler-probe workaround. The build
compiled the app, unit tests, and UI tests. Focused automated cases cover mapping,
privacy/ownership, bounded Samsung queries, Vizio fresh-hash request order, dynamic
payload rejection, Sony Unicode/focus/counter behavior, manual brand routing,
delayed view actions, and queued requests across TV switching. Runtime test results
passed in an isolated macOS 14 Swift package: all 13 new tests passed using the
unchanged core and protocol sources. After material review fixes, all 25 focused
tests passed, including failed/cancelled configuration writes, independent IME
freshness, timeout recovery, stale power-off/store projection, alias identity,
stale wake guards, and late connection cleanup ownership, and stale router result ownership. The package included the real controller and
HTTPS client; the Vizio transaction used an injected URLProtocol and RFC 5737
address, with no TV contact. The temporary package was removed. These results do
not replace the integrated iPhone simulator gate or real UI checks.

Root integration must merge the native HR-044 layout and HR-042 discovery-row
association follow-up without weakening these expected-key/generation checks. Then:

1. Run the complete gate on the integrated current head and inspect the diff.
2. Use computer control to verify Buttons/Swipe switching, compact/large Dynamic
   Type, light/dark, increased contrast, VoiceOver, Reduce Motion, More Controls,
   favorite save/remove/forget, failed queries, keyboard-disabled state, and each
   manual-brand pairing presentation.
3. Reproduce TV A → TV B switching while a request or gesture is pending; verify
   no old action reaches B. Repeat background/disconnect cancellation.
4. On each household TV, validate source/guide/channel/digit behavior where offered,
   returned input selection, supported favorites, and focused text in system
   search plus an app. Record unsupported app/model behavior honestly.

No physical-TV acceptance is certified by this ticket's isolated development. No
simulator, browser, server, or household TV was started or contacted by this agent.

## Protocol references

- [Samsung remote command and app envelopes](https://github.com/xchwarze/samsung-tv-ws-api/blob/master/samsungtvws/remote.py)
- [Samsung installed-app response handling](https://github.com/ollo69/ha-samsungtv-smart/blob/master/custom_components/samsungtv_smart/api/samsungws.py)
- [Android TV feature negotiation and IME behavior](https://github.com/tronikos/androidtvremote2/blob/main/src/androidtvremote2/remote.py)
- [Android TV protobuf schema](https://github.com/tronikos/androidtvremote2/blob/main/src/androidtvremote2/remotemessage.proto)
- [App-link examples and known limitations](https://www.home-assistant.io/integrations/androidtv_remote/)
- [Vizio endpoint and key definitions](https://github.com/raman325/pyvizio/blob/master/pyvizio/const.py)
- [Vizio input request behavior](https://github.com/raman325/pyvizio/blob/master/pyvizio/api/input.py)
- [Vizio app launch schema](https://github.com/raman325/pyvizio/blob/master/pyvizio/api/apps.py)

These references informed a native implementation. Their code licenses and
interoperability evidence do not establish permission to distribute a brand's
control protocol publicly. The existing separate distribution decision still
applies.

## Final review follow-up

The first combined head `3a98a52` passed the complete canonical gate: 380 tests /
429 executions, zero failures or skips, followed by signature, installation and
launch checks. A completed 43-file CodeRabbit CLI pass identified three further
functional issues. Vizio server rejection of an optional request now leaves
ordinary controls available, while transport and pairing errors retain their
existing handling. Samsung app socket writes preserve cancellation and report
existing typed transport failures so recovery can run. A saved, validated Vizio
favorite remains requestable after reconnect before any current-app read;
this does not establish an installed-app inventory.

Regression coverage checks rejected read/launch/input requests followed by an
ordinary command, app-write error normalization, and native launch of a saved Vizio
favorite without newly reported optional support. Public synthetic visual evidence
is linked from the native QA record. The resulting head still requires its complete
gate, current native QA, reviewer coverage and hosted CI before merge. Hardware
acceptance and public distribution remain separate.

The GitHub outside-diff manual-address note was accepted only for an unpaired
candidate. Its discovery alias and observed legacy port now stay with the address
where they were found. An authenticated saved identity intentionally survives a
manual DHCP repair, including a known Vizio legacy port; an unexpected TV still
fails identity validation. Dropping that identity merely because an address
changed would weaken the saved-TV boundary and was rejected. Factory regressions
cover fresh changed-address pairing, same-endpoint legacy candidates, and
identity-preserving legacy repair. This core follow-up requires its own current
head gate/review; the previous gate result is retained as historical evidence.
