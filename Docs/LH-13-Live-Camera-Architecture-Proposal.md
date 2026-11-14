# LH-13 — Live Two-Player Camera Input: Architecture & Implementation Proposal

**Owner:** Edo. **Reviewers:** Jevon (session/time/recovery), Kevin (display/geometry), Theo (instructions and visual design).

**Status: architectural direction accepted; targeted documentation refinement, 3 November 2026.** This revision authorizes no implementation. LH-13A0 is sufficiently specified for a separately authorized limited preflight; full LH-13A is conditional on configuration and diagnostics review. LH-13B, LH-22, LH-13C, LH-13D and full live CP2 integration are not authorized.

The initial audit was on `feat/cutout-handoff` at `5bb285f87270a875339f3ff44648ae42d725bfc5`. **This refinement finds the checkout already on `feat/camera-foundation` at `845b1997388051a3df4ede73c572820d7c2e642b`.** No branch was created or switched. Local HEAD's subject records a merge of PR #15, but remote PR approval/merge status and current remote staging freshness were not queried or verified. This is not a claim about GitHub's present state.

Only this existing planning document is revised. Current Swift takes precedence over stale implementation-status prose. Existing CP1/CP2 corrections, tests, rendering, project settings and untracked user work are preserved. Future implementation belongs exclusively on the separately established `feat/camera-foundation` branch after verifying its approved up-to-date staging base (§12); no LH-13 implementation belongs in PR #15.

## 1. Actual baseline audit

### Repository and settings

**Current refinement entry:** `?? Docs/LH-13-Live-Camera-Architecture-Proposal.md` and `?? Scripts/`; no staged/tracked modifications or unresolved merge entries. The proposal already exists locally but is untracked; editing it does not stage it. Current branch/HEAD are recorded above and will not be changed by this task.

**Initial-audit history:** the earlier planning pass began with only untracked Scripts. External CP2 edits then restricted presentation to acquired slot membership and added two regression tests. Those corrections are now present in local committed history (`98e589a`) below `845b199`; they are preserved. They do not resolve the removed-cutover finding below. The historical CP2 report's test counts are not new verification of those later corrections. No remote Git operation is needed for this documentation revision.

The existing app and root `SedactiveTests` targets use separate filesystem-synchronized source groups. Logical modules are `App`, `Games/LaserHeist` and `Shared`; no new package, target or global technical layer is needed. Test resources remain in the root test target.

Inspected `.pbxproj`: Swift 5.0, default MainActor isolation, approachable concurrency YES, MemberImportVisibility YES, deployment 26.5. Strict concurrency is not explicitly set in the project file. Do not change these settings. Generated Info.plist already includes `NSCameraUsageDescription` in Debug/Release. It does **not** request permission or implement capture. Current orientation settings allow portrait and landscape and the app still has iPhone configuration: an iPad/landscape operational plan is not proof those project restrictions already exist.

### Files inspected — presence is not completion

Paths in this table are relative to `Sedactive/`.

| File / area | Actual state | Implication |
|---|---|---|
| `Shared/BodyTracking/Capture/CameraPipeline.swift` | Comments + Foundation import only | No AVCaptureSession, permission handling or lifecycle. |
| `Shared/BodyTracking/Capture/FrameStore.swift` | Import-only skeleton | No bounded source ownership, source sequencing or retention policy. |
| `Shared/BodyTracking/Capture/PoseEstimator.swift` | Import-only skeleton | No live Vision body detection or adaptation. |
| `Shared/BodyTracking/Capture/PersonSegmenter.swift` | Import-only skeleton | No instance masks or pose-to-mask association, including calibration masks. |
| `Shared/BodyTracking/Processing/PlayerTracker.swift` | Import-only skeleton | No initial P1/P2 binding, association or reacquisition. |
| `Shared/BodyTracking/Processing/MotionEngine.swift` | Import-only skeleton | No live processing composition/history. |
| `Shared/BodyTracking/Processing/BodyMeasurementExtractor.swift` | Import-only skeleton | No crown/sole estimation or live coordinate conversion pipeline. |
| `Shared/BodyTracking/Processing/JumpDetector.swift` | Import-only skeleton | No airborne classification. |
| `Shared/BodyTracking/Processing/CalibrationSession.swift` | Import-only skeleton | **LH-22 processing is not implemented.** A comment saying “calibrates players” is not an algorithm. |
| `Shared/BodyTracking/BodyInputService.swift` | Import-only skeleton | No live provider conforming to BodyInputProviding. |
| `Shared/Players/Player.swift` | Implemented anonymous P1/P2 enum | No profiles, names, weights, selection roster or persistent player UUIDs. |
| `Shared/BodyTracking/Models/` | Five implemented CP1 files | Values, mapping, validity, revisions, provider/lifecycle contracts exist; calibration algorithms do not. |
| `Shared/BodyTracking/ReplayBodyInput.swift` | Implemented schema-2 replay, stream/cache/context/status/cutovers | Reference behavior for live-provider conformance; not a camera service. |
| `Shared/BodyTracking/Capture/PlayerCutout{Frame,Compositor,Handoff}.swift` | Implemented CP2 CPU handoff/copy/budget | No live segmentation/composition or production renderer wiring. Do not use its calibrated cutout packet as an uncalibrated raw camera-frame container. |
| `App/AppDependencies.swift` | Import-only skeleton | No replay/live factory or lifetime ownership yet. |
| `App/RootView.swift`, `App/SedactiveApp.swift` | ContentView opens PlayView; app creates ContentView | Neither replay nor live input is currently selected/injected through App. |
| `Games/LaserHeist/UI/PlayView.swift` | Implemented RealityView virtual-camera preview with scene/debug preview | Uses a virtual render camera; does not own an AVCaptureSession. Preserve Kevin's implementation. |
| `Shared/GameRuntime/GameClock.swift` | Implemented source-time advance/pause/resume and capture-to-game mapping | Reuse Jevon's clock; review live host-time anchoring, rather than implement another clock. |
| `Games/LaserHeist/Session/{GameSessionCoordinator,SessionState}.swift` | Import-only skeletons | Jevon's real start/calibration/pause/recovery orchestration is a separate integration dependency. LH-12 readiness is not established by this preview. |

### Tests and documentation reconciliation

- Four CP1 suites and four Cutout suites contain real Swift Testing tests. Active synthetic replay fixtures are schema 2 (`cooperative-v2.json`, `two-player-recovery-v2.json`); schema-1 resources remain historical. Replay and cutout tests cannot prove a live tracker works.
- `PlayerTrackerTests.swift`, `BodyMeasurementExtractorTests.swift` and `JumpDetectorTests.swift` are skeletons. There are no implemented camera, pose-estimator or calibration algorithm suites in the inspected tree.
- The CP2 Phase 1 report records **92 registered tests / 161 executions / 0 failures / 0 skips** and successful app/test builds. These are historical results, **not tests rerun for this planning task**, and not physical-iPad evidence.
- The canonical CP1 proposal still describes its anonymous migration as not yet implemented, while the actual code implements it. Its accepted semantics remain useful; its status/reconciliation tables are historical.
- The architecture reference/tree still mentions profiles/ordered selection and older fixture names. TEAM_ALIGNMENT has abbreviated Crown-only/mirroring-TBD summaries. The gameplay draft has old paths, roles/zones, missing test-target claims, Crown-only high rules, an older torso definition and the coarse “LH-22 before LH-13 starts” dependency. Use current anonymous types, Crown + both Wrists, the shoulder-midpoint-to-hip-midpoint torso reference and current Games/Shared paths instead. Do not edit those documents or redesign rules in this task.
- All six specifically requested documents are present. Applicable Architecture Reference sections and actual test/source files were also inspected.

### Concrete CP1 → CP2 integration mismatch found

**Static finding, not a newly executed failing test:** `ReplayBodyInput.setCalibrations` intentionally retains cutovers for removed players (`ReplayBodyInput.swift`, lines 179–183). `PlayerCutoutHandoff.updateInput` requires `context.cutovers.keys` to be a subset of accepted `calibrationRevisions.keys` (line 106). A legitimate full replacement that removes P1 retains P1's invalidation marker and therefore fails CP2 ingress validation.

Current cutout tests mostly construct their own context events and do not forward that complete real CP1 replacement sequence. Add a real-context bridge regression in a separately reviewed CP2 correction: empty → P1 → both → P2-only → empty → reacceptance. Preserve CP1 removal markers/cutovers; do not filter them out or change CP1 to satisfy the stricter CP2 guard. The smallest proposed correction is for CP2 to validate legitimate cutovers without requiring every marker to represent an accepted baseline. **No fix is made here.** This does not block camera/raw-pose work; it is a gate before live status is wired to CP2.

## 2. Scope and non-goals

LH-13 replaces the input provider, not the game rules. Its eventual deliverable is live, timestamped, calibrated two-player evidence through the existing `BodyInputProviding` API, integrated by the appropriate owners and demonstrated on physical iPad.

In scope across separately approved milestones:

- One front-camera AVCaptureSession lifecycle from Play-triggered setup/calibration through countdown/play and ordinary gameplay pauses.
- Permission, camera availability, source startup/shutdown/interruption and processing progress independent from frame delivery.
- Source generation/frame sequencing, canonical geometry/revisions and host-clock capture timestamps.
- Bounded source admission and two-person Vision 2D pose adaptation.
- Stable P1/P2 binding/tracking, per-measurement validity and conservative identity loss/reentry.
- Accepted standing calibration use; live crown/wrists/soles/center and JumpState; real CP1 publication.
- Replay/live dependency selection, with Jevon retaining the single gameplay reader and all game-time/recovery authority.

