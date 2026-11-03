# LH-00 CP2 — Synthetic Data → GPU / RealityKit integration spike

Edo / 3 November 2026. **Result: the Data-copy carrier and bounded staging path execute successfully on the development Mac, including a standalone RealityView. This is not production CP2 approval or LH-14 completion.** Kevin still needs to review material/edge quality, production-host integration and presentation behavior; physical-iPad validation remains outstanding.

## 1. Scope, checkout and preserved work

Edo relayed Kevin's approval of the producer-confined pool + immutable Data-copy **investigation candidate**. No production ownership model was approved.

Work stayed in the existing `feat/cutout-handoff` checkout, HEAD `976e89f7ff2325991c1876df9fcc413bda721c67`. No branch switch, worktree, Git staging, commit, push, merge, rebase or reset. A SHA-256 manifest of **167 pre-existing tracked/untracked files** was taken before editing; all remain unchanged. This includes CP1, its tests/JSON fixtures, Kevin's renderer, the CP2 proposal, earlier experiments/reports and the user's project-file blank-line modification.

Read the CP2 proposal, the three earlier spike/ownership reports, existing isolated scripts, CP1 values/context, current renderer, project settings, TEAM_ALIGNMENT and architecture. The 31-case compiler characterization and CPU comparison were not repeated. This task changes no production contract, Swift source, test target, scheme, setting or asset. New Swift files are outside both filesystem-synchronized source roots.

Environment: native arm64 Mac / Apple M5, macOS 26.5.2, Xcode 26.6 (17F113), Apple Swift 6.3.3, SDK 26.5. Global xcode-select remains unchanged; commands explicitly select `/Applications/Xcode.app/Contents/Developer`. Project remains Swift 5 / default MainActor / approachable concurrency / iPadOS 26.5. Native observations are **not iPad or Simulator rendering results**.

## 2. Exact new files

All paths below are repository-relative. No existing file was modified.

| File | Purpose |
|---|---|
| `Scripts/CP2Spike/DataGPU/SyntheticFrame.swift` | Producer-confined bounded CPU CVPixelBufferPool; explicit Data deep copies; immutable combined frame with the real CP1 BodySnapshot; asymmetric synthetic pixels and full-canvas placement. |
| `Scripts/CP2Spike/DataGPU/UploadStore.swift` | Experimental MainActor upload/presentation adapter: fixed staging, one pending frame/one submitted job, actual RealityKit backing-device handshake, front/back surfaces, fenced lifetime pins, cancellation/context checks and readback support. |
| `Scripts/CP2Spike/DataGPU/GPUTests.swift` | Standalone deterministic CPU/real-Metal assertions and a small measured upload sample; no new Xcode target. |
| `Scripts/CP2Spike/DataGPU/VisualHarness.swift` | Standalone native SwiftUI RealityView, same upload adapter, P1/P2/body dots, light/dark backgrounds and front/behind synthetic laser core/glow. |
| `Scripts/CP2Spike/DataGPU/DeviceProbe.swift` | Small device/LowLevelTexture compatibility probe. |
| `Scripts/CP2Spike/run-data-gpu-spike.sh` | Complete-checking SIL, ownership negative control and optimized native executable; optional Simulator compile-only mode. |
| `Scripts/CP2Spike/build-data-gpu-visual.sh` | Complete-checking standalone visual app build and local ad-hoc signature; creates no project/target. |
| `Scripts/CP2Spike/DataGPU/Results/gpu-results.json` | Actual assertion outcomes and 30 per-pair measurement samples. |
| `Scripts/CP2Spike/DataGPU/Results/verification.json` | Compiler logs, regression summary, environment, preservation result, source hashes and visual-state metadata. |
| `Scripts/CP2Spike/DataGPU/Results/visual-frame-1.jpg` | Synthetic-only screenshot after correcting the vertical UV adapter. |
| `Scripts/CP2Spike/DataGPU/Results/visual-after-switching.jpg` | Synthetic-only screenshot after the 90-frame switching sample. |
| This report | Outcomes, limitations and owner handoff. |

