# D07 — synthetic clearance evidence and review protocol

10 November 2026 · Jevon review input · **Human judgment authority CONFIRMED; visual development direction recorded; production acceptance OPEN**

## Follow-up confirmations supplied by Jevon

Source: Kevin's D07 reply and Edo's subsequent D07 Tech Lead reply, forwarded by Jevon on 10 November 2026. These are scoped confirmations, not approval of every candidate in this report.

| Subject | Recorded direction | Meaning for this branch |
|---|---|---|
| Human judgment authority | **CONFIRMED by Edo; Kevin agrees.** High requires crown and both wrists; low requires both soles and valid airborne evidence. Retain the existing checker, margins and timing; invalid evidence stays UNAVAILABLE. | Continue Jevon-owned regression fixtures. Avatar geometry, IK and visual scale never decide HIT/CLEAR. |
| First visual investigation | Kevin recommended height-preserving fitting first. Edo's subsequent Tech Lead direction prioritizes fixed 1.6 m mascots with explicitly reviewed presentation mapping; compare height-preserving fitting if the fixed-size approach cannot resolve mismatches. | Follow the later Tech Lead development priority. Kevin still needs to acknowledge the investigation order; neither mapping is production-approved. |
| Ownership | Kevin: rig, reach, retargeting and visual mapping. Edo: measurement validity, accepted calibration and source-correlated E07 evidence. Jevon: checker, timing and fairness fixtures. Theo: comprehension. | No renderer or producer changes are authorized by Jevon's test additions. Edo/Kevin coordinate D06 packet changes with no second CP1 gameplay reader. |
| Capability and acceptance | Crown, independent soles and airborne remain experimental/unavailable. Keep the 33-case baseline, expand targeted cases, and derive tolerances from actual iPad measurements. | Synthetic integration may continue. No fake accepted measurements, invented tolerances or live fairness acceptance. |

The recorded raised-wrist HIT/visual-CLEAR mismatches remain unresolved. Passing the baseline or the added authority tests cannot close D07.

## Follow-up authority regression

[D07FairnessAuthorityTests](../SedactiveTests/Games/LaserHeist/DomainTests/D07FairnessAuthorityTests.swift) adds four test definitions / 64 parameterized cases in Jevon's domain-test area. It uses production scheduling, evidence selection and round effects with explicit synthetic calibrations. Four ordered pairs of standing spans (1.0/1.6, 1.6/1.0, 1.3/1.75 and 1.75/1.3 game units) exercise either player as the affected slot:

- Either raised wrist produces HIT for its own player while the other clears against their own calibrated band.
- Either grounded sole prevents clearance even when the fixture supplies a valid airborne flag.
- Clear soles with grounded phase produce HIT; missing/stale airborne evidence produces UNAVAILABLE. The existing technical-attempt rule suppresses team reward/damage when one player is unavailable.
- A later clear pose cannot overwrite the raised-wrist evidence selected at crossing; the test records the selected source frame and game capture time. It does not mount a renderer or claim what a display showed.

Verification: **45 test definitions in five suites passed** on the iPad Pro 13-inch (M5), iOS 27.0 Simulator, Xcode 27.2, with parallel testing disabled. The run includes the new suite, `LaserCollisionJudgeTests`, `CollisionTimingTests`, the unchanged `AvatarFairnessTests` baseline and `LiveGameLoopTests`. Existing boundary, validity, pause/recovery, calibration-change and stale-input cases remain in those suites rather than being duplicated here. Log: `/private/tmp/sedactive-d07-confirmed-authority.log`.

Only test code changed; the checker, timing, rendering and producer remain unchanged. This is targeted software regression, not a new complete-suite or physical-device result.

## Evidence collected

