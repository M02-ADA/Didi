# Lean Game-Oriented Modular Architecture

**Completed structural migration — 31 October 2026.** Edo explicitly authorized structural relocation of all affected files, including Jevon's and Kevin's, plus necessary documentation/reference fixes. This exception applies to this migration only; functional ownership, APIs and normal review workflows remain intact.

This structure fits Sedactive's game-first direction: Laser Heist owns its rules, session and presentation, while reusable body tracking, profiles, timekeeping and audio live in Shared. All folders are **logical modules within the existing application target**. There is no compiler-enforced package/target isolation, generic game engine, additional framework, or second game.

## Final actual structure

The tree below is the actual filesystem, also verified in Xcode's filesystem-synchronized Project navigator. It includes existing skeletons as well as implemented code; file presence is not feature completion.

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

`Docs/Architecture/` publishes this reference and the [two-stage migration report](Structural-Migration-Report.md). The obsolete stage-one `.proposed.patch` artifacts are preserved locally only and intentionally excluded from this commit. They are historical review records, superseded by the completed lean migration; do not apply them to current documents. Other historical documents remain under `Docs/`.

The source root contains exactly `App/`, `Games/`, `Shared/` and the existing `Assets.xcassets/`. There is **no global Features layer**, nor global Domain, Rendering, Debug, Motion or Infrastructure folder. The empty earlier intermediate folders were removed only after their contents moved. No empty Entities/Components/Systems or extra game directories were generated. Assets and Xcode's Products group stay where they were.

## Responsibilities and ownership

All paths below are relative to app source unless marked as tests.

| Area | Responsibility | Owner |
|---|---|---|
| `App/` | Entry point, startup and dependency composition; current RootView still defines ContentView | Edo; shared wiring remains coordinated with consumers |
| `Games/LaserHeist/Domain/` | Authoritative encounters, laser rules, health, score, round results | Jevon |
| `Games/LaserHeist/Session/` | Laser Heist lifecycle, input/game orchestration, pause/recovery | Jevon |
| `Games/LaserHeist/Rendering/` | RealityKit world, mapping, cutouts and game-specific ECS presentation | Kevin |
| `Games/LaserHeist/UI/PlayView.swift` | Gameplay presentation host/HUD | Kevin |
| Remaining `Games/LaserHeist/UI/` files | Home, setup, calibration instructions and results presentation | Implementation still unassigned; Theo owns design, not automatically Swift implementation |
| `Games/LaserHeist/Debug/PoseDebugOverlay.swift` | Rendering alignment diagnostics | Kevin |
| `Shared/Players/` | Persistent PlayerID, Player profiles, ordered SelectedPlayers | Edo |
| `Shared/BodyTracking/` | Shared body evidence, standing calibration, pose processing, capture adapters, live/replay input | Edo |
| `Shared/GameRuntime/GameClock.swift` | Reusable timekeeping mechanism; Jevon still owns game-time progression and conversion | Jevon |
| `Shared/Audio/AudioService.swift` | Reusable playback mechanism | Still unassigned |
| `Assets.xcassets/` | Existing catalog, icons/accent; UI/UX/art handoff | Theo design, coordinated with Kevin; no ownership change |
| `SedactiveTests/Shared/BodyTrackingTests/` | Body-input, replay and Motion tests | Edo |
| `SedactiveTests/Shared/GameRuntimeTests/` | GameClock tests | Jevon |
| `SedactiveTests/Games/LaserHeist/` | Domain and session tests | Jevon |
| `SedactiveTests/TestTargetSmokeTests.swift` | LH-23 app-import/test-target foundation | Edo |

## Dependency direction

```text
App composition → Games/LaserHeist and Shared
LaserHeist UI / Rendering → LaserHeist Session / read-only game state
LaserHeist Session → LaserHeist Domain + Shared input/runtime contracts
LaserHeist Domain → framework-independent Shared values
Shared entry points / adapters / processing → Shared models and player identity
```

These arrows express intended dependencies, not new wiring implemented by this move. App creates concrete dependencies; games and Shared do not depend on App. Shared never depends on Laser Heist. A future independent game may reuse Shared, but must not consume another game's implementation details. No generic game coordinator/protocol is added preemptively.

