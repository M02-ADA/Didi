# 3D avatar: orange LaserHeist mascot (Debug spike)

> **Status:** Debug only, presentation only. The live camera path is verified on an iPad Pro 13" for frames, Vision and latency. Avatar motion is verified with synthetic data in the Simulator; on hardware it still needs a person in front of the camera.

## Asset

**Active avatar: the final colour-corrected orange mascot.** `Rendering/Avatar/Robot/mascot.usdz` is Codex's `mascot.usdz` from `LaserHeist-Original-Mascot-3D-Color/`, byte-identical (sha1 `61d0a911…a2d3ec`, 1.6 MiB). `RobotAvatarLayer.resourceName` is `"mascot"`, and it is the only avatar in the app bundle. Every 3D path loads it through `RobotAvatarLayer.loadTemplate()`, once per layer: the robot demo, the Live Avatar Lab, the live round and `-robotReplay`.

- One skinned mesh on a 20-joint UsdSkel: 14,309 vertices and 27,066 triangles per instance. The head shell and face are weighted to `Head` only.
- 7 matte PBR materials (roughness 0.94, metallic 0, specular 0.12, no emission on the body), used unchanged.
- 1.398 m tall, soles at y = 0, +Y up, facing −Z, with +X as the mascot's anatomical right. It is shown at the shared 1.6 m (scale 1.1445) for P1 and P2.
- Under our camera (at +Z, looking down −Z) we see its back, with its right side on screen right. P1 is on the left, P2 on the right, and no extra rotation or flip is applied.

**Rig compatibility.** Joint names, paths, order and parents match the earlier robots. The bind transforms differ:

| Model metres | First robot | Pilot mech | Orange mascot |
|---|---:|---:|---:|
| Pelvis Y | 0.665 | 0.526 | 0.406 |
| Upper-arm pivot X / Y | 0.177 / 0.995 | 0.361 / 0.790 | 0.135 / 0.605 |
| Ankle X / Y | 0.117 / 0.088 | 0.163 / 0.114 | 0.139 / 0.105 |
| Hip-to-ankle height | 0.574 | 0.393 | 0.293 |
| Head joint Y | 1.106 | 0.883 | 0.709 |