The existing [AvatarFairnessTests](../SedactiveTests/Games/LaserHeist/RenderingTests/AvatarFairnessTests.swift) were rerun read-only at checkout `95bd90c` on Xcode 27.2 (27B52), iPad Pro 13-inch (M5) Simulator, iOS 27.0. Eight test definitions passed. Their 102 reported synthetic comparisons are retained in [the numeric CSV](Validation/D07-Synthetic-Clearance-2026-11-10.csv).

The suite intentionally asserts known agreement **and mismatch** classes. Passing it reproduces the recorded renderer behavior; it does not certify fairness. No camera footage, participant pose recording or new asset is included.

The tests use constructed human geometry, the production LaserCollisionJudge/LaserWaveDirector, source-correlated synthetic pose values and the current solved mascot rig. P1 exercises each case; P2 stands at the fixture reference span. Synthetic standing spans are 1.0, 1.3, 1.6 and 1.75 **game units**, not a validated supported human-height or age range. The fixture image aspect is 1.5; it is not a characterization of the actual negotiated camera format.

## Test labels and measured results

**K04 A/B below are existing test labels, not the architecture proposal's policy A/B.** Both retain human-body verdict authority. Neither tests avatar-derived collision.

| Test mode | Current fixture behavior |
|---|---|
| K04 A | Fixed 1.6 m mascot; draw the beam at the authoritative player's game-space band. |
| K04 B | Same fixed mascot; DEBUG candidate scales only the drawn beam height using per-player avatar motion scale. Authoritative evidence/bands/verdicts remain unchanged. |

The main K03-packet matrix has 33 cases per mode: 30 CLEAR/HIT comparisons and three UNAVAILABLE cases.

| Main packet matrix | Agrees | CLEAR but avatar looks hit | HIT but avatar looks clear | Not judged |
|---|---:|---:|---:|---:|
| K04 A | 14 | 13 | 3 | 3 |
| K04 B | 20 | 8 | 2 | 3 |

These counts describe a deliberately selected fixture matrix, not camera accuracy, population success rates or physical safety.

- **Different spans:** the drawn-band candidate removes six recorded size-related mismatches: five shorter-player CLEAR cases and one taller-player HIT case. A height-preserving avatar candidate was not measured by this suite, so this run cannot choose between those policies.
- **Raised wrists:** both modes retain two HIT/looks-clear duck cases. The current rig's maximum hand-centre reach is **0.986 m**, below the lowest normalized duck band at **1.477 m**, on both arms/players in the dedicated fixture. Simple beam normalization does not solve this anatomy/reach difference.
- **Jump capability:** both modes retain eight CLEAR/looks-hit jump cases through the K03 packet path. That path has no authoritative airborne input in these fixtures and keeps the avatar grounded. With the CP1-shaped DEBUG bridge that supplies valid jump state, all **16 jump-state comparisons per mode** agree. This is supporting synthetic evidence, not permission to create another CP1 reader or treat procedural foot lift as airborne evidence.
- **Matched-span boundary samples:** four additional comparisons agree. They do not replace a complete exact-margin/threshold matrix on the rendered rig.

## What the measurements mean

[AvatarFairnessProbe](../Sedactive/Games/LaserHeist/Rendering/Avatar/AvatarFairnessProbe.swift) compares a posed head-top reference, hand-joint centres and derived sole points against the drawn band. Hand mesh radius, glow, perspective occlusion and the user's perceived silhouette are not measured by this sign comparison. Printed CSV values are rounded to three decimal places; `nan` means an unavailable human margin, not zero clearance.

Human margins use the authoritative band. Shown margins use the band actually drawn, including the candidate transform in K04 B. Do not subtract those values across modes as if they were one untransformed physical coordinate system.

The existing smoothing fixture reports human clearance at **0.633 s** and shown clearance at **0.650 s**, a **17 ms** difference, with synthetic 30 Hz input, 60 Hz render steps and the test's 30 ms smoothing setting. This is one deterministic logical-time sequence, not a device latency distribution or display-to-photon measurement.

## Jevon follow-up within the confirmed direction

