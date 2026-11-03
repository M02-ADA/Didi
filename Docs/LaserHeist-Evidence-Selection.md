# LH-09 — Crossing evidence selection

Implemented for review, 3 November 2026. Owner: Jevon; integration reviewer: Edo.

## Policy and scope

The task's D-Evidence policy is implemented with explicit `LaserEvidenceTiming`: capture window `[Tc - W_before, Tc + W_after]` and finalization deadline `Tc + W_after + A`. There are no new production window/delay defaults. Tests use the LH-07 fixture values 0.35/0.25/0.10 seconds. Selection chooses the nearest sample with valid required evidence; exact distance ties prefer earlier capture time, then lower frame ID if capture times are identical. Selection never chooses a sample because its geometry would CLEAR.

`LaserCollisionJudge.swift` returns selected evidence or UNAVAILABLE, not a production CLEAR/HIT verdict. Required fields follow Edo's current CP1 baseline: high needs crown and both wrists, low needs both soles and valid jump phase. Grounded is valid evidence that may produce HIT in LH-10, not a reason to discard a nearer sample. Geometry, phase, capture time and frame identity always remain from one snapshot. BodyInputContext guards generation, camera/calibration revisions and cutover boundaries; target revision must match as well.

LH-10 clearance remains separate. CollisionTimingTests uses a test-only clearance oracle to express official R1/R2/R5 verdict expectations after real production sample selection; it is not the production hit checker. No live camera, body-input producer, renderer, health or score behavior is changed.

## Ownership and call order

- Shared `GameClock` converts normalized source time into active game time. It pauses without accumulating elapsed source time. Resume establishes a fresh capture anchor: paused or previous-epoch captures are rejected, as unresolved attempts are withdrawn rather than judged retrospectively. No unbounded list of pause intervals is stored. Time scaling is not implemented here.
- Session code advances that clock, rechecks the producer's current context after suspension, and maps each snapshot's **capture time**, separately from arrival. A failed mapping is rejected. It must not label capture time with delivery time.
- `LaserGame` owns short per-player body history, target registration and immutable selected results, keyed by encounter/attempt/player. `LaserCollisionJudge` only selects from the supplied history; the coordinator never selects a sample.
- Register the attempt before its evidence deadline. Feed deliveries using `receive(snapshot, capturedGameTime:, arrivedAt:)`, then call `advance(to:)` for that tick. Inclusive deadline deliveries are processed before the finalization tick. Later deliveries close earlier deadlines before they are admitted. A committed result is never changed by a late frame.
- Before the deadline, selection remains PENDING. At or after it, a game tick commits the result based only on deliveries at/before the deadline. No future data is inspected. A delayed tick can publish the decision later in wall time but cannot extend the eligibility/delivery deadline.
- Call `pause()` or `exit()` before further selection/tick processing when the corresponding lifecycle event occurs. Pending targets become withdrawn, history clears and no new result is finalized while inactive. `resume()` does not reactivate withdrawn attempts; schedule a new attempt ID after readiness/countdown. Exit cannot be resumed.
- Call `updateContext` before accepting more data/ticks when generation/calibration/camera context changes. It withdraws unresolved attempts and blocks continuation until readiness/resume. Do not retain an obsolete provider context after suspension.
- Release consumed target results with `remove(key)`. Results carry selected snapshots until consumed; retaining every finished encounter indefinitely would retain evidence too. Session/LH-08 wiring is not implemented by this task.

## Bounded storage and overload

Each slot's samples are pruned to the configured window span plus delivery allowance, using converted capture time. A required positive `historyCapacityPerPlayer` also bounds storage under excessive source rates. The caller chooses capacity from measured rates; there is no hidden production number. Duplicate frame IDs in retained history preserve first arrival and count once. Conflicting duplicate content/conversion is rejected.

If the capacity is exhausted while a target is pending, that target is marked internally as having incomplete history. It stays PENDING until its deadline, then reports UNAVAILABLE/historyOverflow rather than producing player damage or a guessed CLEAR. This is a conservative integration policy for review with Edo. One last-pruned capture-time scalar per player preserves the stale-versus-none reason without retaining old samples; it resets on withdrawal. Active target results are explicitly consumer-released.

## R4 and reason semantics

The old LH-07 R4 fixture expected UNAVAILABLE/late even before a late sample had arrived. It now expects UNAVAILABLE/noSample at the deadline. A deadline with only stale evidence reports stale; invalid in-window evidence reports its shared validity reason. Future late arrival cannot retroactively change noSample to late or a finalized result to CLEAR. The enum's late case is preserved for compatibility, but the selector never predicts future delivery.

## Verification

`CollisionTimingTests` executes official R1–R9 against production selection and compares frame identity plus the test-only verdict oracle. Additional tests cover exact inclusive boundaries, zero-after causal windows, earlier-sample ties, out-of-capture-order arrival, duplicate transport, no premature overflow result, pause/exit withdrawal, context cutover, required wrist invalidity, capture conversion across pause, and a 10,000-frame replay with bounded history and eventual pruning to zero. Existing LH-07 validation/Shared transport tests are retained.

Tests run in the isolated temporary SwiftPM harness against the actual Shared/Domain source files, with Swift 5 mode, MainActor default isolation, complete concurrency checking and compiler warnings-as-errors. SwiftPM cache-access warnings are environmental. Full application/Simulator/device validation and session wiring remain pending; the local project.pbxproj changes are untouched. Edo reviews context/evidence interpretation; Kevin later displays results from the authoritative game state, without a competing clock.