The isolated adapter deliberately combines the experimental Edo upload store and Kevin-side surface adapter in one Scripts file. **It must not be copied wholesale into Shared**, which must remain independent of RealityKit. Production separation/signatures remain for Edo/Kevin review. No Kevin-owned production file needed editing or a patch to run this demonstration.

## 3. Actual ownership and upload path

```text
SyntheticProducer actor
  persistent CPU CVPixelBufferPool (threshold 2 on every checkout)
  → fill completed BGRA pixels under a write lock
  → Data(bytes:count:) under a read lock; unlock and release raw source
  → immutable Sendable SyntheticCutoutFrame + exact CP1 BodySnapshot
       ↓ no raw CV/Metal object or pointer crosses this boundary
MainActor UploadStore
  one replaceable latest frame → one encodeAndSubmit transaction
  → scoped Data access, memcpy into two fixed shared MTLBuffers
  → same-device blit to hidden RealityKit back textures
  → store registers completion and commits once
       ↓ GPU terminal callback carries only token/status/error/timing scalars
MainActor completion
  release independent staging pins; reject cancellation/incompatible context
  → set full-canvas size/position, displayed BodySnapshot and front/back visibility
  → same-frame debug dots updated synchronously, without suspension
```

Two deterministic **512×768 BGRA8** images per frame have different slot colors, four asymmetric corner markers, changing eight-bit frame bars, zero-RGB/zero-alpha padding and alpha-128 edges. P2's visible content is shorter using the same game scale; it is not normalized to P1's height. These are test rectangles, not generated human silhouettes or segmentation claims.

The real `PlayerID`, BodySnapshot, geometry, layout, calibration/provider context definitions are compiled directly with the spike. Generation/frame/capture/camera/calibration provenance stays in the immutable snapshot. Capture timestamps are deterministic `frameID / 60` fixture seconds, **not live host-clock measurements**. No CP1 stream/status subscription or latestSnapshot sampling occurs.

Representative experimental interfaces, not a finalized production contract:

```swift
actor SyntheticProducer {
    func produce(frame: UInt64, generation: UUID = spikeGeneration) throws -> SyntheticCutoutFrame
}
@MainActor final class UploadStore {
    func offer(_ frame: SyntheticCutoutFrame) throws -> Bool
    func encodeAndSubmit(
        gate: (any MTLSharedEvent)? = nil,
        failBeforeCommit: Bool = false,
        completionFailureForTest: Bool = false
    ) throws -> UUID?
    func result(_ token: UUID) async throws -> UploadResult
    func cancel(_ token: UUID)
    func cancelPending()
    func setContext(_ new: BodyInputContext)
}
```

The test gates/failure knobs are experimental controls, not proposed public CP2 operations. Acquisition is internal to the synchronous pending→upload transaction; this spike does not implement the production consumer/lease observer API.

### Device and format

Create all four persistent LowLevelTextures, then use `texture.read().device`; verify every P1/P2/front/back resource agrees. The queue and staging buffers come from that **actual backing device**, Apple M5, registry ID 4294969048. No imaginary RealityView.device or independent-default-device assumption. A probe also found the default device, but it is not the source of upload ownership.

The requested `.bgra8Unorm_srgb` destination (format 81) accepted buffer-to-texture blits. Two-player exact GPU readback passed for packed stride 2048 and padded stride 4096. The blit preserves bytes; it does not unpremultiply or convert color. Core Video is CPU-backed here, so **no CVMetalTextureCache/IOSurface source mapping is used or claimed**. The previous IOSurface allocation failure is not bypassed with shared raw buffers; the Data candidate simply does not require that bridge.

Apple's [LowLevelTexture contract](https://developer.apple.com/documentation/realitykit/lowleveltexture) and [buffer-to-texture blit API](https://developer.apple.com/documentation/metal/mtlblitcommandencoder/copy(from:sourceoffset:sourcebytesperrow:sourcebytesperimage:sourcesize:to:destinationslice:destinationlevel:destinationorigin:)) informed the SDK inspection; actual results above are from execution.

