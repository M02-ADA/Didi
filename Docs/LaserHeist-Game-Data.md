# LH-07 — Game data and deterministic replay

Implemented for review, 3 November 2026. Owner: Jevon. Consumers/reviewers: Edo and Kevin.

## Contract and ownership

The current layout is [Games/LaserHeist and Shared](Architecture/Game-Oriented-Architecture.md). Domain consumes the existing anonymous `PlayerID.player1/player2`, shared calibration and body snapshot types directly. No shared types or project settings are modified. Functional work here is limited to the user's explicit LH-07 authorization, not resumption of other paused features.

- `LaserEncounter.swift`: validated horizontal high/low targets, per-player beam bands in the same Double player-plane units as BodyGeometry, explicit calibration revision, warning and crossing times; stable P1/P2 target order. Both players require the same move; their geometry and crossing times can differ.
- `LaserRoundConfiguration.swift`: explicit evidence window and delivery allowance, finalization `Tc + W_after + A`, clearance margin, and round constants from the current game rules. Diamond points remain optional because 25 is still a proposal. No production timing default is invented.
- `LaserGameState.swift`, `LaserGame.swift`, `RoundSummary.swift`: immutable state/event/summary shapes, one team score, explicit event sequence and round outcomes. No engine, selector, hit checker, clock conversion, wrist collision or renderer is implemented here.
- Pending/hit/unavailable cases carry reasons. Measurement failures carry Edo's `EvidenceValidity`; gameplay timing failures use separate gameplay reasons. Do not turn unavailable values into zero/clear.

The accepted [CP1 baseline](LH-00-Checkpoint-1-Contract-Proposal.md) requires crown **and both wrists** for high clearance, and both soles plus airborne phase for low. The older crown-only explanation in LH-01 needs reconciliation before LH-10 implementation; fixtures include the current wrist evidence and do not redefine it.

All new domain/fixture values are `nonisolated` with checked `Sendable`, matching current Shared values under MainActor-default compilation. This preserves existing Swift 5 language mode and does not claim whole-team S1/B2 approval or perform a Swift 6 migration. Edo/team confirmation of that broader convention remains pending.

## Official R1–R9 fixture mapping

Cases come from [LH-09 in the cooperative backlog](LaserHeist-Cooperative-Active-Gameplay-DRAFT.md). `LaserReplayScenarios.swift` supplies actual shared `ReplayFixture` / `BodySnapshot` / `PlayerCalibration` values and per-player expected verdict/frame/checkpoint data for the future checker.

| Case | Input and expectation |
|---|---|
| R1 | Valid clearing sample on time; expected CLEAR at finalization |
| R2 | Nearest valid sample overlaps; expected HIT |
| R3 | Only pre-window samples; expected UNAVAILABLE/stale |
| R4 | Eligible capture delivered after finalization; expected UNAVAILABLE/late without another candidate |
| R5 | Airborne/low-feet and grounded/high-feet are distinct samples; expected HIT from the nearest sample, never mixed evidence |
| R6 | Same frame delivered twice; input preserves duplicate transport, expected one selected observation/effect |
| R7 | Pause after crossing but before finalization; expected no finalized verdict, recovery required |
| R8 | P1 and P2 have different crossing times; expected separate selected frames/windows |
| R9 | Nearest sample invalid, later sample valid; expected the valid sample |

Fixture-only timing: crossing 10 seconds (P2 10.5 in R8), W_before 0.35, W_after 0.25, delivery allowance 0.10, margin 0.01. Source capture/delivery times use fixed epoch 100 seconds; mapping subtracts 100, not callback arrival time. All UUIDs, frame IDs, calibrations and record-array order are fixed. No wall-clock sleeps, live camera or random identities are involved. Values are synthetic, not physical-device tuning or approved production defaults.

`LaserGameDataTests` checks invalid geometry/timing, player duplication/mixed moves, stable target order, shared unit/revision use, repeatable fixtures, official case inputs and actual Shared replay delivery (including duplicate and out-of-order captures). It does not implement a second selector or claim R1–R9 verdict execution has passed: that belongs to LH-09/LH-10 `CollisionTimingTests` once the checker exists.

## Integration and remaining review

Verification on 3 November: six Swift Testing tests passed in an isolated temporary SwiftPM harness containing the actual Domain and Shared body-input sources. Compilation used Swift 5 mode, MainActor default isolation, complete strict-concurrency checks and warnings-as-errors; no Swift source warnings occurred. SwiftPM emitted environment/cache-access warnings. Domain framework/duplicate-contract checks and `git diff --check` passed. The extra transport test runs all nine fixtures plus an out-of-capture-order fixture twice through Edo's real ReplayBodyInput and compares the delivered packets, including duplicates.

The full Xcode app/Simulator test run was not completed: the normal developer directory points to CommandLineTools, and the Xcode override encountered restricted cache/Simulator-service access. The isolated run is not an app build, iOS Simulator run, physical-device check or validation of the unimplemented LH-09 judgement algorithm.

- Edo reviews calibration/validity interpretation and the currently approved high-wrist prerequisite; no shared producer or ReplayBodyInput edits are required by this change.
- Kevin reviews target bands/timeline, immutable game state and ordered GameEvent consumption before renderer integration. RealityKit never becomes the authority for health, score or judgement.
- Jevon implements bounded history/selection in LH-09 and geometry judgement in LH-10, then executes these fixture expectations against that code. Boundary/tie policies and production window/delay values still require agreement.
- The state/summary shapes can grow only when an implemented consumer requires it; vault/diamond contact geometry is deliberately not invented from the current Y-only wrist measurements.
- Full app/Simulator/device validation is separate from isolated Swift domain/test validation. The existing local project.pbxproj changes are outside LH-07 and must stay untouched.