Not in scope: new gestures, perfect squat-form classification, collision rules/margins/windows, score/health/vault/diamonds, a second CP1 reader, new CP1 model fields, full live cutout/segmentation-to-renderer pipeline, Metal/RealityKit texture integration, UI redesign, another architecture, or project-wide settings changes. **LH-22 has its own implementation approval and acceptance gate.** Minimal segmentation needed to measure calibration boundaries belongs to that dependency; it is not authorization for full LH-14.

## 3. Proposed dataflow and responsibilities

```text
AppDependencies (one selected backend and retained live service)
  → BodyInputService: lightweight MainActor lifecycle / authoritative accepted context
       → CameraPipeline: off-main capture-session owner
            front video callback: metadata + bounded owned copy only
               → FrameStore: latest bounded raw-source handoff
                    → one background processing loop
                         PoseEstimator: Vision → existing PoseFrame plain values
                         PlayerTracker: bind/associate P1/P2
                         MotionEngine:
                           BodyMeasurementExtractor + accepted calibration + shared layout
                           JumpDetector: bounded temporal phase history
                         → immutable same-source BodySnapshot
                              → BodyInputService validation / cache / CP1 yield
                                   → Jevon's ONE continuous consumer/history/judge

Independent source notifications → BodyInputService status/context (no frame needed)
Internal source-status tee       → CP2 context ingress, only after its compatibility gate
Optional future same-frame tee  → separately bounded segmentation/cutout branch → CP2
```

`MotionEngine` interprets plain observations. It does not own or start a camera. `CameraPipeline` knows capture configuration but not lasers. Shared never imports Laser Heist/RealityKit. MainActor owns only lightweight control/context/cache/stream publication, not pixel copies, Vision, Motion or calibration computation.

| Component | Proposed responsibility |
|---|---|
| CameraPipeline | Authorization adapter, one session/input/output, serial configuration/start/stop, actual front-device selection, geometry fingerprint, source time conversion, notifications and capture adapter. |
| FrameStore | Private Capture-only immutable source payload/metadata, checked byte/retention budget, one latest pending source, capture watermark/drop counters and bounded worker wakeup. Not a camera history. |
| PoseEstimator | One serial Vision request execution per admitted image; convert all required joint values/confidence and source metadata to existing PoseFrame. No PlayerID assignment by result index. |
| PlayerTracker | Two bound tracks with bounded prior state; initial mirrored-position binding, unique association or explicit uncertainty/loss. No persistent human recognition. |
| CalibrationSession | LH-22 stable sample validation, independent standing estimates and source-keyed result/progress. Produces candidates, not authoritative accepted context or gameplay readiness. |
| BodyMeasurementExtractor | Accepted offsets/mapping → six independent EstimatedScalars. No hidden stale/other-limb substitution. |
| JumpDetector | Causal phase estimate using bounded captured-time history and accepted standing references; unknown when insufficient evidence. No low-laser verdict. |
| MotionEngine | Compose tracking/extraction/jump processing and reset their local histories on relevant context changes. |
| BodyInputService | LH-13C implements the existing provider exactly; sole authoritative accepted calibration/context owner; validates full replacements, commits revisions/cutovers, rejects stale work, publishes evidence/status and internally tees immutable source facts. |
| Jevon's Session | LH-13D starts/stops provider, requests calibration and submits intended full replacements; owns calibration phases, generation/layout, countdown/readiness, capture-to-game time, the sole gameplay reader and pause/recovery. Requesting acceptance does not make Session a second accepted-context store. |
| Kevin's renderer | Mirrors preview/cutouts/debug consistently, renders validity/pause reasons, consumes CP2 separately; no independent source or gameplay clock. |

## 4. Frame ownership, concurrency and bounds

### Proposed conservative first ownership boundary — requires Edo approval in LH-13A

Do not assume a camera CMSampleBuffer/CVPixelBuffer can be sent between actors because an example uses a dispatch queue or `sending`. CP2's pooled ownership results are a warning about alias topology, not proof that every fresh camera transfer is impossible.

**Recommended first candidate:** keep capture framework values inside the native callback/session ownership boundary. In the callback, synchronously normalize metadata, lock/read a supported BGRA source and make an explicit independent immutable byte copy into a **private Capture-only source envelope**. Send only those bytes and plain immutable metadata to one processing worker. That worker owns a separate bounded CV pool, reconstructs the image from bytes and executes Vision there. Mutable source CV, VNRequest/VNObservation and handler objects do not cross to MainActor or another actor. Convert results into existing Sendable PoseFrame values before leaving the worker.

This is a **new proposed raw-input technique**, not a claim that CP2 approval already selected it for camera capture. The two copies (camera → owned bytes, owned bytes → worker CV) are explicit. It prioritizes a defensible ownership boundary; it has an important CPU/memory cost and needs a measured admission gate. Do not confuse raw BGRA Data with encoded JPEG/PNG: `VNImageRequestHandler(data:)` must not be given unencoded BGRA. Use the worker-owned CVPixelBuffer initializer.

Keep supporting types in `FrameStore.swift`; do not add a public raw-frame API to CP1 or reuse CutoutImage (which requires calibrated image provenance). Use checked sizing, actual source/destination strides, balanced locks and immutable private byte storage. Read/copy only in scoped access; no escaped addresses/no-copy aliases. Retained source-envelope references must stay charged until their final owner releases them.

The capture adapter should be a narrow explicitly nonisolated NSObject delegate with no actor-isolated mutable processing state. Its framework callback only uses scoped sample access plus synchronized Sendable admission/metadata state. Camera/session mutation belongs to an off-main serial actor/owner. Immutable configuration epochs prevent an old delegate/notification from using a new context. **Exact delegate, actor and clock-reference signatures are a compiler gate**, not proven by this Markdown. No unsafe executor assumption is needed for the proposed byte-copy crossing.

Before extending the candidate, compile with existing Swift 5/MainActor/upcoming-feature conventions plus temporary complete checking and warnings-as-errors/SIL. Include a negative control for retained mutable camera-workspace access. If even the small bridge requires suppression, stop and revise the topology. No unchecked Sendable, `nonisolated(unsafe)`, preconcurrency suppression, pointer ownership tricks, blind detached tasks or actor-per-file design.

If the bounded raw-copy cost is unacceptable on iPad, review a same-executor capture/Vision alternative in a focused follow-up. Synchronous Vision on the delegate queue can use AVFoundation late-frame dropping, but prolongs callbacks and complicates status responsiveness/overlapping image work. Do not silently adopt that alternative, send pooled CV references unchecked or claim zero-copy performance. The first milestone measures this tradeoff before building tracking on it.

### Admission and scheduling

- Set `alwaysDiscardsLateVideoFrames = true`. This bounds the AVFoundation output backlog, **not** the application's later queues. [Apple TN2445](https://developer.apple.com/library/archive/technotes/tn2445/_index.html) recommends late-frame dropping for this kind of realtime output.
- In FrameStore, admit at most one raw copy in construction, one latest pending immutable source and one source currently being processed. Reserve byte/count limits before copying; replace/drop pending without waiting for a reader. Allocate no per-frame Task, dispatch block backlog or camera history. A small synchronized mailbox/continuation may wake one owned long-lived worker.
- The callback does no Vision, segmentation, MainActor wait, GPU wait or consumer wait. The unavoidable copy is bounded by a configured format/byte ceiling; measure callback p50/p95 and dropped-source rate. “Short” is an acceptance measurement, not an unproven adjective.
- Use one worker loop and await its lightweight publication acknowledgement before admitting its next result. This prevents an unbounded MainActor result queue. Capture continues replacing the latest pending source while the worker is busy. Motion receives only plain values and bounded history.
- Start with fixed supported source dimensions and a single processing job. Pixel format, resolution, target capture rate, byte ceilings and expected pose cadence are measured choices, not production guarantees. For perspective, 1280×720 BGRA occupies 3,686,400 bytes before stride padding; this is an example, not an approved preset.
- Count capture drops, admission replacements, processing rejects, context drops and CP1 stream overflow separately with saturating counters. An output overflow/drop never directly causes HIT, CLEAR or pause.
- A future segmentation branch must have its own latest admission/job limit and a reserved/partitioned source-retention budget so it cannot exhaust the body path. It may share an immutable bounded source envelope with its exact snapshot, not raw mutable CV resources. Skip cutouts first under image pressure; CP1 publication cannot await segmentation or a renderer lease. Extra retained source frames and reconstruction costs must be accounted before adding that branch.

### LH-13A initial operating configuration — review gate before full capture

Keep this Capture-internal configuration separate from the existing BodyInputConfiguration; do not add hardware fields to CP1. A0 may check SDK signatures/ownership with small synthetic inputs without selecting a hardware preset. **Full LH-13A cannot choose unresolved values ad hoc.** Record Edo's approved experimental configuration and actual negotiated device output before enabling the camera path.

