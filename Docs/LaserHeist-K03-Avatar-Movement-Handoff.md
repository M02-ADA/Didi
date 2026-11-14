# K03 avatar movement — Kevin → Edo handoff

Status: **Proposed** (10 November 2026), branch `feat/k03-avatar-movement`. Presentation only: no packet field, calibration rule, judgment or gameplay value changed. Simulator-verified; **not yet seen on a physical iPad**.

## P0 checklist for the next iPad M4 session (two players)

Use the DEBUG "Real camera · game scene preview" on Home (direction-only) and a calibrated round (START MISSION, then calibrate both). For each step, record the screen, the route, both slots' tracking state and rebind flag, and the K03 accepted-packet count.

| # | Do | Expect | Not acceptable |
|---|---|---|---|
| 1 | P1 raises the right arm, P2 still; then swap; then both | The same anatomical arm on the same player's mascot, no visible lag | The other mascot moves; mirrored sides |
| 2 | Each player turns their head right, centre, left (~30°); then both at once in opposite directions | The mascot's head turns the same way from behind and returns straight | A head that stays turned after facing the camera; flicker when still |
| 3 | Lean sideways; then shrug one shoulder or reach up with one arm | The trunk leans and the head tilts. A shrug lifts that side's arm root slightly (subtle) | The whole body or the other shoulder moving for a shrug |
| 4 | Turn side-on, step closer and farther, cover the face with a hand | No head snap; the turn eases to straight when the ears are lost | Jumps or held poses |
| 5 | Walk out of frame and back; trigger a rebind | That mascot dims to neutral within ~0.5 s and returns without a jump; the partner is unaffected | A pose held after loss; both players reset |
| 6 | Crouch and jump on the direction-only route | **No** crouch, pelvis drop or root lift | Any lower-body movement |
| 7 | Crouch in the calibrated round | The pelvis lowers and the knees bend, feet planted | Root lift; feet sliding |

Capture a short clip of steps 2 and 3 for both players at once: that is the visible P0 change.

## What changed

- **Head turn (new, both modes).** The nose's sideways offset between the ears drives a head turn of up to about 35°. Facing the camera the nose sits midway for every face, at any camera height or distance, so it needs no standing reference. It is ignored when the nose or an ear is below confidence 0.3, or when the ear line collapses below 0.12 × shoulder width (about a 70° turn). It eases back to straight after 0.15 s without evidence, and fades with tracking loss like the rest of the pose. (`RobotRetargeter.headTurn`, `RobotPoseTargets.headYaw`, solver Head joint.)
- **Shoulder shrug (new, both modes).** The shoulder line's tilt beyond the trunk lean lifts **only the raised side's collarbone** (`Shoulder_L`/`Shoulder_R`), at about twice the tilt (one collarbone spans half the shoulders), up to about 29°. A rigid lean tilts the line by −lean, so only the rest counts. The trunk, neck, head, other shoulder and pelvis don't move, and the arm keeps its measured direction while its root rises. It needs no reference: a level shoulder line is level for every body and stays level when the body turns. It is ignored side-on (shoulders under 0.25 × torso length) and eases out without evidence. **It is subtle on this rig:** the arm roots sit just under the head, so a full shrug lifts the arm root about 4 cm on the 1.6 m mascot. (`RobotRetargeter.shoulderShrug`, `RobotPoseTargets.shoulderShrug`, solver Shoulder joints.)
- **Smoothing unchanged, by measurement.** Simulated 30 Hz Vision noise (σ = 0.004 image heights) on a 0.35 s arm raise: the 1€ joint filter trails by about 24 ms at mid-reach and 14 ms near the end, and halves rest jitter. Retuning would gain about 10 ms, so it was left alone. Render smoothing is 30 ms.
- **No crouch without calibration (decided, with evidence).** A pinhole model of an adult (1.75 m) and a child (1.10 m) in front of a floor camera tilted up 12° shows that direction-only ratios can't separate a DUCK-sized crouch (8 % drop) from body size or rotation:

  | Signal | Adult standing | Adult DUCK, 30° turn | Child standing |
  |---|---|---|---|
  | Hip-to-ankle ÷ shoulder width | 2.0 | 1.92 | 1.82 |
  | Hip-to-ankle ÷ torso | 1.85–1.95 | 1.50 | 1.35–1.40 |

  Only deep squats (30 %) separate, so no crouch signal is shown in direction-only mode, not even behind a DEBUG flag.

## Edo's `feat/visual-posture-evidence` (77ae6c3), reviewed read-only

- **Same data.** Every feature is computed from joints the merged K03 packet already carries (shoulders, hips, ankles of the bound candidate) through the same `VisionAvatarPacketAdapter` validation. Torso lean uses the same formula as K03's lean. Shoulder roll is what the K03 shrug above derives. **No new field is needed for these.**
- **Per-player baseline: it works where cross-person comparison failed.** Compression is each player's own leg ÷ torso ratio against their own standing value, with the same pinhole model and simulated Vision noise:

  | | Adult | Child |
  |---|---|---|
  | DUCK (8 % drop) | +0.21 | +0.20 |
  | DUCK, turned 30° | +0.21 | +0.20 |
  | Standing, stepped back / closer 0.5 m | +0.02 / −0.03 | +0.01 / −0.02 |
  | Standing, bent forward 15°, knees straight | +0.09 | +0.04 |
  | Single-frame noise σ | 0.04–0.06 | 0.06–0.09 |

  The per-player ratio separates a DUCK from distance and rotation. Two problems remain: noise, because a child's torso is short in the image, and leakage from bending forward without the knees.
