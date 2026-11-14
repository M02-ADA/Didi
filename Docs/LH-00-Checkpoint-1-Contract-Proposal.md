# LH-00 checkpoint 1 — body-input contract proposal

**Owner:** Edo. **Reviewers:** Jevon and Kevin. **Revised:** 2 November 2026.

**Status: accepted implementation baseline, with the final calibration-replacement clarification below; Swift migration is not yet authorized.** Anonymous P1/P2 and the Play → Calibration flow are the new final product decisions. Seven CP1 Swift files, four test suites and two schema-v1 fixtures already exist, but still use the superseded identity model. This document proposes their smallest necessary migration; it neither erases that work nor claims the revised model has been implemented/tested. LH-00 is not complete, CP2 remains separate, and feature work stays paused.

**Authority:** published architecture commit `a992205ff9da467a827aa377ca09d4e45083d4f7`, branch `feat/architecture`, repository `M02-ADA/Sedactive`. [Current architecture](Architecture/Game-Oriented-Architecture.md) and [migration evidence](Architecture/Structural-Migration-Report.md) establish the paths. The Tech Lead's current product decisions supersede the old profile/selection baseline. **Edo default** means a local implementation choice, **Device tuning** an unvalidated parameter, and **Integration review** consumer wiring/behavior requiring review; structural move authorization does not imply Jevon/Kevin approved functional changes.

Current approved decisions take precedence over older wording in TEAM_ALIGNMENT, the Architecture Reference and the gameplay draft. Section 15 records mismatches; this revision changes none of those files.

## 1. Scope, ownership and completed foundation

Checkpoint 1 defines reusable, framework-independent body values, input lifecycle behavior and deterministic replay evidence. This revision aligns existing CP1 work with anonymous two-player gameplay. It implements no live capture, calibration algorithm, collision, renderer, UI/navigation or persistence. Profiles, registration and energy calculations are removed from the current MVP requirements.

```text
Camera / Vision / segmentation    Edo: acquire observations
              ↓ PoseFrame
Motion / tracking / calibration   Edo: interpret observations
              ↓ BodySnapshot
Game / evidence selection         Jevon: select evidence and judge crossings
              ↓ shared game geometry and results
RealityKit presentation           Kevin: map and display the shared game world
```

`BodyInputService` runs the live input lifecycle and data flow: start/stop capture, connect processing and publish completed output. `MotionEngine` interprets poses and maintains motion/tracking state; it does not own an AVCaptureSession or know how to turn the camera on.

Jevon owns GameClock, bounded evidence history, evidence selection, LaserCollisionJudge, encounters, health and score. Edo supplies evidence, never verdict implementations. Kevin owns RealityKit rendering and GameWorldMapping. Shared model contracts and Laser Heist Domain import no AVFoundation, Vision, RealityKit, Core Image or SwiftUI types. Foundation UUID remains appropriate for sessionGeneration and subscription tokens, not PlayerID.

**LH-23 and the structural migration are completed and preserved.** Actual paths include root-level `SedactiveTests/`, `Shared/BodyTracking/Processing/CalibrationSession.swift` and `Games/LaserHeist/Rendering/{GameWorldMapping,PlayerCutoutEntity}.swift`. App/test targets remain separate filesystem-synchronized roots. No new target, package, global Features layer, ECS scaffolding or folder refactor is needed. The seven existing CP1 implementation files and their reconciliation are listed in sections 3 and 19.

Final intended player journey (not UI implemented by CP1):

```text
PLAY → TWO-PLAYER CALIBRATION → COUNTDOWN → LASER HEIST → ROUND RESULTS → PLAY AGAIN
```

The Play action begins input/calibration; there is no family/profile-selection step. Camera permission/availability handling is technical startup, not another registration screen. Both players must bind and calibrate before Jevon permits countdown/gameplay. Play Again starts a fresh input generation and calibration; minute milestones and bonus phases do not create new input generations by themselves. Shared reports input facts; Laser Heist Session owns this flow. Existing UI files are not deleted or rewired by this document.

Image resources, ownership, orientation, cutout association and permitted display lag remain **LH-00 checkpoint 2**, agreed with Kevin. Do not create another body/cutout contract while that review is pending.

## 2. Accepted baseline and finalized technical decisions

| Classification | Decision |
|---|---|
| **Finalized — anonymous identity/entry** | PlayerID has only `.player1` and `.player2`; bind P1 to displayed-left and P2 to displayed-right during calibration. No Player profile struct, name, weightKg, SelectedPlayers, registration or persistence. A new sessionGeneration separates repeated uses of the same slot labels. |
| **Finalized — high laser** | Valid crown and both direct Vision wrists; `max(crownY, leftWristY, rightWristY) + clearanceMargin < laserLowerY`. Wrist-only is the intentional MVP simplification. |
| **Finalized — low laser** | Valid both soles and valid airborne; `jumpPhase == airborne AND min(leftSoleY, rightSoleY) - clearanceMargin > laserUpperY`. |
| **Finalized — evidence/calibration** | Missing/stale/uncertain required evidence means UNAVAILABLE. Independent standing baselines, nose-specific head offset, separate ankle offsets, no wrist calibration or baseline changes during movement. Preserve distinct heights. |
| **Finalized — delivery** | Gameplay consumes `AsyncStream<BodySnapshot>` with `.bufferingNewest(8)` initially: eight complete two-player packets, bounded and lossy. One explicitly owned active consumer per generation continuously drains into Jevon's bounded history. |
| **Finalized — latest cache** | Separate read-only latestSnapshot is the compatible published snapshot with the highest capture-sequence frameID. A late older completion cannot replace it. It is diagnostic state, not Jevon's evidence history. |
| **Finalized — coordinates/display** | Upright unmirrored image/game evidence; normalized bottom-left camera origin, X right/Y up; player-plane floor Y = 0. Every player-facing live preview/cutout is mirrored once, preserving P1/displayed-left and P2/displayed-right. |
| **Finalized — layout direction** | Shared PlayerPlaneLayout holds leftCenterX, rightCenterX and gameUnitsPerImageHeight. Calibration holds camera references, not copies of that shared scale or lane assignments. Numeric parameters need tuning. |
| **Finalized — time/lifecycle** | Capture, delivery and GameClock time are separate. One camera lifecycle from Play-triggered startup through Calibration → Countdown → Gameplay where possible. Recalibration replaces context without reopening capture; gameplay pause does not automatically stop it. |
| **Finalized — LH-00 settings** | Preserve verified project-wide Swift/concurrency/deployment settings. Use immutable Sendable body values with deliberate non-MainActor Shared-model isolation and background processing. This is LH-00's convention, not whole-team B2 approval. |
| **Edo defaults / integration review / device tuning** | Concrete subscription/status/reset choices are in section 9, isolation in section 13, tests in section 18. Review categories and numeric tuning are explicitly separated. |

Wrist-only does not guarantee fingertip/elbow clearance. No leftHandTopY, rightHandTopY or hand-length fields are introduced. Jevon implements verdicts; this document finalizes only the input/evidence requirements and technical handoff.

## 3. Expected implementation locations — producer defines each type once

Paths here are relative to `Sedactive/` and already exist. These are logical shared modules within the existing app target. They describe the intended contract after later approval, not new files implemented now.

| File | CP1 contents | Purpose |
|---|---|---|
| `Shared/Players/Player.swift` | PlayerID only; small directly related identity helpers only if needed | Two session-scoped logical slots; remove the existing profile/selection types later. |
| `Shared/BodyTracking/Models/PlayerCalibration.swift` | PlayerCalibration, ImageToPlayerPlaneMapping | Standing measurements, offsets and conversion parameters. |
| `Shared/BodyTracking/Models/BodyGeometry.swift` | EvidenceValidity, EstimatedScalar, BodyGeometry; PlayerPlaneLayout | Live measurements, shared units and one shared session scale/layout. |
| `Shared/BodyTracking/Models/BodySnapshot.swift` | TrackingStatus, JumpPhase, JumpState, PlayerBodySample, BodySnapshot | One observation with explicit samples keyed by `.player1` and `.player2`. |
| `Shared/BodyTracking/Models/BodyInputProviding.swift` | Provider interface, BodyInputConfiguration, context, delivery/status/failure/event/diagnostic values | Common live/replay lifecycle and bounded delivery behavior. |
| `Shared/BodyTracking/Models/PoseFrame.swift` | Raw pose candidate, joint and mask-measurement values | Internal Motion input, including both wrists and confidence. |
| `Shared/BodyTracking/ReplayBodyInput.swift` | Replay provider and fixture decoding/control | Deterministic synthetic input without a camera. |

Supporting types can stay beside the main type; one file per type is unnecessary. Consumers import Edo's definitions instead of making local copies. Tests remain in root-level `SedactiveTests/Shared/BodyTrackingTests/`; the LH-23 smoke test stays at the test root. Game consumers live under `Games/LaserHeist/{Domain,Session,Rendering}/`; GameClock remains Jevon-owned in `Shared/GameRuntime/`. Shared never imports Laser Heist. See section 19 for implementation status.

## 4. Anonymous PlayerID and calibration binding

### Final identity representation

```swift
// Conceptual intended representation; exact isolation/conformance verified later.
enum PlayerID: String, Codable, Hashable, Sendable {
    case player1
    case player2
}
```

`Player.swift` remains the existing file location; no replacement Player struct, SessionPlayers/roster/selection container or stored zone is needed. The participant set is always `{.player1, .player2}`. A tiny computed set/iteration helper may avoid repeated validation code; it is not runtime selection state. P1/P2 presentation labels are derived/localized from PlayerID, not stored names.

| Identity | Meaning and lifetime |
|---|---|
| `.player1` | Person initially bound at the displayed-left calibration position. |
| `.player2` | Person initially bound at the displayed-right calibration position. |
| `(sessionGeneration, playerID)` | A slot in one input session. P1 in G1 is not evidence about P1 in G2. |
| Vision candidate ID/index | Frame-local raw observation identity; never PlayerID. |

The new enum supersedes persistent UUID PlayerID, Player(id/name/weightKg), SelectedPlayers, profile lookup and order-based placement. No family role or permanent profile zone exists. UUID remains in sessionGeneration and internal subscription tokens. Different human beings may occupy the same logical slot in another session; there is no cross-session person recognition promise.

### Calibration binds the two slots

1. Jevon's session lifecycle starts a fresh input generation when Play is accepted.
2. The mirrored preview shows two intended positions. Edo's future tracker/calibrator binds the person at displayed-left to P1 and displayed-right to P2; never assign by raw Vision array order.
3. Accept a separate standing baseline for each correctly bound person, carrying that slot ID and the active generation/camera/revision metadata.
4. Jevon waits for both compatible accepted calibrations and the required current tracking/readiness facts, then permits countdown/gameplay. Input status `.running` alone is insufficient.

P1/P2 stay bound after calibration. Movement across the image, candidate reorder, temporary overlap or occlusion must not silently swap IDs. When association is ambiguous, emit uncertain/lost samples and invalid dependent evidence rather than guess. Reliable reacquisition must preserve the original binding; if that cannot be established, Jevon coordinates recovery/recalibration. Deliberate replacement/rebinding to different people starts a new generation and accepts new baselines; do not reuse old evidence under the same slot label.