| Decision | Proposed experimental default / policy | Approval or measurement required |
|---|---|---|
| Device | Front-facing built-in wide-angle camera preferred, subject to actual discovery/support. Never silently use the rear camera, microphone or an AR capture session. | Edo approves supported front-device order. If the preferred front device is absent, initially report unavailable; an alternate front device (for example ultra-wide) needs explicit approval and a new geometry fingerprint. |
| Source pixel format | Prefer `kCVPixelFormatType_32BGRA` when advertised by the output; validate the actual pixel format on receipt. | Unsupported format fails configuration/admission explicitly. No silent YUV interpretation/conversion or format fallback; an alternate adapter requires review. |
| Resolution/preset | One fixed supported preset/format. 1280×720 / `.hd1280x720` is only a **candidate**, not a selected default or SDK guarantee. | **Exact initial resolution/preset requires Edo approval before full A.** Confirm device support and upright output dimensions; no automatic higher/lower-resolution fallback. |
| Capture FPS | Fixed supported rate. 30 FPS is an experimental candidate, not an approved rate or delivered-pose guarantee. | **Exact target requires Edo approval before full A.** Check supported frame-duration ranges and applicable automatic-rate settings; record actual capture and processed rates separately. |
| Per-frame raw byte ceiling `B` | Finite positive cap on checked `bytesPerRow × height`, including padding; reject invalid/overflow/over-cap descriptors before owned allocation/copy. | **Exact B requires Edo approval** after proposed format/stride bounds. Tight 1280×720 BGRA is 3,686,400 bytes; that figure is not a stride-inclusive cap. |
| FrameStore work counts | Experimental default: at most **1 construction + 1 latest pending + 1 processing** raw-source envelope. No per-frame Tasks/queues; `alwaysDiscardsLateVideoFrames = true`. | Edo confirms this bounded initial topology; any increase needs a reviewed count/byte budget. Driver-owned capture buffers are separately accounted, not described as controlled by FrameStore. |
| Total retained source bytes | Proposed raw-copy budget at most `3 × B`, using checked multiplication and last-owner accounting across cancellation/context changes. References to one backing allocation are counted once; all outstanding owners keep its reservation live. | Approve B and the total together. Retired/preview-held sources consume this budget; do not allocate a new budget on restart to evade old readers. |
| Reconstructed source CV | A later Vision/reconstruction workspace has its own finite count/stride-inclusive byte cap; initial serial candidate is one checked-out reconstructed buffer, kept until all handler use ends. | Edo approves actual pool/byte limits before reconstruction is used. This is **additional** memory, not covered by raw Data's `3 × B`. LH-22 cannot add a second pool/branch without revising the accounting. |
| Preview retention | Same retained CameraPipeline/session. Any image retention is charged to the source budget; any independent preview copy has an additional finite reviewed budget `P`. | Edo agrees diagnostic resource limits; Kevin reviews orientation/mirroring. Numeric-only A0 diagnostics need no image-retention budget. No unbounded SwiftUI image backlog. |
| Diagnostics | Saturating separate counters for AV drops/reasons, pending replacements, source-budget pressure, stale/context drops and processing rejects. CP1 delivery overflow stays separate. | Validate deterministically; no image/pose archive or participant data in logs. |
| Latency/rate observation | Monotonic callback total/copy p50/p95, source-to-worker wait, processing duration and capture-to-completion latency; effective source/processed FPS, drop ratios and current/peak retained bytes. | In A, processing can be a labeled controlled sink/copy path; **not** a Vision benchmark. B adds actual Vision timing. No fabricated results or threshold. |

Application-owned retained pixel payload accounting must include raw copies, reconstructed CV storage, any calibration-branch sources/masks and independent preview copies. At A's initial topology the estimate is `≤ 3B + reconstructed-workspace cap + P`, with allocation/driver/framework overhead measured separately. Every enabled term must have an approved finite cap; this formula is not a whole-process memory guarantee. Reserve primary tracking capacity before allowing optional preview/calibration retention; skip optional work under pressure rather than starving body input. A shared immutable source can have multiple owners but cannot be force-reclaimed while one is reading.

**Initial physical-iPad acceptance record:** approved configuration and negotiated camera/format/dimensions/stride/FPS; actual callback copy/total latency and source/sink latency distributions; source/processing rates and each drop reason; peak owned source/workspace/preview counts and bytes; cleanup after stop/cancel/restart; main-actor responsiveness and interruption delivery with no images. Test a documented finite observation interval and device/OS/thermal conditions agreed by Edo before the run. One session, correct orientation/mirroring and enforced bounds are correctness gates. Numerical latency, sustained throughput/drop/thermal limits are **production acceptance thresholds still requiring measurements and review**, not values this proposal invents. Full A is not considered accepted merely because it compiles; report the measurements for Edo's review.

The capture-only diagnostics route borrows the **same retained CameraPipeline and AVCaptureSession** from its owner. It must never instantiate another session in a view/preview/observer. Show capture status, generation/frame/time/geometry, orientation/mirror state and bounded performance counters, explicitly labeled **capture only — not calibrated gameplay readiness**. Kevin reviews the effective preview/mirroring transform; neither this route nor A0 authorizes edits to his PlayView or production renderer. The DEBUG-only entry and its Swift owner must be agreed before full A.

## 5. Source provenance, clock and geometry

### Observation identity and order

Jevon supplies the input sessionGeneration. CameraPipeline assigns a capture-sequence frameID before application admission, not after Vision finishes. All samples in one BodySnapshot refer to that capture. Gaps are allowed. AVFoundation's dropped-sample callback has metadata but no pixels; count it and use one documented sequencing policy (recommended: consume a sequence slot for delivered drop callbacks too). It is not a promise to count invisible sensor exposures.

Do not manufacture a BodySnapshot on a timer to represent an interruption. Do not combine last-frame wrists/soles with a new crown. Preserve original metadata throughout FrameStore → PoseFrame → measurements → BodySnapshot and any future CP2 frame. Serial Vision processing is the initial default; late old-generation/configuration work is rejected regardless of completion order. CP1 remains completion-order delivery with a highest-compatible-frameID latest cache, so do not change its out-of-order contract to fit this first serial implementation.

The live provider need not copy replay's finite fixture scanning into a realtime duplicate detector. One serial worker plus frame/configuration gates and a bounded recent identity check can reject duplicate work without retaining whole-round observations. Jevon owns his separate evidence-history deduplication.

### Capture time normalization — SDK-confirmed direction

The installed `AVCaptureSession.h` explicitly says capture-output timestamps use `synchronizationClock`. Obtain the sample presentation timestamp with `CMSampleBufferGetPresentationTimeStamp`; use the actual session synchronization clock as the source of `CMSyncConvertTime` and `CMClockGetHostTimeClock()` as the target. Convert the resulting valid numeric CMTime into CP1 `capturedAt: Double` seconds. Verify the actual clock is available and its relationship established. Use the supported current clock, not deprecated masterClock or an invented Date offset. [Apple synchronizationClock documentation](https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock).

Reject/diagnose invalid, indefinite, nonnumeric or incompatible clock values with existing `clockNormalizationFailure`; never replace capture time with callback/Vision completion time. Jevon anchors these host-clock seconds to GameClock and handles pauses; Edo does not rewrite timestamps. Kevin's independent freshness clock reads Core Media host time on MainActor. Tests inject source time/clock conversion, including nonidentity offset/rate cases; merely assigning identical synthetic times does not test normalization.

### Canonical orientation and revisions

Recommended initial operational mode: a mounted iPad and a reviewed landscape orientation, while leaving current project orientation settings untouched. Explicitly control the data-output connection's supported rotation and mirroring. Disable automatic video mirroring on the data connection and set its mirror state false when supported. Prefer physically upright data-output buffers and a matching `.up` Vision orientation, then validate actual dimensions/markers. If an alternate orientation path is necessary, document its exact transform and apply it once, not both to pixels and observations.

The installed SDK warns that some newer iPad front-camera defaults use a 180-degree videoRotationAngle. Never assume the default is 0 or hard-code an angle from a different device. `isVideoRotationAngleSupported` must guard assignment. Do not use deprecated videoOrientation examples unchanged.

Canonical numeric evidence is bottom-left normalized X-right/Y-up; raw raster row order is a separate descriptor fact. Vision's normalized point convention must be tested using asymmetric corners and anatomical left/right wrists/ankles. Preview/cutout/overlay mirroring belongs in display, once: initial displayX = 1 − canonicalX, so initial P1 is normally at larger canonical image X. After binding, that relation is not an ongoing identity rule. Kevin reviews lane-local mapping; do not globally flip the world.

Geometry fingerprint includes actual camera/device/format, upright dimensions/aspect, rotation, measurement-affecting crop/zoom/stabilization/framing changes. Any incompatible change advances cameraGeometryRevision, clears accepted incompatible calibration/processing history and reports context without requiring another frame. Do not reset frameID within the generation. Shared layout changes or deliberate person rebinding require a new generation.

Review disabling dynamic framing/Center Stage and stabilization for the calibrated local mapping, respecting supported device/configuration controls. These can change effective crop even if output dimensions stay constant. No silent auto-rescaling baseline. Detect supported configuration changes; do not claim image dimensions alone detect physical iPad movement. A fixed mount, scale/torso drift checks, explicit invalidation/recalibration and device review are needed. An automatic IMU/camera-motion system is not included without a separate requirement.

## 6. LH-22 dependency analysis

**Actual status: standing-calibration values and validators exist; the sampling/estimation algorithm does not.** Synthetic fixture calibrations are not valid live baselines. LH-13A and LH-13B can proceed without LH-22 because source frames and PoseFrames exist before calibration. Those milestones must be labeled capture/raw tracking, not live gameplay.

| Evidence | Required real calibration/input | Before a compatible accepted baseline |
|---|---|---|
| Crown Y | Live nose + `headOffsetFromNoseShare * standingBodyImageHeight`, then floor/shared mapping | Unavailable; no constant generic head offset or borrowed ear offset. |
| Left/right sole Y | Matching live ankle minus its independent foot-offset share × standing height, then mapping | Each unavailable independently; never use whole-mask bottom as both soles. |
| Wrist Y | Direct live anatomical wrist + floor/image-to-plane mapping and shared scale | Raw PoseJoint X/Y may exist; canonical BodyGeometry still notCalibrated. No standing wrist-height calibration. |
| centerX | Valid hip midpoint + per-player origin/aspect + shared layout | Raw hip midpoint may exist; mapped center unavailable. |
| JumpState | Compatible standing hip/foot/floor/scale references + valid causal temporal evidence | Unknown/notCalibrated; foot clearance alone does not establish airborne. |
| Drift/readiness | Standing torso/body references + stable identity + camera geometry | No invented trusted distance or gameplay-ready flag. |

