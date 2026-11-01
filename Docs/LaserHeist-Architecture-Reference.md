# Laser Heist architecture reference

This responsibility reference was created for LH-23 and structurally aligned on 31 October 2026. The current lean structure is defined in [Game-Oriented Architecture](Architecture/Game-Oriented-Architecture.md). Many files remain placeholders. No feature or gameplay implementation is added by this migration.

**Historical-contract notice:** earlier mechanics, mirroring, delivery and task-status explanations retained below are historical where superseded by approved current decisions and the [CP1 baseline](LH-00-Checkpoint-1-Contract-Proposal.md). Updating locations does not reopen or revise those decisions. LH-23 remains complete; LH-00 and other feature work remain paused.

**Authority and review:** follow the source-precedence order in [TEAM_ALIGNMENT.md](TEAM_ALIGNMENT.md). Approved current team decisions and agreed contracts take precedence over this reference; earlier architecture drafts and prototype findings are historical context. The task breakdown is [LaserHeist-Cooperative-Active-Gameplay-DRAFT.md](LaserHeist-Cooperative-Active-Gameplay-DRAFT.md). Its v0.9 corrections and TEAM_ALIGNMENT are still labelled draft. This documentation update does not approve outstanding decisions or shared Swift interfaces on behalf of the team; Jevon and Kevin review their affected boundaries before integration.

The design has a simple purpose: screens display the experience, motion processing understands the players, game rules decide outcomes, and rendering draws the world. Edo, Jevon and Kevin own distinct engineering responsibilities; Theo owns UI/UX and visual design. Shared data contracts let the four-person team work together without duplicate implementations.

## Complete structure

The tree is the completed lean filesystem layout; existing skeleton files are retained. Modules are logical folders inside the existing app target, not separate packages.

```text
Sedactive/
├── App/
│   ├── AppDependencies.swift
│   ├── RootView.swift
│   └── SedactiveApp.swift
├── Assets.xcassets/
│   ├── AccentColor.colorset/
│   │   └── Contents.json
│   ├── AppIcon.appiconset/
│   │   └── Contents.json
│   └── Contents.json
├── Games/
│   └── LaserHeist/
│       ├── Debug/
│       │   └── PoseDebugOverlay.swift
│       ├── Domain/
│       │   ├── LaserCollisionJudge.swift
│       │   ├── LaserEncounter.swift
│       │   ├── LaserGame.swift
│       │   ├── LaserGameState.swift
│       │   ├── LaserWaveDirector.swift
│       │   └── RoundSummary.swift
│       ├── Rendering/
│       │   ├── GameWorldMapping.swift
│       │   ├── LaserScene.swift
│       │   └── PlayerCutoutEntity.swift
│       ├── Session/
│       │   ├── GameSessionCoordinator.swift
│       │   └── SessionState.swift
│       └── UI/
│           ├── CalibrationView.swift
│           ├── HomeView.swift
│           ├── PlayView.swift
│           ├── PlayerSetupState.swift
│           ├── PlayerSetupView.swift
│           └── ResultsView.swift
└── Shared/
    ├── Audio/
    │   └── AudioService.swift
    ├── BodyTracking/
    │   ├── Capture/
    │   │   ├── CameraPipeline.swift
    │   │   ├── FrameStore.swift
    │   │   ├── PersonSegmenter.swift
    │   │   ├── PlayerCutoutCompositor.swift
    │   │   └── PoseEstimator.swift
    │   ├── Models/
    │   │   ├── BodyGeometry.swift
    │   │   ├── BodyInputProviding.swift
    │   │   ├── BodySnapshot.swift
    │   │   ├── PlayerCalibration.swift
    │   │   └── PoseFrame.swift
    │   ├── Processing/
    │   │   ├── BodyMeasurementExtractor.swift
    │   │   ├── CalibrationSession.swift
    │   │   ├── JumpDetector.swift
    │   │   ├── MotionEngine.swift
    │   │   └── PlayerTracker.swift
    │   ├── BodyInputService.swift
    │   └── ReplayBodyInput.swift
    ├── GameRuntime/
    │   └── GameClock.swift
    └── Players/
        └── Player.swift

SedactiveTests/
├── Games/
│   └── LaserHeist/
│       ├── DomainTests/
│       │   ├── CollisionTimingTests.swift
│       │   ├── LaserCollisionJudgeTests.swift
│       │   ├── LaserGameTests.swift
│       │   └── LaserWaveDirectorTests.swift
│       └── SessionTests/
│           └── GameSessionCoordinatorTests.swift
├── Shared/
│   ├── BodyTrackingTests/
│   │   ├── Fixtures/
│   │   │   ├── cooperative-v1.json
│   │   │   └── reversed-selection-v1.json
│   │   ├── BodyInputContractTests.swift
│   │   ├── BodyInputDeliveryTests.swift
│   │   ├── BodyInputLifecycleTests.swift
│   │   ├── BodyMeasurementExtractorTests.swift
│   │   ├── JumpDetectorTests.swift
│   │   ├── PlayerTrackerTests.swift
│   │   └── ReplayBodyInputTests.swift
│   └── GameRuntimeTests/
│       └── GameClockTests.swift
└── TestTargetSmokeTests.swift
```

