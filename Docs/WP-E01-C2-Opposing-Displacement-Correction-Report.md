# WP-E01-C2 — Opposing-Displacement Candidate Independence Correction

7 November 2026 · Owner: Edo · **READY FOR INDEPENDENT RE-REVIEW**

The opposing-displacement defect was reproduced by Swift Testing against unchanged C1 production source, then corrected within the pure B2a tracker. This is not B2a acceptance, B2b authorization, physical tracking validation or production policy approval. The C1 report and earlier B2a correction history remain unchanged.

## 1. Exact baseline and scope

| Item | Verified value |
|---|---|
| Corrective worktree | `/Users/edwardgk/.codex/worktrees/player-tracker-independence/Sedactive` |
| Branch | `codex/wp-e01-c1-candidate-independence` |
| HEAD/base | `69860cc75d820c76c3ac45cfac09edce651892f7` |
| Entry production SHA-256 | `284ff53bc9657a7c5f2176d10f64111b97b9f7ab1f192f4fa3275a12034a2c2b` |
| Entry test SHA-256 | `09e55bb1436bfe30d389e8db692d836a337fff1fd67ef1bef90af12a31001b54` |
| Preserved C1 report SHA-256 | `9fcb8a814fb3f0bb216aa6033dafd01a613c8c6e4665bd972f0b2ba2f86b3080` |
| Persistent evidence root | `/Users/edwardgk/LaserHeistReviewArtifacts/WP-E01-C2/run-2026-11-07-c896afb7/` |

C1 was already uncommitted: two modified Swift files and its untracked report. C2 builds on those actual files, not an older HEAD copy. Full entry diffs, source snapshots and file hashes are retained under `baseline/`. No fetch, checkout, branch creation, worktree creation, reset or merge occurred.

Read AGENTS/TEAM_ALIGNMENT, lean architecture, B2 architecture and correction history, actual tracker/tests, C1 report, the independent review, and B1/CP1 source/identity contracts. Skills applied: swift-concurrency and swift-testing-expert.

## 2. Actual failing-before reproduction

`opposingPartialDisplacementsCannotConfirmIndependentBodies(_:)` uses the unchanged default `TrackingFixtures.policy()` and 1280×720 context. Full candidates at X=0.55/0.45 acquire at frames 1–2, capturedAt 0.000/0.125 seconds.

Frame 3, capturedAt 0.250, confidence 0.9 for every present joint:

| Joint | Candidate 30 | Candidate 40 |
|---|---|---|
| leftShoulder | (0.36, 0.60) | (0.44, 0.60) |
| rightShoulder | (0.64, 0.60) | (0.56, 0.60) |
| leftHip | absent | (0.41, 0.40) |
| rightHip | (0.59, 0.40) | absent |

The mirrored execution reflects X in both acquisition anchors and current observations, preserving anatomical labels. This is a geometric symmetry fixture, not a change to source mirroring or binding policy.

Before editing production code, the exact suite actually executed on the Simulator:

**`BeforeFixExactBooted.xcresult`: 82 definitions, 81 passed / 1 failed; 149 executions, 147 passed / 2 failed; zero skips.**

Both parameter executions failed for the intended reason. Both slots returned tracking, non-nil candidates, `lastConfirmedAt=0.250` instead of 0.125, and four confirmed descriptors instead of two. Eighteen assertion issues were recorded. The restored-hip control passed in both directions. The production hash remained the entry C1 hash above throughout this reproduction.

The first attempt (`BeforeFix.xcresult`) also reproduced the original-direction unsafe output, but had an additional mirror-fixture error: it reflected observations without reflecting acquisition anchors. That test-only setup was corrected before the definitive run; it was not a policy or production change. `BeforeFixExact.xcresult` and `BeforeFixExactRetry.xcresult` then encountered Simulator Busy/application-preflight failures before tests ran. The selected Simulator was booted without erasure, and the definitive run above executed. All attempts remain separate; launch failures are not algorithm evidence.

## 3. Why C1 remained insufficient

Candidate-to-anchor costs and reverse identity evidence were available, but neither proved current candidate-to-candidate independence. The two shared shoulders had aspect-corrected displacement magnitudes approximately 0.142222, both above separation=0.12, while their vectors opposed and canceled.

C1's partial fallback tested only each vector's magnitude. It classified the pair as distinct; the unique global assignment and existing resolve checks consequently permitted dual confirmation. The earlier evaluate/resolve/commit correction was structurally intact but was consuming an unsound distinct-body predicate.

