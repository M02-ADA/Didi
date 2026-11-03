# LH-00 CP2 — Production Phase 1 Report

**3 November 2026 — local implementation, awaiting Edo's review.** Branch `feat/cutout-handoff`, starting HEAD `976e89f7ff2325991c1876df9fcc413bda721c67`. No commit, push, merge, branch switch, staging or destructive Git operation.

## 1. Result and scope

Implemented the production **CPU cutout handoff**, exercised by an independent actor-based synthetic producer and mock MainActor consumer through the real API. The packet owns independent copied bytes, carries its exact CP1 snapshot, and supports bounded latest-frame delivery and context-aware leases.

**This is Phase 1 only.** No live source pipeline, mask association, actual calibration, Metal/GPU work or RealityKit integration was implemented or executed in this phase. The previous GPU/alpha spike evidence remains historical isolated evidence, not a production renderer test. Full CP2 / LH-14 completion is not claimed.

## 2. Files changed

| File | Change |
|---|---|
| `Sedactive/Shared/BodyTracking/Capture/PlayerCutoutFrame.swift` | New packet, image descriptor, source metadata, placement/rect validation, limits and errors. |
| `Sedactive/Shared/BodyTracking/Capture/PlayerCutoutCompositor.swift` | Replaced import-only skeleton with fixed producer-confined pool/copier, immutable Data owner and shared reservation budget. No live compositor algorithm. |
| `Sedactive/Shared/BodyTracking/Capture/PlayerCutoutHandoff.swift` | New consumer protocol/channel: claim, latest pending, acquired lease, context/status/freshness and release. |
| `SedactiveTests/Shared/BodyTrackingTests/CutoutContractTests.swift` | New schema/identity/alpha tests and controlled actor producer. |
| `SedactiveTests/Shared/BodyTrackingTests/CutoutMemoryTests.swift` | New real CV pool/copy/padding/lifetime/bounds tests. |
| `SedactiveTests/Shared/BodyTrackingTests/CutoutDeliveryTests.swift` | New real-provider mock-consumer, ordering/backpressure/cancel/CP1-independence tests. |
| `SedactiveTests/Shared/BodyTrackingTests/CutoutLifecycleTests.swift` | New generation/camera/calibration/status/controlled cancellation tests. |
| `Docs/LH-00-Checkpoint-2-Cutout-Handoff-Proposal.md` | Updated canonical production contract, decision history, ownership/API, alpha/bounds and remaining gates. |
| `Docs/LH-00-CP2-Production-Phase-1-Report.md` | This report. |

No CP1 source, JSON fixture, existing test, BodyInputService, Kevin/Jevon production file, RCP asset, App wiring, scheme or project setting changed. Existing `Scripts/CP2Spike/` files are untouched and not dependencies of production code.

## 3. Actual API and data contract

All names use existing module-internal access in the app target; no package/framework/public SDK was added.

```swift
// Immutable checked-Sendable values:
PlayerCutoutFrame.init(
    bodySnapshot: BodySnapshot,
    sourceImageSizePx: CutoutImageSize,
    players: [PlayerID: PlayerCutoutSlot]
) throws

enum PlayerCutoutSlot: Sendable {
    case available(image: CutoutImage, placement: CutoutPlacement)
    case unavailable(CutoutUnavailableReason)
}

// Source association is sealed when copying and checked when building the frame:
CutoutImageSource.init(snapshot: BodySnapshot, playerID: PlayerID) throws

CutoutImageDescriptor.init(
    width: Int, height: Int, bytesPerRow: Int,
    zeroAlphaColor: CutoutZeroAlphaColor = .zeroRGB,
    limits: CutoutMemoryLimits
) throws

// Intentionally non-Sendable producer workspace, owned by one worker actor:
CutoutPixelCopier.init(
    width: Int, height: Int, budget: CutoutMemoryBudget,
    rowAlignment: Int = 64, sourceBufferLimit: Int = 2
) throws
CutoutPixelCopier.makeImage(
    source: CutoutImageSource,
    sourceAlpha: CutoutSourceAlpha = .straight,
    zeroAlphaColor: CutoutZeroAlphaColor = .zeroRGB,
    renderCompleted: (CVPixelBuffer) throws -> Void
) throws -> CutoutImage

// Immutable image's only byte access; no escaped source buffer or naked Data alias:
CutoutImage.withUnsafeBytes(
    _ body: (UnsafeRawBufferPointer) throws -> Void
) rethrows
```

