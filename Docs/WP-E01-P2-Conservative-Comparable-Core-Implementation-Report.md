# WP-E01-P2 — Conservative Comparable-Core Implementation

7 November 2026 · Owner: Edo · **READY FOR INDEPENDENT ACCEPTANCE REVIEW**

## 1. Explicit authorization and source baseline

The Tech Lead's WP-E01-P2 instruction explicitly approves Option A from [the P1 decision proposal](WP-E01-Partial-Independence-Policy-Decision.md) for the B2a v1 **observational model**:

- Preserve the configurable three/four mutual-core requirement and corresponding anatomical pair.
- Preserve full-torso shape distinction and comparable proximity.
- Remove the below-coverage partial-translation fallback; insufficient mutual support is unavailable.
- Intentionally revise the two documented heuristic-positive test definitions.

This report records that authorization. P1, C1, C2 and earlier B2a reports retain their original proposed/review/history wording unchanged. B2a acceptance, production thresholds, B2b, physical acceptance, calibration, live CP1, avatar/gameplay integration, merge/push/PR remain outside this authorization.

| Item | Verified value |
|---|---|
| Worktree | `/Users/edwardgk/.codex/worktrees/player-tracker-independence/Sedactive` |
| Branch | `codex/wp-e01-c1-candidate-independence` |
| HEAD/base | `69860cc75d820c76c3ac45cfac09edce651892f7` |
| Entry tracker SHA-256 | `7f4e2fa39726998dc8da7b6853cf311b24f8edc40156d06c050f2a1ba5582731` |
| Entry tests SHA-256 | `4114037324ed2454b8ebaf162469eadde692d405aee43446bbffdc9fc950705e` |
| New persistent evidence directory | `/Users/edwardgk/LaserHeistReviewArtifacts/WP-E01-P2/run-2026-11-07-cmpcore/` |

Entry had the uncommitted C1/C2 source/test changes plus untracked C1, C2 and P1 documents. Implementation starts from those actual working-tree files. Read AGENTS/TEAM_ALIGNMENT, P1, C1/C2 reports, actual tracker/tests and B2 design; existing ownership/source contracts and pure-state architecture are preserved. Skills applied: swift-concurrency and swift-testing-expert.

## 2. Exact implementation change

Only `independence(_:_:)` and its explanatory comment change in production:

1. Retain `.distinct`, `.overlapping`, `.unavailable`.
2. Retain existing finite full-torso shape distinction. Both shapes require all four observed core joints, so this branch cannot create a sparse-coverage exception.
3. Retain `proximity`, including `minimumSharedCoreJoints` and the corresponding shoulder/hip pair requirement. Comparable distance above the existing separation gate is distinct; at/below is overlapping.
4. If comparison is unavailable, return `.unavailable` immediately. Remove C2's mean-direction/projection fallback completely.

No thresholds, weights, validation or fixture-policy defaults changed. The production prefix before the classifier and every method from acquisition onward are byte-identical to the entry source. `test-revision-map.json` records this check. Identity evidence, costs, hypotheses, candidate-pair proposal/resolution safeguards, recovery and source lifecycle were not rewritten.

This implements the approved observed-comparable boundary, not a certificate against every imaginable missing-joint completion or physical identity uncertainty.

## 3. Intentional test revisions mapped before editing

The two approved definitions were identified before production/test edits; their original scenes are retained:

| Existing definition | Authorized revision |
|---|---|
| `coherentPartialSeparationSupportsDifferentTranslationDirections` | Keep all four original directional scenes, method identifier and parameters. Since complementary missing hips leave two shared shoulders, now require uncertain/ambiguous, nil IDs, no unknown-only rebind, lastConfirmedAt=0.125, two confirmed/no provisional descriptors. A display name explains the new expectation. |
| `separatedPartialCoverageRemainsSupported` | Keep all sixteen ordered missing-core combinations inside the existing four parameter executions. The four same-missing combinations retain their positive identity/time assertions. The twelve complementary combinations now require ordinary uncertainty and frozen history because only two core joints are shared. |

The saved method-body comparison confirms **exactly these two pre-existing test bodies changed**, no existing method was removed, and seven definitions were added. No other existing expectation was changed or needed to be relaxed. The approval and old heuristic premise are recorded in test comments.

