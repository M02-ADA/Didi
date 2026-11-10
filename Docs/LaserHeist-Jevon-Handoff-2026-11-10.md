# Jevon handoff — D07, D09 and J03


**Latest task-owner clarification, 10 November 2026:** Diamond Time has four persistent targets for ten active seconds. Uncollected targets do not pass/miss/disappear; collection alone spawns a replacement, with at most four active. Only normal diamonds are permanently missed after passage. This supersedes earlier bonus passage/missed-slot assumptions below. Bonus contact admission uses the phase deadline, not the spawn's normal passage exit.
10 November 2026 · Updated after Edo's D09 v1 approval and Jevon's product decisions · **Not sent; exact CP1 fields/coordinate freeze and live acceptance remain pending**

## D07 — confirmed authority, open visual acceptance

Edo's later Tech Lead direction is recorded in [the D07 review](LaserHeist-D07-Synthetic-Fairness-Review.md): keep existing human crown/both-wrist and both-sole/valid-airborne judgment, checker margins and timing. Investigate fixed 1.6 m mascots with reviewed presentation mapping first; compare height-preserving fitting if fixed-size mismatches persist. Kevin's earlier height-preserving-first recommendation remains recorded; please acknowledge the investigation order.

Jevon's additional tests cover either player in unequal-height pairs, either raised wrist, either grounded sole, missing/stale airborne evidence and selection of the actual crossing frame despite a later clear pose. Four new definitions execute 64 parameterized cases. The focused run passed 45 definitions in five suites, including the unchanged renderer baseline and existing timing/live recovery tests. No renderer or CP1 source code changed.

Kevin still owns rig/reach/mapping corrections and rendered comparisons. Edo/Kevin own source-correlated E07 references and any D06 changes. Theo reviews comprehension. D07 remains open for measured iPad acceptance; crown, independent soles and airborne are still experimental/unavailable for authoritative live input.

## D09 — behavior approved, producer schema and mapping pending

Edo approved the architecture/behavior direction and explicitly authorized J04/J05 synthetic fixtures. [The D09 decision record](LaserHeist-D09-Contact-Decision-Proposal.md#subsequent-d09-v1-approval) preserves the exact scope and the original proposal. Exact field-level freeze still awaits Edo's CP1 compatibility check and the agreed coordinate mapping; no shared producer schema was invented on this branch.

The agreed behavior is now implemented/tested in Jevon's domain area:

1. Fresh outside → inside domain entry; no dwell/interpolation, first-inside award or held-pose pickup on a new/resumed target. Missing/invalid membership clears pending history. Independent valid wrists can qualify independently, subject to existing session readiness.
2. Capture and arrival must both precede the interaction deadline; equality closes first. No laser delivery allowance or retroactive out-of-order award.
3. Deterministic same-frame batches: representative tie order **P1 left → P1 right → P2 left → P2 right**, stable target-ID order; no personal-score implication. Vault applies all buttons before one completion transition; diamond terminal states precede replacements.
4. Normal passage/miss and persistent Diamond Time targets, collection replacements and summary accounting. Product choices confirmed by Jevon: **25 team points, four initial bonus diamonds, persistent bonus targets until collection or phase end; permanent misses for normal diamonds**. The cap limits concurrent active diamonds, not total collections.

The combined domain replay fixture completes 50 laser targets/player, 30 normal diamonds, five contact-driven vaults and eight bonus collections with **10,950 points / 38 diamonds / full health**. Its one ReplayBodyInput consumer and GameClock are real; contact membership is explicitly synthetic test input, not E08 or a proposed wire format. Default interactive replay presentation has not been extended to render these diamond plans.

For J07, Edo still needs to provide the exact producer-owned attachment and atomic source/epoch/control/binding/calibration acceptance rules, including absent-attachment/old-replay behavior. The domain tracker intentionally consumes classified membership only. The session adapter must validate actual E08 provenance, use original capture conversion/current arrival time, invalidate entry on all lifecycle cutovers, stage tracker/game mutations together and process each source frame once before any replacements. No latest-pose join or second CP1 subscriber is permitted.

For Kevin/Theo/Edo joint review, production zone radius/placement/separation, comfortable reach, coordinate mapping, approach/interaction trajectory and the read-only rendering/event handoff remain open. The fixed numeric circles and placement schedules used in tests are not production defaults. No GameEvent schema or renderer code changed.

## J03 — latest session/readiness status

**Implemented and exercised with controlled synthetic accepted data:**

- Injected live/replay selection, one CP1 stream/observer, explicit setup/binding acknowledgment and producer-owned calibration acceptance flow.
- Numeric readiness gates for accepted current calibration, required valid body measurements, reliable binding, settling and freshness. Rendering must attach and supply its first update before countdown can start.
- One GameClock for captures, countdown-to-round anchoring, pause, guarded recovery and domain judgment. Selected capture/arrival ordering and old-context rejection are tested.
- Safe sequential Stop/Retry: cancel and join the old consumer, await provider cleanup, fresh generation with empty calibrations, claim a new stream and explicitly bind again. No old token/context reuse.
- Vault phase entry/timeout/pause bridge, terminal summaries and joined cleanup. This phase bridge does not detect wrists or complete the diamond game.

**Default app behavior remains setup-only for live:** its factory supplies no reviewed round plan, live timing policy or recovery plan. Real crown/sole/airborne acceptance, physical calibration and measured fairness remain gates. The conditional live loop passing with controlled inputs does not establish production camera gameplay.

Verification: the latest full regression passed **653 Swift Testing definitions in 70 suites**, **three UI smoke cases**, and Debug/Release Simulator builds. Targeted D09 runs passed 43 definitions in six suites and eight combined/legacy replay definitions in two suites. Logs and limitations are recorded in [the consumer checkpoint record](LaserHeist-Replay-Slice.md). Existing framework/concurrency/Simulator graphics warnings remain. No physical-device validation is claimed.

## Implementation boundary for the next handoff

| Owner | Next input needed |
|---|---|
| Edo | Define the exact CP1 producer/replay surface and acceptance mechanism; agree coordinate mapping; continue genuine anatomy/calibration and E08 validation. Approved D09 behavior need not be reapproved. |
| Kevin | Acknowledge D07 investigation priority; address rig mismatches; review zones/trajectories and the diamond presentation/state/event handoff. |
| Theo | Review entry behavior, comfortable target reach/size and visual HIT/UNAVAILABLE comprehension. |
| Jevon | Plug in Edo's frozen E08 surface when available, then complete J07 and the interactive full replay/live flow with reviewed placement/presentation. Preserve current controlled-input gates. |

No message was sent, no branch was pushed and no PR was created for this handoff.
