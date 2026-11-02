# Structural migration report — final lean architecture

**Stage 2 completed, 31 October 2026.** This current result supersedes the pending moves and intermediate paths in the preserved stage-one record below.

## Authorization and preserved starting state

Edo explicitly authorized completing the structural migration across all owners, flattening UI, simplifying BodyTracking, updating active documentation and keeping Assets.xcassets in place. This narrow relocation authorization superseded the stage-one move approval gate; it does not permit functional implementation changes or reassign ownership. LH-00 and all feature tasks remain paused.

Started on `feat/architecture` with the previous 33 delete/destination move pairs and four untracked architecture artifacts intact. Nothing was staged. No automatic checkout or Git mutation occurred. The real filesystem, synchronized Xcode roots and current reports were inspected before editing; sources, skeletons, fixtures, catalog, documents and proposed patches were hashed before moves.

## Totals and exceptions

| Item | Result |
|---|---|
| Stage 1 | 33 files relocated |
| Stage 2 | 42 relocations: 20 previously pending source/test files, 5 UI flattening moves, 17 BodyTracking simplifications |
| Distinct originally located files moved across both stages | 53; 22 of the stage-two moves simplify destinations already moved in stage one, so 33 + 42 is not a unique-file count |
| Preserved source/test content | All 55 Swift files (41 app + 14 tests), including seven CP1 implementations and all skeletons |
| Preserved resources | Two synthetic JSON fixtures and three asset-catalog JSON files; all 60 source/test/resource files identical by content |
| Membership/configuration | Project and shared scheme byte-identical; no targets, packages, build settings or imports changed |
| Unmigrated files required by final target | None |
| Intentional exclusions | Assets.xcassets stays at its original location by final decision; App files and root smoke test stay in place; Products is untouched; historical documents and prototype workspace settings stay in place |
| Code/reference adjustments | No Swift/fixture/asset edits required. Only documentation and development-instruction paths/content were aligned. |

Legacy app roots Domain, Features, Rendering, Debug, Motion and Infrastructure are absent. The earlier nested BodyTracking groups and UI subfolders are absent. The source root is exactly App, Games, Shared, Assets.xcassets. No extra game or empty ECS folder was added.

## Actual architecture tree

See also the [current architecture explanation](Game-Oriented-Architecture.md).

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

## Stage-two migration map

These include moves of untracked stage-one destinations, performed safely without relying on git mv or staging. Every destination was checked for collisions before rename.