The final snippet lists method signatures using qualified names for reference, not a standalone compilable declaration file. Exact declarations are in the source files above.

Each combined frame has exactly P1/P2 outcomes and the **original BodySnapshot value**, not a new snapshot sampled at consumption. Available images require reliable tracking and calibration metadata. Each source binding includes player, generation, frameID, capturedAt, camera revision and calibration revision. Wrong-frame or wrong-player images are rejected. Invalid collision measurements do not automatically prevent otherwise reliable imagery.

The descriptor fixes BGRA8, sRGB and actual **straight alpha**. BytesPerRow may exceed width×4; all size/stride arithmetic is checked and copied padding is cleared. Encoded-sRGB premultiplication and linear-light premultiplication have different explicit conversion paths; neither is merely relabeled. Default A=0 RGB is zero; producer-prepared hidden edge color can be preserved only for a straight source. No dilation algorithm, production edge radius, color calibration or material modification was introduced.

```swift
@MainActor protocol PlayerCutoutProviding: AnyObject {
    var state: CutoutHandoffState { get }
    func claimConsumer(generation: UUID) throws -> CutoutConsumerToken
    func acquireLatest(_ consumer: CutoutConsumerToken, at now: Double) throws -> CutoutLease?
    func isCurrent(_ lease: CutoutLease, playerID: PlayerID, at now: Double) -> Bool
    @discardableResult func release(_ token: CutoutLeaseToken) throws -> Bool
    @discardableResult func releaseConsumer(_ token: CutoutConsumerToken) throws -> Bool
    func observe(_ callback: @escaping @MainActor (CutoutHandoffEvent) -> Void) throws -> UUID
    func removeObserver(_ token: UUID) throws
}

// Concrete MainActor owner ingress:
PlayerCutoutHandoff.init(budget: CutoutMemoryBudget, freshness: CutoutFreshnessPolicy)
PlayerCutoutHandoff.updateInput(_ event: BodyInputStatusEvent) throws
PlayerCutoutHandoff.offer(_ frame: PlayerCutoutFrame, at now: Double) throws
```

`CutoutLease` contains token, consumer, frame and `availablePlayers` at acquisition. Only current-context slots may be presented. Recheck after every suspension. Releasing a lease revokes presentation permission; there is no post-release activation token.

## 4. Ownership, bounds and cancellation

- One non-Sendable copier retains its fixed CVPixelBufferPool on the producer executor. The completed-writes callback is synchronous. The producer must finish all writes before it returns; no hidden later writer is permitted.
- The copier reserves budget, creates independent Data, read-locks/copies/converts and balances unlocks. The source may be rewritten/reused immediately after return. Output owns no CV resource.
- Private Data remains behind an immutable checked-Sendable `CutoutImage`. Scoped read access may be used to copy to Kevin's staging; pointers must not escape.
- One shared Mutex-backed budget accounts for **all retained output images**, including consumers holding old generations. Reservation deinit, not channel cancellation, releases the charge. There is no forced reclaim of in-use memory.
- Default configurable ceilings: maximum dimension 2048, per-image 8 MiB, all copied bytes 18 MiB, six output images, source checkout threshold two. One acquired pair + pending pair + constructing pair is bounded by six image slots and the independent byte ceiling.
- Source-pool backing storage, allocation overhead and Kevin's staging/GPU textures are separate. This is not a process-memory/FPS guarantee. Future live wiring must bound worker/source candidates and use the same budget across contexts, rather than create replacement budgets indefinitely.
- Handoff owns one latest pending frame, one acquired lease, one claimed consumer and one observer. No image queues, per-frame Tasks, sleeps or timeout-driven forced reuse.
- Duplicate/late frameIDs are rejected after publication/acquisition. Source frame ordering remains generation-scoped even after camera/calibration changes.
- Source status revisions are monotonic; stale/conflicting events are rejected atomically. Generation changes revoke claims; camera changes revoke imagery; interrupted/failed clear imagery; stopped also clears the claim. Per-player calibration changes/removal preserve the other compatible slot and enforce CP1 cutovers on reacceptance.
- Ordered synchronous state notifications include current replay and work without images. One coalesced image wakeup tells Kevin to drain later. Reentrant control from callbacks is rejected, preventing half-applied state. Callback readers may inspect state.
- Explicit release/releaseConsumer supports cancellation before/after acquire and reattachment. Late stale tokens cannot release replacements. Consumer cancellation leaves input running. If a client retains old image references, pressure is reported safely until those references are dropped.
- Freshness uses injected current compatible capture-clock time at offer/acquire/presentation, not the original status-transition timestamp. An untuned nil age limit is explicit; no production hold duration was invented.