Restoring candidate 30's leftHip=(0.51,0.40) and candidate 40's rightHip=(0.49,0.40) produces equal full-torso scales and proximity approximately 0.088889. The existing full-support policy calls this overlapping. Removing those hips must not turn the same ambiguous scene into confident independent bodies merely because individual shoulder vectors are large.

## 4. Minimal production correction

Only the insufficient-mutual-support fallback inside `independence(_:_:)` changes. Full-torso shape distinction and comparable `proximity` behavior are unchanged.

Let each shared, aspect-corrected anatomical displacement be `d[j]`, its mean be `m`, and the existing separation gate be `s`:

```text
m = mean(d[j])
require finite |m| > s
u = m / |m|
require dot(d[j], u) > s for EVERY shared joint
otherwise: unavailable
```

This asks for a common direction along which every shared anatomical displacement supports separation. Opposing vectors cannot justify one another, exact or near cancellation fails, and one large vector cannot conceal another weak/orthogonal projection. Merely exceeding the gate with the mean magnitude is insufficient.

No new angular, confidence, distance or temporal threshold is introduced. The existing `minimumPairSeparation` retains image-height units. All input coordinates and anatomical labels remain unchanged. No joint is synthesized, and candidate IDs do not enter the metric.

### Correctness and symmetry properties

- Every accepted projection is bounded above by its vector's magnitude. Therefore C2's fallback distinct set is a subset of C1's; it cannot promote a formerly unknown pair by this change.
- All shared displacements must support the same directed separation axis. Magnitude-only opposing evidence no longer suffices.
- Swapping candidates reverses both the mean direction and displacements, leaving projections unchanged. Horizontal reflection likewise preserves dot products. Core joints are traversed in fixed anatomical order, not dictionary iteration order.
- Insufficient or inconsistent support remains **unavailable**, not positively labeled duplicate. Ordinary unknown-only uncertainty does not automatically latch permanent rebind.
- Supported overlap and existing identity competition failures retain their prior stronger latch/loss behavior.

This is bounded geometric evidence under an experimental model, not biometric proof of two physical identities. It does not promise consistency under every imaginable unobserved joint completion or faulty Vision observation.

## 5. Same-frame safety, history and bounds

All existing call sites still consume the same three-state classifier: supported alternative checks during evaluation, proposed-pair checks during resolution, and distinct-body explanations for retained competing identities. The cost matrix, plausible hypotheses, reverse-evidence checks, recipient eligibility and confirmed/recovered/refused helpers are unchanged from C1.

Both proposals and resolved outcomes are computed before either slot commits. Refused and tentative outcomes retain confirmed descriptors and timestamps. Lost/latched identities remain competition evidence but cannot receive positive output. Source generation/epoch/geometry/dimensions/orientation/time/control validation remains before state mutation.

Persistent state remains two slots, at most two confirmed and one provisional descriptor per slot. Eight current candidates and at most 73 hypotheses remain the limits. Each pair comparison traverses at most four fixed anatomical points; the fallback adds a mean/projection calculation, not history or iteration over time. No Task, actor, timer, lock, queue, raw image or framework owner is added. Stream-length-independent computation/state bounds are preserved.

## 6. Before/after behavior

| Property in exact frame 3 | C1 before | C2 after |
|---|---|---|
| Partial opposing pair, either direction | both tracking | both uncertain / ambiguous |
| Current candidate IDs | 30/40, slot order reflected in mirror | nil / nil |
| Last confirmed capture times | 0.250 / 0.250 | **0.125 / 0.125** |
| Confirmed / provisional descriptors | 4 / 0 | **2 / 0** |
| Immediate rebind for unknown-only partial evidence | false | **false** |
| Restored-hip overlap control | uncertain, latched | same supported refusal |
| Later adequate separation | not a remedy for prior unsafe history | original recovery dwell required; no tentative history advance |

Repeated opposing observations cannot improve the confirmed anchors. They remain refused through the existing prediction/recovery expiry and eventually lost. A lost slot cannot automatically recover. Fresh, uniquely supported separation inside the allowed horizon can recover only after the existing capture-time dwell.

## 7. Permanent test matrix

C2 adds eight definitions / twenty executions. Parameter loops inside a test are not counted as extra executions. No pre-existing C1/B2a test, fixture default or assertion was weakened or deleted.