LH-22 requires reliably associated mask/head/foot observations to establish crown and independent sole offsets. Therefore it also depends on **minimal person-instance segmentation and pose association for calibration**. `PersonSegmenter.swift` is a skeleton; CP2's Data copier is not segmentation. This dependency must be implemented/reviewed before declaring real standing results valid. Authoritative live-provider acceptance is a later LH-13C gate. Calibration masks can be calibration-only/rate-limited; continuous live cutouts and Kevin's textures remain outside this dependency.

### Same-frame pose/mask provenance and bounded source ownership

Whenever a pose and mask are jointly used for one standing sample, both must come from the **same captured source** with equal sessionGeneration, frameID, capturedAt and cameraGeometryRevision, plus compatible normalized dimensions/orientation. A mask instance index is not PlayerID: pose-to-mask-to-bound-slot association must also be reliable. Equal timestamps alone or a “nearby latest” frame are insufficient. Never pair pose A with mask B to fill a missing result. Reject/skip an incomplete, stale, mismatched or ambiguous calibration sample with a reason.

A stable calibration window may aggregate many samples; each contributing pose/mask pair independently passes that exact-source rule. The final PlayerCalibration sourceFrameID/capturedAt still describe the last accepted contributing frame, not a claim that the whole baseline came from one image. Keep pending pair/join state bounded and discard unmatched results when their source is retired or context changes; do not retain a window of raw images to implement the numeric standing aggregate.

| Approach for LH-22 | Ownership and benefits | Tradeoff / primary-path protection |
|---|---|---|
| Same-worker pose + calibration mask | One worker retains the immutable source and its worker-owned reconstructed CV/handler while computing both results for that selected frame. Exact-source pairing is straightforward, with no cross-actor mutable buffer/handler transfer or duplicate reconstructed source. | Segmentation consumes that worker's time and can reduce pose cadence. Release handler/source only after both uses finish, then reuse the pool. Rate-limit/skip optional calibration-mask jobs; do not delay an already-completed primary pose/body publication waiting for a mask. Admit this option only if measured primary tracking cadence/responsiveness meets reviewed requirements; bounded memory alone is not proof of adequate cadence. |
| Separately bounded calibration-mask branch | Retain the **same immutable source envelope** under its existing reservation and reconstruct a separate CV on the segmentation owner. One active mask job + one replaceable latest pending candidate is the initial candidate, with a finite join/output bound. Return plain same-source mask measurements/association results, not raw mutable Vision objects. | Extra retained sources, reconstructed CV storage, mask output and association/join state require explicit count/byte limits and a reserved primary-path budget. No body completion/publication awaits this branch. Drop pending mask work under pressure; after cancellation/context invalidation discard results and release only when actual readers/requests finish. Separate workers still share CPU/memory hardware, so scheduling isolation is not proof of no contention. |

Neither topology is selected for production by this refinement. **Before authorizing LH-22 implementation**, Edo reviews/chooses the smallest suitable approach, its budgets/rate policy and the pose/mask result seam. Kevin reviews coordinate/association interpretation; Jevon reviews calibration-phase expectations and progress/cancellation integration. If same-worker execution cannot protect reviewed tracking cadence, choose/review the bounded branch rather than add an unbounded queue. No new framework abstraction is required.

**A/B prerequisites for either option:** retain an immutable source stamp and scoped source ownership through the admitted operation; make raw PoseFrame metadata exact; provide a bounded optional-source admission capability with explicit release/context invalidation if a branch is chosen later. A proves source-copy/lifetime bounds; B proves source→pose correlation. They may use controlled placeholders to test these ownership capabilities, but **do not implement segmentation, mask association, joins or a second production branch prematurely**. Any later branch adds its declared memory/work budget to §4 before it runs.

PoseFrame already supports optional mask extents and localized foot bottoms. A whole-person `maskTopImageY` is insufficient to guarantee a head top when hands are raised. Use a standing hands-down gate and a localized head-region estimate with a reliable association. If necessary, keep a private source-keyed standing-observation value inside CalibrationSession rather than silently changing the approved PoseFrame contract. Any genuinely necessary shared-field extension gets separate review first.

Standing aggregate output retains slot, generation, camera revision, last contributing source frame/time, independent standing crown/soles/hips/height/torso, nose-specific head offset, independent foot offsets and mapping. Shared scale stays in PlayerPlaneLayout once; do not normalize both people to equal standing heights. Shoulder-midpoint-to-hip-midpoint torso length follows the accepted current contract, superseding older neck/hip backlog wording.

### Output, acceptance and session orchestration — distinct gates

| Milestone | Owns and proves | Does not require / must not own |
|---|---|---|
| **LH-22: Edo's calibration algorithm** | Produce independently validated real P1/P2 standing results using existing PlayerCalibration values, with reliable same-source pose/mask association, stability/confidence and generation/camera/source provenance. Deterministic algorithm/rejection tests can run with a controlled driver. | No fully implemented BodyInputService, authoritative accepted dictionary, cache invalidation, provider cutover transaction or game-phase machine. Producing a valid candidate is not accepting it for gameplay. |
| **LH-13C: Edo's live provider integration** | Own the sole authoritative accepted context; validate candidate results again against the current request/source context; apply atomic full replacement, monotonic per-player revisions, cutovers and stale-result rejection; publish CP1 evidence under that accepted context. | No dependency on Jevon having implemented a calibration screen/session. A controlled caller can exercise the real provider API and acceptance tests. |
| **LH-13D: Jevon's session integration** | Enter/leave calibration phases, request/cancel calibration, decide which complete intended dictionary to submit through existing setCalibrations, observe acceptance and enforce tracking/readiness, countdown/pause/recovery and GameClock behavior. | No second accepted calibration store, calibration estimator or provider cutover implementation. Session controls requests/gameplay; BodyInputService controls acceptance/context. |

**Prerequisite seam agreement before LH-22:** Edo and Jevon agree the minimal request/progress/result/cancellation boundary using existing PlayerCalibration results and exact request/generation/camera/source metadata. Specify how proposed revision values are supplied/allocated, how stale/canceled requests are identified and who submits the complete intended dictionary in D. A proposed result revision is not proof of acceptance; C still enforces current-context/monotonic-revision rules. Kevin reviews mapping/preview implications, and a production calibration UI implementer must be assigned separately. Exact signatures remain to be reviewed; this proposal does not silently add a protocol, accepted-state flag or early provider implementation.

LH-22 uses a small controlled request/result driver with deterministic context/revision inputs to prove algorithm correctness, not a fake live provider or fixture baseline passed off as real calibration. C's conformance tests then exercise acceptance through the actual existing BodyInputProviding API; D connects Jevon's real requests/phase flow. These are forward-only dependencies.

**Unchanged CP1 acceptance requirement, to be implemented/tested for the live provider in C:** accept dictionaries atomically in full: empty → P1 → P1+P2 → P2-only intentionally removes P1. Validate first; invalid replacements leave the entire existing accepted context unchanged. Unchanged retained baselines keep revisions/cutovers; changed/removed baselines invalidate incompatible evidence, including retained removed-slot markers. Only newly captured observations after the cutover may use a changed/reaccepted baseline. This requirement is not weakened or moved into the LH-22 estimator.

### Dependency order

1. **LH-13A:** camera/control/owned frame foundation and ownership compiler gate.
2. **LH-13B:** raw two-person pose and stable binding/tracking, with unavailable mapped evidence.
3. **LH-22:** independently validated standing results and same-frame calibration masks/progress; algorithm proof via a controlled driver, no live-provider acceptance dependency.
4. **LH-13C:** integrate approved results into the authoritative live provider, atomic replacement/revisions/cutovers → real measurements + jump state → CP1 publication.
5. **LH-13D:** Jevon's calibration requests/phases/readiness and Kevin/App integration, then real two-player round/recovery validation.

A/B are foundational preparation explicitly proposed by this decomposition, not completion of the backlog's “LH-22 before live play” condition. **LH-22 has no prerequisite edge back to C or D:** its output seam is agreed beforehand and tested with a driver; authoritative acceptance is first implemented in C; session requests/readiness in D. LH-13D also requires an actual replay-playable session/evidence integration (LH-12/LH-08–10); the current session skeleton cannot satisfy it. CP2 review/renderer work need not block A/B or pure body evidence, but cutout display remains a separate end-to-end gate. Every milestone still needs separate approval (§12).

## 7. Two-player association and measurement policy

### Binding and tracking proposal

- Bind two eligible, distinguishable people in the **mirrored preview's** intended positions during calibration. Reject/continue waiting if extra people or ambiguous placement prevent a unique assignment. Do not pick the first two observations or infer parent/child from height.
- Keep two bounded track states. Associate using multiple confident torso/hip/shoulder points, continuity/predicted displacement and scale/shape consistency under capture-time deltas. Evaluate both possible assignments and require a unique sufficiently separated match. Thresholds/hysteresis are device-tuned; X position or stature alone is not identity proof.
- Candidate IDs and Vision result order/observation identifiers are not promised persistent person IDs. Reordering candidates must not reorder slots.
- People crossing, partial occlusion, missing joints or a third entrant must produce uncertain/lost state when uniqueness cannot be supported. Extra observations may be ignored only when the established tracks remain uniquely attributable. Bound candidate processing; if its reviewed cap is exceeded, fail association conservatively rather than silently truncate to two identities.
- After short loss, restore an ID only with sufficient unambiguous continuity. If identity cannot be recovered, report uncertainty and let Jevon request explicit recalibration/rebinding. A different person cannot inherit an old calibrated slot silently; deliberate replacement starts a new generation.
- Reset temporal jump/measurement filters on uncertain identity, incompatible geometry/baseline or excessive observation gap. Never reclassify missing people as safely crouched/airborne.

