# LH-00 Checkpoint 2 — Player Cutout Handoff Contract

**Current baseline: production Phase 1, 3 November 2026.** Edo authorized the Data-copy handoff implementation after Kevin's approved-with-conditions review and synthetic investigations. This document records that agreement and the implemented CPU handoff. It does **not** declare full CP2, LH-13, LH-14, live input, or physical-iPad validation complete.

## 1. Purpose, decisions and boundaries

Deliver transparent P1/P2 imagery to Kevin with the **exact same-frame CP1 BodySnapshot**, while keeping gameplay evidence independent of image processing and rendering.

**Finalized CP1 invariants:** anonymous `.player1` / `.player2`; generation + frame identity; capture time, camera and per-player calibration revisions; independent accepted calibrations; canonical upright unmirrored measurements; one shared player-plane scale; mirrored player-facing presentation. P1 binds displayed-left and P2 displayed-right during calibration, then identities persist through detection reordering. Uncertain association is unavailable, never a silent identity swap. High-laser Crown + both Wrists and low-laser both Soles + valid Airborne remain Jevon's rules. Image availability never decides damage, health, score or recovery.

**Approved Phase 1 direction:** producer-confined CVPixelBufferPool; explicit independent Data copies; checked Sendable immutable envelopes; combined P1/P2 publication; separate bounded latest-frame channel; straight-alpha BGRA8/sRGB for the tested material path. No CVPixelBuffer, CVMetalTexture, mutable Metal resource or Core Image graph crosses this handoff.

**Rendering direction accepted for the next integration:** front/back surfaces per player, hidden-back upload, GPU completion and context checks before activation; lane-local UV mirroring; full-canvas geometry; straight-alpha soft edges. Depth writing off plus explicit sort grouping is an **isolated-scene candidate**, not a universal production-scene fix. Kevin retains material, tone-map, depth, sorting and actual-frame validation authority.

## 2. Decision history and evidence

| Stage | Finding / resulting decision |
|---|---|
| Initial proposal | Opaque raw pooled-pixel leases and Edo-owned encode/upload bridge were a proposed topology, not an executable production approval. |
| [Synthetic ownership spike](LH-00-CP2-Synthetic-Spike-Report.md) | The original persistent actor-pool transfer failed the complete-concurrency SIL gate; negative control detected forbidden writer access. |
| [Ownership investigation](LH-00-CP2-Ownership-Boundary-Investigation.md) | Characterized 31 compiler variations. Whole-owner transfer was possible in constrained scopes; compiler acceptance did not establish Core Video alias safety. |
| [Runtime comparison](LH-00-CP2-Ownership-Runtime-Comparison.md) | Whole-owner round trips serialize producer progress. Producer-confined pools plus explicit Data copies preserve overlap within bounded admission, at extra CPU/memory cost. |
| [Data/GPU investigation](LH-00-CP2-Data-GPU-Integration-Spike-Report.md) | Tested synthetic Data/staging/Metal/RealityKit path. This was isolated evidence, not production wiring or iPad performance proof. |
| [Alpha/presentation investigation](LH-00-CP2-Alpha-Presentation-Review.md) | Actual straight-alpha conversion improved the tested material path; depth/sort and edge treatment were tested in isolated scenes. Color and full-scene behavior remain integration gates. |
| Current authorization | Edo and Kevin select producer-confined pool + independent Data and tested straight-alpha direction for Phase 1. Kevin owns GPU staging, submission, completion pinning and presentation. Earlier raw-pool transfer and Edo GPU-store API sketches are superseded. |

Previous reports and experimental `Scripts/CP2Spike/` remain historical/reproducible evidence. They are not production dependencies. No experimental UploadStore is copied into Shared.

## 3. Producer/consumer architecture and ownership