| Before stage 2 | Final path | Mechanical content changes |
|---|---|---|
| `Sedactive/Debug/PoseDebugOverlay.swift` | `Sedactive/Games/LaserHeist/Debug/PoseDebugOverlay.swift` | None; identical bytes |
| `Sedactive/Domain/LaserHeist/LaserCollisionJudge.swift` | `Sedactive/Games/LaserHeist/Domain/LaserCollisionJudge.swift` | None; identical bytes |
| `Sedactive/Domain/LaserHeist/LaserEncounter.swift` | `Sedactive/Games/LaserHeist/Domain/LaserEncounter.swift` | None; identical bytes |
| `Sedactive/Domain/LaserHeist/LaserGame.swift` | `Sedactive/Games/LaserHeist/Domain/LaserGame.swift` | None; identical bytes |
| `Sedactive/Domain/LaserHeist/LaserGameState.swift` | `Sedactive/Games/LaserHeist/Domain/LaserGameState.swift` | None; identical bytes |
| `Sedactive/Domain/LaserHeist/LaserWaveDirector.swift` | `Sedactive/Games/LaserHeist/Domain/LaserWaveDirector.swift` | None; identical bytes |
| `Sedactive/Domain/LaserHeist/RoundSummary.swift` | `Sedactive/Games/LaserHeist/Domain/RoundSummary.swift` | None; identical bytes |
| `Sedactive/Features/Play/PlayView.swift` | `Sedactive/Games/LaserHeist/UI/PlayView.swift` | None; identical bytes |
| `Sedactive/Features/Session/GameClock.swift` | `Sedactive/Shared/GameRuntime/GameClock.swift` | None; identical bytes |
| `Sedactive/Features/Session/GameSessionCoordinator.swift` | `Sedactive/Games/LaserHeist/Session/GameSessionCoordinator.swift` | None; identical bytes |
| `Sedactive/Features/Session/SessionState.swift` | `Sedactive/Games/LaserHeist/Session/SessionState.swift` | None; identical bytes |
| `Sedactive/Games/LaserHeist/UI/Home/HomeView.swift` | `Sedactive/Games/LaserHeist/UI/HomeView.swift` | None; identical bytes |
| `Sedactive/Games/LaserHeist/UI/Results/ResultsView.swift` | `Sedactive/Games/LaserHeist/UI/ResultsView.swift` | None; identical bytes |
| `Sedactive/Games/LaserHeist/UI/Setup/CalibrationView.swift` | `Sedactive/Games/LaserHeist/UI/CalibrationView.swift` | None; identical bytes |
| `Sedactive/Games/LaserHeist/UI/Setup/PlayerSetupState.swift` | `Sedactive/Games/LaserHeist/UI/PlayerSetupState.swift` | None; identical bytes |
| `Sedactive/Games/LaserHeist/UI/Setup/PlayerSetupView.swift` | `Sedactive/Games/LaserHeist/UI/PlayerSetupView.swift` | None; identical bytes |
| `Sedactive/Rendering/LaserHeist/GameWorldMapping.swift` | `Sedactive/Games/LaserHeist/Rendering/GameWorldMapping.swift` | None; identical bytes |
| `Sedactive/Rendering/LaserHeist/LaserScene.swift` | `Sedactive/Games/LaserHeist/Rendering/LaserScene.swift` | None; identical bytes |
| `Sedactive/Rendering/LaserHeist/PlayerCutoutEntity.swift` | `Sedactive/Games/LaserHeist/Rendering/PlayerCutoutEntity.swift` | None; identical bytes |
| `Sedactive/Shared/BodyTracking/Calibration/CalibrationSession.swift` | `Sedactive/Shared/BodyTracking/Processing/CalibrationSession.swift` | None; identical bytes |
| `Sedactive/Shared/BodyTracking/Calibration/PlayerCalibration.swift` | `Sedactive/Shared/BodyTracking/Models/PlayerCalibration.swift` | None; identical bytes |
| `Sedactive/Shared/BodyTracking/Contracts/BodyGeometry.swift` | `Sedactive/Shared/BodyTracking/Models/BodyGeometry.swift` | None; identical bytes |
| `Sedactive/Shared/BodyTracking/Contracts/BodyInputProviding.swift` | `Sedactive/Shared/BodyTracking/Models/BodyInputProviding.swift` | None; identical bytes |
| `Sedactive/Shared/BodyTracking/Contracts/BodySnapshot.swift` | `Sedactive/Shared/BodyTracking/Models/BodySnapshot.swift` | None; identical bytes |
| `Sedactive/Shared/BodyTracking/Infrastructure/BodyInputService.swift` | `Sedactive/Shared/BodyTracking/BodyInputService.swift` | None; identical bytes |
| `Sedactive/Shared/BodyTracking/Infrastructure/Camera/CameraPipeline.swift` | `Sedactive/Shared/BodyTracking/Capture/CameraPipeline.swift` | None; identical bytes |
| `Sedactive/Shared/BodyTracking/Infrastructure/Camera/FrameStore.swift` | `Sedactive/Shared/BodyTracking/Capture/FrameStore.swift` | None; identical bytes |
| `Sedactive/Shared/BodyTracking/Infrastructure/Compositing/PlayerCutoutCompositor.swift` | `Sedactive/Shared/BodyTracking/Capture/PlayerCutoutCompositor.swift` | None; identical bytes |
| `Sedactive/Shared/BodyTracking/Infrastructure/Vision/PersonSegmenter.swift` | `Sedactive/Shared/BodyTracking/Capture/PersonSegmenter.swift` | None; identical bytes |
| `Sedactive/Shared/BodyTracking/Infrastructure/Vision/PoseEstimator.swift` | `Sedactive/Shared/BodyTracking/Capture/PoseEstimator.swift` | None; identical bytes |
| `Sedactive/Shared/BodyTracking/Motion/BodyMeasurementExtractor.swift` | `Sedactive/Shared/BodyTracking/Processing/BodyMeasurementExtractor.swift` | None; identical bytes |
| `Sedactive/Shared/BodyTracking/Motion/JumpDetector.swift` | `Sedactive/Shared/BodyTracking/Processing/JumpDetector.swift` | None; identical bytes |
| `Sedactive/Shared/BodyTracking/Motion/MotionEngine.swift` | `Sedactive/Shared/BodyTracking/Processing/MotionEngine.swift` | None; identical bytes |
| `Sedactive/Shared/BodyTracking/Motion/PlayerTracker.swift` | `Sedactive/Shared/BodyTracking/Processing/PlayerTracker.swift` | None; identical bytes |
| `Sedactive/Shared/BodyTracking/Motion/PoseFrame.swift` | `Sedactive/Shared/BodyTracking/Models/PoseFrame.swift` | None; identical bytes |
| `Sedactive/Shared/BodyTracking/Replay/ReplayBodyInput.swift` | `Sedactive/Shared/BodyTracking/ReplayBodyInput.swift` | None; identical bytes |
| `SedactiveTests/CollisionTests/CollisionTimingTests.swift` | `SedactiveTests/Games/LaserHeist/DomainTests/CollisionTimingTests.swift` | None; identical bytes |
| `SedactiveTests/CollisionTests/LaserCollisionJudgeTests.swift` | `SedactiveTests/Games/LaserHeist/DomainTests/LaserCollisionJudgeTests.swift` | None; identical bytes |
| `SedactiveTests/GameLogicTests/LaserGameTests.swift` | `SedactiveTests/Games/LaserHeist/DomainTests/LaserGameTests.swift` | None; identical bytes |
| `SedactiveTests/GameLogicTests/LaserWaveDirectorTests.swift` | `SedactiveTests/Games/LaserHeist/DomainTests/LaserWaveDirectorTests.swift` | None; identical bytes |
| `SedactiveTests/SessionTests/GameClockTests.swift` | `SedactiveTests/Shared/GameRuntimeTests/GameClockTests.swift` | None; identical bytes |
| `SedactiveTests/SessionTests/GameSessionCoordinatorTests.swift` | `SedactiveTests/Games/LaserHeist/SessionTests/GameSessionCoordinatorTests.swift` | None; identical bytes |

## Complete original-to-final migration map

Owners retain their implementation responsibilities. Original paths are from before stage one. Status is completed for every row.

