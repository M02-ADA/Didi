# LH-13A2 — Safe DEBUG Camera Preview Architecture Review

4 November 2026 · Edo · `feat/camera-foundation` · inspected HEAD `499f865494e65a2e8b35a4e228ef963eb936f650`.

**Recommendation: Option B, a separately bounded, low-frequency owned-image preview, as the next implementation candidate.** Keep the existing session actor and canonical source unchanged. Option A is attractive for native preview performance, but the tested same-session adapters do not satisfy the installed compiler/ownership constraints. This is an architecture recommendation, not authorization to implement or acceptance of runtime performance. A2 remains REVISE; LH-13B remains unauthorized.

## 1. Actual baseline

Inspected the LH-13 proposal, A1/A2 reports, CameraPipeline, FrameStore, CameraCaptureMetrics, diagnostics controller/view, AppDependencies, and Kevin's mapping/cutout code and CP1/CP2 mirroring rules. A1/A2 are implemented; older planning tables calling them skeletons are historical. A2 records successful M4 capture, cleanup/background shutdown, and **manual** denied → re-enabled permission confirmation. Those earlier results are not new preview tests.

AppDependencies retains one CameraPipeline. Its native driver actor owns the session; the sample delegate copies independent Data into FrameStore. FrameStore has one processing consumer and three raw-source slots. Its scoped private bytes and final-owner reservations must remain intact. The diagnostics controller already occupies the sole CameraPipeline status observer; reuse that status path rather than registering another observer.

Entry Git status: existing `.pbxproj` signing-team modification and untracked `Scripts/`. Both are preserved. No remote Git operation was performed; the user's published-baseline statement is not a newly verified remote-branch comparison.

## 2. Comparison

| Concern | A — same-session AVCaptureVideoPreviewLayer | B — independent owned-image preview |
|---|---|---|
| Concurrency | Tested session/layer transfers and protocol/closure adapters fail complete checking. Indirection alone does not disconnect a shared mutable graph. | Independently owned Data → worker-built immutable CGImage → MainActor packet passes SIL/WMO and object compilation. Runtime backing ownership still needs validation. |
| Camera owner | Could use the existing session, with attachment/configuration serialized by its owner. The layer retains its session; exposing a connected layer is not automatically a safe encapsulation boundary. | Never exposes the session or mutable CV resources. No new camera. |
| Source lifetime | Framework owns preview buffers; no application raw-frame queue is needed. Attachment/detachment and view ownership remain unresolved here. | No long-lived CameraSourceFrame reference; clone optional input into a separate budget before returning from the scoped source access. |
| CPU/memory | Avoids application image copies/conversion, but framework preview memory and workload are not zero. | Additional admitted-frame copies and display upload; explicit finite input/provider/output limits. Higher application-controlled memory/CPU cost. |
| Latency | Native continuous preview is a promising lower-overhead option; not measured in this review. | Sampling adds visible delay/stepping. Dropped preview work must not delay the primary worker. No measured preview latency yet. |
| Orientation | Separate preview connection rotation/mirroring and gravity must match the data path. Numeric source angle alone is insufficient. | Displays the actual upright-source pixel representation with one explicit display mirror and full-image aspect fit. Still needs asymmetric device validation. |
| Future LH-13B | Useful smooth positioning guides, but displayed pixels have no demonstrated exact match to a selected pose frameID. | Image packet carries exact source identity for same-frame overlays; 5 Hz is useful for binding diagnostics, not proof of dynamic tracking quality. |
| Implementation risk | A small-looking adapter has unresolved actor/UI aliasing and session-connection mutation issues. | More explicit copying, but fits the existing checked immutable handoff and leaves native ownership unchanged. |

Apple documents the preview layer as its normal native camera-preview mechanism, including UIView hosting and connection/coordinate APIs. That establishes API purpose, not compatibility of every sample adapter with this project's ownership rules. [AVCaptureVideoPreviewLayer](https://developer.apple.com/documentation/avfoundation/avcapturevideopreviewlayer), [AVCam](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app).

## 3. Verified compiler boundaries

Toolchain: Xcode 26.6 (17F113), Swift 6.3.3; iPhoneOS and Simulator SDK 26.5, arm64 deployment 26.5. Probes use Swift 5, default MainActor, the existing approachable-concurrency feature flags, complete checking, warnings as errors and **SIL/WMO**, not typechecking alone.

