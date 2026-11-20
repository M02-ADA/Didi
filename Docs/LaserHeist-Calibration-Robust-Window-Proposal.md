# Proposal: robust standing-calibration window (StandingCollectionPolicyV1.2)

> **Status: NOT ADOPTED.** Superseded by option D, the span-majority rule, which is implemented ([the comparison](LaserHeist-Calibration-Algorithm-Comparison.md)). This option's patch was never applied and was removed on 20 November 2026; this page remains as the record of why it was not chosen.
>
> - **Owner of the changed code:** Edo, `Shared/BodyTracking/Processing/CalibrationSession.swift`.
> - **Requested by:** Kevin (task owner), 18 November 2026.

## The problem

A player standing still loses calibration progress: 70 % falls back to 20–30 %.

In V1.1, a sample outside the window's 2-row tolerance is skipped. **Two such samples in a row that agree with each other** count as the player moving, and the window restarts from those two.

## Evidence

The evidence comes from the iPad Pro 11" (M5), a Debug build, Solo, three games in a row. The log holds counters only, no images.

| Game | Calibration time | Samples accepted | Refused as `moving` | Refused as `headObstructed` |
|---|---|---|---|---|
| 1 | 24.2 s | 44 | 24 | 20 |
| 2 | 8.4 s | 21 | 7 | 0 |
| 3 | 14.4 s | 40 | 22 | 1 |

Game 1 also needed a second attempt (see the cold-start section below).

What the log shows:
- **The head-top flips; the soles don't.** In 126 logged samples, the window's head-top range (including the new sample) went over 2 mask rows (3.75 px) in **35**. The soles did so in only **5**.
- **The flips are 5–8 mask rows**, recorded as ranges of 9.4, 11.2, 13.1 and 15.0 px. The range then falls back to 1.9 px.
- **The head-top estimate is not stable.** Its distance above the nose switched between two clusters, about 0.10–0.12 and 0.22–0.24 of body height.
- **The player didn't move:** the soles stayed within 0–1.9 px.

## Proposed rule (V1.2)

- **Window.** Each player keeps a rolling window of their latest **10 valid samples**, all within the existing 10 s span.
  - A valid sample has passed every existing check.
  - Every valid sample enters the window.
- **Stable.** A player is stable when **at least 8 samples in the window agree with each other**: the head-top, left sole and right sole each lie within the **unchanged** tolerance of max(3 px, 2 mask rows).
- **Reference.** The reference is the **mean of the agreeing samples only**. Readings outside the majority are never averaged in.
- **Still reported as moving.** A sample that falls outside the agreeing majority from before it arrived is reported as `moving`, as before.
- **Acceptance** requires 8 to 10 agreeing samples per player. Before, it required exactly 10.
- **Progress** in the UI counts agreeing samples towards 8.

## Unchanged

- Freshness, cadence (0.25 s), request and candidate lifetimes, and the window span.
- Identity:
  - a player who isn't tracking clears only their own window;
  - pair uncertainty clears both windows.
- Mask separation, joint confidence, the upright landmark order, and the anatomy refusals (head obstructed, feet, and the rest).
- The STOP/REVIEW mask budget.
- `StandingEstimateAcceptancePolicyV1`, and `.experimental` provenance.

## Behaviour changes (please review)

- **Faster:** a still player completes after 8 agreeing samples instead of 10, about 0.5 s sooner.
- **Clustered jumps are tolerated:** up to 2 jumps in any 10 samples no longer restart the window. This is the fix.
- **Stricter for frequent isolated jumps.** V1.1 skipped every isolated jump, so a jump on every third sample still completed. V1.2 does not complete when there are more than 2 jumps in 10. The existing test now asserts this; it is renamed `frequentJumpsAndARealStepUnderTheMajorityRule`.
- **Looser for one dither pattern.** With a head-top dither of 0–3 rows, 8 of 10 readings stay within 2 rows. V1.2 now calibrates from those 8; V1.1 refused it. `stabilityToleranceIsNeverBelowTwoMaskRows` asserts this explicitly and adds a sustained-drift case that must never complete.
- **A real step** calibrates at the new place once 8 samples agree there. It never mixes the two places.

## Accuracy note

- Every sample used still meets the 2-row tolerance, and the reference averages 8 to 10 of them instead of exactly 10.
- **If the head-top estimator really has two modes** with roughly equal shares, then V1.1 and V1.2 alike calibrate on whichever mode wins. The flip pattern above suggests that may be happening for some players.
- Fixing the head-top estimator itself (`AnatomicalCandidatePolicyV1` and its extractor) would need an approved, consented recording. That is out of scope here; please consider it.

## Tests

All were run in a copy of the tree in the Simulator; nothing ran in the shared checkout.

- **New: `RobustCalibrationWindowTests`** (deterministic, injected times, the real `CalibrationSession`):
  - head-top jumps two at a time on a still player complete from the agreeing samples, with the jumps excluded;
  - progress never falls back on a single jump;
  - more than 2 jumps in 10 never completes;
  - sustained movement never completes;
  - a step calibrates only at the new place;
  - the accuracy tolerance is the same as before;
  - invalid tracking or a missing face is never counted;
  - repeated sessions start empty and calibrate the same way.
- **Updated (V1.1 expectations made explicit):**
  - `AnatomicalMeasurementTests`: 3 tests.
  - These now stop feeding samples once a candidate exists: `CoopCalibrationDiagnosticsTests` (the sampling helper), `ParentChildCalibrationEvidenceTests` (two tests; the uncertain frame moves to sample 6), `LiveBodyEstimateTests` (2 loops), `SoloTestModeTests` (2 loops) and `LiveRepeatedCalibrationTests` (the minimum-time bound).
- **Results:**
  - Calibration-related suites: 130 / 130 pass.
  - Full unit target: everything passes except the known baselines (`withoutJointsTheCrownDropShowsADuck`, `LaserGateLifecycleTests.feedbackReplacesAndClears`) and the parallel-load tests that already fail today (`priorBindingCalibration…`, `LiveCutoutTests.resourcesStayBounded…`).
  - Real-provider repeated games: 3.6–3.7 s per calibration, down from 4.1–4.4 s.

## What it would have changed (not applied)

- `CalibrationSession.swift` (Edo), `GameSessionCoordinator.swift` and `CalibrationView.swift` (progress towards 8), plus the tests above.

## Separate: the cold-start mask (not in this patch)

- **Measured on the device:**
  - The first person-instance-mask request in a fresh process took **90.7 ms** in an idle probe, and **111 ms** in the app.
  - Later sessions' first masks took **36–41 ms**, each with a fresh segmenter; warm requests took 4–12 ms.
  - The capture had exactly **one** STOP/REVIEW, on the first mask after launch.
- **Conclusion:** this is expected Vision behaviour. The model loads lazily on first use, once per process, not once per session. It becomes a reliability problem only because the 100 ms STOP/REVIEW budget turns it into a failed first attempt: about 3.5 s lost on the first calibration after launch.
- **Proposal (Edo's `CameraCopySink`):** one throwaway mask request on the camera worker when a body session starts, before any calibration request. No threshold changes.