| Original path | Final path | Owner | Status/content |
|---|---|---|---|
| `Sedactive/Debug/PoseDebugOverlay.swift` | `Sedactive/Games/LaserHeist/Debug/PoseDebugOverlay.swift` | Kevin | Moved; identical bytes |
| `Sedactive/Debug/ReplayBodyInput.swift` | `Sedactive/Shared/BodyTracking/ReplayBodyInput.swift` | Edo | Moved; identical bytes |
| `Sedactive/Domain/BodyInput/BodyGeometry.swift` | `Sedactive/Shared/BodyTracking/Models/BodyGeometry.swift` | Edo | Moved; identical bytes |
| `Sedactive/Domain/BodyInput/BodyInputProviding.swift` | `Sedactive/Shared/BodyTracking/Models/BodyInputProviding.swift` | Edo | Moved; identical bytes |
| `Sedactive/Domain/BodyInput/BodySnapshot.swift` | `Sedactive/Shared/BodyTracking/Models/BodySnapshot.swift` | Edo | Moved; identical bytes |
| `Sedactive/Domain/LaserHeist/LaserCollisionJudge.swift` | `Sedactive/Games/LaserHeist/Domain/LaserCollisionJudge.swift` | Jevon | Moved; identical bytes |
| `Sedactive/Domain/LaserHeist/LaserEncounter.swift` | `Sedactive/Games/LaserHeist/Domain/LaserEncounter.swift` | Jevon | Moved; identical bytes |
| `Sedactive/Domain/LaserHeist/LaserGame.swift` | `Sedactive/Games/LaserHeist/Domain/LaserGame.swift` | Jevon | Moved; identical bytes |
| `Sedactive/Domain/LaserHeist/LaserGameState.swift` | `Sedactive/Games/LaserHeist/Domain/LaserGameState.swift` | Jevon | Moved; identical bytes |
| `Sedactive/Domain/LaserHeist/LaserWaveDirector.swift` | `Sedactive/Games/LaserHeist/Domain/LaserWaveDirector.swift` | Jevon | Moved; identical bytes |
| `Sedactive/Domain/LaserHeist/RoundSummary.swift` | `Sedactive/Games/LaserHeist/Domain/RoundSummary.swift` | Jevon | Moved; identical bytes |
| `Sedactive/Domain/Players/Player.swift` | `Sedactive/Shared/Players/Player.swift` | Edo | Moved; identical bytes |
| `Sedactive/Domain/Players/PlayerCalibration.swift` | `Sedactive/Shared/BodyTracking/Models/PlayerCalibration.swift` | Edo | Moved; identical bytes |
| `Sedactive/Features/Home/HomeView.swift` | `Sedactive/Games/LaserHeist/UI/HomeView.swift` | Unassigned | Moved; identical bytes |
| `Sedactive/Features/Play/PlayView.swift` | `Sedactive/Games/LaserHeist/UI/PlayView.swift` | Kevin | Moved; identical bytes |
| `Sedactive/Features/Results/ResultsView.swift` | `Sedactive/Games/LaserHeist/UI/ResultsView.swift` | Unassigned | Moved; identical bytes |
| `Sedactive/Features/Session/GameClock.swift` | `Sedactive/Shared/GameRuntime/GameClock.swift` | Jevon | Moved; identical bytes |
| `Sedactive/Features/Session/GameSessionCoordinator.swift` | `Sedactive/Games/LaserHeist/Session/GameSessionCoordinator.swift` | Jevon | Moved; identical bytes |
| `Sedactive/Features/Session/SessionState.swift` | `Sedactive/Games/LaserHeist/Session/SessionState.swift` | Jevon | Moved; identical bytes |
| `Sedactive/Features/Setup/CalibrationView.swift` | `Sedactive/Games/LaserHeist/UI/CalibrationView.swift` | Unassigned | Moved; identical bytes |
| `Sedactive/Features/Setup/PlayerSetupState.swift` | `Sedactive/Games/LaserHeist/UI/PlayerSetupState.swift` | Unassigned | Moved; identical bytes |
| `Sedactive/Features/Setup/PlayerSetupView.swift` | `Sedactive/Games/LaserHeist/UI/PlayerSetupView.swift` | Unassigned | Moved; identical bytes |
| `Sedactive/Infrastructure/Audio/AudioService.swift` | `Sedactive/Shared/Audio/AudioService.swift` | Unassigned | Moved; identical bytes |
| `Sedactive/Infrastructure/BodyInputService.swift` | `Sedactive/Shared/BodyTracking/BodyInputService.swift` | Edo | Moved; identical bytes |
| `Sedactive/Infrastructure/Camera/CameraPipeline.swift` | `Sedactive/Shared/BodyTracking/Capture/CameraPipeline.swift` | Edo | Moved; identical bytes |
| `Sedactive/Infrastructure/Camera/FrameStore.swift` | `Sedactive/Shared/BodyTracking/Capture/FrameStore.swift` | Edo | Moved; identical bytes |
| `Sedactive/Infrastructure/Compositing/PlayerCutoutCompositor.swift` | `Sedactive/Shared/BodyTracking/Capture/PlayerCutoutCompositor.swift` | Edo | Moved; identical bytes |
| `Sedactive/Infrastructure/Vision/PersonSegmenter.swift` | `Sedactive/Shared/BodyTracking/Capture/PersonSegmenter.swift` | Edo | Moved; identical bytes |
| `Sedactive/Infrastructure/Vision/PoseEstimator.swift` | `Sedactive/Shared/BodyTracking/Capture/PoseEstimator.swift` | Edo | Moved; identical bytes |
| `Sedactive/Motion/BodyMeasurementExtractor.swift` | `Sedactive/Shared/BodyTracking/Processing/BodyMeasurementExtractor.swift` | Edo | Moved; identical bytes |
| `Sedactive/Motion/CalibrationSession.swift` | `Sedactive/Shared/BodyTracking/Processing/CalibrationSession.swift` | Edo | Moved; identical bytes |
| `Sedactive/Motion/JumpDetector.swift` | `Sedactive/Shared/BodyTracking/Processing/JumpDetector.swift` | Edo | Moved; identical bytes |
| `Sedactive/Motion/MotionEngine.swift` | `Sedactive/Shared/BodyTracking/Processing/MotionEngine.swift` | Edo | Moved; identical bytes |
| `Sedactive/Motion/PlayerTracker.swift` | `Sedactive/Shared/BodyTracking/Processing/PlayerTracker.swift` | Edo | Moved; identical bytes |
| `Sedactive/Motion/PoseFrame.swift` | `Sedactive/Shared/BodyTracking/Models/PoseFrame.swift` | Edo | Moved; identical bytes |
| `Sedactive/Rendering/LaserHeist/GameWorldMapping.swift` | `Sedactive/Games/LaserHeist/Rendering/GameWorldMapping.swift` | Kevin | Moved; identical bytes |
| `Sedactive/Rendering/LaserHeist/LaserScene.swift` | `Sedactive/Games/LaserHeist/Rendering/LaserScene.swift` | Kevin | Moved; identical bytes |
| `Sedactive/Rendering/LaserHeist/PlayerCutoutEntity.swift` | `Sedactive/Games/LaserHeist/Rendering/PlayerCutoutEntity.swift` | Kevin | Moved; identical bytes |
| `SedactiveTests/BodyInputTests/BodyInputContractTests.swift` | `SedactiveTests/Shared/BodyTrackingTests/BodyInputContractTests.swift` | Edo | Moved; identical bytes |
| `SedactiveTests/BodyInputTests/BodyInputDeliveryTests.swift` | `SedactiveTests/Shared/BodyTrackingTests/BodyInputDeliveryTests.swift` | Edo | Moved; identical bytes |
| `SedactiveTests/BodyInputTests/BodyInputLifecycleTests.swift` | `SedactiveTests/Shared/BodyTrackingTests/BodyInputLifecycleTests.swift` | Edo | Moved; identical bytes |
| `SedactiveTests/BodyInputTests/Fixtures/cooperative-v1.json` | `SedactiveTests/Shared/BodyTrackingTests/Fixtures/cooperative-v1.json` | Edo | Moved; identical bytes |
| `SedactiveTests/BodyInputTests/Fixtures/reversed-selection-v1.json` | `SedactiveTests/Shared/BodyTrackingTests/Fixtures/reversed-selection-v1.json` | Edo | Moved; identical bytes |
| `SedactiveTests/BodyInputTests/ReplayBodyInputTests.swift` | `SedactiveTests/Shared/BodyTrackingTests/ReplayBodyInputTests.swift` | Edo | Moved; identical bytes |
| `SedactiveTests/CollisionTests/CollisionTimingTests.swift` | `SedactiveTests/Games/LaserHeist/DomainTests/CollisionTimingTests.swift` | Jevon | Moved; identical bytes |
| `SedactiveTests/CollisionTests/LaserCollisionJudgeTests.swift` | `SedactiveTests/Games/LaserHeist/DomainTests/LaserCollisionJudgeTests.swift` | Jevon | Moved; identical bytes |
| `SedactiveTests/GameLogicTests/LaserGameTests.swift` | `SedactiveTests/Games/LaserHeist/DomainTests/LaserGameTests.swift` | Jevon | Moved; identical bytes |
| `SedactiveTests/GameLogicTests/LaserWaveDirectorTests.swift` | `SedactiveTests/Games/LaserHeist/DomainTests/LaserWaveDirectorTests.swift` | Jevon | Moved; identical bytes |
| `SedactiveTests/MotionTests/BodyMeasurementExtractorTests.swift` | `SedactiveTests/Shared/BodyTrackingTests/BodyMeasurementExtractorTests.swift` | Edo | Moved; identical bytes |
| `SedactiveTests/MotionTests/JumpDetectorTests.swift` | `SedactiveTests/Shared/BodyTrackingTests/JumpDetectorTests.swift` | Edo | Moved; identical bytes |
| `SedactiveTests/MotionTests/PlayerTrackerTests.swift` | `SedactiveTests/Shared/BodyTrackingTests/PlayerTrackerTests.swift` | Edo | Moved; identical bytes |
| `SedactiveTests/SessionTests/GameClockTests.swift` | `SedactiveTests/Shared/GameRuntimeTests/GameClockTests.swift` | Jevon | Moved; identical bytes |
| `SedactiveTests/SessionTests/GameSessionCoordinatorTests.swift` | `SedactiveTests/Games/LaserHeist/SessionTests/GameSessionCoordinatorTests.swift` | Jevon | Moved; identical bytes |