## 4. New deterministic coverage and actual behavior

All fixtures are synthetic immutable values with explicit original source times/context. No real camera/Vision fallback, new source contract or mock live behavior is introduced.

| Added definition | Coverage / actual passing assertions |
|---|---|
| `coherentShouldersCannotProveOppositeTorsoIndependence` | Exact P1 counterexample at 0.250 after binding at 0.000/0.125; complete-scene mirror, both array orders, three ID pairs including reused IDs. Both slots refuse without history advance or unknown-only permanent latch. |
| `restoredOppositeTorsoRetainsGlobalIdentityAmbiguity` | Restored missing hips, both directions/orders. Full observations admit contested identity permutations; existing lost/ambiguous/rebind behavior remains, with confirmed time 0.125. |
| `mutualCoreCoverageHonorsConfiguredThreeAndFour` | Floors three/four crossed with full/full, partial/full and same-missing partial/partial. At floor three comparable partials track. At floor four unsupported partials refuse; a separate valid full peer can still continue. |
| `comparablePartialSeparationSupportsDifferentTranslationDirections` | Four useful horizontal/diagonal positive scenes with the same missing hip in both candidates: three common joints, correct IDs, fresh confirmation and no rebind. |
| `droppingMutualSupportCannotCreateIndependentPair` | Four first-missing parameters, each checking three other deletions. Copy the exact same baseline; removing one joint from the full peer changes mutual support from three to two. Richer input tracks, poorer input refuses with frozen history. No coordinates/IDs/source metadata are otherwise changed. |
| `repeatedBelowCoverageFramesFreezeHistoryThroughExpiry` | Both directions; reordered/re-ID'd observations through existing expiry, no confirmed/provisional growth, no candidate resurrection after loss, at most 73 hypotheses. |
| `unavailablePairRecoversOnlyAfterComparablePartialDwell` | Both directions; initial sparse refusal, then adequate same-missing partial separation. First recovery observation stays provisional with confirmed time 0.125; only the dwell-confirmed frame advances to 0.500 with original slot identity. |

Seven new definitions produce **22 additional executions**. Inner fixture loops are not counted as extra executions.

### Latest policy example, now executed in Swift

The new fixture uses confidence 0.9 and canonical coordinates:

| Joint | Candidate 30 | Candidate 40 |
|---|---|---|
| leftShoulder | (0.49,0.60) | (0.41,0.60) |
| rightShoulder | (0.59,0.60) | (0.51,0.60) |
| leftHip | absent; restored control (0.42,0.40) | (0.50,0.40) |
| rightHip | (0.50,0.40) | absent; restored control (0.58,0.40) |

Partial observations produce **uncertain / ambiguous**, nil IDs, no immediate rebind and lastConfirmedAt=0.125 for both players. Restored full observations produce **lost / ambiguous**, nil IDs, rebind-required and the same frozen times because the existing global hypotheses contest identity. Unavailable evidence and supported identity ambiguity therefore retain distinct consequences.

## 5. Preserved safety and ownership

- Explicit atomic acquisition and mirrored-left/right binding are unchanged; later position or frame-local IDs do not rename slots.
- Global assignment remains injective, includes unmatched outcomes and all retained eligible competitors, and has at most 73 hypotheses for eight candidates.
- Lost/latched identities still participate through supported/excluded/unavailable evidence but cannot receive positive output. Unknown competitor evidence is not exclusion.
- Proposal and resolution checks still use the same immutable frame baseline; both outcomes resolve before the unchanged whole-frame commit. No sequential eligibility/history bypass is reintroduced.
- Refused, lost and tentative recovery outcomes cannot advance confirmed history. Existing dwell, prediction, expiry and monotonic latch rules remain.
- Source generation, epoch, geometry, dimensions/presentation, frame/time and control validation still precede state mutation. The tracker does not create camera generations or synthetic expiry frames.
- C1's independent acquisition inference-failure correction is unchanged and its regression passes.
- Two slots, two confirmed and one provisional descriptor per slot remain the persistent bounds. The removed fallback reduces pair-comparison work; no actor, Task, queue, timer, lock, raw resource or additional state is added.
- The core remains Foundation-only checked-Sendable value code. Public CP1/CP2, B1, camera/FrameStore, gameplay and rendering contracts remain unchanged.