Retain human crown/both-wrist and sole/valid-airborne authority and the current equality/margin rules. Do not close D07 by dropping required wrists, inferring airborne from visual feet, changing evidence windows or silently moving judged geometry.

Before activating live avatar gameplay, resolve or explicitly review the recorded mismatch classes with Edo/Kevin/Theo. Investigate the fixed-size candidate first under Edo's later direction; retain height-preserving fitting as the comparison if mismatches persist. Address the raised-arm silhouette/feedback problem explicitly; a HIT badge alone is not evidence that players understand a visually clear arm. Finish the same-source calibrated motion/airborne handoff without an extra gameplay subscriber.

This recommendation changes no runtime settings. The drawn-band normalization remains a candidate; no production tolerance, smoothing allowance, Vision FPS requirement or rig policy is selected here.

## Proposed acceptance protocol

| Checkpoint | Required cases and records | Review outcome |
|---|---|---|
| Deterministic canonical boundaries | Below/at/above each existing configured margin; crown plus each wrist, asymmetric soles, valid/invalid jump state, missing/weak fields and unequal spans. Record encounter/attempt/player, canonical band, source frame/time/context and verdict. | Jevon/Edo confirm rule/validity semantics; no hidden judge adjustment. |
| Candidate rig/beam comparison | Same fixtures through each reviewed visual mapping, at the interaction plane and current camera perspective. Record head/hand/sole references, root/scale/reach clamps, drawn band and policy version. | Kevin/Jevon compare size and arm mismatch classes; agree how residuals are measured before choosing tolerances. |
| Actual rendered comprehension | Inspect silhouettes, glow, overlap/occlusion, unavailable fallback and raised-wrist HITs for two players. Preserve the measured geometry beside visual evidence. | Theo/Kevin/Jevon decide whether cues and clearance are understandable; numeric agreement alone is insufficient. |
| Dynamic source/judgement correlation | Record original display frame/capture time, selected judgement frame/captured game time, crossing/deadline, mapping/retarget update time and smoothing residual. Include fast duck/jump, delayed/missing frames and context invalidation. | Edo/Kevin/Jevon select temporal criteria from evidence. Different displayed/judged frames may be legitimate; never retime captures or freeze live video to force equality. |
| Physical acceptance after input readiness | Different-height technical pilots, then consented parent–child comprehension/comfort checks; crossings/overlap, extra entrants, loss/rebind, pause/retry, actual camera format and device/resource conditions. | Record measured distributions, mismatches and untested cases. No universal identity, age, comfort or latency guarantee from synthetic tests. |

Use bounded numeric diagnostics; do not retain identifiable camera recordings without the team's approved consent/handling process. Optical latency needs a separately agreed measurement method. Physical work depends on validated input/calibration and the applicable integration gates; this review does not bypass E09/Q01.

## Remaining sign-off

| Owner | Decision still needed | Status |
|---|---|---|
| Kevin, following Edo's Tech Lead direction | Acknowledge fixed-size-first investigation order; compare height-preserving fitting if needed | Development direction recorded; Kevin acknowledgment pending |
| Edo + Kevin + Jevon | Production human-to-avatar mapping/fairness policy and the residual/temporal acceptance process | OPEN |
| Kevin + Theo, with Jevon | Size/arm silhouette and readable HIT/UNAVAILABLE feedback | OPEN |
| Edo + Kevin, with Jevon | Exact-source calibrated movement/airborne capability and invalidation handoff | OPEN |

The [architecture proposal's fairness section](https://github.com/M02-ADA/Didi/blob/feat/architecture/Docs/LaserHeist-Architecture-V2-Avatar-Pivot.md#L300-L342) and [D07 work package](https://github.com/M02-ADA/Didi/blob/feat/architecture/Docs/LaserHeist-Technical-Workplan-V2.md#L192-L205) remain proposals where no later affected-owner agreement is recorded. This evidence packet prepares Jevon's review contribution; D07 is not marked closed.