## 4. Bounds, lifetime, cancellation and failures

- **One producer call at a time**, two-buffer source pool threshold; dimensions/stride/count arithmetic checked. No Data(bytesNoCopy:), escaped source/Data pointer, unchecked Sendable, unsafe isolation, preconcurrency suppression or detached task.
- **One pending combined frame**, replaced only by a higher compatible frameID. Taking it does not reset the watermark. Calibration changes preserve that watermark for the unchanged source generation/camera; a new generation/camera resets it. The demo also admits only one production call while a UI action is suspended.
- **One submitted upload globally per store**, including after context changes. A busy store cannot reuse staging. Offers replace pending while its GPU job is blocked. Tests produced 17 subsequent image pairs while the first upload was explicitly gated; none needed GPU completion to recycle the producer's source pool. This is independent scheduling, not a real-camera/CP1 contention benchmark.
- **Two preallocated shared MTLBuffers**, each 4096×768 bytes: **6 MiB staging total**. Packed uploads copy 3 MiB/pair; padded uploads copy 6 MiB/pair. Readback tests allocate another fixed **6 MiB**, disabled in the visual host. No synchronous GPU waits or image painting on MainActor; the measured Data→staging memcpy is on MainActor.
- Four logical BGRA textures occupy **6 MiB**, excluding RealityKit versioning/caches. At most three pipeline Data pairs can be in producer/pending/upload ownership: 9 MiB packed or 18 MiB at the allowed padded maximum. Raw producer pool reservation is separately bounded to 3 MiB packed / 6 MiB padded. The assertion driver deliberately retains reference fixtures for comparisons; these pipeline bounds are **not a measured whole-process RSS or framework-allocation bound**.
- A checked MainActor `StagingPin` retains the buffers through terminal completion **even if the UploadStore is destroyed**. The callback transfers only a reference to that actor-confined lifetime owner plus Sendable result scalars; it never transfers a mutable Metal value. Its release is fileprivate. A real shared-event test destroys the store while the GPU is blocked, verifies its independent pin still owns two staging buffers, then signals and observes release.
- Cancel before submit clears pending and commits nothing. Cancel after submit only revokes display permission. The actual GPU readback stays correct and the busy slot remains occupied until completion. No timeout/forced reclaim exists. A truly missing terminal callback retains the bounded pins; safe automatic recovery is not proven.
- Context replacement immediately hides incompatible displayed slots, discards pending and checks current CP1 context again at completion. Removing P1 still allows unchanged P2 to activate. An old-generation completion cannot activate even when P1/P2 labels and frame numbers are reused.
- Old/duplicate callback tokens cannot settle a replacement upload. The test replay hook refuses the active token, so it cannot forge GPU completion. One last result replaces any older result; there is no growing completion history.
- **Pre-commit throw after P1 replace:** end the encoder, do not commit, detach/retire the affected hidden back and create a fresh hidden replacement. The existing front remains visible. A subsequent real upload/readback succeeded. This proves this tested queue recovery; repeated-abort framework memory/visual behavior is not certified.
- **Per-slot absence:** a combined frame with no P1 imagery uploads/activates P2 using the exact original snapshot. The old P1, if compatible, keeps its original provenance; no fake new-frame P1 is manufactured. Production hold/pictogram expiry is not implemented here.
- **Terminal error branch:** a software-injected failed acknowledgment occurs only **after actual GPU completion**, suppresses both slots and releases staging. **No real Metal GPU fault was induced**; driver-loss/device-removal/error recovery remains unvalidated. One command buffer has one terminal status; the adapter conservatively avoids activation of all its submitted slots on failure.

## 5. Compiler and deterministic verification