## Why these folders exist

| Folder | Simple question it answers |
|---|---|
| `App/` | How do we start and connect everything? |
| `Games/LaserHeist/Domain/` | What rules and state define Laser Heist? |
| `Games/LaserHeist/Session/` | How does its lifecycle coordinate input and game logic? |
| `Games/LaserHeist/UI/` | What does the player see and do? |
| `Games/LaserHeist/Rendering/` and `Debug/` | How does RealityKit present and inspect the game? |
| `Shared/Players/` | Which persistent family profiles are selected? |
| `Shared/BodyTracking/Models/` | What shared evidence/interfaces/calibration values are exchanged? |
| `Shared/BodyTracking/Processing/` | How are body observations interpreted? |
| `Shared/BodyTracking/Capture/` | How do camera, Vision and cutout adapters work? |
| `Shared/GameRuntime/` and `Shared/Audio/` | Which runtime/playback mechanisms are reusable? |
| `SedactiveTests/Shared/` and `SedactiveTests/Games/` | How do we verify existing shared/game code? |

The main architectural boundary is the domain: game rules do not depend on SwiftUI, RealityKit, Vision, AVFoundation, or Core Image. UI, live services, and rendering connect to the domain's values/contracts. Constructor injection in `AppDependencies` selects concrete implementations.

## Current ownership

Paths below are relative to `Sedactive/`, except the test target. TEAM_ALIGNMENT remains the authority for ownership and changes to another owner's files.

| Owner | Responsibility and files | Integration boundary |
|---|---|---|
| **Edo — Tech Lead** | `Shared/BodyTracking/`, including `Processing/CalibrationSession.swift` and `ReplayBodyInput.swift`; `Shared/Players/`; project/test-target foundation | Produces body and cutout data. Maintains `App/` as a shared wiring hotspot; coordinates Jevon's and Kevin's wiring there. |
| **Jevon** | `Games/LaserHeist/Domain/`; `Games/LaserHeist/Session/`; `Shared/GameRuntime/GameClock.swift` | Owns gameplay decisions, capture-time conversion, evidence selection, co-op/health/score, and running the calibration phase. |
| **Kevin** | `Games/LaserHeist/Rendering/`; `Games/LaserHeist/UI/PlayView.swift`; `Games/LaserHeist/Debug/PoseDebugOverlay.swift` | Owns the RealityKit host, world mapping, visual entities, live-texture integration, rendering debug view, and frame-update integration with Jevon. |
| **Theo** | UI/UX, art direction, assets and animation specifications | Delivers design/asset handoff to Kevin; asset formats and location are agreed together. |
| **TBD** | Implementation of Home, Setup and Results screens; `Shared/Audio/AudioService.swift`; document owner | Assign an owner before implementation. Jevon running the setup/calibration flow does not assign him the screen implementation. |