| New test | Evidence |
|---|---|
| `opposingPartialDisplacementsCannotConfirmIndependentBodies` | Exact original and full-scene mirror; actual failing-before proof and history freeze |
| `restoringOpposingFixtureHipsRetainsSupportedOverlap` | Missing-evidence companion control, both directions |
| `opposingPairsAreInvariantUnderCandidateOrderAndLocalIDs` | Mirrored scenes, both array orders, three ID pairs including reused IDs |
| `coherentPartialSeparationSupportsDifferentTranslationDirections` | Horizontal and diagonal common translations, changed IDs/order; useful partial continuation |
| `incompleteCancellationCannotBecomeIndependentTranslation` | Four finite unequal opposing-displacement variants; no coordinate-specific exception |
| `largeMeanDisplacementStillNeedsSupportFromEverySharedJoint` | Both vertical signs: mean magnitude can exceed the gate while a shared shoulder has insufficient projection |
| `repeatedOpposingObservationsFreezeHistoryThroughExpiration` | Reordered/re-ID'd repeated frames, nil output, frozen history, finite state, eventual loss |
| `opposingUncertaintyRecoversOnlyAfterSupportedSeparationAndDwell` | Both directions: provisional-only recovery, then correct original identity after dwell |

The final run also includes C1's complementary partials, all sixteen missing-core positive combinations, same-missing-hip/full duplicate controls, one-near/one-far support, full-torso shape-distinguishable crossings, unaffected independent peer, expiry/reset/overflow, and earlier cross-slot and same-frame regressions. Original long deterministic bounded-state sequences remain passing.

## 8. Actual verification

Environment: Xcode **26.6 (17F113)**, Swift **6.3.3**, iOS and Simulator SDK **26.5**. Available Simulator destinations were queried before selecting iPad mini (A17 Pro), iOS 26.5 (23F77), UUID `1E1C6B07-B356-4303-8756-4C0D2A4CDF05`. Physical device deployment or tracking was not performed.

| Gate | Actual C2 result |
|---|---|
| Exact regression before production change | FAIL as required: 81 passed / 1 failed definitions; 147 passed / 2 failed executions |
| Focused PlayerTracker suite | **88 definitions / 165 executions**, zero failures/skips |
| Full Simulator regression on this base | **310 definitions / 482 executions**, zero failures/skips |
| Debug Simulator app/test-target build | PASS, `build-for-testing` |
| Release Simulator app build | PASS |
| Generic iOS SDK app build | PASS, unsigned command-only `CODE_SIGNING_ALLOWED=NO`; not device execution |
| Complete warnings-as-errors concurrency | PASS on both SDKs: production SIL/WMO, object/WMO, testable module and Shared test SIL/WMO |
| Ownership negatives | Six expected compiler rejections, three per SDK |
| Whitespace/scope/preservation | `git diff --check` clean; primary's 319 baseline files unchanged |

The final full count is C1's reported 302/462 plus C2's actual eight/twenty additions. C1's deleted temporary bundles were not recovered or falsely revalidated; these are fresh C2 results. No newer staging-only tests absent from this branch are claimed.

`verify-strict.py` retains exact argument arrays and anchors source reads to this worktree. It preserves Swift 5, default MainActor, applicable approachable/upcoming features, complete checking and warnings-as-errors. It compiles the Shared production sources plus existing diagnostic composition, with an explicit nonisolated production delegate callback probe; Shared tests include tracker, CP1/CP2, camera, preview and B1 tests. The first external harness attempt lacked Swift Testing search paths; `strict-attempt1/` and its log remain. The corrected harness uses the test-framework/plugin paths from Xcode's actual invocation and passes without source or setting suppressions.

The old temporary negative files were unavailable. `probes/` recreates the same three meaningful scenarios: retained mutable CV workspace after sending, retained mutable Vision workspace after sending, and MainActor-isolated delegate conformance installed from nonisolated code. All six SDK executions reject for the intended data-race/actor-isolation diagnostics, not import failures. These are fresh equivalent controls, not a claim of byte-identical recovery of old files.

App builds retain the existing AppIntents metadata-extraction warning. No warning was suppressed. Simulator hosting/RealityKit diagnostic output is not visual or physical validation.

## 9. Persistent commands and evidence

Evidence root: **`/Users/edwardgk/LaserHeistReviewArtifacts/WP-E01-C2/run-2026-11-07-c896afb7/`**. It is outside the repository and outside system temporary directories. No earlier evidence directory was overwritten.

Important artifacts:

