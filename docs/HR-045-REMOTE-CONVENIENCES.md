# HR-045 — Supported remote conveniences

Hafa Remote now offers source and channel controls, per-TV app favorites, optional
discrete swipe navigation, and negotiated Sony keyboard input. Each feature uses
the existing local session and serialized command stream. No app catalog or icon
is downloaded, no developer mode or ADB is used, and no runtime dependency is added.

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
favorite launch refreshes the list and requires its ID and launch type to still
appear. Service/factory/reset/internal-tool entries are excluded. App support
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

Sony text requires a focused field and matching IME/field counters refreshed
within 15 seconds. Incoming text, label, and package content is discarded. Text
selection indices count UTF-16 units. Navigation, power-off, standby, disconnect,
reconfiguration, and a completed text send clear focus evidence. After sending,
focus must be established again rather than reusing old counters. A per-TV
keyboard preference is applied during connection and can be disabled if the TV's
onscreen keyboard becomes unavailable. Missing/stale focus produces a useful
focus-field message without declaring the whole remote disconnected.

## Ownership and interaction

Favorites and Sony keyboard preferences are bounded local records keyed by brand
plus authenticated stable TV identity. Up to 12 favorites per TV and 100 TV
preference records are accepted. Forgetting a saved TV removes its preferences.
No pairing credential is stored with a favorite. Launch requests are described as
sent; display execution is never asserted.

The remote offers explicit Buttons and Swipe modes. A completed swipe must exceed
24 points and have a dominant axis; diagonal/jitter input is ignored. One swipe
produces at most one ordinary movement, and a tap selects. Buttons remain the
default and accessible fallback. The swipe surface also exposes VoiceOver actions.
There is no mouse protocol, macro, gesture repeat queue, or long-held TV key.

View tasks are cancelled on dismissal, backgrounding, and disconnect. Home actions
carry their captured stable TV key. The controller checks both expected identity
and its connection generation immediately before queued execution, and rejects
stale results after suspension. Optional-feature errors preserve ordinary remote
controls. Convenience operations have a ten-second outer deadline; normal command
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
unchanged core and protocol sources. The package included the real controller and
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