The exact live association/reacquisition algorithm belongs to later PlayerTracker/calibration work and device validation, not CP1. Jevon/Kevin review flow and presentation integration, not whether profile selection returns.

### Fixed lanes and mirrored presentation

P1 maps to `PlayerPlaneLayout.leftCenterX`; P2 maps to `rightCenterX`. The mapping does not recalculate identity from current X on every frame. Preserve local movement in the assigned lane and anatomical wrist/ankle sides. Preview, cutouts and overlays mirror once with the same effective display transform; do not globally flip the world or exchange lanes. Camera-to-plane evidence stays unmirrored.

Before live binding, expected slots still exist in the contract, but a frame without established people carries explicit uncertain/lost entries; missing calibration makes mapped measurements unavailable. The contract does not invent calibrated people merely because its enum has two cases.

## 5. Observation identity and three separate times

| Metadata | Final meaning |
|---|---|
| PlayerID | Anonymous `.player1` / `.player2` slot; meaningful as a tracked participant only with sessionGeneration. |
| sessionGeneration | Jevon supplies a fresh UUID for Play/Play Again, explicit source restart, deliberate person rebinding or incompatible layout change. Calibration → Countdown → Gameplay normally shares one generation/camera session. Subscription reattachment, ordinary pause and game milestones do not create a new generation. |
| frameID | Unsigned capture-sequence number unique within a generation. Gaps allowed. Processing completion/publishing order may differ. Never renumber delayed frames to look new. |
| capturedAt | Original source capture time, expressed in a documented monotonic source-time domain. Not wall-clock Date, Vision completion, delivery time or GameClock time. |
| cameraGeometryRevision | Measurement-affecting camera orientation/crop/dimensions/configuration revision. A display mirror is not a change to canonical measurement geometry. |
| calibrationRevision | Per-player standing-baseline version; different players may have different versions. |

Observation identity is `(sessionGeneration, frameID)`; per-player observation identity additionally includes PlayerID. Reusing `.player1`/`.player2` in G2 must never make G1 packets/calibrations compatible; generation is checked before slot equality. Repeated/duplicate deliveries represent the same immutable observation. No reprocessing, recalibration or late completion may silently change its metadata/payload or present it as a fresh capture. Only newly captured compatible observations may use newly accepted calibration revisions.

**Edo time-basis default for future live adaptation:** monotonic seconds in the Core Media host-clock domain. The adapter must establish the capture timestamp's source clock/timebase and explicitly convert/synchronize into this documented domain when needed. Do not blindly treat sample presentation time, host time, ContinuousClock instants, Date or arbitrary numerical seconds as interchangeable. If the clock relationship cannot be established, report a clock-normalization failure rather than fabricate a timestamp. Shared models store numbers/value metadata, never CMTime or camera objects. The conversion implementation remains outside CP1.

Replay injects deterministic synthetic capture times and clock advancement. Its basis is synthetic source seconds, not a claimed live host-clock epoch. `deliveredAt` controls transport/replay availability and remains outside the snapshot's capture metadata. Optional diagnostic completion/delivery time never substitutes for capturedAt.

Jevon owns capture-to-GameClock anchoring/conversion, pause/resume/time scaling and crossing eligibility. Edo never advances GameClock or shifts capturedAt to compensate for a pause. Before merging, agree how Jevon reads/anchors the documented source-clock basis; the policy and conversion implementation remain his responsibility.

Recalibration does not rewrite delivered evidence. Context compatibility checks use generation, camera revision and each affected player's calibration revision. Layout is fixed within a generation; changing it requires a new generation/validated calibration context.

## 6. Shared coordinates and PlayerCalibration

### Canonical player plane

**Confirmed principle:** body points and laser bands use compatible player-plane game units. Y points up from the calibrated floor. Kevin maps that same geometry into RealityKit for bodies, lasers and debug views. Collision never reads RealityKit transforms/physics.

**Final camera convention:** upright, unmirrored full-image normalized coordinates with bottom-left origin, X right/Y up and X/Y in 0…1. The future capture adapter explicitly controls orientation/mirroring and normalizes observations, rather than assuming source buffers arrive unmirrored. Localized mask observations are converted to this convention before Motion. Preserve anatomical left/right wrists and ankles; screen reflection never relabels them.

Image-space height is a fraction of the source image; player-plane height uses shared game units. Independently calibrating two players does not mean setting both standing heights to 1. Their different heights must remain distinguishable. RealityKit does not remove the need to map camera measurements into compatible coordinates.

### PlayerCalibration — one player's standing reference

| Field | Simple explanation |
|---|---|
| `playerID` | `.player1` or `.player2`, bound to the person measured in this input session. |
| `sessionGeneration` | Input session/context where calibration was accepted. Reused P1/P2 labels never make a prior generation's calibration valid. |
| `revision` | Version of this player's accepted baseline. |
| `cameraGeometryRevision` | Camera geometry used; must match usable output. |
| `sourceFrameID` | Last accepted contributing source frame of the stable standing aggregate; not a claim that one frame alone established calibration. |
| `capturedAt` | Capture time of that source frame, on the source clock. |
| `standingCrownImageY` | Estimated standing crown Y in normalized image coordinates. |
| `standingLeftSoleImageY` | Independently estimated standing bottom of the left foot. |
| `standingRightSoleImageY` | Independently estimated standing bottom of the right foot. |
| `standingHipImageY` | Edo field definition: midpoint Y of valid left/right hip landmarks. |
| `standingBodyImageHeight` | Positive standing crown-to-sole image span: crown minus the lower standing sole. |
| `standingTorsoImageLength` | Positive shoulder-midpoint to hip-midpoint distance in aspect-corrected image-height units. Edo's field definition; the live estimator is validated under LH-22. |
| `headOffsetFromNoseShare` | Upward nose-to-crown image offset divided by standing body-image height. Explicitly nose-referenced. |
| `leftFootOffsetShare` | Downward left-ankle-to-left-sole image offset divided by standing body-image height. |
| `rightFootOffsetShare` | Separate downward right-ankle-to-right-sole offset divided by standing body-image height. |
| `mapping` | Image-to-player-plane parameters, including the calibrated floor reference below. |

No stored zone, permanent left/right role, standing wrist height or hand-length calibration. Floor lives once as `mapping.floorImageY`. Baselines are measured independently for P1 and P2, stay fixed during ducking/jumping and change only through explicit recalibration/revision.

### Mapping and session placement

**Accepted ImageToPlayerPlaneMapping fields (concrete Swift syntax verified during implementation):**

| Field | Simple explanation |
|---|---|
| `imageAspectRatio` | Upright width / height; expresses X displacement in the same scale as Y. |
| `floorImageY` | Calibrated floor reference in the source image. |
| `originImageX` | This player's standing image center; camera reference for horizontal displacement, not a gameplay slot. |

**Shared PlayerPlaneLayout:** `leftCenterX`, `rightCenterX` in game units and positive `gameUnitsPerImageHeight` (sharedScale). These three values live once in session/layout configuration. Do not store independent scale copies in each PlayerCalibration. Calibration keeps imageAspectRatio, floorImageY and originImageX plus its standing references/offsets. PlayerID directly selects the fixed lane center; there is no selection order. Kevin reviews integration with his GameWorldMapping; numeric lane spacing and scale remain tunable.

Baseline local conversion (not 3D reconstruction or physical-height measurement):

```text
sharedScale = layout.gameUnitsPerImageHeight
gameY = (imageY - floorImageY) * sharedScale
gameX = slotCenterX
      + (imageX - originImageX) * imageAspectRatio * sharedScale

slotCenterX = layout.leftCenterX  for .player1
              layout.rightCenterX for .player2
```

Calibration stores the camera reference, PlayerID fixes the logical slot and layout supplies compatible coordinates. Remove the existing selection parameter from `PlayerPlaneLayout.centerX(for:)` and `ImageToPlayerPlaneMapping.gameX(imageX:playerID:layout:)` in the later migration; exact throwing/isolation syntax is compiler-verified then. Kevin's mapping uses the resulting geometry for lasers and bodies. Perspective/size effects must preserve the visible relationship used by collision; decorative transforms cannot independently move judged geometry.

This is a calibrated local mapping for an agreed camera-distance range, not accurate depth/physical-height reconstruction. Camera placement, tolerated distance/scale drift and geometry changes need device tuning. They must reduce confidence/invalidate affected data rather than silently alter standing baselines. Do not choose separate scales to make both players the same standing game height. A new session generation or explicit rebinding requires newly validated calibration/context. Equal P1/P2 labels alone never authorize reuse of an old mapping.

**Display contract:** calibration imagery, gameplay cutouts and their landmarks/overlays must share exactly the same effective image-to-display transform, including crop/orientation, lane-local placement and one horizontal reflection. The accepted camera-to-plane output stays unmirrored. Kevin owns the display projection/transform integration; the future calibration-preview owner must use the same convention. Mirror-like movement must be checked with real players, not inferred from candidate order or a global world flip. CP1 specifies this behavior without implementing previews, rendering or CP2 image transport.

### Crown estimation baseline — device validation required

1. Require a stable standing pose, whole body visible, hands down. Raised hands must not become the head reference.
2. Use relevant head landmarks (nose, eyes, ears, neck) and a reliably associated mask to localize crown. The highest point of an entire mask is not automatically crown.
3. Calculate headOffsetFromNoseShare from crown and nose relative to standing body-image height.
4. Baseline gameplay estimate: `crownImageY = liveNoseY + headOffsetFromNoseShare * standingBodyImageHeight`, while calibrated image scale remains valid.
5. Convert the image estimate through the agreed mapping.

An unavailable nose cannot be replaced by an ear, eye or neck using the same nose offset. Alternatives require their own explicitly defined, calibrated and validated rule; otherwise crown is unavailable. Head pose and segmentation reliability can reduce validity.

### Sole estimation baseline — device validation required

1. Detect both ankles during stable standing calibration.
2. Estimate each foot bottom independently from localized segmentation near the corresponding ankle, only with reliable association.
3. Store separate left/right ankle-to-sole offsets relative to standing body-image height.
4. Gameplay: `leftSoleImageY = liveLeftAnkleY - leftFootOffsetShare * standingBodyImageHeight`; use the right ankle and right offset independently for the right foot.
5. Convert each sole through the agreed mapping.

The lowest point of a whole-person mask does not establish both soles. Missing ankles do not borrow the other foot's value. Significant camera-geometry changes, identity uncertainty or distance/scale drift must invalidate measurements or reduce confidence until usable again. Drift thresholds and validated scale compensation are future work; never silently update a standing baseline during a jump/duck.

Wrists need no standing calibration: convert each live Vision wrist Y with the same image-to-plane mapping.

## 7. BodyGeometry and validity

### EstimatedScalar and EvidenceValidity