Each owner adds tests for their own implementation. Edo owns motion/body-input/calibration tests; Jevon owns collision/game/session tests and the gameplay replay harness; Edo owns the shared ReplayBodyInput producer and its tests; Kevin owns world-mapping/rendering tests. The project-level smoke test is Edo's LH-23 foundation check.

Do not create duplicate body contracts or calibration baselines in consumers. Cross-owner, coordinate, timing and shared-contract changes follow TEAM_ALIGNMENT's proposal/agreement workflow. If Edo needs a camera debug view, he adds an Edo-owned file rather than editing Kevin's rendering overlay. Real debug implementations are guarded with `#if DEBUG`.

## One frame through the system

`BodyInputService` implements `BodyInputProviding` for the live camera. It coordinates the following processing rather than putting all of it into one class:

```text
CameraPipeline → PoseEstimator → PoseFrame
                                    ↓
                               MotionEngine
                           ┌────────┴─────────┐
                      PlayerTracker    BodyMeasurementExtractor
                           └────────┬─────────┘
                                    ↓
                               BodySnapshot
                                    ↓
                         GameSessionCoordinator
                                    ↓
                                LaserGame
                         ┌──────────┴──────────┐
                  LaserWaveDirector    LaserCollisionJudge
                         └──────────┬──────────┘
                                    ↓
                         Game state and events
                                    ↓
                       Scene + HUD + sound feedback
```

There is also an image path: camera frame → person mask → transparent per-player cutout → RealityKit textured entity. The cutout and body-data paths retain source-frame identity and compatible placement metadata. The diagram is runtime data flow, not a requirement for the domain to import its outer adapters.

`MotionEngine` runs `JumpDetector` as part of the required motion-processing flow. The resulting airborne phase and body geometry belong to the same timestamped player sample in `BodySnapshot`. An optional `SquatDetector` can supply repetitions or other future action facts. The game decides how these facts affect an encounter.

## Important distinctions

### Data versus processing

`BodyGeometry` is data: for example, crown height and left/right sole heights with validity. `BodyMeasurementExtractor` is the code that calculates that data. Neither decides universal safety; the judge evaluates it against a specific laser.

`PoseFrame` contains plain raw pose values, including related `PersonPose`, joint, and confidence types if useful. Under LH-00 it also carries any available per-person mask edges as plain numeric measurements, not image buffers. There is no separate mandatory `PersonPose.swift` in this layout.

`BodySnapshot` contains identified, timestamped, game-facing measurements and jump state. Each player's sample carries geometry availability and a jump phase/validity, all referring to the same observation time and calibration/coordinate revision. A plain `JumpPhase` value can live alongside the sample types in this file; the domain does not depend on the `JumpDetector` implementation. This is the same central handoff previously called `MotionSnapshot`; use **BodySnapshot** consistently from here onward.

### Calibration work versus calibration result

`CalibrationSession` collects stable samples and validates them. Its output is `PlayerCalibration`, the baseline the rest of the system uses. `PlayerSetupState` exposes readiness, messages, and a progress projection for display; it does not independently calculate another calibration baseline.

Edo implements this processing in `Shared/BodyTracking/Processing/CalibrationSession.swift`. Jevon's session coordinator owns the active setup/calibration flow: start, progress, complete, fail and retry. It passes completed calibration values to the input/motion processing. Calibration values have one source of truth. The exact progress/result interfaces and calibration method are reviewed through LH-00/LH-22, not implemented by this documentation change.

### Live service versus motion engine

`BodyInputService` manages live startup/shutdown and data flow: it connects capture, Vision, motion processing, and publication of the processed output. Publication is a local handoff, not a network upload. `MotionEngine` processes plain pose values, owns tracking/jump-detector history and any enabled squat-detector history, and produces body snapshots using supplied calibration values. It does not know how to start a camera and does not own an `AVCaptureSession`. Motion processing must not require a running camera or RealityKit scene.

