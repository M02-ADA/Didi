# LaserHeist — Pose-First Temporal Candidate

> **Status (14 November 2026): PRODUCTION DEFAULT in Debug and Release, approved by the task owner.**
>
> `PoseFirstCandidate.isEnabled` is `true` in every build. A DEBUG build launched with `-trackingBaseline` runs the previous rules for comparison. The earlier `-trackingCandidate` flag is gone.
>
> Mask benchmarking and its overlay remain DEBUG-only.

## Baseline versus candidate

| Situation | Production baseline | Candidate |
|---|---|---|
| One weak or hidden landmark while running | The round pauses at once (running grace 0) | No pause while the player is **present**: tracked, or held by squat presence. The round pauses after **0.6 s of absence**, the rules' proposed `lostTimeout` (§C1, G15). |
| Deep or fast squat, hips hidden | Tracker slot becomes `uncertain`; every measurement is blanked; the round pauses | Squat presence holds the identity (unchanged rule). The partial body is **measured** from what Vision saw: nose, wrists, ankles. It is marked `presenceOnly`, and missing joints stay missing. |
| Head bow | Nose plus a fixed offset: the crown reads lower, a possible false CLEAR | The crown is the higher of the nose estimate and a **shoulder estimate**: shoulders + the player's own upright shoulder-to-nose height + the nose-to-crown offset. A bow alone cannot lower it; a squat lowers both. |
| Hands behind the back | A hidden wrist pauses at the crossing | The judge still needs both wrists (no rule change). It already uses the best frame in its 0.6 s window. A window with no visible wrists is UNAVAILABLE, unscored and without a pause. |
| Held tiptoe | Stays "airborne" for as long as it is held | Airborne ends after a 0.7 s flight, and a new take-off needs the soles to come back down first. |
| Ankle-only rise (pose jitter) | Can start "airborne" | At take-off, the hips must rise at least half as much as the soles. |
| UNAVAILABLE verdict | Pauses the round | Unscored, play continues. The **2nd in a row** or **4th in a round** for a player pauses, as does any UNAVAILABLE for an absent player. The pause uses the existing recovery, which retries the lasers. |
| Identity ambiguous, lost or replaced; camera lost | Pause or recalibrate | **Unchanged.** |

Avatar rendering is unchanged: a presence-held player's mascot still shows as "identity uncertain". Gameplay measurements and the smoothed avatar transforms stay separate.

## Not solved

- A **quick** tiptoe (rise and drop within 0.7 s) looks like a small hop in 2D: both raise the ankles and the hips. At 2% sole lift for JUMP, only a larger required lift (a product decision) or real toe evidence can separate them.
- Hands **fully** hidden for the whole crossing window stay UNAVAILABLE. Accepting them would need either a rule change (task owner and Jevon) or elbows in CP1 (Edo).
- The shoulder-based crown is learned during play; for the first ~0.5 s of tracking it uses the nose only.

## iPad launch

