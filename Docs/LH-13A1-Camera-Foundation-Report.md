# LH-13A1 — Device Configuration & Capture Foundation

**Checkpoint result: PASS for A1 review. A2 is not implemented or authorized by this report.**

Date: 4 November 2026. Owner: Edo. Branch: `feat/camera-foundation`.
Starting HEAD: `0e39f1cdac72b22e5de19f84c5f931dd9f9d0e81`.

This is capture infrastructure with synthetic/runtime regression verification. It is not live gameplay, physical-camera verification, or approval of production camera performance.

## 1. Baseline and files

Before implementation, the two Capture files were skeletons. CP1 anonymous P1/P2 contracts, CP2 Data-copy handoff, root test target and filesystem-synchronized groups were present. Existing production input/processing wiring remains unchanged.

Initial Git status contained only the pre-existing untracked `Scripts/` tree. No staged changes or merge conflicts were present. A before-edit SHA-256 inventory of existing files is retained at `/private/tmp/lh13a1/baseline.json`.

| File | Change |
|---|---|
| `Sedactive/Shared/BodyTracking/Capture/CameraPipeline.swift` | Implement capture-only configuration/capabilities, MainActor lifecycle facade, permission actor, native session actor, explicitly nonisolated sample delegate and independent native-event channel. |
| `Sedactive/Shared/BodyTracking/Capture/FrameStore.swift` | Implement immutable owned-source metadata, checked descriptors, bounded mailbox/budget, host-clock conversion and actor-owned reconstruction-only sink. |
| `SedactiveTests/Shared/BodyTrackingTests/CameraPipelineTests.swift` | New Swift Testing lifecycle/capability suite and controlled test adapters. |
| `SedactiveTests/Shared/BodyTrackingTests/FrameStoreTests.swift` | New Swift Testing ownership, bounds, provenance and real Core Video/Core Media synthetic tests. |
| `Docs/LH-13A1-Camera-Foundation-Report.md` | This checkpoint report. |

No project, scheme, CP1/CP2, App wiring, renderer, gameplay, calibration, Vision or other processing implementation changed. Existing `Scripts/` contents are preserved. No diagnostic view, preview route, or camera activation was added to the running app.

## 2. Actual configuration behavior

The internal `CameraCaptureConfiguration.experimental` requests 1280×720 BGRA at 30 FPS; source-copy limits are 4 MiB per frame and 12 MiB total. These values do not extend CP1's `BodyInputConfiguration`.

- Discover front Ultra Wide, TrueDepth and Wide device advertisements. Prefer an actual front Ultra Wide. A front device advertising Center Stage formats is recognized as the appropriate capability alternative: iPad front hardware must not be identified solely by a Wide device-type assumption. Generic front Wide without that capability is not silently selected.
- Never discover/select the rear camera or audio input. Choose one front device deterministically; an incompatible preferred device fails with available-format descriptions rather than silently trying another device.
- Select a compatible native 16:9 format at least 1280×720 with a frame-rate range containing 30 FPS. Use `.inputPriority` and an explicit active format, with requested 1280×720 video-output dimensions. A larger supported native format may supply the explicitly requested output size; it is not permission to deliver another output resolution. Native dimensions and requested output dimensions remain distinct.
- Verify BGRA advertisement, frame-rate controls and landscape rotation support. Set both frame durations to 1/30. Disable auto FPS only when supported. Set zoom 1 only when supported. Disable stabilization only when supported; require actual stabilization off.
- Derive capture rotation from `AVCaptureDevice.RotationCoordinator`; accept supported landscape 0°/180° and set it explicitly. Do not assume the M4 front camera's default angle. Explicitly turn off automatic mirroring where supported and require unmirrored output.
- Do not alter global/user Center Stage control ownership. Active Center Stage is an explicit unsupported configuration, including if it activates later. Active-format, zoom, capture-angle and synchronization-clock changes fail closed; a new explicit generation/configuration is required. This conservative policy is subject to actual M4 verification in A2.
- Set `alwaysDiscardsLateVideoFrames = true`. Disable automatic/preview-sized output dimension selection and request BGRA/1280×720 explicitly.
- Native-format/output-control validation happens during setup. **Actual delivered dimensions, pixel format, row stride, rotation, mirror state and stabilization are checked on callbacks.** A `.running` session state alone is not proof of actual 720p/30 FPS delivery. Hardware negotiation and achieved FPS have not been measured.

