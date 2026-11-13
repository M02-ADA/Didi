# LaserHeist — DUCK/SQUAT occlusion and forced recalibration (proposal)

> **Status: Proposed — Edo (tracker identity) and Jevon (readiness, DUCK rule) must decide.**
> Author: Kevin, 13 November 2026. Nothing here is applied to Edo's or Jevon's files.
> Patch: [`LaserHeist-Duck-Occlusion-Proposal.patch`](LaserHeist-Duck-Occlusion-Proposal.patch)
> (proposals 1 and 2). It applies cleanly to the current checkout (`git apply --check`).
>
> The patch contains:
>
> - the tracker change (Edo);
> - the readiness change (Jevon);
> - their new tests:
>   - `SquatPresenceTrackingTests`: held squats of 1, 2 and 4 s keep both identities; an absent
>     player, a partial body at the other player's place, or two partial bodies keep today's latch;
>   - `ReadinessWristIndependenceTests`: a hidden wrist no longer blocks; a hidden head or sole
>     still does;
> - Kevin's evidence-test update for the new squat contract.
>
> **Applied in an isolated copy (13 November 2026, second review):**
>
> - 358 tests in 29 suites pass. The only failure is Edo's flaky
>   `priorBindingCalibrationSourceAndPresentationCannotCrossRetry`, which passes alone (9 of 9).
> - Coverage: every tracker, identity, setup, readiness, live-loop, five-gate, JUMP-timing,
>   wall-button, diamond and warning suite.
> - With both changes, the 1.5 s in-round squat ends with the round running again by itself.
> - A DUCK with hidden wrists stays UNAVAILABLE: the DUCK rule is unchanged.

## Problem (iPad)

- A player who ducks with their hands behind their body pauses the round.
- A deep or held squat can send the players back to calibration.

## Evidence (synthetic, deterministic; real tracker, setup gate and session)

The evidence is in `SedactiveTests/Games/LaserHeist/SessionTests/DuckOcclusionEvidenceTests.swift`.

| Situation (today) | Tracker | Session |
|---|---|---|
| Wrists hidden (one or both; P1, P2 or both players; 1–30 frames) | Identity untouched (wrists are not tracker evidence) | `running` → `paused` (blocker `.measurements`) at the first frame; `running` again 4.1 s after the evidence returns; setup stays `awaitingGameplayReadiness`; calibration kept |
| A squat with P1's hips unseen ≤ 0.80 s | Both identities kept | — |
| A squat with P1's hips unseen ≥ 0.83 s | P1 cannot be re-matched; **P2, fully visible, is latched ambiguous** (`requiresRebind`) | — |
| A 1.5 s squat during a round | As above | `paused` → setup `restartRequired`, `awaitsIdentityRecovery`; **still paused 5 s after standing**; exit only through Recalibrate |
| A DUCK under the beam with the wrists hidden | — | Paused before the crossing: no verdict, never a free CLEAR |

**Root cause of the hidden-wrist pause (confirmed):** `LaserLiveReadiness.observe` admits a running
frame only when both wrists are valid. With PR #46's zero running grace, one frame pauses the round.

**Root cause of the squat recalibration (confirmed):**

1. The hips fall below the 0.5 joint confidence. The squatting player then has fewer than the
   tracker's 3 shared core joints, so they have no descriptor and stay unmatched.
2. Their anchor is never refreshed. After the 1.0 s observation gap, every frame of the OTHER
   player's match finds that anchor `.unavailable` and latches it:
   `case .unavailable: if baseline[other].confirmed != nil { safe = false; latch = true }`.
   The rule is deliberate: "an expired competitor is unknown, not absent".
3. In co-op, the latch makes setup `restartRequired`.

The flaw is that the tracker treats a player who is **still in view** (Vision finds their shoulders)
as absent, just because their hips are hidden.

## Proposal 1 — Edo: squat presence (recommended)

When a slot gets no full match in a frame, it may still be marked present, if exactly one partial
body (both shoulders confident, no usable descriptor) is:

- within the position gate of where that player was last seen, and
- not within the gate of the other player.

