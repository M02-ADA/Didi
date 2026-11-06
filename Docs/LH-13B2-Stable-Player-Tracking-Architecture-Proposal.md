# LH-13B2 — Stable Anonymous Two-Player Tracking Architecture Proposal

5 November 2026 · Author/owner: Edo · **PROPOSED — design review only; implementation not authorized.**

## 1. Verified baseline and authority

The current checkout contains accepted B1 raw Vision extraction. At the first inspection it was on `feat/vision-pose`, HEAD `ba4da2d206feb48754ba4e5020fc713f2319d253`. During read-only inspection an external checkout change occurred. Reinspection found **`staging`, HEAD/local `origin/staging` `1a48e19971c8440a40d014ce29a091f00418e0f8`**, merge PR #19 from `feat/vision-pose`; the B1 implementation commit is an ancestor. Final inspection found another external branch change to **`feat/player-tracking` at the same merged HEAD `1a48e19971c8440a40d014ce29a091f00418e0f8`**. This task performed no branch creation/switch, fetch, merge or other Git mutation. Local remote-tracking references are inspected evidence, not a new remote-server freshness check. The proposal uses the merged source now present; no source baseline changed between those branch observations.

Entry unrelated work: two app signing-team line changes in `Sedactive.xcodeproj/project.pbxproj` and untracked `Scripts/`. Preserve both. No Swift, test, fixture, project or existing document changes are authorized here.

Read AGENTS, TEAM_ALIGNMENT, the lean architecture/reference, accepted LH-13 plan, B1 report including Final Acceptance Addendum, A2 transform approval, current capture/pose/preview seams, CP1 identity/provider/calibration contracts and relevant tests. Current approved product/contracts override historical profile, selection and feature-status wording in older architecture tables. Shared remains game-independent; folders are logical modules in one app target.

| Actual item | Verified implementation / consequence |
|---|---|
| `Capture/PoseEstimator.swift` | Synchronous worker-local `VNDetectHumanBodyPoseRequest` through `.up` request handler. Numeric conversion preserves 14 existing joint types, anatomical sides and positive raw confidence; absent/invalid points are omitted. |
| `Capture/CameraPoseResults.swift` | One latest immutable result, source/context/ticket/order gates, bounded counters/windows. No pose history, subscription or persistent identity. |
| `Models/PoseFrame.swift` | Immutable Sendable candidates; `candidateID` is frame-local. Contains generation/frameID/capturedAt/geometry/dimensions. Epoch and applied orientation remain in capture's internal envelope. |
| `Capture/FrameStore.swift` | One bounded source consumer; `CameraCopySink` actor owns reconstruction and synchronous Vision. Raw limits 4 MiB/frame, 12 MiB retained; single reconstructed workspace cap 4 MiB; optional preview separate. |
| `Processing/PlayerTracker.swift`, `MotionEngine.swift` | Skeletons, not working tracking/composition. `PlayerTrackerTests.swift` is also a skeleton. |
| `Shared/Players/Player.swift` | Only anonymous `.player1` / `.player2`; no profiles or selection ordering. Binding is scoped by session generation. |
| CP1 | `TrackingStatus` has `reliable`, `uncertain`, `lost`; no `unbound` case. `PlayerBodySample` forbids valid mapped evidence for uncertain/lost or uncalibrated players. Existing provider/calibration acceptance stays unchanged. |
| LH-22 / later live provider | Standing estimator, measurement/jump processing and live provider integration are not implemented by B1 and are not authorized here. |
| Tests/evidence | B1 report records 180 definitions / 273 executions, no failures/skips; successful Simulator/Release/device builds and strict ownership checks. Physical two-person result: 11/14 and 14/14 joints; extended 326.663-second cumulative session: 9,792 results. These are historical B1 evidence, not newly run B2 tests or tracking accuracy proof. |

Settings inspected: Swift 5 language mode, default MainActor, approachable concurrency, MemberImportVisibility, deployment 26.5. B1 reports Xcode 26.6 / Swift 6.3.3 / SDK 26.5. No toolchain build or device run is performed by this documentation task.

Apple's supported pose request returns per-image observations with normalized joint locations and confidence; zero-confidence points are invalid. That is input evidence, not a persistent person-identity service. See [Apple: Detecting Human Body Poses in Images](https://developer.apple.com/documentation/vision/detecting-human-body-poses-in-images) and [VNHumanBodyPoseObservation](https://developer.apple.com/documentation/vision/vnhumanbodyposeobservation). The association policy below is our proposed design, not an Apple accuracy guarantee.

## 2. Scope, safety and alternatives

**Goal:** associate current raw candidates with two anonymous slots over a bounded continuous observation interval. Never rename slots merely because screen positions cross or Vision reorders results. No facial recognition, appearance embedding, profile recognition or personal identity storage.

