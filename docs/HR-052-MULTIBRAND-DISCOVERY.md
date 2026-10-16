# HR-052 — Mixed-brand discovery and recovery

## Scope and acceptance

October 16, 2026. Leon requested implementation after the full audit at base `82299d5`: improve Sony/Vizio discovery and recovery while retaining Samsung behavior. The app is an iPhone local-network remote with no account/backend/SDK addition. Public composition remains Samsung-only; internal composition retains experimental Sony Android TV Remote v2 and Vizio SmartCast. Credentials remain brand-scoped in Keychain, addresses remain location caches, and selected stable identity and endpoint-scoped TLS remain mandatory.

This ticket makes the active scope visible, preserves safe per-brand discovery stages, retries Vizio service resolution once, and permits a new manually entered Vizio candidate to use either reviewed connection port. It also prepares the next multibrand internal build, 1.0 (10), with matching internal app/control versions and strict audience-specific preflight. Public configurations remain 1.0 (9). It does not certify household control, add an alternate Sony protocol, widen public brand exposure, upload a build or change TV/router settings. Larger remote styling and unrelated transport changes remain separate.

Acceptance:

- Setup, About and reports explain the active build support without implying universal brand/model compatibility.
- Resolution failure differs from no advertisement. A failed brand browser remains visible after the scan timeout, while healthy candidates remain selectable.
- Vizio has at most two five-second resolution attempts. A fresh NetService producer rejects the first attempt's late callbacks; stop/restart cancels all pending producers. A bounded twelve-second scan accommodates an early candidate's two attempts.
- Manual Vizio setup exposes an older-connection option for the explicitly entered host only. Only 7345/9000 are permitted; saved brand/identity expectations survive a port choice. No subnet scan, global TLS bypass, credential crossover or claim of command execution is added.
- Diagnostic search stages contain only reviewed brand/stage enums, stay bounded and memory-only, and use the scan's original opt-in consent lease through completion. Clear/disable/reconsent cannot revive old events.
- Both audience gates, affected native journeys, public binary exclusion, current CodeRabbit coverage and CI must pass before readiness. Physical compatibility remains governed by HR-021/022 and the existing hardware matrix.

## Current network evidence

The earlier audit observed an Android Remote candidate with reachable 6466/6467 and a visible Vizio advertisement whose Foundation service resolution timed out (-72007). These are Mac observations, not authenticated Sony identity or iPhone pairing acceptance.

A subsequent bounded read-only probe during this ticket found Vizio SRV/TXT, combined DNS-SD resolution and IPv4 A responses on reviewed port 7345. Foundation's five-second resolve also succeeded. AAAA did not respond in five seconds, which is immaterial to the app's current IPv4 path. The earlier failure is not currently reproducible; transient/service/cache conditions are hypotheses. DNS probes can warm shared cache. No permanent missing record or TV incompatibility is inferred.

No household values are committed here. Probes retained names/targets/record data only in memory and published sanitized categories/ports. They sent no pairing, remote or power commands. The selected Vizio subsequently returned HTTP200 and SmartCast SUCCESS from an unauthenticated, read-only device-information request on7345. The actual current codec decoded its modern ITEMS[].VALUE / SYSTEM_INFO envelope. Safely filtered model: V655-G9; firmware: 2.600.596.0-10. A fresh ephemeral TLS session accepted only that selected private endpoint/port; no global trust override, redirect, AUTH header, certificate persistence or pairing/command request was used. This proves current API/parser compatibility, not authorization or control. Installed household build/audience, iPhone permission and PIN/command/reconnect/standby acceptance remain unverified. Leon cannot check the installed Help scope right now.

## QA ledger

Agent-executed affected-flow QA. Synthetic fixtures only for native connected/setup journeys; current iPhone 17 Pro / iOS 26.5 simulator. The borrowed simulator and shared services are untouched. Session: `01a1437b-f983-7ae0-a11c-fc6218e819b2`. Runtime ownership and cleanup are recorded independently of semantic work status.