The service handles asynchronous startup, errors, interruptions, and stopping. The coordinator cancels/stops it on exit and ignores old-session completion callbacks. Keep capture/image work off the UI executor, use bounded latest-data delivery, and give every snapshot its capture timestamp. The service must report failure even if no further frame arrives.

### Session state versus game state

`SessionState` says where the app is in a round's lifecycle: setup, calibration, countdown, playing, paused, finished, or failed. `LaserGameState` says what is happening inside the game: team health/score, active encounters, individual results, and round progress.

`GameSessionCoordinator` owns the session state and the `LaserGame` instance. `LaserGame` privately mutates its game state. These are distinct responsibilities, not two copies of health or score.

**Confirmed:** Jevon's `GameClock` is the single game time. Jevon's code owns time progression, pause/resume, time scaling and capture-time conversion. Kevin supplies one agreed frame-update signal to Jevon's code and then displays the resulting state/events. A RealityKit rendering clock or cosmetic animation does not advance gameplay. **TBD:** the exact frame-update mechanism is chosen jointly by Kevin and Jevon; this reference does not prescribe a callback or ECS implementation.

### Scheduling versus judgement versus presentation

`LaserWaveDirector` decides what obstacle comes next and when. `LaserEncounter` describes an obstacle, its targets, geometry, and timing; targets can differ between players. `LaserCollisionJudge` evaluates their evidence. `LaserGame` applies the result to shared health/score and emits events. `LaserScene` draws the result and reacts visually.

Use a collection of active encounters so overlapping gates can be supported. Keep entity, transform and texture references out of domain encounter state. Related pattern, timing, target, and judgement types can initially live in `LaserEncounter.swift`; related team/player statistics can live in `LaserGameState.swift`, and game-event definitions can initially live in `LaserGame.swift`.

**Confirmed ownership:** Jevon's `LaserGame` owns the bounded body-sample history. Evidence selection belongs in `Games/LaserHeist/Domain/LaserCollisionJudge.swift` under LH-09. The coordinator converts capture time to game time but does not choose the crossing sample. Edo supplies evidence and reviews its interpretation; he does not build a second checker in Motion or the input service.

## RealityKit rendering and live cutout boundary

**Confirmed:** production LaserHeist uses RealityKit 2.5D: mostly 2D assets on flat surfaces in a virtual 3D world. The game-data player plane stays independent of RealityKit world transforms. `LaserScene.swift` keeps its name; the filename does not imply an `SKScene` superclass or prescribe a RealityKit class design.

- `GameWorldMapping.swift` converts canonical game geometry into RealityKit world positions through one mapping shared by lasers, cutouts and debug views. Edo converts camera measurements into game units; Kevin owns the game-to-world mapping. Scale, origin/depth placement, perspective parameters and display-mirror behavior remain subject to the shared contract review.
- `PlayerCutoutEntity.swift` is Kevin's presentation of a player as a transparent textured entity. Kevin owns live-texture updates, transparency/layering behavior and visual fallback when cutouts are missing. A filename alone does not validate performance or draw order.
- `PlayView.swift` hosts the chosen RealityKit presentation and the SwiftUI HUD. **TBD:** Kevin chooses the render host, live-texture strategy and transparency approach; Jevon reviews the gameplay frame-update hook. Minimum iPadOS implications go through B2. This reference does not select those implementations.
- `LaserCollisionJudge` compares game values. It never reads RealityKit entities, transforms or physics collisions. Rendering does not change health, score or verdicts.
- Cosmetic animation must not move judged geometry independently of its visible body/beam mapping. Runtime cutout alignment, texture performance and transparent overlap need physical-iPad validation.

### Edo → Kevin cutout handoff

**Confirmed location/producer:** the image-carrying output type is defined in `Shared/BodyTracking/Capture/PlayerCutoutCompositor.swift`, owned by Edo and reviewed with Kevin in LH-00 checkpoint 2. It does not live in Domain and is not defined or implemented by this follow-up.