- **Calibrated rounds keep today's crouch.** It uses hip-to-ankle span against the accepted standing hip/ankle heights. That method reads +0.16 when a standing player steps back 0.5 m. But the judge converts through the same calibrated mapping, so the mascot and the verdict move together. Switching rounds to the ratio would make the mascot disagree with the judge.

### Recommendation

| Item | Status |
|---|---|
| Head turn, shoulder shrug (K03, from merged joints) | **Safe now**: implemented and tested |
| Torso lean | Already in K03 with Edo's formula; nothing to integrate |
| Direction-only per-player crouch from leg ÷ torso | **DEBUG A/B only**, and only with an explicit neutral reference (below). It applies only to the uncalibrated setup/debug routes, because rounds are calibrated. |
| Any production crouch from the ratio, or replacing the calibrated crouch | **Blocked** pending Edo's device validation of noise, forward-bend leakage and neutral stability |

### Smallest contract, if the team wants the DEBUG A/B

The features need no new fields. The one missing input is an **explicit neutral reference** per player, which K03 must not learn from live frames. The smallest form: in the existing `VisionNumericPoseStatus`, the frame ID and capture time of each player's B2 pair acknowledgment (players stand still facing the camera to bind), invalidated by the existing control/presentation fences. The drain must deliver that frame, not coalesce it away. K03 would take that player's neutral leg ÷ torso from that one same-source frame, and drop it on rebind, context, generation or calibration change. No second subscriber is needed: it is the same E07 drain the pump already reads.

## Two modes to test

| Route | Mode | What moves |
|---|---|---|
| DEBUG "Real camera · game scene preview" on Home, or `--live-avatar-smoke` | **Direction-only.** These routes attach only with no accepted calibration. | Arms, sideways lean, head roll, **head turn** |
| START MISSION → calibrate both players → round | **Calibrated** (accepted calibration, frames after the cutover) | The above, plus **crouch from hips and ankles** with the knees bending and the feet planted |

The calibrated crouch already exists on staging, but the earlier test never reached it: it ran only on the direction-only routes.

## Two-player protocol (iPad M4 on the floor, both players in frame)

For each step, record a screen recording and note the **route**, both slots' **tracking state** (tracking / matched / rebind false), and the **K03 accepted-packet count** before and after.

1. **Arms (both routes).** P1 raises the right arm to the side, then overhead, while P2 stays still. Then swap players, then both at once. *Expected:* the same anatomical arm on the same player's mascot (the player's right arm moves the mascot's screen-right arm), no lag you can see, no movement on the other mascot.
2. **Head turn (both routes).** Each player slowly turns their head to their right, back to centre, then left, about 30° each way. Then both players turn opposite ways at once. *Expected:* the mascot's head turns the same way as seen from behind (player turns right → head turns to screen right). It returns straight when facing the camera, with no flicker when still.
3. **Sideways lean, head tilt and shrug (both routes).** *Expected:* the trunk leans and the head rolls, as before. Raising one shoulder (shrug, or reaching up with that arm) raises the mascot's same-side shoulder slightly.
4. **Crouch (calibrated round only).** After both calibrations are accepted: stand, a partial DUCK (about 15 cm), a deeper squat, then stand again. *Expected:* the pelvis lowers and the knees bend forward with the feet planted, then recovers. The visual depth follows the hips-and-ankles share of the player's own leg. Note any DUCK that the judge calls CLEAR while the mascot's head still looks in the beam: that is the recorded D07 size mismatch, not a K03 regression.
5. **Crouch on the direction-only routes.** *Expected:* **no** crouch, pelvis drop or root lift. Only the upper body moves. This is intentional.
6. **Jump (both routes).** *Expected:* feet stay planted and the root does not lift (no accepted airborne evidence exists). Arms and head still follow.
7. **Robustness.** One player turns side-on to the camera, steps closer, steps farther, walks out of frame and back, and covers their face with a hand. *Expected:* no head snap (the turn eases to straight when the ears are lost). The mascot dims to neutral within about 0.3 s when tracking is lost and comes back without a jump. A rebind or a calibration change resets that player only.

**Good retargeting:** every movement on the mascot matches a movement the player made, on the same side and the same player. **Misleading:** any mascot movement that the player didn't make. That includes a crouch on the direction-only routes, a jump lift, a head that keeps turning after the player faced the camera again, or a pose that holds after tracking is lost. Record the time and route if you see one.

## What K03 needs from E06/E07 for more (not requested from existing data)

1. **Elbows and knees in B1.** `PoseEstimator` already runs Vision's body pose, which detects them, but keeps 14 joints (`BodyJoint` has no elbow or knee cases). The retargeter already uses elbows when present: real elbow bends instead of straight arms. Knees would let the legs show the player's own knee direction in calibrated mode. On their own, the model above shows knees are **not** a clean direction-only crouch signal.
2. **The accepted standing frame's joints.** Nose, ears, neck, shoulders and hips from the calibration frame, in canonical image space, with the calibration revision. This is a valid upright reference that isn't learned from live frames. It would support head nod (pitch) and forward torso bend, which today depend on camera height and per-person posture, so they are not shown.
3. **`visual` crown/sole/centre and valid airborne evidence (E05/E06).** The factory sends `visual: nil` today, so there is no crown-based duck, sideways sway or jump lift. The retargeter already consumes them (`crownY`, `lowerSoleY`, `centerX`, `airborne`). Only `VisionK03PacketFactory` needs to fill them once they are accepted; no rig work is needed.