Laser Heist Domain imports no SwiftUI, RealityKit, AVFoundation, Vision or Core Image. RealityKit and UI read state and forward actions; they do not create competing authoritative state. Folder organization alone cannot enforce these rules: code review and appropriate tests remain necessary.

## Shared BodyTracking in simple terms

| Location | What belongs here |
|---|---|
| `Models/` | Plain measurements, snapshots, provider interface, standing calibration values/mapping and raw PoseFrame values. The folder name does not introduce a new state owner. |
| `Processing/` | Calibration sampling, tracking, measurement extraction and jump interpretation. Processing consumes plain data; it does not decide laser outcomes or own an AVCaptureSession. |
| `Capture/` | Camera frame capture/store, Vision estimation, segmentation and cutout composition adapters. Framework work remains outside plain models. |
| `BodyInputService.swift` | Live pipeline entry point/lifecycle and processed-output publication. Existing skeleton remains a skeleton. |
| `ReplayBodyInput.swift` | Existing deterministic synthetic producer implementing the same body-input interface, without real camera input or gameplay time. |

The five Models files, Player.swift and ReplayBodyInput.swift contain the seven existing CP1 implementations, preserved exactly. Their four implemented test suites and two JSON fixtures also remain unchanged. Motion/calibration algorithms and live capture adapters are currently import-only skeletons. No paused LH-00, LH-22 or LH-13 work resumes.

## Game-specific state versus shared state

- Persistent player identity/profile and ordered session selection stay in shared Player values; no roles/zones are introduced.
- Standing calibration and per-frame evidence remain shared technical data with their original UUID, time and revision semantics. Calibration screens remain game UI.
- Laser encounters, verdicts, cooperative health/score and results belong to Laser Heist Domain. Session coordinates the game's flow without duplicating those values.
- GameClock's reusable mechanism lives in Shared, but Jevon remains responsible for using it, advancing game time and converting capture time. No camera or renderer owns a competing gameplay clock.
- Rendering entities, textures and visual state belong to Laser Heist. Shared body evidence does not contain authoritative laser outcomes or RealityKit entities.

## RealityKit ECS boundary

`LaserScene.swift`, `GameWorldMapping.swift` and `PlayerCutoutEntity.swift` sit directly in game Rendering. They retain their agreed names; all three are currently skeletons. Future ECS components/systems belong to this game's rendering implementation when actual code warrants them. No ECS architecture is implemented by moving folders.

Authoritative collision, health, score and cooperative decisions remain in Domain/Session. RealityKit physics/events must not independently mutate those outcomes. Kevin maps shared game-plane geometry into the world; Edo's canonical evidence and Jevon's judged geometry keep their existing contracts. Preview/cutout mirroring, coordinates and timing rules are not changed here.

## Xcode, resources and preservation

The existing application/test targets use separate filesystem-synchronized root groups. All moves remain inside their original target root, so no `.pbxproj`, scheme, imports, Swift APIs or project settings needed changes. Test code stays out of the app target. Fixtures stay in the test root and are loaded from the built test bundle. The existing catalog compiles from `Sedactive/Assets.xcassets`; no Resources folder is added.

App startup remains the starter ContentView flow. Most gameplay/rendering/session files and nine test files are skeletons, not completed features. The migration report records actual builds, test executions, byte-preservation checks and Xcode UI inspection. No physical-device gameplay or camera validation is claimed.

## Documentation and future review

[TEAM_ALIGNMENT](../TEAM_ALIGNMENT.md) contains the current ownership paths and the narrow structural authorization. The [older Architecture Reference](../LaserHeist-Architecture-Reference.md) keeps its architectural explanations with updated active paths; explicitly historical mechanics/status notes defer to approved current decisions. Historical CP1/backlog/prototype paths can be resolved through the complete original-to-final migration map without rewriting those records.

Before future implementation, review: correct owner; no game dependency in Shared; no framework dependency in Domain; one owner per mutable state; unchanged body/time/geometry semantics unless separately approved; tests and target membership appropriate to the change. LH-00 and all feature work remain paused until separately authorized.