| Case | Starting state, actions and expected saved/visible outcome | Status |
| --- | --- | --- |
| D01 | Internal synthetic resolution failure → inspect Vizio-specific explanation → Scan Again → Vizio candidate appears; old issues cleared | passed affected native precheck; complete gate pending |
| D02 | Internal empty scan → manual setup → choose Vizio → toggle older connection; address field remains usable | passed affected native precheck; complete gate pending |
| D03 | Internal Sony/Vizio displayed-code fixtures → pairing → remote; existing setup and identity-repair journeys preserved | passed affected native precheck; complete gate pending |
| D04 | Public empty setup and Help → Samsung scope visible, no experimental brand/legacy control; demo still works | pending complete gate |
| D05 | Opt-in diagnostics → search-stage recording → immutable preview; Clear/reconsent rejects prior scan lease | pending complete gate |
| D06 | Backend fixtures: partial browser failure + active healthy browser, fresh Vizio retry, late producer, cancellation, bounded failure | pending complete gate |
| D07 | Manual target fixtures: fresh standard/legacy, invalid port rejection, saved identity across address/port change, other-brand isolation | pending complete gate |
| H01 | Current internal build on physical iPhone → Sony/Vizio discovery, real PIN, observed commands, saved reconnect and standby | blocked: physical phone/code/TV observation required |

Final commit gate, review/CI and cleanup receipts belong in the PR acceptance record. Test counts and fixtures do not complete H01. Native internal archive/export preparation is allowed; no upload is authorized by this ticket.

Precheck environment history: the reused audit simulator became unresponsive; the first unit precheck exited65 with a Mach server-died error while installing/launching its runner (no assertion result). A fresh simulator boot completed; its first preliminary run was terminated after launch stalled without an app host. These are not passing tests or established application defects. Later run results remain required.

## Distribution diagnosis and internal candidate

Authenticated read-only Apple inventories on October16 show build9 valid, unexpired and in internal beta testing, alongside build8 in the same internal group. Artifact/source receipts bind9 to Samsung-only public composition;8 is the previous multibrand internal candidate. Apple distribution eligibility and TestFlight group membership do not determine compiled TV support. Consequently, the latest TestFlight build can explain the missing brands; the installed phone build remains unconfirmed. Store version1.0 still selects9 and is Waiting for Review with manual release. No Apple configuration was changed.

Complete processed-build and app-scoped upload inventories contain1–9;10 was absent at this read. This selects10 as a candidate, not a permanent reservation. Recheck before native packaging and any upload. Native archive/export is preparation; TestFlight upload and App Store Connect changes require task-specific authorization under AGENTS.md.

Unit precheck after completed cold boot:392 declarations passed, zero failures/skips. Affected native precheck:5/6 passed; the legacy-toggle test tapped the full-row accessibility element instead of the native switch thumb. Manual interaction verified the thumb changes its value0→1; the test now follows the existing native-switch pattern and waits for the corresponding value. The full updated gate remains required.

Final precheck on build10:395 declarations /527 executions passed, zero failures/skips (392 unit declarations and three affected native UI cases). The corrected legacy switch, empty retry and Vizio issue/recovery cases passed. Sony/Vizio pairing fixtures and About passed in the prior native precheck. The subsequent terminal-failure regression still requires the complete gate. Manual native inspection verified issue copy, scope, Scan Again and the recovered Vizio row; synthetic-only screenshots are in `docs/evidence/hr052/`. Independent source review found no remaining material issue; this does not replace CodeRabbit or final acceptance.

Review follow-up: CodeRabbit reviewed412ad63 and found one valid guidance edge case: an advertisement still unresolved at scan completion was hidden by the issue-only details condition. Setup now uses one shared visibility predicate for both details and no-result guidance; a separate native advertised-only fixture covers Scan Again recovery. The first complete gate and hosted run were intentionally interrupted after this finding so final evidence will bind to the corrected head. They are not passing gate receipts. The bot's broad docstring-percentage warning is nonblocking; no blanket documentation expansion is included.