**Safety invariant:** do not publish a confident association when retained evidence supports competing identities. Refusal is a valid output. Pose geometry cannot guarantee personal identity after an unobserved substitution, complete occlusion or an indistinguishable crossing. No claim of universal swap prevention is possible from these inputs. The implementation must expose uncertainty and require explicit rebind where continuity cannot be established; it must never guess silently.

| Alternative | Benefit | Limitation / recommendation |
|---|---|---|
| Sort candidates by X each frame | Smallest code | Renames players at crossings and ignores extra detections. Reject after initial binding. |
| Independent nearest-center matching | Cheap | Both slots may select one candidate; ignores missing evidence and alternatives. Reject as sole matcher. |
| Two-slot, gated global assignment with small motion/torso descriptors | Evaluates conflicts, partial matches, uncertainty and extras within a small fixed bound | **Recommended.** Conservative geometric continuity, not biometric recognition. |
| Kalman/Hungarian/general multi-object tracker or image-feature tracker | More elaborate motion/appearance models | Additional state/tuning/framework ownership without evidence it is needed. Not the first phase. Reassess only from measured failures. |

Use a pure deterministic state transition core inside existing Processing, with synchronous worker-owned composition. No new app-wide reducer framework, tracking actor, target, package or generic engine. This fits the existing lean architecture and one-worker ownership model.

## 3. Initial P1/P2 binding

Binding is an **explicitly armed operation** for a particular source context and request token. Camera running or seeing two detections does not arm it. A controlled driver can arm it during B2 verification; Jevon later owns which calibration/session phase requests it. Shared does not infer game phases or start countdown.

Proposed acquisition gate:

1. Validate active context, source presentation and monotonic source time/order (§9). No existing lost slot is eligible for automatic replacement.
2. Require exactly two independently eligible, spatially distinct torso candidates, with no unresolved duplicate/extra-person hypothesis or retained-cap overflow. Clearly unusable observations may be excluded for stated joint/geometry reasons, not merely to get a pair. An extra potentially valid body blocks initial binding.
3. The proposed initial experimental policy requires all four shoulders/hips with reviewed confidence and nondegenerate torso geometry. This is an acquisition-quality requirement; ankles, wrists, face or equal heights are not required. Partial-body acquisition waits rather than inventing a center. Exact confidence/stability/duplicate/separation gates need approval and tuning.
4. Evaluate their separation and stable continuity across a bounded acquisition dwell measured in **capture time**, not just a frame count. Both remain in distinct intended display halves, outside a reviewed center guard region. A pair cannot be confirmed from one transient duplicate detection. Stability does not mean perfectly motionless bodies.
5. With canonical unmirrored center X, display X is `1-x`: **larger canonical X becomes displayed-left P1**, smaller canonical X becomes displayed-right P2. Require that each occupies its intended half; equality/near-center ambiguity waits. Screen dimensions/letterboxing do not change this ordering.
6. Commit the pair atomically only after a unique stable acquisition. Do not bind P1 now and pick an unrelated P2 later. Return both slots even when acquisition is incomplete, with state unbound and no current matched pose.

After commitment, the half/left-right rule is no longer an association rule. P1 can move to displayed-right without becoming P2. Slot-to-game-lane placement remains the existing CP1/CP2 convention; B2 does not reposition rendered players or change gameplay geometry.

Initial pair acquisition keeps only two provisional descriptors, capture-time dwell and ambiguity flags, not a growing list of acquisition frames. Any candidate swap/ambiguity during acquisition resets the dwell. No masks or standing baselines are needed to prove raw binding; calibration is a later independent gate.

## 4. Recommended association algorithm

### 4.1 Current-frame descriptors

Construct descriptors from the existing 14 joints only. Do not silently require unavailable knees, elbows or a new Vision root joint. Preserve the complete raw candidate unchanged; derived descriptors are matching aids.

Use confident shoulder/hip **pairs** and their midpoint, shoulder/hip widths and shoulder-to-hip torso vector/length. Use shared anatomically named core joints for residual comparisons. Centers must carry their anchor kind and contributing-joint set: never compare a shoulder midpoint to a previous hip midpoint as if they represented the same body center. A missing torso part reduces the available evidence; it does not become `(0,0)` or a historical measurement.

Initial full-torso binding establishes reference geometry. Continued partial-body association may use a surviving corresponding shoulder or hip pair plus sufficient additional shared core support, under a separately reviewed coverage/gating rule. If support is insufficient, refuse association. Wrist/ankle motion and head landmarks are optional corroboration, not primary identity anchors. Arm movement must not drag a whole-body center through a wrist-based fallback.

For image-space distances use `q = (x * imageWidth/imageHeight, y)` to avoid aspect-ratio distortion. This is only a matching metric. Published coordinates remain the original normalized values. Different standing heights and torso dimensions may corroborate continuity but cannot identify a person or reject a height mismatch by themselves. Scale estimates must not update a standing calibration baseline.