Its required content is player ID, capture timestamp, source frame ID, calibration revision, an owned image handle, orientation/mirroring state, placement metadata compatible with game geometry, and an explicit unmatched-mask indication. Edo owns segmentation and mask-to-player matching. Kevin consumes the packet; he does not implement another segmenter or body identity model.

**TBD:** image format, ownership/lifetime details, buffer-reuse strategy, association policy and permitted display lag. The design must avoid allocating a fresh image buffer every frame. Immutable values or explicitly owned image handles cross processing boundaries; a mutable shared buffer is not safe merely because a frame ID is attached.

### Live display and crossing judgement use different moments

Following TEAM_ALIGNMENT §C:

1. Kevin displays each live cutout using placement from its own source frame, or within a lag agreed and validated on device. The displayed debug geometry follows that displayed frame/placement association.
2. Jevon judges a crossing using the body sample selected for that crossing. The judged frame may differ from the current displayed frame.

The renderer keeps live video moving; it does not freeze to the selected judgement frame. Source IDs let the team inspect the difference. **TBD:** association, acceptable lag and how feedback remains visually consistent; do not hard-code a lag before measurement.

## Historical judgement and geometry notes

This section records the earlier reference, not a new approval. The approved CP1 baseline supersedes its Crown-only wording and mirror/delivery proposals; follow the current decision source. No mechanics are modified by this structural edit.

The current mechanics require:

```text
Low laser SAFE  = valid airborne phase AND sole clearance at crossing
High laser SAFE = crown clearance at crossing
```

`JumpDetector` is therefore required. A high laser does not require a classified squat, a fresh squat, or a particular knee angle. `SquatDetector` remains optional for additional mechanics such as completed repetitions in an override objective.

Before judging, validate the evidence needed by that rule: a high laser needs reliable crown geometry; a low laser needs reliable sole geometry and jump state. Missing or stale required evidence produces `Unavailable`, not an automatic SAFE or HIT. During asynchronous collection an evaluation can still be pending; `Unavailable` describes insufficient evidence for a judgement. An earlier airborne phase must not be combined with unrelated newer sole geometry to manufacture a SAFE result.

Use one canonical game coordinate system:

- Virtual player plane with Y increasing upward from the calibrated floor (`Y = 0`). These are game units, not claimed real-world meters.
- `BodyGeometry.swift` defines crown/left-sole/right-sole measurements and placement/revision conventions in those units.
- `LaserEncounter.swift` defines compatible beam geometry, thickness, player plane, and per-target crossing time.
- `LaserCollisionJudge` compares those values directly.
- `GameWorldMapping` maps them into RealityKit world positions through Kevin's shared mapping. It must not independently redefine the collision body or beam height.

**TBD under TEAM_ALIGNMENT:** keeping body/game/replay values unmirrored and applying display mirroring only in Kevin's mapping is the proposed mirror convention, not a newly approved decision in this reference. Exact game-unit scale, mapping parameters, validity states and Swift interfaces are finalized through LH-00 review.

For horizontal beams, clearance can be expressed as crown below the lower beam edge, or the lower of both sole heights above the upper beam edge, including the configured margin. Exact boundary and margin values are tuning decisions. Cosmetic effects must preserve the visible relationship between the judged beam and body.

The camera does not necessarily deliver a sample exactly at crossing. **Proposed, D-Evidence:** LH-09 describes a bounded eligibility window and delivery allowance, selecting the closest eligible sample whose required evidence is valid, with earlier-sample tie-breaking. Geometry and jump phase come from that one sample; duplicate frames do not create new observations. Jevon owns this policy and its bounded history; the team approves it. It replaces the prototype's any-qualifying-sample success rule only once agreed. Window/delay values, recovery behavior and timing interfaces remain open; this follow-up does not choose or implement them.

`JumpDetectorTests` checks phase transitions, jitter, invalid input, and recovery. `CollisionTimingTests` checks per-player crossings, capture-to-game-time mapping, stale/delayed evidence, and pause/resume behavior. Replay fixtures must supply coherent jump state and geometry as well as timestamps.