**Accepted EstimatedScalar shape; Edo representation default:** optional finite numeric `value`, plus `validity`. Valid requires a finite value. Invalid means `value = nil` with a reason; do not substitute zero, previous data or the other limb. Although the common type is called EstimatedScalar, wrists are mapped direct landmarks; crown/soles are inferred boundaries.

**Edo validity vocabulary default:** `valid`, `lowConfidence`, `missingLandmarks`, `outOfFrame`, `stale`, `identityUncertain`, `notCalibrated`. Thresholds/additional reasons need review. Only valid is usable required evidence. Raw joint confidence remains in PoseFrame; consumers do not reinterpret raw confidence to override invalid output.

Edo may flag established source/measurement staleness. Jevon independently decides whether selected evidence is temporally eligible for a crossing; producer-valid does not guarantee it meets his window. An immutable snapshot is not rewritten as wall time passes.

### BodyGeometry fields

All six fields are EstimatedScalar in player-plane game units.

| Field | Meaning | Used for |
|---|---|---|
| `crownY` | Estimated top of head | High laser |
| `leftWristY` | Direct left wrist, converted to player plane | High laser |
| `rightWristY` | Direct right wrist, converted to player plane | High laser |
| `leftSoleY` | Estimated bottom of left foot | Low laser |
| `rightSoleY` | Estimated bottom of right foot | Low laser |
| `centerX` | Horizontal center; Edo's initial definition is mapped hip midpoint X | Kevin's placement/debug review; not a prerequisite of these Y-only rules |

All fields describe the same captured observation and accepted calibration context. Partial validity is allowed: missing wrists prevent high judgment but do not alone invalidate valid low evidence. If identity/mapping is uncertain, dependent measurements cannot remain usable under that uncertain assignment.

### Finalized evidence requirements — Jevon implements verdicts

| Laser | Required valid evidence in selected sample | CLEAR condition |
|---|---|---|
| High | Crown, both wrists; reliable identity and compatible frame/revisions/time | `max(crownY, leftWristY, rightWristY) + clearanceMargin < laserLowerY` |
| Low | Both soles and JumpState; reliable identity and compatible frame/revisions/time | `jumpPhase == airborne AND min(leftSoleY, rightSoleY) - clearanceMargin > laserUpperY` |

High does not require soles, jump or a classified squat. Low does not require crown/wrists. Check required availability first: any required missing/invalid/stale evidence means UNAVAILABLE, even if another point looks unsafe. With fully valid eligible evidence, failure of the CLEAR condition means HIT. Equality at the margin is not CLEAR. Jevon owns sample selection, margins, finalization, verdict code and collision tests; none are implemented here.

## 8. TrackingStatus, JumpState and BodySnapshot

**Edo TrackingStatus vocabulary:** `reliable`, `uncertain`, `lost`. Reliable means confident session-slot-to-person association, not guaranteed visibility of every joint. Uncertain/lost assignment cannot supply valid required evidence for that slot.

**Edo JumpPhase vocabulary:** `grounded`, `takingOff`, `airborne`, `landing`, `unknown`.

| JumpState field | Meaning |
|---|---|
| `phase` | Classification at captured observation time. Only airborne meets the low-laser phase requirement. |
| `validity` | Whether classification is usable. Valid grounded fails low clearance; unknown/invalid means unavailable required phase evidence. |

JumpState remains separate from BodyGeometry. The detector can use past observations, but its output describes this capture time and cannot borrow future evidence. The phase vocabulary is an Edo branch default for Jevon's integration review; detector phase boundaries need later device validation. The valid-airborne requirement is final. No jump-cycle IDs/events in CP1 unless an agreed consumer need requires them.

### PlayerBodySample

| Field | Meaning |
|---|---|
| `playerID` | `.player1` or `.player2`; matches its dictionary key in this generation. |
| `calibrationRevision` | Edo default: optional before calibration; nil means mapped geometry cannot yet be valid. |
| `trackingStatus` | Confidence in identity assignment. |
| `geometry` | Crown, both wrists, both soles and center X, each with validity. |
| `jumpState` | Phase/validity for this same observation. |

### BodySnapshot

| Field | Meaning |
|---|---|
| `sessionGeneration` | Source input session; excludes old-session work. |
| `frameID` | Frame identity shared by this packet's observations. |
| `capturedAt` | Capture time, never delivery time. |
| `cameraGeometryRevision` | Geometry used by frame and usable calibration. |
| `players` | Dictionary keyed by exactly `.player1` and `.player2`, including explicit uncertain/lost entries. Detection order is irrelevant. |

Shared metadata lives once on the envelope; calibration revision is per player. No names, weights, profiles, roles, selection containers or duplicate lane assignments exist in the revised model. Validate the exact fixed key set as well as key/sample equality; dictionary count alone is not the contract. Reused slot IDs across sessions always require generation compatibility.

No crown from frame A combined with a wrist/sole from frame B, no unrelated jump state and no hidden old-pose fallback when a joint disappears. A frame with no people can publish lost samples for both slots. Camera interruption must also be observable without inventing another frame.

## 9. Final conceptual BodyInputProviding contract

The following preserves observable transport behavior already largely implemented by ReplayBodyInput, while revising identity/configuration. It is the target contract, not a claim that current Swift already has the anonymous API. Section 13 defines LH-00 isolation; the implementation must verify exact accessor/closure signatures with the installed compiler.

### Configuration and context

| BodyInputConfiguration field | Meaning |
|---|---|
| sessionGeneration | Jevon-supplied input-generation UUID, echoed unchanged on data/status. |
| calibrations | Validated per-slot baselines; empty or one accepted baseline is allowed during calibration. Reject unknown slot keys, key/playerID mismatch, mismatched generation or incompatible camera metadata. Both are required for gameplay readiness, not for camera startup. |
| playerPlaneLayout | One leftCenterX, rightCenterX and gameUnitsPerImageHeight shared by both players. Fixed within the generation. |
| snapshotBufferCapacity | Configurable positive integer N; prototype default **8 completed BodySnapshots**, not eight per player. Fixed for a delivery lifecycle; change configuration through explicit restart, not a hidden buffer mutation. |
| noProgressPolicy | Configurable future-live monitoring policy: disabled by default for unvalidated production behavior, or diagnostic-only with an injected investigation threshold/arming rules. Approximately 1 second is an investigation starting point, not an approved timeout. |

**Edo default:** expose a read-only `currentContext` view of the provider's authoritative active generation, camera geometry and P1/P2 accepted calibration revisions, plus whether the context is active. It is derived from owned configuration/calibration state, not a second independently mutable copy. The view permits buffered evidence to be checked after reset. Initial camera geometry/revisions may be unavailable during startup; no dependent mapped value is then usable. Exact support-type syntax lives beside the provider contract.

### Running input is not gameplay readiness

The revised BodyInputConfiguration has exactly five conceptual fields: `sessionGeneration`, `calibrations`, `playerPlaneLayout`, `snapshotBufferCapacity`, `noProgressPolicy`. There is no selectedPlayers, participant list, participant-count option or replacement roster. Keep the configurable bounded transport/no-progress policy; do not add a Shared game-phase state machine.

`BodyInputContext` retains generation, camera revision, per-slot calibrationRevisions, cutovers and isActive, with **no selectedPlayers copy**. Its fixed slot set is implicit. `isActive` means input/evidence context is active; it does not mean the game may start. Existing `accepts(...)` remains a context-compatibility check, not a claim of valid landmarks, successful binding, calibration completeness or crossing eligibility.

| Fact | Evidence / responsible owner |
|---|---|
| Input running | BodyInputStatus.running reports the source/processing lifecycle; it may have zero bound people/calibrations. Edo reports this. |
| Both people bound | Future Motion tracking has reliable slot-to-person associations. Current samples can report trackingStatus; it is not inferred from camera status or two detections alone. Edo owns association; no live tracker is implemented in CP1. |
| Both calibrated | Accepted matching baselines exist for P1 and P2 in current generation/camera geometry. Revisions/context report acceptance. CalibrationSession's real progress/result handoff is later LH-22 integration. |
| Countdown/gameplay permitted | Jevon's Laser Heist Session gates entry on the two accepted compatible baselines, binding/tracking readiness and his session policy; running source/compatible packet alone is insufficient. Recovery/startup criteria require integration/device review. |

A bound but not-yet-calibrated sample may have reliable tracking and nil calibrationRevision, with mapped geometry and JumpState unavailable. Before binding, samples are uncertain/lost and unavailable. A completed such packet is still source progress. Partial acceptance must never silently manufacture a second baseline or begin gameplay. Jevon owns pause/recovery if readiness is later lost; do not create a competing state owner inside Shared.

### Operations and access

| Member | Final conceptual behavior / owner |
|---|---|
| start(configuration) — async, can fail | Edo establishes generation state and its prepared bounded stream before starting output. Success means source running, not calibrated/visible. Jevon owns calling it for session flow. |
| stop() — async | Explicit source shutdown: invalidate context, clear cache, finish delivery, cancel processing/capture, then publish stopped. Idempotent. Only the lifecycle owner calls it; subscription cancellation is not stop. |
| setCalibrations(values, generation) — async, can fail | Validate `values` as the complete replacement accepted calibration dictionary for the active generation, then commit it atomically without reopening capture. This is not an incremental merge: omitted slots lose their accepted baseline; an empty dictionary clears all. Return the exact committed context. Invalid requests leave the existing accepted context unchanged. Clear cache on an actual dictionary change and invalidate incompatible buffered/history evidence; only new compatible captures may use changed/reaccepted baselines. |
| snapshotStream — explicit single-consumer acquisition | Acquire `AsyncStream<BodySnapshot>` for the active generation using `.bufferingNewest(N)`. The initial N is 8. A second acquisition while claimed fails with an ownership/operation error, not a second camera or independent competing iterator. Exact Swift spelling may be a throwing acquisition method; it is not a getter that silently constructs streams. |
| latestSnapshot — read-only | Compatible published packet with the highest capture-sequence frameID. Nil before output and after incompatible context replacement/stop/fatal failure. No polling dependency for gameplay. |
| status — read-only | Current source lifecycle state, independent from snapshot transport. |
| statusUpdates — explicit observation registration | Independent current-state replay plus ordered status/context/progress/delivery notifications. Edo default is lightweight MainActor callback observation, not a lossy snapshot stream. Details below. |
| currentContext — read-only supporting view | Authoritative compatibility metadata used by the owner to reject old generation/camera/calibration data. |
| releaseSnapshotSubscription(generation) — supporting cleanup | Explicitly finish/release the current gameplay subscription on early loop exit; retain source capture if calibration or session recovery still needs it. Task cancellation also invokes token-checked cleanup. This is not stop(). |

`currentContext` and explicit subscription release are small support operations needed for correct reset/early-exit semantics. They do not add game history, clock conversion or a generic event framework to Edo's provider.

### Atomic full replacement of accepted calibrations

Every call supplies the **entire intended accepted dictionary**, not a delta. All examples below use the same active `generation`; the generation argument is required even when omitted from the abbreviated calls.