All final positive native core and visual SIL/builds use Swift 5, complete strict concurrency, warnings-as-errors, default MainActor and the applicable approachable-concurrency features plus MemberImportVisibility. SIL emission/WMO is required; typecheck-only success is not counted. The core also compiles/links for arm64 iOS 26.5 Simulator with the same checks. No permanent setting changes.

The retained original writer-after-transfer **negative control is rejected on both platforms**, with `sending 'value' risks causing data races`. No relevant warning/error remains in the final positive spike logs. Runtime safety is independently checked rather than inferred from compiler acceptance.

**16/16 standalone assertion groups passed, zero failures/skips**:

1. Independent BGRA/premultiplied/transparent anchors and full immutable byte verification after source reuse.
2. Actual same-device sRGB upload and full P1/P2 pixel readback.
3. Actual 4096-byte padded source rows without row bleed.
4. Shared-event GPU gate: submitted cancellation, pinned staging, latest replacement and independent producer progress.
5. Late/duplicate frames and stale callbacks rejected after acquire.
6. Full calibration-context replacement: P1 removal, P2 compatibility and no watermark regression.
7. Cancellation before submission, with no extra commit.
8. Failure after first hidden replace: no commit, quarantine and successful subsequent upload.
9. P1 unavailable/P2 success with original combined provenance.
10. Generation invalidation during actual GPU work, then new-generation restart.
11. Injected terminal failed acknowledgment after a real fence; no activation of either slot.
12. Numeric full-canvas sizing/translation, asymmetric padding, lane reflection and one shared scale.
13. Repeated front/back uploads: five warmup + thirty measured pairs, balanced commits/completions.
14. Completed store/staging cleanup.
15. Store destroyed with GPU work still gated: independent completion-owned pins remain until the fence.
16. Ready-image admission rejects absent accepted calibrations and uncertain body identity, independently of individual joint validity.

The primary test store recorded **45 commits and 45 terminal completions**, peak one in flight and 22 intentional drops/rejections/supersessions. Two additional one-upload cleanup/teardown stores also completed: **47 actual submitted command buffers across the assertion executable**, including the injected failed acknowledgment (whose actual GPU work completed). No unsubmitted failure was counted as a commit. These are standalone assertion groups, not 16 newly registered Swift Testing tests.

### App and existing regression suite

- Unchanged Sedactive Simulator app build: **BUILD SUCCEEDED**.
- Existing test-target build: **TEST BUILD SUCCEEDED**.
- Existing Simulator suite: **64 registered tests in 9 suites; 131 executions including parameters; 0 failed / 0 skipped / 0 expected failures**. All four CP1 suites, smoke test and current gameplay/render-lifecycle tests passed. This supersedes the older historical 30/36 count; no test was removed or rewritten.
- No Swift compiler/concurrency warnings in these final logs. App/test builds emit the tooling warning `Metadata extraction skipped. No AppIntents.framework dependency found.` Simulator startup additionally logs RealityKit internal rematerial asset-path and missing-data-file messages; tests still pass. These are not silently relabeled as a clean runtime log, nor fixed by changing Kevin's code.
- Script sources/assets are outside synchronized app/test groups; existing source/fixture/asset hashes are unchanged. Successful CP1 replay tests exercise the existing bundled fixtures. No duplicate app source, new target or project reference is added.

## 6. Actual RealityView observations and limitations

The standalone **native Mac RealityView with virtual camera** uses the same surface creation/device/upload path. It is not Kevin's authored corridor or a physical iPad. It uses no production renderer file.

The first visual inspection discovered a **vertical UV inversion**, despite exact GPU bytes. Correcting the isolated mesh to bottom UV V=0/top V=1 made the four markers upright and brought the shorter P2 content into alignment with its crown/sole dots. U is horizontally mirrored once; full-canvas position is reflected about the assigned lane and entity scales remain positive. Padding retains the content's size and translation; P1/P2 are not swapped.

Inspected corrected frame 1, a sample during the switching run and final frame 91. The run ended with **91 commits/completions**, both displayed slots recording frame 91. Red P1 remains displayed-left, blue P2 displayed-right, with different heights; green beam is behind opaque player content and orange core/glow in front. Padding is transparent rather than an opaque full canvas. Screenshots retain only these synthetic images.

