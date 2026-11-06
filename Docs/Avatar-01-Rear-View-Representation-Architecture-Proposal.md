# Avatar-01 — Rear-View Representation Architecture Proposal

6 November 2026 · Design owner: Edo · Rendering review: Kevin · Gameplay review: Jevon

**Status: PROPOSED — design only; implementation and extraction are not authorized by this document.** The Tech Lead selected selective adoption (Option B) as the direction. The coordinate candidate, presentation packet, extraction adaptations, visual policy and acceptance gates below require the indicated owner reviews. No new CP1/CP2 decision, tracker acceptance, asset license, gameplay rule or physical performance claim is implied.

**Dated correction — 6 November 2026 (source-verified):** this proposal pinned the spike at `6cd0626` and its blue robot asset. The spike is now at `b130d5a`. Read the pinned rows below with these updates; the extraction principles and exclusions are unchanged and nothing here is approved:

- **Asset:** the active, approved asset is the final orange mascot `Rendering/Avatar/Robot/mascot.usdz` (sha1 `61d0a911…a2d3ec`, 1.6 MiB, `Mascot.usdc`, 20 joints, 1.398 m, +Y up/−Z forward/+X anatomical right, 7 matte PBR materials), from Codex's `LaserHeist-Original-Mascot-3D-Color` package derived from Asset 13. `laserheist-robot.usdz` below is historical. The §2.3 rights/provenance gate still applies (WP-D08).
- **New spike files to review with the same retain/adapt rules:** `Robot/MascotPoseEnvelope.swift` (raises arms outward to clear the large head; presentation targets only), avatar-only lighting in `RobotAvatar.swift`, and `SedactiveTests/.../MascotArmClearanceTests.swift` (CPU-skinned real-mesh arm/head clearance).
- **Foot planting** (`RobotFootPlanner.swift`) is implemented with deterministic tests; adoption remains a separate WP-K07 decision after the first rig/retarget checkpoint.
- **Physical evidence:** user-reported single-player iPad feasibility through the excluded lab stack (JUMP/DUCK observed, movement-quality issues reported). Not production acceptance; two-player tracking, latency and stability are unverified.
- **Exclusion reconfirmed:** the spike's Live Avatar Lab runs its own `CameraPipeline` instance, Vision request, identity, calibration, jump detection and GameClock, and in DEBUG `-liveGame` mode feeds its own BodySnapshots into LaserGame. The §2.2 exclusions stand.

## 1. Recommended adoption decision and verified baseline

Adopt the spike as a source for a **synthetic, rendering-only rear-view avatar prototype**, not as an alternative live input/session implementation. Keep Lean Game-Oriented logical modules within the existing app/test targets; add no package, engine, global layer or second camera owner.

| Inspected reference | Commit / state |
|---|---|
| Working checkout | `feat/player-tracking`, `69860cc75d820c76c3ac45cfac09edce651892f7` |
| Reference staging | `origin/staging`, `5070c0431b8c3fda6a0a0882e667e2b967edc09c` |
| Extraction source | `origin/spike/front-facing-avatar`, `6cd062680e5967778125f2b87c01bd189e461229` (same available local spike tip) |
| Spike/staging merge base | `9ea77feead299fbf932fb0170ce244f4d03f3f87` |
| B2a | Pure core present; report says **READY FOR RE-REVIEW**, not accepted or live-integrated |
| Unrelated local work | Signing `.pbxproj` edit and untracked `Scripts/`; preserve both |

The spike contributes 36 additions and three modifications from its merge base. Staging also contains B1 and newer replay tests absent from the spike. Do not copy its complete tree or interpret those absent files as approved deletions. The source commit contains no Shared, project-file or RCP-asset changes relative to its base.

Verified implementation: RealityKit skinned USDZ cloning; skeleton/IK; procedural feet; joint retargeting and smoothing. The spike also contains a separate camera/Vision sink, greedy identity, approximate calibration/jump evidence and a Rendering-owned live game adapter. Those live components are excluded.

| Boundary | Accepted baseline | Spike | Avatar-01 recommendation |
|---|---|---|---|
| Capture / inference | One retained CameraPipeline, bounded FrameStore, B1 PoseEstimator | Separate lab pipeline/custom sink | No camera in Avatar-01; preserve accepted future source |
| Identity / calibration | Edo contracts; B2a review and LH-22 pending | LiveIdentity / LiveCalibrator | Synthetic labeled fixtures only; no replacement algorithms |
| Presentation | RealityKit corridor and existing cutout mapping | Rear-view robot with reflected motion | Selectively adapt rig/renderer; approve mapping explicitly |
| Gameplay | Jevon's rules, GameClock and session | Temporary live adapter in Rendering | Static visual clearance fixtures; no game/session changes |

References: [team ownership](TEAM_ALIGNMENT.md), [lean layout](Architecture/Game-Oriented-Architecture.md), [CP1](LH-00-Checkpoint-1-Contract-Proposal.md), [CP2](LH-00-Checkpoint-2-Cutout-Handoff-Proposal.md), [B1 acceptance](LH-13B1-Raw-Vision-Pose-Implementation-Report.md), [B2 design](LH-13B2-Stable-Player-Tracking-Architecture-Proposal.md), [B2a correction history](LH-13B2a-Pure-Tracking-Core-Implementation-Report.md). Historical architecture text about profiles/skeleton implementations does not override actual anonymous PlayerID values or implemented code.