### Measurements and movement

Use the accepted crown/independent-sole offset formulas and mapping. Preserve each scalar's own validity and anatomical labels. Missing nose invalidates crown; missing wrist invalidates that wrist; missing ankle invalidates that sole. Low-confidence/out-of-frame/identity-uncertain/uncalibrated/stale values are nil, not zero/clamped-safe/last-known values.

Wrist evidence does not need perfect squat form; **no SquatDetector is required** for the high rule. Valid crown and both wrists below the beam are Jevon's concern. JumpDetector must use a causal captured-time sequence and sufficient corroborating hip/feet motion to emit a valid phase, not sole height alone or detection absence. Phase thresholds, gap handling and false-airborne rejection require separate tests and device tuning. BodyJoint currently contains no knees/elbows; do not silently add them or design a detector that requires unavailable raw joints.

The output always contains exactly P1/P2. Unbound/lost/uncertain people have invalid dependent geometry/jump state. Bound but uncalibrated people may be reliably tracked, yet calibrationRevision is nil and all mapped evidence remains unavailable. Camera running, two detections, both bound, both calibrated and permission to start gameplay are different facts.

## 8. Lifecycle, source status and integration

Preserve the exact BodyInputProviding API: `start(configuration)`, `stop()`, atomic `setCalibrations`, `snapshotStream`, `releaseSnapshotSubscription`, `latestSnapshot`, `currentContext`, `status`, `diagnostics`, `statusUpdates` and observer removal. No new gameplay subscriber or model field is planned.

**Milestone allocation:** the following live-provider acceptance/publication behavior is planned for implementation and testing in **LH-13C**, using LH-22 results and controlled callers. It is not a dependency for LH-22's estimator correctness. Jevon's real requests/phase/readiness/clock integration is **LH-13D**. A/B diagnostics remain capture/raw-pose tools rather than a partially authorized provider or game lifecycle.

- Start validates configuration, establishes generation/stream and ordered starting status before admitting output, requests permission only when needed, configures off-main and reports confirmed running with compatible source geometry. No accepted calibration is required to run. Source startup/permission errors remain observable without frames.
- One pipeline/session instance survives Setup → Calibration → Countdown → Play and ordinary gameplay pauses. SwiftUI re-render, view change or gameplay consumer cancellation does not recreate/stop it. Only the coordinated lifecycle owner stops it. Explicit restart/rebinding uses a new generation; identical active start is idempotent and incompatible active start fails.
- **C's acceptance transaction:** calibration replacement uses a serialized admission/context epoch and capture watermark. Validate the whole requested dictionary, result/request provenance, generation/camera metadata and revision compatibility before committing; stamp new captures with the new accepted context only after the cutover. Invalid requests leave existing context/cache/cutovers unchanged. Reject old in-flight completion rather than relabeling it. Worker configuration is an immutable versioned input, not a competing calibration owner. Context/cache/observer changes remain atomic; no await inside the authoritative commit. D's caller submits full intended dictionaries; LH-22 only produces validated candidates.
- A pause in GameClock does not alter capture time. Jevon's continuous reader remains alive and checks current generation/camera/per-player calibration **after suspension** before accepting/selecting evidence. Finishing an AsyncStream does not purge buffered observations.
- Preserve `.bufferingNewest(configuration.snapshotBufferCapacity)` (initial 8 whole packets), inspect yields, highest-compatible-frameID latest cache, single stream claim and token-protected termination/reattachment. Reuse CP1 behavior, not ReplayBodyInput's synthetic scheduler or fixture scanning. Start with the smallest BodyInputService implementation and common conformance tests; do not create a new generic transport framework/refactor CP1 as a prerequisite.
- Register session interruption/runtime-error/start/stop and app lifecycle handling independently of frame output. Project framework objects/Notification payloads into small immutable categories before asynchronous forwarding. Generation/configuration/source-event sequence gates reject late notifications. Do not coalesce away starting → running → failed transitions or rely on one Task per notification to preserve arrival order.
- Existing BodyInputStatus vocabulary is source-only: stopped/starting/running/interrupted(system or cameraUnavailable)/failed(permissionDenied, cameraUnavailable, processingFailure or clockNormalizationFailure). Map detailed AV reasons into those categories; no new `.playerLost` case is assumed. Optional bounded technical diagnostics may preserve more source detail without changing that API.
- **Tracking loss is a per-player sample fact**, using reliable/uncertain/lost and invalid measurements. The source may stay running and progressing. Jevon consumes that fact to create P1/P2 pause reasons. Interruption/failure is separately delivered even if there is no further frame. If frames stop without a confirmed interruption, diagnostic progress/staleness is distinct from asserting an AV interruption.
- Preserve configurable disabled/diagnostic no-progress policy, arming after expected output and resetting around startup/context/interruption transitions. Approximately one second is only the existing investigation seed, never an approved pause/production timeout. Use injected host-clock monitoring, not GameClock advancement.
- Interruption end/foreground entry does not automatically authorize gameplay resume: validate source/geometry, require reliable identities and accepted baselines, then Jevon owns recovery/countdown. Media-service reset/fatal failure must not silently change sessionGeneration, reuse incompatible baselines or hide failed status with an immediate stopped event.
- Shutdown invalidates context first, disables new admission, cancels/drains owned work, releases sources and finishes delivery with token guards. A synchronous Vision request may finish late; discard it rather than force-free its image. Keep control/status responsive while work runs, with bounded task ownership and explicit cancellation cleanup.

## 9. Small implementation milestones — separate approvals

All paths below are repository-relative. Lists are proposed edits/additions for later scoped approval; **nothing listed is implemented by this documentation refinement**. Use `feat/camera-foundation` only after its staging/dependency/isolation gate (§12), never PR #15. Keep file-local helpers together rather than creating one file per support type.

### LH-13A0 — Limited SDK and ownership preflight (ready for separate authorization)

**Scope/files:** a small isolated compiler reproduction in a scratch/preflight location agreed in the next A0 request, using actual AVFoundation/CoreMedia/Vision imports, minimal synthetic ownership values and a meaningful forbidden-alias negative control. No real capture session startup, permission prompt, production provider, segmentation or broad source implementation. No project-setting changes or edits to existing CP2 experiments. Exact preflight files/commands belong in that scoped implementation authorization, not an implicit expansion of this document.

**Acceptance:** verify imported callback/clock/handler signatures and the proposed actor/byte-copy boundary under the actual Swift 5/default-isolation/upcoming-feature conventions, temporary complete checking, warnings-as-errors and SIL compilation. Positive path is clean and the negative control is diagnosed; compiler acceptance alone does not prove Core Video alias safety. Report remaining runtime proof requirements. Small synthetic dimensions do not select the full camera resolution/FPS/budget.

**Dependency/limit:** ready for limited implementation **when separately authorized**; no need for LH-22 or Jevon's session. Passing A0 does not authorize full A. No A0 work is executed in this documentation task.

### LH-13A — Camera foundation (conditionally ready)

**Intended files:** implement `Sedactive/Shared/BodyTracking/Capture/CameraPipeline.swift` and `FrameStore.swift`; add `SedactiveTests/Shared/BodyTrackingTests/CameraPipelineTests.swift` and `FrameStoreTests.swift`. For physical diagnostics only, propose new Edo-owned `Sedactive/Games/LaserHeist/Debug/LiveInputDiagnosticsView.swift` and a DEBUG-only route in Edo's `App/RootView.swift` (and minimal retained factory in `App/AppDependencies.swift` if needed). Review that temporary entry with Kevin; do not edit his PlayView/debug overlay or change the default game flow. The new diagnostic view is not a second production calibration screen.

**Dependencies/owners:** accepted A0 plus CP1 metadata/lifecycle semantics, existing permission purpose string and Edo's capture ownership. No LH-22 baseline, full BodyInputService or CP2 renderer needed. Before full A, Edo approves §4's operating configuration (front-device/fallback, format, exact preset/FPS/byte and workspace caps) and the diagnostic resource/lifetime owner; Kevin reviews relevant preview/mirroring and the temporary DEBUG entry. Unresolved numerical settings must not be chosen silently. This gate is separate from approval of the architectural direction.

**Acceptance:** authorized/denied/restricted/not-determined paths are explicit; one front session; no microphone/back-camera fallback; configure/start/stop off-main and never start inside begin/commit configuration. Use the reviewed configuration and record negotiated output; unsupported formats/presets fail explicitly. Capture-only diagnostics share that retained CameraPipeline/session and show source metadata, orientation/mirroring and bounded performance counts, without calibrated body claims. Valid host-clock normalization and generation/geometry/drop stamping; independent interruption/failure after the last frame. One construction/one worker/one pending source under reviewed count/byte caps, no per-frame Task/backlog. Preserve ownership/provenance needed for B and later same-source calibration without implementing segmentation.

**Deterministic tests:** injected authorization/session/clock adapters, denied permission never starts hardware, idempotence/stop during permission request, late old callbacks, unsupported device/format/preset/rate handling, source copy independence/stride/size overflow, approved `B` and total-budget rejection, bounded replacement/exhaustion/last-owner release, dropped callbacks with no image, immutable source stamps across bounded retention, nonidentity source-to-host conversion and clock failure, status events with no frames. Verify diagnostics reuse the same session rather than construct a second one. Small internal seams live beside the implementation; no generic capture framework.

**Physical iPad gate:** §4's acceptance measurements using the approved finite observation conditions; first permission prompt/denial/return from Settings, actual front camera and negotiated format/FPS/stride, asymmetric orientation markers on older/newer iPad front cameras where available, mirrored diagnostic presentation without mirrored internal pixels, repeated start/stop and lifecycle navigation, background/foreground/interruptions. Measure callback copy/total latency, controlled-sink processing/wait latency, source rate/drop reasons and retained source/workspace/preview peaks. These are not Vision or production realtime benchmarks. Report actual hardware/OS and seek Edo's review of numerical adequacy; Simulator alone cannot prove this.

