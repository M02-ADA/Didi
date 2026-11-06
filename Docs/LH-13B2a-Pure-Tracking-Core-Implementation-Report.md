# LH-13B2a — Pure Tracking Core Implementation Report

5 November 2026 · Owner: Edo · Branch: `feat/player-tracking`

**Current disposition: LH-13B2a — READY FOR RE-REVIEW.** Section 15 records the authorized frame-consistent evaluate–resolve–commit correction and newly executed verification on 6 November 2026. The original REVIEW, both REVISE findings/failing reproductions, and §13 correction history are preserved below. B2a is not automatically ACCEPTED; B2b/live tracking, production thresholds, calibration, gameplay and overlays remain outside this scope and require separate authorization.

## 1. Actual baseline and exact scope

Starting/current HEAD: `1a48e19971c8440a40d014ce29a091f00418e0f8`, merged staging Camera Foundation/B1 (PR #19). The existing branch was `feat/player-tracking` throughout this implementation. No branch, worktree, fetch, merge or history change was performed.

Read AGENTS/TEAM_ALIGNMENT, lean architecture and applicable reference, the B2 proposal, B1 final accepted report, actual PlayerID/PoseFrame/CP1 tracking values, capture source/result metadata, and Swift Testing/concurrency conventions. Actual PlayerTracker and PlayerTrackerTests were skeletons; MotionEngine is still a skeleton. Current CP1/CP2 code is preserved.

Entry work preserved byte-for-byte:

- External two-line app signing-team modification in `Sedactive.xcodeproj/project.pbxproj`.
- Untracked `Docs/LH-13B2-Stable-Player-Tracking-Architecture-Proposal.md`.
- Untracked `Scripts/`, including the prior experiments.

Only these authorized files were created/modified:

| File | Change |
|---|---|
| `Sedactive/Shared/BodyTracking/Processing/PlayerTracker.swift` | Replace skeleton with pure tracking policy, numeric input/output/provenance, bounded assignment and lifecycle core. |
| `SedactiveTests/Shared/BodyTrackingTests/PlayerTrackerTests.swift` | Replace skeleton with synthetic fixture helpers and 47 Swift Testing definitions. No camera/framework mock was added to production. |
| `Docs/LH-13B2a-Pure-Tracking-Core-Implementation-Report.md` | New report. |

Production core imports **Foundation only**. Tests import Foundation, Testing and the app with `@testable`. No CameraPipeline, FrameStore, PoseEstimator, CameraPoseResults, MotionEngine, diagnostics, CP1/CP2 contract, calibration, gameplay, renderer, generated package, signing or project-setting change was made. The tracker has no live caller.

## 2. Actual internal API and ownership

All types below are app-internal, explicitly nonisolated and checked Sendable value types. This does not extend the public CP1 contract. `PlayerTrackingState` is separate from the unchanged CP1 TrackingStatus.

```swift
struct PlayerTracker: Sendable {
  static let maximumCandidates: Int // 8, matching B1's retained-value cap
  let policy: PlayerTrackingPolicy
  init(policy: PlayerTrackingPolicy) throws
  mutating func reset(context: PlayerTrackingContext, controlRevision: UInt64) throws
  mutating func invalidate(controlRevision: UInt64) throws
  mutating func armBinding(controlRevision: UInt64) throws
  mutating func process(_ input: PlayerTrackingInput) throws -> PlayerTrackingSnapshot
  mutating func inferenceFailed(source: PlayerTrackingSource) throws -> PlayerTrackingSnapshot
  mutating func expire(at time: Double, controlRevision: UInt64) throws -> PlayerTrackingSnapshot
  var snapshot: PlayerTrackingSnapshot { get }
}
```

The source declarations include `nonisolated`; the sketch omits bodies and declaration repetition for brevity. No default init or default live policy exists.

- `PlayerTrackingContext`: generation, internal epoch, geometry revision, image width/height, already-applied capture rotation and mirror flag. Only upright canonical/unmirrored provenance (current supported applied angles 0/180) is accepted; the tracker applies no rotation.
- `PlayerTrackingSource`: exact context, frameID, host-clock capturedAt and original controlRevision.
- `PlayerTrackingInput`: source, original immutable PoseFrame, total SDK observationCount. Total count must agree with B1's retained prefix up to eight; overflow remains explicit.
- `PlayerTrackingSlotResult`: state, reason, optional source-local candidateID, optional matching cost and `requiresRebind`. Costs are diagnostics, not probabilities or calibrated measurement validity.
- `PlayerTrackingSnapshot`: original source or nil after reset/invalidation, injected evaluation time, control revision, exactly P1/P2 outcomes, last assignment count and retained descriptor counts. Subscript accepts PlayerID. No pose or image history is returned.

State is owned by the caller's single mutable value. Sendable permits value transfer; it does not permit concurrent mutation or authorize multiple independent production trackers. Future B2b must retain one instance on the existing processing worker and perform source/control-gated publication. No actor, lock, Task, queue, timer, stream, CV/VN reference or image storage was introduced into the core.

## 3. Implemented algorithm

### Explicit acquisition

`reset` supplies context and a strictly newer external control revision, clears history/output and disarms. `armBinding` explicitly authorizes acquisition for that revision. Merely processing two people while disarmed cannot bind.

Acquisition requires exactly two eligible, distinct full shoulder/hip candidates, no eligible extra/duplicate hypothesis, no retained-cap overflow, intended display halves and capture-time dwell. At least two observations are required even when a test policy uses zero dwell. Both slots bind atomically.

With the accepted single display mirror, larger canonical X is displayed-left **P1**, smaller canonical X is displayed-right **P2**. Sorting is acquisition-only. Frame-local IDs and subsequent X position never determine established identity. Incomplete acquisition, missing input, ambiguity or excessive acquisition gap resets provisional dwell rather than accumulating intermittent evidence.

### Descriptors, motion and matching

Descriptors retain only the four torso joint types, filtered by explicit policy confidence. Full acquisition requires all four; continued association permits three or four common core joints with a corresponding shoulder/hip pair. Every available pair must be geometrically nondegenerate. No wrist/ankle/head fallback manufactures a body center.

Matching distances use `(x * width/height, y)` in image-height units; original PoseFrame coordinates remain untouched. Center/residual calculations compare the same anatomical joint subset, so changing from a shoulder-heavy partial pose to a hip-heavy one cannot appear as a cheap center match. Torso length is available only with full core coverage. Missing core and missing scale terms incur explicit penalties; absent terms never become zero residuals.

At most two confirmed descriptors per slot support capture-time velocity prediction. Velocity is clamped by policy. An edge must pass coverage, elapsed-time, position, mean joint residual and available log-scale gates. Its cost combines normalized position/joint errors, weak scale consistency and missing-evidence penalties. The position gate expands only within the finite prediction horizon; it does not expand forever during loss.

The matcher evaluates injective P1/P2 assignments, including either/both unmatched. Eight candidates permit at most `8*7 + 2*8 + 1 = 73` hypotheses. A candidate cannot be assigned to both slots. All admissible retained competitors are considered, with explicit unmatched cost and a best-versus-alternative cost band. Array order never breaks ties.

Only competitive **global** alternatives imply identity conflict; a much weaker gated edge alone does not override a unique result. An independently attributable player may continue while the other refuses association.

### Conservative state/recovery choices

| Event | Behavior |
|---|---|
| Unique supported current match | Tracking; update the two confirmed descriptors; return that frame's candidateID. |
| Missing/weak match or match-versus-unmatched ambiguity | Uncertain; no current candidate; confirmed history frozen. |
| Brief loss without identity competition | Recovery requires unique support and a finite multi-observation dwell. Tentative descriptors do not update confirmed history. |
| Two candidate identities remain competitive for one slot, or a near-coincident duplicate challenges it | Uncertain with a monotonic ambiguity latch and `requiresRebind = true`; later disappearance of an alternative does not prove who remained. Unaffected slot can continue. |
| Competitive global hypotheses could assign the same candidate to either slot | Irrecoverable exchange ambiguity: both lost and require rebind. This intentionally refuses indistinguishable overlaps/crossings. |
| Raw source gap exceeds configured horizon | Lost; do not infer identity from endpoint left/right order. |
| Confirmed anchor is too old to predict, but raw frames keep arriving | No matching edge; uncertain until recoveryWindow expiry, then lost. Continuing raw frames do not extend the confirmed anchor's horizon. |
| Lost | Never automatically tracking; no automatic replacement by a third entrant or even a geometrically perfect return. |
| More SDK observations than retained candidates | No confident association; established slots uncertain, acquisition refused. Omitted candidates cannot be declared harmless. |

The ambiguity latch is a deliberate conservative realization of the proposal's bounded uncertainty summary. It can over-refuse duplicate/spurious observations, including duplicates that actually describe one person. This usability tradeoff requires review and later physical characterization; it is not hidden behind a tracking-confidence number. A fresh generation/full pair rebind is the only release for lost/identity-indeterminate slots. Ordinary missing-only uncertainty remains recoverable.

No universal person-identity guarantee is claimed after complete occlusion or an unobserved geometrically indistinguishable substitution. No face/appearance recognition, segmentation, standing calibration, crown/sole estimation, jump detection or gameplay interpretation occurs.

## 4. Explicit synthetic policy and units

**No production policy values were selected.** The following defaults exist only in the test-target `TrackingFixtures.policy` helper. Tests override them for deliberate boundary/failure cases. Production must explicitly construct a policy; nothing automatically activates it.

| Parameter | Synthetic value | Unit / purpose |
|---|---:|---|
| minimumJointConfidence | 0.5 | SDK confidence cutoff for matching support; not the DEBUG 0.3 label or an identity probability. |
| minimumTorsoExtent | 0.02 | Image heights; minimum available paired width/full torso length. |
| minimumPairSeparation | 0.12 | Image heights; acquisition separation / nearby duplicate ambiguity. |
| centerGuardFraction | 0.04 | Normalized canonical X fraction about 0.5. |
| acquisitionDwell | 0.125 | Capture seconds, plus at least two observations. |
| recoveryDwell | 0.125 | Capture seconds, plus at least two recovery observations. |
| maximumObservationGap | 1 | Seconds; raw source-gap limit and maximum confirmed-anchor prediction age. |
| recoveryWindow | 2 | Seconds since last confirmed association; does not reset on tentative evidence. |
| freshness | 0.5 | Injected host seconds since last confirmed association for no-frame expiry. |
| maximumSpeed | 0.5 | Image heights/second; predicted velocity clamp and bounded position-gate growth. |
| positionGate | 0.15 | Image heights; base position gate. |
| jointResidualGate | 0.22 | Image heights; mean corresponding-joint residual gate. |
| maximumLogScaleChange | 0.35 | Dimensionless absolute natural-log torso-length ratio. |
| positionWeight | 0.4 | Dimensionless normalized-cost weight. |
| jointWeight | 0.4 | Dimensionless normalized-cost weight. |
| shapeWeight | 0.2 | Dimensionless weak normalized log-scale weight. |
| missingEvidencePenalty | 0.3 | Cost per missing common core joint and missing scale term. |
| unmatchedCost | 2 | Cost of declining one slot. |
| assignmentMargin | 0.15 | Cost band for plausible global alternatives. |
| minimumSharedCoreJoints | 3 | Common core count; allowed 3...4 plus paired anatomical support. Acquisition still requires 4. |

Why these values: binary-exact 0.125-second steps make dwell boundaries deterministic; bodies centered at canonical 0.75/0.25 are well separated at 16:9; synthetic confidence 0.9 passes while 0.49 refuses; explicit missing penalties expose favorable-missing-term mistakes. Distances/weights were chosen to exercise supported matches, unmatched alternatives, ties and conservative refusal in controlled geometry. They were **not** fitted to M4 observations or selected as final operational limits.

Validation rejects nonfinite values, invalid signs/ranges, confidence outside (0,1], guard >= 0.5, unsupported core counts, freshness greater than gap, gap greater than recoveryWindow, recovery dwell >= window, assignment margin >= unmatched cost and arithmetic-overflowing cost/gate configurations. Zero acquisition/recovery dwell and zero shape weight are allowed explicitly, with multi-observation acquisition/recovery still enforced. Numerical policy validation does not certify practical camera performance.

## 5. Provenance, reset, no-frame expiry and future lifecycle obligations

Input must match the authorized generation/epoch/geometry/dimensions/presentation/control revision and its PoseFrame fields exactly. frameID and capture time increase; skipped IDs/irregular intervals are allowed. Nonfinite/negative time, duplicate/older IDs/times, stale control, incompatible context, malformed joints and inconsistent retained/total counts are rejected before state mutation. Rejected input cannot advance acquisition/recovery dwell.

- `reset` / `invalidate` require strictly increasing caller-supplied controlRevision and immediately clear both states, confirmed/provisional histories, source and evaluation time. `invalidate` also removes active context. Invalid reset requests leave existing state unchanged.
- Internal control revision is distinct from session generation. The tracker never manufactures a CameraPipeline generation or host timestamp.
- The last bound generation is remembered across resets. Arming within that bound generation is rejected; a full rebind requires a new externally authorized generation. The future lifecycle owner must **never reuse older generation UUIDs**, consistent with CP1; the core deliberately does not keep an unbounded historical UUID set.
- A context/control change is an explicit owner operation. A delayed input with the wrong context is rejected; it cannot reset newer state or opportunistically arm itself. Future B2b must call invalidation/reset on lifecycle events even without frames and gate public visibility immediately while a worker is busy.
- Original source/control tokens must be stamped before asynchronous processing. A future adapter must not relabel an old result with the current revision on completion.
- `expire(at:controlRevision:)` accepts a deterministic monotonic host-clock evaluation value, clears current associations after freshness expiry and advances to lost when the recovery window expires. It preserves the original source key/capture time and creates no synthetic PoseFrame. Regressing/nonfinite evaluation times are rejected. Frames older than the evaluation watermark are conservatively rejected.
- `inferenceFailed(source:)` consumes the real source identity, records a distinct reason and invalidates current association without manufacturing a zero-person observation. Lost/ambiguous state cannot be cleared by a later failure or return.

No scheduled expiry observer or live context bridge is implemented. B2b must review expiry scheduling, original control stamping, staged worker-state commit and source-gated diagnostic publication. CP1 calibration revisions/cutovers/full replacement remain owned by the later provider; recalibration must not secretly reassign people.

## 6. State and memory bounds

Persistent state is two slot records, at most four confirmed descriptors total, at most two provisional descriptors total, fixed scalar/control/source keys and ambiguity flags. Every descriptor contains at most four numeric torso joints. One immutable snapshot contains outcomes/provenance/counts, not retained raw poses or images.

Transient work contains at most eight current numeric descriptors, a 2-by-8 cost matrix, at most 73 assignments and a bounded plausible subset. All are released at call return. There is no raw frame, image backlog, trajectory tree, candidate registry or historical output cache. Policy validation and per-input bounds apply before traversing candidate values.

The long deterministic test processes 4,998 further frames through **two independently initialized trackers**, verifies identical results, at most four confirmed/two provisional descriptors and at most 73 hypotheses, then invalidates and checks zero descriptors. Worst-case enumeration explicitly reaches 73 hypotheses. These are state/lifetime assertions, not Instruments heap-leak measurements or a realtime throughput benchmark. No pixel resources or producer-buffer ownership are added by B2a.

## 7. Deterministic evidence

**Final focused suite: 47 definitions / 79 executions, one suite, zero failures and skips.**

Coverage includes disarmed/zero/one-person acquisition; atomic mirrored binding/dwell; candidate array reversal and reused IDs; same-screen-position exchange through distinguishable paths; differing torso geometry; indistinguishable crossing refusal; partial-body/common-anatomy support; changing partial anchor sets; weak/missing core and absent peripherals; degenerate partial torso; missing-only recovery dwell; competing recovery/rebind latch; expired prediction/recovery; lost-slot return and third-entrant refusal; harmless distant extras versus near duplicates; cap overflow; 73 assignments; unmatched costs; missing-term penalties; ties/permutation invariance; policy validation; irregular time; stale/out-of-order/malformed input; source/envelope preservation; aspect correction; positive zero coordinates versus absence; all context components and reset/old-control invalidation; explicit new-generation rebind; inference-failure versus zero detections; no-frame expiry and long repeatability/bounds.

Tests use immutable synthetic values, fixed source identities where appropriate, and injected capture/evaluation times. No production mocks, camera access, wall-clock sleeps, GPU work or physical accuracy claims are involved.

One initial focused run failed in the worst-case enumeration test because its synthetic policy used a position gate broad enough to make **initial acquisition** ambiguous. The fixture was corrected to acquire narrowly, then use an elapsed capture interval to exercise 73 admissible matching hypotheses. No assertions were relaxed to force P1/P2 output. Subsequent focused runs passed. Additional review added conservative substitution latching and degenerate-partial rejection, with regression cases; final results below are from that reviewed source.

## 8. Builds, compiler verification and reproducible commands

Environment actually used: Xcode **26.6 (17F113)**, Swift **6.3.3**, iOS/device and Simulator SDK **26.5**. Simulator: iPad mini (A17 Pro), iOS 26.5 (23F77), UUID `1E1C6B07-B356-4303-8756-4C0D2A4CDF05`. Existing project remains Swift 5/default MainActor/approachable concurrency/MemberImportVisibility/deployment 26.5. Commands set DEVELOPER_DIR locally; global tool selection and project settings are untouched.

| Verification on reviewed source | Actual result |
|---|---|
| Simulator app build, complete concurrency | PASS |
| Simulator test-target build | PASS |
| Focused PlayerTrackerTests | PASS: **47 definitions / 79 executions**, 0 failures/skips |
| Full regression, including existing CP1/CP2/camera/preview/gameplay/rendering suites | PASS: **269 definitions / 396 executions in 28 suites**, 0 failures/skips |
| Release Simulator app build (arm64 and x86_64) | PASS |
| Device + Simulator complete strict concurrency, warnings-as-errors | PASS: SIL/WMO, object/WMO and test SIL/WMO |
| Existing ownership negative controls, both SDKs | PASS: **six expected rejections** (retained mutable CV workspace, actor-isolated delegate, retained mutable Vision workspace) |
| Physical build/deployment/live tracking | Not performed or required for pure B2a; device-SDK object compilation is not physical execution. |
| Membership | 65 unique app Swift-file-list entries, 32 unique test entries; tracker and its test each appear once in their correct targets. No project edit required. |
| Whitespace/preservation | `git diff --check` passes; baseline hash comparison limits existing-file changes to the two authorized Swift files. |

No relevant Swift/concurrency errors or warnings remain in successful checks. Existing Xcode **“Metadata extraction skipped. No AppIntents.framework dependency found.”** warning appears in builds; it is unrelated to the tracker. Simulator app launch emits existing RealityKit asset/material diagnostic chatter; passing pure tests do not validate those visuals. The initial sandboxed simctl inventory could not reach Simulator services; normal authorized service access resolved it. A pilot host-only test compile lacked the Testing framework search path; actual SDK/framework-aware Xcode and strict checks passed without suppressions. Initial failed-test diagnostic collection also reported the global CLT simctl lookup limitation; final successful bundles/counts are available.

Representative commands, run from repository root (scratch paths are outside the checkout):

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/lh13b2a/Derived \
  SWIFT_STRICT_CONCURRENCY=complete build

# Same project/scheme/destination/Derived + complete flag:
# build-for-testing

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/lh13b2a/Derived \
  -resultBundlePath /private/tmp/lh13b2a/FocusedReviewed.xcresult \
  -only-testing:SedactiveTests/PlayerTrackerTests test-without-building

# Same project/scheme/destination/Derived, without -only-testing:
# -resultBundlePath /private/tmp/lh13b2a/RegressionReviewed.xcresult test-without-building

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/lh13b2a/ReleaseDerived \
  SWIFT_STRICT_CONCURRENCY=complete build

bash /private/tmp/lh13b2a/verify-strict.sh
git diff --check
```

Strict script uses the same existing approachable-feature flags plus `-swift-version 5 -default-isolation MainActor -strict-concurrency=complete -warnings-as-errors -parse-as-library`. For **both** `arm64-apple-ios26.5` and `arm64-apple-ios26.5-simulator`, it performs `-emit-sil -whole-module-optimization`, `-c -whole-module-optimization`, emits a testable module and compiles focused/new plus existing camera/pose/preview tests to SIL. It includes the new tracker and tests and reuses prior explicit callback positive/ownership negatives. Script/probes/logs are isolated in `/private/tmp/lh13b2a/`, not added to untracked Scripts or app targets.

Final evidence:

- `app-build-reviewed.log`, `test-build-reviewed.log`, `release-build-reviewed.log`.
- `FocusedReviewed.xcresult`, `focused-reviewed.log`, `focused-reviewed-summary.json`.
- `RegressionReviewed.xcresult`, `regression-reviewed.log`, `regression-reviewed-summary.json`.
- `strict-complete.log` and `strict/{iphoneos,iphonesimulator}/` logs.

All under `/private/tmp/lh13b2a/`. xcresult summaries distinguish top-level definition counts from per-device parameterized execution counts; the older B1 180/273 record is historical, not the full suite count for this later merged checkout.

## 9. Known limits and review decisions

- Synthetic matching is not real tracking accuracy, measured tracker CPU performance, total RSS/leak proof or successful P1/P2 tracking on the iPad. No new physical observations were collected.
- The selected test thresholds are unvalidated. Core coverage, duplicate gate, missing penalties, motion/shape weights, margins and all temporal limits need review before live activation.
- Monotonic per-slot ambiguity latching can require a full rebind after a spurious duplicate. Cross-slot identity competition becomes lost immediately. These conservative decisions prevent unsupported recovery but may interrupt usability; do not silently relax them in B2b.
- A pose-only tracker cannot detect every unobserved substitution. Similar people, complete occlusion, depth changes, ducking/torso compression and perspective can defeat geometry. Supported synthetic crossings do not promise arbitrary real-world crossings.
- Full-core acquisition may refuse otherwise visible partial people. Three-joint continued support is experimental and includes nondegeneracy checks, not standing calibration or identity recognition.
- BodySnapshot, its tracking enum, calibration revisions, accepted context and transport are unchanged. Tracking does not imply valid crown/wrist/sole/jump evidence or countdown permission.
- Pure reset/expiry is synchronous and deterministic. Real no-frame lifecycle invalidation, stale in-flight publication, expiry scheduling and worker ownership remain B2b obligations, not proven live by these tests.

## 10. B2b prerequisites and proposed physical protocol

**No B2b implementation is authorized by this report.** Before separately authorizing it:

1. Review this pure API, conservative ambiguity/rebind policy and synthetic tests. Select an explicitly versioned experimental live policy; do not import test defaults automatically.
2. Agree with Jevon on binding authorization/rebind requests/new-generation ownership and future readiness/recovery projection. Shared must not own gameplay phases or GameClock.
3. Adapt the exact B1 source envelope to PlayerTrackingInput inside the existing worker; stamp original control before work. Review atomic source/control validation, staged-state discard and immediate external visibility invalidation on Stop/context changes. No new source or CP1 consumer.
4. Implement only scoped raw tracking composition in MotionEngine/FrameStore and bounded numeric projection after separate approval. Review no-frame expiry scheduling so a stale latest result is never current and timer watermarks do not inadvertently starve delayed valid input.
5. For a later overlay, Kevin must review exact displayed-frame generation/epoch/frameID/geometry/fitted-rect association and one mirror. Hide unmatched overlays. No production GameWorldMapping/cutout change follows from this core.
6. Keep LH-22, live provider publication and gameplay/session integration separate. Any deliberate replacement invalidates old calibration compatibility in a new generation through the reviewed provider lifecycle.

Physical protocol for later B2b, on the iPad Pro 13-inch M4/iPadOS 26.7.1:

- Record configuration/build/policy, lighting/distance, finite per-case duration and preview state. Observe empty-from-first-frame, one person and stable side-by-side people, including differing heights.
- Confirm initial mirrored-left/right binding, ordinary motion, separated position exchanges and overlap/separation. Require explicit uncertainty/rebind where identity is not observable rather than labeling every case successful.
- Exercise missing/weak torso, partial exits, short loss, long loss, third entrants and near-duplicate detections. Verify that no entrant inherits a lost/ambiguous slot.
- Verify Stop/Start, background/foreground, source failures without frames, geometry/epoch reset and explicit rebind authorization. Old results must not revive output.
- Compare finite preview-off/on windows: camera FPS versus pose/tracking cadence, inference and association latency, result age, drops/rejections, bounded source/workspace/preview memory, process RSS and observed thermal state. No 30 FPS Vision requirement or production performance threshold is assumed.
- Keep manual identity observations distinct from numeric diagnostic logs. Do not persist participant imagery/pose histories. Authorize same-source optical overlays separately if needed to prove image alignment.

## 11. Final Git and handoff

The final branch remains `feat/player-tracking` at the starting HEAD. No staging, commit, push, merge, rebase, reset, branch switch or worktree creation occurred.

Expected status after this task:

```text
 M Sedactive.xcodeproj/project.pbxproj                       # preserved external signing edit
 M Sedactive/Shared/BodyTracking/Processing/PlayerTracker.swift
 M SedactiveTests/Shared/BodyTrackingTests/PlayerTrackerTests.swift
?? Docs/LH-13B2-Stable-Player-Tracking-Architecture-Proposal.md # preserved entry document
?? Docs/LH-13B2a-Pure-Tracking-Core-Implementation-Report.md
?? Scripts/                                                # preserved entry work
```

Nothing is staged. Baseline hash comparison covers all pre-existing tracked/untracked files and proves that only the two authorized Swift files changed; the report is the only newly created file in this implementation. CP1/CP2, other-owner code, fixtures, signing edit and existing proposal/Scripts remain unchanged.

Skills read/applied: **swift-concurrency**, **swift-testing-expert**. Verification reached actual Simulator builds/tests and device/Simulator SDK compiler checks. It did not reach physical tracking, live worker integration or rendering validation.

**Historical implementation handoff: REVIEW.** This was the status before the final acceptance audit below. B2b, overlays, calibration and gameplay remain unimplemented; §12 records the current REVISE decision.


## 12. Final Acceptance Addendum — 5 November 2026

### 12.1 Decision and audit scope

**REVISE — LH-13B2a Pure Tracking Core is not accepted yet.** A mandatory identity-safety counterexample is reproducible in the current pure core with the existing synthetic policy, without camera input, timing races, physical accuracy assumptions or any source modification. Passing existing tests and compiler gates does not resolve this logical defect. This is a source/test correction prerequisite, not a request to tune real-device thresholds or weaken conservative refusal.

Audit branch/HEAD: `feat/player-tracking`, `1a48e19971c8440a40d014ce29a091f00418e0f8`. Inspected actual tracker, all current tracking tests, the approved B2 design, CP1 PlayerID/PoseFrame/tracking/provider values and B1 capture provenance/result/context gates. No code, contract, project, test, fixture or integration change is made in this audit. Stop after this documentation update; correction and B2b each need separate authorization.

### 12.2 Mandatory finding — an ambiguous player's pose can be claimed by the other slot

**High-priority correctness defect:** `PlayerTracker.edge` at source line 356 returns nil whenever the slot is lost or `identityAmbiguous`. Consequently the cost matrix built at line 409 contains no competing identity evidence from that slot. The contested-candidate check at lines 426–428 only examines global hypotheses built from that reduced matrix. The other slot can then get a unique-looking assignment and update confirmed history at lines 456–457, even though the omitted slot's retained body history still makes the candidate's identity ambiguous.

The ambiguity latch correctly prevents **that same slot** from recovering automatically. It does not prevent the other slot from taking the ambiguous person's body. This violates the proposal's requirement to preserve unresolved alternative reachability and not confidently associate a candidate where two identities remain plausible. Mechanical injectivity alone is insufficient: no two output slots claim one candidate, yet the surviving output can have the wrong identity.

#### Exact newly executed synthetic counterexample

Use §4's unchanged test policy, 1280×720 canonical unmirrored context, one generation/epoch/geometry/control revision throughout. Every body has the same full, nondegenerate torso, confidence 0.9 and Y center 0.5. Shoulders are `(x±0.05, 0.6)` and hips `(x±0.04, 0.4)`. There is no cap overflow or excessive time gap.

| Source frames / capture time | Synthetic scene / oracle | Actual result |
|---|---|---|
| 1 / 0.000 s, 2 / 0.125 s | P1 at canonical X=0.75; P2 at X=0.25. Explicitly arm and acquire. | P1 tracking candidate 10; P2 tracking candidate 20. |
| 3–10 / 0.250–1.125 s | At each 0.125-second step P1 moves left by 0.025 and P2 right by 0.025, ending at X=0.55 and X=0.45. No crossing. | Both track their intended people throughout. |
| 11 / 1.250 s | P1 remains X=0.55; an extra/duplicate pose is X=0.551; P2 remains X=0.45. | P1 uncertain/ambiguous, candidate nil, requiresRebind=true; P2 tracking candidate 20. |
| 12 / 1.375 s | Only the **same P1** pose at X=0.55 remains visible. P2 is absent. | **P2 tracking candidate 10**, cost approximately 0.657873; P1 still uncertain/ambiguous and requires rebind. |

Candidate IDs above are test-oracle labels within each source frame, not evidence the matcher is allowed to trust. The defect concerns continuous torso/source geometry; the matcher does not need to inspect the numeric ID to make the wrong assignment. A missing P2 must not be reported as confidently tracking the still-plausible P1 body merely because P1 is forbidden to receive matches.

The final frame passes current P2 motion/joint gates. P1's competing identity is absent from the matrix solely because of the latch. Lowering distances or changing the synthetic policy could hide this particular numeric example; it would not repair the distinction between **ineligible for positive assignment** and **still relevant to rejecting another identity's assignment**.

The unchanged Swift core was compiled and executed in a scratch-only native Mac probe:

```text
P1 duplicate frame 11 P1 uncertain ambiguous candidate nil rebind true
  P2 tracking matched candidate 20 cost 0.1644682115270349
P1 still visible, P2 absent frame 12 P1 uncertain ambiguous candidate nil rebind true
  P2 tracking matched candidate 10 cost 0.6578728461081405
AUDIT_COUNTEREXAMPLE_CONFIRMED true
```

Evidence: `/private/tmp/lh13b2a-final-audit/Counterexample.swift`, `counterexample-compile.log`, `counterexample-output.txt` and `counterexample`. The probe uses actual repository PlayerTracker/PlayerID/CP1 model sources and the same numeric fixture geometry/policy; no repository test/source or project file was edited. Command:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc   -parse-as-library -swift-version 5 -default-isolation MainActor   -strict-concurrency=complete -warnings-as-errors -whole-module-optimization   -module-cache-path /private/tmp/lh13b2a-final-audit/ModuleCache   Sedactive/Shared/BodyTracking/Processing/PlayerTracker.swift   Sedactive/Shared/Players/Player.swift   Sedactive/Shared/BodyTracking/Models/*.swift   /private/tmp/lh13b2a-final-audit/Counterexample.swift   -o /private/tmp/lh13b2a-final-audit/counterexample
/private/tmp/lh13b2a-final-audit/counterexample
```

This new execution is a deterministic native-host audit reproduction, **not** an additional Swift Testing suite run, Simulator test, device observation, Vision result or performance measurement.

#### Smallest required correction and missing regression — not implemented

Keep conservative refusal and the monotonic ambiguity latch. Separate permission to **receive** an assignment from bounded identity-competition/exclusion evidence used to **veto** another slot's assignment. An ambiguous/lost slot must not become tracking, but suppressing its assignment row must not erase still-plausible competitors. Define the finite age/reachability rules and how refusal propagates to another affected slot. Alternatively review a deliberately more conservative full-pair rebind whenever independent association can no longer be justified. Neither option needs image history, recognition, a generic tracker or unbounded hypotheses.

A mandatory regression must reproduce the sequence above and its P1/P2 mirror: after one slot requires rebind and the other person disappears, the remaining body cannot become the other slot's confident current match. Cover the corresponding lost-state case and preserve a genuinely distinguishable unaffected player's ability to continue where justified. Assert no confirmed-history update from the refused assignment and no delayed recovery by simply removing a competitor. Agree expected uncertain/lost/rebind propagation before coding.

Current `thirdEntrantCannotInheritIdentityWhenOriginalAlternativeDisappears` and `lostSlotIsNotFilledWhileOtherPlayerRemainsVisible` only guard the affected slot's own reassignment while the other person remains at a well-separated location. They do not test the **other slot** claiming the affected person's body. This is the missing mandatory pure-core test; physical tracking is not required to reveal it.

### 12.3 Acceptance-gate audit

| Gate | Source/test finding |
|---|---|
| Armed stable two-person acquisition | Supported: explicit arm; full-core distinct pair, intended halves, bounded provisional dwell; atomic commit. |
| Initial mirror and frame-local candidate semantics | Supported: descending canonical X only in acquisition; subsequent association uses geometry/time, not IDs/order. Reorder/crossing tests exercise this. |
| All retained competitors and unmatched outcomes | Mechanically enumerated for assignment-eligible slots, **semantically incomplete after latch/loss**: omitted identity competition permits the counterexample above. Mandatory failure. |
| Injectivity / bounded assignments | Supported: different candidate indexes, ≤8 retained candidates and ≤73 hypotheses. This alone does not ensure correct identity. |
| Missing/confidence/coverage costs | Explicit confidence/coverage gates, comparable anatomical subsets, missing-core/scale penalties and unmatched alternatives are present/tested. No numeric policy is approved for production. These checks do not repair omitted identity competition. |
| Confirmed versus tentative history | Ordinary uncertainty recovery uses a separate provisional descriptor and dwell; refusal freezes confirmed history. **The incorrect confident assignment above can still poison the other slot's confirmed history.** |
| Distinguishable versus indistinguishable crossing | Existing controlled crossing cases pass; shared competitive hypotheses cause lost/rebind. Counterexample shows why these cases are not a complete identity-safety proof. |
| Ambiguity latch and lost slot | Monotonic for its own slot; lost never directly becomes tracking. Usability cost from duplicate-triggered rebind remains explicit. **Cross-slot exclusion is unsupported.** |
| Overflow | Explicit refusal when total SDK count exceeds retained values; no first/largest-two workaround. |
| Provenance and rejected-input transaction | Supported within the caller contract: exact generation/epoch/geometry/dimensions/presentation/control, matching PoseFrame metadata, increasing ID/time; validation precedes mutation. |
| No-frame expiry | Supported pure transition: injected monotonic evaluation time, original source remains unchanged, candidate IDs clear; no invented frame. Live scheduling remains B2b work. |
| New-generation rebind | Externally supplied context/revision; remembered last-bound generation prevents immediate reuse. Caller must never reuse older UUIDs or relabel original control; no camera restart/generation is fabricated. |
| Finite state / concurrency isolation | Two slots, four confirmed/two provisional descriptors, bounded transient enumeration; nonisolated checked Sendable values, Foundation-only core, no Tasks/framework owners. Supported by code and existing compiler evidence. |

The documented state, source and ownership rules are useful foundations, but the mandatory identity defect prevents scoped B2a acceptance. This audit does not impose an unapproved numerical accuracy target or require physical validation of a pure core.

### 12.4 Evidence reinspection and provenance

- **Existing results, reread now:** `FocusedReviewed.xcresult` confirms 47 definitions / 79 per-device executions; `RegressionReviewed.xcresult` confirms 269 definitions / 396 executions; both zero failures/skips. Summaries were extracted again with xcresulttool into `/private/tmp/lh13b2a-final-audit/`; no tests were rerun. They lack the counterexample identified here.
- **Existing builds/compiler checks:** reread app/test/Release success markers, strict script/flags, SIL/object/test logs and expected negative diagnostics. Complete checking, warnings-as-errors and both SDK paths are explicit; retained CV workspace, isolated callback and retained Vision workspace negatives are rejected for intended reasons. The existing AppIntents metadata warning is unchanged. No new app build, regression, strict-suite run or device validation occurred.
- **New work in this audit:** source/test/design inspection, policy/state reasoning, one native-host scratch reproduction, old-result extraction, Git/hash/document checks. This separates newly reproduced failure from historical passing suites.
- **Policy review:** all 20 policy fields/units and validators were inspected. Full-four-core acquisition, three-or-four common-core continuation, confidence/extent/gap/cost gates and finite prediction/dwell rules are explicit. Test values remain synthetic; policy selection must consider missing penalties relative to cost weights, overlap refusal and recovery horizon, not merely field validation. No empirical threshold approval follows.

### 12.5 Actionable B2b handoff — blocked until pure-core correction

**Do not activate or implement B2b from this audit.** First authorize the focused B2a correction/test, rerun relevant verification and repeat the acceptance audit. The following is the integration handoff after that prerequisite passes:

| Work item | Required design/acceptance seam | Owner / coordination |
|---|---|---|
| 1. Worker-local composition | One authoritative tracker inside raw MotionEngine composition, invoked synchronously from the existing CameraCopySink/FrameStore worker after Vision numeric conversion. No second FrameStore consumer, timer-driven tracker or per-frame Task. | Edo |
| 2. Exact B1 adaptation | Copy generation, epoch, geometry, original frameID/capturedAt, dimensions and already-applied orientation/mirror provenance from the same CameraPoseResult; forward total observationCount and the unchanged PoseFrame. Verify retained cap agreement. No display reflection or `.up` rotation applied twice. | Edo |
| 3. Original control stamping | Stamp binding/control authorization before work starts, independently of camera generation. Preserve it through completion; never look up a newer revision to make an old result acceptable. Arm/reset requests require explicit current-context authorization. | Edo; request semantics with Jevon |
| 4. Staged mutation/publication | Compute from a worker-local staged value, then commit authoritative state plus source-joined numeric outcome only if original source/context/control is current. Discard rejected staged state. Review serialization with invalidation so a stop/control change cannot race into visible old output. | Edo |
| 5. Lifecycle / no-frame expiry | Immediately gate public output unavailable on Stop/interruption/failure/background/geometry changes, even while synchronous Vision is running. Apply worker reset safely when it returns; never force-reclaim its resources. Serialize expiry with pending input to respect the current evaluation watermark and avoid starving all delayed captured frames. Use host clock, not GameClock. | Edo; Jevon recovery interpretation |
| 6. One state owner | Diagnostics/App/session read a projection, not a second mutable player mapping. Preserve existing source memory/preview independence and single gameplay consumer. No additional status observer; use the existing diagnostics status route. | Edo |
| 7. Numeric-only diagnostics | Show source key, per-slot state/reason/rebind-required, match/missing/ambiguity/overflow/rejection counts and tracking cadence/age. Distinguish camera FPS, inference cadence and tracking outcomes. Do not show calibrated/gameplay-ready state or persist image/pose histories. | Edo |
| 8. Versioned live policy | Select and record an explicitly approved experimental live policy, its units/version and validation/tuning plan. No implicit reuse of TrackingFixtures defaults, production accuracy guarantee or required 30 FPS rate. | Edo approval |
| 9. Binding/full-rebind lifecycle | Jevon retains session/calibration-phase requests and readiness/recovery decisions. Edo validates tracking controls and camera lifecycle. Agree who supplies a never-reused new generation, when a full pair reset is requested and how camera retention is preserved if feasible. Do not change his interfaces or turn a tracker request into an implicit capture restart. | Edo + Jevon |
| 10. Physical acceptance/tuning | Run the finite protocol in §10, including close-player competition, duplicate→other-player loss, reordered raw results, crossings, partial bodies, third entrants, resets and no-frame events. Record manual truth separately from numeric outcomes and measure actual timing/memory; tune only through reviewed policy changes. | Edo; Jevon recovery expectations |

**Owner decisions:** Edo reviews the corrected bounded competition/refusal model and explicit live policy. Jevon must review binding authorization, new-generation/full-rebind orchestration, rebind-required behavior and readiness/status freshness; tracking never advances GameClock or decides gameplay recovery. Kevin's exact-source fitted-rect/single-mirror DEBUG overlay remains separately owned and unauthorized; GameWorldMapping, CutoutPlacement and production rendering need no change in this audit. Optical skeleton-to-image alignment remains unvalidated.

### 12.6 Final scope, limitations and Git status

Current disposition is **REVISE**, superseding the historical REVIEW handoff without erasing its measurements. No ACCEPTED claim is made. B2b activation is blocked by §12.2, not by absent physical testing. All numerical production thresholds, real-iPad P1/P2 correctness, standing/calibrated evidence, gameplay readiness and skeleton alignment remain unapproved/unvalidated.

Only this report is modified in the audit: current status, historical-handoff clarification and this addendum. Since it was already untracked, the exact incremental diff is recorded against `/private/tmp/lh13b2a-final-audit/report-before.md`, not mistaken for an empty tracked Git diff. Existing source/tests, proposal, external signing edit and Scripts are preserved by hash comparison. No branch switch, worktree, staging, commit, push, merge or rebase. Review skills applied: swift-concurrency and swift-testing-expert.


## 13. Identity-Competition Correction & Regression Verification — 5 November 2026

### 13.1 Disposition, authorization and exact files

**B2a: READY FOR RE-REVIEW.** The documented identity-safety defect is corrected and verified within the pure core. Acceptance is intentionally not declared. Sections 1–12 retain the earlier implementation, REVIEW history, REVISE finding and original failing reproduction; the current source/evidence below supersedes their pre-correction algorithm/status where necessary.

The correction was explicitly authorized by Edo, limited to the same existing `feat/player-tracking` branch and these three files:

| File | Correction-specific change |
|---|---|
| `Sedactive/Shared/BodyTracking/Processing/PlayerTracker.swift` | Separate positive output eligibility from identity evidence, retain ambiguous/lost identities in bounded competition, and veto matches when exclusion evidence is unavailable. Add a read-only last-confirmed capture-time watermark to internal slot output. |
| `SedactiveTests/Shared/BodyTrackingTests/PlayerTrackerTests.swift` | Permanent original/mirrored regression, lost/exclusion/expiry/independence/reset/overflow/bounds tests and exact history-watermark assertions. Strengthen one legacy expectation that incorrectly trusted the other slot indefinitely after competitor evidence expired. |
| `Docs/LH-13B2a-Pure-Tracking-Core-Implementation-Report.md` | Current disposition and this dated correction/evidence section. |

HEAD remains `1a48e19971c8440a40d014ce29a091f00418e0f8`. No camera/live caller, MotionEngine, CP1/CP2, calibration, renderer, gameplay, project, signing or generated-resource change. The pre-existing proposal and untracked Scripts are preserved. Skills used: swift-concurrency and swift-testing-expert.

### 13.2 Failing-before evidence — permanent Swift Testing regression

Before changing the algorithm, added `excludedIdentityMustNotBeClaimedByOtherSlot(_:)`, parameterized for the exact §12.2 scene and its P1/P2 mirror. The original coordinates, timestamps and test policy were unchanged. Source bytes were compared with the saved pre-correction core before executing the failure test.

An initial individual-name Xcode filter selected **zero tests**; that run is not evidence of reproduction or success. The subsequent suite-level run actually executed the new parameter cases:

- `BeforeFixSuite.xcresult`: **48 definitions, 47 passed / 1 failed definition; 81 executions, 79 passed / 2 failed, 0 skipped**.
- Both parameter cases failed the intended assertions: the other slot was `tracking` and claimed the remaining body's candidate instead of nil. Four assertion issues were recorded across those two executions.
- The remainder of the old suite passed. The old 47/79 and 269/396 records remain historical baseline evidence, not proof of the correction.

The permanent regression still asserts the exact failure's remedy, including per-slot states/rebind flags and frozen history. Factoring the common approach/duplicate sequence into `TrackingFixtures.duplicateNearCenter` preserved its frames 1–11 and mirrored coordinates; no gate or fixture tuning was used to hide the failure.

### 13.3 Corrected exclusion invariant and algorithm

**Invariant:** inability to receive a positive assignment must not erase an identity from competition. A confident match requires both a supported positive explanation and sufficient separation from retained alternative identity explanations. Missing/expired comparison evidence is not proof that another identity is impossible.

The previous `edge` function combined state eligibility and numeric evidence, returning nil for all lost/ambiguous slots. It is replaced by state-independent `identityEvidence`, with three distinct outcomes:

| Evidence | Meaning / use |
|---|---|
| `supported(cost)` | Fresh corresponding torso evidence passes the existing gates. This identity remains in the current identity-hypothesis matrix even if its slot is lost or latched. |
| `excluded` | Fresh, comparable geometry fails the configured position/residual or available-scale gates. Under that experimental geometric model it is noncompetitive; this is not proof of personal identity. |
| `unavailable` | Missing anchor, expired/nonpositive prediction age, insufficient comparable anatomical support or unusable numerical evaluation. It cannot establish exclusion and must not silently disappear from safety checks. |

The same at-most-73 injective hypotheses now explain **identities**, including retained identities forbidden positive output. Existing unmatched costs, competing-hypothesis margins and duplicate handling remain. A separate eligibility snapshot plus final state/latch guards prohibit returning a current candidate for a lost or identity-ambiguous slot. Explaining a body as that identity for exclusion purposes does not reacquire it or update its confirmed history.

Before confirming another slot's chosen candidate:

1. If the other bound identity's evidence for it is unavailable, refuse, latch ambiguity and require explicit rebind. The candidate cannot become confidently identified from absence of usable competitor evidence.
2. If the other slot is ineligible for positive output but still supports that candidate, a lower positive matching cost alone is insufficient. Permit the match only when **every plausible global hypothesis explains the other identity with a separate, non-nil body**. Otherwise refuse/latch/rebind.
3. If relevant geometry excludes that competitor, or the current hypotheses separately explain it and uniquely support the healthy player's body, a genuinely independent match can continue. A distant noncompetitive extra alone does not freeze the pair.

This additional veto matters beyond simply including ghost rows: a candidate at P2's old position can have zero P2 cost while remaining plausible for a forbidden P1 identity. A new regression verifies refusal unless a separate P1 body is adequately explained.

No policy fields, default values or thresholds were added or tightened. `PlayerTrackingPolicy` declarations/validation and the original synthetic policy remain byte-identical to pre-correction versions. The correction changes logical eligibility/competition handling, not the distances in §12.2.

### 13.4 Relevance, expiry, refusal and history lifetime

Retained identity evidence uses the existing last two confirmed descriptors, original capture time, compatible geometry/context and `maximumObservationGap` prediction-age horizon. The same anatomical/quality/gating rules apply. Within that finite horizon, a lost/ambiguous identity can participate in exclusion analysis without receiving an output assignment. The existing `freshness` policy independently controls no-frame positive readiness through `expire`; becoming unavailable for positive output does not mean the person is absent.

Once the confirmed anchor is too old to compare, the evidence is explicitly unavailable. No ever-widening prediction or discarded-row assumption establishes identity. A proposed positive match challenged by such unavailable evidence becomes uncertain/rebind-required; later candidate disappearance does not clear that monotonic latch. Insufficient common torso joints are treated the same way. A finite, valid comparison that rules a candidate outside the reviewed geometric gates is different from a stale/unusable descriptor.

**Deliberate conservative tradeoff:** a continuously visible player is no longer trusted indefinitely after the other identity's evidence expires. The legacy `lostSlotIsNotFilledWhileOtherPlayerRemainsVisible` test assumed the opposite and was replaced with `lostSlotNotReplacedAndExpiredCompetitorRequiresExplicitRebind`, asserting nil current associations, rebind-required and frozen confirmed time after expiry. The separate fresh-independent-body tests continue to require successful unaffected tracking. This strengthens the newly authorized expiry/exclusion safety contract; it does not merely loosen an old assertion to pass the audit scenario.

`PlayerTrackingSlotResult.lastConfirmedAt` is an immutable, read-only diagnostic watermark copied from the confirmed descriptor. It permits direct assertions that a refused assignment did not update history, even after descriptor counts already reached their maximum. It is not a new capture timestamp, standing baseline, state owner or CP1 field. Tentative recovery, lost/ambiguous identity explanations, unknown-evidence refusals and overflow cannot advance it.

Generation/epoch/geometry/presentation/control validation is unchanged. An authorized new-generation reset clears all descriptors, latches and output watermarks. An old frame/control cannot revive them. Rebind authorization remains external; no camera generation or restart is fabricated.

### 13.5 Permanent regression scenarios and before/after observations

New coverage adds **11 definitions / 15 executions** over the prior focused baseline:

- Exact P1 duplicate → P2 disappears, and mirror: frame 11 still keeps the unaffected player tracking; frame 12 cannot claim the excluded identity's body. Confirmed times remain 1.125 s and 1.250 s respectively.
- Excluded identity progressed to lost, both directions: retained fresh evidence still prevents theft. A separately bounded test policy uses equal 0.5-second gap/window to place the lost transition exactly inside the relevance boundary; these are test-specific values, not a new operational policy. Later expired evidence forces explicit rebind rather than a confident match.
- Independent healthy body with a separately explained excluded body, changed candidate IDs/order and a distant extra: healthy slot remains tracking and advances its own confirmed time; excluded slot stays unassigned/rebind-required with frozen time.
- Repeated candidate disappearance and reused IDs: no restoration by sorting or by dropping a competitor; refusal leaves both histories frozen.
- Lower-cost positive match that is still plausible for the excluded identity: cost advantage alone cannot bypass exclusion. The converse test requires a healthy current match when independent bodies are sufficiently explained.
- Capture-time expiry and insufficient comparable torso support: unavailable evidence causes explicit uncertainty/rebind, never a favorable missing-cost or absence inference.
- New-generation reset/rebind clears old exclusion/history and rejects delayed old controls.
- Overflow/third-person interference does not overwrite retained identity evidence or create a confident replacement.
- Long excluded sequences through two independent trackers produce identical results, nil refused associations, frozen confirmed times, at most four confirmed/two provisional descriptors and at most 73 hypotheses.

An intermediate new lost-case test initially expected both slots to become lost immediately. Actual global evidence uniquely explained the remaining body as the already-lost identity, correctly leaving the other slot **uncertain/missing** with nil candidate. The test now asserts that precise state/history, then separately verifies rebind-required refusal when evidence expires. The original mandatory “no confident wrong association” assertion and coordinates were never weakened.

The original scratch audit probe was also compiled again against corrected source with its scene unchanged:

```text
P1 duplicate frame 11 P1 uncertain ambiguous candidate nil rebind true
  P2 tracking matched candidate 20 cost 0.1644682115270349
P1 still visible, P2 absent frame 12 P1 uncertain ambiguous candidate nil rebind true
  P2 uncertain missingOrWeak candidate nil cost nil
AUDIT_COUNTEREXAMPLE_CONFIRMED false
```

That native-host check corroborates the permanent Simulator regressions; it is not a physical Vision or performance test.

### 13.6 Verification results and baseline comparison

Newly executed for this correction, with Xcode 26.6 / Swift 6.3.3 / SDKs 26.5 and unchanged Swift 5/default MainActor/approachable-concurrency settings:

| Gate | New actual result | Previous passing baseline |
|---|---|---|
| All PlayerTrackerTests | **58 definitions / 94 executions**, 0 failures/skips | 47 / 79 |
| Full Simulator regression | **280 definitions / 411 executions in 28 suites**, 0 failures/skips | 269 / 396 |
| Simulator app build | PASS, complete concurrency | PASS |
| Simulator test-target build | PASS | PASS |
| Release Simulator build | PASS | PASS |
| Complete strict checking, warnings-as-errors | PASS, both device and Simulator SDKs, SIL/WMO + object/WMO + test SIL/WMO | PASS |
| Existing meaningful ownership negatives | **Six expected rejections**, retained mutable CV workspace, isolated callback and retained Vision workspace on both SDKs | Six expected rejections |
| Scope, target membership and whitespace | PASS; no project/target change, same existing source/test locations, `git diff --check` clean | Preserved |
| Physical tracking/device performance | Not performed; pure/disconnected scope | Not validated |

The full suite increase is exactly the new 11 definitions / 15 executions; existing CP1/CP2, camera/preview, gameplay and rendering regression suites are retained. Definition/execution counts were extracted from actual xcresult summaries, not inferred solely from log text.

One initial full-regression launch could not create its installed XCTest bundle before tests ran. Rebuilding `build-for-testing` and rerunning fixed the bundle-launch problem with **no source or assertion changes**. Only the final successful run is counted above. Existing AppIntents metadata-extraction warnings and Simulator RealityKit asset diagnostic chatter remain; no successful Swift/concurrency error or warning was suppressed. The initial individual-method filter selected zero tests as already disclosed; the real before/after suite evidence is separate.

Evidence directory: `/private/tmp/lh13b2a-identity-correction/`:

- `BeforeFixSuite.xcresult`, `before-suite.log`, `before-summary.json`: intended pre-fix failure.
- `CorrectedFocused.xcresult`, `corrected-focused.log`, `focused-summary.json`: final focused success.
- `RegressionFinal.xcresult`, `regression-final.log`, `regression-summary.json`: final full success.
- `app-build.log`, `test-build-final.log`, `release-build.log`.
- `verify-strict.sh`, `strict.log`, `strict/{iphoneos,iphonesimulator}/`: complete compiler and negative-control evidence. Isolated script reuses the prior exact verification flags and existing controls; Scripts in the repository is untouched.
- `counterexample-after`, `probe-build.log`, `probe-after.txt`: unchanged scene against corrected source.

Reproduction commands use the same project/scheme and Simulator as §8. For this correction the derived-data paths remained `/private/tmp/lh13b2a/Derived` and `/private/tmp/lh13b2a/ReleaseDerived`; evidence paths changed to the correction directory:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# Build app; then build-for-testing to prepare the XCTest bundle:
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive   -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05'   -derivedDataPath /private/tmp/lh13b2a/Derived   SWIFT_STRICT_CONCURRENCY=complete build-for-testing

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive   -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05'   -derivedDataPath /private/tmp/lh13b2a/Derived   -resultBundlePath /private/tmp/lh13b2a-identity-correction/RegressionFinal.xcresult   test-without-building
# Focused run adds -only-testing:SedactiveTests/PlayerTrackerTests with its own result bundle.
bash /private/tmp/lh13b2a-identity-correction/verify-strict.sh
```

### 13.7 Boundedness, limitations and B2b handoff

The correction adds only transient two-by-eight identity evidence and scalar eligibility flags to the existing bounded candidate/cost/hypothesis work. There are still exactly two slots, at most eight current descriptors, four confirmed/two provisional descriptors and 73 identity hypotheses. No new image/pose-frame cache, competitor trajectory, actor, task, lock, queue or permanent candidate collection is introduced. The watermark adds no new history owner.

Remaining limits are deliberately conservative: spurious duplicates can latch rebind; expired or incomparable competitor evidence can interrupt the otherwise-visible player; prediction/shape gates remain experimental geometric assumptions, not personal identity recognition. No universal correctness through complete occlusion, unobserved substitution, torso compression or arbitrary scene changes is claimed. Synthetic pass counts are not physical calibration, measured performance or production threshold acceptance.

Before B2b, re-review this corrected identity/exclusion model, its expiry tradeoff and the new regressions. The prior B2b handoff (§12.5) remains a planning checklist: one worker-local owner, exact original source/control stamping, staged mutation and stale-publication rejection, no-frame invalidation/expiry, existing diagnostics route without a second observer, and explicit versioned live policy. Coordinate binding/new-generation/full-rebind and recovery expectations with Jevon. Kevin's same-source skeleton overlay remains separately owned and unauthorized. No live integration is added here.

### 13.8 Final status and Git boundary

**B2a: READY FOR RE-REVIEW.** Mandatory original/mirrored regressions fail before the correction and pass after it, together with the expanded suite, full regression, builds and strict compiler gates. This is not automatic ACCEPTED status or permission to proceed to B2b.

Only the three authorized files changed relative to correction entry. Hash checks preserve the existing B2 proposal, signing `.pbxproj` modification, untracked Scripts and every other baseline file. The branch/HEAD remain unchanged; nothing is staged, committed, pushed, merged, reset, rebased or switched. Stop for Edo's review.


## 14. Final B2a Re-Review & Acceptance Addendum — 5 November 2026

### 14.1 Disposition and scope

**REVISE — acceptance withheld.** The prior correction closes the already-latched identity omission, including its original and mirrored regressions. However, newly created ambiguity in the **same processing call** can bypass the additional competitor veto. This is a deterministic pure-core correctness issue under a validated policy, not a physical performance/accuracy requirement or permission to relax conservative refusal.

Audit baseline: existing `feat/player-tracking`, HEAD `1a48e19971c8440a40d014ce29a091f00418e0f8`. Inspected actual identityEvidence, hypotheses, output decisions, confirm/recover/refuse paths, current tests, B2 proposal, PlayerID/PoseFrame/CP1 tracking and recorded compiler/results evidence. Only this report changes. Swift, tests, contracts, project/signing, existing proposal and Scripts are preserved.

### 14.2 Mandatory finding — output eligibility is stale within the frame

Source locations at audit time:

- `PlayerTracker.swift:418` snapshots `assignmentEligible` **before** processing either slot's current outcome.
- Lines 454 and 479 can set `identityAmbiguous` during that frame; lines 468–469 can also latch a new refusal.
- Lines 465–467 decide whether a supported competing identity requires exclusion using the earlier `assignmentEligible[other]`, rather than the effective current-frame eligibility.
- Lines 483–484 can consequently confirm the other slot and advance its history before the frame's final identity state has been accounted for.

The recipient's own lost/latch guard is intact. The bypass concerns the **competitor**: it has become ineligible in the current output but is still considered assignment-eligible by the veto. Merely rereading live state in the existing sequential loop would also be insufficient: the mirrored case confirms the earlier-processed slot before the later slot's ambiguity is discovered. Final decisions must be frame-consistent, independent of slot processing order.

#### Deterministic scratch reproduction, both directions

Use the existing synthetic policy with `unmatchedCost = 0.5` and its otherwise unchanged defaults, including `assignmentMargin = 0.15`. This is a **valid caller-supplied policy**, and unmatchedCost 0.5 is already exercised by an existing test (that earlier test uses a different margin). No production policy, source, test or gate was edited; no value was tuned to hide a failure. The core's safety contract applies to validated policy combinations, not only the helper's default unmatched cost 2.

1280×720, canonical unmirrored source, full torso confidence 0.9, unchanged generation/epoch/geometry/control throughout:

1. Frames 1–2 at 0 and 0.125 seconds: explicitly bind full torso candidates at canonical X=0.55 (P1) and X=0.45 (P2). Both track normally.
2. Frame 3 at 0.25 seconds: two **partial** candidates at X=0.55 and X=0.551, each missing only leftHip, plus a full candidate at X=0.45. All other torso geometry matches the synthetic helper. The mirror duplicates X=0.45 and X=0.449 and keeps the full candidate at X=0.55.
3. For the affected identity, the two partial candidates each incur the explicit missing-core/scale penalties (approximately 0.600 and 0.607). Its unmatched cost is 0.5, so plausible global hypotheses include **nil and both partial candidates**. The affected slot correctly becomes uncertain, ambiguous and requires rebind.
4. The other slot's full candidate has cost zero. It remains supported as a competing identity for the now-ambiguous slot (approximately 0.658), but not every plausible hypothesis supplies a separate body: the other identity may be unmatched. Thus `independentOtherBody` is false. The exclusion veto should apply to the frame's now-ineligible identity, but `assignmentEligible[other]` is still true from the beginning of the call.
5. The other slot is returned **tracking candidate 90**, with confirmed time advanced from 0.125 to **0.25 seconds**, despite the unresolved supported competing identity and missing independent-body explanation.
6. Frame 4 at 0.375 seconds repeats the scene. Now the latch exists at frame entry, and the other slot correctly becomes uncertain/rebind-required with nil candidate. This next-frame refusal cannot undo the already published confident association/history update in frame 3.

The result is symmetric:

```text
mirrored false first affected uncertain true first other tracking candidate 90
  confirmedAt 0.25 next other uncertain true next candidate nil
SAME_FRAME_INELIGIBILITY_BYPASS true
mirrored true first affected uncertain true first other tracking candidate 90
  confirmedAt 0.25 next other uncertain true next candidate nil
SAME_FRAME_INELIGIBILITY_BYPASS true
```

This is a violation of the corrected **same-frame exclusion invariant**, not an assertion of a real participant's identity from a saved camera image. Lower positive cost alone bypasses a rule that would refuse the identical unresolved competition after the latch already existed. No raw Vision data, camera capture, personal recognition or device latency assumption is involved.

Scratch evidence: `/private/tmp/lh13b2a-rereview/SameFrameEligibility.swift`, `compile.log`, `output.txt`, `same-frame`. The probe compiles/executes the unchanged repository core and CP1 value sources under Swift 5, default MainActor, complete strict concurrency, warnings-as-errors and WMO. It is outside all project targets. Command:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor -strict-concurrency=complete -warnings-as-errors -whole-module-optimization -module-cache-path /private/tmp/lh13b2a-rereview/ModuleCache Sedactive/Shared/BodyTracking/Processing/PlayerTracker.swift Sedactive/Shared/Players/Player.swift Sedactive/Shared/BodyTracking/Models/*.swift /private/tmp/lh13b2a-rereview/SameFrameEligibility.swift -o /private/tmp/lh13b2a-rereview/same-frame
/private/tmp/lh13b2a-rereview/same-frame
```

This new native-host audit execution is not a new Swift Testing/Simulator result or physical accuracy/performance evidence.

### 14.3 Invariant audit and mandatory missing coverage

| Invariant group | Re-review finding |
|---|---|
| Already lost/latched slots never receive positive associations | Supported by state guards before confirm/recover and tests. |
| Retained competition survives prior-frame loss/latch | Supported: identityEvidence is state-independent and both identities enter bounded hypotheses. Original/mirrored §12 counterexamples are corrected. |
| Supported competitor / smaller positive cost cannot bypass exclusion | **Fails when ineligibility arises in the same call.** The pre-frame eligibility snapshot defeats the final veto despite current unresolved ambiguity. |
| Unavailable/expired comparison is not exclusion | Supported by explicit evidence enum and unknownCompetitor veto. Missing common support and prediction age are unavailable; fresh geometric exclusions remain experimental model decisions. |
| Independent unaffected body can continue | Existing positive-control tests support this for separately explained bodies/distant extras. That does not justify frame-3 confirmation in §14.2, where independent explanation is absent in some plausible hypotheses. |
| Injectivity and candidate-order independence | Mechanically supported by injective indexes, choice uniqueness and geometry-based association; the new defect does not require duplicate output indexes or stable candidate IDs. |
| Refusal/tentative recovery does not directly update history | Those paths preserve history as intended, but the stale-eligibility bypass misclassifies the other slot as confirmable and advances its history incorrectly. Whole-frame confirmation safety remains unsupported. |
| Context/reset/time provenance | Existing exact-source/control validation and reset behavior are intact; the new failure uses one fully compatible context and valid increasing capture times. No camera generation is manufactured. |
| Bounds and ownership | Still two slots, eight candidates, four confirmed/two provisional descriptors and 73 hypotheses; Foundation-only nonisolated checked Sendable core, no tasks/framework ownership. No new ownership failure found. |

Current `lowerCostPositiveMatchCannotEraseExcludedButPlausibleOtherIdentity` first latches a duplicate in one frame and tests the lower-cost candidate **in the next frame**. Existing lost-state tests similarly establish loss before the association call. None covers the transition from tracking/ordinary uncertainty into identity-ambiguous **within the frame whose other outcome is being confirmed**.

A mandatory permanent regression must cover §14.2 and its mirror, including partial evidence, competing unmatched hypotheses and exact confirmed-history watermarks. Assert that current-frame ineligibility cannot be bypassed regardless of loop order; include a positive control where an independent other body is actually explained. A validated policy may alter unmatched/missing-cost relationships, so do not fix or conceal this by tightening gates, banning only these coordinates, changing the scene or approving one numerical policy as the safety argument.

**Proposed correction boundary, not implemented:** stage both slots' proposed state/refusal decisions before committing either confirmed history. Evaluate exclusion against effective frame-final eligibility, and propagate any newly created monotonic latches/refusals before confirmations. Any needed fixed-point pass must remain finite for two slots; it must not create a trajectory tree or a new actor/queue. Merely replacing the eligibility snapshot with sequential live reads cannot address the mirrored ordering. A separately authorized correction must define the resulting states, add regressions and repeat relevant verification/re-review.

### 14.4 Evidence reinspection and limits

Re-read actual existing result bundles with xcresulttool:

- Pre-correction `BeforeFixSuite.xcresult`: 48 definitions, 79 passing / 2 failing executions, no skips; the original and mirrored historical defect failed as intended.
- Corrected `CorrectedFocused.xcresult`: **58 definitions / 94 passing executions**, zero failures/skips.
- Corrected `RegressionFinal.xcresult`: **280 definitions / 411 passing executions**, zero failures/skips.

Fresh read-only summaries are in `/private/tmp/lh13b2a-rereview/{before,focused,regression}-result.json`. No repository suites, app builds or strict compilation suites were rerun during this audit. The old passing suites do not contain the new same-frame transition case.

Inspected existing app/test/Release successful completion markers, strict script flags/source lists, both SDKs' positive SIL/WMO, object/WMO and test SIL logs, and actual six negative diagnostics. Positives have no relevant compiler/concurrency warnings/errors; negatives reject retained mutable CV/Vision sharing and isolated callback registration as intended. The existing AppIntents metadata warning remains unrelated. These compiler facts do not prove algorithmic identity safety.

Policy tradeoffs remain scoped and nonblocking by themselves: duplicates may force rebind; unavailable competitor evidence can interrupt a visible player; lost identity does not auto-recover; full torso acquisition and three/four-joint support are experimental. Production confidence/distance/time thresholds are not approved. The mandatory blocker is the demonstrated frame-consistency defect, not missing physical validation.

### 14.5 B2b readiness and owner decisions

**B2b is not ready for live activation and is not authorized here.** First correct the pure-core defect and review its new state/history tests. The existing §12.5/§13.7 handoff remains prospective:

- Edo: one worker-owned tracker, exact B1 source/PoseFrame adaptation, original control stamping, source-gated staged commits, immediate no-frame lifecycle invalidation/host-clock expiry, bounded numeric-only diagnostics and explicit versioned experimental live policy.
- Edo + Jevon: binding/rebind request authorization, never-reused external camera generation, full-pair reset/recovery behavior and readiness/status interpretation. PlayerTracker must not fabricate generations or implicitly restart capture; Jevon retains game-phase/GameClock authority.
- Kevin: future exact-source fitted-rect/single-mirror DEBUG skeleton overlay remains separately reviewed and unauthorized. No production renderer, GameWorldMapping or CutoutPlacement change follows.
- Later physical acceptance must exercise partial/extra detections and same-frame ambiguity transitions as well as the established protocol. No live P1/P2 accuracy, production thresholds, calibration, BodySnapshot publication, gameplay readiness or optical overlay alignment is validated by this audit.

### 14.6 Documentation and Git boundary

Only this report changes: current disposition plus this dated addendum. REVIEW, original REVISE/failing reproduction, correction and READY FOR RE-REVIEW history remain intact. Exact incremental documentation diff is measured against `/private/tmp/lh13b2a-rereview/report-before.md` because this report was already untracked.

All pre-existing source/tests, architecture proposal, signing modifications and Scripts remain unchanged by this audit. Branch remains `feat/player-tracking` at the same HEAD; nothing staged, committed, pushed, merged, rebased, reset or switched. Skills applied: swift-concurrency and swift-testing-expert. **Final disposition: REVISE. Stop for a separately authorized pure-core correction; do not begin B2b.**


## 15. Same-Frame Identity Resolution Correction — 6 November 2026

### 15.1 Scope and disposition

**LH-13B2a: READY FOR RE-REVIEW.** Both §14 same-frame directions are corrected, and earlier §12/§13 regressions remain passing. This is a pure-core correction, not acceptance or authorization for live integration. Prior REVIEW, both REVISE findings, scratch reproductions and earlier verification remain historical evidence; this section records the current implementation and results.

Branch/HEAD remained `feat/player-tracking` / `1a48e19971c8440a40d014ce29a091f00418e0f8`. Only the three authorized files changed:

- `Sedactive/Shared/BodyTracking/Processing/PlayerTracker.swift`: frame-local evaluation, symmetric resolution, single history commit and value-returning transition helpers.
- `SedactiveTests/Shared/BodyTrackingTests/PlayerTrackerTests.swift`: exact failing-before original/mirror plus policy, permutation, recovery, circular-evidence, reset and bounded-sequence tests.
- `Docs/LH-13B2a-Pure-Tracking-Core-Implementation-Report.md`: current disposition and this section.

No camera/FrameStore/Vision/MotionEngine integration, diagnostics, CP1/CP2, calibration, renderer, gameplay, generated-resource, project or signing change. Existing proposal and untracked Scripts are preserved. Skills applied: swift-concurrency and swift-testing-expert.

### 15.2 Root cause and permanent failing-before proof

The previous code captured assignment eligibility at frame entry, then mutated each slot's ambiguity and confirmed history in a sequential output loop. A newly latched slot therefore did not constrain its peer until the next frame. Rereading mutable state inside that loop would still miss the mirrored order, where the unsafe confirmation happens first.

Added `sameFrameNewAmbiguityMustVetoOtherConfirmation(_:)` for **both directions before changing the core**, using the exact §14.2 policy (`unmatchedCost=0.5`, `assignmentMargin=0.15`, other defaults unchanged), binding at X=0.55/0.45 at 0.000/0.125 seconds and partial duplicate scene at 0.250 seconds. No coordinate, joint, confidence, threshold or dwell change hides the defect.

Before-fix suite result, actually executed on the unchanged core:

- **59 definitions: 58 passed, 1 failed. 96 executions: 94 passed, 2 failed; 0 skipped.**
- Both parameter cases failed the unsafe slot's state/rebind/candidate/history assertions; eight assertion issues were recorded.
- The incorrect confirmation advanced its last-confirmed time to 0.250 seconds and increased confirmed history before whole-frame ambiguity was resolved.
- Saved `BeforeFix.xcresult`, `before-tests.log`, `before-summary.json` and the original `PlayerTracker.swift` copy under `/private/tmp/lh13b2a-frame-resolution/`. Source-byte comparison confirmed the core was unchanged at this stage.

### 15.3 Evaluate → Resolve → Commit

The correction uses three finite stages in the existing synchronous association method. There is no new actor, task, lock, queue, timer or framework.

**A — Evaluate:** after existing source/control/PoseFrame validation, copy the two slots to a local baseline. Stage source-gap/expiry refusals there; do not mutate authoritative identity/history. Build current numeric descriptors, supported/excluded/unavailable evidence and all bounded injective identity hypotheses, including lost/latched competitors. Derive a `FrameProposal` for **each** slot: no positive output, refusal/latch, or unique candidate/cost. Duplicate/ambiguous decisions for both slots are known before any confirmation. Lost/latched baseline slots cannot propose positive output.

**B — Resolve:** apply the competitor rule to every candidate proposal using only immutable baseline evidence and plausible hypotheses. The old `assignmentEligible[other]` condition is removed: a supported competing identity must satisfy exclusion requirements **regardless of its past, newly discovered or final positive eligibility**. A lower matching cost cannot opt out of this rule.

For candidate `c` proposed for slot `i`, compare the other identity `j`:

- `excluded`: a fresh comparable geometric model rules out that alternative under the configured experimental gates; the proposal can proceed.
- `unavailable`: an existing bound identity cannot be excluded; resolve to uncertainty/rebind with nil candidate. Expired/missing comparisons are not evidence of absence.
- `supported`: **every** plausible global hypothesis must explain `j` with a separate non-nil candidate `d != c`. Also require the reverse comparison of identity `i` against `d` to be available (`supported` or `excluded`). An unknown reverse edge cannot create a circular independent-body justification. If these conditions fail, resolve to a refusal/latch.

This rule is deliberately independent of another slot's positive-output decision. Forbidding positive output never erases identity evidence; conversely, discovering a new latch cannot weaken a check that already applies to all competitors. The resolution loops read proposals/evidence and write a separate resolved vector; they do not read a peer's progressively mutated state or history.

**C — Commit:** create both final slot values from that same baseline and the resolved vector. Only safe unique candidates can call value-returning confirmation/recovery helpers. Ordinary uncertain recovery retains the existing multi-observation capture-time dwell; tentative recovery changes only its bounded provisional descriptor. Refusals/lost outcomes retain confirmed history. Assign the complete slot vector once, after both final values are computed. No provisional confirmation escapes through a snapshot or persists for the next frame.

Source-gap, overflow and contested-identity early exits likewise stage/commit both refusals together, without positive history updates. Joint initial acquisition remains the existing explicitly armed atomic pair gate; it does not have sequential competing association decisions to resolve.

### 15.4 Frame-consistency and termination argument

Let `E` be the immutable two-by-N identity-evidence matrix and `H` the fixed plausible injective hypotheses for this source. A positive confirmation for `(i,c)` requires: compatible original source/control, eligible recipient, a unique common choice `H[i]=c`, no duplicate refusal, the universal competitor test above, and any required recovery dwell. All tests complete before confirmation.

The resulting invariants are:

1. Candidate assignments are injective; candidates/IDs/order never create persistent identity.
2. Lost or monotonically latched recipients have no positive proposal, but their evidence remains in `E`/`H`.
3. The competitor obligation is maximal from the outset: it cannot be relaxed by a pre-frame eligibility bit or a later same-frame refusal.
4. Supported evidence needs a distinct-body explanation in **all** plausible hypotheses; unavailable evidence cannot be converted to exclusion or zero cost.
5. A reverse unavailable comparison refuses circular explanation instead of relying on a peer's tentative positive output.
6. Confirmation reads only frame-baseline histories. Refused, lost and tentative outcomes never advance confirmed descriptors or watermarks.
7. The two final outcomes commit together; evaluation/commit slot order cannot affect the immutable predicates or baseline inputs.
8. Existing generation/epoch/geometry/presentation/time/control rejection remains before mutation. The core creates no camera generation and no fake expiry frame.

**No fixed-point iteration is necessary.** The resolution predicate is a pure function of fixed `(baseline, E, H, proposal)`, not another resolved eligibility or confirmation. Repeating resolution produces the same decisions; a newly latched state adds no previously skipped competitor obligation. This avoids both sequential-order leakage and circular status dependencies. Only two proposals are evaluated, two are resolved and two are committed.

Candidate values remain capped at eight; hypotheses at 73. Persistent histories remain at most two confirmed and one provisional descriptor per slot. Baseline/proposal/resolved/commit temporaries are constant-size two-slot values (immutable descriptor storage uses normal Swift value/COW semantics); no retained extra trajectory, raw image, pose-frame history or new state owner is added. Work/state bounds are independent of stream length.

### 15.5 Before/after outcomes and confirmed history

For both exact §14 directions in the corrected SAME frame:

| Outcome | Defective | Corrected |
|---|---|---|
| Affected partial-duplicate slot | uncertain/ambiguous, rebind=true, nil candidate | unchanged conservative refusal |
| Other slot | tracking candidate 90, rebind=false | **uncertain/ambiguous, rebind=true, nil candidate** |
| Other lastConfirmedAt | incorrectly 0.250 s | **0.125 s**, unchanged from the accepted baseline |
| Confirmed descriptor count | incorrectly increased | **2**, no tentative/unsafe confirmation |
| Provisional descriptor count | no safety restoration | **0**, refused recovery cannot be staged |

Recompiled the unchanged scratch §14 probe against corrected code; both directions now print `SAME_FRAME_INELIGIBILITY_BYPASS false`, with nil current candidate and confirmedAt 0.125 in frame 3. The unchanged §12 probe still prints `AUDIT_COUNTEREXAMPLE_CONFIRMED false`; its healthy player can track in frame 11 but cannot claim the remaining excluded person's body in frame 12. These native-host checks supplement permanent Simulator tests and are not physical tracking/performance validation.

No policy declarations, validation limits or original helper defaults were changed. New parameterized test values are controlled synthetic cases, not tuning approved for live production.

### 15.6 Expanded permanent tests

Added **10 definitions / 26 executions** relative to 58/94, including the exact regression. Current coverage adds:

- Original/mirrored §14 transitions: ambiguity discovered in either logical slot, same-frame refusal/rebind/reason/nil IDs and frozen timestamps.
- All six permutations of three current candidates, both mirrors and unmatched costs 0.5/0.6/0.7: **36 sequence checks inside six parameter executions**, not 36 extra counted test executions.
- Missing-evidence penalties 0.25/0.30/0.35 against unmatched cost 0.5, including match-versus-unmatched and multiple candidate ambiguity. The unsafe peer still cannot confirm even when the other refusal itself remains ordinarily recoverable rather than latched.
- Positive controls at unmatched costs 0.8/2.0: a guaranteed independent-body explanation lets the unaffected slot continue; only the ambiguous slot refuses. No blanket “both lost” workaround.
- Ordinary uncertainty and a pending recovery whose dwell would mature in the unsafe frame: no unsafe history/provisional advancement.
- Circular partial-body explanation with unknown reverse comparison: both refuse. A far-separated counterpart verifies that geometric exclusion can still preserve the independently supported side.
- New-generation/control reset after both new latches, and rejection of delayed old context/control.
- Repeated ambiguous frames through two trackers and changing candidate order: deterministic results, nil associations, monotonic rebind flags, frozen timestamps and constant descriptor/hypothesis limits.

All earlier tests remain in the run: §12 original/mirror, already-latched and lost identities, overflow/third-person cases, no-frame expiry, weak/missing/partial joints, independent recovery, distinguishable/indistinguishable crossing and long supported tracking sequences. No test assertion or original scene was loosened to accept next-frame refusal instead of same-frame safety.

### 15.7 Newly executed verification

Environment rechecked: Xcode **26.6 (17F113)**, Swift **6.3.3**, device/Simulator SDK **26.5**; existing Swift 5/default MainActor/approachable-concurrency/MemberImportVisibility/deployment settings preserved. Simulator remains iPad mini (A17 Pro), 26.5, UUID `1E1C6B07-B356-4303-8756-4C0D2A4CDF05`.

| Gate | Current actual result | Previous passing baseline |
|---|---|---|
| PlayerTrackerTests | **68 definitions / 120 executions**, zero failures/skips | 58 / 94 |
| Full Simulator regression | **290 definitions / 437 executions in 28 suites**, zero failures/skips | 280 / 411 |
| Simulator app build | PASS | PASS |
| Simulator test-target build | PASS | PASS |
| Release Simulator build | PASS | PASS |
| Complete concurrency + warnings-as-errors | PASS on both SDKs, SIL/WMO, object/WMO and test SIL/WMO | PASS |
| Existing six ownership negatives | Expected rejection for retained CV workspace, isolated delegate and retained Vision workspace on both SDKs | Preserved |
| Scope/whitespace/preservation | `git diff --check` passes; only the three authorized files differ from entry | Preserved |
| Physical tracking / production performance | Not run or claimed; pure-core scope | Unvalidated |

Counts were extracted from actual xcresult summaries, with definitions distinguished from per-device parameter executions. Existing CP1/CP2, camera/preview, gameplay/rendering tests remain in full regression. Successful relevant compiler checks have no Swift/concurrency warnings/errors; the existing AppIntents metadata-extraction warning remains separate. No diagnostic suppression, unsafe sendability or project-wide setting change was used.

The working-directory path briefly became unavailable while launching an intermediate command. No edits ran in that failed command. After it was accessible again, branch/HEAD and baseline hashes were checked; no folder/branch/worktree change was performed by this task. Final verification ran on the preserved checkout. This was a tooling/access interruption, not an algorithmic passing result or an unresolved test gate.

New evidence: `/private/tmp/lh13b2a-frame-resolution/`:

- `BeforeFix.xcresult`, `before-tests.log`, `before-summary.json`: original/mirrored expected failures before core edits.
- `FocusedFinal.xcresult`, `focused-final.log`, `focused-summary.json`: final tracker run.
- `RegressionFinal.xcresult`, `regression-final.log`, `regression-summary.json`: final full run.
- `app-build.log`, `test-build.log`, `release-build.log`.
- `verify-strict.sh`, `strict.log`, `strict/{iphoneos,iphonesimulator}/`: exact flags/source lists, SIL/object/test logs and expected negative diagnostics.
- `same-frame-after.txt`, `original-after.txt` and corresponding scratch executables/compiler logs: unchanged audit scenes against corrected source.

Commands retain the §8/§13 project/scheme/destination and derived-data paths. Actual final sequence was app `build` → `build-for-testing` → focused `test-without-building` → full `test-without-building`, using the separate result bundles above. Release used `generic/platform=iOS Simulator` and `/private/tmp/lh13b2a/ReleaseDerived`. The isolated script ran complete checking with warnings-as-errors, project-equivalent flags, SIL/WMO and object/WMO on device and Simulator SDKs plus the existing six negatives. No repository Scripts file changed.

### 15.8 Remaining limits and B2b readiness

No remaining mandatory counterexample was found in the reviewed model, permanent test matrix or unchanged audit probes. This is not a proof of personal identity under every physical scene or every numerical tuning choice. Geometry/confidence thresholds remain synthetic-only; full torso acquisition is strict; duplicates and expired/incomparable evidence may interrupt continuity and require a new-generation rebind. No facial recognition, calibration, jump/sole/crown evidence, gameplay readiness or optical skeleton alignment is validated.

**READY FOR RE-REVIEW**, not ACCEPTED. A subsequent audit must review the universal competitor rule, bidirectional availability requirement, whole-frame commit and usability tradeoffs. B2b still needs separate authorization: one worker-local owner, exact B1 source/control adaptation, staged source-gated publication and no-frame lifecycle expiry, explicit versioned live policy and numeric-only diagnostics. Jevon retains game-phase/clock/binding-recovery orchestration; the tracker never creates a camera generation. Kevin's future same-source overlay remains separate. Do not begin live integration from these synthetic results.

### 15.9 Final Git boundary

Only PlayerTracker.swift, PlayerTrackerTests.swift and this report were changed in this correction. The existing architecture proposal, signing edit, untracked Scripts, CP1/CP2, camera, Vision, MotionEngine, diagnostics, renderer, gameplay, calibration and generated files are preserved by baseline hash comparison. Branch/HEAD remain unchanged. Nothing staged, committed, pushed, merged, reset, rebased or switched; no worktree created. Skills used: swift-concurrency and swift-testing-expert. **Stop for review.**