### 4.2 Bounded prediction and costs

Keep the last **two confirmed** descriptors/times for each slot. Predict the next corresponding anchor using capture-time deltas and a reviewed bounded velocity/extrapolation horizon; with only one usable sample, use a conservative position gate. Cap movement uncertainty by a reviewed maximum horizon rather than widening gates forever. A long gap disables identity-confirming prediction and requires uncertainty/loss handling.

A candidate-to-slot edge is admissible only when shared-joint coverage, confidence, displacement, elapsed-time and geometry gates pass. Its cost combines normalized anchor displacement, confidence-weighted shared-core residuals and weak scale/torso consistency. Use the same comparable terms across competing edges; absence of a term cannot make an under-supported candidate win cheaply. Low-quality candidates have explicit coverage penalties or are ineligible, rather than receiving a zero residual.

Weights, gate sizes and prediction bounds are named policy values, not final constants in this document. Raw confidence weights are not probabilities of identity. Prediction aids matching and is never emitted as a detected joint or gameplay measurement.

### 4.3 Global matching with refusal

For at most eight retained candidates, evaluate all injective assignments of P1/P2 to different candidates **including unmatched outcomes**. With eight candidates there are at most `8*7 + 2*8 + 1 = 73` assignment hypotheses. Evaluate all retained competitors; never choose the first two, independently match two slots to one candidate, or maximize cardinality regardless of support.

Compare the best admissible hypothesis with alternatives, including partial/unmatched hypotheses, using reviewed minimum support and separation margins. Unmatched penalties are explicit policy, not infinity. Require unique candidate-to-slot support and adequate best-versus-alternative separation. Numerical ties remain ambiguity; array index is never an identity tie-breaker. Detect near-coincident duplicate torso candidates as competing evidence rather than treating them as two proven people or silently deduplicating them into a confident match.

If global hypotheses disagree on P1 but agree convincingly on P2, only P2 may remain tracking. If they exchange both identities or conflict on a shared candidate, both are uncertain. Preserve unresolved alternative reachability conservatively within bounded per-slot uncertainty summaries. Do not erase ambiguity simply because one guessed track has been repeatedly updated. Do not update confirmed anchors/velocity/shape from tentative matches.

Crossing is permitted when independently supported motion and shared geometry keep assignments unique. If two paths become indistinguishable at overlap, refuse them; later left/right separation alone cannot restore identities. Any case requiring multiple persistent trajectory branches exceeds the recommended minimal tracker: require explicit rebind rather than silently add an unbounded hypothesis history.

## 5. Per-player states and output seam

Use a Processing-internal state enum; **do not extend CP1 `TrackingStatus`**. Each result contains exactly P1/P2 outcomes, original source provenance and a reason. Only `tracking` includes a current candidate association. A candidate can belong to at most one slot per frame.

| State | Meaning / current output | Main transitions |
|---|---|---|
| Unbound | No established person. No current candidate for the slot. | Armed unique pair acquisition → both tracking. Incomplete/ambiguous acquisition → remain unbound. |
| Tracking | This frame has sufficiently supported unique association. Raw joints remain raw and may be missing. | Missing/weak/competing observation, failed inference or excessive gap → uncertain immediately; lifecycle/context invalidation → unbound under invalid binding authorization. |
| Uncertain | Previously bound; continuity may still be recoverable. No confidently assigned current pose. Preserve bounded last-confirmed descriptor and competing-reachability flag. | Only reviewed unique recovery supported over capture time → tracking; expired horizon, impossible continuity or unrecoverable identity ambiguity → lost. |
| Lost | Original identity cannot safely be established with retained evidence. No current association; no automatic new entrant binding. | Explicit authorized full rebind with new generation → unbound, then pair acquisition. No automatic lost → tracking. |

An accepted current frame with zero candidates is a successful negative observation, not an inference failure. Both tracks become uncertain, then lost if the reviewed capture-time loss horizon is exceeded. One supported visible player may remain tracking while the other is uncertain/lost. Partial exit follows evidence quality, not an automatic state based solely on image X.

For future CP1 integration, internal tracking maps to `reliable` only for the current supported association; uncertain maps to `uncertain`; unbound/lost map conservatively to `lost`, with more specific reasons kept internally. This is a proposed future adapter in LH-13C, not live BodySnapshot publication now. Even reliable identity does not make all joints or calibrated measurements valid.

Proposed small internal value seam, names/signatures to confirm during later implementation review:

- Input: immutable PoseFrame, capture-internal epoch, retained/total observation counts and a current control/binding token. The capture adapter supplies exact metadata from the same CameraPoseResult; Processing does not import CameraPipeline or access CV/VN objects.
- Control: arm binding, disarm/reset, source interruption/failure, and explicit observation-expiry evaluation using injected host-clock time. No game phases or GameClock conversion.
- Output: immutable original source key plus exactly two slot outcomes (state, reason, optional current candidateID) and bounded association diagnostics. Optional candidateID always refers to that exact source PoseFrame. Raw poses are not cloned into a persistent tracked history.
- Owner: one synchronous PlayerTracker value within the worker-owned MotionEngine composition. No second authoritative player dictionary in diagnostics/App/provider.