**Risks:** imported isolation/aliasing, copy cost, source pool pressure, nullable session clock, front-camera defaults and dynamic framing. Stop for review if the boundary needs unsafe suppression or misses a measured responsiveness budget.

**Out of scope:** Vision, player binding, calibration, BodySnapshot production, gameplay/RealityKit/cutouts. Do not call this live LH-13 completion.

### LH-13B — Two-person pose and tracking

**Approval state:** not yet authorized; requires accepted full A and its own scope/verification approval.

**Intended files:** implement `Sedactive/Shared/BodyTracking/Capture/PoseEstimator.swift`, `Processing/PlayerTracker.swift`; implement only the raw-pose/tracking composition part of `Processing/MotionEngine.swift`; extend the new Edo diagnostics view. Add `SedactiveTests/Shared/BodyTrackingTests/PoseEstimatorTests.swift`, replace the existing `PlayerTrackerTests.swift` skeleton with real tests and add `MotionEngineTests.swift`. FrameStore changes only if the approved ownership gate requires mechanical support. CP1 Models/PoseFrame remain unchanged.

**Dependencies/owners:** accepted A, current normalized PoseFrame contract, Kevin's review of preview/binding transform. No LH-22 calibration required for raw joints and identity continuity. MotionEngine still has no camera owner.

**Acceptance:** one serial Vision 2D request path produces exact-source PoseFrames with both wrists/ankles/head/hip references/confidence when present. Source metadata remains tied to the immutable captured envelope; scoped/retained source capability is ready for a later reviewed calibration-mask path without adding masks now. Missing observations stay explicit. Initial binding uses mirrored positions; result reordering and later movement do not rename slots. Ambiguous association is uncertain/lost; a third entrant never silently replaces someone. Bound/uncalibrated diagnostics are clearly labeled, not calibrated gameplay.

**Deterministic tests:** SDK adapter mapping via numeric observation seams, all supported required joints/confidence and missing points, canonical corners/anatomical sides, reordered candidates with changed frame-local IDs, clear continuous association, crossing/overlap ambiguity, one-person/no-person/extra-person cases, bounded candidate cap, loss/reentry/reset and capture-time gaps. Test supplied observation sequences, not a Vision accuracy claim from a mocked result.

**Physical iPad gate:** two people of different heights, list-order changes, side movement, brief and long occlusion, overlap/crossing, leaving/reentry and a third entrant. Correct identity or explicit uncertainty is acceptable; unnoticed swaps are not. Measure Vision latency/cadence at actual play distance and lighting.

**Risks:** observational ambiguity in monocular 2D, joint confidence at distance, dropped-frame gaps, two-person coverage. Vision returns a collection, not a guarantee of exactly two reliable detections. Do not assume a hand-pose maximum-count API exists on body-pose requests.

**Out of scope:** accepted standing baselines, real mapped measurements/airborne, full masks/cutouts, game pause implementation and renderer edits.

### LH-22 — Standing calibration result production and validation

**Approval state:** not yet authorized; requires A/B, the §6 result/progress/request seam and segmentation-topology/budget agreement, then a separate LH-22 scope approval. Does not require C's provider implementation or D's session implementation.

**Intended files:** implement `Sedactive/Shared/BodyTracking/Processing/CalibrationSession.swift`; implement the calibration-required subset of `Capture/PersonSegmenter.swift`; update `Processing/MotionEngine.swift` only to supply stable source-keyed pose/mask observations and calibration result/progress. Add `SedactiveTests/Shared/BodyTrackingTests/CalibrationSessionTests.swift` and `PersonSegmenterTests.swift`, including a controlled request/result driver. Extend Edo's diagnostics view for candidate results without implying provider acceptance. `Models/PlayerCalibration.swift`/PoseFrame are consumed, not changed; a necessary shared-field extension is a separate proposal. **No BodyInputService acceptance implementation or Jevon session call-site implementation is required here:** those are C and D respectively. Production CalibrationView implementation ownership remains unassigned and must be assigned before changing that file.

**Dependencies/owners:** A/B source ownership/pose provenance, reliable same-frame per-player mask association, approved hands-down/head/independent-foot estimation/shared layout and the agreed minimal output seam. Edo computes validated candidate results. Jevon reviews that seam now and later runs/requests the phase in D; C's provider owns acceptance. Kevin reviews visible scale/mirroring; Theo supplies instructions. This is a separate task approval, not hidden LH-13 feature work.

**Acceptance:** stable full-body standing sample window; independent real candidate baselines for P1/P2; head-localized crown/nose offset, independently localized ankle/foot offsets, hip/body/torso/floor/origin references and exact source provenance/revisions. Jointly used pose/mask pairs have identical generation/frame/capture time/camera geometry and reliable slot association. Hands up, missing feet/head, mismatched/ambiguous mask or unstable stance prevents a valid result with a reason. Different heights remain different; no baseline updates during duck/jump. Algorithm correctness is proven through the controlled driver, with no authoritative accepted dictionary or live provider required. Full replacement/atomicity/cutover integration is explicitly C's acceptance gate.

**Deterministic tests:** stable/unstable/partial/raised-hands/head-region cases, independent foot bottoms (including one missing), same-frame pairing and rejection of different frame/capture/gen/camera metadata, mask-to-pose mismatch/ambiguity, two different heights under one scale, stale/canceled request results, bounded source/reconstruction/mask/join cleanup on loss/context changes, and no drift-induced silent baseline rewrite. Validate output schema and rejection via controlled context/revision inputs. **Provider empty/partial/full/remove/reaccept, cache and cutover transaction tests belong to C**, not a condition of algorithm completion here. Numeric/synthetic standing observations only; no private participant images in repository.

**Physical iPad gate:** both people produce independently valid standing results at valid play distance; diagnostic crown/each sole/hip align in standing. Move closer/farther or change camera geometry and verify candidate/sample rejection or reduced confidence, rather than normalize both people identically. This proves algorithm/result behavior; accepted-provider-context invalidation is tested later in C. Test nose/head pose, hands-down instructions and one-foot occlusion. Tune stability/drift/error tolerances with owners.

**Risks:** instance masks are not persistent identity, global mask top is not necessarily crown, close/overlapping feet are not one shared sole; segmentation can contend with pose even with separate workers. Choose the reviewed same-worker/bounded-branch topology and prove primary-path protection. The small result/progress/cancellation seam and revision proposal rules must be agreed first; do not invent an early provider or second baseline store to hide this prerequisite.

**Out of scope:** authoritative provider acceptance, atomic replacement/cutover implementation, Jevon's real calibration-phase/readiness implementation, continuous live cutout production, textures, calorie/profile work, automatic IMU reconstruction and gameplay judgments. No constant placeholder calibration is acceptable for moving to C/D.

### LH-13C — Live BodySnapshot production

**Approval state:** not yet authorized; requires validated LH-22 outputs after A/B and a separate C scope/verification approval. Uses controlled callers for provider integration; does not depend on D being implemented first.

**Intended files:** implement `Sedactive/Shared/BodyTracking/BodyInputService.swift`, `Processing/BodyMeasurementExtractor.swift`, `Processing/JumpDetector.swift`; finish `Processing/MotionEngine.swift` and integrate approved CameraPipeline/FrameStore/PoseEstimator/Tracker/CalibrationSession APIs. Fill the existing `BodyMeasurementExtractorTests.swift` and `JumpDetectorTests.swift` skeletons; add `BodyInputServiceTests.swift` and `LiveInputConformanceTests.swift`; extend MotionEngine tests. Preserve existing CP1/CP2 suites, ReplayBodyInput and JSON schemas. Any CP2 correction for §1 remains a separately reviewed CP2 change, not an incidental LH-13C edit; integrate its approved staging version before enabling the CP2 tee.

**Dependencies/owners:** A/B plus real **validated candidate results from LH-22** and its agreed seam. C implements their authoritative acceptance; it does not demand results already accepted by an unimplemented provider. BodyInputService is Edo-owned; no Jevon/Kevin production edits or real game session are prerequisites. Source compatibility and full replacement semantics must match CP1 exactly. Public contracts are not extended to bypass a missing algorithm.

**Acceptance:** implement the sole authoritative accepted calibration context, atomic full replacement, per-player revision/cutover transaction and in-flight stale-result rejection through existing setCalibrations. Invalid requests leave previous context/cache/cutovers unchanged; equal retained baselines preserve their revisions; changed/removed/reaccepted baselines cannot revive old evidence. Under that accepted context, produce real current-frame crown/wrists/soles/center/JumpState with independent validity and exact P1/P2 keys. Nil invalid values, no prior-frame/other-limb substitution, conservative valid-airborne classification. Existing single-consumer stream, highest-frame cache, independent ordered status and token cleanup. Input can run with zero/one baseline but reports unavailable mapped evidence. Actual camera interruption is observable without a frame; lost player and suspected stall remain distinct. One internal status tee can support CP2 without another gameplay/status subscriber.

**Deterministic tests:** all provider conformance scenarios from CP1 using controlled source/processing events, both source and processing delays, lost/uncertain/uncalibrated samples, one missing wrist/sole, nose-specific offset and independent foot estimates, known mapping values/height differences, causal jump phases and unknown on gap/loss, out-of-order stale completion, buffer overflow/duplicates/cache, cancellation/reattach/late token, atomic full replacement and same-revision reaccept cutovers, stop/fatal failure without frames, source-clock normalization failure, diagnostic stall arming and CP2 held-reader independence. No collision verdict assertions in Edo's suites.

