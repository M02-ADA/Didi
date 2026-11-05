# 3D robot avatar (Debug spike)

> **Status:** Debug only, presentation only. The live camera path is verified on an iPad Pro 13" for frames, Vision and latency. Robot motion is verified with synthetic data in the Simulator; on hardware it still needs a person in front of the camera.

## Asset

`Rendering/Avatar/Robot/laserheist-robot.usdz` is Codex's `avatar.usdz`, byte-identical (sha1 `ed1be8dd…0f2255`):

- One skinned mesh on a 20-joint UsdSkel.
- 1.398 m tall, +Y up, facing −Z, with +X as the robot's anatomical right.
- Under our camera (at +Z, looking down −Z) we see the robot's back, and its right side is on screen right.

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

**Jump.** The robot rises by the lower sole height, but only while the jump hysteresis says airborne (enter above 6% of height, exit below 3%). This value is not smoothed. A raised knee lifts that foot.

**Duck.** Each leg's hip-to-ankle height, as a share of the calibrated standing height, sets that leg's reach on the robot's leg:

- The longer leg sets the pelvis drop.
- Two-bone IK solves each leg toward its ankle, with the knees bending forward (−Z).
- The feet stay level and planted (tested to within 2 mm).

**Arms.** Shoulder→elbow drives the upper arm, and elbow→wrist drives the forearm:

- Each segment is aimed in model space, then converted into its parent's space, so child joints follow.
- A limb that looks shorter than its longest measured length is pointing toward the camera, so it gets forward depth.

**Lean and head.** Shoulders over hips give the trunk tilt, split across Spine and Chest. The ear line gives head roll.

**Mirroring.** Player-plane differences (dx, dy) become (−dx, dy) in model space. This is the single presentation mirror, the same as `GameWorldMapping.cutoutPoint`. Anatomical sides are never swapped: the player's right wrist drives `Forearm_R`.

**Filtering.** Each joint passes a 1€ filter; a step change gets about 85% of the way within 100 ms. On tracking loss the robot eases back to its bind pose and dims, and recovery starts from fresh data.

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

**Evidence:** `robot-equal-size.png` is current. The older `robot-synthetic-*.png/.gif` and `live-avatar-lab-robot-simulator.png` predate equal sizing and still show a smaller P2.

## Removed 2D chibi experiment

Removed: `ChibiRig.swift`, `RearAvatar.swift`, `ChibiRetargeting.swift`, the `ChibiRig/` sprites and manifest, `ChibiRigTests.swift`, the `-rearAvatar` and `-rigDemo` flags, and the chibi art brief, manifest, slicer, master copy and evidence.

What survived was moved, not deleted:
- **The 1€ filter** is now `PoseSmoothing.swift`.
- **The synthetic scenarios** are now `Robot/RobotDemo.swift`, used by `-robotDemo` and the tests.
- **The replay hook** is now `-robotReplay`.

## Edo dependencies

1. Replace the Vision call in `LivePoseSink` with his `PoseEstimator` from `feat/vision-pose`.
2. Replace the lab's identity and calibration with his `PlayerTracker` and `CalibrationSession` when they land.
3. Decide whether the lab should keep owning its own `CameraPipeline` or borrow the shared one in `AppDependencies` through a frame fan-out.