All prior cross-slot, same-frame, opposing/complementary partial, duplicate, strong ambiguity, shape-crossing, unaffected-peer, malformed/stale/context/reset, recovery, overflow and long-sequence regressions are included in the fresh passing run.

## 6. Fresh verification results

Environment queried for this run: **Xcode 26.6 (17F113), Swift 6.3.3, iOS/Simulator SDK 26.5**. Available destinations were inspected; selected booted Simulator: iPad mini (A17 Pro), iOS 26.5 (23F77), UUID `1E1C6B07-B356-4303-8756-4C0D2A4CDF05`.

| Gate | Fresh P2 result |
|---|---|
| Debug Simulator app/test-target build | PASS (`build-for-testing`) |
| Focused PlayerTracker tests | **95 definitions / 187 executions**, zero failures/skips |
| Complete Simulator regression on this branch base | **317 definitions / 504 executions**, zero failures/skips |
| Release Simulator app build | PASS |
| Generic iOS SDK app build | PASS, unsigned command-only `CODE_SIGNING_ALLOWED=NO` |
| Complete warnings-as-errors strict compiler gates | PASS on both SDKs: production SIL/WMO, object/WMO, testable module and Shared test SIL/WMO |
| Six ownership negatives | Expected rejection: retained mutable CV workspace, retained mutable Vision workspace and isolated delegate conformance, each on both SDKs |
| Source/test scope and whitespace | PASS; exactly the approved existing test revisions; `git diff --check` clean |
| Physical accuracy / live integration | Outside this pure-core verification; no physical deployment/run performed |

Counts come from reopened xcresult summaries: top-level definitions versus device/parameter executions. C2's prior 88/165 and 310/482 are comparison history only; no successful C2 result is reused as proof for the new implementation. New P2 DerivedData/result bundles and fresh compiler outputs/logs are used. Newer staging-only tests absent from this base are not claimed.

The strict harness/probe sources are copied from the retained C2 harness, while all compilation and negative outcomes are newly executed under the P2 directory. Exact argument arrays retain Swift 5, default MainActor, applicable approachable/upcoming features, complete checking, warnings-as-errors and current-worktree source paths. The positive probe invokes the actual nonisolated production capture delegate. Negative controls fail for intended data-race/actor-conformance diagnostics rather than import or syntax errors. No unsafe suppression or project setting change is introduced.

App builds retain the existing AppIntents metadata-extraction warning; isolated strict positive gates have no relevant Swift/concurrency diagnostic. Simulator host/RealityKit output is not visual or physical evidence.

## 7. Persistent evidence and reproducibility

**`/Users/edwardgk/LaserHeistReviewArtifacts/WP-E01-P2/run-2026-11-07-cmpcore/`** was newly created and checked empty before baseline capture. It is outside Git and system temporary directories. Earlier C1/C2/P1 evidence is preserved.

The initial directory-preparation tool request did not execute because automatic approval review timed out. A smaller retry succeeded. This was an approval-service timeout, not a safety rejection or a compiler/test failure; subsequent evidence creation and verification completed.

Retained evidence:

- `baseline/`: entry working-tree and primary hashes/status, source/tests/policy snapshots and full entry diff.
- `environment.log`, `debug-test-build.log`, `release-build.log`, `ios-sdk-build.log`.
- `Focused.xcresult`, `focused.log`, `focused-summary.json`.
- `Regression.xcresult`, `regression.log`, `regression-summary.json`.
- `verify-strict.py`, `strict.log`, `strict-results.json`, `strict/{iphoneos,iphonesimulator}/`: exact commands, compiler outputs and six intended negative diagnostics.
- `test-revision-map.json`, `PlayerTracker.swift.p2.diff`, `PlayerTrackerTests.swift.p2.diff`: incremental P2 changes over the actual uncommitted C2 baseline.
- `final-source-hashes.json`, `final/`, `final-git-status.txt`, `final-head.diff`, `preservation.json`, `artifact-reopen.json`, `artifact-manifest.json`.