**Physical iPad gate:** compare live debug geometry to bodies in stand/duck/jump; both soles plus airborne evidence independent from head/wrists; low-confidence/out-of-frame/head-turn cases; different heights; camera/distance drift invalidation; capture/pose/publish latency and thermal/memory observations. Explain detector error and required tuning honestly before calling values gameplay-ready.

**Risks:** airborne false positives from camera movement/walking/gaps, offset invalidity during head rotation/scale drift, context-commit races and processing stalls. Exact imported delegate ownership and complete concurrency must already have passed A; do not suppress a later diagnostic.

**Out of scope:** Jevon's clock conversion/crossing window/pause policy, UI/renderer, new squat/vault/diamond fields and live cutout production.

### LH-13D — Lifecycle, replay/live wiring and gameplay integration

**Approval state:** not yet authorized; requires accepted C, Jevon's session/replay dependencies, cross-owner integration agreement and a separate D scope/verification approval.

**Intended Edo files:** implement production composition in `Sedactive/App/AppDependencies.swift`; update `App/RootView.swift` (and `SedactiveApp.swift` only if injection requires it); tighten `Shared/BodyTracking/BodyInputService.swift` for reviewed app lifecycle. Add `SedactiveTests/Shared/BodyTrackingTests/LiveInputLifecycleTests.swift` for source behavior. Retain/restrict the debug diagnostics route to DEBUG.

**Owner-reviewed separate edits:** Jevon owns `Games/LaserHeist/Session/GameSessionCoordinator.swift`, `SessionState.swift` and `SedactiveTests/Games/LaserHeist/SessionTests/GameSessionCoordinatorTests.swift` for calibration/readiness/reader/pause/recovery. `Shared/GameRuntime/GameClock.swift` changes only if Jevon's reviewed source-clock conversion needs them. Kevin owns `Games/LaserHeist/UI/PlayView.swift`, `Debug/PoseDebugOverlay.swift` and any `Rendering/GameWorldMapping.swift` changes for injection, source-state display and common transform; he reviews his own renderer tests. Theo owns cue/instruction design. Changes to other UI files require assigning their Swift owner first.

**Dependencies/owners:** C/device measurement gate, Jevon's real LH-12 replay/session/evidence integration, review of source-clock anchor/readiness/recovery and Kevin's update/preview conventions. CP2 renderer integration remains separately authorized; physical LH-13 body-only diagnostics do not close LH-14.

**Acceptance:** Jevon owns entering/leaving calibration, requesting/canceling its work and submitting complete intended dictionaries to C's existing provider acceptance API; he observes the committed context rather than maintaining another accepted store. He owns gameplay readiness, countdown, pause/recovery and session/GameClock behavior. Backend selection constructs either ReplayBodyInput or BodyInputService behind **the same BodyInputProviding dependency**. Explicit replay scheduling remains replay-only; game Domain/collision rules do not branch on source. One retained live service/camera across setup/calibration/play; one Jevon gameplay reader continues during ordinary pause. Both accepted compatible calibrations **and** reliable tracking are necessary for countdown. P1/P2 loss/uncertainty pauses via Jevon without damage caused by the loss; resume only through his reviewed recovery after all reasons clear. Source interruptions reach him even without samples. No profile setup or identity reassignment. End/exit/Play Again cleanup uses new generation as approved.

**Deterministic tests:** inject fake authorization/capture/clock and source events through real provider into Jevon's coordinator, verify backend-neutral rules, continuously draining single consumer, GameClock pause mapping, zero/partial/full calibration readiness, lost P1/P2 pause, overlapping reasons, interruption with no frames, no premature resume, stale buffered history rejection, view/lifecycle transitions without camera duplication, explicit stop/restart generation isolation. Jevon owns game outcome/recovery assertions; Edo owns source contract tests. Keep existing full suite.

**Physical iPad gate:** two actual people, clearly different heights, entire configured round, stand/duck/jump, overlap/crossing, loss/reentry, extra entrant, background/foreground/permission and feasible interruption, rotation/mount/scale changes, back-to-back rounds. Inspect mirrored preview/body overlays, identities, status/no-frame recovery, geometry/verdict alignment and measured latency. Capture only approved consented evidence outside the repository. Full rendered cutout cases wait for Kevin's separate Phase 2/live integration and remain explicitly outstanding if unavailable.

**Risks:** session code is currently a skeleton, UI implementation ownership gaps, source/GameClock confusion, competing lifecycle owners, visual/gameplay evidence times differing. No inference that production session/cutout integration exists because the preview renders lasers.

**Out of scope:** changing game mechanics to accommodate unreliable input, CP2 GPU integration, final artwork, new targets/settings, release validation beyond the agreed test matrix. Failure is a reason to fix/limit the input and review policy, not silently weaken collision tests.

## 10. Verification and device acceptance gates

Use existing Swift Testing conventions. New suites belong in `SedactiveTests/Shared/BodyTrackingTests/`; owner-specific game/renderer tests stay under `SedactiveTests/Games/LaserHeist/`. Inject capture, clock, observation and completion seams at the smallest required boundary. Use synthetic pixels/poses and controlled continuations/gates; no arbitrary sleeps or private recordings as unit fixtures.

For A0, use its limited compiler/ownership acceptance in §9; no physical-capture result is implied. For each separately authorized source implementation milestone:

1. Build app and test target with installed Xcode and unchanged project settings; verify membership/resources.
2. Run targeted new tests and then the applicable existing suite. Compare against actual baseline/counts rather than keeping a count by excluding tests. CP2 PR state may change the baseline before implementation; inspect again then.
3. Run focused complete-concurrency SIL checking with warnings treated as errors, including ownership negative controls. The historical generated RealityKit package suppress-warnings/WAE conflict remains a tooling consideration; isolate the relevant compiler gate without muting diagnostics or editing package/project settings.
4. Report actual compiler/concurrency warnings and device/Simulator distinction. SDK declarations and a mocked observer do not validate hardware inference.
5. Run the milestone's physical-iPad matrix before claiming camera/tracker/calibration/gameplay accuracy. Measure source/processing/publication rates, drops, bounded retained bytes, callback and inference p50/p95, lifecycle latency, drift/identity errors and thermal behavior. Do not approve thresholds from host CPU tests.

Eventual LH-13 completion requires all of: one front session across flow; real independent standing calibrations; stable identities or explicit uncertainty; correct unavailable evidence; unchanged input-neutral gameplay; no-frame camera status; owner-reviewed pause/recovery and capture/GameClock mapping; physical two-person round/loss/overlap/interruption evidence. Passing A/B, synthetic tests or CP2 CPU handoff alone cannot satisfy this gate.

### Dependency-specific acceptance — no backward implementation requirement

| Gate | Must be verified in that milestone | Not a prerequisite for its completion |
|---|---|---|
| A0 | Exact SDK/isolation signatures, positive SIL and meaningful diagnosed negative control; remaining runtime limitations reported | Full capture configuration, physical session, Vision/calibration/provider/session implementation |
| A | Approved experimental configuration and same-session diagnostic ownership; owned-source provenance/bounds, lifecycle/copy/device measurements | Segmentation, calibration outputs or calibrated body/gameplay readiness |
| B | Source-correlated poses, stable binding or uncertainty, bounded retention needed for a later same-source mask path | Actual calibration masks/algorithm or provider acceptance |
| LH-22 | Same-frame pose/mask association, bounded selected topology, independent real standing output/stability/rejection and provenance via the agreed controlled driver | Live BodyInputService, provider replacement/cutover transaction, real Session/CalibrationView |
| C | Live-provider conformance, exact accepted key sets and unchanged CP1 atomic replacement/revision/cutover/cache/in-flight rules; real evidence under accepted context | Jevon's real phase/countdown orchestration, which is D |
| D | Real calibration requests/cancellation/phases, submission to C, gameplay readiness/countdown/pause/recovery/GameClock and one consumer | No earlier milestone claims this game integration from its own algorithm/transport tests |

For LH-22's chosen source topology, add deterministic pairing tests that deliberately deliver mask results from a different frame/generation/time/geometry and verify rejection, plus controlled delayed/never-completing mask jobs to prove raw-source/mask/join bounds, primary-path capacity and eventual cleanup without forced reclaim. Measure primary tracking cadence under calibration load on iPad before accepting the topology. Production latency/throughput limits are reviewed from actual measurements; no numeric limit or benchmark result is asserted here.

## 11. Installed SDK/API inspection evidence

Inspected **Xcode 26.6 (17F113), Apple Swift 6.3.3** and installed iPhoneOS **26.5** SDK at:

`/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk`

Paths below are relative to `System/Library/Frameworks/` inside that SDK. Availability here means declarations/header behavior were inspected, **not that a new adapter was compiled or run**.