The slot is then **present**. It stays `uncertain` (no match, no measurement, no verdict), but its
identity does not expire while it is in view:

- the other player is not latched;
- when the hips return, the player is re-matched against their own pre-squat anchor, without
  extrapolating motion across the gap and with the gate capped at its 1 s width.

An absent player (no partial body at all) behaves exactly as today.

**Validated in an isolated copy:**

- All of Edo's identity and tracking suites pass (223 tests, 13 suites), including the 5
  deliberate tests that a broader "continuity" patch broke:
  - `PlayerTrackerTests`, `BystanderTrackingTests`, `CoopTrackingRecoveryTests`;
  - live tracking lifecycle and native source loss;
  - `LiveBodySessionRetryTests`, `LiveVisionPipelineTests`, `AnatomicalMeasurementTests`;
  - Solo and automatic setup.
- Hidden-hips squats of 0.9 s, 1.2 s, 1.5 s and 1.8 s keep both identities.
- The 1.5 s in-round squat resumes by itself (`running` within 5 s of standing), with calibrations
  kept.
- A player who truly leaves still needs Recalibrate.
- The only failures were Kevin's evidence tests, which pin today's 0.80 s limit.

**Consequence:** while squatting with the hips hidden, the player is still `uncertain`, so the round
still pauses (tracking) and shows the warning. It no longer forces recalibration, and it resumes
after standing. Letting play continue through such a squat would need the tracker to report a
partial body as tracked (measured from shoulders and head). That is a larger identity decision,
best taken with iPad data.

## Proposal 2 — Jevon: wrists are action evidence, not presence

```diff
-                && [sample.geometry.crownY, sample.geometry.leftWristY, sample.geometry.rightWristY,
-                    sample.geometry.leftSoleY, sample.geometry.rightSoleY].allSatisfy { $0.validity == .valid }
+                && [sample.geometry.crownY, sample.geometry.leftSoleY, sample.geometry.rightSoleY]
+                    .allSatisfy { $0.validity == .valid }
```

**Validated:**

- Hidden wrists no longer pause the round.
- Readiness, co-op recovery, automatic setup, the live loop, the complete round, the five-gate
  end-to-end round and JUMP timing all pass.
- The wall consoles and diamonds keep requiring their own fresh wrist evidence (consumer and
  vault-zone suites pass): no fabricated presses.
- JUMP is unchanged (soles and airborne state still required every frame).
- A DUCK at the crossing with hidden wrists is still **UNAVAILABLE**, and the session still pauses
  on that verdict.

## Open decision — Jevon (with Edo): a DUCK with occluded hands

Today the DUCK judge needs both wrists below the beam. An isolated trial that ignored an invalid
wrist when the head is under the beam did produce CLEAR for a real hands-behind duck. It changes 2
of the 36 cases of `everyInvalidRequiredMeasurementStaysUnavailable`.

It is **not recommended as is**, for two reasons:

- the producer reports an absent joint (`missingLandmarks`) the same way whether it is occluded
  or out of frame, so a hand raised out of the top of the image would also be ignored;
- a hidden hand typically comes as `lowConfidence`, not `missingLandmarks`.

Before deciding, use the iPad `[LaserDropout]` log, which now records each wrist's invalidity reason
(for example `hands(lowConfidence)`). Options:

- (a) keep UNAVAILABLE;
- (b) ignore occluded wrists only when the producer can say "occluded", not "out of frame" (Edo);
- (c) judge on the head when the elbows (not in CP1 today) are below the beam.

## What does not change

- No fabricated wrists, contacts or verdicts.
- No grace period restored.
- A replacement player never inherits a calibration.
- The Recalibrate warning flow is unchanged.

## iPad validation (DEBUG `[LaserDropout]`)

Run these with two adults and with an adult and a child:

- standing;
- DUCK;
- DUCK with the hands behind the body;
- DUCK with the arms crossed;
- a held deep squat;
- JUMP with natural arms;
- one player briefly leaving.

Record the dropout durations, the wrist reasons and any "re-bind required" lines. Then decide the
patch, the DUCK option and any running grace.
