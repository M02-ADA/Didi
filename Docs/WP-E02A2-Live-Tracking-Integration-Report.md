# WP-E02A2 — Live PlayerTracker Integration Report

7 November 2026 · Edo · **READY FOR INDEPENDENT INTEGRATION REVIEW**

This checkpoint implements controlled **numeric B2b diagnostics**, not live CP1, calibration, avatar presentation, gameplay integration, physical identity acceptance, or production tracking thresholds. The Tech Lead explicitly approved D02/D03 v1, all 20 B2bExperimentalPolicyV1 values, and rejection at capture-to-final-commit age **>= 0.5 seconds** in the WP-E02A2 request.

## 1. Verified baseline and exact task changes

Checkout: `/Users/edwardgk/Desktop/APPLE/Sedactive-B2b`; branch `feat/live-player-tracking`; HEAD and available `origin/staging` remain `93254b097b1f44aac95c181077f38a59534632c6`. No fetch, branch switch, merge, staging, commit, push, reset or PR operation occurred. This is verification of locally available refs, not a remote-server freshness claim.

The two pre-existing untracked D02/D03 and A1 proposal documents were preserved byte-for-byte. Their historical pending-approval wording is not rewritten; the current request supplies the later approval.

| Task file | Actual change |
|---|---|
| [MotionEngine.swift](../Sedactive/Shared/BodyTracking/Processing/MotionEngine.swift) | Implement the worker-local value adapter, explicitly selected policy, staged inference/failure transitions, and serialized control/expiry application. |
| [CameraPoseResults.swift](../Sedactive/Shared/BodyTracking/Capture/CameraPoseResults.swift) | Preserve B1 mailbox implementation; add internal admission/control/ack/diagnostic values and the single tracking linearization gate. |
| [FrameStore.swift](../Sedactive/Shared/BodyTracking/Capture/FrameStore.swift) | Stamp independent source frames before copy; connect begin/suspend/resume/end; compose MotionEngine on CameraCopySink; reuse existing worker wake and pixel ownership. |
| [CameraPipeline.swift](../Sedactive/Shared/BodyTracking/Capture/CameraPipeline.swift) | Add arm/cancel/full-rebind facade, one pending rebind operation, synchronous background source invalidation and worker control draining. |
| [LiveInputDiagnosticsView.swift](../Sedactive/Games/LaserHeist/Debug/LiveInputDiagnosticsView.swift) | Add explicit DEBUG controls and bounded numeric tracking diagnostics through the existing retained model/observer. |
| [LivePlayerTrackingTests.swift](../SedactiveTests/Shared/BodyTrackingTests/LivePlayerTrackingTests.swift) | New control, source, worker, timer and camera-lifecycle integration suites: 29 definitions / 42 executions. |
| This report | Implementation, proof, verification, limitations and preservation record. |

Accepted B2a production SHA-256 remains `4cc0a4a648e7250910303826bd5a3a14d27efea023d4f9ff861f094eff01fd34`; its test SHA-256 remains `906defbadd128ff938700367c6f829a06958bd52e5c28df761a3a007a13e8a75`.

No changes to PoseEstimator/B1 inference, CP1/CP2, BodyInputService, calibration, GameSessionCoordinator, avatar/production renderer, AppDependencies, project/signing settings or generated resources. The test file is included by the existing filesystem-synchronized test group; no target/project modification was necessary.

## 2. Runtime composition and D02/D03 compatibility

```text
App-retained CameraPipeline
  FrameStore -- pre-copy CameraTrackingAdmission on each owned source
    existing single CameraCopySink actor
      existing reconstruction -> existing synchronous B1 Vision -> immutable CameraPoseResult
      MotionEngine -> staged accepted B2a PlayerTracker transition
        CameraTrackingGate final validation
          worker-owned state assignment + numeric result + current-request acknowledgment
```

One retained native capture session, one FrameStore consumer, one Vision worker and one authoritative mutable PlayerTracker remain. Gate state stores authorization, publication and a bounded binding receipt; it stores no tracker, raw pixels, Vision objects, pose-joint history or calibration. A staged value copy is an uncommitted transaction, not another live tracking authority.

