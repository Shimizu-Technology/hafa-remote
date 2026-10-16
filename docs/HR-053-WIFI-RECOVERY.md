# HR-053 — Automatic discovery after Wi-Fi returns

## Product brief and evidence

Hafa Remote is an iPhone local-network remote for family household TVs. It stores device metadata on the phone and brand-scoped credentials in Keychain. Public builds remain Samsung-only; Sony and Vizio remain experimental internal capabilities. Source baseline: merged `c346a93`, internal TestFlight 1.0(10). Sources: PRD.md, BUILD_PLAN.md, HR-052 and its final PR acceptance record. The family use case is documented in Brain-Dump's October4 company/project review. This ticket follows Leon's request to research, implement, review and deliver automatic recovery through TestFlight.

Leon reports Sony mostly working. The Vizio manual attempt failed while the phone displayed LTE, then paired successfully after joining home Wi-Fi; subsequent screenshots show its connected remote. This establishes operator-observed initial pairing, not a command soak, relaunch or standby matrix. Household screenshots and identifiers are not copied into this repository. The setup screen continued to show an earlier Vizio browser failure while PIN entry succeeded. Current setup starts discovery once, without observing Wi-Fi or foreground transitions; partial results have no rescan button and can hide missing-brand guidance.

Apple's [NWPathMonitor](https://developer.apple.com/documentation/network/nwpathmonitor) provides path hints, not TV handshake or permission evidence. [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) distinguishes Local Network permission and requires physical-device privacy testing. Unknown/requires-connection paths must not be called denied or unsupported. An inactive scene can be a system permission alert; background and foreground are distinct. Home Wi-Fi can use iPhone [Auto-Join](https://support.apple.com/en-gb/102480), but the app does not silently join networks or add remote-over-cellular infrastructure.

## Implementation acceptance

- Share Home's existing Wi-Fi monitor with setup. Unknown path allows the initial scan; known unavailable Wi-Fi explains the local-network requirement and waits. No SSID/address collection is introduced.
- Stop old discovery on Wi-Fi loss or backgrounding. On availability/foreground return, start one fresh bounded scan while visible and idle; reject late callbacks and post-dismissal work. Repeated available hints do not repeat scans. Ignore temporary scene inactivity.
- Do not replace connection admission, PIN entry, repair or saved-TV choice with a competing scan. Preserve manual address, brand, port and entered code. A path hint cannot cancel an active bounded handshake; protocol results remain authoritative.
- Show ongoing discovery beside early healthy results. Completed mixed-brand results retain missing/incomplete brand status and Scan Again. Hide old search failures while connecting/pairing.
- Keep existing saved-device identity, Keychain reuse and foreground reconnection. Admit saved-address recovery only in the active Home scene outside Add TV; recheck eligibility after discovery and identity resolution. Fix manual Vizio records lacking a Bonjour alias: inspect up to8 discovered Vizio candidates using the saved certificate and credential-free device-info reads, with a five-second work budget plus the final bounded two-second request. Match the saved serial, then require the normal pinned/token reconnect before persisting any address or alias. Deliver initial known path hints to the saved-session controller. Do not auto-select an unauthenticated candidate, delete credentials or bypass TLS.
- Use a fresh consent lease per scan, complete diagnostics at scan end, and keep existing redaction/public binary boundaries.
- Prepare the next live-verified unused internal build with matching app/control versions, pass the complete gate, native affected journeys, current-head review/CI, merge and verify Apple processing plus existing internal tester access. Public build9/submission remains separate.

## QA plan

Agent executes deterministic policy, session and native UI scenarios with RFC5737 synthetic endpoints. Native target: iPhone17Pro/iOS26.5. Retain existing public audience, saved switching/relaunch/background, Vizio saved-credential/PIN and diagnostic consent regressions in the complete gate. Exact tested commits, results, review, release provenance and cleanup receipts belong in the PR acceptance record so receipts do not change the source they certify.

| Case | Expected journey and evidence | Execution |
| --- | --- | --- |
| W01 | Initial Wi-Fi unavailable → clear guidance, no discovery → restore → Vizio found automatically, repeated available hint does not rescan | pending native/policy |
| W02 | Unknown initial hint, path flaps, background/foreground and dismissal → one owned scan, no invalid restart | pending policy/native |
| W03 | Sony found with absent or advertised-incomplete Vizio → useful details/rescan → both candidates, healthy Sony retained | pending native |
| W04 | PIN partially entered → path hint loss/return → digits/target remain, no extra scan, pairing completes | pending native/session |
| W05 | Existing saved-TV restore/reconnect and Vizio pinned-credential reuse → no new PIN or identity crossover | pending complete gate |
| W06 | Both audiences, diagnostics clear/reconsent, signatures, optimized public exclusion and release checks | pending complete gate |
| H01 | Physical iPhone install → Wi-Fi loss/return → Vizio discovery, saved reconnect and observed controls | operator retest after delivery; not certified by simulator |

No TV commands, pairing requests or settings changes are issued by the agent's synthetic QA. Real Wi-Fi and Local Network permission behavior, home multicast, observed buttons and standby remain explicitly limited by H01. Lifecycle session `01a1437b-f983-7ae0-a11c-fc6218e819b2`; baseline borrowed simulator and shared/protected services are preserved. Claim exact new resources and clean them after QA.