This seam is not a new CP1/CP2 public contract. Do not attach a PlayerID to raw PoseCandidate or alter its frame-local candidate semantics.

## 6. Confidence, uncertainty and recovery

Keep four separate meanings:

| Layer | Meaning | Must not imply |
|---|---|---|
| Raw Vision joint confidence | SDK's per-point value, preserved by B1 | Identity confidence or calibrated measurement validity. |
| Association evidence | Coverage, motion/geometry residuals, competing-match margin and reason | A calibrated probability or guaranteed personal identity. Prefer categorical sufficient/ambiguous/insufficient plus diagnostic costs. |
| Tracking state | Whether this slot has a supported **current** match | All joints exist, both players are calibrated, or countdown is allowed. |
| Future evidence validity | Per-measurement tracking + landmark + calibration + source/freshness compatibility | Determined by B2 alone or by a joint-confidence average. |

The DEBUG `<0.3` label is not an approved threshold. A single high-confidence joint cannot compensate for missing independent torso support. Missing one wrist need not lose a clearly associated torso; it still invalidates that wrist for a later high-laser assessment. B2 does not perform that judgment.

**Recovery proposal:** permit uncertain → tracking only inside a finite recovery horizon, with adequate corresponding core evidence, unambiguous separation from the other slot and all plausible competitors, no unresolved identity-exchange flag and a reviewed confirmation dwell. Do not output tentative poses during this dwell or update confirmed history from them. Retain at most one provisional recovery descriptor per slot; reset its dwell on conflicting evidence. A single returning detection near an old X is not sufficient.

Once lost, or after a gap/occlusion through which either identity could have exchanged, do not restart identity from the current left/right order. Expose rebind-required. A full rebind establishes new persons in a **new generation**, invalidating old standing/calibration compatibility through the later provider workflow. No automatic timeout replaces a person. An unobserved, geometrically indistinguishable substitution remains a limitation of pose-only association even with these safeguards; review any stronger product identity guarantee before implementation.

## 7. Extra people, duplicate detections and overflow

- Initial binding: extra eligible/ambiguous candidates block acquisition. Do not assert every observation is a real distinct person.
- Established tracks: inspect all retained candidates. An unmatched third detection may be ignored only if both retained identities remain uniquely supported and that competitor fails to challenge either assignment. Report extra-candidate presence numerically. No assignment to a lost slot, even if the entrant is alone in the expected lane.
- A spurious duplicate close to an established candidate can invalidate uniqueness; do not force an association because the screen appears to contain two people.
- If `observationCount > frame.candidates.count` (B1 cap overflow), incomplete competitor evidence prevents safe matching. **No new binding or confident association from that frame.** Established slots become uncertain with overflow reason; retain confirmed anchors only within the normal recovery horizon. Do not change B1's cap or claim discarded candidates were harmless.
- More than two candidates within the cap does not automatically fail established tracking if competitors are demonstrably noncompetitive. Ambiguity, not array count alone, decides refusal; overflow is a separate conservative failure because candidates were omitted.
- Failure/no new input never means a person safely ducked, jumped or left. Distinguish inference failure, zero detections, stale source, ambiguity and source interruption.

## 8. Lifecycle, reset and calibration boundaries

| Event | Required behavior |
|---|---|
| Reordered candidates / crossing image X | Preserve slot identity by supported continuity; no lane-based rename. |
| Duplicate/older frameID, nonincreasing/nonfinite capturedAt | Reject without advancing tracker history, acquisition/recovery dwell or current source key. Skipped frameIDs are allowed; use actual capture-time delta. |
| Gap too large for reviewed prediction | Clear velocity usefulness; uncertain/lost as applicable, never a huge proximity gate. |
| Stop, interruption, failure, suspend | Immediately make exposed output incompatible/unavailable through existing lifecycle/token path, even with no next frame. Clear binding authorization and invalidate pending computation. |
| Same generation/epoch resume | A new control token still invalidates pre-suspend work; conservative default requires explicit fresh binding authorization. Do not carry reliable state through an invisible interval. If this means re-establishing persons, request a new generation. |
| Generation, epoch, geometry, dimensions/presentation incompatibility | Clear both histories, predictions, provisional dwell and output. No first-frame automatic binding. New explicit arm is required for the current context. |
| Explicit tracker reset / deliberate person replacement | Full pair rebind, new generation. No silent one-slot reinitialization carrying old calibration. |
| Recalibration of continuously tracked same people | Does not by itself rename or reset identity. LH-22 requests use the current bound identities. LH-13C owns accepted revisions/full replacement/cutovers. If recalibration entails uncertain/new people or geometry, reset/rebind first and invalidate old compatibility. |
| Calibration removed/reaccepted | Cannot create tracking confidence or restore old identity. B2 does not own the accepted dictionary. Provider evidence compatibility remains governed by CP1. |