Unsupported dimensions/format/stride, configuration or dynamic geometry stop the affected source. There is no silent format/device substitution.

## 3. Lifecycle and ownership

The capture-only control surface is deliberately independent of `BodyInputProviding`:

```swift
@MainActor final class CameraPipeline {
    func start(generation: UUID,
               configuration: CameraCaptureConfiguration = .experimental) async throws
    func stop() async
    var state: CameraPipelineState { get }
    func observe(_ callback: @escaping @MainActor (CameraPipelineState) -> Void) throws -> UUID
    func removeObserver(_ token: UUID)
}
```

All symbols are internal; these are not new public CP1 contracts. `state` contains a revision, source context, capture status and configuration description. The one optional observer receives current-state replay and synchronous ordered notifications. Reentrant lifecycle mutation from that observer is rejected/ignored; observers must stay short and must not run image work.

`AVCameraDriver` owns one lazily created AVCaptureSession, retained across explicit stop/restart. Configuration, blocking start and stop run on the driver actor rather than MainActor. Start occurs after `commitConfiguration`. Permission checking/requesting is separate; native permission is video-only and a pending OS prompt is not falsely described as cancellable. Stop or caller cancellation invalidates the operation before any late permission reply can start capture. Compatible repeated starts share the operation, repeated stops are harmless, and used generation identifiers cannot be restarted. A fresh generation gets a new epoch and geometry revision.

Native interruption, start/stop and runtime-error notifications travel over a bounded, independent event channel. Interruption immediately suspends source admission and clears pending bytes. Notification overflow produces an explicit terminal failure instead of silently losing lifecycle state. The native session's actual `isInterrupted` / `isRunning` state distinguishes a delayed stop notification, interruption-related stop, and unexpected source shutdown. Recovery revalidates geometry/clock before admission resumes. No frame is required to observe interruption or failure.

There is one controlled processing task per active epoch. It suspends across interruptions rather than terminating on temporarily closed admission. Stop cancels the task and waits for cooperative processing completion; restarting waits for the old worker to quiesce before making another. It does not force-release a reader or create replacement workers to bypass a stuck consumer. Defensive facade deinitialization invalidates delivery and schedules native cleanup, but awaited `stop()` is the explicit shutdown contract.

**A2 composition requirement:** retain and reuse one CameraPipeline instance. Neither the observer nor the future diagnostic route may construct a second pipeline/session. App composition is intentionally not changed here.

## 4. FrameStore bounds and source lifetime

```text
native callback (scoped CV access)
  → reserve capacity
  → independent Data allocation/copy
  → latest pending owned source
  → single processing lease
  → actor-owned reconstruction-only workspace
```

- `FrameStore` is checked Sendable; small synchronous state transitions use `Synchronization.Mutex`, allowing reservation before copying without creating a Task per callback.
- Source metadata is immutable: generation, configuration epoch, geometry revision, capture-sequence frameID, host capture seconds, actual descriptor, applied rotation and unmirrored provenance.
- Width/height/stride/format and multiplication overflow are checked. BGRA visible bytes are copied row by row into fresh Data; padding is zeroed, with the full stride×height charged. No producer CVPixelBuffer or source pointer escapes the synchronous copy scope.
- Topology permits at most one construction, one latest pending and one processing job. A separate ownership budget also caps **all retained source frames at three and total source bytes at 12 MiB**, even when completed readers or retired generations retain references.
- Reserve before allocation. Replacing pending bytes may temporarily use all three slots; the oldest pending source is released only when no owner remains. Capacity pressure drops the incoming frame without a backlog.
- Private Data is reachable only through scoped `withBytes`; consumers keep the frame owner alive, not an unaccounted Data property. Reservation release follows final frame-owner destruction, not the end of a processing token. Token checks prevent an old completion from freeing a new processing slot.
- The AsyncStream carries only a bounded one-element **Void wakeup**, not queued source images. One loop drains the mailbox. Admission, processing and cancellation create no per-frame Tasks.
- Context end clears pending work but preserves accounting for construction/in-use readers. Late callbacks/results cannot revive another epoch. Starting a new generation does not reset retained-source budget.
- `CameraCopySink` reconstructs into a worker-confined CVPixelBufferPool with allocation threshold one. It checks actual destination stride against a separate 4 MiB cap, balances locks/unlocks and releases the pool on reset. No Vision request or body evidence is produced.