| Isolated probe | Result on both SDKs |
|---|---|
| Return actor-owned AVCaptureSession to MainActor | Rejected: non-Sendable result crosses actor boundary. |
| Return retained connected AVCaptureVideoPreviewLayer | Rejected: non-Sendable result. |
| Return a freshly constructed connected layer as `sending`, while keeping its session in the actor | Rejected: actor-isolated value cannot be sent. |
| Sendable target protocol with a nonisolated method mutating a MainActor-owned layer | Rejected: MainActor property access from nonisolated method. |
| Send a UI layer into the session actor, then reuse it in the UI hierarchy | Rejected: sending risks data races. |
| Sendable encoding/connection closure capturing the UI layer | Rejected: non-Sendable layer capture. |
| Independent Data + immutable metadata; worker CGDataProvider/CGImage; MainActor image packet | Accepted: SIL/WMO **and object/WMO**; SDK CGImage satisfies checked Sendable. |
| Optional admission using Mutex.withLockIfAvailable | Accepted: SIL/WMO. |
| Deliberate Sendable packet containing a mutable non-Sendable workspace | Rejected as expected. |

These are six rejected A variations per SDK, four accepted B image compilations, two accepted admission compilations, and two meaningful mutable-payload negative results. No suppression, unchecked conformance, unsafe nonisolation, camera startup or device run was used. The B probe uses explicit independent immutable provider bytes; it does not validate resampling, memory permits, color correctness or framework lifetime.

Reproduce: `bash /private/tmp/lh13-preview-review/verify.sh`. Sources, exact flags and logs are in that scratch directory; final results are `results-final.log`. No experimental Swift file was added to a production target. Online conformance lists are not substituted for the installed compiler's diagnostics. These failures do not prove every conceivable safe layer adapter impossible; no acceptable one was established here.

## 4. Recommended B boundary and resource limits

Start with **full-canvas 1280×720 at a proposed maximum 5 preview updates/second**, avoiding an additional resize pipeline initially. These are preview experiment candidates requiring approval, not performance promises or capture-FPS changes.

```text
successful primary source admission
  → optional try-reservation, otherwise skip preview
  → bounded independent Data clone inside existing scoped source access
  → one optional worker / no pending input backlog
  → immutable CGImage + exact source stamp
  → one latest pending image → MainActor presenter
```