Everything geometric is read from the loaded bind pose, never assumed:
- **Bones and stance:** leg and bone lengths, leg rest height (crouch depth is a share of it), and ankle stance (the foot planner's home positions). The leg-rest fallback for a rig without leg joints is now the solver's own leg length, not the first robot's 0.574 m.
- **Knee plane:** knees bend in the bind pose's own plane, so the rest targets reproduce the bind exactly (`restTargetsReproduceTheBindPose`).
- **Foot planner:** its board-metre constants needed no change. Every foot scenario keeps 0.0 mm planted drift, no IK reach shortfall and no sole below the deck.

**Arm clearance (`MascotPoseEnvelope.swift`).** The shoulders sit under the large head, so an upper arm aimed straight up goes through it. Codex's helper is used with its values unchanged. It runs in `RobotAvatarLayer.present`, after smoothing and foot planning and immediately before the solve, only while `RobotAvatarLayer.headClearance` is on (tied to the mascot resource). It reads and writes presentation targets only, never Vision joints, body samples or anything judged. Its effect:
- Rising arms are turned outward: the upper arm settles about 9° above horizontal and the forearm about 34°, with more clearance when the trunk or head tilts.
- Downward arms are untouched, the change eases in over the first part of a raise, and left and right mirror each other.

`MascotArmClearanceTests` checks it on the real mesh, skinned on the CPU from the imported weights and inverse bind matrices (bind reproduced to < 0.1 mm) and posed by our solver:

| | Raw targets | With the helper |
|---|---|---|
| Arm vertices inside the head | 340–1,627 per pose (10 poses) | 0 in every pose |
| Closest arm vertex to the head | — | 5.5–44 mm |

The 10 poses: left, right or both arms up, forward-up, both up in a deep crouch, both up while leaning either way, right up while stepping, bent elbow, and reaching across. A 1° sweep from arm-down to arm-up never moves the shown direction by more than 3° per step, so there is no snapping.

**Lighting and colour.** The key (3000) and fill (1200) directional lights are unchanged; they are the same rig Codex validated the colours under.
- **The problem:** RealityView's default environment light added on top. It clipped red on 81% of the mascot's orange pixels and washed the lit orange to #FFA762, a pale peach.
- **The fix:** the avatars now receive their own uniform dark-grey environment light (`neutralEnvironment()`, sRGB 0.18) instead of the default one. The lit-orange median is #F68046, against #F47E44 in Codex's rear render under the same lights and the asset target #F78146.
- **Scope:** only the avatar containers receive it. The corridor and lasers are unlit, and they were pixel-identical in before/after captures.
- **How it was measured:** Simulator screenshots are sRGB-tagged and verified against a control in the same capture (the system-blue button reads exactly #0088FF). The figure is the median of orange pixels in the 45–85% luminance band. `evidence/mascot-color-check.png` shows before, after and the reference.
- **Not covered:** the iPad display itself (P3 panel, True Tone, brightness) has not been looked at.

**Verified (Simulator, synthetic poses; not yet a person on the iPad).** All 276 tests pass.
- **Watched in the landscape iPad Simulator:** idle, arms overhead (the new `-robotDemo arms-up`: both up, duck with arms up, P2 stepping with an arm up), asymmetric arms, duck, jump, P1 ducking while P2 jumps, step right, lean right, tracking loss and recovery, and the live round (lasers, JUMP cue, CLEAR/HIT).
- **Cost:** about 20 µs per solve, and about 80 µs per rendered frame for both avatars (retarget, planner, envelope, solve, joint write; Simulator). The pair is about 54k triangles, against 168k for the previous mech. iPad frame time and thermals are unmeasured.

**Known visual limits.**
- **Leg creases:** deep knee bends crease the backs of the short lower legs, from linear-blend skinning on the asset's weights. Codex's own crouch and step validation renders show the same; fixing it means changing the asset's weights, not our solver.
- **Knee angle:** the bind knee leans slightly inward as well as forward, so knees converge a little in a deep duck.
- **See-through when dimmed:** a tracking-lost avatar is dimmed to 50% opacity, and at that opacity the far side of the head and body shows through. The earlier avatars did the same.
- **Arms overhead:** a straight-up arm is shown out to the side by design, so it never matches the player's vertical arm.

**Rollback.**
- **Pilot mech (previous version):** Codex's `LaserHeist-Mascot-Pilot-Mech/mascot-pilot-mech.usdz` (sha1 `73ba1683…`).
- **Blue-and-white robot:** Codex's `LaserHeist-Robot/avatar.usdz` (sha1 `ed1be8dd…`), also in Git at `6cd0626` as `laserheist-robot.usdz`.
- **How to restore:**
  1. Copy the file in as `Rendering/Avatar/Robot/<name>.usdz`, remove `mascot.usdz`, and set `RobotAvatarLayer.resourceName` to `<name>`. `headClearance` then switches off on its own.
  2. Rebuild.
- **Tests that are mascot-specific:** `MascotArmClearanceTests.raisedArmsClearTheHeadOnlyWithTheEnvelope` expects `headClearance` and expects raw arms to hit the head, so it fails after a rollback; skip or remove it.

**Evidence** (`evidence/`, Simulator, synthetic):
- **Images:** `mascot-idle-landscape.png`, `mascot-color-check.png`, `mascot-live-round-sheet.png`.
- **Animations:** `mascot-arms-up.gif`, `mascot-arms.gif`, `mascot-duck.gif`, `mascot-jump.gif`, `mascot-duck-jump.gif`, `mascot-step-right.gif`, `mascot-lean-right.gif`, `mascot-tracking-loss.gif`, `mascot-live-round.gif`.

## Pipeline

```
Front camera → Edo's CameraPipeline (unchanged, owned by the lab)
  → LivePoseSink (Vision, newest frame only)                    [reused]
  → LiveAvatarTracker (staleness, P1/P2 identity, calibration)  [reused]
  → RobotRetargeter (human → robot targets)                     [new]
  → RobotPoseSolver (FK aim + two-bone leg IK → jointTransforms) [new]
  → RobotAvatarLayer (one clone per player on its lane)          [new]
```

## Retargeting

**Jump.** The robot rises by the lower sole height continuously, from the first frame the feet leave the floor; it does not wait for the jump phase. Lift below 2% of standing height is a soft noise zone, so tiptoe jitter barely moves the robot and leaving the zone never steps. A fast 1€ filter follows takeoff within about a frame. Missing feet hold the last lift for 0.15 s, then settle. A raised knee lifts that foot only. The robot's lift is presentation: it never feeds the jump phase or the checker.

**Duck.** Each leg's hip-to-ankle height, as a share of the calibrated standing height, sets that leg's reach on the robot's leg:

- The longer leg sets the pelvis drop.
- Two-bone IK solves each leg toward its ankle, with the knees bending forward (−Z).
- The feet stay level and planted (tested to within 2 mm).

**Arms.** Shoulder→elbow drives the upper arm, and elbow→wrist drives the forearm:

- Each segment is aimed in model space, then converted into its parent's space, so child joints follow.
- A limb that looks shorter than its longest measured length is pointing toward the camera, so it gets forward depth.

**Lean and head.** Shoulders over hips give the trunk tilt, split across Spine and Chest. The ear line gives head roll.

**Mirroring.** Player-plane differences (dx, dy) become (−dx, dy) in model space. This is the single presentation mirror, the same as `GameWorldMapping.cutoutPoint`. Anatomical sides are never swapped: the player's right wrist drives `Forearm_R`.

**Filtering.** Each joint passes a 1€ filter; a step change gets about 85% of the way within 100 ms. The lab also eases the shown pose toward the latest camera pose at render rate (30 ms), so 30 Hz poses don't step on a 60 Hz display.

**Dropout.** One or two missed detections (up to 0.15 s) hold the pose exactly, still shown as tracked. After that the pose fades to the bind pose (τ 0.3 s) and dims. Recovery fades back in (τ 0.08 s) toward fresh data, never the old pose. A low-confidence arm holds for 0.5 s, then fades to rest; it fades back in when seen again. Elbows are limited to 150°. Crouch uses a soft 3% dead zone instead of a step.

## Deployment

The lab build is installed under a separate Debug-only bundle identifier, `com.Edward-Kristian.Sedactive.avatarlab`, set on the `xcodebuild` command line. No project, scheme or signing file is changed. It installs next to the normal Sedactive app without conflicting:

```bash
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive -configuration Debug -destination "id=<iPad UDID>" -allowProvisioningUpdates PRODUCT_BUNDLE_IDENTIFIER=com.Edward-Kristian.Sedactive.avatarlab build
```

## Size

Both players get the same robot at the same size: `RobotAvatarLayer.standingHeight` (1.6 m), applied as one uniform `modelScale`. Their lanes sit at the same depth (authored anchors at (±0.7, 0, 0)), so the robots also appear equally tall through the gameplay camera; a test checks the projected heights.

A player's own height never sizes the robot. It still normalises that player's motion through `RobotRetargeter.motionScale` (`standingHeight / player's standing height`):
- **Jump lift and sideways steps** are scaled by it.
- **Crouch depth** is a share of the player's own leg length.
- **Arm and trunk directions** don't depend on size.

**Evidence:** `mascot-idle-landscape.png` is current (orange mascot). `robot-equal-size.png` shows the earlier robot. The older `robot-synthetic-*.png/.gif` and `live-avatar-lab-robot-simulator.png` predate equal sizing and still show a smaller P2.

## Removed 2D chibi experiment

Removed: `ChibiRig.swift`, `RearAvatar.swift`, `ChibiRetargeting.swift`, the `ChibiRig/` sprites and manifest, `ChibiRigTests.swift`, the `-rearAvatar` and `-rigDemo` flags, and the chibi art brief, manifest, slicer, master copy and evidence.

What survived was moved, not deleted:
- **The 1€ filter** is now `PoseSmoothing.swift`.
- **The synthetic scenarios** are now `Robot/RobotDemo.swift`, used by `-robotDemo` and the tests.
- **The replay hook** is now `-robotReplay`.

## Live round (real rules, Debug only)

`Live/LiveGameSession.swift` is a temporary adapter for Jevon to review. `GameSessionCoordinator` is replay-only, so live evidence never reached the checker before. Each live frame's `BodySnapshot` (the same frame ID, capture time and players the robot is posed from) now goes into Jevon's own types:

- **Schedule:** `LaserWaveDirector` places the lasers from the live calibrations, using the conservative candidate profile and an alternating DUCK/JUMP sequence every 6 s.
- **Clock:** `GameClock` is anchored to the camera's host clock.
- **Judging:** `LaserGame` and `LaserCollisionJudge` select the evidence nearest each crossing and judge it.
- **Presentation:** the existing `GameplayScenePresenter` draws corridor travel, gates, cues and CLEAR/HIT badges.

**Solo mode** schedules P2's targets with P1's standing reference, which only places P2's beam. Nobody is there, so every P2 target is UNAVAILABLE and encounters are technical: no damage, no score.

**Co-op mode** needs both players calibrated and applies real team effects.

**Verdict panel.** For each judged target the panel shows:
- the checker's measurement against its threshold;
- the frame it used and its offset from the crossing;
- the frame's arrival delay;
- the robot's lift and crouch for that same frame.

**Launch flags:**
- `-liveGame solo` or `-liveGame coop`: open the lab and start a round as soon as the players are calibrated.
- `-liveGameSynthetic`: add to drive the round with a scripted SYNTHETIC player, for Simulator checks.

**Evidence:** `live-round-synthetic.png` and `live-round-verdict-panel.png` (Simulator, synthetic player).

## Jump tuning (Debug live round)

Root causes of "jump is hard" on the iPad:
1. The first live rule needed the feet 6% of standing height up (9.6 cm on a 1.6 m player) before calling a jump. The checker's JUMP beam only needs about 3.2 cm, so real hops that cleared the beam were judged HIT (not airborne).
2. Any frame missing an ankle ended the jump at once.
3. The robot only rose once that phase flipped, so a small hop showed nothing, and a big one popped up 9.6 cm late and dropped 4.8 cm on landing.

`LiveJumpDetector` has two named rules. Pick one in the lab (segmented control) or with `-jumpTuning original|tuned` (default: tuned).

| | original | tuned |
|---|---|---|
| Start | both soles > 6% of height | both soles > 3% of height **and** > 4× the player's own standing foot noise |
| Takeoff shape | none | must rise 80% of the start height within 0.25 s (a hop, not a slow rise onto the toes) |
| Land | < 3% | < 1.5% |
| Missing ankles | ends the jump | frames are *unknown* (never airborne); a jump survives 2 such frames |
| Floor | fixed calibration | follows the grounded foot height (τ 1 s) |

The checker is unchanged: same beam, margin, evidence window and rule (lower sole above the beam while airborne). Only the Debug evidence's jump phase differs.

Before/after on the same SYNTHETIC recordings (`LiveJumpTuningTests`, a 1.6 m player, 30 fps, ±1.2 cm ankle jitter). Columns: jumps / airborne frames / takeoff latency in frames after the feet are 2 cm up:

| Recording | original | tuned |
|---|---|---|
| standing noise | 0 / 0 / — | 0 / 0 / — |
| slow tiptoe 6 cm | 0 / 0 / — | 0 / 0 / — |
| one knee raised 25 cm | 0 / 0 / — | 0 / 0 / — |
| small hop 6 cm | **0** / 0 / — | **1** / 5 / 1 |
| hop 10 cm | 1 / 4 / 4 | 1 / 8 / 1 |
| jump 20 cm | 1 / 10 / 2 | 1 / 13 / 0 |
| hop 10 cm, 1 frame dropout | **0** / 0 / — | **1** / 7 / 1 |
| ankles lost, back 2 cm higher | 0 / 0 / — | 0 / 0 / — |

`evidence/jump-tuning-compare.png` plots the two hops. In the live round test a 5% hop is HIT (not airborne) with the original rule and CLEAR with the tuned one; clear jumps, misses and standing still get identical verdicts and frames under both.

**Not yet supported by real data:** these numbers come from synthetic tracks. The real ankle noise, tiptoe height and hop shape on the iPad are unmeasured; the lab now logs them (below).

**Comfort proposals for Jevon (not implemented):**
1. For JUMP, select the best eligible frame in the evidence window rather than the one nearest the crossing. A hop then only needs to be airborne at some point in [−0.35, +0.25] s, instead of within about one frame of the crossing.
2. Review whether ~2% of standing height is the intended JUMP beam once real hop heights are measured.

## Foot planting and side steps (Debug)

**Cause of the sliding (before):** `RobotAvatarLayer` moved the whole robot container by the hip centre's X, and the leg IK aimed each ankle at its fixed bind position in model space. Both feet therefore travelled with the hips: any sideways movement (lean, sway or step) slid the robot across the board. Tracked ankle X was never used; nothing modelled foot contact.

**Now:** feet live in hoverboard space (the player entity's local frame, which stays put while the corridor travels):
- `RobotFootPlanner` keeps each foot PLANTED, STEPPING (a compact arc lasting 0.12–0.25 s, 2.5–6 cm high, longer and higher for longer steps; sideways travel front-loaded and decelerating into the landing) or AIRBORNE. One foot steps at a time; the support foot stays planted. While a foot steps, the pelvis shifts slightly toward the support foot and dips (2 cm, 1.2 cm).
- A planted foot is released only on evidence:
  - **Tracked ankle:** the ankle, relative to the hip centre and to the player's own standing stance (learned from the first 10 grounded frames), moved more than 3.5 cm (robot scale) for one camera frame (33 ms), or the foot visibly lifted.
  - **Balance fallback:** only for a foot without ankle evidence, when it is more than 9 cm from where it stands under the pelvis for 0.1 s. The foot on the side the body moved toward goes first.
  - **Reach guard:** a foot more than 22 cm from its stance under the pelvis.
- **Lean vs step:** a lean moves the hips, not the ankles, so the feet stay and the legs angle; a step moves the ankles.
- **IK:** each foot has its own target (`RobotPoseTargets.footShift`). The solver lowers the pelvis just enough for both legs to reach (`reachDrop`), so the knees bend over spread feet instead of the feet being dragged; it is zero at rest.
- **Jump:** both feet release at takeoff (root lift > 3 cm), hang under the body, and plant where they land (< 1.2 cm). No step starts in the air.
- **Timing:** pelvis and feet read the same render-smoothed values in the same rendered frame.

**Comparison:** the Lab has a *Feet: planted / legacy* switch; `-legacyFeet` starts any Debug path in the old behaviour. The lab's player chip and `-robotDemo` show one feet line per player: contact, step reason, tracked ankle offset, planted drift, foot height, steps, reach shortfall. Lab stats include `feetReadout`.

**Demo scenarios** (`-robotDemo <key>`, SYNTHETIC): `lean-right`, `lean-left`, `step-right`, `step-left`, `two-steps`, `step-stop`, `duck-planted`, `step-jump`, `loss-step`, `p1-step-p2-idle`, plus the earlier ones (`idle`, `p1-jump`, ...).

**Measured on the same synthetic input** (`RobotFootPlantingTests`, 30 Hz frames, 60 Hz render, Simulator):

| Scenario | Planted-foot drift, before | After | Steps per foot, after |
|---|---|---|---|
| Lean right/left (hips 7 cm, ankles still) | 70 mm | 0.0 mm | 0 |
| Step right/left 16 cm and back | 123–160 mm | 0.0 mm | 2 |
| Two steps out, two back | — | 0.0 mm | 4 |
| Duck with balance sway | — | 0.0 mm | 0 |
| P2 idle with 1.2 cm sway while P1 steps | — | 0.0 mm | 0 |

No foot goes below the deck in any scenario; the IK reaches every planted foot (shortfall 0.0 mm). The largest per-frame foot move is 17–26 mm sideways and 12–15 mm vertically during a step (no snaps). Responsiveness: the robot's leading foot passes the half-way point of a 16 cm step 133 ms after the player's ankle does (30 ms render smoothing, one-frame confirmation, front-loaded swing); this is added to the camera-to-avatar pipeline, which the lab measures separately. Cost: about 78 µs per rendered frame for both robots (retarget, planner, solve, joint write; Simulator).

Evidence: `evidence/feet-step-right-before-after.gif`, `evidence/feet-lean-right-before-after.gif` (separate runs, not frame-synchronised), and `evidence/feet-*.gif` for the other scenarios.

**Limits:** Vision gives 2D joints, so contact is inferred from ankle motion, not measured. The stance is learned once per robot (a player who widens their stance permanently looks like a step). Ankles are the least confident Vision joints; with them missing, steps come only from the balance fallback. Not yet verified with real human movement on a device.

## Lab diagnostics

The player chip shows ankle validity (L✓ R✓), lower-sole lift against the start threshold, the noise floor, the phase, the jump count and the active rule. Each verdict line names a cause from that player's own frames within ±0.6 s:
- **TRACKING:** no usable evidence (UNAVAILABLE).
- **TIMING:** the move happened, but not at the crossing.
- **DETECTION:** feet above the beam, but no jump recognized.
- **CLEARANCE:** recognized, but not high or low enough.
- **NO MOVE:** nothing seen.
- **PRESENTATION:** CLEAR, but the robot barely showed it.

Lab stats (`Documents/live-avatar-lab-stats.json` on the device: counts, timings, verdict lines and the jump readout; no images or joints) are now written by default; `-noLabLog` turns them off.

## Edo dependencies

1. Replace the Vision call in `LivePoseSink` with his `PoseEstimator` from `feat/vision-pose`.
2. Replace the lab's identity and calibration with his `PlayerTracker` and `CalibrationSession` when they land.
3. Decide whether the lab should keep owning its own `CameraPipeline` or borrow the shared one in `AppDependencies` through a frame fan-out.
4. The jump phase is CP1 evidence the checker relies on. Until his `JumpDetector` exists, the lab uses `LiveJumpDetector` (see *Jump tuning*); its rule should move to him with it.

## Jevon dependencies

1. Move the live round into Session (a live `GameSessionCoordinator`) and review `LiveGameSession`.
2. Tracking-loss pause and recovery (gameplay rules §B) is not applied in the Debug live round.