```text
One captured frame, original source metadata
  ├─ pose/Motion → immutable BodySnapshot → CP1 stream → Jevon's sole gameplay consumer
  │                       └─ internal same-frame value to cutout work
  └─ masks + stable tracking → producer-confined completed canvases
         → independent Data copy + matching placement + exact BodySnapshot
         → separate PlayerCutoutHandoff (latest pending + one acquired)
         → Kevin: bounded staging → GPU → front/back activation / visual fallback
```

| Owner | Responsibility |
|---|---|
| Edo | Source pool, future segmentation/mask association, completed-pixel copy, alpha conversion, descriptor, source/crop metadata, CPU image budget, immutable packet and channel/context invalidation. |
| Kevin | Separate staging budget, actual render-device handshake, Metal resources/command commits, GPU completion fences, textures, world projection, full-canvas geometry/UVs, same-frame overlays, materials/sorting and visual fallback. |
| Jevon | Capture-to-GameClock conversion, temporal evidence history/selection, gameplay verdicts and pause/recovery policy. Coordinates the renderer's update/freshness hook. |
| Theo | Visual art and fallback/cue appearance with Kevin. |

Shared imports no RealityKit or game-specific code. CP2 references CP1 immutable values; CP1 contains no images. Future BodyInputService supplies an **internal tee** of source status/context and the original BodySnapshot. Do not acquire another CP1 gameplay stream or another independently competing CP1 status subscription. Phase 1 leaves BodyInputService and all live algorithms unchanged.

## 4. Production packet schema

All contracts below have module-internal access in the existing app target; they are not a new framework/public SDK.

| Type | Meaning |
|---|---|
| `PlayerCutoutFrame` | Immutable exact `bodySnapshot`, positive `sourceImageSizePx`, and `players` dictionary containing exactly P1 and P2. |
| `PlayerCutoutSlot` | `.available(image: CutoutImage, placement: CutoutPlacement)` **or** `.unavailable(CutoutUnavailableReason)`. No old image is inserted into a newer source frame. |
| `CutoutImageSource` | PlayerID, sessionGeneration, frameID, original capturedAt, cameraGeometryRevision, calibrationRevision. Created from a validated reliable, calibrated CP1 sample. |
| `CutoutImage` | Immutable checked-Sendable owner of independent private Data, descriptor, source binding and lifetime budget reservation. |
| `CutoutImageDescriptor` | Width, height, actual bytesPerRow, checked byteCount, BGRA8, sRGB, straight alpha, zero-alpha-color policy. Upright unmirrored **top-left raster rows**. |
| `CutoutPlacement` | `sourceCropPx`, `textureContentRectPx`, `playerPlaneRect`; validated in-bounds, uniform mapping. |
| `CutoutUnavailableReason` | notCalibrated, identityUncertain, trackingLost, maskMissing, maskUnmatched, maskAmbiguous, sourceUnavailable, compositionFailed, resourcePressure. |

A throwing frame initializer validates the exact P1/P2 key set and image/source metadata against its attached snapshot. Available imagery requires reliable identity and a nonnil calibration revision. It does not require every collision measurement to be valid: a missing wrist may make high-laser evidence unavailable while a reliably associated cutout remains displayable. Image pixels do not establish the truth of body measurements.

Combined publication is immutable. Two resources may differ in availability but cannot silently come from different source frames. Per-slot unavailability allows the other player to proceed. A mask/composition failure is not a gameplay HIT. There is no pending partial mutation after publication.

## 5. Image representation, copy and alpha contract

The output is 8-bit BGRA, sRGB-encoded RGB and **unassociated/straight alpha**. Alpha is coverage and is not sRGB-transformed. Row padding is zeroed and excluded from visible content. This choice reflects the tested LowLevelTexture/material path; it is not a claim that every RealityKit material expects straight data.

`CutoutPixelCopier` owns one fixed-size CVPixelBufferPool and is intentionally non-Sendable. Keep it on the producer's worker actor, never MainActor for live pixel processing. `makeImage` checks out a source with an allocation threshold, clears it, invokes a synchronous completed-writes callback, then read-locks and copies into a **new Data allocation**. It reserves budget before allocation. Locks are balanced on error. No Data(bytesNoCopy:), retained source address, or transferred CV resource is used. The source can be reused as soon as copying returns.