No-frame freshness is separate from source-frame evidence: expose a derived unavailable/uncertain status when an injected current host-clock evaluation exceeds the reviewed observation-age policy. Retain original capturedAt and source key; never invent a new PoseFrame to report timeout. Use the existing diagnostics/status control path for later integration, not a second observer or gameplay clock. Deterministic pure tests inject expiry events; live expiry/control wiring requires separate approval. A frozen latest numeric result must not remain advertised as currently reliable indefinitely.

## 9. Concurrency, publication and finite memory

```text
existing capture → bounded FrameStore → one CameraCopySink actor
  → existing reconstruction + synchronous worker-local Vision
  → immutable CameraPoseResult
  → narrow immutable input adaptation → worker-owned MotionEngine / PlayerTracker
  → context/token-validated latest diagnostic outcome (later scoped integration)
```

Do not poll CameraPoseResults from a new tracker task/stream consumer. Sequential processing consumes the original admitted source once. Tracking operates only on immutable numeric values; Vision/CV ownership, capture callback responsiveness and preview pipeline stay unchanged. No per-frame Task or image retention is needed.

Finite proposal:

- Two slot records; two confirmed descriptors and at most one provisional acquisition/recovery descriptor per slot. Each descriptor contains only a fixed subset of the existing 14 joints and scalar summaries.
- Two bounded uncertainty/reachability summaries, dwell timestamps, source/control keys and reason enums. No trajectory tree, ever-growing candidate registry or appearance archive.
- At most eight transient current-frame descriptors and 73 assignment hypotheses; no persisted candidate history. Hypotheses can be evaluated incrementally, retaining only best/competing costs and conflict summaries.
- One current immutable result for diagnostics, plus existing bounded statistical windows (at most 1,024 samples if reused). No extra raw-source budget, pixel buffer, image queue or CV/VN reference.

Worker state is authoritative; the MainActor reads a projection only. Source lifecycle changes may invalidate visibility while synchronous Vision is still executing. Use the existing context/ticket token plus a binding/control revision at publication. Recheck before processing and at publication. A stale finish cannot publish, advance a new-context track or complete a replaced binding request. On next worker entry, compare control/context and reset old local state before accepting any new frame; existing awaited worker reset releases old state. Do not hold a Mutex during Vision or tracker computation. The minimal implementation must test these races; merely checking cancellation is insufficient.

Stage transition computation without suspension and commit only for its authorized control/context; if completion is rejected, discard its staged state or require reset before reuse. Any one-frame latest result sharing the existing raw-result cache must be published with the raw source under the same gate, rather than independently combining latest raw and latest tracking values. Do not add a second observer to the diagnostics controller's already-claimed status route.

Preserve Swift 5/default MainActor conventions with explicit checked Sendable values and a nonisolated pure core, actor confinement for the one mutable composition owner. Later verification must repeat complete strict concurrency, warnings-as-errors, SIL/WMO and object compilation plus meaningful ownership negatives. No unsafe annotations or global settings change is acceptable. This proposal has no new compiler-validated API claim.

## 10. Exact proposed file impact and phased approval

Paths are repository-relative. **None of these source/test changes is made now.**

| Phase / file | Proposed change / owner |
|---|---|
| First bounded core: `Sedactive/Shared/BodyTracking/Processing/PlayerTracker.swift` | Edo: implement pure tracking states, finite descriptors, policy validation, assignment, binding/recovery/reset and internal immutable input/output values together. Avoid splitting small support types prematurely. |
| First core: `SedactiveTests/Shared/BodyTrackingTests/PlayerTrackerTests.swift` | Edo: replace skeleton with real synthetic sequence tests. In-memory fixtures initially; no change to CP1 replay schema. |
| Later worker composition: `Sedactive/Shared/BodyTracking/Processing/MotionEngine.swift` | Edo: raw tracking composition only; no jump/calibration/BodySnapshot production. |
| Later worker bridge: `Sedactive/Shared/BodyTracking/Capture/FrameStore.swift` | Edo: call that composition synchronously from existing sink, propagate lifecycle/reset/control tokens. No second frame consumer or source retention. |
| Later result projection: `Sedactive/Shared/BodyTracking/Capture/CameraPoseResults.swift` | Edo: minimal source-joined tracking projection/control revision/invalidations if approved; raw B1 output semantics preserved. No new CP1 API. |
| Later worker tests: `SedactiveTests/Shared/BodyTrackingTests/MotionEngineTests.swift` (new), existing `PoseEstimatorTests.swift` | Edo: deterministic integration, late-control-result rejection, failures/backpressure and cleanup regression where required. |
| Later numeric diagnostics: `Sedactive/Games/LaserHeist/Debug/LiveInputDiagnosticsView.swift` | Edo: reuse existing refresh/status owner for explicit arm/reset and slot state/reason/cost counters, never fake calibration or gameplay readiness. |
| Optional later synthetic files: `SedactiveTests/Shared/BodyTrackingTests/Fixtures/tracking-b2-v1.json` | Only if reviewed sequences need external fixtures; separate versioned tracking schema with injected times/truth labels. Do not modify CP1 replay fixtures. |
| Future overlay, separately scoped: `Sedactive/Games/LaserHeist/Debug/PoseDebugOverlay.swift` and relevant preview/diagnostic join seam | Kevin-owned overlay needs Kevin approval; any bounded source join/memory budget reviewed first. No overlay implementation in B2's first phase. |

