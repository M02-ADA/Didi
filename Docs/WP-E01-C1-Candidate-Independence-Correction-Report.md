# WP-E01-C1 — B2a Candidate Independence Correction

6 November 2026 · Owner: Edo · **READY FOR INDEPENDENT RE-REVIEW — pure B2a only.**

The complementary-partial counterexample is reproduced by Swift Testing and corrected. The acquisition-stage inference-failure diagnostic is separately reproduced and corrected. Existing identity-competition and frame-atomic corrections remain passing. This report does not accept B2a, authorize B2b, select production thresholds or claim physical tracking accuracy.

## 1. Source baseline, isolation and scope

| Item | Actual value |
|---|---|
| Reviewed/current available tracking ref | `origin/feat/player-tracking` and local `feat/player-tracking`: `69860cc75d820c76c3ac45cfac09edce651892f7` |
| Corrective branch | `codex/wp-e01-c1-candidate-independence` |
| Base/current corrective HEAD | `69860cc75d820c76c3ac45cfac09edce651892f7`; changes remain uncommitted |
| Corrective worktree | `/Users/edwardgk/.codex/worktrees/player-tracker-independence/Sedactive` |
| Preserved primary checkout | `/Users/edwardgk/Desktop/APPLE/Sedactive`, `feat/architecture` at `7cab6121eea5351b3b2a51256c9d433cb2d497dd` |
| Primary local work | Existing untracked `Scripts/CP2Spike/`; architecture documents already committed at entry |
| Evidence directory | `/private/tmp/wp-e01-c1.laFm6V/` |

The available tracking ref had not advanced beyond the audited implementation; no fetch or new remote-server freshness claim. The app-managed worktree was created at that exact commit, then the dedicated corrective branch was created there. The primary branch was never switched or edited. Initial sandbox restrictions on branch-ref creation and Simulator service access were resolved through authorized escalated tool execution; no project/signing workaround was used.

Read AGENTS/TEAM_ALIGNMENT (identical in both checkouts), lean architecture, B2 design, B2a implementation/correction history, the independent WP-E01 review in the conversation, B1 source/result envelopes and CP1 identity/provenance types. The old B2a report and architecture proposal are preserved unchanged. Architecture V2, Avatar-01 and Technical Workplan in the primary checkout are untouched.

## 2. Exact changed files

| Repository-relative file | Change |
|---|---|
| `Sedactive/Shared/BodyTracking/Processing/PlayerTracker.swift` | Private three-state candidate-independence evidence, proposal/resolve guards, independent unbound failure-reason fix |
| `SedactiveTests/Shared/BodyTrackingTests/PlayerTrackerTests.swift` | 12 added definitions / 25 additional executions; existing fixtures, defaults, tests and assertions retained |
| `Docs/WP-E01-C1-Candidate-Independence-Correction-Report.md` | This focused verification report |

No B1/CP1/CP2, camera, FrameStore, MotionEngine, calibration, gameplay, renderer, asset, target, package, project or signing file changed. No new public contract, actor, queue, Task or raw resource ownership was introduced.

## 3. Reproduction before production edits

Added `complementaryPartialCandidatesCannotProveIndependentBodies(_:)`, parameterized over both P1/P2 directions, using unchanged `TrackingFixtures.policy()`:

1. Frame 1, 0.000 s: full torso ID 10 at X=0.55 and ID 20 at X=0.45.
2. Frame 2, 0.125 s: same pair; explicit armed acquisition completes.
3. Frame 3, 0.250 s: ID 30 at X=0.51 missing leftHip, ID 40 at X=0.49 missing rightHip. Mirror variant reverses the X centers; source geometry/joint construction/default policy stay unchanged.

Assertions require both unsafe outputs to be uncertain/nil and retain lastConfirmedAt=0.125, with two confirmed descriptors and no provisional recovery descriptors. Also added the independent acquisition-failure diagnostic test before core edits.

The pre-fix core Git blob was still **`8cf19c1218b3ef33e8ac33962d6e8b8d5c6dbc19`**, identical to HEAD. Its SHA-256 is `7bd5be8a2510757e21e31762e256c709522dfe84ee20459fc6cbc058d55be793`; saved as `PlayerTracker.before.swift` alongside the pre-fix tests.

**Actually executed pre-fix result:** `BeforeFixSuite.xcresult`: **70 definitions: 68 passed / 2 failed; 123 executions: 120 passed / 3 failed; zero skips.**

- Both complementary-partial parameter executions failed: tracking instead of uncertain, candidate IDs 30/40 (40/30 in mirror), lastConfirmedAt **0.250**, and advanced confirmed history. Fourteen assertion issues across those two executions.
- Acquisition failure retained `.acquiring` instead of `.inferenceFailed`, two assertion issues in its one execution.
- The original 68 definitions / 120 executions passed against the unchanged core.