The producer publishes primary work first, releases the FrameStore state lock, and never awaits preview conversion or UI consumption. A busy, contended, inactive or exhausted preview admission gate skips optional work before allocation. Mutex.withLockIfAvailable supports a metadata-only try-reservation; no copy/conversion occurs under its lock. [Apple's try-lock API](https://developer.apple.com/documentation/synchronization/mutex/withlockifavailable(_:)).

**Do not hand a retained raw source to a slow preview worker.** A fourth outstanding historical raw frame could compete with construction + pending + processing under the three-slot cap. Instead, make the optional independent clone while the existing scoped source is available, and never retain that source after the tee returns. Do not call FrameStore.acquire from the UI or add a second processing/gameplay reader.

This removes a waiting/backpressure dependency, not CPU cost: the extra bounded clone still extends some callbacks and competes for memory bandwidth. There is no claim of zero extra AV drops. Measure it against A2's no-preview baseline. If “must not block” means literally no additional callback CPU work, B cannot meet that stronger interpretation as proposed; review a different source-retention budget before proceeding.

Proposed limits:

- One preview input/conversion permit; no per-frame Tasks, queue of inputs, JPEG encoding, extra CV pool or Metal renderer. Use one lifetime-controlled worker and bounded wakeup.
- One latest pending image and one displayed image. Replacements are optional; no transition animations or image history.
- `B = 4 MiB` maximum checked stride-inclusive payload. A conservative **candidate P = 3B = 12 MiB** covers one input Data clone, one independent provider backing and one previous displayed/provider image. Reserve the entire job allowance before copying. If pending + displayed images already leave insufficient allowance, skip new preview work until released; do not allocate a fourth backing.
- Original raw 12 MiB + reconstruction 4 MiB stay unchanged. The candidate additional P would make the reviewed explicit pixel-allocation ceiling 28 MiB, **not process RSS**. P is not approved by this report.
- Budget/lifetime accounting must follow backing ownership, not mailbox dequeue or wrapper destruction alone. CGImage/providers can retain pixels and UI/frameworks may retain an image after assignment changes. Validate actual release; explicitly distinguish framework caches/decoded/display surfaces from application-controlled allocations. Do not claim a hard total-memory bound from packet counts or compiler acceptance.
- Immutable CFData/provider bytes are created independently; no mutable producer alias, escaped source pointer or raw CV object crosses executors. Keep any mutable construction local to its worker; present only the completed CGImage. The probe verifies the SDK's Sendable boundary, not all backing-lifetime invariants. [CGImage](https://developer.apple.com/documentation/coregraphics/cgimage).

Stop/interruption/failure/generation or geometry change invalidates preview immediately through the existing diagnostics status owner, even with no new frame. Clear pending/displayed imagery, cancel optional admission and reject late results by generation + epoch + geometry + preview subscription token. Actual readers retain their credits until release; a stuck optional job exhausts preview capacity rather than spawning replacement workers or blocking primary input. Closing/reopening a view reuses the retained camera and preview budget. Display source age using the existing Core Media host-clock basis; expire imagery through the existing diagnostic refresh even when no new images arrive. Kevin/Edo must review a configurable diagnostic age limit; no production timeout is chosen here. No images are persisted.

## 5. Minimal Kevin/Edo display contract

- Input is canonical upright, unmirrored BGRA; packet retains generation, epoch, frameID, original host capturedAt, geometry revision, source dimensions/stride and applied orientation provenance. No CP1/CP2 modification.
- Initial preview shows the whole camera image using aspect fit, with visible letterboxing; no aspect-fill crop or independent player scaling.
- Do not apply the recorded capture rotation again to already rotated buffers. First verify optical uprightness with asymmetric markers; 0° alone proves nothing.
- Apply exactly one horizontal display reflection. For canonical normalized `(x,y)` with bottom-left origin and fitted image rect `(ox,oy,w,h)` in top-left UI coordinates:

  `displayX = ox + (1-x)*w; displayY = oy + (1-y)*h`.

- Image and overlay use the same transform/content rect. Do not mirror UI labels or anatomical landmark identities. P1 initially binds mirrored displayed-left and P2 displayed-right; no roles or detection-index assignment. This full-preview reflection does not flip the RealityKit world or change game lanes.
- Future pose overlays display only for the **same source key** as the shown image. Hide unmatched overlays; never combine a live latest pose with an older sampled image. Do not hold raw frames waiting for poses. LH-13B's eventual bounded association needs separate approval; none is implemented here.
- Raw diagnostic camera preview is opaque BGRA, not CP2 straight-alpha cutout imagery. Provider byte order, alpha treatment, raster row direction and source color attachments must be validated; the probe's sRGB/ignored-alpha choice is only a synthetic compile candidate.

Kevin's GameWorldMapping still has historical parent/child lanes and an unmirrored prototype default. Preserve that production code; current anonymous CP1/CP2 decisions govern this diagnostic proposal.

## 6. Minimal future implementation surface

Subject to separate authorization:

1. New `Sedactive/Shared/BodyTracking/Capture/CameraDiagnosticPreview.swift`: DEBUG-only private packet, optional gate/budget, worker and latest-image mailbox. No generic media framework.
2. `Capture/FrameStore.swift`: narrow optional scoped tee after primary admission; no public raw Data getter or extra raw-frame owner.
3. `Capture/CameraPipeline.swift`: retain/connect the optional preview service and invalidate source contexts; native session remains private.
4. `Capture/CameraCaptureMetrics.swift`: bounded preview admission/drop/time/backing-byte diagnostics.
5. `Games/LaserHeist/Debug/LiveInputDiagnosticsView.swift`: display image, fitted rect, stale/invalid state and matching metadata; reuse its existing status observer.
6. `App/AppDependencies.swift`: compose one retained optional preview service. RootView's existing DEBUG route should suffice.
7. New `SedactiveTests/Shared/BodyTrackingTests/CameraPreviewTests.swift`: deterministic admission, lifetime, token/context and transform tests.

No Kevin/Jevon file, CP model, project setting, package or target needs a proposed change.

## 7. Review decisions and acceptance gates

**Kevin/Edo must review:** (1) B versus further A investigation; (2) full-canvas aspect fit, one mirror and normalized-point convention; (3) sampled 5 Hz adequacy for initial positioning; (4) opaque/color/raster interpretation; (5) invalidation/fallback, diagnostic freshness policy and same-frame future overlays. Edo must approve P and the bounded callback-copy cost before implementation. Kevin's review is not supplied or presumed here.

Before accepting an implementation:

- Synthetic asymmetric corners, padded rows, BGRA channels and both landscape orientations; verify overlay/letterbox mapping without double rotation/mirror.
- Deterministic busy/never-finishing conversion, blocked UI, budget exhaustion, final backing release, late callbacks and stop/restart without frames. Primary admission must continue while optional work is dropped.
- Physical mounted M4 test with left/right/top/bottom markers and two people of different heights. Visual checks remain diagnostics, not tracking/calibration evidence.
- Compare preview off/on over equal finite intervals: capture/sink FPS, callback/copy p50/p95, worker lag, preview age, drops and source/workspace/preview peaks. Measure RSS/thermal growth separately and test repeated view/camera cycles. Do not infer preview performance from the earlier 30 FPS reconstruction result.
- Repeat permission/background behavior with preview visible; ensure stale imagery disappears without waiting for another frame.

**Readiness:** B's basic compiler boundary is feasible. Backing-lifetime/budget behavior, physical rendering, color/orientation and performance remain unverified. A2 stays open; this review does not authorize preview or LH-13B implementation.

Only this review document is added to the repository. Existing files are hash-preserved; no build/test/device run or Git mutation occurs in this investigation. Isolated compiler checks are the new evidence. Skill used: swift-concurrency.