No planned change to PlayerID, PoseFrame, BodySnapshot, BodyInputProviding, calibration contracts, CP2, GameWorldMapping, production cutouts, App signing, Jevon's session, GameClock or collision rules. CameraPipeline should not need ownership changes. If wiring requires another file or shared contract change, propose it explicitly before implementation.

## 11. Deterministic fixture and test matrix

Use existing Swift Testing, immutable synthetic PoseFrame sequences, fixed generation/epoch/control tokens and injected capturedAt/asOf clocks. Ground-truth participant labels belong only to the synthetic test oracle, never production matching input. Candidate IDs deliberately change each frame. Tests assert identities **when observable**, and uncertainty/refusal **when not**. Test-only numeric policy values exercise boundaries; they are not production tuning approval.

| Sequence / condition | Required assertions |
|---|---|
| Binding disarmed; zero/one/two people | Remain unbound regardless of count; arming is explicit. |
| Stable separated two people during acquisition | Dwell/coverage gates; atomic P1 canonical-right/P2 canonical-left binding, correct mirror interpretation and unequal body heights. |
| Duplicate/extra initial observations, center tie, incomplete core | No pair manufactured; waiting reason and dwell reset. |
| Stable two tracks with candidate order/IDs reversed every frame | Same person retains slot; candidateID points only into matching frame; permutation-invariant states/cost decisions. |
| Players exchange positions on distinguishable paths | Slots preserved where features/time continuity suffice; no X-based rename. |
| Symmetric crossing / merged body / overlap then ambiguous separation | Both or affected slot uncertain; no forced recovery by left/right. Irrecoverable ambiguity requires rebind. |
| Missing wrist/ankle; low-confidence core; no comparable torso anchor | Missing peripheral joints do not necessarily lose identity; inadequate core refuses; anchor-kind changes do not create false motion. |
| Valid `(0,0)` positive-confidence point versus absent joint | Preserve distinction; no synthesized zero or missing-joint residual. |
| One candidate disappears briefly while other stays distinct | Other may track; missing slot uncertain, unique supported recovery can pass dwell; no pose copied from prior frame. |
| Partial-body exit/reentry; unfamiliar entrant near last location | Sufficient continuing core may associate; unsupported return cannot inherit slot. |
| Lost slot, even a perfect geometric return | Remain lost until explicit new-generation full rebind. Test documents conservative limitation. |
| Third person far outside both gates | Established unique tracks may persist; extra-candidate counter; no new slot. |
| Third entrant challenges one track, duplicate torso detection | Affected association uncertain even if another cheaper match exists; uniquely supported other slot can remain tracking. |
| 3–8 retained candidates, both good and competing fixtures | Evaluate all competitors, not first/largest two; order invariance and deterministic ties. |
| Total observations exceed retained cap | No binding/confident output; explicit overflow; cannot treat omitted candidates as irrelevant. |
| Zero-result frames versus inference failure | Different reasons; both invalidate current matches appropriately, no mock fallback or forced count of two. |
| Duplicate/out-of-order frame or capture time | No state/dwell/source advancement; future accepted result retains its original metadata. |
| Dropped capture sequence IDs / irregular time intervals | Use elapsed capture time, not nominal 30 FPS; gap at/beyond configured horizon invalidates prediction/recovery correctly. |
| No new frames, injected expiry evaluation | Current reliability expires without invented source time/new frame; confirmed history cannot remain gameplay-ready. |
| Generation / epoch / geometry / dimensions / same-context token change | Clear authorized state/output; late old completions/control callbacks cannot revive tracks or arm new context. |
| Reset/recalibration request and cancellation | Explicit binding reset requires new generation; same-person baseline replacement does not rename identity; no accepted-calibration store in tracker. |
| Stop during delayed Vision / slow processing / preview on/off | One existing worker, bounded pending sources, no published stale tracking; eventual source/workspace cleanup, no preview dependency. |
| Long repeated synthetic sessions / worst-case eight candidates | Constant state counts and bounded statistics, no history/resource growth; deterministic replay produces identical outcome sequence. |