Build and install once, then launch (`<DEVICE-ID>` from `xcrun devicectl list devices`):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Sedactive.xcodeproj -scheme Sedactive -destination 'id=<DEVICE-ID>' -configuration Debug -derivedDataPath /tmp/SedactiveMaskSpike -allowProvisioningUpdates build
```

```bash
xcrun devicectl device install app --device <DEVICE-ID> /tmp/SedactiveMaskSpike/Build/Products/Debug-iphoneos/Sedactive.app
```

**Baseline**

```bash
xcrun devicectl device process launch --console --terminate-existing --device <DEVICE-ID> com.Edward-Kristian.Sedactive -- -startSoloTest -maskBench A -maskBenchScript -maskBenchDuration 210
```

**Candidate**

```bash
xcrun devicectl device process launch --console --terminate-existing --device <DEVICE-ID> com.Edward-Kristian.Sedactive -- -startSoloTest -trackingCandidate -maskBench A -maskBenchScript -maskBenchDuration 210
```

`-maskBench A` reuses the existing instrumentation (pose only, no masks) and the on-screen script. The log's first round line says which rules are active: `[LaserCandidate] round starts · tracking rules: …`.

## Physical test (one tester, ~5 min per mode)

Run the baseline, then the candidate, with the same room, clothes and position. Follow the on-screen script, and **try to clear the lasers** when one comes. Tap Play Again if a round ends.

Script steps:

1. Stand
2. Slow squats
3. Fast squats
4. Deep squat held
5. Squat with hands behind the back
6. Jump
7. Tiptoe, held (no jump)
8. Head bow, knees straight
9. Lean
10. Hide a wrist, then an ankle
11. Stand

Captured from the console (I tally them after each run):

| Measure | Source |
|---|---|
| Pauses while running | `[LaserState] … running → paused` |
| Pauses caused by the UNAVAILABLE budget (candidate) | `[LaserCandidate] UNAVAILABLE budget → PAUSED` |
| Recalibrations and round ends from identity loss | `[LaserInterrupt]`, setup `restartRequired` |
| DUCK and JUMP verdicts | `[LaserVerdict]`; the tester notes which ones were wrong |
| Jump phases (held tiptoe: airborne must end within 0.7 s) | `[LaserJump]` |
| Pose rate, pose latency, render rate, CPU, thermal | `[MaskBenchSummary]` |

**For the tester:**
- Note false CLEARs: head bow only, tiptoe only, or hands raised into a high beam.
- Note false HITs: a clear duck or jump scored as a HIT.

## Owner review

**Edo**
- `PlayerTracker.swift`: `presentCandidateID` (the partial body squat presence holds).
- `BodyMeasurementExtractor.swift`: `candidateSample` (measures presence-held bodies; the conservative crown).
- `BodySnapshot.swift`: `PlayerBodySample.presenceOnly`, and the relaxed `validate` for it.
- `BodyInputService.swift`: candidate wiring.
- `JumpDetector.swift`: maximum flight and hip follow-through at take-off.
- `PoseFirstCandidate.swift`: `HeadHeightReference`.

**Jevon**
- `LaserLiveReadiness.swift`: `absenceGrace`.
- `LaserLiveWristRoundPlan.swift`: candidate timing.
- `LaserSessionSetup.swift`: `hasConfirmedPresentPair`.
- `GameSessionCoordinator.swift`: `pairInPlay`, the retry policy wiring, and the log line.
- `LaserCollisionJudge.swift` / `LaserGame.swift`: `acceptsPresenceHeldEvidence`.
- `LaserUnavailableRetryPolicy.swift`: the budget values.
- Gameplay rules §C1 (immediate pause) versus the candidate.

**Values to tune on the device:** absence grace 0.6 s, UNAVAILABLE budget 2 in a row / 4 per round, maximum flight 0.7 s, hip follow-through 0.5, upright-reference percentile 0.8.

## First iPad comparison (14 November 2026)

**Setup**
- One tester, iPad Pro 11-inch (M5), same room, Debug build, 300 s of in-round play per mode, same script.
- Baseline: the earlier Mode A run (production rules unchanged since). Candidate: `-trackingCandidate`.
- Thermal state "fair" in both runs.

| Measure | Baseline | Candidate |
|---|---|---|
| Pauses while running | **16** (most after ankle or hand confidence dropped) | **0** |
| UNAVAILABLE-budget pauses | — | 0 (no UNAVAILABLE verdicts) |
| Round ends from identity loss | 1 (tester out of view about 2 s) | 0 |
| Tracker uncertain while running | 0 | 1, recovered without a pause |
| Dropout episodes while running | 33 hands, 15 feet | 21 hands, 7 feet (none paused) |
| Verdicts, script phase | DUCK 17 clear / 3 hit · JUMP 10 clear / 3 hit | DUCK 16 clear / 3 hit · JUMP 10 clear / 1 notAirborne |
| Verdicts, negative-control phase (after the script) | not run | DUCK 10 clear / 0 hit · JUMP 5 clear / 1 notAirborne / 2 insufficient clearance |
| Pose 30.0/s, p95 worker time | 10.6 ms | 10.9 ms |
| Render / frames over 50 ms | 59.4 fps / 4 | 59.6 fps / 0 |
| CPU mean / memory peak | 64% / 894 MB | 59% / 709 MB |

**Negative controls are not confirmed.** In the negative-control phase, the candidate's DUCK CLEARs had head estimates 0.92–1.25 against beams 1.16–1.28. That means the shoulders dropped too: a neck-only nod cannot lower the candidate crown this far. The JUMP CLEARs had peak sole lifts of 0.09–0.12 game units, the same range as the script's real jumps (0.06–0.16). Whether these were false CLEARs depends on what the tester actually did (a waist bend and small hops, or a neck nod and tiptoes), which has not been confirmed yet.

**Tester's account (14 November 2026).** The low lasers were answered with real tiptoes, and the high lasers with a bow at the waist, not a neck nod.

- **JUMP:** 5 of 8 tiptoe answers scored CLEAR. **False CLEARs, confirmed.** The tiptoes' peak ankle lift (0.09–0.12 game units) overlapped the script's real jumps (0.06–0.16), so neither lift height nor the candidate's flight-time and hip rules separate a quick tiptoe from a small hop. The baseline has no tiptoe guard at all, so the candidate is not worse, but it does not fix this.
- **DUCK:** a waist bow physically lowers the head and shoulders, so CLEAR is correct under the current rule (head below the beam). The neck-nod guard is therefore **untested on the device**; only the synthetic test covers it.

## Dip-before-take-off check (iPad, 14 November 2026)

**Setup.** Candidate with a JUMP take-off that needs a hip dip of ≥ 3% of standing height within 1 s; same tester and room; 53 verdicts.

| Block | High lasers | Low lasers |
|---|---|---|
| Nod / tiptoe (lasers 1–6 and 9–13) | Nod: 5 HIT, 2 CLEAR. Both CLEARs were in the first block, with head estimate 1.06 (shoulders dropped too); the second block went 3/3 HIT. | Tiptoe: 3 HIT, 1 CLEAR (first block) |
| Real dodges (the other 42) | Squat: **24 / 25 CLEAR** (the one HIT was right at the beam edge) | Jump: **10 / 17 CLEAR**. 6 were refused as "not airborne" with ankle lift up to ~0.10, 1 was too low. |

**For comparison**

- Real jumps in the earlier candidate run, without the dip check: 10/11 CLEAR. Baseline: 10/13.
- Tiptoes without the dip check: 5/8 false CLEAR. With it: 1/4.

**Pauses.** 2 while running, both genuine:

- Once the player was in view but neither matched nor held by presence for more than 0.6 s, then lost and relinked.
- Once nobody was in view.

**Verdict on the dip check: NO-GO as built.** It cut tiptoe false CLEARs, but it also refused about a third of real jumps. Hip heights are not logged, so the cause is unconfirmed. The likely cause is the reference: the calibrated standing hip shifted by the feet's floor drift (−0.04 in this run), which demands a deeper dip than intended.

## Timed jump event (replaces the dip check; 14 November 2026)

**Dip check: removed completely.**

**Candidate JUMP rule:**

- **What counts as CLEAR.** A low laser is CLEAR when this player has an **airborne run** that:
  - consists of consecutive captures the jump estimator calls airborne, with both soles valid;
  - may bridge gaps of up to 0.1 s;
  - lasts **≥ 0.1 s**;
  - is in the air **at the crossing**, ± 0.05 s.
- **HIT and UNAVAILABLE.** Usable evidence with no such run is a HIT (`notAirborne`). No usable evidence in the window is UNAVAILABLE.
- **No sole height** is compared with the drawn laser.
- **No added latency.** The verdict is still final at crossing + 0.25 s + 0.1 s.
- **Code.** `LaserCollisionJudge.judgeJumpEvent` (Jevon); thresholds in `PoseFirstCandidate`.

**Estimator (unchanged from the candidate before the dip check).** Airborne needs:

- the lower sole above the player's own drifting floor by more than 3% of standing height, rising fast;
- the hips rising at least half as much;
- ending after a 0.7 s flight (a held tiptoe).

**Thresholds, from the logs, not tuned.** Ankle jitter stayed above the take-off line for 1–2 frames; the smallest real jumps for 6–8 frames (0.20–0.23 s); hence 0.1 s. The ± 0.05 s tolerance is one frame plus capture jitter.

**Also fixed (from the logs).** Resting soles read −0.02 to −0.07 below the *calibrated* floor, so a small jump never lifted the soles above the drawn laser: production's literal clearance check scored HIT. The event rule uses the player's own floor.

**Known limit.** Quick tiptoes (0.08–0.12 lift, 8–11 frames above the line) overlap real small jumps in height and duration. This rule accepts them when they are in the air at the crossing. Held tiptoes, jitter and squat recovery stay rejected.

**Gameplay-contract change for Jevon and the task owner.** The CP1 low-laser rule says: "Low CLEAR requires valid airborne phase AND min(leftSoleY, rightSoleY) − m > upperEdge", at the one selected sample. The candidate replaces it with: "Low CLEAR requires a jump event — airborne, both soles seen, at least 0.1 s — in the air at the crossing (± 0.05 s). No sole evidence in the window is UNAVAILABLE." The drawn laser height is unchanged for now and no longer judged; aligning it with the rule is a later decision (Kevin and Jevon).

### Short iPad test (about 2 minutes)

Launch:

```bash
xcrun devicectl device process launch --console --terminate-existing --device <DEVICE-ID> com.Edward-Kristian.Sedactive -- -startSoloTest -trackingCandidate -maskBench A -maskBenchDuration 120 -maskBenchLabel jump-event
```

Answer **high lasers with a normal squat** throughout. Count only the **low lasers**:

| Low lasers | Do | Expect |
|---|---|---|
| 1–4 | Small, natural jump (both feet just off the floor) | CLEAR |
| 5–8 | Normal jump | CLEAR |
| 9–10 | Tiptoe, **held** about 1 s | HIT |
| 11–12 | Quick tiptoe | Known limit: may CLEAR |
| 13–14 | Jump clearly **early** (land before the laser reaches you) | HIT |
| 15–16 | Jump clearly **late** (after it has passed) | HIT |

### Jump-event iPad test (14 November 2026): results

17 low lasers, same tester; high lasers answered with a squat.

| Low lasers | Expected | Result |
|---|---|---|
| Small natural jumps (4) | CLEAR | **3 CLEAR**, 1 HIT. The HIT was a real 0.27 s jump (lift 0.098), probably just outside the ±0.05 s window; the crossing time is not logged, so this is unconfirmed. |
| Normal jumps (4) | CLEAR | **3 CLEAR**, 1 HIT. The HIT jump had not left the floor when the verdict was made (head rising at the verdict): late. |
| One extra low laser (count slip) | — | CLEAR. Its profile was a real jump (0.15 up, down in 0.37 s), not a held tiptoe. |
| Held tiptoes (2) | HIT | **2 HIT** |
| Quick tiptoes (2) | known limit | **2 HIT** |
| Early jumps (2) | HIT | 2 CLEAR. #1 was still in the air at the crossing (airborne 0.4 s, verdict right after landing): the rule was correct, the jump was not early enough. #2 was a **false CLEAR caused by a bug** (below). |
| Late jumps (2) | HIT | **2 HIT** |

**Bug found and fixed (candidate only, `JumpDetector.swift`).**

- **What happened:** after the early jump landed, the ankles settled about 0.03 above the old floor (a slightly different foot position). That is above the 1.5% exit line, so the estimator called the player "airborne" for another 0.4 s, and the run reached the crossing.
- **The fix:** coming down from the peak, the flight now ends below the take-off line (3%). That matches the "above the take-off line" frames the 0.1 s minimum was derived from.
- **Tests:** a new test covers the case. Retest on the iPad: pending.

### Retest after the landing fix (14 November 2026)

| Low lasers | Expected | Result |
|---|---|---|
| Early jumps (3) | HIT | **2 HIT**, 1 CLEAR |
| Small jumps (3) | CLEAR | **2 CLEAR**, 1 HIT |

Both misses have one cause: **the floor estimate after the player changes where they stand.** The floor follows a position change only slowly (a 1 s time constant).

- **The false CLEAR (early jump).** After landing, the ankles stayed at a flat 0.097–0.101 above the old floor for over 0.3 s. A flat line never descends, so the landing rule could not end the flight. The 0.7 s limit ended it, after the crossing.
- **The missed small jump.** The player was standing on a new spot that already read 0.05–0.06 "above the floor". The jump added only about 0.03, too little for a quick take-off, so it was never recognised.

**Next fix, not implemented.** Re-settle the floor quickly when the feet are still at a new height for a moment, and end a "flight" that goes flat. Both target this one cause; both need Edo's review.

### Floor re-anchoring (14 November 2026, Edo-owned code, needs his review)

**Root cause (from the retest logs).** Both retest failures happened right after a squat.

- While squatting, the ankle-based sole reads about 0.1–0.2 below the real floor. This is inferred: the floor baseline dropped to −0.16 to −0.20 around every duck.
- The baseline followed it down. Standing again, the real floor (raw ≈ 0 in both traces) read as 0.06–0.10 "lifted" for 1–3 s.
- **Early jump A:** it landed back on the real floor and stayed "airborne" for 0.4 s: a false CLEAR.
- **Small jump B:** a 4.7 cm jump rose only about 0.03 above the stale floor and never took off.

**Correction (candidate only, `JumpDetector.swift`).** The floor baseline:

- learns only while **upright**: hips at least 90% of the calibrated standing leg above the soles;
- **re-anchors** to where the soles are once they have been **still** (within 1% of standing height) for 0.15 s, upright and grounded;
- is **frozen** during a flight.

A "flight" that stays that still for 0.15 s ends. A body in free flight stays within 1% of height of its apex for at most 2·√(2δ/g) ≈ 0.12 s (a 1.9 m player), so a real apex never triggers it. The earlier "end below the take-off line on the way down" rule is reverted, because it shortened small jumps. Hip-follow, the 0.7 s limit, and the timed-event judge (0.1 s, ± 0.05 s) are unchanged.

**Tests**

- The logged traces A and B replay after a squat. A now ends at the landing on the real floor, and B now takes off.
- Also covered: a step closer, a real apex, a squat that must not move the floor, a tracking gap (no re-anchor across it), held and quick tiptoes, and an ankle-only rise.

**Remaining limit.** B itself (3.4% of height) stays above the take-off line for only one frame. Its airborne run (~0.067 s) is under the 0.1 s minimum and inside the logged jitter range, so it still scores HIT. The same jump 1.5 cm higher passes. Lowering the minimum would admit jitter, so it was not done.

**iPad retest of the floor fix (14 November 2026).** Every early jump and small jump followed a squat.

| Measure | Result |
|---|---|
| Floor baseline through the squats | stayed near −0.01 (before the fix it dropped to −0.16 to −0.20 around every duck) |
| Early jumps (3) | **3 HIT** |
| Small jumps (3) | **2 CLEAR**, 1 HIT. The HIT was a clean 0.3 s flight that ended exactly at the landing, on a floor re-anchored to a new standing spot; its timing missed the crossing, most likely early (the crossing time is not logged). |
| Squats | 8 CLEAR, 1 HIT (DUCK, unrelated to the floor) |