| Header | Verified declaration / consequence |
|---|---|
| `AVFoundation.framework/Headers/AVCaptureDevice.h` | Video authorization status/request APIs (iOS 7+), front device/configuration APIs; RotationCoordinator and Center Stage controls exist. Center Stage may not be set blindly while user-controlled. Runtime support/configuration still must be checked. |
| `AVFoundation.framework/Headers/AVCaptureVideoDataOutput.h` | Serial delegate queue preserves callback order, alwaysDiscardsLateVideoFrames, dropped-sample callback (no source pixels), supported video-format querying. Extra downstream work requires its own memory bounds. |
| `AVFoundation.framework/Headers/AVCaptureSession.h` | begin/commit configuration; startRunning/stopRunning block; runtime/start/stop/interruption notifications; synchronizationClock iOS 15.4+ (masterClock deprecated). Rotation-angle API iOS 17+, mirroring support checks and newer iPad front-camera default warning. |
| `CoreMedia.framework/Headers/CMSampleBuffer.h` | Get image buffer and presentation timestamp; keep buffers inside their controlled source ownership scope. |
| `CoreMedia.framework/Headers/CMSync.h` | CMClockGetHostTimeClock, CMClockGetTime, CMSyncConvertTime; explicitly convert clock domains, not offset Date. |
| `Vision.framework/Headers/VNDetectHumanBodyPoseRequest.h` | iOS 14+ collection of VNHumanBodyPoseObservation; recognizedPoints group API and anatomical wrist/ankle/head/hip joints. No crown/sole landmarks and no maximum-body-count property declared on this request. [Apple request reference](https://developer.apple.com/documentation/vision/vndetecthumanbodyposerequest). |
| `Vision.framework/Headers/VNRequestHandler.h` | CVPixelBuffer + CGImagePropertyOrientation initializer and synchronous request performance path. Handler retains source; source must remain unmodified for its lifetime, not just until buffer checkout ends. |
| `Vision.framework/Headers/VNGeneratePersonInstanceMaskRequest.h`, `VNObservation.h` | iOS 17+ instance masks and per-instance/scaled-mask APIs. Instance indices are not P1/P2 and no persistent person identity guarantee is declared. Needed for reviewed calibration association, not automatically live cutout completion. |

All listed platform minimums are below the current deployment target; no target upgrade is justified. Prefer the familiar VN 2D request family for this incremental plan rather than migrating to a different Vision API alongside live integration. Check exact imported Swift signatures/isolation in A0. Supplemental official documentation was consulted for source-clock, body request and late-frame behavior; installed SDK headers are the availability baseline.

## 12. Review decisions, risks and recommended next step

### Branch and PR isolation — prerequisite to any later implementation

- **No LH-13 implementation belongs in PR #15** (`feat/cutout-handoff` → `staging`). CP2 fixes/review and their commits stay scoped to that work; do not mix unrelated CP2 working-tree edits into camera changes.
- The dedicated implementation branch is **`feat/camera-foundation`**, separately created from an **up-to-date staging containing the required approved dependencies**. This checkout already has that name, but its name or local merge subject alone does not prove remote freshness, approval or a clean dependency base.
- Before separately authorized implementation, verify the actual staging base and dependency contents (CP1, and approved CP2 changes only where required). If the existing branch/base is unsuitable or a required dependency is not available, report the gate and agree a Git action separately. Do not automatically recreate/switch branches, pull, merge, rebase or copy/cherry-pick CP2 changes into the camera task.
- Review the eventual diff against the verified integration base so only the intended milestone changes are included; required already-merged dependency code is distinguished from new unrelated changes. No assumption is made about current GitHub PR #15 approval/merge status from this document.
- **Concurrent implementation must not share a mutable checkout.** Use appropriately isolated Git worktrees/checkouts for different active branch work under separately authorized setup, or serialize the work instead. This documentation task creates none. In particular, CP2 corrections and camera implementation must not edit the same checkout concurrently.
- Every milestone, including A0, has its own scoped authorization, verification and review. Overall architecture approval, a branch's existence or a successful earlier milestone does not authorize the next one.

### Decisions and readiness

| Item | Classification / owner | Gate |
|---|---|---|
| P1/P2, body fields, stream/cache/status/replacement semantics, no profiles, canonical units/mirroring | Already accepted CP1/current code | Preserve; do not reopen as implementation shortcuts. |
| AVFoundation → bounded owned source → Vision → stable P1/P2 → LH-22 → existing CP1 provider / Jevon session | **Approved architectural direction** | Preserve decomposition/ownership; implementation permissions below remain separate. |
| CP2 Data-copy/straight-alpha output and Kevin GPU ownership | Accepted Phase 1 direction; remote PR #15 state not verified here | Preserve all existing corrections; no full cutout implementation or CP2 edits here. |
| Raw camera → independent bytes → worker CV candidate | **Proposed technical default, Edo**; not inherited CP2 production approval | A0 strict compiler gate + A callback/copy/device measurements. Stop for review if unsuitable. |
| A0 SDK/callback ownership/compiler check | **Ready for limited implementation**, once separately authorized | Positive/negative SIL gate only; do not begin it during this documentation task. |
| Full A camera foundation | **Conditionally ready** | A0 passes; Edo approves §4 operating configuration/finite budgets and diagnostics ownership, Kevin reviews preview/mirroring, then a scoped full-A authorization. |
| Capture resolution/rate, raw-source byte limits, pending/job counts | Experimental count/policy candidates in §4; exact preset/FPS/B/workspace/preview caps require Edo approval | Resolve before full A; distinguish experimental settings from production device acceptance thresholds. |
| Operational iPad orientation/front device, dynamic framing/stabilization | Edo + Kevin; Theo for preview instructions | Agree reproducible mounted geometry, supported settings and change invalidation. No project restrictions silently added. |
| Binding, candidate cap, match margin, occlusion/reentry thresholds | Edo technique, Kevin placement review, Jevon recovery review | B synthetic ambiguity tests + physical two-person evidence. No guaranteed identity through indistinguishable overlap. |
| Real head/sole baseline method and stability/drift thresholds | Edo LH-22 algorithm/results; Kevin mapping review | Validate outputs independently before C acceptance; no fixture baseline in live operation. |
| Calibration source topology / same-frame pairing | Same-worker versus bounded branch still requires Edo choice; Jevon/Kevin review affected integration | Choose and budget before LH-22 implementation. A/B prepare provenance/ownership capabilities, not segmentation. |
| Calibration request/progress/result seam and revision proposal rules | Edo + Jevon prerequisite agreement; Kevin mapping review; UI implementer unassigned | Agree before LH-22; algorithm can run via a driver without C/D. C owns authoritative acceptance; D owns game requests/phases/readiness. No new CP1 API assumed. |
| CP1 removed-cutover / CP2 validation mismatch | Existing static finding; any correction remains separately scoped to Edo's CP2 work and reviewed with Kevin | Resolve with real-context regression before CP2 status tee integration, not by changing CP1 or adding a CP2 fix to LH-13. Does not block A/B. |
| Source clock → GameClock, pause/readiness/recovery and one consumer | Jevon, Edo supplies documented source time | Required before D; no new Shared game clock or identity-loss source status case. |
| Preview/cutout/debug common transform, visual status, idle renderer update | Kevin + Edo; update hook/recovery coordinated with Jevon | Review before touching Kevin files; renderer phase remains separately authorized. |
| Freshness/stall/hold durations, jitter/accuracy/performance targets | Existing configurable conventions; numerical tuning not approved | Device measurements and relevant owner agreement; no invented production timeout. |
| Existing documentation status/path mismatches | Recorded, not changed | A separate scoped documentation alignment may follow approval; current Swift remains authoritative. |
| LH-13B, LH-22, LH-13C, LH-13D | **Not yet authorized** | Separate forward-only dependency gates and scoped approval for each. LH-22 output does not depend on C's provider; C does not depend on D's session. |
| Full live CP2 cutout / RealityKit integration | **Not yet authorized by this plan** | Separate Edo/Kevin implementation/review and physical-device gates. |
| Dedicated branch/dependency/isolation workflow | `feat/camera-foundation`, based separately on verified approved up-to-date staging | Apply the workflow above before any code; never add LH-13 to PR #15 or share concurrent mutable checkout state. |

**Recommended next authorization: limited LH-13A0 only**, on the verified dedicated implementation branch after the branch/dependency/isolation check. Do not execute it in this task. Full LH-13A remains conditional on §4's operating configuration and diagnostic ownership/preview review, A0 results and a separate approval. LH-13B, LH-22, C and D remain unauthorized until separately reviewed after their forward dependencies; the architecture approval does not approve them collectively. Do not begin with JumpDetector, game-clock changes, fake calibration or production cutouts.

The limited preflight is sufficiently specified for a scoped implementation request. Full capture still needs Edo's initial configuration decisions and Kevin's relevant preview review; LH-22 needs its result seam and same-frame segmentation choice; C later proves provider acceptance; D proves Jevon's game orchestration. These are explicit remaining gates, not circular implementation prerequisites. No compiler/runtime/device gate is claimed passed from this Markdown refinement.

## 13. Planning-task verification and handoff

Only the existing `Docs/LH-13-Live-Camera-Architecture-Proposal.md` is edited by this refinement; it remains untracked, as it was on entry. A pre-edit hash inventory of 277 tracked/untracked files and a before-copy of this proposal are retained temporarily under `/private/tmp/lh13-refinement/` for preservation/diff review. No Swift, test, fixture, other document, renderer, resource, project setting or Git state is changed. Existing committed CP2 corrections and untracked Scripts are preserved. Branch remains the already-active `feat/camera-foundation` at `845b1997388051a3df4ede73c572820d7c2e642b`; no branch creation/switch, fetch/pull/merge/rebase/stage/commit/push is performed.

**Checks performed for this refinement:** current Git/structure and relevant existing instruction/contract/dependency inspection; complete updated-proposal review against the before-copy; forward-only milestone and ownership audit; same-source pairing/count/byte/lifetime review; approval/branch-reference and whitespace/fence checks; preservation hashes and final Git status. §11's SDK/header evidence and earlier reports' test counts remain earlier inspection/verification history. **No A0/compiler spike, build, unit test, Simulator run or physical-iPad test is performed** for this documentation-only refinement.

**Skills used:** swift-concurrency and swift-architecture-skill (existing lean structure retained; explicit asynchronous ownership/cancellation and dependency-composition boundaries). No new architecture/framework is introduced.

After Edo reviews the proposal, each owner approves/implements their integration surface; this document is not permission to edit Jevon's coordinator/GameClock or Kevin's renderer/PlayView. Stop here until the next milestone is separately authorized.