Test evidence logic includes changed weights/missing terms, competitor margin boundary, unmatched alternatives, ambiguous-dwell resets and nonfinite/invalid policy rejection. Do not write a test that succeeds merely because two dictionary keys exist. Pure core tests need no camera or real-time sleeps. Later integration races use controlled continuation gates; a synchronous inference gate is test-only, never a production wait added to an actor.

No tests are added or run by this proposal. Existing B1/camera/preview/CP1/CP2/gameplay suites remain regression requirements, not B2 success claims.

## 12. Physical iPad protocol and acceptance

Target the same iPad Pro 13-inch M4 / iPadOS 26.7.1, landscape front-camera configuration actually supported by capture. Record build/OS, source context, lighting/distance, duration, policy version and preview setting. Only aggregate numeric states/reasons/counts/timing are exported; no participant imagery or real pose-coordinate histories are committed. Obtain manual consent for any separately approved recording.

1. Empty-from-first-frame and one-person trials: arm acquisition and verify no fabricated two-player binding. Repeat the B1 contaminated negative trial cleanly as characterization, without inventing a false-positive acceptance rate.
2. Two side-by-side people, different heights where available: confirm initial mirrored-left P1/right P2 using controlled manual identification, then confirm stationary and ordinary arm/leg movement continuity. Capture raw-count fluctuations alongside tracker refusal reasons.
3. Deliberate position exchanges with separated and overlapping paths: require retained IDs only for observable cases; record uncertain/lost/rebind behavior when paths become ambiguous. Left/right sorting must not conceal a swap.
4. One person partly exits, fully exits, briefly reenters, then returns after the configured horizon. Add a third person near a missing slot and near an established player. No automatic replacement of lost identity.
5. Brief overlap then separation, close similar-height people, weak joints and intermittent extra detections: verify conservative refusals and recovery conditions, with per-scenario manual observations rather than aggregate counts presented as identity accuracy.
6. Stop/start, background/foreground, interruption where feasible, and 180° geometry invalidation: clear compatible tracking without a new frame, require explicit authorized binding/rebind, reject delayed old output.
7. Finite comparable preview-off/on windows and slow-worker synthetic stress: report camera FPS separately from pose/tracking cadence; association CPU duration and total result age p50/p95, AV/pending/stale/failure counts, state transitions, peak explicit pixel memory, process RSS and observed thermal state. Verify unchanged source bounds and cleanup. No requirement for 30 FPS Vision is implied.

Before accepting integrated B2, the reviewed deterministic matrix, strict checking, app/test/Release/device builds, regression and actual device scenarios must pass their scoped gates. Numerical confidence/distance/accuracy/performance acceptance thresholds must be agreed from controlled measurements, not silently derived from B1 throughput. Known unobservable exchanges are tested as refusal cases, not successful identification.

Numeric B2 diagnostics alone cannot visually prove exact joint-to-image alignment. If acceptance needs optical alignment evidence, authorize the same-source overlay phase separately; do not claim it was verified by a raw-count label or by MainActor update order.

## 13. Future same-source DEBUG skeleton overlay

Preserve Kevin's **approved DEBUG-only** mapping into the displayed aspect-fit rectangle `(ox, oy, w, h)`:

```text
screenX = ox + (1-x) * w
screenY = oy + (1-y) * h
```

Match the displayed preview packet and raw/tracked pose by exact generation, internal epoch/control compatibility, frameID and camera geometry revision, with original capture metadata/dimensions. Use its exact fitted rectangle and valid presentation context. Never combine independently polled latest values. If the displayed frame has no matching compatible pose, **hide the overlay**; if identity is uncertain, do not draw confident P1/P2 labels. Unassigned raw candidates may later use explicitly anonymous styling only after Kevin reviews it.

A later join must have an approved finite value-only cache/mailbox; do not retain raw images/history to force every preview frame to acquire an overlay. It may initially omit unmatched overlays. The final-screen formula already mirrors X and flips Y for top-left UI. A container that already mirrors imagery/overlays must not mirror its child coordinates again. Preserve anatomical labels.

Production CutoutPlacement/player-plane scaling, lane-local mirroring and GameWorldMapping are separate and unchanged. Kevin's A2 transform approval is not approval of a new overlay implementation or a change to production renderer behavior.

## 14. Decisions, review responsibilities and tuning