The reviewed application-owned pixel budget is therefore at most 12 MiB raw copies plus 4 MiB reconstructed workspace. This is **not a process-RSS guarantee**: AVFoundation-owned buffers, allocator/framework overhead, app/renderer memory and later approved branches are separate. No AVFoundation source is retained beyond the callback by this implementation.

## 5. Capture clock and identity

The delegate reads `CMSampleBufferGetPresentationTimeStamp` and converts using the actual session synchronization clock:

```swift
CMSyncConvertTime(pts, from: sessionClock, to: CMClockGetHostTimeClock())
```

The synchronization clock is acquired after native startup (some sessions establish it then) and before installing the sample delegate. Missing/changing clocks fail closed. Numeric finite host seconds are required. Arrival time, processing completion time and wall-clock offsets are never substituted.

Each delivered or AVFoundation dropped callback consumes a source frameID **before application admission**, including callbacks without an image. This sequences observed callbacks, not invisible sensor exposures. Restart uses a new generation/epoch; IDs are never reused within that context to disguise drops. Duplicate/outdated offers and obsolete contexts are rejected.

Synthetic runtime tests exercise both identity host-clock conversion and a real nonidentity Core Media timebase conversion (rate 2 with anchors: source 26 → host 203). This validates the conversion mechanism with controlled clocks, not a physical camera's timestamp behavior.

## 6. Tests and actual verification

Environment: Xcode 26.6 (17F113), Swift 6.3.3, iPhoneOS/iPhoneSimulator SDK 26.5; Apple Silicon macOS 26.5.2. Project settings remain Swift 5, default MainActor isolation, approachable concurrency enabled, MemberImportVisibility enabled and deployment 26.5.

| Verification | Actual result |
|---|---|
| App Simulator build | PASS |
| Test-target build (`build-for-testing`) | PASS |
| Focused A1 run | PASS: 26 test definitions, 33 executions including parameter arguments; 0 failures/skips |
| Full Simulator suite | PASS: 126 definitions in 16 suites, 202 executions; 0 failures/skips |
| Existing suites | All 100 existing test definitions included and passed; CP1/CP2, smoke and gameplay suites preserved |
| Complete-concurrency SIL/WMO | PASS for production files + explicit nonisolated callback registration/invocation probe, device and Simulator |
| Production object/WMO compilation | PASS, device and Simulator |
| New test-suite SIL/WMO | PASS, device and Simulator |
| Ownership negative controls | 4 expected rejections: retained mutable workspace transfer and actor-isolated delegate registration, each on device and Simulator |
| Swift/compiler concurrency diagnostics | None in successful strict checks or app/test build |
| Target membership | 52 app compile entries / 24 test compile entries; no duplicates; no test sources in app |
| Replay resources | Four JSON fixtures present once each in test bundle with exact original bytes; replay loading tests passed |
| Existing file preservation | Only the two intended skeleton source files changed; no baseline file missing; pre-existing Scripts and unrelated files unchanged |
| `git diff --check` | PASS |

The current total exceeds older historical test counts because this checkout already contains additional existing tests; this report uses the actual current result bundle, not the earlier 30/36 or CP2 historical baseline.

Tests cover permission authorized/denied/restricted/not-determined and rejected/granted responses; cancellation/stop during permission; shared startup and startup failure; repeated operations; native lifecycle events with no camera frames; both interruption/stop ordering cases; stale generations; delayed worker cleanup; bounded signal overflow; unsupported formats/rates/devices; CV source reuse after independent copy; zeroed padded rows; arithmetic/budget/owner-count limits; pending replacement; final-reader release; duplicate/obsolete offers and old processing tokens; source IDs including no-image drops; exact metadata and reconstruction; actual Core Media conversion and invalid time rejection. Controlled continuations, recorded transition cursors and no timing sleeps coordinate async tests.

**Non-compiler diagnostics:** Xcode's AppIntents metadata tool reports “Metadata extraction skipped. No AppIntents.framework dependency found.” No AppIntents feature is added here. Existing renderer startup also logs an `engine:throttleGhosted.rematerial` asset-path parsing message during hosted tests. Neither is a Swift/concurrency diagnostic or test assertion failure; renderer/assets are unchanged.