## 2. Exact extraction list and resource gate

Paths in this section are repository-relative. Every spike source is pinned to the commit in §1. All rows are future proposals; no file is extracted now.

### 2.1 Retain or adapt

| Exact spike source | Proposed destination / action | Required adaptation |
|---|---|---|
| `Sedactive/Games/LaserHeist/Rendering/Avatar/Robot/mascot.usdz` (replaces the historical `laserheist-robot.usdz`) | Same path, **conditional retain** | Provenance/license approval (WP-D08); runtime bundle and rig checks. No regenerated asset. |
| `Sedactive/Games/LaserHeist/Rendering/Avatar/Robot/RobotSkeleton.swift` | Same path, retain solver / adapt validation | Validate unique required names, parent order, transform counts, finite values and compatible unit bind scales. Fail clearly instead of silently using fallback limb lengths. Keep model-space FK → parent-local rotation and two-bone IK. |
| `Sedactive/Games/LaserHeist/Rendering/Avatar/Robot/RobotAvatar.swift` | Same path, **adapt substantially** | Keep RobotRetargeter / RobotAvatarLayer concepts; consume §5, remove launch-argument policy and assumed CP1-shaped synthetic evidence, validate contexts, add no-frame invalidation, explicit cleanup, rig metadata and size policy. Do not copy its weak generation/frame-only gate. |
| `Sedactive/Games/LaserHeist/Rendering/Avatar/PresentationPose.swift` | Same path, **replace proposed DTO design** | Use §5 exact provenance and explicit P1/P2 outcomes. Existing `matches` checks only generation/frameID and is insufficient. No public CP1 model change. |
| `Sedactive/Games/LaserHeist/Rendering/Avatar/PoseSmoothing.swift` | Same path, retain algorithm / adapt policy | Typed finite parameters, deterministic injected elapsed times, reset filters on invalidation. No production latency claim from synthetic tuning. |
| `Sedactive/Games/LaserHeist/Rendering/Avatar/Robot/RobotFootPlanner.swift` | Same path, conditional second step | Keep bounded presentation-only planner; name units/tunables; reset contacts/stance on context loss. Include only after basic rig acceptance, not as prerequisite for arms/rest/IK. |
| `Sedactive/Games/LaserHeist/Rendering/Avatar/Robot/RobotDemo.swift` | Adapt synthetic fixture logic into `SedactiveTests/Games/LaserHeist/RenderingTests/AvatarPoseFixtures.swift` | Remove replay-script/provider dependency, BodySnapshot manufacture, gameplay reactions and launch routing. A small separately reviewed DEBUG host can reuse the fixtures later. |
| `SedactiveTests/Games/LaserHeist/RenderingTests/RobotAvatarTests.swift` | Same path, selectively adapt | Keep import, independent clones, bind pose, anatomical sides and IK cases; replace old envelope assumptions and timing assertions as acceptance policy. |
| `SedactiveTests/Games/LaserHeist/RenderingTests/RobotFootPlantingTests.swift` | Same path, conditional second step | Keep deterministic contact/IK tests after planner inclusion; migrate fixture source. Synthetic wall-clock timing is characterization, not a universal pass threshold. |

**Minimum coherent implementation surface:** licensed asset + validated RobotSkeleton/RobotPoseSolver + adapted RobotAvatar.swift + PresentationPose.swift + PoseSmoothing.swift + deterministic fixture/test files. Include the filter because the retargeter references it, with explicit synthetic parameters. For the first checkpoint, remove RobotFootPlanner-dependent fields/calls, foot diagnostics/contact state and legacy launch switches from the adapted RobotAvatar.swift; use direct standing-stance IK targets and synthetic foot lift instead. Otherwise omitting RobotFootPlanner.swift would not form a compilable extraction. Full procedural stepping is a later coherent addition with its tests. Removing gameplay/input dependencies is an actual adaptation, not permission to copy these files unchanged.

### 2.2 Explicit exclusions

- Entire `Sedactive/Games/LaserHeist/Rendering/Avatar/Live/`: `LivePoseSink.swift`, `LiveAvatarTracking.swift`, `LiveAvatarLabModel.swift`, `LiveAvatarLabView.swift`, `LiveGameSession.swift`, `LiveSyntheticPlayer.swift`.
- Spike edits to `Sedactive/Games/LaserHeist/UI/PlayView.swift`, `Rendering/LaserScene.swift`, and `Rendering/GameplayScenePresenter.swift`. Do not extract those hooks wholesale. Any later Kevin-owned host patch must be separately scoped and approved.
- `LiveAvatarTests.swift`, `LiveGameplayTests.swift` and `LiveJumpTuningTests.swift` as adoption tests: they validate excluded lab components. They may inform scenario design but are not migration candidates.
- Spike evidence PNG/GIFs and README claims as proof of new acceptance. Link historical evidence when useful; do not copy media into the app or treat them as frame/latency measurements.
- No CameraPipeline, FrameStore, PoseEstimator, PlayerTracker, MotionEngine, calibration, gameplay or CP1/CP2 changes. No extra frame consumer, source fan-out implementation or live adapter in Avatar-01.

### 2.3 Asset provenance, license and target membership