## Naming and scope decisions

- Use **BodyMeasurementExtractor.swift**. Do not also create `BodyGeometryEstimator.swift`; these names previously referred to the same responsibility.
- Keep the calibration data model only in **Shared/BodyTracking/Models/PlayerCalibration.swift**. The active sampling process is **Shared/BodyTracking/Processing/CalibrationSession.swift** on this branch.
- Use **BodySnapshot.swift** for the shared game-facing handoff; do not add a parallel `MotionSnapshot.swift` with the same data.
- `JumpDetector` is required for low-laser airborne validation. `SquatDetector` is optional; high-laser clearance does not require a particular squat form or fresh squat.
- A separate `SessionPhase.swift` is not required initially. Its lifecycle enum can live in `SessionState.swift`.
- `PlayViewModel` and `ResultsViewModel` are not required for this foundation. Add one only when the screen gains presentation work that needs its own owner. Never duplicate authoritative health/time there.
- `App/RootView.swift` currently contains the starter `ContentView` type. Edo maintains the app-entry wiring; no root-view rename or implementation is performed here.
- The `SedactiveTests` unit-test target and shared `Sedactive` scheme are now configured. App sources belong to the app target; files under root-level `SedactiveTests/` belong to the test target. The existing Swift Testing smoke test imports the app with `@testable` under Debug. Future task-specific tests still need implementations.

This reference records current paths, ownership and the current low/high laser prerequisites. It does not approve B2, shared Swift contracts, timing tolerance, damage grouping, recovery rules or advanced encounters. TEAM_ALIGNMENT and the reviewed backlog govern those decisions.

## Camera permission and unchanged B2 settings

The app uses a generated Info.plist. Its Debug and Release target settings now include `INFOPLIST_KEY_NSCameraUsageDescription`, producing this user-facing purpose string:

> Sedactive uses the camera to track your movements and display you and your partner in the game.

The key explains a future camera access request. Adding it does not start capture, prompt for access or implement the live pipeline. The test target does not receive a separate camera purpose string. No microphone permission is added.

**Current configuration facts, not B2 approval:** Swift language mode `5.0`, default `MainActor` isolation, approachable concurrency enabled, deployment target `26.5`, and device families `1,2` remain unchanged. Project-wide `nonisolated`/`Sendable` conventions, Swift 6 migration, minimum supported iPadOS/device policy and supported orientation still require the team's decision. A render-host proposal does not silently change these settings.

## Historical build and review order

The following describes the earlier planning order. LH-23 is complete, existing CP1 code is preserved, and feature development is currently paused. This structural migration does not assert new feature/task completion.

Finish LH-23 review/integration and the blocking team decisions before implementing shared contracts. In LH-00, Edo proposes the players/calibrations, body snapshots, input lifecycle and replay-fixture contracts for Jevon and Kevin to review. Jevon defines encounter/game types under LH-07 using the agreed body contracts. Replay then supports the first playable slice while Edo develops live input/calibration and Kevin develops RealityKit presentation. The cutout contract is reviewed separately before live cutout integration. This follow-up does not begin LH-00.

Initial tests should cover missing landmarks, identity ambiguity, jump phases, per-player target timing, repeated-frame deduplication, health changes, pause/recovery, and stale-session work. Add squat-detector tests if its optional mechanics are implemented. Real tracking and visible cutout/laser alignment also need target-device checks.

LH-23 still requires Jevon/Kevin's review of their affected documentation boundaries, reconciliation of the recorded move/rename statuses, and integration through the agreed Git workflow. This edit does not mark their reviews, the whole task or a merge complete. B2 changes, if agreed later, are a separate follow-up.

For each foundation change, review: one owner per mutable value; no platform dependencies inside rules; explicit coordinates/time/frame identity; a shared geometry mapping with distinct live-display/judgement timestamps; visible input failure; bounded/cancellable work; and checks appropriate to the behavior changed.