| Step | Request | Accepted key set after success | Readiness consequence |
|---|---|---|---|
| 1 | Start input with `calibrations: [:]` | `{}` | Input may run; neither slot is calibrated. |
| 2 | `setCalibrations([.player1: calibrationP1], generation: generation)` | `{.player1}` | Only P1 is accepted; countdown remains blocked. |
| 3 | `setCalibrations([.player1: calibrationP1, .player2: calibrationP2], generation: generation)` | `{.player1, .player2}` | Both are accepted; Jevon may permit countdown only with compatible baselines and required current tracking readiness. |
| 4 | `setCalibrations([.player2: calibrationP2], generation: generation)` | `{.player2}` | P1 is intentionally removed, not retained by merging. Countdown cannot begin with only P2. |
| 5 | Any invalid replacement, including a dictionary with one valid and one invalid entry | Unchanged from the last successful step | No partial acceptance or removal. |

Validate generation, every dictionary key/value identity, camera geometry, baseline values, source metadata and revision compatibility **before** committing anything. Commit the replacement, its context and cutover consequences as one serialized operation. Failure leaves the previously accepted dictionary/context intact, with no partial revision/cutover update or cache reset.

Retaining the identical P1 value in step 3 preserves its revision and existing compatible per-player evidence; merely adding P2 does not recalibrate P1. A changed retained baseline must carry an advancing revision. Omitted slots lose their accepted calibration/revision. Changed, removed or newly reaccepted baselines use the existing cutover/compatibility rules to reject incompatible buffered, in-flight and history evidence; previously delivered samples are never rewritten. Reacceptance must not revive pre-cutover evidence even if a revision value is encountered again. A byte-for-byte/equal replacement is an idempotent no-op, with no artificial revision/cutover advancement or cache reset.

`currentContext.calibrationRevisions.keys` must equal the accepted dictionary's keys exactly after each successful replacement; no omitted baseline survives in the context. Cutover metadata may retain a removal marker for rejecting older evidence, but that marker is not an accepted calibration. Context/status observation and the returned context expose the committed key set even if no snapshot arrives. The snapshot participant set remains P1/P2: removing P1's calibration does not delete P1's identity or sample; subsequent P1 mapped evidence is unavailable/notCalibrated until accepted again.

Jevon's Session gates countdown on both compatible accepted calibrations **and** required tracking readiness. An active source, a successful partial replacement, or a nonempty calibration dictionary does not meet that gate. Loss of readiness after gameplay starts is handled by Jevon's existing recovery policy, not a new Shared gameplay state machine.

### Gameplay stream, ownership and coverage

- Edo owns snapshot production, validation, the continuation and delivery diagnostics. Jevon explicitly owns **one active gameplay consumer per generation** and his own bounded evidence history.
- Jevon registers lifecycle observation before start. start creates the stream before output can publish; he then explicitly acquires it and starts a continuously draining task before enabling gameplay. The task remains active from Play-triggered startup through Calibration/Countdown/Gameplay and ordinary gameplay pauses when input remains needed; it never waits for a laser crossing to start reading. If start fails, status still reports the failure without a stream or camera frame.
- One packet contains both P1/P2 slots from the same captured frame, including unavailable/lost samples. BufferingNewest(8) limits pending packets to eight total. It drops the oldest **buffered publication**, not necessarily the lowest capture-sequence ID. It does not sort completion order.
- No rendering/debug consumer iterates this gameplay stream. Diagnostics use latestSnapshot; Kevin's image handoff is CP2. Copying AsyncStream or constructing another iterator is not a multicast subscription.
- Late completed compatible observations may still enter the stream in completion/publication order with their original frameID/capturedAt/revisions. Jevon determines their crossing eligibility and deduplicates immutable observation keys. Do not reorder or rewrite metadata to hide processing delay.
- N = 8 is a configurable prototype default, not a permanent constant or a guarantee of eight valid frames near every crossing. Throughput, invalid measurements, scheduling, overflow and Jevon's independent history/window determine actual coverage.

### Latest cache is a different access mechanism

For the current compatible generation/camera/calibration context, publish a completed packet to the cache only when its frameID is greater than the cached packet's frameID (or cache is empty). Equal-ID identical evidence does not advance it; old-generation/incompatible completion is rejected. A compatible packet with invalid joints/lost tracking may still be the newest evidence: do not retain an older apparently safe pose instead.

Example publication sequence 101, 103, 102: stream can deliver 101, 103, 102; latestSnapshot ends at 103. A delayed 102 must not replace 103. The cache is not defined by delivery time or highest-confidence pose. During a compatible consumer detachment the provider may continue updating the cache for calibration/diagnostics.

### Overflow and termination diagnostics

Inspect every continuation yield result. Enqueued means accepted/buffered or delivered to a waiting reader; dropped increments a saturating bounded-memory droppedSnapshotCount; terminated increments a saturating terminatedYieldCount. Count subscription termination separately, with a small reason category. A dropped result can describe the displaced older buffered element while the new packet was accepted: never treat it as proof the incoming packet was rejected.

Use bounded counters and small categories, not an ever-growing event log, image payloads, names, raw participant recordings or pose archives. Reset/summarize counters at an explicit generation boundary. Do not emit a status transition for every diagnostic count increment.

Overflow alone causes no HIT, CLEAR or automatic pause. When no eligible valid crossing evidence is available, the verdict remains UNAVAILABLE under Jevon's policy. Tracking loss, confirmed source interruption and processing stall are separate facts. A cancelled/closed consumer is a delivery state, not a camera failure.

### Subscription termination and explicit reattachment — Edo default

There is one active claim at a time. An acquisition returns the prepared stream and records its owner; repeated acquisition while active fails. It never silently creates another subscription. If the consumer cancels or exits, its owner releases the claim. An early break must explicitly release it rather than rely on deinitialization. onTermination performs only delivery cleanup, routed safely to the state owner; it must not stop camera capture needed by calibration/session flow.

After release, an **explicit** acquisition may create a fresh bounded stream in the same still-active generation. This is a deliberate handoff, not automatic resubscription. The previous task must have exited before the replacement starts. An internal subscription token distinguishes old/new continuations and cleanup callbacks; it is transport ownership only and never changes PlayerID, generation, frameID or capture metadata. Old-token work cannot yield into or terminate a replacement stream. Previous queued packets are not replayed into the replacement; gaps are possible and do not imply a verdict.

Normal gameplay pause should keep the consumer alive. New-generation restart is reserved for source/session restart, deliberate rebinding or incompatible layout change, not ordinary subscription reattachment. Camera lifetime belongs to start/stop and actual fatal source failure, not the subscription's cancellation handler.

### Recalibration/reset and buffered evidence — Edo default

The live stream stays attached across an accepted full-dictionary replacement; source capture remains open. The replacement compares the old and new dictionaries per slot: unchanged entries retain their revisions/cutovers, and changed or removed entries invalidate incompatible evidence. On an actual dictionary change the serialized context commit records the affected capture cutovers, clears the whole-packet latestSnapshot cache and rejects old-context in-flight completions. Do not relabel a frame captured before the cutover with the new revision. The next new compatible capture can populate the cache and stream.

AsyncStream has no clear-buffer operation. **Invalidation is explicit compatibility rejection, not a claim that finish() purges pending values.** Already queued packets may still be yielded to the existing reader. Before inserting evidence into history or selecting a crossing, Jevon checks current active generation/camera and each affected player's accepted calibration revision. His history invalidates incompatible evidence on context change; packet/sample metadata is never rewritten. An unchanged player's evidence may remain usable under its own matching revision/cutover only if that player's baseline is explicitly retained in the full replacement. A removed player's old calibrated sample is incompatible even if the other player remains accepted. The lifecycle/context observer reports the committed context even with no new snapshot. Consumer acceptance and context commits must be serialized/checked so suspension cannot append an obsolete sample after reset.

On stop/fatal failure/new generation, context becomes inactive/incompatible and cache clears before delivery finishes. finish may leave old queued packets drainable; the old consumer must reject them. Startup/continuation/termination callbacks carry generation and subscription tokens, so old work cannot publish into the replacement generation. Repeated start with identical active configuration neither resets stream/history nor creates a second subscription. Different active configuration fails explicitly. Explicit stop then start uses a new generation.

### Independent lifecycle observation — Edo default

BodyInputStatus reports **starting**, **running**, **interrupted(reason)**, **failed(failureCategory)** and **stopped**. Permission/camera/processing/clock-normalization failures use small framework-independent categories. Operation misuse, such as a second stream claim, returns an operation error without falsifying source status.

StatusUpdates is an explicit observation surface: one lifecycle-owner callback registration for CP1, replaceable only after releasing the previous registration. On registration, synchronously replay the provider's authoritative current event on its owning MainActor before returning; subsequent changes are delivered serially in increasing statusRevision order. An event carries generation (nil only before the first generation), source-basis occurredAt, statusRevision, status, current context and delivery/progress facts. It needs no camera frame to exist. The owner can then share lightweight UI state through its own normal state model without adding gameplay stream subscribers.

Callbacks do not await or perform heavy processing. They immediately record/handle the immutable event; requested asynchronous recovery runs separately. Do not reenter provider control mutation from inside callback dispatch. No `.bufferingNewest(1)` or coalesced callback task is used for critical transitions: starting → running → failed must reach the registered observer in order. There is no unbounded status queue. A detached observer receives the current authoritative state when explicitly registering again, not a promise to replay all historical transitions. Sequence numbers/generation prevent stale queued owner work from overwriting newer state.

A fatal failure publishes failed(category), invalidates evidence, finishes delivery and releases source resources. **Failed remains current until explicit stop/restart**; do not automatically replace it with stopped and hide the cause. Explicit normal stop ends in stopped; an explicit stop after a failure may then report stopped. Gameplay consumer cancellation only changes delivery facts, leaving source running if still needed. These behaviors remain distinguishable even when no BodySnapshot arrives.

### Configurable no-progress policy for future live input

Track completed source-processing progress, not whether the gameplay reader happens to consume or whether a required landmark is valid. A completed lost-tracking packet is still processing progress. Overflow does not imply a processing stall, and duplicate transport delivery does not establish new source progress.

A diagnostic-only policy may report suspectedStall after an injected interval without completed output; approximately **1 second is only an investigation seed**. It is not an approved production timeout, pause rule or automatic failed/interrupted transition. Represent suspectedStall separately from a confirmed AVFoundation interruption (for example, progress facts accompanying running status). New compatible output clears the suspicion. Never invent an AVFoundation interruption reason from elapsed time.

Arm only while completed processing is expected, after initial output/transition readiness. Disarm/reset during startup, explicit stop/interruption, known calibration/context transitions or intentional suspension of processing; rearm after the first new compatible completion. Startup failure/never-producing input needs its own explicit source-start diagnostics, not a false one-second stall. Arming/grace rules and production tolerance require device validation. CP1 tests inject a manual clock and policy events; it implements no live camera watchdog.

Jevon owns all gameplay pause/recovery, clock conversion, bounded history, crossing selection and verdict finalization. No part of this interface selects LH-09 windows or judges a laser.

API behavior cross-check: [Swift AsyncStream specification (SE-0314)](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0314-async-stream.md). Buffer/drop/finish behavior is the standard library's; ownership, context invalidation and callback status reporting above are Sedactive's explicit contract.