## Xcode hierarchy and membership verification

Xcode's live Project navigator was inspected through its accessibility tree after migration, not inferred only from Markdown. It showed Games/LaserHeist with Domain, Session, Rendering, flat UI and Debug; Shared with BodyTracking Models/Processing/Capture and the two root entry points, Players, Audio and GameRuntime. The test tree showed Games/LaserHeist/DomainTests and SessionTests, Shared/BodyTrackingTests with both fixtures, Shared/GameRuntimeTests, and the root smoke test.

The pre-existing open collision editor pointed at the removed old path after the filesystem rename. Selecting LaserCollisionJudge.swift from the new navigator location opened it successfully at `Sedactive/Games/LaserHeist/Domain/LaserCollisionJudge.swift`; no source or project change was needed to clear that stale editor location.

Generated SwiftFileLists were checked for both arm64 and x86_64 Simulator builds: 41 app source files plus Xcode's one generated asset-symbol source, and 14 test sources, each exactly once per architecture. No app/test membership crossover or missing/duplicate source was found. The project retains two separate filesystem-synchronized roots and its existing scheme Test action.

## Build and test results

Installed Xcode 26.6 (17F113). Actual tests ran on iPad mini (A17 Pro), iOS Simulator 26.5.

| Check | Previous stage | Final stage |
|---|---|---|
| App build | PASS | PASS |
| Test target build | PASS | PASS |
| Registered tests / suites | 30 / 5 | 30 / 5 |
| Executions including parameter cases | 36 | 36 |
| Failures / skipped | 0 / 0 | 0 / 0 |
| LH-23 smoke test | PASS | PASS |
| Both test-bundle fixtures load/decode | PASS | PASS |

No Swift compiler/concurrency warnings or errors occurred. Xcode emitted only its AppIntents notice: “Metadata extraction skipped. No AppIntents.framework dependency found.” No configuration change was made to suppress it. Assets compiled from the original catalog location. Both bundled JSON files also match the unchanged source fixtures byte-for-byte.