The final evidence check reopens both new result bundles with `xcresulttool get test-results summary`, checks counts against exports, verifies source snapshots and reads/hashes every manifest-listed artifact. Regenerable DerivedData/module caches and the manifest itself are excluded from the manifest; explicit result bundles, logs, compiler outputs, commands and source snapshots are retained. Accessibility is verified at task completion, not guaranteed against later external deletion.

Main commands, executed from this worktree with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:

```bash
p2_artifacts=/Users/edwardgk/LaserHeistReviewArtifacts/WP-E01-P2/run-2026-11-07-cmpcore
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath "$p2_artifacts/Derived" \
  SWIFT_STRICT_CONCURRENCY=complete build-for-testing
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -parallel-testing-enabled NO -derivedDataPath "$p2_artifacts/Derived" \
  -resultBundlePath "$p2_artifacts/Focused.xcresult" \
  -only-testing:SedactiveTests/PlayerTrackerTests test-without-building
# Full regression: same command without -only-testing, using Regression.xcresult.
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive -configuration Release \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$p2_artifacts/ReleaseDerived" \
  SWIFT_STRICT_CONCURRENCY=complete build
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'generic/platform=iOS' -derivedDataPath "$p2_artifacts/DeviceDerived" \
  CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=complete build
python3 "$p2_artifacts/verify-strict.py"
git diff --check
```

These result paths already exist. Use a fresh directory for another run rather than overwrite this evidence.

## 8. Final source hashes, limitations and reviewer action

| Source | Final SHA-256 |
|---|---|
| `PlayerTracker.swift` | `4cc0a4a648e7250910303826bd5a3a14d27efea023d4f9ff861f094eff01fd34` |
| `PlayerTrackerTests.swift` | `906defbadd128ff938700367c6f829a06958bd52e5c28df761a3a007a13e8a75` |

The approved model may refuse visibly separated people when their missing joints are complementary. Persistent refusal can reach existing expiry/lost/rebind behavior. Sufficiently comparable partials and an independently justified healthy peer can continue, as the passing controls assert. This is not a full-body completion certificate, personal identity proof, calibrated measurement, production threshold or physical-performance approval.

Independent acceptance review should verify: exact Option A classification with no below-floor exception; approved versus protected expectation changes; the new executable coherent-shoulder/restored-torso controls; lost/latched competition and same-frame history invariants; fresh artifact/hash correspondence. B2b remains separately authorized and must preserve one worker/tracker, exact source/control adaptation, source-gated commits and immediate lifecycle/no-frame invalidation, with explicit binding/rebind authority and physical characterization.

**READY FOR INDEPENDENT ACCEPTANCE REVIEW.** B2a is not marked ACCEPTED by this implementation task.

## 9. Exact file changes and Git preservation

P2 changes only:

1. `Sedactive/Shared/BodyTracking/Processing/PlayerTracker.swift`.
2. `SedactiveTests/Shared/BodyTrackingTests/PlayerTrackerTests.swift`.
3. New `Docs/WP-E01-P2-Conservative-Comparable-Core-Implementation-Report.md`.

All other entry working-tree files, including untracked C1/C2/P1 documents, remain hash-identical. The primary architecture checkout's 319 entry files and file set remain unchanged, including existing untracked Scripts. No signing/project, generated package, contract, camera, Vision, renderer or gameplay file is changed.

Final status on the unchanged corrective branch/HEAD:

```text
 M Sedactive/Shared/BodyTracking/Processing/PlayerTracker.swift
 M SedactiveTests/Shared/BodyTrackingTests/PlayerTrackerTests.swift
?? Docs/WP-E01-C1-Candidate-Independence-Correction-Report.md
?? Docs/WP-E01-C2-Opposing-Displacement-Correction-Report.md
?? Docs/WP-E01-P2-Conservative-Comparable-Core-Implementation-Report.md
?? Docs/WP-E01-Partial-Independence-Policy-Decision.md
```

Nothing staged, committed, pushed, merged, reset, cleaned, switched or submitted as a PR. No additional branch/worktree or B2b implementation is created.