- `baseline/`: C1 source/tests/report, entry diff/status/file hashes and exact pre-fix C2 tests.
- `BeforeFixExactBooted.xcresult`, `before-exact-booted-tests.log`, `before-exact-summary.json`: definitive pre-fix failure.
- `Focused.xcresult`, `focused.log`, `focused-summary.json`: final focused result.
- `Regression.xcresult`, `regression.log`, `regression-summary.json`: final full regression.
- `final-debug-build.log`, `release-build.log`, `ios-sdk-build.log`, `environment.log`.
- `verify-strict.py`, `strict.log`, `strict-results.json`, `strict/{iphoneos,iphonesimulator}/`: exact commands, SIL/object/module outputs, test and negative diagnostics.
- `PlayerTracker.swift.c2.diff`, `PlayerTrackerTests.swift.c2.diff`: incremental changes over uncommitted C1, not only HEAD.
- `final-source-hashes.json`, `preservation.json`, `artifact-manifest.json`, `artifact-reopen.json`, `final/`: final source evidence and readability checks.

Main commands, from this worktree:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
c2_artifacts=/Users/edwardgk/LaserHeistReviewArtifacts/WP-E01-C2/run-2026-11-07-c896afb7
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath "$c2_artifacts/Derived" \
  SWIFT_STRICT_CONCURRENCY=complete build-for-testing
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -parallel-testing-enabled NO -derivedDataPath "$c2_artifacts/Derived" \
  -resultBundlePath "$c2_artifacts/Focused.xcresult" \
  -only-testing:SedactiveTests/PlayerTrackerTests test-without-building
# Full regression: same command without -only-testing, separate Regression.xcresult.
# Pre-fix: same focused command on unchanged C1, separate BeforeFixExactBooted.xcresult.
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive -configuration Release \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$c2_artifacts/ReleaseDerived" \
  SWIFT_STRICT_CONCURRENCY=complete build
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'generic/platform=iOS' -derivedDataPath "$c2_artifacts/DeviceDerived" \
  CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=complete build
python3 "$c2_artifacts/verify-strict.py"
git diff --check
```

Result bundle paths above already exist; do not overwrite them on rerun. The final readability check reopens all three definitive bundles with `xcresulttool get test-results summary`, compares their exports and reads/hashes retained evidence. The manifest excludes regenerable Derived/module-cache directories and itself; explicit result bundles, compiler outputs/logs, commands and source snapshots are retained. Accessibility is verified at task completion, not guaranteed against later external deletion.

## 10. Final source hashes, limitations and disposition

| File | Final SHA-256 |
|---|---|
| `PlayerTracker.swift` | `7f4e2fa39726998dc8da7b6853cf311b24f8edc40156d06c050f2a1ba5582731` |
| `PlayerTrackerTests.swift` | `4114037324ed2454b8ebaf162469eadde692d405aee43446bbffdc9fc950705e` |

Conservative projection checks can refuse rotating/distorted partial observations that lack a sufficiently supported common translation. That is uncertainty, not proof of duplicate bodies. Existing stronger ambiguity, expired-competitor and lost/rebind policies can still interrupt continuity. Full torso acquisition and all numerical values remain experimental; there is no physical accuracy, latency, throughput, universal identity guarantee or production-threshold approval.

Independent reviewers should examine the shared-direction predicate, cancellation and large-mean negative fixtures, shape-crossing preservation, ordinary uncertainty versus monotonic latch, immutable whole-frame commit, and retained evidence/source hashes. B2b still requires separately approved one-worker ownership, exact B1/control adaptation, source-gated commits, no-frame/lifecycle invalidation, binding/rebind/new-generation authority with Jevon, versioned live policy and physical characterization. No camera generation is manufactured by this tracker.

**READY FOR INDEPENDENT RE-REVIEW.** No automatic acceptance, B2b, calibration, live CP1, gameplay, avatar or overlay work follows.

## 11. Changed files and preservation

C2 changes only `Sedactive/Shared/BodyTracking/Processing/PlayerTracker.swift`, `SedactiveTests/Shared/BodyTrackingTests/PlayerTrackerTests.swift`, and this new report. The C1 report is retained byte-for-byte. No other pre-existing corrective-worktree file changes. The primary architecture checkout's 319 baseline files and file set are unchanged, including untracked Scripts. Architecture V2, Avatar-01, workplan, camera, Vision, CP1/CP2, renderer, gameplay, signing and generated resources remain untouched.

Final corrective Git status consists of the two modified Swift files, existing untracked C1 report, and new untracked C2 report. Nothing staged, committed, pushed, merged, reset, cleaned or submitted as a PR. Branch and HEAD remain unchanged.
