# Hafa Remote improvement and internal TestFlight delivery

Leon authorized this implementation cycle on October 7, 2026: isolated branches, complete local validation and computer-use QA, reviewed PRs with material findings fixed, merge when ready, and the next signed internal TestFlight build for testing on his iPhone. The selected visual direction is Warm teal.

## Tickets

| Ticket | Outcome | Acceptance |
|---|---|---|
| HR-041 | Restore repeatable Xcode validation and record the approved scope | Actual Apple compiler preserved; probe-output regression passes; complete local gate passes; no app behavior changes |
| HR-042 | Preserve saved-TV identity and recover changed addresses | A cached address cannot select another paired TV; discovery aliases reconcile with authenticated identity; credentials and certificate pins stay brand/device scoped |
| HR-043 | Separate connection, power, and capability evidence | Standby does not imply disconnected or awake; eligible wake remains usable during recovery; unsupported/unverified features are presented honestly |
| HR-044 | Apply the Warm teal native design | Ergonomic D-pad and volume groups; accessible D-pad fallback for discrete swipe navigation; native semantic fonts/symbols; pre-pairing Help; light/dark/high-contrast/large-text/reduced-motion checks; semantic commands preserved |
| HR-045 | Add supported everyday remote conveniences | Discrete swipe navigation, source chooser, and device-scoped favorites from a returned app list, explicit configured link, or saved current-app configuration; no universal installed-app inventory claim; safe tuner/channel keys, with guide and numeric input gated on a reviewed tuner command path; negotiated Sony text where implemented; no speculative mouse, cloud catalog or wrong-TV launch |
| HR-046 | Complete private support and offline demo | Bounded redacted on-device diagnostics with preview and opt-in sharing; clearly labeled Release demo makes no network requests and stores no real credentials |
| HR-047 | Refine identity and complete release QA | Original icon consistent with the native palette; current screenshots and reviewer instructions; privacy/security checks and full simulator flows |
| HR-048 | Upload the next internal TestFlight build | Next unused build number verified in App Store Connect; exact merged release commit passes gate; signed archive/export pass preflight; upload processes and owner can access internal testing |

## Design contract

- Light: canvas `#F7F5EF`, surface `#FFFFFF`, primary text `#192927`, secondary text `#59665E`, primary action `#12685D` with white text.
- Dark: canvas `#111B1C`, surface `#1C292B`, primary text `#EDF3EF`, secondary text `#AFBFBA`, primary action `#78D5BF` with `#112A23` text.
- Use semantic tokens, native Dynamic Type and SF Symbols; every target is at least 44 points. Provide stronger boundaries for increased contrast and retain useful disabled/pressed states.
- Navigation and volume lead; separate Play/Pause remain explicit until actual playback state supports a truthful toggle. Optional controls appear only for the selected TV's capabilities.
- Recovery preserves context and offers the action its typed failure needs. Avoid indefinite spinner-only states and connection-based assumptions about display power.
- Input feedback is immediate, short and restrained; Reduce Motion and Reduce Transparency receive useful native fallbacks.

## Internal and public boundaries

This cycle produces an internal household TestFlight candidate, not a public App Store submission. Internal capability paths may be tested without claiming broad model support. Do not call a feature hardware-verified merely because a driver implements it, a simulator test passes, an API accepts a request, or a control service is reachable.

Keep physical hardware evidence pending until observed on the exact TV/build. The public release still requires the PRD's protocol-distribution determination, advertised model/firmware/network matrix, command/reconnect soak, accessibility evidence and accurate compatibility metadata. Unresolved drivers must be excluded from a public binary. Internal upload is explicitly authorized; external TestFlight/public review is outside this delivery step.

No new TV brands/platforms, backend, account, tracking, advertisements, subscription, casting, cloud catalogs, macros or background command service are added. Watch/iPad and direct widget/Shortcuts controls remain later product decisions.

## Review and validation

Each ticket uses one isolated branch/worktree and the repository's current PR workflow. Run the full gate on the current commit and exercise affected UI with computer use. CodeRabbit/current CI coverage and resolved material threads are checked before each merge; incomplete or stale reviews are never reported as clean. Clean task-owned resources after QA and preserve borrowed services/hardware.