Camera start is disarmed. The existing DEBUG model explicitly calls the same Edo-owned CameraPipeline facade used for future composition; no setup/calibration flow is implemented. Canonical image-right binds P1 and image-left P2 under accepted B2a semantics. Source coordinates and anatomical labels are neither mirrored nor rotated again.

## 3. First gate: atomic commit feasibility and linearization argument

Before production edits, `AtomicGateProbe.swift` compiled with complete strict concurrency, default MainActor isolation, Swift 5 mode and warnings-as-errors for both supported SDKs. It verifies the exact ownership technique: an actor can synchronously assign its private value inside a nonescaping closure invoked under a Sendable gate's mutex. This compiler result alone is not a correctness proof; final production SIL/object checks and race/refusal tests supplement the following argument.

### Critical section

`CameraTrackingGate.finish` locks its state, reads the current host time, applies any due expiry, and checks:

- Active source context and exact admitted context/request/revision.
- Cancellation, finite time, no future capture, and capture-to-commit age strictly below freshness.
- Increasing committed frame ID and capture timestamp.
- Original capture at or after the expiry watermark, and staged state incorporating that watermark.
- Exact original generation, epoch, geometry revision, dimensions, applied orientation, mirror state, frame ID, capturedAt and control revision.

Only then does the nonescaping `commit` closure assign `motion = staged` on the calling CameraCopySink actor. The same critical section installs the matching immutable snapshot, advances accepted ordering, and makes a current-request acknowledgment eligible.

**Linearization point:** the authoritative worker assignment inside `finish`, before the mutex is released. All associated publication/ack changes are in that same critical section. Neither inference nor association evaluation is performed there. The separate B1 `CameraPoseResults.finish` Bool is checked, but is not used as a substitute for this protected assignment.

### Revocation cases

1. Revoke acquires the gate first: request/revision/source validity changes; old final validation fails; the commit closure is not called.
2. Commit acquires the gate first: assignment, result and acknowledgment become one accepted operation; subsequent revocation acquires the lock and clears current publication/ack synchronously.
3. Expiry arrives after staging: its watermark invalidates the old proposal; final validation refuses both history commitment and publication. A delayed timer callback is covered by checking the deadline again inside final validation.

There is no suspension between validation and assignment. The private worker state cannot be observed/mutated concurrently from another actor; published values require this same lock. Rejected stages are discarded, not committed and later hidden. Authorized invalidation may clear worker state on the next serialized control drain; this is a control transition, not rejected-frame history advancement.

The closure contract forbids suspension, inference, reentrancy into the gate, or lifecycle calls. Actual call sites only assign the staged value; expiry/control closure runs bounded pure-core operations. FrameStore/control lock order never calls back from the gate into FrameStore. The proof assumes the SDK mutex's mutual exclusion and these reviewed call-site restrictions; tests do not claim exhaustive scheduler model checking.

## 4. Admission, requests and atomic acknowledgment

- FrameStore obtains the original request/revision under the gate while validating/reserving construction, before allocating/copying Data.
- The immutable CameraSourceFrame retains that stamp through pending replacement and processing. A later arm cannot relabel a disarmed frame; old admitted work cannot borrow a new revision after Vision.
- Same-active-request arm is idempotent and preserves acquisition dwell. New authorization/supersession and actual revocation advance control revision; revision exhaustion fails closed instead of wrapping.
- Gate publication retains only the active request and at most one acknowledgment. The cumulative acknowledgment counter saturates; it is not an event queue.
- Acknowledgment contains requestID, original source/control identity and both slot results. It is produced once when both slots atomically reach tracking, never merely on arming. Recovery does not create a second acknowledgment for that request.
- Current acknowledgment clears on revocation. A bounded last-bound-generation receipt guards authorization; the actual core's lastBoundGeneration also survives invalidate/reset/worker cleanup. Neither creates camera generations.

## 5. Lifecycle, no-frame expiry and full rebind

FrameStore begin/end/suspend/resume update the same source/control gate. Native interruption, stopped/error events and a source-owned background notification synchronously suspend/invalidate publication without awaiting the actor or another frame. The background observer belongs to the source event channel and is removed on finish/deinit; no additional CameraPipeline status observer is installed.

Ordinary uncertainty stays in accepted B2a logic. Native resume restores raw admission only; it neither arms tracking nor unconditionally increments the binding revision. Stop/interruption revocation and a later new authorization advance revision.