Exact commands run from repository root (the global xcode-select setting was not changed):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Sedactive.xcodeproj -scheme Sedactive -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/Sedactive-Lean CODE_SIGNING_ALLOWED=NO build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Sedactive.xcodeproj -scheme Sedactive -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/Sedactive-Lean CODE_SIGNING_ALLOWED=NO build-for-testing

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Sedactive.xcodeproj -scheme Sedactive -configuration Debug \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/Sedactive-Lean -parallel-testing-enabled NO \
  -resultBundlePath /private/tmp/Sedactive-Lean-Tests-20261031.xcresult \
  CODE_SIGNING_ALLOWED=NO test-without-building
```

Logs: `/private/tmp/sedactive-lean-app.log`, `/private/tmp/sedactive-lean-test-build.log`, `/private/tmp/sedactive-lean-tests.log`. Machine-readable summary: `/private/tmp/sedactive-lean-test-summary.json`. The xcresult summary confirms all 30 tests, 36 executions, zero failed/skipped. Verification is builds + Simulator unit tests + Xcode navigator inspection; no physical-iPad or live gameplay/camera validation is claimed.

## Documentation alignment

Updated:

- `Game-Oriented-Architecture.md`: completed lean tree, responsibilities, dependency direction, owner map, state boundaries and RealityKit ECS limits. Distinguishes skeletons from existing implementations and logical folders from compiler-enforced modules.
- This report: current result, both-stage totals, complete original-to-final map, verification evidence, preserved stage-one history.
- `Docs/TEAM_ALIGNMENT.md`: active ownership paths, current structure authority, completed structural relocation authorization and test-path references. Functional ownership and unrelated contract/workflow text are retained.
- `Docs/LaserHeist-Architecture-Reference.md`: actual current tree and path references, with superseded mechanics/task-status notes explicitly marked historical rather than reapproved.
- `AGENTS.md` and `CLAUDE.md`: direct future developers to the current structure; owner/workflow rules unchanged.

The two existing `.proposed.patch` artifacts are preserved locally byte-for-byte as stage-one history and intentionally excluded from publication. They are superseded and must not be blindly applied. Historical stage-one paths in the record below, the older drafts/prototype comparison, LH-00 proposal path examples and gameplay backlog remain preserved. Their paths resolve through the complete map above. No stale active path references remain in the current architecture/ownership/development-instruction sections; this is not a rewrite of historical backlog records or approval of old mechanics text.

## Publication verification — 1 November 2026

The separately authorized final Git review compared every current source/test/resource file with HEAD and the migration map: all 53 intended relocations are R100 exact-content renames. All 55 Swift files, both replay fixtures and all three asset-catalog JSON files are unchanged; project/scheme bytes remain unchanged. Staging includes only those relocations and the six intended documentation files. The two obsolete proposed patches remain local, untracked and excluded.

Fresh Xcode 26.6 app build, test-target build and full Simulator tests passed on the currently available iPad mini (A17 Pro), iOS 26.5: **30 registered tests, 36 executions, zero failures/skips**, including LH-23 smoke and fixture decoding. Both architectures' compiler file lists show all 41 app sources plus one generated source and all 14 test sources with correct unique membership. No Swift/concurrency warnings or errors; only the existing AppIntents metadata-extraction notice. `git diff --cached --check` passes.

The commands in the build section were rerun with derived data `/private/tmp/Sedactive-Publish-20261101` and result bundle `/private/tmp/Sedactive-Publish-Tests-20261101.xcresult`; the same Simulator UUID was verified available before use. Current logs: `/private/tmp/sedactive-publish-app.log`, `/private/tmp/sedactive-publish-test-build.log`, `/private/tmp/sedactive-publish-tests.log`; summary: `/private/tmp/sedactive-publish-test-summary.json`.

Documentation-only corrections clarify local-only historical patches, distinguish the earlier Git snapshot from publication, clarify Edo's shared replay versus Jevon's gameplay replay responsibilities, and link the approved CP1 baseline without changing decisions. Feature work remains paused. Commit/push outcome is reported separately after Git completes; this section records the verified pre-commit state.

## Pre-publication Git snapshot and remaining work

This snapshot records the end of the structural migration before the separately authorized commit/push review; it is not a claim about the post-publication working tree.

- Branch remains `feat/architecture`.
- Staged changes: none.
- Unstaged tracked changes: 53 old-location deletions paired with identical destination files, plus four documentation/instruction modifications (AGENTS, CLAUDE, TEAM_ALIGNMENT, older Architecture Reference).
- Untracked: 53 moved destinations plus four pre-existing architecture artifacts (57 files). Those four include the two updated current architecture/report documents and the two unchanged historical proposed patches.
- Nothing committed, pushed, merged, rebased, reset, checked out or automatically staged. No untracked work discarded.
- Structural migration is complete with no unresolved technical blocker or pending owner move. User review is next; Git integration waits for separate authorization. Paused feature work is separate.
- Skill applied: Swift Architecture; preserved dependencies/state ownership and avoided new frameworks/abstractions.

---

## Preserved stage-one historical report

Everything below records the earlier intermediate migration. Its pending moves, old layout and status numbers were accurate at stage one and are superseded by the final result above. The asset move originally proposed below was explicitly canceled by the final decision to keep Assets.xcassets in place. Earlier patch-check results describe their original context, not applicability to the updated documents.

# Structural migration report — stage 1 historical record

31 October 2026 — `feat/architecture`. Started clean: no staged, modified or untracked files. No merge in progress. No branch changes or Git mutations performed.

## Inspection inventory

- 41 app Swift files: seven existing body-input/calibration-value/pose/replay implementations, one starter root view and app entry point, five starter feature views, 27 import-only skeletons. No real game/rendering/camera implementation in this checkout.
- 14 test Swift files: four implemented body-input suites, one LH-23 smoke test, nine skeleton test files. Two existing synthetic JSON fixtures.
- Three asset catalog JSON files; no game art or RealityKit package references. `StuntRunSpike/` has only workspace/user settings and is untouched.
- LH-23 retained: separate synchronized app/test roots, unit-test target dependency on app, Debug testability, shared scheme Test action, generated camera usage-description setting.
- Swift source/test/fixture files and all pre-existing tracked documents/configuration are preserved byte-for-byte; only locations change.

## File migration map

Repository-relative paths. Pending rows are proposals, not completed changes. No imports, API names, access levels, algorithms, fixture contents or project settings change.

| Original path | Destination | Owner | Status | Mechanical edits |
|---|---|---|---|---|
| `Sedactive/Domain/Players/Player.swift` | `Sedactive/Shared/Players/Player.swift` | Edo | Moved | None; bytes preserved. |
| `Sedactive/Domain/Players/PlayerCalibration.swift` | `Sedactive/Shared/BodyTracking/Calibration/PlayerCalibration.swift` | Edo | Moved | None; bytes preserved. |
| `Sedactive/Motion/CalibrationSession.swift` | `Sedactive/Shared/BodyTracking/Calibration/CalibrationSession.swift` | Edo | Moved | None; bytes preserved. |
| `Sedactive/Domain/BodyInput/BodyGeometry.swift` | `Sedactive/Shared/BodyTracking/Contracts/BodyGeometry.swift` | Edo | Moved | None; bytes preserved. |
| `Sedactive/Domain/BodyInput/BodyInputProviding.swift` | `Sedactive/Shared/BodyTracking/Contracts/BodyInputProviding.swift` | Edo | Moved | None; bytes preserved. |
| `Sedactive/Domain/BodyInput/BodySnapshot.swift` | `Sedactive/Shared/BodyTracking/Contracts/BodySnapshot.swift` | Edo | Moved | None; bytes preserved. |
| `Sedactive/Motion/BodyMeasurementExtractor.swift` | `Sedactive/Shared/BodyTracking/Motion/BodyMeasurementExtractor.swift` | Edo | Moved | None; bytes preserved. |
| `Sedactive/Motion/MotionEngine.swift` | `Sedactive/Shared/BodyTracking/Motion/MotionEngine.swift` | Edo | Moved | None; bytes preserved. |
| `Sedactive/Motion/PoseFrame.swift` | `Sedactive/Shared/BodyTracking/Motion/PoseFrame.swift` | Edo | Moved | None; bytes preserved. |
| `Sedactive/Motion/JumpDetector.swift` | `Sedactive/Shared/BodyTracking/Motion/JumpDetector.swift` | Edo | Moved | None; bytes preserved. |
| `Sedactive/Motion/PlayerTracker.swift` | `Sedactive/Shared/BodyTracking/Motion/PlayerTracker.swift` | Edo | Moved | None; bytes preserved. |
| `Sedactive/Infrastructure/BodyInputService.swift` | `Sedactive/Shared/BodyTracking/Infrastructure/BodyInputService.swift` | Edo | Moved | None; bytes preserved. |
| `Sedactive/Infrastructure/Camera/FrameStore.swift` | `Sedactive/Shared/BodyTracking/Infrastructure/Camera/FrameStore.swift` | Edo | Moved | None; bytes preserved. |
| `Sedactive/Infrastructure/Camera/CameraPipeline.swift` | `Sedactive/Shared/BodyTracking/Infrastructure/Camera/CameraPipeline.swift` | Edo | Moved | None; bytes preserved. |
| `Sedactive/Infrastructure/Vision/PoseEstimator.swift` | `Sedactive/Shared/BodyTracking/Infrastructure/Vision/PoseEstimator.swift` | Edo | Moved | None; bytes preserved. |
| `Sedactive/Infrastructure/Vision/PersonSegmenter.swift` | `Sedactive/Shared/BodyTracking/Infrastructure/Vision/PersonSegmenter.swift` | Edo | Moved | None; bytes preserved. |
| `Sedactive/Infrastructure/Compositing/PlayerCutoutCompositor.swift` | `Sedactive/Shared/BodyTracking/Infrastructure/Compositing/PlayerCutoutCompositor.swift` | Edo | Moved | None; bytes preserved. |
| `Sedactive/Infrastructure/Audio/AudioService.swift` | `Sedactive/Shared/Audio/AudioService.swift` | Unassigned | Moved | None; bytes preserved. |
| `Sedactive/Debug/ReplayBodyInput.swift` | `Sedactive/Shared/BodyTracking/Replay/ReplayBodyInput.swift` | Edo | Moved | None; bytes preserved. |
| `Sedactive/Features/Home/HomeView.swift` | `Sedactive/Games/LaserHeist/UI/Home/HomeView.swift` | Unassigned | Moved | None; bytes preserved. |
| `Sedactive/Features/Setup/CalibrationView.swift` | `Sedactive/Games/LaserHeist/UI/Setup/CalibrationView.swift` | Unassigned | Moved | None; bytes preserved. |
| `Sedactive/Features/Setup/PlayerSetupState.swift` | `Sedactive/Games/LaserHeist/UI/Setup/PlayerSetupState.swift` | Unassigned | Moved | None; bytes preserved. |
| `Sedactive/Features/Setup/PlayerSetupView.swift` | `Sedactive/Games/LaserHeist/UI/Setup/PlayerSetupView.swift` | Unassigned | Moved | None; bytes preserved. |
| `Sedactive/Features/Results/ResultsView.swift` | `Sedactive/Games/LaserHeist/UI/Results/ResultsView.swift` | Unassigned | Moved | None; bytes preserved. |
| `SedactiveTests/BodyInputTests/BodyInputContractTests.swift` | `SedactiveTests/Shared/BodyTrackingTests/BodyInputContractTests.swift` | Edo | Moved | None; bytes preserved. |
| `SedactiveTests/BodyInputTests/BodyInputDeliveryTests.swift` | `SedactiveTests/Shared/BodyTrackingTests/BodyInputDeliveryTests.swift` | Edo | Moved | None; bytes preserved. |
| `SedactiveTests/BodyInputTests/BodyInputLifecycleTests.swift` | `SedactiveTests/Shared/BodyTrackingTests/BodyInputLifecycleTests.swift` | Edo | Moved | None; bytes preserved. |
| `SedactiveTests/BodyInputTests/Fixtures/cooperative-v1.json` | `SedactiveTests/Shared/BodyTrackingTests/Fixtures/cooperative-v1.json` | Edo | Moved | None; bytes preserved. |
| `SedactiveTests/BodyInputTests/Fixtures/reversed-selection-v1.json` | `SedactiveTests/Shared/BodyTrackingTests/Fixtures/reversed-selection-v1.json` | Edo | Moved | None; bytes preserved. |
| `SedactiveTests/BodyInputTests/ReplayBodyInputTests.swift` | `SedactiveTests/Shared/BodyTrackingTests/ReplayBodyInputTests.swift` | Edo | Moved | None; bytes preserved. |
| `SedactiveTests/MotionTests/BodyMeasurementExtractorTests.swift` | `SedactiveTests/Shared/BodyTrackingTests/BodyMeasurementExtractorTests.swift` | Edo | Moved | None; bytes preserved. |
| `SedactiveTests/MotionTests/JumpDetectorTests.swift` | `SedactiveTests/Shared/BodyTrackingTests/JumpDetectorTests.swift` | Edo | Moved | None; bytes preserved. |
| `SedactiveTests/MotionTests/PlayerTrackerTests.swift` | `SedactiveTests/Shared/BodyTrackingTests/PlayerTrackerTests.swift` | Edo | Moved | None; bytes preserved. |
| `Sedactive/Domain/LaserHeist/LaserCollisionJudge.swift` | `Sedactive/Games/LaserHeist/Domain/LaserCollisionJudge.swift` | Jevon | Pending agreement | None; bytes preserved. |
| `Sedactive/Domain/LaserHeist/LaserEncounter.swift` | `Sedactive/Games/LaserHeist/Domain/LaserEncounter.swift` | Jevon | Pending agreement | None; bytes preserved. |
| `Sedactive/Domain/LaserHeist/LaserGame.swift` | `Sedactive/Games/LaserHeist/Domain/LaserGame.swift` | Jevon | Pending agreement | None; bytes preserved. |
| `Sedactive/Domain/LaserHeist/LaserGameState.swift` | `Sedactive/Games/LaserHeist/Domain/LaserGameState.swift` | Jevon | Pending agreement | None; bytes preserved. |
| `Sedactive/Domain/LaserHeist/LaserWaveDirector.swift` | `Sedactive/Games/LaserHeist/Domain/LaserWaveDirector.swift` | Jevon | Pending agreement | None; bytes preserved. |
| `Sedactive/Domain/LaserHeist/RoundSummary.swift` | `Sedactive/Games/LaserHeist/Domain/RoundSummary.swift` | Jevon | Pending agreement | None; bytes preserved. |
| `Sedactive/Features/Session/GameSessionCoordinator.swift` | `Sedactive/Games/LaserHeist/Session/GameSessionCoordinator.swift` | Jevon | Pending agreement | None; bytes preserved. |
| `Sedactive/Features/Session/GameClock.swift` | `Sedactive/Shared/GameRuntime/GameClock.swift` | Jevon | Pending agreement | None; bytes preserved. |
| `Sedactive/Features/Session/SessionState.swift` | `Sedactive/Games/LaserHeist/Session/SessionState.swift` | Jevon | Pending agreement | None; bytes preserved. |
| `Sedactive/Rendering/LaserHeist/PlayerCutoutEntity.swift` | `Sedactive/Games/LaserHeist/Rendering/Entities/PlayerCutoutEntity.swift` | Kevin | Pending agreement | None; bytes preserved. |
| `Sedactive/Rendering/LaserHeist/LaserScene.swift` | `Sedactive/Games/LaserHeist/Rendering/LaserScene.swift` | Kevin | Pending agreement | None; bytes preserved. |
| `Sedactive/Rendering/LaserHeist/GameWorldMapping.swift` | `Sedactive/Games/LaserHeist/Rendering/GameWorldMapping.swift` | Kevin | Pending agreement | None; bytes preserved. |
| `Sedactive/Features/Play/PlayView.swift` | `Sedactive/Games/LaserHeist/UI/Play/PlayView.swift` | Kevin | Pending agreement | None; bytes preserved. |
| `Sedactive/Debug/PoseDebugOverlay.swift` | `Sedactive/Games/LaserHeist/Debug/PoseDebugOverlay.swift` | Kevin | Pending agreement | None; bytes preserved. |
| `SedactiveTests/CollisionTests/CollisionTimingTests.swift` | `SedactiveTests/Games/LaserHeist/DomainTests/CollisionTimingTests.swift` | Jevon | Pending agreement | None; bytes preserved. |
| `SedactiveTests/CollisionTests/LaserCollisionJudgeTests.swift` | `SedactiveTests/Games/LaserHeist/DomainTests/LaserCollisionJudgeTests.swift` | Jevon | Pending agreement | None; bytes preserved. |
| `SedactiveTests/GameLogicTests/LaserGameTests.swift` | `SedactiveTests/Games/LaserHeist/DomainTests/LaserGameTests.swift` | Jevon | Pending agreement | None; bytes preserved. |
| `SedactiveTests/GameLogicTests/LaserWaveDirectorTests.swift` | `SedactiveTests/Games/LaserHeist/DomainTests/LaserWaveDirectorTests.swift` | Jevon | Pending agreement | None; bytes preserved. |
| `SedactiveTests/SessionTests/GameSessionCoordinatorTests.swift` | `SedactiveTests/Games/LaserHeist/SessionTests/GameSessionCoordinatorTests.swift` | Jevon | Pending agreement | None; bytes preserved. |
| `SedactiveTests/SessionTests/GameClockTests.swift` | `SedactiveTests/Shared/GameRuntimeTests/GameClockTests.swift` | Jevon | Pending agreement | None; bytes preserved. |
| `Sedactive/Assets.xcassets/AccentColor.colorset/Contents.json` | `Sedactive/Resources/Assets.xcassets/AccentColor.colorset/Contents.json` | Theo / Kevin | Pending agreement | None; bytes preserved. |
| `Sedactive/Assets.xcassets/AppIcon.appiconset/Contents.json` | `Sedactive/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` | Theo / Kevin | Pending agreement | None; bytes preserved. |
| `Sedactive/Assets.xcassets/Contents.json` | `Sedactive/Resources/Assets.xcassets/Contents.json` | Theo / Kevin | Pending agreement | None; bytes preserved. |

The root smoke test and all three App files remain in place. The catalog's three files remain in place. The original architecture reference, TEAM_ALIGNMENT, AGENTS, CLAUDE and backlog/CP1 documents remain unchanged; proposed documentation patches are separate review artifacts. Owner labels for tests follow the implementation responsibility, not whoever created their skeletons.

## Documentation additions

- `Game-Oriented-Architecture.md`: approved architecture decision, actual tree with implementation status, intended destinations, dependency/state boundaries and review checklist.
- `TEAM_ALIGNMENT.proposed.patch`: proposed ownership/path lookup updates only, without changing owners, contracts, mechanics, B2 or task statuses. Not applied; team review required.
- `Architecture-Reference.proposed.patch`: proposed pointer to the new reference and explicit historical-layout label for old paths. Not applied; review required.
- This report: complete inventory, migration map, verification evidence and remaining work.

Existing LH-00 proposal path examples, historical drafts and prototype comparison are preserved. Resolve their old paths through this map. No gameplay-backlog rewrite occurs. AGENTS and CLAUDE still point to existing TEAM_ALIGNMENT; no broken instruction-file link is introduced.

## Verification

Verification completed using Xcode 26.6 (17F113), iPad mini (A17 Pro) Simulator / iOS 26.5. Simulator unit tests ran; no physical-iPad validation or game-behavior session was performed.

| Check | Result |
|---|---|
| App build | PASS |
| Unit-test target build | PASS |
| All existing tests | PASS: 30 registered tests in five suites, 36 executions including parameter cases, 0 failed / 0 skipped |
| LH-23 smoke | PASS, included in full suite |
| Repository file preservation | All 74 original tracked files retain original bytes at original/planned paths |
| App source membership | 41 repository Swift files plus generated asset-symbol source; each exactly once per architecture |
| Test source membership | 14 Swift files, each exactly once per architecture; no app/test source crossover |
| Resources | Both unchanged JSON fixtures copied into `.xctest` and decoded by passing tests; unchanged asset catalog compiled |
| Project/scheme/settings | Byte-identical; separate synchronized groups and Test action preserved |
| Whitespace / patch syntax | `git diff --check` passes; both proposed patches pass `git apply --check` without applying them |
| Compiler diagnostics | No Swift compiler/concurrency warnings or errors. Xcode reports: “Metadata extraction skipped. No AppIntents.framework dependency found.” No setting or dependency change needed. |

Commands run from repository root, using `DEVELOPER_DIR` rather than changing global Xcode selection:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Sedactive.xcodeproj -scheme Sedactive -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/Sedactive-Modular CODE_SIGNING_ALLOWED=NO build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Sedactive.xcodeproj -scheme Sedactive -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/Sedactive-Modular CODE_SIGNING_ALLOWED=NO build-for-testing

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Sedactive.xcodeproj -scheme Sedactive -configuration Debug \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/Sedactive-Modular -parallel-testing-enabled NO \
  -resultBundlePath /private/tmp/Sedactive-Modular-Tests-20261031.xcresult \
  CODE_SIGNING_ALLOWED=NO test-without-building
```