## 10. Shared PoseFrame — raw values before interpretation

| Field/type | Meaning |
|---|---|
| Frame metadata | Generation, frame ID, capture timestamp, camera-geometry revision. Raw input exists before calibration. |
| `imageWidth`, `imageHeight` | Upright dimensions; derive aspect ratio. |
| `candidates` | Detected people not yet bound to P1/P2. |
| Candidate `candidateID` | Frame-local identifier/index; never a logical PlayerID. |
| Candidate `joints` | Named normalized X/Y points with per-point confidence. Explicitly includes **left wrist and right wrist**, plus nose, eyes, ears, neck, shoulders, hips and ankles when observed. Missing joints stay missing. |
| Candidate `maskTopImageY`, `maskBottomImageY` | Optional associated full-image mask extents; not automatically crown/both soles. |
| Candidate `leftFootBottomImageY`, `rightFootBottomImageY` | Optional independently localized foot bottoms near corresponding ankles. |
| Candidate `maskAssociation` | Edo default: matched / ambiguous / unavailable association to this pose candidate. Ambiguous mask observations cannot refine estimates as valid. |

All are plain values. Vision objects/images/buffers stay in Shared BodyTracking Capture adapters. PlayerTracker separately binds P1/P2 during calibration and maintains that association. Reliable head-region localization may require additional numeric observations during LH-22 design rather than trusting global mask bounds. BodyMeasurementExtractor maps live wrist points directly and estimates crown/soles from calibration. A later cutout packet can reference the same frame without entering PoseFrame/BodySnapshot.

## 11. Replay schema migration and deterministic evidence

### Actual current fixtures — inspected, unchanged

`SedactiveTests/Shared/BodyTrackingTests/Fixtures/cooperative-v1.json` and `reversed-selection-v1.json` both have schemaVersion 1, a profiles array (id/name/weightKg), UUID-keyed calibrations/samples, configuration.selectedPlayers, and 14 snapshot records each. Their source generations differ; the second reverses profile selection. Both have late/out-of-order/duplicate observations: frames 11, 13, 12, 12 arrive at 11.2, 13.2, 13.3, 13.4. They contain no raw PoseFrame candidate arrays or status records; lifecycle tests construct status/geometry records in code.

The decoder currently accepts schema 1 only; it explicitly rejects version 2. Those facts require a schema migration, not just relabeling named characters in prose. No fixture, decoder, test or resource is changed by this revision.

### Proposed schema 2 — anonymous, no profile context

Keep the existing fixture envelope/record approach and manual scheduler, with these fields:

| Field | Target meaning |
|---|---|
| `schemaVersion` | 2 for the anonymous contract. |
| `configuration.sessionGeneration` | Fixed synthetic UUID; independent of player slots. |
| `configuration.calibrations` | Empty/partial for startup tests or complete synthetic baselines keyed by `player1` / `player2`; each record carries matching slot/generation/camera/revision metadata. |
| `configuration.playerPlaneLayout` | One shared left/right center pair and gameUnitsPerImageHeight. |
| `configuration.snapshotBufferCapacity` | Whole-packet N, prototype default 8. |
| `configuration.noProgressPolicy` | Disabled or explicit injected diagnostic-only policy. |
| `cameraGeometryRevision` | Initial compatible synthetic camera geometry. |
| `records` | Transport records, sorted by deliveredAt with array-order tie breaking. |
| Record `deliveredAt` | Synthetic availability time, separate from capturedAt. |
| Record `snapshot` / `status` / `cameraGeometryRevision` | Exactly one payload per record, using existing record shapes. No images or game state. |

No profiles array, Player values, names, weights, persistent player UUIDs, selectedPlayers or redundant slot roster appears in schema 2. BodySnapshot.players remains a two-entry dictionary. Player IDs encode as string values `"player1"` and `"player2"`; dictionaries must encode as JSON objects keyed by those strings. Verify the enum's dictionary Codable behavior in implementation: use the smallest checked CodingKeyRepresentable conformance or local explicit coding if required. Do not assume String raw values alone prove JSON dictionary-key encoding. Reject unknown slot strings/UUID player keys and wrong/missing snapshot slot keys. Calibration dictionaries may be partial; snapshot dictionaries always explicitly include both slots.

**Edo migration default, for approval:** introduce `cooperative-v2.json` and `two-player-recovery-v2.json` alongside the untouched v1 files as historical artifacts. Move active test loading to v2; the revised decoder accepts v2 and rejects v1 with an explicit unsupported-version failure. No runtime UUID-to-slot inference or silent v1 conversion. Any later deletion of v1 resources is a separate reviewed cleanup, not required here. Tests currently using schema 2 as the invalid-version case must change that assertion to a genuinely unsupported version. Preserve existing evidence/transport coverage even if fixture record counts change.

`cooperative-v2` carries the standing/high/low/invalidity/late-delivery evidence. `two-player-recovery-v2` replaces the obsolete reversed-family-selection purpose with explicit anonymous uncertainty/loss/recovery and generation-isolation cases. It does not pretend a BodySnapshot fixture executes PlayerTracker. Raw candidate-order permutations use in-code PoseFrame values in CP1 schema tests; actual binding/tracking behavior tests wait for the later tracker implementation. Reordering JSON dictionary keys is not a substitute for reordering raw detected people.

### Deterministic scheduling and lifecycle — preserved

ReplayBodyInput remains the common-interface synthetic producer. Replay-only `advance(to:)` controls source availability; no camera, wall-clock sleeps, GameClock, random ID generation during decoding or task-scheduling guesses. Start resets the cursor. Same fixture/config/manual advancement/read-acknowledgment schedule produces identical packets/cache/status/diagnostics. Use one gameplay reader, bounded `.bufferingNewest(N)`, greatest-compatible-frameID cache and independent ordered lifecycle observation. Holding the reader deliberately exercises overflow; advance does not drain on its behalf.

Identical observation keys have identical immutable payloads; conflicting duplicates are rejected. Capture time cannot exceed delivery time. The producer applies generation/camera/calibration compatibility and cutovers; negative fixtures can test rejection, not exemption from the contract. Already buffered packets remain drainable after reset but incompatible; Jevon rechecks context before history/selection. EOF alone does not stop/invalidate source or erase the last packet. Status and camera-revision injections can occur without snapshots. Jevon supplies encounters, GameClock and verdict assertions in his own tests.

### Anonymous identities across input generations and candidate order

G1 and G2 are readable aliases for fixed synthetic session UUIDs (for example `10000000-0000-4000-8000-000000000001` and `10000000-0000-4000-8000-000000000002`). They are not PlayerIDs.

| Input generation | Logical identity | Binding and display |
|---|---|---|
| G1 | player1 / player2 | Bind mirrored displayed-left person to P1, right to P2; maintain association through raw candidate reorder. |
| G2, Play Again | player1 / player2 again | Accept fresh bindings/baselines for this generation; old G1 evidence fails compatibility despite equal slot strings. No persistent human identity is asserted. |

In an upright unmirrored calibration image, illustrative centers P1 x=0.75 / P2 x=0.25 become displayed-left/right under reflection. Raw candidate arrays `[candidateA, candidateB]` and `[candidateB, candidateA]` describe the same two people in different list order; their order must not become a slot reassignment. Across frames, even candidate IDs are not promised persistent. The real tracker must correlate observations or emit uncertainty. CP1 can validate raw value schemas and supplied stable slot evidence, but cannot prove this unimplemented correlation algorithm.

Example only: layout centers −0.65/+0.65, shared scale 2, image aspect 1.5. For P1, imageX − originImageX = +0.02 gives canonical local displacement +0.06. A lane-local reflected display uses center −0.06 while retaining P1's left lane center. Imagery/overlays use the same transform and anatomical wrist names stay unchanged. Kevin verifies projection integration; numeric spacing is device tuning, not a new rendering implementation.

### Worked example — abbreviated input, unchanged laser semantics

Use floorImageY = 0.10 and one gameUnitsPerImageHeight = 2. P1's standing crown image Y 0.90 maps to game Y 1.60; P2's 0.625 maps to 1.05. Different heights remain distinguishable; no profile or weight lookup is involved.

G1 packet: frame 101, capturedAt 9.98, deliveredAt 10.03, compatible camera revision and per-slot calibration revision 1. These are current moving measurements, not changes to the standing baseline. All values below are valid, identities reliable.

| Slot | Crown Y | Left wrist Y | Right wrist Y | Left sole Y | Right sole Y | JumpState |
|---|---:|---:|---:|---:|---:|---|
| player1 | 0.90 | 0.82 | 0.86 | 0.00 | 0.00 | grounded, valid |
| player2 | 1.28 | 1.10 | 1.15 | 0.22 | 0.24 | airborne, valid |

If Jevon selects eligible evidence from this packet:

- High lower edge 1.10, margin 0.02: P1 maximum is 0.90; `0.90 + 0.02 < 1.10` permits CLEAR.
- Change only P1 right wrist to valid 1.12: `1.12 + 0.02 < 1.10` is false; fully valid evidence gives HIT despite crown clearance.
- Make that wrist nil/missingLandmarks: high is UNAVAILABLE, not CLEAR or automatic HIT. Soles/jump are not high prerequisites.
- Low upper edge 0.16, margin 0.02: P2 lower sole is 0.22; `0.22 - 0.02 > 0.16` plus valid airborne permits CLEAR.
- P2 right sole valid 0.17 instead gives `0.17 - 0.02 > 0.16` false: HIT for fully valid eligible evidence. A missing sole instead means UNAVAILABLE. Crown/wrists do not rescue or block low judgment.

These are explanatory examples, not producer verdicts/tests. Equality fails strict clearance; any required invalid evidence takes UNAVAILABLE first. Section 18 separates retained transport/value tests from new anonymous identity/schema tests and later live accuracy tests.

## 12. Contract relationships — one owner per responsibility

```text
PlayerID (.player1 / .player2), scoped by sessionGeneration
   │ identity: who is this currently bound participant?
   ↓
PlayerCalibration (standing refs + offsets + camera mapping + revisions)
   │ baseline: how do we interpret this person's measurements?
   ↓ future Processing consumes PoseFrame + calibration + shared layout
BodyGeometry (crown / wrists / soles / centerX, independent validity)
   │ measurement: where are the checked points in this capture?
   ↓ combined with tracking + JumpState
BodySnapshot (both slots + capture time/frame + generation/revisions)
   │ evidence: an immutable observation, not an outcome
   ↓ BodyInputProviding produces stream / cache / context / status
Laser Heist Session → Jevon's bounded history and Domain judge
   │ gameplay interpretation: eligibility, collision, health, score, progression
   ↓
Kevin's game-specific RealityKit rendering and UI read state/events
```

BodyInputProviding transports BodySnapshots; it does not change a slot into a profile or a measurement into a verdict. Calibration is not live wrist geometry, and running input is not gameplay readiness. A PlayerID is not a raw Vision track/index. Layout fixes lanes once; after binding, current horizontal movement must not rename the person. No redundant participant-selection context or Shared game-state owner is added.