An initial function-only filter selected zero Swift Testing tests (`BeforeFix.xcresult`). It is explicitly **not reproduction evidence**; the subsequent whole-suite run above is the failing proof. No arithmetic prediction is substituted for execution.

## 4. Root cause

Each current partial descriptor can compare with a full confirmed anchor using three shared core joints. However, complementary partial candidates share only two joints with each other, so the old `proximity` returns nil.

The old duplicate guard used `proximity(...).map { ... } ?? false`: unknown became nonduplicate. Global assignment then favored P1→30/P2→40. Reverse identity edges were available, but they compared anchors with candidates; they did not prove the two current detections were independent bodies. Distinct candidate indices were sufficient for the old separate-body explanation, allowing confirmed-history advancement.

The same-frame evaluate/resolve/commit mechanism itself was present and is retained. Its decision predicates needed current candidate-pair evidence in addition to injectivity and cross-slot identity evidence.

## 5. Narrow correction and evidence semantics

`CandidateIndependence` is a private transient enum: **distinct**, **overlapping**, **unavailable**. `independence(_:_:)` uses only immutable current descriptors and existing policy gates:

| Evidence | Classification / behavior |
|---|---|
| Two full torso shapes differ beyond existing `maximumLogScaleChange` | Distinct under the same experimental geometric-exclusion model; retains already-supported shape-distinguishable crossings |
| Sufficient common support for existing `proximity` | Distance above `minimumPairSeparation` is distinct; at/below is supported overlapping/duplicate ambiguity |
| Insufficient common support, but **every shared anatomical point** is beyond the existing separation gate | Distinct spatial evidence; preserves clearly separated complementary partial torsos |
| Insufficient/close/inconsistent mutual support | Unavailable; never default distinct or positively labeled duplicate |

Each descriptor has at least three of four core joints, so any two have at least two common anatomical points. The partial fallback does not invent joints, compute a favorable missing residual or lower the identity-association coverage gate. One far shared point cannot establish separation when another remains close. Shape evidence is not personal identity recognition; history, source, assignment and competition checks still apply.

No policy declarations, validation, thresholds or test helper defaults changed. In particular, the counterexample still uses minimumSharedCoreJoints=3, separation=0.12, unmatchedCost=2 and assignmentMargin=0.15.

### Evaluate → resolve → commit

1. **Evaluate:** existing source validation, immutable baseline/evidence/hypotheses and bounded assignment remain. A supported alternative current candidate with overlapping pair evidence causes the existing latched refusal. Unavailable pair evidence causes ordinary uncertainty, rather than guessed independence or automatic permanent loss.
2. **Resolve:** two proposed positive outputs must have distinct current-pair evidence, including when their cross-anchor identity edges are excluded. Every separate-body explanation used for a supported competing identity must also establish current-pair distinction, in addition to the existing distinct-index/reverse-availability checks. All plausible hypotheses are inspected; a stronger existing identity/exclusion failure still latches rebind even if another check is merely unknown.
3. **Commit:** only resolved safe matches call the unchanged confirmation/recovery helpers. Both final slot values still derive from the same baseline and commit once. Unknown/refused/tentative decisions cannot advance confirmed descriptors/timestamps.

The predicates read immutable proposals/evidence, not a progressively updated peer slot. No fixed-point procedure or slot-order dependency is added. Lost/latched identities still cannot receive positive output and still participate in identity competition. Their unavailable/expired evidence remains distinct from exclusion.

### Resulting original/mirrored outcome

| Frame 3 property | Before fix | Corrected |
|---|---|---|
| Both player states | tracking | uncertain / ambiguous |
| Current candidate IDs | 30/40, reversed in mirror | nil / nil |
| Last confirmed times | 0.250 / 0.250 | **0.125 / 0.125** |
| Confirmed descriptor count | 4 | **2** |
| Provisional descriptor count | 0 | **0** |
| Immediate requiresRebind for unknown-only pair evidence | false | **false**, not a blanket permanent-loss workaround |

Later supported separation can recover only through the existing multi-observation dwell while the anchors remain compatible/fresh enough. Repeated unresolved observations cannot confirm; original prediction/recovery expiry and lost/rebind rules still apply. Proven duplicate/identity ambiguity retains its monotonic latch. These are conservative model decisions, not physical identity guarantees.

### Preserved positive crossing and intermediate verification

An initial spatial-only correction passed the new regressions but over-refused the existing `differentTorsoGeometryCanDisambiguateCrossing` test. The intermediate `Focused.xcresult` retains that failure; no old assertion was weakened. The final pair classifier retains the existing full-torso shape-exclusion gate before interpreting coincident centers, and adds a mirrored same-center/different-shape control. Original distinguishable-crossing tests and new controls pass on final source. This is preservation of existing geometric evidence, not numerical tuning to hide the reported defect.