The callback must finish all source writes before returning, including any producer-side rendering completion. It may not schedule later writers into the buffer. Compiler checking cannot prove Core Video alias discipline inside a producer; runtime source-rewrite tests verify independence of the copied result. Retaining test source aliases stays entirely within the producer actor.

The source alpha convention is explicit:

- `.straight`: preserve color at fractional alpha.
- `.premultipliedSRGB`: input RGB was multiplied in encoded sRGB; validate channel ≤ alpha, then divide in that domain.
- `.premultipliedLinear`: input encodes `sRGB(linearRGB * alpha)`; decode sRGB, divide linear color by alpha, re-encode. Quantization is bounded/clamped. This is different from encoded-domain division.

Do not relabel premultiplied bytes as straight. The producer must know its actual compositing color/alpha convention; real Core Image output must be verified before live integration. Invalid premultiplied pixels are rejected rather than disguised.

At A=0, default `.zeroRGB` writes RGB=0. `.preservedEdgeColor` is allowed only for an already-prepared straight source: it retains hidden edge RGB while alpha stays zero. It does **not** implement dilation or make padding opaque. The spike's edge-extension candidate still requires production review/tuning; no fixed dilation radius is approved. Test light/dark backgrounds, fractional edges, halos, source color accuracy, tone mapping and actual material sampling with Kevin. There is no 0.5 opacity threshold for live cutouts.

### Representation comparison

| Representation | Phase 1 decision |
|---|---|
| Producer CVPixelBufferPool | Confined mutable source storage; allocation threshold on every checkout. |
| Core Image graph | Future producer implementation detail; must complete into known pixels, not cross the handoff. |
| Immutable independent Data | Chosen crossing boundary. Additional CPU copy is explicit; no claimed zero-copy GPU upload. |
| CVMetalTexture / MTLBuffer / texture | Kevin-owned staging/upload only. Must use the actual render-compatible device and separate GPU lifetime limits. |
| RealityKit LowLevelTexture | Kevin's MainActor-facing integration. No calls or resources in Shared. |

## 6. CPU bounds and resource lifetime

`CutoutMemoryBudget` is one shared checked-Sendable object with a small Mutex-protected accounting state. It charges each immutable image **until its last owner releases it**, including old-generation/canceled client references. A channel release revokes permission, not memory held by another owner. Private Data has scoped read-only access; no naked Data getter permits unaccounted no-copy aliases. A consumer may copy into its own bounded staging inside `withUnsafeBytes`, and must not escape the address.

Initial configurable safety ceilings, not measured production budgets:

| Limit | Initial value |
|---|---|
| Per dimension | 2048 pixels |
| Per copied image | 8 MiB |
| All live copied images, across generations/readers | 18 MiB and 6 images, both enforced |
| Producer source checkout threshold | 2 buffers per fixed workspace |
| Pending / acquired presentation frames | 1 / 1, each at most two images |

Use **one budget across the pipeline and replacement contexts**, not a fresh budget to bypass old readers. A fresh composing pair + pending pair + acquired pair fits six image slots when byte limits also permit it. Pressure throws `resourcePressure`; the producer drops/skips imagery or explicitly publishes unavailable outcomes. It does not block CP1 or create replacement pools/tasks indefinitely.

This is not a whole-process or GPU memory cap. Source-pool backing storage, allocator overhead, consumer copies and GPU staging/textures are separate. A pool workspace is fixed-size and serially confined; future orchestration must bound the number of workspaces and retain at most the allowed source frames. Every allocation uses the pool threshold. Consumers cannot force-free in-use data. A permanently retained lease can exhaust CPU admission safely; recovery requires releasing owners, not reclaiming their addresses.