### Exact build and test commands

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/lh13a1/Derived \
  SWIFT_STRICT_CONCURRENCY=complete build

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/lh13a1/Derived \
  SWIFT_STRICT_CONCURRENCY=complete build-for-testing

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/lh13a1/Derived \
  -resultBundlePath /private/tmp/lh13a1/FocusedVerified.xcresult \
  -only-testing:SedactiveTests/CameraPipelineTests \
  -only-testing:SedactiveTests/FrameStoreTests \
  SWIFT_STRICT_CONCURRENCY=complete test-without-building

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/lh13a1/Derived \
  -resultBundlePath /private/tmp/lh13a1/Regression.xcresult \
  SWIFT_STRICT_CONCURRENCY=complete test-without-building

bash /private/tmp/lh13a1/verify-strict.sh
git diff --check
```

Complete-checking builds use a command-line override only. The isolated script additionally uses `-warnings-as-errors -emit-sil -whole-module-optimization`, Swift 5, `-default-isolation MainActor`, and the existing upcoming features: NonisolatedNonsendingByDefault, InferIsolatedConformances, InferSendableFromCaptures, GlobalActorIsolatedTypesUsability, DisableOutwardActorInference and MemberImportVisibility. It also performs object/WMO compilation and test-module SIL compilation with the SDK's Swift Testing macro plugin. The temporary explicit-callback probe registers and invokes the actual production `CameraSampleDelegate` from a nonisolated function; nominal protocol conformance alone is not the gate.

The existing A0 negative controls are read from `/private/tmp/lh13a0-preflight-4nsniuo3/NegativeWorkspace.swift` and `NegativeDelegate.swift`. They fail at SIL compilation for the intended data-race and actor-isolated-conformance diagnostics, not missing imports. No unsafe sendability, preconcurrency or diagnostic suppression was introduced. Scratch compiler scripts/probes/logs remain outside production targets and the repository.

Xcode/xcresult commands required sandbox escalation for Simulator/cache/TestReport access. The first sandbox-only build was blocked by cache/XPC permissions; successful verification above used normal Xcode services with that access. This was an environment restriction, not a source-code fix or a weakened compiler gate.

## 7. Physical device and A2 gates

Read-only CoreDevice inspection found the paired iPad Pro M4 (`iPad16,5`) on iPadOS 26.7.1 (23H30), Developer Mode enabled and developer-device services available. Xcode `-showdestinations` lists the connected iPad as an available iOS destination. No device-support incompatibility was established merely from SDK 26.5 versus OS 26.7.1.

**No physical app installation, launch, permission request, AVCaptureSession startup, captured participant imagery or camera run occurred.** Simulator tests use controlled camera adapters; only synthetic Core Video/Core Media operations execute for real. Availability in Xcode is not proof of successful deployment or supported camera configuration.

A2 still requires separate review/authorization for retained App wiring and a DEBUG diagnostics route, Kevin-reviewed preview/mirroring, physical landscape rotation/negotiation, Center Stage behavior, clock behavior through interruption, achieved dimensions/stride/FPS, p50/p95 copy/processing latency, drop/memory measurements and repeated cleanup. The Data-copy method is compiler-feasible and synthetically verified; its target-iPad throughput and CPU contention are unmeasured. There is no performance claim about CP1 independence beyond the absence of a CP1 scheduling/wait dependency in A1.

No LH-13B, LH-22, LH-13C/D, live segmentation, CP2 renderer, BodySnapshot publication or gameplay was implemented. Jevon still owns session readiness/recovery and GameClock. Kevin still owns presentation/preview conventions and RealityKit. No integration change is required from either owner to run these synthetic tests; their review is required at the later checkpoints.

## 8. Review disposition and Git

A1 is ready for Edo's review before any A2 work. Native device behavior and the physical performance/diagnostics acceptance gates remain explicitly open. App behavior is unchanged because capture is not yet composed into the application flow.

No staging, commit, push, merge, rebase or branch switch was performed. Final intended scope is two modified production files, two new test files and this new report, alongside the untouched pre-existing untracked Scripts tree.

Skills applied: `swift-concurrency` (checked isolation, task entry, mutable framework ownership and strict gates); `swift-testing-expert` (Swift Testing, parameterized cases and deterministic continuation-based async coordination).