*Historical (superseded by the orange mascot; see the dated correction at the top):* the pinned asset is 738,481 bytes, SHA-256 `dcce9ba6132800a5ffd284c54ce97e93507fdbffe5dfe740f3f0f10ae1265dc4`, a USDZ archive with `Robot.usdc`. The spike README attributes it to a Codex `avatar.usdz`; that statement and a hash are **not a license or full provenance record**. No dedicated license/notice was found in the inspected tree. The source/tests declare 20 joints, +Y up, −Z forward, +X anatomical right and native height 1.398 m; these must be checked on actual import, not trusted for arbitrary replacements.

Pinned source anchors: [asset/retargeting claims](https://github.com/M02-ADA/Didi/blob/6cd062680e5967778125f2b87c01bd189e461229/Docs/Avatar-Spike/robot/README.md), [clone/rig attachment](https://github.com/M02-ADA/Didi/blob/6cd062680e5967778125f2b87c01bd189e461229/Sedactive/Games/LaserHeist/Rendering/Avatar/Robot/RobotAvatar.swift#L379), [skeleton and IK](https://github.com/M02-ADA/Didi/blob/6cd062680e5967778125f2b87c01bd189e461229/Sedactive/Games/LaserHeist/Rendering/Avatar/Robot/RobotSkeleton.swift#L127), [old incomplete packet match](https://github.com/M02-ADA/Didi/blob/6cd062680e5967778125f2b87c01bd189e461229/Sedactive/Games/LaserHeist/Rendering/Avatar/PresentationPose.swift#L49). The URL uses the checkout's configured `M02-ADA/Didi` remote, not an assumed repository rename.

Before copying the asset, Kevin/Theo and Edo must record its original source/generation history, rights to modify/distribute, third-party contributions and required attribution (or explicitly confirm no attribution is required). If unresolved, block extraction of this asset; do not invent clearance. Pure numeric/contract design can proceed without it. No legal conclusion is made here.

The app and root SedactiveTests targets use separate filesystem-synchronized groups with no spike membership exception. Proposed app files stay under app source and tests under test source. No `.pbxproj` change is expected. Verify actual built app contains exactly the intended USDZ, `Bundle.main` lookup works from hosted tests, no runtime download/local absolute asset path is required, and required joints import. Test resources must not accidentally enter app source.

For a DEBUG-only candidate, source compilation can be DEBUG-gated. That alone does **not** exclude the USDZ from Release resources. Check Release bundle contents/size explicitly and agree whether shipping the dormant asset is acceptable; do not promise DEBUG asset exclusion without a reviewed resource strategy. No new target/package or project-setting workaround is preauthorized.

## 3. Rendering and joint ownership architecture

```text
Avatar-01 synthetic fixtures (explicit synthetic origin / supplied clock)
  → immutable AvatarPoseFrame + independent context/invalidation event
  → MainActor avatar layer
      source/identity/reference validation → retarget targets → FK/IK
      → one reviewed render/update hook → jointTransforms / local presentation

Future, NOT implemented by Avatar-01:
CameraPipeline → bounded FrameStore → B1 PoseEstimator → one worker-owned tracker
  → reusable immutable source/tracking values (+ LH-22 reference when accepted)
  → App-composed game adapter → same renderer-facing packet
  └→ approved measurement/provider path → CP1 → Jevon's sole gameplay consumer
```

Edo remains authoritative for original camera metadata, candidate association, binding/control revision, accepted calibration and human evidence. Kevin owns only visual targets, rig state, filtering/IK, placement and fallback. Synthetic fixture IDs are explicit labels, not a tracker or a live provider. Jevon alone controls game phase, verdicts, countdown/recovery and GameClock. No render state feeds back as human evidence.

Shared must not import game Rendering. The proposed packet is game-specific, defined once at the renderer boundary (`PresentationPose.swift`, Kevin owner, Edo co-review). Future App composition adapts existing reusable results; it must not retrack people or compute competing calibrations. The exact future worker/publication adapter is a B2b/LH-13C integration decision, not an interface quietly added here.

One MainActor layer owns both avatar entities and a reviewed per-frame subscription. Numeric packet delivery is latest-only: at most one pending packet and one current packet; replacement drops the entire combined pending frame. No raw image, Data image payload, CV/VN object, CP2 lease, texture upload or Task-per-pose. Fixed joint keys (at most the 16 proposed PresentationJoint cases) and exactly two slot outcomes bound payload size. Renderer history is limited to current/filter state per named joint and current foot contacts; no stream-length pose history.

The synthetic test host should instantiate the existing LaserScene without changing it, read its lane anchors/camera, and attach an owned avatar subtree. Add only one optional owned lighting group, remove it at teardown, and restore only presentation nodes the layer itself hid. Do not attach CP2 simultaneously to the same player surface. Use a Kevin-reviewed explicit host mode to select cutout/pictogram/avatar rather than two presenters fighting over entity visibility.

## 4. Coordinate transformation contract and examples

**Preserved:** source pixels and Vision coordinates are canonical upright/unmirrored. **Proposed for review:** anatomical co-facing avatar control. This is not approval to change the accepted DEBUG camera preview, CP2 mapping, initial B2a binding or GameWorldMapping.

### 4.1 Spaces and transformation matrix

Use column vectors; transforms apply right-to-left. Length units must be named, not inferred from a field called X/Y.

| From → to | Proposed mapping / invariant | Authority |
|---|---|---|
| Sensor raster → delivered canonical raster | Existing capture-applied orientation; source records applied rotation (current landscape 0°/180°), unmirrored state and dimensions | Edo; unchanged capture |
| Delivered top-left raster → Vision normalized bottom-left | Pixel-edge coordinates `x=c/W`, `y=1-r/H`; pixel centers use `(c+0.5)/W`, `1-(r+0.5)/H`. Already-upright pixels go to Vision `.up`. Never reapply recorded capture rotation | Edo |
| Canonical image → optional **unmirrored** diagnostic image UI | In fitted rectangle `(ox,oy,w,h)`: `u=ox+x*w`, `v=oy+(1-y)*h` | New route only after Kevin review; existing mirrored A2 preview unchanged |
| Canonical joint delta → aspect-corrected camera plane | `D=diag(A,1,1)`, `A=W/H`; `d_c=D*(dx,dy,0)`. Temporary +Z is toward the camera/viewer to complete a right-handed basis; Vision 2D supplies no measured Z | Read-only geometric adaptation; no alteration to PoseFrame |
| Front-facing person plane → co-facing anatomical avatar basis | `R=R_y(π)=diag(-1,1,-1)`; hence `R*d_c=(-A*dx,dy,0)` | **Proposed Edo/Kevin mapping**, not camera mirroring |
| Asset basis → canonical avatar basis | Fixed proper rotation `Q_asset` and positive uniform scale, validated once; candidate asset has `Q_asset=I` because +Y up/−Z forward/+X right already match | Kevin |
| Avatar model → world | `p_w=T_lane * T_visual * Q_asset * S_uniform * p_model`; translations in world metres, `S_uniform=H_avatarMetres/H_assetMetres`, parent scale/rotation validated or explicitly compensated | Kevin; read existing lane mapping |
| World → screen | Existing PerspectiveCamera view/projection; positive world X is screen-right for current corridor view, world +Y up, −Z down corridor | Kevin; no global world flip |

`R` has determinant +1: it is a change from the front-facing human plane into a co-facing body basis, not negative entity scale. For planar data its X sign resembles the old mirror. Keep that distinction explicit; a negative sign is not automatically an error. This rotation must not also be applied to the whole robot/world: the asset already faces into the corridor. Nor does the planar conversion infer real 3D joint depth. Avatar-01 should use planar directions initially; spike projected-length depth is an optional separately tested aesthetic candidate, never measured evidence.

For a calibrated image point, keep existing CP1 mapping exactly:

```text
X_human = L + (x - x0) * A * S
Y_human = (y - floorY) * S

avatarSwayMetres = -metersPerGameUnit * (X_human - L) * motionGain
```

`S` is the one accepted human player-plane scale in game units per image height. Read `metersPerGameUnit` and lane world positions from existing GameWorldMapping; do not hardcode a second lane or world scale. `motionGain` is dimensionless and explicitly cosmetic, independent of canonical measurement. It is not an implicit change to CP1 or laser geometry. Synthetic equal-height normalization can use `H_avatarMetres/(H_humanGameUnits*metersPerGameUnit)` as the experimental gain, but must be labeled in clearance comparisons (§7). Use the same explicit metre conversion for visual root lift; model-space pelvis/foot targets remain in asset metres before uniform model scale. Arm aims use normalized segment directions; root translation uses lengths. Do not multiply segment directions by model height twice.

The candidate model has no 180° yaw correction to apply. A replacement asset with different forward/up axes needs a fixed `Q_asset`; convert canonical-avatar aim directions back through `Q_asset.inverse` for its asset-local solver, then apply the fixed correction once in the entity hierarchy. That correction is independent of participant movement and identity. No negative scale, UV mirror, global scene reflection or anatomical joint-name swap is part of this candidate.

### 4.2 Concrete expected outcomes under the proposed co-facing candidate

Physical left/right below means **the participant's anatomical left/right while facing the iPad**, not the left/right edge of an unmirrored camera image.

| Action / condition | Canonical observation | Proposed visible outcome |
|---|---|---|
| Raise physical left arm | Named left shoulder/elbow/wrist; often on camera-image right | Robot LEFT arm raises; from behind this is the screen-left side. Right arm is not renamed or raised by the left keys. |
| Raise physical right arm | Named right joints; often on image left | Robot RIGHT arm raises on its screen-right side. |
| Move physical left | Canonical body X generally increases | Negative lane-local robot displacement, screen-left, subject to explicit cosmetic clamp. |
| Move physical right | Canonical body X generally decreases | Positive lane-local displacement, screen-right. |
| Lean anatomical left/right | Shoulder-vs-hip vector tilts on canonical plane | Corresponding co-facing left/right trunk tilt; no global model yaw. |
| Duck | Compatible human hip/ankle references indicate compression | Pelvis lowers, knees bend toward corridor (−Z), feet remain on the deck within IK reach. No duck verdict is produced. |
| Jump | Compatible independently provided human foot/floor reference or synthetic lift fixture | Positive world-Y root lift; body returns to deck on landing. Renderer does not label grounded/airborne as gameplay evidence. |
| Two people side by side | B2a mapping remains canonical image-right → P1, image-left → P2 when explicitly armed and eligible | P1 occupies existing world-left lane, P2 world-right. An **unmirrored camera preview shows these raw people on the opposite displayed sides**; labels must explain slot/lane, not silently change identity. |
| People cross | Source candidate order/position may change | Fixed PlayerIDs/lane ownership do not swap. Only a trusted association drives a slot; uncertainty hides/neutralizes it. Do not use X sorting in the renderer to resolve crossing. |

This candidate gives same-anatomical-side rear-view control with an unmirrored capture/image route. If “unmirrored avatar” instead requires avatar displacement to follow **raw image X**, the expected lateral outcomes differ and same-side limb aims need a redesigned basis. Edo/Kevin must resolve that product meaning before implementation; the document does not present both incompatible behaviors as simultaneously achieved.

### 4.3 Binding and preview compatibility gates

B2a currently arms binding explicitly and acquires P1 from canonical image-right (the left side in the existing mirrored A2 preview). Preserve that rule and all ambiguity/rebind controls. The new product image convention does not authorize modifying it. Changing initial binding to “left in an unmirrored preview” is a separate CP1/B2/lifecycle review with Edo/Jevon/Kevin. Bound identities never change merely because presentation does.

Existing Kevin-approved A2 skeleton transform remains `u=ox+(1-x)*w`, `v=oy+(1-y)*h` for that **mirrored DEBUG preview only**. Do not apply it to a new unmirrored image route. Any future overlay must match the displayed image's exact generation, epoch, frameID, geometry, dimensions, applied orientation and fitted rectangle; never pair latest pose with an older image. Hide unmatched overlays, and mirror zero times in the unmirrored route or exactly once in the existing mirrored route. Avatar-01 implements no camera overlay.

## 5. Proposed immutable avatar-pose contract

This is a field-level contract sketch, **not compiled Swift or an adopted public API**. Exact isolation syntax must be verified later under Swift 5/default MainActor/approachable concurrency with complete checking. Keep the conceptual shapes minimal; reuse existing immutable producer values where scope permits, rather than inventing new identity/calibration definitions.

### 5.1 Separate the three meanings

1. **Source-aligned raw pose:** observed normalized X/Y and confidence, anatomical keys, original source. A candidateID is frame-local and is never PlayerID.
2. **Calibrated human reference/evidence:** Edo's accepted PlayerCalibration, BodyInputContext/cutovers and optional existing exact-source BodySnapshot. These are human observations, not robot geometry. No new calibrated values are manufactured by the renderer.
3. **Avatar presentation:** rig-local aims, smoothing, root displacement, cosmetic scale and foot contacts owned by Kevin. These are not written back into any body/game contract.

### 5.2 Envelope and slot schema

```text
AvatarPoseFrame (immutable, checked Sendable values only)
  origin: synthetic(fixtureID) | camera
  source:
    generation, epoch                  original camera values; synthetic fixtures explicitly supply theirs
    frameID, capturedAt                 original sequence / host-clock seconds
    cameraGeometryRevision
    imageWidth, imageHeight
    appliedCaptureRotation, sourceMirrored=false
  bindingControlRevision               original authorized control, never stamped from “current” on completion
  presentationContextRevision          ordered context publication revision, not a new identity or game clock
  player1, player2: AvatarSlot          exactly two outcomes, no arbitrary participant list

AvatarSlot
  available:
    sourceCandidateID                  diagnostic reference into THIS source only
    joints: named normalized X/Y/confidence values; missing stays absent
    humanReference: PlayerCalibration? optional immutable accepted value, no replacement profile/baseline
  unavailable(reason)
```

The enum-like `player1/player2` fields avoid missing/extra dictionary keys; a dictionary implementation must enforce exactly the two existing PlayerIDs. The proposed joint vocabulary is the spike's 16 PresentationJoint cases. Validate finite normalized coordinates/confidence, unique valid keys, positive dimensions/revisions and finite nonnegative times. Explicitly represent weak/missing evidence; do not insert `(0,0)` or infer reliable confidence. Weak joints are retained as observed values and filtered according to a named visual policy; confidence is not an identity probability.

`available` means the authoritative association permits a **current** positive presentation for that slot. It does not mean all joints, human calibration or gameplay evidence are valid. Unbound/uncertain/lost/rebind-required cannot masquerade as available. Example unavailable reasons: unbound, identityUncertain, trackingLost, rebindRequired, sourceUnavailable, incompatibleContext. Never infer association from array order, candidateID reuse, lane position, avatar dimensions or the presence of a calibration value.

The accepted presentation context independently records exact camera context, binding revision, active/inactive state and accepted calibration dictionary/revisions/cutovers. A `humanReference` must equal the owner-accepted reference for that slot/generation/geometry. Its source frame is the earlier standing-calibration capture, **not the pose's current frame**. Baseline removal means the exact accepted key set changes; do not retain it as a cache. Honor existing strictly-after frameID **and** capturedAt cutovers when using calibrated values.

Uncalibrated source-aligned joints may drive a separately selected direction-only demo (arms/lean) with neutral root/feet. They cannot supply measured jump height, floor or body scale. Avatar-01's crouch/jump acceptance uses explicitly synthetic standing references/lift, not a fake live calibration. Do not make an optional reference into default “1.6 m human” evidence.

B1's current BodyJoint table does not include elbows/knees. No change is authorized here. Synthetic packets may exercise those optional joint keys; live integration must initially omit them and use an explicitly limited pose, or obtain a separate reviewed producer contract extension. The renderer cannot reconstruct a missing observation and label it detected.

An exact-source BodySnapshot is **not required in every avatar packet**. If a later retargeting path needs its crown/soles/jump values, join the existing immutable snapshot at the adapter using generation/frameID/capturedAt/geometry plus current binding/accepted context; reject mismatches. Do not add images to CP1, create a second CP1 consumer, or make the renderer decide airborne from raw ankles. Avatar-01 fixtures can avoid this join entirely.

### 5.3 Admission and staged presentation

The App-composed producer adapter must join one original B1 result, its source-stamped tracking result and accepted reference context. It checks source equality before extracting the associated candidate's joints. A delayed result cannot be relabeled with a newer context/control. No tracking or measurement algorithm is duplicated at this seam.

Kevin's consumer validates the entire bounded packet against the active context before mutation. Reject duplicate/older frameIDs, nonincreasing capture time, impossible future time relative to the injected clock, malformed values or context mismatch **without advancing accepted watermarks or filters**. A newer incompatible packet cannot reset acceptance. Context replacement is a separate ordered operation. Preserve the source frame/time watermark when only presentation policy, calibration or control context changes within the same source epoch; a revision bump cannot make an old frame fresh. Reset source ordering only on an explicitly installed new source generation/epoch, while rejecting every retired context.

Stage both slot targets from one packet, then publish both targets/source diagnostics together without suspension on MainActor. Missing P2 does not block valid P1; P2 receives explicit fallback. Per-rig failure must hide that rig and report an error without retargeting its data onto another slot. Application-level grouped updates are not proof of atomic physical display; visual acceptance must inspect actual rendering.

## 6. Source freshness, invalidation, release and fallback

| Event | Required presentation behavior |
|---|---|
| New valid frame | Replace latest pending as a whole; validate before touching current state; update only supported joints |
| Missing/weak individual joint | Mark unavailable to the retargeter; optionally bounded cosmetic hold then neutral limb, according to explicit policy; never raise confidence or affect gameplay |
| Uncertain/lost/rebind-required player | Immediately mark slot noncurrent and discard its pending target. Proposed fallback: visibly unavailable neutral robot with no retained active pose/root lift; no claim of tracking. Jevon still decides session recovery. |
| No new frames / age exceeds policy | Existing reviewed update hook evaluates `hostNow-capturedAt`; invalidate even without another packet. No retimed source, fabricated frame or GameClock substitution |
| Stop, background, interruption or input failure | Immediate independent context invalidation clears pending/current active poses and diagnostics, then neutral/hide. Do not wait for the frame stream to emit an empty result. |
| Generation, epoch, geometry, dimensions or orientation change | Invalidate all source-dependent filter/stance/contacts/targets; require explicitly installed compatible context. Never retain a calibration because numeric revision happens to restart at 1. |
| Binding/control reset or rebind | Invalidate both slot associations immediately. Only upstream owner can authorize/reset; full rebind obeys B2a's external new-generation requirement. Renderer never generates or restarts a camera session. |
| Calibration removal/replacement | Conservatively invalidate the current/pending combined packet on the ordered context update; clear affected reference-dependent filters and honor owner cutovers. The next pair can make the unaffected player available independently. Unchanged accepted player revisions remain unchanged. If switching global visual scale/policy affects both rigs, stage that visual reconfiguration consistently; do not change accepted human scale. |
| Renderer close / recreation | Revoke attachment token, clear numeric packets/filters, cancel owned update subscription, remove owned robots/lights, restore owned placeholder visibility; late model loads/packets cannot attach to the retired layer |

Freshness age, limb hold/fade, smoothing, gains, sway limits, IK reach and step timing are typed finite **experimental visual policy** with units and a version identifier. No production numerical defaults are approved here. Deterministic tests supply explicit values and an injected monotonic clock. Synthetic source time is separate from live host time; a `.synthetic` packet must not reach an attachment configured for camera origin. A future live attachment reads the existing Core Media host-clock basis, not wall time.

Context updates use monotonically ordered publication revisions; older events cannot reactivate current state. Use one existing source-owner/internal status tee, not an independent CP1 gameplay/status claim. The consumer has one current attachment token; delayed async asset loading must compare the original token before entity attachment. Cancellation is cleanup plus token/context rejection, not an assumption that canceled work cannot finish.

Retaining a neutral decorative robot is different from holding stale active evidence. Any optional last-good limb hold is only for a compatible, still-fresh source and must be labeled cosmetic; lifecycle/context invalidation overrides it immediately. Physical rendering of that fallback and its duration require Kevin's approval. Do not introduce automatic camera restart or rebind behavior.

The packet carries no camera buffers. Keep at most one pending and one current bounded numeric envelope, two rigs, one template and one owned light group. Each rig keeps named filter state and at most two feet; no unbounded trajectories or per-frame Tasks. Releasing an attachment must release packet/reference and model owners; framework caches/RSS are measured separately from these logical bounds.

## 7. Synthetic acceptance matrix

All cases are proposed tests, not tests run by this design task. Use Swift Testing in the existing root target, deterministic fixtures/clocks and bounded sequences. CPU numeric assertions, RealityKit import assertions, rendered observations and physical display behavior are separate evidence levels.

| ID | Fixture / assertion | Evidence gate |
|---|---|---|
| S01 | Import pinned asset; required unique joints, valid hierarchy, finite bind transforms, positive scale; reject incompatible rig without hidden default limb lengths | Hosted import test + asset gate |
| S02 | Robot forward vector is world −Z, up +Y; camera at +Z sees labeled BACK; +X right; static model correction independent of actions | Numeric basis test + actual rear-view render |
| S03 | Left-only, right-only, asymmetric arm poses; named side affects corresponding bones, other side unchanged | FK / joint assertion + labeled visual fixture |
| S04 | Canonical X changes of ±δ with fixed source/ID; check proposed co-facing sway sign and aspect correction; no negative entity scale or world flip | Exact transform tests |
| S05 | Two slots at existing lane anchors; reverse raw candidate array / reuse candidateID in another frame without changing trusted ID mapping | Fixture adaptation test, not tracker-accuracy proof |
| S06 | Labeled people cross positions; trusted identities persist, then explicit uncertain outcomes; renderer never sorts/rebinds | Slot/fallback test |
| S07 | Fixed avatar height candidate versus human-height candidate for short/tall references; uniform scale, same deck floor; no per-frame size pumping | Bounds / projected-height test + visual comparison; final size remains open |
| S08 | Rest → crouch → rest; feet on deck, knees toward corridor, pelvis lowering finite/continuous, no below-floor penetration beyond declared numeric tolerance | IK / transformed-foot assertions |
| S09 | Synthetic takeoff/landing and one-knee raise; root lift separate from foot lift; no fabricated CP1 JumpState | Numeric targets + visual fixture |
| S10 | Reach limits, zero-length or weak limb direction, extreme finite input, incompatible scale; finite output, documented clamps, no NaN/division by zero | Boundary tests |
| S11 | Optional foot planner: lean keeps feet, step moves correct foot, support contact, jump release/landing, missing ankle fallback labeled procedural | Contact/IK tests; no proof of actual physical foot contact |
| S12 | Missing/low-confidence shoulders/elbow/wrist/hips/ankles individually; do not substitute zero coordinates, confidence or another person's joints | Explicit per-joint fallback tests |
| S13 | Mismatch each generation/epoch/frameID/time/geometry/dimensions/orientation/control/origin/reference revision; duplicates and old frames | Rejection leaves watermarks, histories and visible accepted context unchanged |
| S14 | Calibration full replacement/removal/reacceptance; strictly-after frame/time cutovers; no reuse on restart | Context/reference tests; existing CP1 API unchanged |
| S15 | No-frame expiry with injected time, just-before/at/after boundary; stop/interruption/geometry reset without subsequent frame | Clear active pose immediately; old delayed packet cannot resurrect it |
| S16 | Release during delayed template load, close/reopen, repeated install/remove, stale attachment callbacks | Exactly two active rigs maximum; no duplicate lights/subscriptions; old callbacks ignored |
| S17 | Fast producer / slow presentation, partial P1/P2 availability, malformed pair | One latest pending + current, same-frame target/debug stamp; valid peer independent |
| S18 | Static low/high laser bands and labeled synthetic human/robot pose; compare visual thresholds for both height policies and jump gains | **Visual-clearance characterization only**, no CLEAR/HIT authority |
| S19 | Existing corridor/RCP and code fallback, lighting/laser glow/depth, cameras at supported framing | Actual rendered inspection for occlusion, clipping and orientation |
| S20 | Long finite pose/invalidation sequence, teardown, Debug/Release and source membership | Constant owner/state counts; app/test/regression and strict compiler gates |

Missing joints, neutral fallback and mismatched packets must have expected refusals; a test cannot pass by always showing two tracked robots. Tolerances must be named numerical test tolerances (solver precision or visual bounds), not invented physical tracking/production latency thresholds. Existing spike timing assertions are not automatically acceptance requirements.

For S18, report both canonical human height/sole values and visible model height/foot position. Equal 1.6 m avatars and height-normalized jump motion can disagree with per-human laser bands. Demonstrating that discrepancy is a useful test result, not permission to silently scale the beams or judge robot meshes. No changes to LaserCollisionJudge or GameWorldMapping are authorized.

## 8. Physical visual validation protocol

After separate implementation approval, Kevin/Theo inspect the synthetic representation on the iPad Pro 13-inch M4 (reported iPadOS 26.7.1; verify actual OS/toolchain at that time). Avatar-01 can run **without camera permission or a live session**. Use synthetic labels and do not record participant images.

1. Present rest, labeled LEFT/RIGHT-only and asymmetric arm fixtures; verify BACK faces viewer, robot front faces incoming lasers, world up and UI labels correct.
2. Run signed X displacements and lean; confirm lane-local direction, lane ownership and no scale inversion. Compare any optional unmirrored image diagram separately from old mirrored A2 preview.
3. Compare short/tall synthetic human references, fixed-size and height-preserving candidates, duck/jump/one-knee poses; inspect floor/feet, clipping and arm reach.
4. Render static high/low hazard fixtures and moving decorative lasers; inspect visible clearance, depth/occlusion and glow. Do not log a gameplay pass/fail verdict from pixels.
5. Exercise missing joints, unavailable slots, no-frame expiry, lifecycle invalidation, delayed packet and layer reopening; verify no stale motion/duplicate entities.
6. Collect finite render/update cost, allocations/RSS trend, rig count, selected policy version and device/thermal conditions where measurable. Report actual intervals and measurements, not a required 30/60 FPS or display-to-photon claim.

A later separately approved live test requires B2b association and applicable LH-22/LH-13C integration: asymmetric physical arms, participant-left/right steps, two different heights, overlap/crossing, extra entrant, loss/reentry and rotation/restart. Edo confirms original source/binding provenance; Kevin confirms perception and exact-source diagnostics; Jevon confirms recovery semantics. Until then, no claim of real-person identity preservation, calibrated floor/jump accuracy, skeleton-to-image alignment or gameplay fairness follows from Avatar-01.

## 9. Owner sign-off and unresolved decisions

No sign-offs below are inferred from earlier cutout, DEBUG-preview or spike approvals.

| Decision | Required owners | Proposed / unresolved gate |
|---|---|---|
| Selective renderer extraction | Edo Tech Lead + Kevin | Direction selected by Tech Lead; exact adaptations/host patch still reviewed |
| Asset rights, rig compatibility and art | Kevin + Theo + Edo | Provenance/distribution/attribution unresolved; block asset copy until recorded |
| Co-facing anatomical basis vs raw-image-direction control | Edo + Kevin; Theo for usability | §4 candidate requires explicit approval before transform implementation |
| Initial placement with unmirrored image | Edo + Jevon + Kevin | Preserve B2a semantics now; any binding/UX change separately proposed |
| Presentation packet / validity / freshness | Edo + Kevin | §5/§6 field rules, status tee, policy and actual compiler syntax pending |
| Height and motion normalization vs collision geometry | Jevon + Edo + Kevin | No production selection. Compare fixed-size and height-preserving synthetic candidates; no renderer-authored verdicts |
| Required optional elbows/knees and depth inference | Edo + Kevin | Current B1 omits elbows/knees; no contract extension here; planar initial candidate |
| Binding/rebind requests, recovery and calibration phases | Jevon + Edo | Upstream session authority; tracker cannot fabricate generation; renderer cannot authorize rebind |
| GameWorldMapping / production host / lighting and fallback | Kevin + affected owners | Read-only reuse for prototype; separate review for any functional change |

Jevon retains authoritative collision/evidence selection, GameClock and session recovery. Current judged geometry remains human evidence; pose filters, avatar mesh contact and foot-planning states are cosmetic. If normalized avatar-space collision is desired, it is a new shared gameplay contract, not an implementation detail of Avatar-01.

Keep CP2 handoff and CutoutPlacement intact until a separate deprecation decision. Continuous cutout segmentation may no longer be necessary for final visuals, but LH-22 crown/independent sole calibration may still need masks and same-frame association. Camera preview and Vision remain useful independently of cutout display. No code should be removed merely because the avatar candidate renders.

## 10. Smallest implementation checkpoint and acceptance gates

**Proposed Avatar-01a — synthetic rig, source contract and mapping only.** Not authorized by this design task.

Before starting: resolve asset rights, §4 movement semantics, owner-approved packet/fallback policy and exact implementation file list. B2a acceptance is not needed to draw explicit synthetic slots, but is required as appropriate before later live integration; do not use synthetic labels to claim tracker readiness.

1. Extract only the minimum §2.1 set, adapt the DTO/rig validation and synthetic fixture tests. No foot planner/live lab/camera source/replay-session adapter initially.
2. Use the existing hosted test target to instantiate a LaserScene and the layer without editing production scene code. Verify S01–S10 and S12–S18/S20 as applicable; no visual pass claim from joint readback alone.
3. For an actual RealityView demonstration, Kevin separately approves a dedicated DEBUG-only `Sedactive/Games/LaserHeist/Debug/AvatarRepresentationPreview.swift` host and a minimal route. Edo reviews any `App/RootView.swift` wiring. These would be new future files/edits, **not part of this task**. Keep default gameplay, PlayView and production presenter unchanged; if safe isolation cannot be achieved, stop for review.
4. Inspect S02/S07/S08/S09/S18/S19 on actual rendering, then §8 synthetic physical visual protocol. Record numeric, Simulator, manual physical and unsupported evidence separately.
5. Only after basic acceptance, separately scope optional Avatar-01b foot-planner extraction and device tuning. Do not automatically add live tracking, skeleton overlays, calibration or gameplay.

Required verification for implementation: app/test Simulator builds, focused deterministic suites, existing regression, Release build/resource contents, complete Swift concurrency with warnings-as-errors and applicable SIL/WMO/object checks under unchanged project conventions, resource cleanup, and actual visual review. No unchecked Sendable, unsafe isolation, suppression, project setting changes or new framework to bypass a gate.

**Readiness: design proposal ready for owner review; not implementation-ready until the asset, mapping, packet and host decisions above are resolved.** Synthetic acceptance would establish a bounded representation candidate, not full production avatar adoption, CP2 removal, B2b, LH-22 or gameplay completion.

### Design-task verification and preservation

This task creates only this Markdown file. No source, tests, assets, settings, existing architecture documents or Git integration are changed. Existing branch, signing changes and untracked Scripts must remain intact. Source inspection used pinned Git objects and current contracts; no new build, test execution or device evidence is claimed. Skills applied: swift-architecture-skill and swift-concurrency. Stop for review before implementation.