Explicit full-pair rebind revokes, stops the actual capture run, awaits native/worker cleanup, starts through CameraPipeline with a genuinely new generation/epoch, then arms the new request. The retained AVCaptureSession owner remains unchanged. A canceled rebind keeps its single operation slot until cleanup actually exits, preventing repeated commands from accumulating replacement tasks behind stuck inference. Operation identity also prevents an old completion from clearing a newer operation.

One DispatchSourceTimer per retained FrameStore/gate schedules the next core freshness/recovery/acquisition deadline. It does not infer, mutate PlayerTracker, or create a per-frame Task. It clears published tracking, advances the evaluation watermark and yields the existing coalesced worker wake. The existing actor then applies `expire(at:controlRevision:)` under the same gate. A pending inference can remain resource-owned while publication is already invalid. The timer is independent of UI polling; a direct deadline/wakeup test verifies that wiring.

Expiry keeps the original source identity; no synthetic frame is created. Applied evaluation time is a watermark, not a new capturedAt. Captures older than it cannot restore freshness. A future result needs both original capture-time eligibility and the approved final host-age gate. An indefinitely stalled SDK call is not forcibly killed and does not free its buffers early; capture/processing cleanup waits for actual exit.

## 6. Approved experimental policy

Version: **B2bExperimentalPolicyV1**. Approval provenance: Tech Lead WP-E02A2 authorization, 7 November 2026; source baseline above. All values are literal production-target construction values, with no test-fixture import or fallback. The gate validates startup configuration; invalid configuration refuses authorization/admission. MotionEngine construction also validates the policy.

| Field | Approved value / unit |
|---|---|
| minimumJointConfidence | 0.5 |
| minimumTorsoExtent | 0.02 image heights |
| minimumPairSeparation | 0.12 image heights |
| centerGuardFraction | 0.04 canonical normalized X |
| acquisitionDwell | 0.125 host seconds |
| recoveryDwell | 0.125 host seconds |
| maximumObservationGap | 1.0 host seconds |
| recoveryWindow | 2.0 host seconds |
| freshness | 0.5 host seconds |
| maximumSpeed | 0.5 image heights/second |
| positionGate | 0.15 image heights |
| jointResidualGate | 0.22 image heights |
| maximumLogScaleChange | 0.35 absolute log ratio |
| positionWeight | 0.4 cost weight |
| jointWeight | 0.4 cost weight |
| shapeWeight | 0.2 cost weight |
| missingEvidencePenalty | 0.3 per missing term |
| unmatchedCost | 2.0 per unmatched slot |
| assignmentMargin | 0.15 absolute cost band |
| minimumSharedCoreJoints | 3, plus corresponding anatomical pair |

Final capture-to-commit age **>= freshness is rejected**, including exactly 0.5 s. No value was tuned. These remain controlled diagnostic parameters, not production or gameplay tolerances. The 1 s anchor support limit can prevent recovery before the nominal 2 s loss window; strict coverage/duplicates can force refusal/rebind. The 0.3 raw confidence diagnostic label remains separate from the selected 0.5 tracker cutoff.

## 7. Numeric diagnostics and bounds

The retained DEBUG diagnostics model uses its existing observer and refresh path. Added values show policy version, request/revision, acknowledgment source, P1/P2 state/reason/candidate/rebind/last-confirmed values, original source/time/context, current result age, recorded capture-to-final-commit age, pair mutual-core coverage, accepted/refused/rejected/stale counts, expiry/invalidation counts and evaluation watermark.

Mutual coverage is available for exactly two retained candidates and is not association confidence. Last accepted coverage/commit-age scalars are diagnostic history, not a readiness certificate after invalidation. No new pose coordinates or imagery are exported.

Tracking storage is independent of stream length: two core slots, accepted core descriptor limits, one staged value, at most eight current candidates, one latest numeric result, one request/ack/receipt, scalar saturated counters and one timer/deadline/wake. Core assignment enumeration stays at its existing bounded maximum. Control and expiry reuse the FrameStore wake buffered newest-one; no second processing consumer or status backlog exists.

Existing raw 4 MiB/frame, 12 MiB retained-source ownership, one reconstruction workspace and independently bounded DEBUG preview are unchanged. Admission stamps add small numeric metadata, not pixel copies. These application-accounted pixel caps are not a process RSS cap. There is no new historical image retention.