## 5. Verification environment and results

Native host: Apple M5, macOS 26.5.2. Xcode 26.6 (17F113), Swift 6.3.3, iOS Simulator SDK/runtime 26.5. Simulator actually used: iPad mini (A17 Pro), `1E1C6B07-B356-4303-8756-4C0D2A4CDF05`, build 23F77.

Project conventions preserved: Swift 5, default MainActor, approachable concurrency, MemberImportVisibility, deployment 26.5. Complete concurrency checking was supplied only as a command-line verification override.

| Check | Actual outcome |
|---|---|
| App build, complete checking | Passed. |
| Separate build-for-testing, complete checking | Passed. |
| Full Simulator suite | **92 registered tests / 161 executions, 0 failures, 0 skips.** |
| Existing baseline | 64 registered / 131 executions; unchanged existing tests passed. |
| Added coverage | 28 registered cutout tests / 30 executions (three alpha cases). |
| Production complete + warnings-as-errors SIL | Passed, no diagnostics. |
| Production testable module + helper/new test SIL, complete + warnings-as-errors | Passed, no diagnostics, actual Testing macro plugin loaded. |
| Ownership negative control | Expected failure diagnosed at actual copier transfer: `sending 'self.workspace' risks causing data races`. |
| Swift warnings in final Xcode run | None. |
| Other build warning | AppIntents metadata extraction skipped because there is no AppIntents dependency. Not a Swift/concurrency warning; no framework added to silence it. |
| Simulator runtime log | An Apple `NetworkAssetManager` asset-dependency message appeared after successful tests; no assertion/build failure and no renderer code was altered to hide it. |
| Unsafe concurrency suppressions | None added; no unchecked Sendable, unsafe nonisolation, preconcurrency suppression or detached task. |

An attempted **whole-project** warnings-as-errors build was blocked before our code by generated RealityKitContent options combining `-suppress-warnings` and `-warnings-as-errors`. That generated package was not edited. Instead, the actual Xcode app/test builds use complete checking, and a separate SIL gate applies complete checking **plus warnings-as-errors** to the production handoff, CP1 dependencies and test sources. This is a tooling limitation of that whole-project command, not an ignored handoff diagnostic.

Initial test compilation identified optional `#require` call syntax and contextual macro warnings; corrected before the successful full test run and strict gate. A first standalone test SIL invocation lacked Testing framework/plugin search paths; the final invocation explicitly loads Xcode's framework and macro plugin. No checking level was weakened.

### Commands executed

From the repository root:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/cp2-phase1/Derived \
  SWIFT_STRICT_CONCURRENCY=complete build

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/cp2-phase1/Derived \
  SWIFT_STRICT_CONCURRENCY=complete build-for-testing

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/cp2-phase1/Derived \
  -resultBundlePath /private/tmp/cp2-phase1/AllTests.xcresult \
  SWIFT_STRICT_CONCURRENCY=complete test

