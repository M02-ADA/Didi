# Standing calibration: algorithm options for Edo

> **Status: IMPLEMENTED (18 November 2026)** with two safety refinements to option D: evidence restarts after a real step (both soles elsewhere twice), and the agreeing samples must be at least 60 % of their span (an evenly alternating estimate never calibrates). See `CalibrationSession.agreeing` and `SpanMajorityCalibrationTests`. The text below is the original proposal.
>
> **Original status: PROPOSED — needs Edo's approval.**
>
> - **Owner of the changed code:** Edo, `Shared/BodyTracking/Processing/CalibrationSession.swift`.
> - **Requested by:** Kevin (task owner), 18 November 2026.
> - **Nothing is applied.**

**Recommendation: option D, the "span majority" rule.** It is now in `CalibrationSession.swift` (its proposal patch was removed on 20 November 2026 as applied).

The earlier 8-of-10 proposal is option B: [LaserHeist-Calibration-Robust-Window-Proposal.md](LaserHeist-Calibration-Robust-Window-Proposal.md). It is **not recommended**, for the reasons below.

## The problem

On the iPad, a still player's head-top estimate jumped by 5–8 mask rows: in 35 of 126 samples the window's head-top range went over 2 rows, compared with 5 of 126 for the soles.

V1.1 restarts the window when **two agreeing out-of-tolerance samples arrive in a row**. Those jumps trigger that restart, so progress falls from 70 % to 20–30 %. Three Solo games took 24 s, 8 s and 14 s to calibrate.

The full evidence is in the option B document.

## The options

| | Rule | Paired jumps (the iPad pattern) | A jump on every 3rd sample | Sustained drift | Real step | Samples in the reference | Harder than V1.1 anywhere? |
|---|---|---|---|---|---|---|---|
| **A — V1.1 (today)** | 10 agreeing, isolated outliers skipped, two agreeing outliers restart | restarts (the bug) | completes | never completes | restarts, then 10 at the new place | 10 | — |
| **B — 8 of the latest 10** | 8 agreeing among the latest 10 valid samples | tolerated up to 2 in 10 | **never completes** | never completes | 8 at the new place | 8–10 | **Yes**: more than 2 isolated jumps in 10 |
| **C — restart on 3** | V1.1, but restart only after 3 agreeing outliers in a row | runs of 2 tolerated; runs of 3 or more still restart | completes | never completes | 10 at the new place, one sample later | 10 | No, but it only moves the cliff |
| **D — span majority (recommended)** | 10 agreeing among the valid samples within the existing 10 s span; nothing restarts | tolerated | completes | never completes | 10 at the new place | 10 | **No**: it completes whenever V1.1 does (property-tested) |

## Option D in detail

- **Kept samples.** Every valid sample is kept for the existing 10 s span: at most 40 at 0.25 s spacing. The existing per-sample checks decide what is valid, and they are unchanged.
- **Stable.** A player is stable once **10 kept samples agree with each other**: the head-top and both soles each lie within the **unchanged** tolerance of max(3 px, 2 mask rows).
- **Reference.** It is the mean of the latest 10 agreeing samples.
  - Acceptance still requires exactly 10.
  - Accuracy is unchanged: the same count and the same tolerance.
  - Readings outside the agreeing set never enter it.
- **No restarts.** A real step leaves the old position's samples in the span until they are 10 s old. The new position completes once 10 samples agree there, as in V1.1.
- **`moving`** is still reported for any sample outside the agreeing set that existed before it arrived.
- **Unchanged:** freshness, cadence, request and candidate lifetimes, identity (a player-only reset, and the pair reset), mask separation, joint confidence, upright landmarks, anatomy refusals, STOP/REVIEW, `StandingEstimateAcceptancePolicyV1` and `.experimental` provenance.

### Evidence

All of this was run in a copy of the tree in the Simulator; the shared checkout was not changed.

- **Property test (`neverHarderThanV11OnSeededSequences`).** It ran 300 seeded sequences mixing still readings, ±1-row noise, 6-row jumps (single and in runs), steps and drift, against a model of V1.1:
  - There was **no sequence** where V1.1 completed and option D did not.
  - Option D was earlier in 103, at the same sample in 48, and completed in 148 where V1.1 never did.
  - Every reference was within tolerance of the readings.
- **`SpanMajorityCalibrationTests`** (new):
  - paired jumps no longer restart, and are excluded from the reference;
  - progress never falls back on a jump;
  - a jump on every third sample still completes;
  - drift never completes;
  - a step completes only at the new place, and a half-and-half mix never does;
  - a brief step aside isn't a restart;
  - the tolerance and sample count are unchanged;
  - invalid tracking and a missing face never count;
  - repeated sessions behave the same;
  - the cost stays bounded (worst case 1.67 ms per sample, Debug, Simulator).
- **Edo's existing tests pass unchanged**, except one: `anIsolatedOutlierIsSkippedAndARealStep…` asserted the restart itself. It now asserts that the old place keeps its 5 samples until the new place outnumbers it.
- **Real provider, gate and coordinator** (`LiveRepeatedCalibrationTests`): all 13 pass, including five consecutive co-op games and paired jumps on P2. With option D, the paired-jump test completes on its first attempt while the jumps continue. With V1.1 it stalls until they stop.
- **Full unit target on option D:** the only failures are those already known before this change (two baselines and two parallel-load tests).

### Trade-offs and risks

- **Two-mode estimator.** If a player's head-top estimate really alternates about evenly between two readings, option D (like V1.1) calibrates on whichever reading reaches 10 first. It does this more often than V1.1, because V1.1 more often failed instead. The real fix is the head-top estimator (`AnatomicalCandidatePolicyV1`), which needs a consented recording.
- **Cost.** The agreement search runs inside the tracking gate's lock, but it is bounded by the 40-sample retention cap and measured at a worst case of 1.67 ms per sample.
- **Status line.** `players[id].samples` now means "agreeing samples, capped at 10" rather than "window length". Every consumer already divides by 10.

## Why not B or C

- **B (8 of the latest 10) is stricter than today** whenever isolated jumps exceed 2 in 10. Edo's own test (a jump on every third sample) completes under V1.1 but never under B. B also needs acceptance and the progress display to change from 10 to 8.
- **C** is the smallest code change, but it only moves the cliff from 2 jumps in a row to 3. In the iPad log the jumps sometimes ran for several samples.

## What option D changed (applied)

- `CalibrationSession.swift`, `AnatomicalMeasurementTests.swift` and `LiveRepeatedCalibrationTests.swift`; it added `SpanMajorityCalibrationTests.swift`.
- No UI, coordinator or acceptance code.

## Separate: the cold-start mask

- The first person-instance mask after launch took 111 ms on the iPad. That is Vision loading its model on first use, once per process; it is expected behaviour.
- Later sessions' first masks took 36–41 ms, and the capture had exactly one STOP/REVIEW.
- **Proposal (Edo's `CameraCopySink`):** one throwaway mask request when a body session starts, before any calibration request, so the load never costs the first attempt (about 3.5 s).