**Do not overstate this evidence:** screenshots are sparse, lossy JPEG UI observations. They cannot certify every intermediate rendered frame, lack of flicker, frame-atomic texture/geometry/overlay switching or physical scanout latency. SwiftUI accessibility and screenshot reads can sample different instants. Synchronous MainActor mutation is verified in code, not a RealityKit frame transaction guarantee. Secondary single-texture visibility gating and ModelSortGroupComponent were not implemented or compared.

**Alpha/color remains a review gate.** Opaque slot colors, transparency and fractional edges render, but a darker/desaturated fringe is visible around parts of the synthetic border, particularly against the light background. Do not declare halo/color accuracy passed. Exact sRGB texel readback proves encoded byte preservation, not that UnlitMaterial's sampling/blending correctly interprets our premultiplied data. No calibrated colorimetric comparison or straight-alpha reference was run. Keep tone mapping disabled and no opacity threshold in this candidate; Kevin must review the alpha/material convention before production. No ownership/carrier change or unreviewed shader workaround was made.

## 7. Measurements

Thirty sequential P1/P2 pairs after five warmup pairs; one short trial, optimized native executable, monotonic time, normal desktop activity without thermal/frequency isolation. Each normal pair contains 3 MiB of pixel Data. CPU painting and verification are outside these reported stages. The measured GPU command also includes **verification texture-to-buffer readback**, so these are not pure-upload or production-render benchmarks. The visual host disables readback but its UI timings are not a controlled benchmark.

The exact p50/p95 values and per-sample data are in `Results/gpu-results.json`; the final numerical summary is recorded alongside this report below. No maximum FPS, physical-iPad budget, thermal result or end-to-end camera-to-display latency is inferred. No calibrated process-memory profile was run.

| Stage, per two-player pair | Samples | p50 ms | p95 ms |
|---|---:|---:|---:|
| Producer explicit Data copy (off MainActor) | 30 | 0.2827 | 0.3912 |
| Data → fixed staging copy (MainActor) | 30 | 0.0644 | 0.0797 |
| Submission → MainActor completion | 30 | 0.4660 | 2.7108 |
| Metal GPU interval (includes readback) | 30 | 0.1106 | 2.1696 |

The MainActor staging copy is a real extra copy and a production review item, even if small on M5. Data is not zero-copy GPU upload. The earlier CPU-only benchmark used a different workload/measurement envelope; do not compare its copy timings as an optimization result.

## 8. Exact reproduction commands

From repository root, with appropriate local GPU/Simulator/macro-plugin access:

```bash
CP2_GPU_BUILD_ONLY=1 bash Scripts/CP2Spike/run-data-gpu-spike.sh
/private/tmp/cp2-gpu/final/gpu-tests /private/tmp/cp2-gpu/final/results.json

CP2_GPU_OUTPUT=/private/tmp/cp2-gpu/simulator \
CP2_GPU_PLATFORM=simulator CP2_GPU_BUILD_ONLY=1 \
bash Scripts/CP2Spike/run-data-gpu-spike.sh

bash Scripts/CP2Spike/build-data-gpu-visual.sh
open /private/tmp/cp2-gpu/final/CP2Synthetic.app
```

Click **90-frame switching sample** in the standalone host; inspect corners/dots/padding and front/behind beams. The finite cosmetic delay is not a correctness timeout. Unit correctness instead uses explicit GPU shared-event/continuation gates without sleep-based assertions. Correctness waits use explicit completion gates; visual button tasks and the 90-frame loop are finite, with one admitted production call. There is no per-capture detached-task stream.

Actual app/test commands:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/cp2-gpu/AppDerived build
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/cp2-gpu/AppDerived build-for-testing
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/cp2-gpu/AppDerived \
  -resultBundlePath /private/tmp/cp2-gpu/Regression.xcresult test-without-building