## 6. Independent diagnostic correction

`inferenceFailureDuringAcquisitionReportsFailureAndClearsDwell` reproduced `.acquiring` after failure. `refused` already cleared candidate/provisional values but returned early for unbound state before updating its reason.

The narrow change sets the requested reason for an unbound refusal, then returns without changing binding/state/history. Lost-state handling remains unchanged. The regression verifies unbound/no current candidate/no confirmed history, cleared acquisition dwell, correct failure reason and a fresh two-observation acquisition afterward. This correction does not participate in pair-independence scoring or resolution.

## 7. Permanent regression matrix

All original tests remain, including §12/§13 cross-slot competition, §14/§15 same-frame correction, lost/expired/incomparable evidence, matched/unmatched costs, overflow, control reset and long sequences.

| New test | Coverage |
|---|---|
| `complementaryPartialCandidatesCannotProveIndependentBodies` | Exact default-policy original/mirror failing-before case, history freeze |
| `partialPairEvidenceIsPermutationAndIDInvariant` | Both input orders, mirrored slots and three ID pairs including reused frame-local IDs; 12 sequence checks inside two executions |
| `comparableNearCandidatesRetainDuplicateLatch` | Full support and same-missing-left/right-hip controls; known ambiguity stays latched after separation |
| `separatedPartialCoverageRemainsSupported` | All 16 ordered one-missing-core combinations, including diagonal shared support, with changed order/IDs; no blanket partial refusal |
| `unknownPartialCoverageDoesNotLatchOrConfirm` | All 12 complementary missing-core combinations; unknown-only uncertainty, nil current IDs and frozen history |
| `oneSeparatedSharedJointCannotProvePartialBodiesDistinct` | Mixed partial support: one distant shared shoulder cannot conceal another close one |
| `fullTorsoShapeExclusionPreservesIndependentOverlap` | Mirrored different-shape positive control at the same center |
| `unknownPairAllowsDwellRecoveryOnlyAfterSeparation` | No tentative confirmation; later adequate separation requires original recovery dwell |
| `independentPlayerSurvivesComplementaryPartialCompetition` | Either affected slot refuses while the separate peer tracks; distant extra candidate harmless |
| `repeatedUnknownPairsFreezeHistoryAndCannotResurrect` | Reordered/re-ID'd observations through expiry; no unsafe history advancement or lost-slot resurrection |
| `unknownPairResetRequiresOriginalControlAndNewGeneration` | Reset clears histories; delayed old control rejected; new real-source authorization arms fresh pair |
| `inferenceFailureDuringAcquisitionReportsFailureAndClearsDwell` | Separate low-severity diagnostic reproduction/fix |

Looped fixture combinations are not counted as extra Swift Testing executions. Final counts are taken from xcresult, not expected annotation counts.

## 8. Boundedness and concurrency

Persistent state is unchanged: two slots, at most two confirmed descriptors and one provisional descriptor per slot, four core joints per descriptor, existing source/control/time scalars. Candidate count remains eight, global hypotheses at most 73.

Pair evidence is computed on demand; no pair/history registry persists. At most 14 eligible-alternative comparisons, two proposed-pair comparisons and 146 hypothesis pair comparisons occur per association call (a conservative 162-call upper bound). Each examines at most four fixed core joints. Bounds are independent of stream length. No raw frames, framework objects, resource queues or additional ownership are retained.

The tracker remains explicit nonisolated checked-Sendable pure value code importing Foundation only. No unsafe annotation/suppression, actor/lock/Task/timer, public CP1/B1 change or project-wide setting alteration. Runtime heap/throughput/physical accuracy were not benchmarked; bounded-state assertions are not a total-process leak claim.

## 9. Actual verification results

Environment rechecked: **Xcode 26.6 (17F113), Swift 6.3.3, iOS/Simulator SDK 26.5**. `simctl list devices available` verified the booted iPad mini (A17 Pro), iOS 26.5 (23F77), UUID `1E1C6B07-B356-4303-8756-4C0D2A4CDF05`; the old UUID was not assumed blindly.

| Final gate | Actual result |
|---|---|
| New regression before core fix | **FAIL as required**, both mirrored executions; diagnostic regression also fails as required |
| Focused final tracker suite | **80 definitions / 145 executions**, zero failures/skips |
| Full Simulator regression on corrective base | **302 definitions / 462 executions**, zero failures/skips |
| Debug Simulator app/test build | PASS (`build-for-testing` builds both) |
| Release Simulator app build | PASS on final production source |
| Generic iOS device-SDK app build | PASS, unsigned via command-only `CODE_SIGNING_ALLOWED=NO`; **not physical deployment/execution** |
| Complete strict concurrency / warnings-as-errors | PASS on both SDKs: production SIL/WMO and object/WMO, focused/camera/preview test SIL/WMO |
| Six ownership negatives | Expected failures for retained CV workspace, isolated capture delegate and retained Vision workspace, on both SDKs |
| Whitespace / scope / preservation | PASS; only the two pure-core/test files plus this new report differ in corrective worktree; primary file hashes unchanged |
| Physical tracking / production thresholds | Not tested or approved; outside this correction |