xcrun xcresulttool get test-results summary \
  --path /private/tmp/cp2-phase1/AllTests.xcresult --format json
```

Full-suite execution reports 92 passed definitions; xcresult's per-device execution count is 161 because parameterized cases are included. This is actual Simulator execution, not test discovery alone.

Isolated strict script used the following compiler commands (macOS SIL verification, separate from actual Simulator execution):

```bash
flags=(-parse-as-library -swift-version 5 -strict-concurrency=complete
  -warnings-as-errors -default-isolation MainActor
  -enable-upcoming-feature NonisolatedNonsendingByDefault
  -enable-upcoming-feature InferIsolatedConformances
  -enable-upcoming-feature InferSendableFromCaptures
  -enable-upcoming-feature GlobalActorIsolatedTypesUsability
  -enable-upcoming-feature DisableOutwardActorInference
  -enable-upcoming-feature MemberImportVisibility
  -module-cache-path /private/tmp/cp2-phase1/ModuleCache)
source=(Sedactive/Shared/Players/Player.swift
  Sedactive/Shared/BodyTracking/Models/*.swift
  Sedactive/Shared/BodyTracking/ReplayBodyInput.swift
  Sedactive/Shared/BodyTracking/Capture/PlayerCutout{Frame,Compositor,Handoff}.swift)

xcrun --sdk macosx swiftc "${flags[@]}" -emit-sil \
  -whole-module-optimization -o /dev/null "${source[@]}"
xcrun --sdk macosx swiftc "${flags[@]}" -enable-testing \
  -emit-module -module-name Sedactive \
  -emit-module-path /private/tmp/cp2-phase1/StrictModule/Sedactive.swiftmodule "${source[@]}"
xcrun --sdk macosx swiftc "${flags[@]}" \
  -load-plugin-library "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib" \
  -F "$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks" \
  -I /private/tmp/cp2-phase1/StrictModule -emit-sil \
  -whole-module-optimization -o /dev/null \
  SedactiveTests/Shared/BodyTrackingTests/BodyInputContractTests.swift \
  SedactiveTests/Shared/BodyTrackingTests/Cutout*Tests.swift
```

The compiler-only negative source at `/private/tmp/cp2-phase1/NegativeCopier.swift` sends an actor's persistent `CutoutPixelCopier` to a MainActor `sending` parameter, then retains/reuses `workspace` in the actor. Compiling it with the same flags, testable module path and `-emit-sil -o /dev/null` returned nonzero with the expected data-race diagnostic. Compiler acceptance of Data values is supported by actual actor-produced frames used in all new suites; runtime copying tests remain necessary for alias safety.

Logs, temporary compiler reproductions and result bundle are under `/private/tmp/cp2-phase1/`; they are not repository changes and may be cleaned by the OS.

## 6. Deterministic verification details

- Real CV sources are rewritten after copy and the pool reused: previously delivered pixel bytes remain unchanged. BGRA slot colors differ and all three actual alpha paths yield the same straight fractional-alpha color.
- Alignment 4096 exercises padded strides; source padding filled with a sentinel is not leaked into copied padding.
- Source writer failures release output reservations; source checkout threshold one rejects a retained source and recovers after it is released.
- Image-count and byte ceilings are tested independently. A retained canceled lease remains charged; admission fails until its final owner drops it. New generation does not bypass that budget.
- A slow reader holds frame 1 while offers 2–25 replace pending: only frame 25 is next, 23 superseded frames are counted, retained steady images are four, transient peak stays within six and the configured byte ceiling.
- Wrong identity/frame, foreign budget, duplicate/older frame and stale generation are rejected. Calibrations can be removed and reaccepted with cutovers without resurrecting old P1 pixels, while compatible P2 remains usable.
- Status transitions and current replay are observed without images. Historical status time does not incorrectly expire a later captured pending image. Observer reentry/stale updates leave context intact.
- Task cancellation is coordinated through explicit continuations and cleanup, with no sleeps. Late tokens cannot clear replacement leases/claims. Stop/failure/generation/camera invalidation prevents old presentation permission.
- Actual CP1 ReplayBodyInput publishes to its existing sole gameplay stream while a CP2 reader holds a lease. No CP2 release is needed. This proves scheduling independence in the controlled scenario, not absence of realtime resource contention.
- Existing JSON replay fixtures load in the unchanged CP1 tests; no CP2 fixture/schema migration was introduced.

## 7. Exact guidance for Kevin

1. Receive `any PlayerCutoutProviding` from Edo's later composition wiring; production renderer does not need Core Video ownership details.
2. Observe state and claim its active generation once. The observer synchronously replays state; schedule one coalesced drain **outside** its callback. Control reentry throws. Do not add a second CP1 consumer.
3. Acquire with compatible host-clock `now`. Use `lease.availablePlayers`; a slot still present in the original frame may have become incompatible after recalibration.
4. Read descriptor/placement and copy scoped bytes into your own bounded staging. Use actual row stride. Data is not automatically a zero-copy GPU buffer.
5. Use the actual render-compatible device, front/back resources and one commit authority. Keep staging alive through GPU completion; handle precommit errors and postcommit cancellation separately.
6. Keep the CPU lease through completion. On MainActor, check `isCurrent` for each slot using fresh host time, activate matching texture/geometry/debug metadata without suspension, then release/drop the lease. This permission check does not prove frame-atomic RealityKit scanout.
7. On cancellation use structured cleanup and release the claim; on context events hide incompatible visuals immediately. GPU staging may still need pinning after CPU cleanup. Old release tokens are harmless.
8. Implement idle expiry with the reviewed renderer update hook; coordinate with Jevon. Apply the short last-good/pictogram policy only with approved durations and retain original frame metadata.

No unresolved ownership/compiler issue blocks reviewing this CPU API. Cross-owner integration still needs Kevin's review of the concrete callback/lease sequence, staging/device/commit strategy, material/zero-alpha policy and actual scene depth/sorting. Jevon coordinates the renderer update hook/recovery and any optional display-versus-verdict diagnostics. Source-status ingress uses the internal owner tee, not a second CP1 status observer.

## 8. Remaining work / readiness

**Phase 1 is ready for Edo's local review.** No claim of complete production CP2 is made.

Separately authorized Phase 2: Kevin's device handshake, bounded staging, GPU completion resource ownership, texture surfaces/activation, full-canvas geometry/UV mirroring, same-frame overlays, actual scene sorting/material/color and fallback. Validate frame behavior visually and on physical iPad; this phase ran no GPU work or new rendering comparison.

Future live input: source timestamps/orientation, camera lifecycle, Vision instance masks/pose association, segmentation/compositing completion, calibrated crop mapping, stable tracking/reentry and appropriate live orchestration/source bounds. BodyInputService remains unwired. No fake snapshots make gameplay appear live. Performance/canvas resolution, edge extension, freshness/hold, pool/memory budgets and camera-distance tolerances need device measurement and review.

## 9. Preservation, membership and Git

Before edits, recorded hashes of **251 existing files** (tracked and untracked). After implementation, the only existing-file content changes are the authorized CP2 proposal and PlayerCutoutCompositor skeleton; none are missing. All pre-existing Scripts, reports, CP1, rendering, gameplay, fixtures and project/scheme bytes were preserved.

The existing project already had a one-blank-line unstaged `.pbxproj` modification on arrival; it remains byte-identical to the recorded baseline. It is **not** a Phase 1 project edit.

Inspected generated Swift file lists: app has 48 sources, including the three production cutout files and no test sources; test target has 21 sources, including all four new suites and no app sources. Filesystem-synchronized groups and the existing test scheme handle membership without edits. Existing replay fixture loading passed.

`git diff --check` passed. No staged changes. Branch remains `feat/cutout-handoff`; HEAD unchanged. New production/test files and this report remain untracked for review; the pre-existing untracked proposal/reports/Scripts remain safe. Nothing was committed or pushed.

**Skills used:** swift-concurrency and swift-testing-expert. No skill required an additional approval gate within this authorized scope.