For reference, two 512×768 tightly packed images are 3 MiB; six are 9 MiB. Four equivalent BGRA8 front/back textures are 6 MiB total, 3 MiB above one texture/player, excluding framework/staging buffers. Those texture bytes are Kevin's separate budget.

## 7. Actual handoff API and lifecycle

The production control surface is lightweight MainActor state, not a worker/image-processing actor:

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
// Concrete producer ingress, not exposed as consumer authority:
// PlayerCutoutHandoff.updateInput(_ event: BodyInputStatusEvent) throws
// PlayerCutoutHandoff.offer(_ frame: PlayerCutoutFrame, at now: Double) throws
```

`CutoutLease` contains an opaque token, consumer token, original frame and `availablePlayers` compatible **at acquisition**. It is not mutable GPU storage. Recheck `isCurrent` per player after suspensions and before activation. The original frame is never rewritten to disguise a changed context.

1. The authoritative source owner forwards ordered CP1 input events. Exact duplicate events are idempotent; a conflicting or older source statusRevision is rejected atomically. This retains CP1's monotonic source revision across generations.
2. A running active context can accept one claimed consumer even before both calibrations exist. Explicit unavailable outcomes can flow then; this does not permit Jevon's countdown to begin early.
3. Each offer validates generation, camera, compatible per-player calibration/cutover, freshness, budget identity and capture-sequence order. Only strictly increasing frameIDs are admitted. The watermark persists after acquisition and across camera/calibration changes within a generation. Older delayed completions and duplicates never replace a newer pending frame.
4. One pending frame is replaced wholesale by a newer offer. One acquired lease can coexist; a second acquire returns nil while it is held. No unbounded queue or per-frame delivery task is created.
5. Calibration replacement/removal invalidates affected slots immediately through current-context checks. An unchanged compatible player may continue. Reacceptance must honor CP1 cutovers, not revive old pixels by reusing a revision number.
6. A camera change invalidates pending and acquired imagery. A generation change also revokes the old consumer and resets that generation's watermark. Interruption/failure clears imagery; stop also revokes the claim. Neither renderer cancellation nor release independently stops camera/input.
7. Release is token-protected and idempotent for stale tokens (`false`). Late old callbacks cannot clear a replacement lease or claim. `releaseConsumer` revokes its lease and leaves a compatible latest pending frame available for reattachment. There is no forced timeout reclamation.
8. Consumers use cancellation-aware structured cleanup (`defer` release/claim cleanup on MainActor). Cancellation alone does not free references another owner retains. GPU-read staging remains Kevin's until GPU completion even if the CPU claim is canceled.

### Independent context/status observation

One synchronous MainActor observer receives `.state(CutoutHandoffState)` with local revision and the exact input event, including **immediate current-state replay**. Starting/running/interrupted/failed/stopped and calibration/camera changes remain observable with no images. No lossy status buffer hides rapid transitions.

`.imageAvailable` is a coalesced wakeup, not another image queue. State callbacks must stay short. Control reentry during a callback throws `reentrantControl`; state reads are safe. Schedule one coalesced consumer drain outside the callback, not a task per frame. Acquiring while busy is nil; releasing a lease wakes a waiting latest frame. A single observer token prevents silent competing presentation owners.

Input-event `occurredAt` is the original transition timestamp, **not a transport-arrival clock**. It must not expire a later captured pending frame. Freshness uses explicit current time at offer/acquire/presentation checks.

## 8. Full-pipeline admission and CP1 independence

Phase 1 implements the bounded copy workspace, total image reservation and output/lease channel. Future live orchestration must maintain these additional bounds; this document does not claim those algorithms exist:

| Stage | Required bounded policy |
|---|---|
| Captured frames awaiting cutout work | One replaceable latest candidate, no camera history retained for imagery. |
| Active instance segmentation/composition | One serial job initially. Check generation/context before and after work. Cancellation can discard results; do not assume Vision computation is interruptible. |
| Source retention | One active source plus latest candidate; fixed source canvas checkout threshold. No waiting for renderer return to publish CP1. |
| Completed copies | Reserve global byte/image budget before allocation; bounded work-in-progress pair. Errors release reservations. |
| Pending / acquired | One latest combined frame / one explicit lease. A slow consumer supersedes pending frames. |
| GPU work | Kevin bounds staging, active upload and surfaces separately; no in-use staging reuse before completion. |

Only immutable values cross to MainActor. Pixel copying/conversion stays on the producer worker. Phase 1 tests demonstrate **no scheduling/release dependency** on CP1 publication; they do not measure absence of CPU/GPU contention on iPad.

## 9. Synchronization, time and freshness

The frame carries the **original exact BodySnapshot** used for image placement/overlay association. Kevin must not position it using a later `latestSnapshot`. Processing completion and capture order can differ; no timestamp/frame rewriting is allowed.

Presentation synchronization differs from gameplay synchronization. Jevon may select an earlier temporally eligible snapshot for a crossing. Display and verdict frame IDs need not match. Proposed bounded diagnostics compare displayed generation/frame/capture time versus Jevon's selected evidence and the host-time display/update observation. Jevon reviews this diagnostic handoff; it neither changes evidence selection nor turns imagery into authoritative collision evidence. No participant imagery/raw recording enters diagnostics.

Live CP1 `capturedAt` targets Core Media host-clock seconds. The future camera adapter converts sample timestamps into that clock using their actual timebase relationship. Kevin can read the same host clock on MainActor; never compare Date, an unrelated uptime clock or a wall-clock offset. Replay/tests inject deterministic compatible `now` values. Shared Phase 1 accepts `now` explicitly and does not create another game clock.

`CutoutFreshnessPolicy.maximumCaptureAge` is optional and configurable. Nil disables the age ceiling for explicit untuned/synthetic operation; finite compatible time and no future captures are still required. **No production expiry/hold duration has been approved.** Kevin must supply a reviewed ceiling and evaluate expiry without new arrivals via his render/update hook, coordinated with Jevon.

Fallback recommendation: short configurable last-good hold, then the existing pictogram; immediate invalidation for incompatible generation/camera/calibration or identity loss. A prior image held for fallback must retain its original metadata and lifetime reservation. The handoff never relabels it as the new frame.

## 10. Geometry, whole-canvas presentation and mirroring

Internal imagery and measurements are upright/unmirrored. Source crop edges are bottom-left pixels; output canvas rows and content-rect edges are top-left pixels. The canonical `playerPlaneRect` is Y-up, floor-compatible, and covers the **content rectangle**, not the entire padded canvas.

For canvas `W,H`, content rect `(cx,cy,cw,ch)` in top-left pixels and canonical rect `(gx,gy,gw,gh)` in bottom-left game units:

```text
sx = gw / cw                 sy = gh / ch       (uniform sx ≈ sy)
quadWidth  = W * sx          quadHeight = H * sy
quadLeft   = gx - cx * sx
quadBottom = gy - (H - cy - ch) * sy
quadCenter = (quadLeft + quadWidth/2, quadBottom + quadHeight/2)
```

Kevin derives both size **and translation** from these values and uses full 0–1 UVs. Transparent padding must not enlarge, shift or independently stretch the actual body. Source crop → content fitting is uniform (integer fitting may round); the producer supplies a compatible canonical rect using CP1's shared scale, preserving height differences. The validation tolerance is a numerical/rounding check, not a physical camera tolerance or new scale calibration.

Mirror once about the assigned lane center `L`: horizontal texture coordinates use the compatible `u → 1-u` transform, while positions/debug geometry reflect `x → 2L-x`; full-quad center reflects too. Do not apply a negative world scale or flip the whole world. P1/P2 lane assignments do not swap. Kevin verifies actual texture V orientation, UV basis and culling with asymmetric corner markers rather than guessing an additional flip. GameWorldMapping remains Kevin's production responsibility.

## 11. P1/P2 mask association and missing imagery

Future instance segmentation provides instance masks, not guaranteed persistent identities. Edo must associate masks to already-tracked slots using pose/region evidence and compatible source frame information; never assign slots by Vision/mask array index. P1 initially binds mirrored-preview left, P2 right. Overlap, ambiguity, missing masks and reentry require explicit unavailable outcomes or revalidated tracking, not an unnoticed UUID/slot swap.

Soft mask edges do not prove correct identity. Source body association and edge quality are separate validation tasks. Live matching, reentry thresholds and segmentation quality are outside this Phase 1 implementation.

If only one slot is usable, preserve the other slot's unavailable outcome in the same combined frame. If Kevin's later upload succeeds for one slot and fails for the other, he may activate only the successful, still-compatible slot with the original source metadata and apply fallback to the other. Do not mutate the published packet or pretend both uploads succeeded. Any coupled two-player visual activation policy is Kevin's reviewed presentation decision, not a gameplay rule.

## 12. Kevin's GPU integration boundary

Kevin owns the complete Data → bounded staging → texture path. Shared supplies only immutable bytes, metadata and revocable lease permission. The old raw-CV acquire/prepare/encode/submit store interface is removed.

Recommended consumer sequence:

1. Claim the current generation and observe state/wakeups. Schedule a single bounded drain outside the synchronous callback.
2. Acquire latest with current host-clock time. Inspect only compatible `availablePlayers`; copy bytes into separately budgeted staging inside `image.withUnsafeBytes`. Honor actual row stride.
3. Use the rendering host's actual compatible MTLDevice. Kevin creates cache/texture/staging resources as needed; do not infer host device access from a compiler-only test.
4. Upload to hidden back surfaces. Kevin is the single command-buffer commit authority. Bind staging lifetime and completion records before commit. Precommit failure releases his unused resources; postcommit cancellation never reclaims GPU-read staging early.
5. Keep the CPU lease through completion for the simplest validity path. On MainActor, call `isCurrent` for each slot with current host time, then activate compatible texture/placement/debug metadata together without suspension. Release and drop the CPU lease afterward. Releasing it earlier revokes activation permission; it is not a reusable post-release GPU authorization token.
6. Generation/calibration/camera changes or cancellation prevent activation. Handle per-player failure/fallback explicitly. Old callbacks cannot release newer claims.

Primary texture candidate remains two persistent front/back surfaces/player; secondary single-resource visibility gating is a comparison only. GPU completion proves writes finished, not atomic RealityKit application or display scanout. Kevin must verify same-rendered-frame behavior, transparent sorting/depth, laser glow in front/behind, no opaque padding, color/tone mapping and actual scene anchors. ModelSortGroupComponent is a tested isolated candidate, not an assumed general fix.

## 13. Production implementation locations and current status

Paths below are relative to the repository root.

| File | Phase 1 role |
|---|---|
| `Sedactive/Shared/BodyTracking/Capture/PlayerCutoutFrame.swift` | New framework-independent packets, descriptor, rects, source binding, errors/limits. |
| `Sedactive/Shared/BodyTracking/Capture/PlayerCutoutCompositor.swift` | Existing skeleton now contains producer-confined pixel copier, checked immutable Data owner and shared memory reservation. No live compositing algorithm. |
| `Sedactive/Shared/BodyTracking/Capture/PlayerCutoutHandoff.swift` | New MainActor provider protocol, bounded channel, claims/leases, context/status, freshness checks. |
| `SedactiveTests/Shared/BodyTrackingTests/CutoutContractTests.swift` | Synthetic actor producer, packet/descriptor/alpha/provenance tests. |
| `SedactiveTests/Shared/BodyTrackingTests/CutoutMemoryTests.swift` | Real source-pool reuse, independent bytes, padding, limits and cleanup. |
| `SedactiveTests/Shared/BodyTrackingTests/CutoutDeliveryTests.swift` | Mock consumer, latest-frame/claim/release/order/backpressure and CP1 independence. |
| `SedactiveTests/Shared/BodyTrackingTests/CutoutLifecycleTests.swift` | Context/revision invalidation, status and controlled cancellation. |

The existing CP1 implementation/tests/JSON are unchanged. Files join existing filesystem-synchronized app/test targets; no project settings or target changes. Production code is **not wired** into BodyInputService, App, Kevin's renderer or a live camera. Synthetic unit tests exercise the actual production API. Spike code remains isolated and is not imported into production.

## 14. Deterministic acceptance and device gates

Phase 1 tests cover exact two-slot identity/source association, rejected mismatches, invalid descriptors/overflow, padded row strides, real straight/premultiplied conversions, zero-alpha policies, source rewrite/reuse after copy, writer failure, source threshold, global byte/count limits, foreign-budget rejection, one consumer/lease, pending replacement, duplicates/late frames, freshness, stale release, cancellation/reattachment, generation/camera changes, calibration removal/reacceptance/cutovers, independent ordered status/current replay and CP1 progress while imagery is held. Cancellation uses controlled continuations, not timing sleeps.

Run complete-concurrency SIL compilation and warnings-as-errors on handoff and tests under the actual project conventions. A forbidden persistent copier transfer is a negative control that must fail. Compiler acceptance is necessary, not proof of runtime alias safety. No unchecked Sendable, unsafe isolation or concurrency suppressions are permitted. Do not permanently change Swift/B2 settings.

See [the Phase 1 report](LH-00-CP2-Production-Phase-1-Report.md) for actual commands/counts and limitations. Synthetic tests do not validate real masks, actor scheduling under camera load, GPU latency or physical iPad display behavior.

Physical-device / Kevin integration gates include source-alpha/color verification from real composition, bounded render staging, actual scene layering, head/sole/overlay alignment, fractional edges on light/dark backgrounds, fast frame changes, interruption/recalibration fallback, thermal/CPU/memory latency and idle expiry. Keep raw participant imagery out of diagnostic logs. No production numeric latency, FPS, scale-drift, hold or segmentation thresholds are implied.

## 15. Decision register and readiness

| Category | Status |
|---|---|
| Cross-owner contract invariants | Approved combined exact-CP1 frame, stable P1/P2, canonical placement, mirrored presentation, separate bounded delivery and unchanged ownership. |
| Ownership carrier | Approved for this production phase: producer-confined source pool + independent immutable Data. Raw pooled-buffer transfer is superseded. |
| Alpha / texture / sorting | Straight-alpha direction approved for the tested path. Front/back and isolated depth/sort direction accepted for Kevin's integration; actual production materials/scene/color remain validation gates. |
| Edo implementation defaults | One pending + one acquired, one observer/consumer, shared retained-Data accounting, thresholded serial source workspace, strict source ordering and explicit cancellation. Implemented and tested locally. |
| Parameters requiring tuning | Canvas resolution, pool/byte/count budgets, capture-to-display freshness ceiling, fallback hold, edge-color extension, source scale/distance tolerances and performance. |
| Kevin review/integration | Render-device acquisition, separately bounded staging, failure/commit/completion handling, lease checks, geometry/UVs, live material/color, actual-frame activation and sorting. |
| Jevon coordination | Source-status tee wiring with Edo, idle update/freshness hook, optional display-vs-verdict diagnostics and session recovery. No new CP1 reader or evidence-selection rule. |

**Readiness:** the CPU packet/copy/handoff foundation is locally implemented for Phase 1; Kevin can integrate against the concrete consumer API after review. This is not full production CP2 completion. Phase 2 renderer integration and future live producer work require separate authorization. No genuine Phase 1 ownership/compiler blocker is accepted or bypassed; actual verification and any limitations are reported separately.