The original passing tracker baseline was 68 definitions / 120 executions; final adds **12 definitions / 25 executions**. Full baseline 290/437 is historical and the new run is 302/462. Existing CP1/CP2, camera/preview, pose and gameplay/rendering regression tests are included for this tracking branch's base; this does not claim execution of newer staging-only tests absent from it.

Successful isolated strict checks have no relevant Swift/concurrency warnings/errors. Xcode builds retain the pre-existing AppIntents metadata-extraction warning; no warning was suppressed. Simulator app hosting emits existing RealityKit asset diagnostic chatter; it is not visual validation.

### Commands and evidence

All commands ran from the corrective worktree with explicit `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Main sequence (logs redirected under the evidence directory):

```bash
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/wp-e01-c1.laFm6V/Derived \
  SWIFT_STRICT_CONCURRENCY=complete build-for-testing

# Before fix: same destination/Derived, entire PlayerTrackerTests suite:
# -resultBundlePath /private/tmp/wp-e01-c1.laFm6V/BeforeFixSuite.xcresult
# -only-testing:SedactiveTests/PlayerTrackerTests test-without-building

# After final tests/code: same destination/Derived:
# -resultBundlePath /private/tmp/wp-e01-c1.laFm6V/FocusedComplete.xcresult
# -only-testing:SedactiveTests/PlayerTrackerTests test-without-building
# Then full regression without -only-testing, RegressionComplete.xcresult.

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/wp-e01-c1.laFm6V/ReleaseDerived \
  SWIFT_STRICT_CONCURRENCY=complete build

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/wp-e01-c1.laFm6V/DeviceDerived \
  CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=complete build

bash /private/tmp/wp-e01-c1.laFm6V/verify-strict.sh
git diff --check
```

Strict script was adapted outside the repository to point **exclusively at this corrective worktree**, preserving Swift 5, MainActor default, applicable approachable/upcoming flags, complete checking, warnings-as-errors and both SDK targets. It reuses the prior meaningful negative controls; no untracked repository Scripts file was changed. Review that anchored source path before future reuse.

Final evidence: `FocusedComplete.xcresult`, `RegressionComplete.xcresult`, `focused-complete-summary.json`, `regression-complete-summary.json`, corresponding `.log` files; `final-test-build-v2.log`, `final-release-build.log`, `device-build.log`; `strict-final-v2.log` and `strict/{iphoneos,iphonesimulator}/` logs. `BeforeFixSuite.xcresult`, `before-summary.json`, `before-suite.log`, original snapshots and the intermediate spatial-only `Focused.xcresult`/`PlayerTracker.initial-fix.swift` remain separate. Earlier successful bundles before the final mixed-support test were superseded by the Complete bundles; no stale-binary result is used for final test counts.

Final source SHA-256: tracker `284ff53bc9657a7c5f2176d10f64111b97b9f7ab1f192f4fa3275a12034a2c2b`. Record the final test-file hash alongside this report's artifact manifest; future edits require renewed verification.

## 10. Remaining limits, reviewer action and Git boundary

**READY FOR INDEPENDENT RE-REVIEW**, not ACCEPTED. Review the new pair-evidence meaning, spatial fallback for partial common support, preservation of shape-distinguishable crossings, ordinary unknown-only uncertainty and interaction with retained lost/latched competitors. Unknown-only recovery remains limited to later unique independently supported evidence, configured dwell and original temporal gates. Spurious detections and expired/incomparable identities can still interrupt usability; synthetic numeric policy is not physically calibrated.

No universal guarantee is made for real occlusion, indistinguishable substitutions, pose distortion or faulty observations. B2b still needs one worker-owned instance, original B1 source/control adaptation, staged source-gated commits, immediate status/no-frame expiry, reviewed binding/rebind/new-generation authority and physical characterization. Calibration, provider/gameplay readiness and avatar/overlay alignment remain separate. No implementation proceeds automatically from this report.

The primary checkout's 319 entry files are preserved by hash comparison. Its branch/HEAD and existing Scripts remain unchanged. Corrective worktree status is two modified Swift files and this untracked report, with nothing staged. Only the authorized corrective branch/worktree was created; no existing branch was reset/merged, no commits/push/PR occurred. The worktree is retained for review of its uncommitted result. Skills applied: swift-concurrency and swift-testing-expert.