## 13. Decision register and LH-00 concurrency convention

### Four classifications — do not treat every item as pending

| CP1 area | Finalized by Tech Lead | Edo-selected branch default | Device tuning | Integration review before merge |
|---|---|---|---|---|
| CP1-01 anonymous identity | Exactly P1/P2 enum slots; no profiles/selection; Play enters calibration | String raw values; fixed key-set checks; explicit v2 fixture coding; no replacement roster | Binding/reacquisition through real movement | Jevon reviews readiness/new generations; Kevin reviews displayed P1-left/P2-right |
| CP1-02 mirror policy | Upright unmirrored processing; mirrored player-facing preview/cutouts once; anatomical sides preserved | Explicit source normalization; one effective image-to-display transform for imagery/overlays | Orientation/crop/display alignment on iPad | Kevin + preview owner: lane-local mirror, no global lane swap |
| CP1-03 scale/layout | Common Y-up plane, floor 0; shared three-field PlayerPlaneLayout; preserve height differences | Camera references in calibration; scale stored once in layout; mapped hip midpoint as initial centerX | Scale, lane centers/spacing, distance range/drift | Kevin validates GameWorldMapping/projection; Jevon validates beam compatibility |
| CP1-04 source time | Capture/delivery/game time separate; identifiers unchanged | Live adapter target is host-monotonic seconds; synthetic injected replay basis; never assume raw clock interchangeability | Timestamp latency/normalization accuracy | Jevon agrees source-clock anchor/read integration and owns GameClock conversion |
| CP1-05 geometry/validity | Accepted crown/wrists/soles model; missing required data is UNAVAILABLE | Finite optional scalar plus validity reason; invalid value nil; reject incompatible metadata | Landmark confidence, out-of-frame/scale tolerances | Jevon checks high three-point/low phase+two-point eligibility; Kevin checks debug interpretation |
| CP1-06 jump | Low requires valid airborne; JumpState separate | grounded/takingOff/airborne/landing/unknown vocabulary; no cycle events initially | Phase thresholds/hysteresis when detector is implemented | Jevon verifies interpretation; Kevin reviews cues |
| CP1-07 calibration | Accepted standing/head/independent-foot fields, no wrist calibration/baseline drift | Mapping owns camera floor/center/aspect only; sourceFrameID is last aggregate contributor | Head/sole estimation and stability criteria | Jevon reviews calibration flow/revision invalidation; Kevin reviews size/placement |
| CP1-08 lifecycle | Camera may remain across Play-triggered calibration/countdown/gameplay; explicit start/stop/calibration replacement | Atomic context commit, old-buffer compatibility rejection, explicit subscription release/reattachment | Live startup/recovery tolerances | Jevon keeps one continuous history-draining owner, handles context invalidation and pause |
| CP1-09 delivery/cache/status | AsyncStream bufferingNewest(8), bounded completed packets; max-capture-ID cache; status independent | N configurable; one active explicit claim, token-guarded reattachment; ordered callback status observation; saturating counters | Capacity N, scheduling/throughput, diagnostic stall threshold/arming | Jevon confirms drain task/reattachment/history behavior and status ownership; Kevin uses cache/CP2 rather than gameplay stream |
| CP1-10 raw PoseFrame | Both wrists and confidence; anatomical joint identity | Numeric mask observations only; candidate IDs never logical slot IDs | Mask matching/localization reliability | Kevin reviews later cutout association in CP2; no CP2 transport here |
| CP1-11 replay/tests | Deterministic injected capture/delivery times and stable slot identity within each generation | Versioned synthetic fixtures, manual advance and controlled consumer readiness | No physical accuracy claimed by fixtures | Owners agree cross-component cases; Jevon owns verdict tests |
| CP1-12 concurrency | Preserve existing project settings for LH-00; immutable Sendable values; no heavy MainActor processing/unsafe suppressions | MainActor control/cache/status facade; deliberate nonisolated Shared model values and background ownership | Performance measured later | Consumer-facing signatures reviewed by Jevon/Kevin; no claim of whole-team B2 approval |

### Existing app/test settings — preserved, no new build claimed

Historical settings inspection used Xcode **26.6 (17F113)** / Apple Swift **6.3.3**. Current repository inspection finds the same explicit project settings and unchanged project/scheme at the published architecture commit. This documentation task does not rerun resolved settings, compilation or Simulator tests. Compiler version is distinct from language mode; exact enum isolation/Codable conformance must be verified during the later implementation.

| Setting | Sedactive Debug / Release | SedactiveTests Debug / Release |
|---|---|---|
| SWIFT_VERSION | 5.0 / 5.0 | 5.0 / 5.0 |
| SWIFT_DEFAULT_ACTOR_ISOLATION | MainActor / MainActor | MainActor / MainActor |
| SWIFT_APPROACHABLE_CONCURRENCY | YES / YES | YES / YES |
| IPHONEOS_DEPLOYMENT_TARGET | 26.5 / 26.5 | 26.5 / 26.5 |
| SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY | YES / YES | YES / YES |
| SWIFT_STRICT_CONCURRENCY | Not explicitly set/resolved | Not explicitly set/resolved |
| ENABLE_TESTABILITY | YES / NO | YES / NO |

Not explicitly set does not mean concurrency checking is disabled. No setting is changed by this revision. Historical verification used explicit DEVELOPER_DIR and temporary DerivedData because the shell selected Command Line Tools and initial default-cache writes were unavailable; those are earlier inspection facts, not new commands executed for this revision.

Historical settings-only command (previously run with Debug and Release; not rerun in this documentation task and not a build/test execution):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -configuration Debug -derivedDataPath /private/tmp/lh00-settings-inspection \
  -showBuildSettings -json build-for-testing
