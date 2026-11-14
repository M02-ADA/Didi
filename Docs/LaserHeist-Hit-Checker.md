# LH-10 — Pure laser clearance and committed verdicts

Implemented for review, 3 November 2026. Jevon owns the checker; Edo reviews evidence interpretation; Kevin reviews rendered-band alignment. Neither collaborator confirmation nor device validation is implied by this implementation.

## Current rules and task reconciliation

The [accepted CP1 baseline](LH-00-Checkpoint-1-Contract-Proposal.md) takes precedence over the older task's crown-only high-laser criterion. High requires valid crown and both direct wrists; CLEAR is `max(crownY, leftWristY, rightWristY) + margin < beam.lowerY`. Low requires valid soles and jump state; CLEAR is `jumpPhase == airborne && min(leftSoleY, rightSoleY) - margin > beam.upperY`. Equal boundaries are HIT, never CLEAR. All coordinates and the nonnegative finite margin are the same player-plane Double units as the input and beam. No additional detector, scale, physics collision, renderer lookup or body-input type is introduced.

Validate all required evidence before comparing geometry. Missing, stale, low-confidence, uncalibrated or identity-uncertain required data stays UNAVAILABLE even if another measurement appears to HIT. High ignores soles/jump state; low ignores crown/wrists. A held crouch can clear high; a one-foot raise cannot clear low. A valid non-airborne phase with sufficient sole height is HIT/notAirborne; insufficient sole clearance is HIT/insufficientClearance. Unknown phase must carry invalid validity under the producer contract; malformed unknown/valid combinations are rejected as incompatible.

The task's split-laser requirement is superseded by the owner's horizontal-high/low-only decision. No mixed encounter spawning is added. The pure checker remains player/target-local: a test can judge a high P1 target and a separate low P2 target from one packet, with independent outcomes. Missing required evidence for one player cannot make the other player's target CLEAR or HIT.

## API and finalization

`LaserCollisionJudge.judge(target:selection:clearanceMargin:context:)` is pure. It returns the existing Judgement (including PENDING/UNAVAILABLE and reasons), or nil for a withdrawn attempt. It rechecks selected evidence against the supplied current context/target revision and required validity. It throws only for an invalid margin. It never changes health, score or a source snapshot.

Create `LaserGame(configuration:context:historyCapacityPerPlayer:)` to enable committed verdicts using the configuration's immutable margin and timing. The older timing-only initializer remains evidence-only unless an explicit margin is supplied, preserving LH-09 consumers without inventing a default margin. Do not treat a nil verdict from an evidence-only game as CLEAR.

At the existing LH-09 deadline, LaserGame selects evidence, calculates the target's verdict once, and caches both. `judgement(for:)` reports PENDING before the deadline, the cached result after it, or nil for unknown/withdrawn/inactive targets. Later CLEAR/HIT poses, duplicate callbacks and repeated ticks cannot change that result. Re-registering an existing key is rejected; release consumed results using the established lifecycle and always use fresh attempt IDs for retries. Pause/exit/context-cutover rules remain those of LH-09. Target results are independent; aggregation into damage/score belongs to later gameplay work.

## Verification and handoff

`LaserCollisionJudgeTests` covers high boundaries for crown/each wrist, low boundaries for each sole, every valid jump phase, all six required-evidence fields crossed with six invalid shared validity states, raised wrists, irrelevant missing evidence, target independence, PENDING/withdrawal/UNAVAILABLE preservation, invalid margins, malformed unknown phase, calibration mismatch, and immutable CLEAR/HIT results after late opposing/duplicate data. Exact equality uses binary-exact margins for stable boundary tests.

`CollisionTimingTests` R1–R9 now checks production `LaserGame.judgement` instead of the former test oracle, including no verdict on pause, PENDING before deadline, and unchanged results after late delivery. Existing history, clock and Shared replay tests remain part of the verification harness.

Validation uses the isolated SwiftPM harness with actual Shared/Domain sources, Swift 5 language mode, MainActor-default compilation, complete concurrency checks and warnings-as-errors. Full app build, Simulator gameplay and physical-iPad beam/body alignment are not established by that harness. No shared producer, rendering file or project setting is changed. Edo still reviews CP1 interpretation; Kevin must confirm drawn lower/upper edges and placement match each target's judged band before renderer integration.

Result on 3 November: **22 Swift Testing tests in three suites passed**, including the nine official replay cases, nine high-boundary variations, six sole-boundary variations and 36 required-field/invalid-validity combinations. No Swift compiler warnings occurred under warnings-as-errors; SwiftPM emitted environmental cache-access warnings. Domain framework-import checks, documentation links and `git diff --check` passed. The temporary harness is a verification aid outside the repository, not a new application target/package.