xcrun xcresulttool get test-results summary \
  --path /private/tmp/cp2-gpu/Regression.xcresult --format json
```

The destination was rediscovered as a booted iPad mini (A17 Pro), iOS 26.5, before use. Rediscover it when reproducing. Complete flags are in both scripts: Swift 5, complete checking, warnings-as-errors, SIL/WMO, default MainActor, NonisolatedNonsendingByDefault, InferIsolatedConformances, InferSendableFromCaptures, GlobalActorIsolatedTypesUsability, DisableOutwardActorInference and MemberImportVisibility. Only SDK/target change for the compile-only Simulator spike.

Sandbox-only native GPU probing trapped with exit 133; outside-sandbox execution succeeded on the M5. SwiftUI Observation macro plugin and Simulator/Xcode operations also needed normal outside-sandbox access. These were environment restrictions, not suppressed ownership diagnostics. Final binaries/logs and xcresult are under `/private/tmp/cp2-gpu/`; retained JSON/screenshots are under Scripts. Initial missing UI import, opacity literal and ambiguous Scene compile errors were corrected in new files before final checks. An initial Simulator link emitted a clang SDK-selection warning; explicitly selecting the matching xcrun SDK removed it. Final native/Simulator positive logs are empty.

## 9. Kevin/Edo/Jevon handoff and readiness

**What is now demonstrated:** checked immutable Data across the producer boundary; a compatible RealityKit-device/staging/blit path; bounded pending/in-flight work; explicit GPU fences and independent teardown-safe pins; actual native RealityView imagery/geometry; existing CP1 unaffected.

**Executable production CP2 contract cannot yet be finalized.** Remaining gates:

1. **Kevin + Edo:** review premultiplied-alpha/sRGB/material fringes, including a properly labeled straight-alpha reference if needed. Agree any conversion/material correction; do not infer a blit performs it. Confirm on target iPad and Kevin's authored scene.
2. **Kevin:** integrate P1/P2 front/back adapters, current world mapping, full-canvas UV/placement/debug updates and pictogram fallback into his production host only with authorization. Validate every-frame activation, transparent laser sorting/depth and pre-commit-abort behavior there. Preserve gameplay authority outside rendering.
3. **Edo + Kevin:** approve the actual Data descriptor/lease/store interface and global byte/admission bounds; split the experimental RK surface adapter from a RealityKit-independent shared upload store. This spike does not implement production claim/release/status delivery or edit the approved proposal.
4. **Jevon + Kevin:** agree the idle presentation-expiry/render-update hook, source-host-clock age and display-versus-selected-evidence diagnostics. No second CP1 gameplay consumer and no new gameplay clock. Synthetic capturedAt is not a test of live normalization.
5. **Device validation:** iPad CPU copy/staging cost, upload and rendered latency, real GPU error/driver loss, repeated lifecycle/abort memory retention, thermal behavior and actual camera/segmentation contention. No physical-iPad run occurred. Simulator execution here is regression testing, not visual cutout validation.

The Data-copy candidate is technically viable for the **next owner review**, rather than blocked at the prior raw-CV transfer compiler gate. It remains an investigation, not approval to implement live CP2/LH-14. Hold durations, capture-age limits, resolution/cadence and physical alignment/performance tolerances remain untuned. Live camera/Vision, identity association, calibration, gameplay and segmentation were not resumed.

Skills read/applied: Swift concurrency for isolation/checked transport; Swift Testing guidance for controlled async assertions and accurate separation of standalone checks from the unchanged Swift Testing suite. No automatic continuation, commit or push.

Retained evidence: [GPU results](../Scripts/CP2Spike/DataGPU/Results/gpu-results.json), [verification and source hashes](../Scripts/CP2Spike/DataGPU/Results/verification.json), [frame 1](../Scripts/CP2Spike/DataGPU/Results/visual-frame-1.jpg), [frame 91](../Scripts/CP2Spike/DataGPU/Results/visual-after-switching.jpg).