```

### Intended isolation — local LH-00 convention

- Shared Models/identity structs/enums and supporting configuration/context/status packets are immutable Swift values with checked Sendable conformance where they cross execution boundaries. They must be usable outside MainActor despite the project's default. Use explicit nonisolated nominal declarations where supported by this toolchain; verify generated isolation/conformances in the real app/test builds during implementation. Do not assume Sendable alone solves every inferred-isolation issue.
- The provider control surface, currentContext, latestSnapshot, status and callback registration are MainActor-facing. Only lightweight validation/commit/publication/observation runs there. Ownership of these values is single-source, not duplicated inside independent actors.
- Future Camera/Vision/segmentation/Motion heavy processing runs on explicitly owned background execution. An async method alone is not proof of leaving MainActor. Use the smallest supported explicit off-main mechanism after compiler verification; do not create an actor per file or introduce a framework merely for this contract.
- Completed immutable values cross to the facade. Context checks/cache comparison/yield are serialized. onTermination may arrive from another executor and must schedule token-checked cleanup without blocking or unsafe access. Consumers own their iterator/task; no concurrent next() calls or copied competing iterators.
- No unchecked Sendable, unsafe nonisolation, blind detached tasks or project-wide migration to silence diagnostics. If safe nominal isolation needs adjustment, handle it locally and verify it, rather than changing language/deployment settings.
- Concrete signatures/annotations and cross-boundary conformance must compile cleanly during authorized implementation. No claim is made that this document proves compilation or that the whole team's broader B2 migration/convention decision is approved.

This permits isolated CP1 implementation under existing settings. Jevon/Kevin review the public surface before merge; a future broader B2 decision does not block drafting/testing these local values and replay under the authorized convention.

## 14. Remaining tunable parameters and device risks

| Parameter | Initial/default status | What must be measured/decided |
|---|---|---|
| Snapshot capacity N | Configurable prototype **8 whole BodySnapshots** | Throughput, consumer scheduling, overflow/coverage; not eight guaranteed valid crossing frames. Changing configuration is explicit. |
| No-progress threshold | Approximately **1 second**, diagnostic investigation seed only | Device-specific completed-output gaps; production timeout is not approved. Policy initially disabled for unvalidated production behavior. |
| Stall arming/grace | Arm after expected processing/first compatible output; suppress startup/known transitions | Startup/calibration grace, deliberate processing suspension and recovery; no fixed production values selected. |
| Shared game scale | One positive gameUnitsPerImageHeight in PlayerPlaneLayout | Shared visual sizes, intended camera distance and valid movement range; not real-world meters. |
| Lane placement | leftCenterX/rightCenterX, no production numbers selected | Lane spacing, local motion range and projection alignment without swapping displayed identities. |
| Geometry/scale tolerances | No approved numeric thresholds | Camera movement/orientation/crop changes, body-distance drift, recalibration requirement. |
| Measurement confidence | No approved numeric thresholds | Crown/head association, wrists/ankles, independent feet, head pose, partial occlusion. |
| Motion phases | Five-phase vocabulary as branch default | Airborne boundaries/hysteresis and robustness; JumpDetector implementation is outside CP1. |
| Jevon-owned crossing policy | No timing windows/margins selected here | Capture-to-game anchoring, evidence window/history capacity, delay, clearance margins and recovery; review/test under LH-09/LH-10. |
| Display alignment/latency | Mirrored once; P1/P2 lanes fixed | Crop/orientation/overlay agreement and device lag. Cutout image transport and permitted lag remain CP2. |

Physical iPad validation is still required for hands-down crown calibration, independent foot localization/offsets, wrist-only fingertip/elbow limitations, airborne accuracy, identity through overlap, distance drift and mirrored preview/gameplay alignment. Replay cannot prove these. Lost tracking can coexist with source progress; overflow, processing stall and confirmed AVFoundation interruption must remain distinct.

These are tuning/validation risks, not open alternatives to accepted identity or high/low evidence requirements, and they do not require a live pipeline before CP1 values/replay can be implemented.

## 15. Mismatch register — completed structure versus pending contract migration

Only this proposal changes now. Actual code remains the published old-identity implementation until separate approval. Do not reopen completed file moves or silently edit the other documents below.

| Source | Actual status / mismatch | Smallest future action |
|---|---|---|
| Published lean hierarchy / migration report | **Resolved:** all source/test moves complete at architecture commit a992205; GameWorldMapping/PlayerCutoutEntity names and root test target intact. | Use current paths; no LH-23 redo or pending owner-move gate. |
| Shared Player/BodyTracking implementation | UUID PlayerID, Player, SelectedPlayers and selection-dependent configuration/mapping/replay remain implemented. **Inconsistent with anonymous contract.** | Migrate existing types/validators/call sites and tests together within Edo's scope after approval; do not reimplement transport. |
| Current v1 fixtures/tests | Named profiles, UUID keys, reversed family selection; tests were executed only for that model. | Explicit schema 2, anonymous fixtures/builders, new generation/key/readiness tests. Preserve transport assertions and historical v1 files. |
| TEAM_ALIGNMENT §A and current architecture paths | **Resolved:** ownership references now use Games/Shared; the move authorization did not transfer functional ownership. | No path migration needed. |
| TEAM_ALIGNMENT §B/§C | Its CP1 link currently calls the older baseline approved; summary lacks wrists, still has historical mirror/TBD details. This newly revised identity proposal is **pending review**, not already implemented/approved wholesale. | After approval, Edo proposes a scoped wording update; reflect anonymous slots, preserved evidence/mirror/transport rules. Do not treat the existing link as authorization to implement this draft. |
| Current Game-Oriented Architecture / older Architecture Reference | Current paths are correct, but shared profile/ordered-selection descriptions still match old code; historical Crown-only notes are explicitly superseded. | After approval update active identity/readiness descriptions only. Keep ownership and finalized high Crown+both wrists / low both soles+airborne unchanged. Preserve historical records. |
| Gameplay backlog LH-00/shared summaries | Profile/role/zone/selection assumptions, old paths and abbreviated evidence/delivery interface remain historical task text. | Separate scoped backlog alignment later; no full rewrite or feature-status change here. |
| Gameplay LH-01/LH-09/LH-10 | Older Crown-only high clearance contradicts finalized Crown+both wrists. | Jevon reconciles before collision implementation approval. This document supplies evidence, not verdict code. |
| Gameplay LH-22 / role-dependent rules | Old standing-zone/profile assumptions and broad mask-edge language. Parent/child audience wording is not a model role. | Preserve independent head/feet calibration; do not infer role from height, slot or identity. Jevon flags any role-specific gameplay conflict separately. |
| Input extensions for vault/diamonds | Exact Dual-Key/collection gestures not specified enough for new Shared fields. | Jevon defines interactions; Edo/Kevin review evidence/display needs separately (section 20). |
| B2 / CP2 | Broader concurrency/device policy and cutout transport reviews remain separate. | Keep project settings; CP2 image format/ownership/sync/lag stay pending. |

## 16. Revision changelog — 2 November 2026

1. Aligned all active paths with published Games/Shared architecture; source/test moves and LH-23 are completed facts.
2. Replaced persistent family identity with final String-backed P1/P2 PlayerID; removed Player profiles, name/weight, SelectedPlayers, profile lookup and registration requirements.
3. Made calibration the entry point for binding: P1 displayed-left, P2 displayed-right, stable after detection reorder/overlap; new generation protects repeated slot labels across sessions.
4. Removed selectedPlayers from proposed configuration/context and selection arguments from mapping; no replacement participant container. Added explicit running/bound/calibrated/gameplay-readiness distinctions.
5. Proposed schema 2 and anonymous fixture/test migration from inspected v1 files; retained deterministic delivery, invalid evidence and historical verification facts.
6. Preserved calibration fields, Crown+both Wrists / both Soles+Airborne rules, independent validity, shared scale, mirroring, timing, stream/cache/status/reset/cancellation semantics and settings.
7. Added actual code/test reconciliation, implementation impact and bounded forward-compatibility analysis for vault/Diamond Time. No code or other document changes.
8. Final Tech Lead clarification: setCalibrations is atomic full replacement, with explicit omission/removal, exact context keys, unchanged revisions, affected evidence invalidation and deterministic readiness tests.

## 17. Readiness and approval gate

The Tech Lead has accepted the anonymous CP1 proposal as the implementation baseline. Fixed enum slots, no profile/selection container, generation scoping, mapping/readiness, atomic full-dictionary calibration replacement, provider configuration and schema/test changes are specified. **Separate authorization to begin Swift migration is still required. No genuine contract ambiguity remains that blocks isolated CP1 migration.** Already implemented transport/value behavior should be reused; sections 18–19 describe migration rather than a from-scratch foundation.

Final product decisions do not need reopening: no family profiles, Play → two-player calibration, P1/P2 placement, preserved laser evidence and canonical coordinates/delivery. Device parameters (section 14) and live algorithms are not prerequisites for synthetic CP1 migration. Exact Swift isolation/enum-key coding and API signatures must compile in the real targets later; this document proves no new compilation.

Before cross-owner wiring/merge:

- [ ] Edo obtains separate implementation approval for anonymous identity, dependent helpers/config/context, schema and tests.
- [ ] Jevon reviews generation ownership, calibration-readiness/start gate, continuous consumer/history/context rejection and recovery; no new Shared game phase machine. Calibration progress/result wiring remains later work.
- [ ] Kevin reviews initial mirrored P1-left/P2-right binding, stable assignment under motion, centerX/local mirroring and shared scale. No rendering or CP2 changes are authorized here.
- [ ] Owners acknowledge breaking identity/Codable/selectedPlayers changes and coordinate consumer call-site migration without duplicate types or hidden UUID fallbacks.
- [ ] After migration run actual app build, test build and complete existing/new Simulator suite, verify resource membership and no unexpected warning/settings changes. Do not silently discard old behavioral coverage to preserve a count.
- [ ] Jevon reconciles high-evidence backlog wording and specifies any vault/diamond interaction separately before requesting new input fields.
- [ ] Integration reviews and physical-iPad validation are reported independently of unit tests. LH-00 overall also requires CP2; neither existing nor future passing CP1 tests alone closes LH-00.

Stop at proposal review now: no Swift/test/fixture/settings edits, UI changes, other-owner code changes, commits, pushes or merges.

## 18. Planned implementation delta and deterministic verification

All paths below are repository-relative and already exist, except explicitly proposed v2 resources. They are not moved by this proposal.

| Existing file | Later authorized CP1 delta |
|---|---|
| `Sedactive/Shared/Players/Player.swift` | Replace UUID wrapper with P1/P2 enum; remove Player and SelectedPlayers; verify checked Sendable/nonisolation and JSON dictionary keys. |
| `Sedactive/Shared/BodyTracking/Models/PlayerCalibration.swift` | Preserve baseline fields/validation; update playerID semantics, remove selection argument from mapping helper. |
| `Sedactive/Shared/BodyTracking/Models/BodyGeometry.swift` | Preserve six measurements/validity; fixed `.player1`→left / `.player2`→right helper without selection argument. |
| `Sedactive/Shared/BodyTracking/Models/BodySnapshot.swift` | Preserve envelope/sample fields; exact fixed slot-key validation and revised comments; no game-state additions. |
| `Sedactive/Shared/BodyTracking/Models/BodyInputProviding.swift` | Remove selectedPlayers from config/context, initializers, replacements and acceptance checks; implicit two-slot set, partial pre-game baselines and unchanged transport/status API behavior. |
| `Sedactive/Shared/BodyTracking/Models/PoseFrame.swift` | Already compatible raw schema; no new measurement or algorithm. Only terminology changes if necessary. |
| `Sedactive/Shared/BodyTracking/ReplayBodyInput.swift` | Remove profiles and selection dependencies, iterate fixed slots, schema-2 validation; retain existing stream/cache/status/cutover/manual scheduler. |
| `SedactiveTests/Shared/BodyTrackingTests/BodyInputContractTests.swift` | Migrate LH00TestData builders, replace profile/reversed-selection assertions with slot/generation/mapping/schema invariants. |
| `SedactiveTests/Shared/BodyTrackingTests/BodyInputDeliveryTests.swift` | Adapt helpers/expected keys to fixed slots; retain every delivery/cache/cancellation assertion. |
| `SedactiveTests/Shared/BodyTrackingTests/BodyInputLifecycleTests.swift` | Fixed-slot helpers, new-generation reused-slot checks and empty/partial calibration-start checks; keep cutover/failure/status tests. |
| `SedactiveTests/Shared/BodyTrackingTests/ReplayBodyInputTests.swift` | Decode v2, schema rejection/absence of old fields, new anonymous recovery scenario; preserve evidence/determinism cases. |
| `SedactiveTests/Shared/BodyTrackingTests/Fixtures/cooperative-v1.json` and `reversed-selection-v1.json` | Preserve now; later retain as historical v1 resources, not active v2 input. No silent decoder conversion. |
| Proposed `SedactiveTests/Shared/BodyTrackingTests/Fixtures/cooperative-v2.json` and `two-player-recovery-v2.json` | New anonymous schema-2 synthetic evidence after approval; bundled test resources, no private imagery. |

No live implementation in BodyInputService, Capture adapters, CalibrationSession, MotionEngine, PlayerTracker, BodyMeasurementExtractor or JumpDetector. No Jevon Domain/Session or Kevin Rendering/Play edits within Edo's CP1 migration. No App wiring or test-target restructuring is needed for contract/replay validation. Consumers/UI integrate separately through owners.

### Retain existing behavior tests, migrating data/builders only

| Area | Deterministic test requirement |
|---|---|
| Buffer/capacity | Hold reader, publish ten compatible packets at N=8: queued 3…10, exactly two drops. N=2 retains its bounded behavior; reject nonpositive N. Each packet contains both fixed slots. |
| Capture versus publication | Publish 101,103,102,102 with original capture times. Stream preserves publication order, latest stays 103. Full queue displaces oldest buffered publication, not necessarily lowest capture frameID. |
| Duplicates | Identical key/payload stays one source observation; equal IDs do not advance cache/progress. Conflicting payload for the same generation/frame is rejected. Jevon deduplicates gameplay history. |
| Consumer ownership | One active claim; second claim errors. Read acknowledgments prove continuous draining without sleeps. Release/reattach explicitly; source remains running. |
| Cancellation/token race | Cancel pending next or release after early break; claim eventually released without camera stop. Old termination callback cannot close replacement. Controlled terminated yield records bounded diagnostics. |
| Start/stop | Identical active start idempotent; incompatible active config rejected. Stop invalidates context/cache and finishes delivery. New generation required for restart; generation reuse rejected within provider lifetime. |
| Recalibration / full replacement | Buffered rev1 stays immutable/drainable but incompatible after a changed/removed baseline. Retain an identical other-player entry explicitly to preserve its compatible evidence. Pre-cutover completions are rejected; new captures may use accepted revisions. Invalid mixed replacements leave dictionary/context/cutovers/cache unchanged. Equal replacements are no-ops. |
| Geometry/status | Camera revision clears incompatible baselines/cache. Status without frames preserves ordered current replay, failure reason/timestamp and nonreentrant control; failed remains until explicit recovery/stop. |
| Progress | Inject diagnostic time; startup/context changes suppress false stalls. Lost-person output and unique late completions are progress; duplicates/overflow are distinct. No automatic verdict/pause. |
| Measurement/scale | Valid finite scalar versus invalid nil; separate crown/wrists/soles, jump validity, independent foot offsets and two different heights under one shared scale. No laser verdict code. |
| Replay | Same manual advancement/read schedule gives identical packets/cache/counters/status, including overflow/reset. No wall-clock sleeps, camera or GameClock. Verify fixture bundle loading/round-trip. |

### Rewrite or add anonymous contract cases

| Case | Required assertion / limit |
|---|---|
| Identity encoding | Only player1/player2 raw values; unknown/old UUID player strings rejected. PlayerID Codable dictionary round-trip uses object keys. No profile model, names/weights, selection or roster payload. |
| Fixed set | Snapshot has exactly P1/P2 and matching sample IDs; missing slot invalid. Frame with no reliable people explicitly contains both unavailable samples. Calibration dictionaries may be empty/partial. |
| Full replacement sequence / exact keys | Start empty → replace with P1 only → replace with P1+P2 → replace with P2 only → optionally replace with empty. Assert accepted dictionary and `currentContext.calibrationRevisions` key sets at every step: `{}`, `{P1}`, `{P1,P2}`, `{P2}`, `{}`. No implicit merge; the identical retained P1/P2 revisions do not advance. Snapshot participants still include both slots, with removed/unaccepted calibration yielding unavailable mapped evidence. |
| Replacement atomicity / evidence | From an accepted pair, submit a dictionary containing one valid change and one invalid baseline/generation/camera/key or revision: no partial commit, removal, context/cutover change or cache reset. Change P1 while explicitly retaining unchanged P2: only P1 history becomes incompatible. Omit P1: old P1 calibrated evidence is rejected; P2 remains compatible. Reaccepting P1 cannot resurrect pre-cutover samples. |
| Countdown readiness | Empty/partial accepted keys never permit countdown. Both compatible keys are necessary but tracking readiness is also required; input `.running` or a compatible packet alone is insufficient. CP1 tests expose exact accepted facts; Jevon's later Session integration tests enforce countdown gating without adding a Shared gameplay-ready flag. |
| Lane/mirror | P1 always uses left center and P2 right, with one shared scale. Asymmetric synthetic camera origins/landmarks demonstrate mirrored display intent without renaming anatomical sides. Real rendered transform is Kevin/device integration. |
| Reused slots across generations | G1 and G2 both use player1/player2, even with equal frame IDs. G1 snapshots/calibrations/callbacks fail G2 compatibility. No profile continuity or slot-only cache keys. |
| Candidate-order schema | Construct raw PoseFrames with reversed candidate arrays; retain coordinates/confidence/frame metadata and keep candidate IDs distinct from slots. Supplied anonymous snapshots keep P1/P2 across uncertainty/recovery. This tests data contracts, not an unimplemented tracker. |
| True tracking/binding | Later PlayerTracker tests must verify bind/reorder/crossing/occlusion/reacquisition with stable people or explicit uncertainty. Do not claim this accuracy passed from snapshot replay. |
| Schema/fixture migration | Decode/round-trip v2, reject v1/unsupported versions/UUID keys/conflicting duplicates. Replace reversed-family-selection assertions with anonymous recovery/generation cases. Preserve Crown+wrists, soles+airborne, missing/stale evidence, ordering and resource coverage. |

Use established Swift Testing, injected synthetic time, explicit producer/consumer readiness and read barriers. The historical baseline is not a target to meet by skipping cases: rerun all retained assertions plus new migration cases, report actual registered/execution counts and explain replacements/additions.

## 19. Actual implementation reconciliation and impact report

Inspected at `a992205ff9da467a827aa377ca09d4e45083d4f7` on feat/architecture, 2 November 2026. **No Swift, tests or fixtures changed.** “Compatible” below means design/schema compatibility from reading, not a new test execution or proof of physical accuracy.

| Item (current path in section 18) | Classification / what exists | Future source change and affected tests | Compatibility risk |
|---|---|---|---|
| Player.swift | **Implemented but inconsistent with revised contract:** UUID wrapper + Player(id/name/weightKg) + SelectedPlayers. | **Yes.** P1/P2 enum only; contract/builders/fixtures and every selection-dependent consumer must migrate. | Breaking identity/Codable/API change; UUID-keyed serialized data is not v2. No dual-profile fallback. |
| PlayerCalibration.swift | **Implemented, needs anonymous revision:** full standing schema, numeric validation, selection-taking gameX helper. Baseline fields still compatible. | **Yes**, helper/semantics only; scale/mapping/calibration tests adapt. | Wrong slot mapping or old-generation baselines reused if a mechanical rename misses context checks. |
| BodyGeometry.swift | **Implemented, partly compatible:** six EstimatedScalars/validity validator and shared layout already exist; centerX(for:selection:) depends on old selection. | **Yes**, fixed-slot helper only. Scalar/height tests remain; lane tests change. | Independent validity/scale must not regress during helper change. |
| BodySnapshot.swift | **Implemented, needs fixed-slot alignment:** same envelope/sample/JumpState; current validator checks count=2 and key/sample equality for arbitrary UUIDs. | **Yes**, exact fixed key validation/comments; contract/replay/lifecycle tests adapt. | Same slot string in a different generation must not validate old evidence. Preserve per-player revision and invalid tracking rules. |
| BodyInputProviding.swift | **Implemented, needs anonymous revision:** complete control API, config/context/status/diagnostics; selectedPlayers stored in config/context/acceptance. | **Yes**, remove selection members and iterate/validate implicit P1/P2. All four suites/builders affected. | Broad call-site compile break; context compatibility must remain distinct from binding, calibration and gameplay readiness. |
| PoseFrame.swift | **Already implemented and still compatible:** raw joint coordinates/confidence, both wrists/ankles, local candidates, mask numeric observations and validation. | **No functional change expected.** Retain raw-pose tests; add data-order permutations as needed. | Do not mistake frame-local candidates for stable PlayerID; no hidden live binding algorithm exists. |
| ReplayBodyInput.swift | **Already implemented, needs anonymous revision:** real bounded stream/cache/lifecycle/status/cutover/manual-time code; schema 1 profiles/selection dependencies. | **Yes**, fixture envelope/config/slot loops and v2 decode; preserve delivery/state implementation. All suites exercise it. | Silent v1 acceptance or partial migration could drop/reset coverage. Preserve buffered incompatibility, duplicate and token behavior. |
| BodyInputContractTests | **Implemented, old identity tests inconsistent:** actual profile/reversed selection, weight validation, selection-derived lanes plus compatible scalar/pose/config tests; LH00TestData builds v1. | Rewrite obsolete identity/lane cases/builders, retain compatible validity/geometry/raw-pose coverage. | Removing a profile assertion is not permission to drop negative identity/schema tests; replace meaningfully. |
| BodyInputDeliveryTests | **Implemented, behavior still compatible:** seven registered tests cover overflow/cache/order/single reader/cancellation/reattach/drain; uses v1 helpers and selected IDs. | Migrate helper/config/key expectations; retain behavioral assertions. | Scheduling-sensitive “fixes” or weakened counts would mask transport regressions. |
| BodyInputLifecycleTests | **Implemented, behavior still compatible:** ten tests cover atomic cutover, one-player recalibration, start/restart, independent status, geometry and stall policy; uses selection/v1 data. | Update to fixed slot fixtures; add empty/partial calibration and same-slot/different-generation cases. | Slot reuse must not bypass generation/camera/revision checks or start gameplay early. |
| ReplayBodyInputTests | **Implemented, needs schema migration:** six tests decode two v1 files/14 records, deterministic replay, evidence validity, overflow and negative schema/time cases. | Target v2; change current “schema 2 is invalid” assertion; retain evidence/transport tests and absence-of-profile payload checks. | Record count/version assertions must follow real v2 resources; no fabricated pass counts. |
| cooperative-v1.json | **Implemented synthetic v1, inconsistent identity schema:** profiles, UUID-keyed fields, 14 records with high/low/invalidity and late/duplicate cases. | No edit now. Later add anonymous cooperative-v2, preserving old content/history. | Keep complete independent calibration and invalid-joint scenarios while removing profile context. |
| reversed-selection-v1.json | **Implemented synthetic v1, obsolete selection purpose:** same named profile identities reversed in another generation; 14 records. | No edit now. Later add two-player-recovery-v2; replace profile-order assertion with meaningful anonymous recovery/generation cases. | It contains no raw candidates; relabeling it cannot prove tracker order invariance. |
| Processing/CalibrationSession, MotionEngine, PlayerTracker, BodyMeasurementExtractor, JumpDetector; Capture adapters; BodyInputService | **Not yet implemented / outside CP1:** inspected files are import-only skeletons. | No algorithm work in the migration. Future tasks implement with separate approval. | Present filenames are not working live input or calibration. |
| Laser Heist Session/Domain and RealityKit UI/Rendering | **Outside CP1; relevant files currently starter views/skeletons.** | Jevon/Kevin own later integration, game readiness, collision, vault/diamond state and rendering. | No new contract means those implementations already exist or were approved. |

### Verification facts versus pending work

- Historical publication verification on **1 November 2026**: app/test builds and Simulator tests passed, **30 registered tests / 36 executions / 0 failed / 0 skipped**, including the root smoke test. Four BodyTracking suites account for 29 registered tests; the smoke test adds one. Those runs exercised UUID/profile schema 1, not anonymous schema 2.
- Current inspection confirms seven implementation files and four implemented suites still exist at published lean paths. BodyTracking Motion test skeletons are not extra passing algorithm tests. No build/Simulator run was performed for this Markdown revision.
- The proposed enum, removed fields, schema 2 resources, new tests and consumer integrations are **not implemented/tested**. Existing test results do not approve or validate those changes, and do not mark LH-00 complete.
- Live camera/calibration/tracker accuracy, mirrored cutout alignment and physical-iPad validation remain unperformed by CP1 replay. CP2 image transport/ownership/synchronization/lag remains separate.

## 20. Game-first forward compatibility — no speculative fields

Working design context supplied by the Tech Lead: five-minute main round, increasing laser difficulty, cooperative Dual-Key Vault at each one-minute milestone with a five-second opening opportunity, a final Diamond Time bonus currently represented as 5:00–5:10, team diamonds and results. These are game/session requirements to consider, not newly finalized detailed mechanics in CP1.

| Question | Current evidence / boundary |
|---|---|
| Can existing evidence help a Dual-Key checkpoint? | Both players' wrist Y and centerX may support vertically described reach/posture/location conditions; paired snapshots provide same-frame slot IDs/times and validity for coordinated evaluation. This does not prove a hand is inside a specific 2D key target or that an interaction occurred. |
| What might be missing? | If Jevon specifies spatial 2D hand targeting, grip/pinch, touch, dwell, trajectory, depth or object contact, wrist Y alone is insufficient. PoseFrame already has 2D wrist joints/confidence, but that does not expose calibrated wrist X/Y in BodySnapshot or establish a pinch/contact detector. Diamond collection gestures are likewise unspecified. |
| Who decides interaction semantics? | Jevon owns exact key/collection actions, targets, coordination/timing windows, success/failure, difficulty, vault progression and diamond scoring. He also resolves the relationship between a possible 5:00 vault milestone and the 5:00–5:10 bonus; CP1 does not choose an ordering. Kevin/Theo review affordances and target placement; Edo evaluates measurable input feasibility. No gesture is invented here. |
| How would a genuine extension happen? | After a concrete mechanic is specified, Edo proposes the smallest reusable Shared body/gesture measurement with coordinates, validity, capture time and deterministic tests; Jevon/Kevin review before implementation. Existing raw observations may support it, but reliability requires device testing. No new fields now. |
| Why no game state inside BodySnapshot? | It is reusable captured evidence for future independent games, not a Laser Heist controller. Timer/round phase, laser difficulty, vault progress, five-second opportunity, diamond counts and results belong to `Games/LaserHeist/Domain/` and `Session/`, using Jevon's GameClock. Their changes do not reset input generations automatically. |

Current high/low laser evidence stays unchanged. CP1 remains lean and sufficiently scoped for the anonymous identity migration once approved; uncertain future gestures do not block it and do not authorize extra detector/renderer/CP2 work.