| Decision / parameter group | Status / required reviewer |
|---|---|
| Anonymous P1/P2, initial mirrored-left/right only; immutable raw values and source provenance; no silent swap; single worker | Existing accepted constraints. B2 must preserve them. |
| Gated two-slot assignment with unmatched alternatives and categorical reasons | **Proposed** algorithm; Edo approves design before implementation. |
| Full-torso pair acquisition; capture-time dwell; conservative lost latch/new-generation rebind | **Proposed** conservative policy. Edo reviews usability/safety; Jevon reviews eventual phase/recovery implications. |
| Joint confidence/coverage, duplicate separation, center guard, acquisition/recovery dwell | **Unselected tunables**, not the DEBUG 0.3 rule. Choose explicit experimental policy for deterministic core implementation; validate/tune on iPad before integration acceptance. |
| Motion gates, velocity cap/horizon, shape weights, residual normalization, unmatched cost, assignment margin | **Unselected tunables.** Record units and boundary behavior; no hidden numeric production defaults. |
| Gap/uncertain/lost/freshness horizons, competitor reachability and permanently ambiguous conditions | **Policy approval plus device tuning.** Use monotonic capture/host-clock semantics, not GameClock. |
| Eight retained candidates; two confirmed + one provisional descriptor/slot; ≤73 hypotheses | Existing B1 cap plus **proposed finite B2 state**. Overflow conservatively refuses; cap change needs separate review. |
| Binding arm/control token and reset/expiry projection seam | **Integration review prerequisite.** Edo owns authoritative tracker, Jevon owns later requests/session response. No new shared public contract approved here. |
| Exact-source fitted-rect overlay/mirror invariants | Kevin's A2 transform already approved. New join/styling/overlay implementation needs Kevin review and separate authorization. |
| Standing calibration and baseline acceptance | LH-22 produces valid results; LH-13C accepts full dictionaries/cutovers; Jevon orchestrates phases in D. B2 adds no calibration state. |

**Questions for Edo:** approve minimum torso coverage and conservative irreversible lost/rebind behavior; decide whether session experience permits refusals at indistinguishable crossings; choose a versioned experimental policy set and approved capture-time gap/dwell semantics before coding. If stronger continuity through complete occlusion is a product requirement, current pose-only scope is insufficient and needs explicit redesign approval.

**Questions for Jevon:** agree when binding is armed/revoked, how rebind-required is surfaced and how a new generation is requested; identify required tracking status/reason/freshness projection and no-frame status delivery for later session integration. He needs current per-slot readiness, uncertainty/loss/rebind-required and source interruption/context state, but retains countdown/pause/recovery decisions. No interface edits or automatic pause are authorized now.

**Questions for Kevin:** review eventual source-joined overlay diagnostics/styling, same-image fitting/transform usage and display behavior for uncertainty. No production renderer or GameWorldMapping work is required for the pure tracker. Coordinate any later overlay file edit through ownership review.

Residual documentation mismatch: older architecture/TEAM_ALIGNMENT summaries retain persistent-profile and narrower mirroring descriptions; current PlayerID, CP1, A2 approval and B1 acceptance supersede them for this proposal. They are not edited here. Older LH-13 tables describing A/B as future remain historical where accepted A/B1 reports now supply implementation evidence. Do not infer B2/LH-22/C/D are complete.

## 15. Recommended next authorization and readiness

**Ready for design review, not implementation.** No fundamental concurrency blocker is identified for a bounded pure numeric tracker; the actual new signatures, state bounds and race handling still require compiler/tests during implementation. Policy and integration choices above remain explicit approvals, not an invitation to implement everything.

Smallest next phase: **B2a — deterministic tracking core only** in PlayerTracker.swift and PlayerTrackerTests.swift. First approve the proposed identity/refusal/recovery policy, internal value seam, finite state and an explicit experimental parameter set. Implement acquisition, gated global association, uncertain/lost and context resets using synthetic sequences; no live worker/UI/overlay/calibration wiring. Pure fixtures can establish behavior without claiming real tracking accuracy.

Then authorize separately: **B2b — existing-worker numeric integration and physical tracking characterization**, after token/invalidation and diagnostics ownership review; **future same-source overlay phase**, only after Kevin reviews the bounded join and file changes. LH-22, live BodySnapshot publication (C), gameplay/session integration (D) and live CP2 segmentation remain separate milestones. These are local phase labels, not new backlog completion claims.

Design review checklist: one owner of tracking state; no candidate-index identity; compare all feasible competitors/unmatched outcomes; no confirmed update from tentative evidence; no lost-slot replacement; exact source/control validation including no-frame invalidation; constant state/memory; explicit tunable policy; conservative tests plus real-device evidence; no CP1/CP2 or other-owner change hidden in integration.

### Documentation-task verification

Created only this proposal. Existing code/tests/project/signing/Scripts remain unchanged by this task. No build, test or physical experiment was run; all B1/A2 results above are attributed historical evidence. Performed source/document consistency, local ancestry/settings, path and Git checks, plus existing-file hash preservation and Markdown whitespace checks. Skills applied: swift-architecture-skill (existing logical-module fit, pure state transitions), swift-concurrency (worker confinement, token/cancellation ownership), swift-testing-expert (deterministic fixtures and controlled race gates). No branch/worktree creation/switch, staging, commit, push, merge, rebase or reset.