Logs: `/private/tmp/sedactive-modular-app.log`, `/private/tmp/sedactive-modular-test-build.log`, `/private/tmp/sedactive-modular-tests.log`. Result bundle: `/private/tmp/Sedactive-Modular-Tests-20261031.xcresult`. Summary: `/private/tmp/sedactive-modular-test-summary.json`.

These checks establish buildability, source/resource membership and unchanged existing tests. They do not demonstrate completion of skeleton game features, live camera algorithms or RealityKit rendering. No new tests are added for byte-preserving moves.


## Remaining structural work

1. Obtain Jevon agreement for nine app files and six skeleton tests, then perform those listed moves (including shared GameClock).
2. Obtain Kevin agreement for five app files (three rendering, Play, pose debug overlay), then move them without implementation changes.
3. Obtain Theo/Kevin agreement for the three-file asset catalog relocation.
4. Review/apply the protected documentation proposals and reconcile any remaining active path references with the map.
5. Rebuild and rerun tests after those remaining moves.

Paused LH-00, calibration, camera, Motion, collision, rendering and onboarding work is outside this list and remains paused. No new Components, Systems, detector, fixtures, games or generic framework is created.

## Final Git state and scope

- Branch: `feat/architecture`, unchanged.
- Staged changes: none.
- Unstaged tracked paths: 33 removed old locations, each with an identical new destination.
- Untracked files: 33 moved destinations and four documentation artifacts (37 total). There were no untracked files at the start.
- No original file content changed. Git reports delete/untracked pairs until staging; exact-content rename detection can associate them when the user approves staging.
- No commit, push, merge, rebase, reset or checkout performed.
- Deviation: migration is deliberately partial under ownership rules. Legacy Domain/Session/Play/Rendering/Debug/test locations remain only for owner-gated moves. Resources and GameRuntime have pending destinations; empty ECS folders are not created.
- Skill read/applied: Swift Architecture (`swift-architecture-skill`), using its refactor/dependency-boundary and behavior-preservation guidance. No new architecture framework added.