## 8. Deterministic verification and race coverage

New tests use exact source/time fixtures and controlled adapters. The actual CameraCopySink reconstruction path is exercised with an explicitly injected test detector, including synchronous blocked calls; those are not physical Vision accuracy trials. Test-only rendezvous blocks the synchronous detector seam and releases deterministically; production has no such wait or fallback.

| Coverage | Evidence |
|---|---|
| Explicit binding, unarmed camera, atomic P1/P2, exactly-once ack, complete source identity | `cameraActivationDoesNotArm`, `explicitPairBindingPreservesSourceAndAcknowledgesOnce`, actual sink source test |
| Duplicate/cancel/supersede; original stamps before/after control cutover | `duplicateActiveRequestDoesNotRestartDwell`, `cancelOrSupersedeRejectsAlreadyStagedFrame`, admission tests |
| Immediate before/after commit revocation; no confirmed history advancement | Staged rejection closure is not called; engine snapshot equality; after-commit clearing/guard test |
| Blocked inference and no next frame | Actual sink tests for cancel/stop/interruption/expiry; ownership retained until detector exits |
| Background without diagnostics observer | Isolated notification center through the real source event channel |
| Native same-context resume / real source restart | Disarmed revision tests and facade test asserting native driver stop/start counts and changed generation/epoch |
| Canceled full-rebind boundedness | Reject replacement request while prior worker cleanup is held; cleanup and bytes released after gate |
| Expiry/watermark, recovery dwell, eventual lost | Captures older than applied watermark refused; lastConfirmedAt frozen; ordinary recovery and loss fixtures |
| Delayed timer and actual timer wiring | Final-commit deadline test plus lifecycle timer test awaiting its wake without polling/manual expiry/new frame |
| Exact 0.5 s age boundary | 0.499 accepted; 0.5 and 0.75 rejected; commit-age and stale counters asserted |
| Context/order safety | Generation/epoch/geometry mismatch and duplicate/older frame/time refusal |
| Option A and useful continuation | Comparable partial positive, complementary missing-core refusal/history freeze, ambiguous crossing and independent healthy peer |
| Preview and resources | Preview off/on through same sink/consumer; processing capacity, retained ownership, workspace and final cleanup assertions |

Final results reopened directly with xcresulttool:

| Suite / gate | Definitions | Executions | Result |
|---|---:|---:|---|
| Accepted PlayerTrackerTests, unchanged | 95 | 187 | Passed, zero failures/skips |
| New B2b integration suites | 29 | 42 | Passed, zero failures/skips |
| Focused combined | 124 | 229 | Passed, zero failures/skips |
| Full current application regression | 355 | 567 | Passed, zero failures/skips |
| Debug app + test-target build | — | — | Passed |
| Release Simulator build | — | — | Passed |
| Unsigned generic iOS SDK build | — | — | Passed; no install/device run |

Counts distinguish parameterized executions from definitions and come from saved summaries/test trees. Full counts reflect the actual current staging-based suite, not earlier historical report totals. Development compile diagnostics were corrected and intermediate evidence retained; only final bundles above establish current verification.

Toolchain: Xcode 26.6 (17F113), Swift 6.3.3, iOS/iOS Simulator SDK 26.5. Simulator: iPad mini (A17 Pro), iOS 26.5 build 23F77, verified destination `1E1C6B07-B356-4303-8756-4C0D2A4CDF05`. An explicit DEVELOPER_DIR selects installed Xcode because the shell default is Command Line Tools; no system/project setting was changed. Simulator host logs contain RealityKit shader warnings; no visual-renderer acceptance is claimed from these tests.

## 9. Strict concurrency and ownership

The established verification script records exact commands and exit codes for both SDKs, preserving Swift 5, default MainActor, existing upcoming features, complete strict checking and warnings-as-errors.

Per SDK: production WMO SIL, production WMO object, testable module, and Shared test WMO SIL passed. Scope includes all Shared Swift, AppDependencies, existing DEBUG diagnostics and native callback probe; standard app builds cover the complete target. This is not a claim that unrelated renderer files received a new standalone strict-WAE audit.

All six expected negative controls failed compilation as intended: raw CV transfer, worker-local Vision transfer and actor-isolated native-delegate boundary on each SDK. No unchecked Sendable, unsafe nonisolated, preconcurrency suppression or compiler-setting weakening was introduced.

## 10. Persistent evidence and source correspondence

Evidence root:

`/Users/edwardgk/LaserHeistReviewArtifacts/WP-E02A2/run-2026-11-07-fdfb4484/`

- `Focused.xcresult`, `Regression.xcresult`; summary/test-tree exports and reopened summaries.
- `debug-test-build.log`, `release-build.log`, `ios-sdk-build.log`, focused/full logs and exact command JSON.
- `verify-builds.py`, `verify-strict.py`, `strict-results.json`, both-SDK compiler command/log/SIL/object outputs and negative-control sources.
- Atomic-gate probe source, commands, logs and both-SDK SIL.
- `final/` source/config snapshots, `final-source-hashes.json`, `final-head.diff`, `preservation.json`, `final-git-status.txt`.
- `artifact-reopen.json` and `artifact-manifest.json` with readable retained-file hashes; intermediate runs are clearly named separately from final evidence.

Source snapshots/hashes match the final built and tested source. Final bundles were reopened after execution. No build artifacts are added to Git. Build caches remain under the evidence directory; the manifest excludes bulky derived/cache directories and itself.

## 11. Remaining limitations and approval gates

1. Independent integration review is required, especially the nonescaping commit restrictions, source/control linearization, timer watermark behavior and canceled-operation bound. B2b is not marked accepted.
2. No physical device was installed, launched or tested in this task. Physical two-person identity continuity, parent/child coverage, crossings/occlusion/third entrants, actual lifecycle responsiveness, confidence distribution, process memory/thermal behavior and throughput remain unverified.
3. Synthetic assertions establish the selected observational policy, not real identity certainty. Option A refusal/rebind usability and experimental values still require controlled device characterization. No 30 FPS tracking requirement or gameplay latency approval is inferred.
4. Stalled synchronous Vision cannot be forcibly canceled; publication revokes immediately, but resources and restart cleanup wait for actual return. The system does not spawn replacement inference workers.
5. Following review and separate physical-testing authorization, use the M4 protocol in A1: explicitly arm, confirm atomic association, exercise different heights/partial views/crossings/extra people and all lifecycle transitions, compare preview off/on, and collect finite numeric-only source/control/status/latency/memory observations with manual versus automated provenance.
6. Jevon's D03 session pause/restart/readiness integration remains a separate handoff; no GameClock, scoring or round state changes occurred. D04 calibration, D05 provider injection, live CP1, D06 avatar fields/packet alignment and rendering remain separately scoped. Resume itself does not advance binding revision.

## 12. Final Git and preservation

Five tracked Swift files modified, one new test file and this report created. The two pre-existing untracked decision documents remain unchanged. Final status:

```text
 M Sedactive/Games/LaserHeist/Debug/LiveInputDiagnosticsView.swift
 M Sedactive/Shared/BodyTracking/Capture/CameraPipeline.swift
 M Sedactive/Shared/BodyTracking/Capture/CameraPoseResults.swift
 M Sedactive/Shared/BodyTracking/Capture/FrameStore.swift
 M Sedactive/Shared/BodyTracking/Processing/MotionEngine.swift
?? Docs/LaserHeist-D02-D03-Tech-Lead-Decision-V1.md
?? Docs/WP-E02A1-Experimental-Tracking-Policy-Proposal.md
?? Docs/WP-E02A2-Live-Tracking-Integration-Report.md
?? SedactiveTests/Shared/BodyTrackingTests/LivePlayerTrackingTests.swift
```

Baseline file-hash comparison found only the five scoped tracked changes. The primary `feat/architecture` checkout remains at `7cab6121eea5351b3b2a51256c9d433cb2d497dd`, with no file changes and its existing untracked `Scripts/CP2Spike/` preserved. HEAD/staging reference, source contracts, accepted B2a/B1, project/signing and generated files are unchanged. Git diff whitespace checks pass.

Skills used: swift-architecture-skill, swift-concurrency and swift-testing-expert. Stop here: independent integration review is next; no commit/PR, physical testing, B2b acceptance, calibration, gameplay or avatar work is authorized by this report.
