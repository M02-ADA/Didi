# WP-E01-P1 — Partial-Body Independence Policy Design Review

**PROPOSED — REQUIRES TECH LEAD APPROVAL**

7 November 2026 · Edo-owned tracking boundary · Documentation/design only

**Recommendation: Option A, conservative comparable-core evidence, for v1.** Retain the existing geometric model's explicitly configured mutual coverage floor and corresponding anatomical pair requirement. Remove the below-floor partial-translation exception after separate approval. Insufficient mutual support is unavailable, however large or coherent the shared subset's displacement. Preserve the existing assignment, competition, transactional commit, recovery and lifecycle rules.

This proposal does not accept B2a or authorize an implementation, B2b, calibration, live CP1, gameplay or avatar work. The latest independent disposition remains REVISE. C1/C2 reports and source remain historical/current implementation evidence, not silently rewritten decisions.

## 1. Current unresolved correctness problem

C1 separated current candidate independence from candidate-to-identity association and stopped treating unknown proximity as nonduplicate. C2 replaced a magnitude-only partial fallback with mean-direction projections, fixing the opposing-shoulder counterexample. Both corrections preserve evaluate → resolve → commit.

The remaining issue is the **meaning of distinct-body evidence**. C2 can classify a pair as distinct from two shared shoulders even though the ordinary comparable-core model requires at least three mutually observed core joints and a corresponding shoulder or hip pair. Coherent upper-body translation does not by itself establish a compatible relationship for the complete torsos. Anchor costs cannot supply the missing candidate-pair evidence.

### Reviewed coherent-shoulder example

With unchanged synthetic policy and 1280×720 context, explicitly acquire full candidates at X=0.55 and X=0.45 at capture times 0.000/0.125. At frame 3, time 0.250, all present confidences are 0.9:

| Joint | Candidate 30 | Candidate 40 |
|---|---|---|
| leftShoulder | (0.49, 0.60) | (0.41, 0.60) |
| rightShoulder | (0.59, 0.60) | (0.51, 0.60) |
| leftHip | absent | (0.50, 0.40) |
| rightHip | (0.50, 0.40) | absent |

The two shoulder displacements both project approximately 0.142222 image heights along their mean, above the fixture's 0.12 separation gate. The partial cost matrix is approximately `[[0.841220, 1.016653], [1.016653, 0.841220]]`. C2 therefore has a unique plausible assignment, passes its pair/reverse checks and reaches confirmation.

Restoring candidate 30 leftHip=(0.42,0.40) and candidate 40 rightHip=(0.58,0.40) preserves acquisition shoulder/hip widths, anatomical ordering and shoulders-above-hips geometry. Both torso scales become approximately 0.245412; their log change from 0.2 is approximately 0.204622, within the existing fixture gate 0.35. Complete pair proximity is effectively zero, and both identity permutations have effectively equal cost. The current full-observation model refuses that configuration.

This is a source-equivalent numerical/branch argument from the independent review, **not a newly executed Swift regression or observed physical swap**. It demonstrates why a below-coverage translation exception needs its own justified evidence model. It does not establish a universal rule that every imagined missing-joint completion invalidates every partial observation.

## 2. Existing implementation and verification baseline

| Item | Inspected baseline |
|---|---|
| Worktree | `/Users/edwardgk/.codex/worktrees/player-tracker-independence/Sedactive` |
| Branch | `codex/wp-e01-c1-candidate-independence` |
| HEAD/base | `69860cc75d820c76c3ac45cfac09edce651892f7` |
| Actual source | Uncommitted C1+C2 changes, not the uncorrected HEAD tree |
| Tracker SHA-256 | `7f4e2fa39726998dc8da7b6853cf311b24f8edc40156d06c050f2a1ba5582731` |
| Tests SHA-256 | `4114037324ed2454b8ebaf162469eadde692d405aee43446bbffdc9fc950705e` |
| Retained C2 evidence | `/Users/edwardgk/LaserHeistReviewArtifacts/WP-E01-C2/run-2026-11-07-c896afb7/` |

The preceding independent review reopened the retained bundles and checked all 2,162 manifest entries against their hashes. Recorded C2 evidence: before-fix 81 passed/1 failed definitions and 147 passed/2 failed executions; final focused 88 definitions/165 executions; full 310/482; zero final failures/skips; Debug/test, Release Simulator and unsigned iOS SDK builds; complete warnings-as-errors SIL/WMO/object gates and six expected ownership-negative rejections. These are previous executions on the source above. No build, test, new compiler probe or device run is performed by this design task; those results do not verify a future Option A implementation.

Read the actual tracker/tests, [B2 design](LH-13B2-Stable-Player-Tracking-Architecture-Proposal.md), [B2a history, especially §§13–15](LH-13B2a-Pure-Tracking-Core-Implementation-Report.md), [C1 report](WP-E01-C1-Candidate-Independence-Correction-Report.md), [C2 report](WP-E01-C2-Opposing-Displacement-Correction-Report.md), latest independent finding, B1 numeric conversion/envelope, PoseFrame, PlayerID and CP1 provenance/validity contracts. Existing App/Games/Shared logical modules and pure value state ownership fit this change; no architectural layer, package, target or effect store is required.

## 3. Evidence semantics and observation limitations

### Separate evidence questions

| Question | Existing mechanism | What it does not establish |
|---|---|---|
| Is a candidate usable? | `descriptor`, confidence/coverage/nondegeneracy checks | Persistent identity or two independent bodies |
| Can this observation continue an identity? | `identityEvidence`: supported cost, excluded, unavailable; original anchor time and geometry | Current candidate-pair independence; absence of another person |
| Are two current observations sufficiently distinguishable? | `independence`, current anatomical values | Who owns either observation; personal identity |
| Is an association uniquely supported globally? | Bounded injective hypotheses including unmatched, cost margin and competitor vetoes | A proof that missing geometric evidence exists |
| May a slot receive positive output? | State/latch eligibility, resolved checks and recovery dwell | Permission to omit its evidence when it is ineligible |
| May history advance? | Final `confirmed` transition after whole-frame resolution | Permission to turn tentative/guessed motion into a confirmed anchor |

Historical continuity uses at most two confirmed descriptors per identity and bounded capture-time prediction. It can support association, but cannot turn two insufficiently comparable current observations into independent bodies. Lost/latched identities retain competition evidence despite being forbidden positive output. Unavailable comparison is not exclusion; exclusion is only under the configured, fresh geometric model.

### Observation boundary

`Capture/PoseEstimator.swift` synchronously invokes Vision in the existing worker and converts only the current B1 capability set: nose, eyes, ears, neck, shoulders, wrists, hips and ankles. Fourteen raw joint types are available, with explicit absence and confidence; the tracker currently uses only shoulders/hips. There are no B1 elbows/knees, depth, appearance identity, segmentation association, bone rigidity constraints or persistent SDK identity. Raw confidence is not a probability of identity. Candidate IDs are frame-local.

Canonical source values remain upright/unmirrored. Matching alone aspect-corrects X. Generation/frameID/capturedAt/geometry/dimensions come from PoseFrame; epoch and applied presentation provenance remain in the internal source envelope. Binding control revision is distinct from camera generation. No new joint, mask, calibration baseline or provenance field is proposed.

### Three candidate-pair outcomes

- **Distinct:** sufficient *current observed* evidence under the explicitly selected geometric model. It permits further association checks; it is not a stand-alone positive identity verdict.
- **Overlapping/duplicate ambiguity:** sufficiently comparable observations fail the selected separation criterion without the existing full-torso shape distinction. This is a model classification, not proof that Vision literally duplicated one person.
- **Unavailable:** required mutual support is missing, weak or incomparable. It proves neither overlap nor separation.

Even all four observed core joints cannot guarantee personal identity through complete occlusion, unobserved substitution, distorted detections or an indistinguishable crossing. B2a can enforce deterministic refusal rules; it cannot certify physical identity.

## 4. Options A, B and C

### A — Conservative comparable-core evidence

Require the existing mutual support floor, corresponding anatomy and valid descriptors. Preserve the existing fully observed shape distinction; otherwise use existing comparable proximity. If that comparison is unavailable, return unavailable without a lower-coverage exception. This is an explicit observational model, not an implicit certificate about unobserved hips.

It preserves full/partial and same-missing-joint partial pairs when their actual mutual support meets the policy. Full-torso shape-distinguishable crossings remain possible. Independent unaffected players can continue only when all existing anchor, competitor, proposal-pair and recovery checks justify it. It deliberately refuses some visually obvious but under-supported pairs.

### B — Geometrically certified partial separation

A stronger claim would require a bounded, explicit completion model and a positive certificate that plausible missing anatomy cannot create the ambiguity being excluded. Candidate and anchor gates cannot simply be reused as a proof of pair independence: they answer different questions and can both support competing identities.

The current model supplies normalized bounds, confidence/coverage, minimum pair extent, full torso length when available and bounded anchor prediction. It lacks a validated rigid-body, maximum-width, depth or anatomical articulation model. The reviewed opposite-lean example is admissible without inventing exotic geometry. Some extreme separated configurations might admit a certificate from existing bounds; this proposal does **not** claim that certification is mathematically impossible. However, no general sound certificate, conservative numerical bounds or bounded implementation proof has been established.

Enumerating a few guessed hips or sampling a grid would not prove separation over continuous permitted completions. Adding fixed widths, joint estimates, maximum lean angles or noise bounds would introduce unapproved assumptions. Option B needs its own narrowly specified evidence model, proof and independent test review before implementation. It is not necessary for v1.

### C — Heuristic partial translation

C2 correctly tests common-direction separation of shared points. Treating this as body independence additionally assumes that the shared subset represents the torso as a whole, that missing anatomy cannot change the relevant relationship, and that coherent pose distortion/duplicate estimates are not confounding it. Those assumptions are not established by B1 or current policy gates. A nonzero projection is not a missing-hip observation.

It offers better apparent continuity, but may admit unsupported dual confirmation and contaminate confirmed history. Additional dwell cannot prove the missing anatomy; repeated heuristic updates can instead reinforce a wrong hypothesis. Retain C2 as historical evidence, not authoritative v1 independence logic.

### Comparison

| Criterion | A: comparable core | B: certified partial | C: heuristic translation |
|---|---|---|---|
| Conservative identity safety | Clear support floor plus unchanged competition model | Potentially stronger if the certificate/model is sound | Depends on unapproved subset-to-body assumptions |
| False dual confirmation risk | Removes below-floor exception; residual 2D/model risk remains | Limited by declared model/certificate, not physical certainty | Known unresolved coherent-subset risk |
| False uncertainty/over-refusal | Higher for complementary missing anatomy | Could preserve certified extremes; incomplete solver must refuse | Lower apparent refusal, with safety cost |
| Valid partial tracking | Yes when mutual coverage actually suffices | Yes only when certified and other gates pass | More partial cases, including disputed ones |
| Unaffected player | Preserved when full competition permits; not unconditional | Same requirement | Same requirement, but explanations can be too weak |
| Crossing/occlusion | Distinguishable full cases remain; unsupported crossings refuse | Requires explicit treatment in the certificate | Shared-subset motion can conceal torso ambiguity |
| Recovery/expiry | Existing dwell, history freeze and loss rules | Must preserve them | Cannot use dwell to cure unsupported independence |
| B2a state architecture | Existing three outcomes and transaction fit directly | Could fit outcomes, but additional reasoning machinery needed | Fits mechanically; semantics remain disputed |
| B2b compatibility | Same one-worker value boundary | Depends on bounded solver cost and publication gates | Ownership-compatible, correctness-unapproved |
| Memory/computation | Existing fixed four-joint checks; no extra state | Must prove bounded continuous reasoning, not assume it | Already bounded, which does not prove correctness |
| Deterministic tests | Precise coverage, margin, refusal and state assertions | Requires analytical certificate/oracles and numerical boundaries | Examples easy; safety assumptions hard to establish |
| Complexity/maintenance | Smallest reviewable scope | Highest model/proof burden | Small code, recurring semantic exception burden |

## 5. Recommended v1 policy and its precise claim

**PROPOSED: choose Option A.** Under the existing observational model, positive pair distinction requires:

1. Both descriptors passed existing normalized-input, confidence, per-descriptor coverage and nondegeneracy validation.
2. Both are fully observed and the existing finite full-torso shape difference exceeds its configured gate; **or** their common confident core joints meet `minimumSharedCoreJoints`, include the corresponding shoulder or hip pair, and existing proximity exceeds `minimumPairSeparation`.
3. When comparable proximity is at/below separation without the full-shape distinction, classify overlapping. With insufficient mutual comparison, classify unavailable. There is no translation, individual-distance, candidate-index or historical-position exception.
4. A distinct pair still must satisfy every existing positive-recipient, source/order, global assignment, reverse-competition and recovery condition before output/history confirmation.

The current synthetic minimum is three shared core joints; the typed policy allows three or four. This recommendation changes neither value nor validation. Both full descriptors necessarily share four joints, so the retained shape branch cannot bypass a mutual-coverage failure. Missing optional wrists/face/ankles do not affect this core rule.

This means **sufficient observed distinction under a declared support floor**, not separation certified against every possible hidden joint. A three-core comparable pair is still a partial model. New supported observations may later reveal ambiguity. Option A does not guarantee completion-monotonic classification for every three-to-four-joint extension, nor physical identity. Claiming that stronger property would require Option B or a separately reviewed stricter evidence requirement, not another fallback patch.

The policy decision for approval is therefore explicit: accept the existing comparable-core observational model as the v1 pure-core evidence boundary, with no below-floor exception. If the Tech Lead instead requires positive classification to survive **all model-permitted missing-joint completions**, this Option A proposal cannot be approved under that stronger interpretation. Do not silently claim the stronger guarantee or silently change the numeric floor to four.

Why this fits Laser Heist: preserving trustworthy refusal is preferable to turning sparse live detections into silently confirmed player evidence. It retains useful tested partial tracking without a new body model, target, package, tracker or raw resource owner. Device characterization must later establish whether its refusal rate is usable for a parent and child.

### Appropriate model-bounded plausibility

For counterexample/review reasoning, a completion must preserve observed coordinates, anatomical labels, exact source context and all actual descriptor checks. Where used to claim anchor compatibility, it must also satisfy the existing capture-time, coverage, motion/residual and available scale gates. A completion cannot move an observed shoulder, import another frame or use a stale anchor. Analysis must explain why its geometry is credible, rather than labeling every normalized point configuration a physical body.

The opposite-lean completion in §1 preserves widths and ordering and lies inside those gates. The current model has no approved constraint excluding it. Preserved widths in that example are **not** a new rule that every person's projected width is fixed. Likewise, a completion inside numeric gates is not automatically physically validated. These are bounded review assumptions, not synthesized production joints or an exhaustive model of human anatomy.

Option A avoids using insufficient mutual support positively; it does not run a completion search. Do not demand an impossible guarantee over arbitrary physically impossible completions, and do not invent unapproved anatomical restrictions to dismiss an admissible ambiguity.

## 6. Proposed policy-level safety invariants

1. Candidate-to-anchor support and lower association cost never substitute for current candidate-pair distinction.
2. Without the full observed shape branch or the required comparable core, candidate independence is unavailable; removing required support cannot create a distinct result through a fallback.
3. Missing/low-confidence joints remain absent. No zero residual, guessed coordinate, confidence average or historic landmark fills the gap.
4. A modeled ambiguous/refused or tentative outcome cannot advance confirmed descriptors, velocity history or lastConfirmedAt.
5. Positive outputs are injective and must remain uniquely supported by the bounded global hypotheses, including unmatched alternatives.
6. Every retained lost/latched identity continues to compete under the same supported/excluded/unavailable rules. An unavailable/expired competitor is not proven absent.
7. A genuinely unaffected identity may continue when the complete existing evidence and competition tests permit it. Do not add a blanket both-lost rule.
8. Pair unavailability alone causes ordinary uncertainty and clears tentative recovery; it does not establish permanent identity exchange. Existing stronger duplicate/contested/reverse-evidence/loss conditions retain their latches. Do not erase a latch merely because coverage later drops.
9. Both proposals and final outcomes derive from the same immutable frame baseline; one slot's refusal cannot weaken the other's obligation. Commit history only after whole-frame resolution.
10. Frame-local IDs, array order and later left/right positions never establish identity. Initial mirrored-left P1/right P2 binding stays explicit, stable and atomic.
11. Original generation, epoch, geometry, dimensions, presentation, frame/time and binding revision validation precedes mutation. Rejection advances neither history nor dwell.
12. Recovery requires later sufficient current evidence, unique association and existing capture-time dwell. Repetition of unavailable pair evidence cannot mature a recovery.
13. Expiry uses injected host time without a fake camera frame. Lost identity cannot auto-recover; full rebind uses externally supplied new camera generation and a valid control revision. Tracker generates neither a camera generation nor a gameplay phase.
14. Two slots, eight retained candidates, at most 73 hypotheses, and two confirmed/one provisional descriptor per slot remain the bounds. No new async work, raw frame history, framework object, state owner or CP1 consumer.

These are model-scoped invariants, not a guarantee that every real human exchange is observable. When evidence/model assumptions are inadequate, expose that limitation rather than rename a slot or promise universal identity preservation.

## 7. Expected supported and refused scenarios

| Current evidence | Proposed v1 behavior, subject to other gates |
|---|---|
| Two full distinct torsos | May track both |
| Full torsos coincident in center but distinguishable by existing full shape gate | May preserve established identities; no approval of physical thresholds |
| One full torso, one valid three-core partial; shared three with required pair | May track both |
| Two three-core partials missing the same joint; shared three with required pair | May track if adequately separated and globally unique |
| Two complementary three-core partials; only two shared joints | Unavailable pair distinction, even if spatially far or coherently translated; refuse unsupported dual confirmation |
| Only a diagonal shared pair, or three common joints when the floor is configured four | Unavailable comparison; do not relax policy |
| Sufficiently comparable close candidates without shape distinction | Existing overlapping/duplicate ambiguity and latch behavior |
| One identity challenged by multiple partials, healthy full peer independently explained/excluded from that identity | Healthy peer may continue; affected identity refuses |
| Healthy candidate itself remains supported by a competing identity with no independent-body explanation | Refuse healthy candidate too; cost advantage is insufficient |
| Irrecoverable crossing/overlap, overflow, expired competition or lost slot | Existing conservative rules, including explicit rebind where already required |
| Later compatible full/comparable separation after ordinary uncertainty | Recovery dwell; no provisional history advance |

Unavailable need not force permanent loss immediately, but prolonged refusal can reach the existing expiry/lost state. No improvement to that UX is authorized by this proposal.

## 8. Impact on existing C1/C2 tests

**No tests are edited here.** A future expectation change must cite this policy approval and describe the old heuristic premise. Preserve old scenes as refusal cases; do not delete evidence to obtain a green suite. Results for a new policy must be executed and reported afresh.

### 8.1 Safety cases: keep their protections unchanged

| Existing test(s) | Required preservation |
|---|---|
| C1 `complementaryPartialCandidatesCannotProveIndependentBodies`, `partialPairEvidenceIsPermutationAndIDInvariant` | Refusal, nil IDs, frozen confirmed history; no unknown-only permanent latch |
| C1 `comparableNearCandidatesRetainDuplicateLatch` | Full/same-missing-hip supported duplicate controls remain latched |
| C1 `unknownPartialCoverageDoesNotLatchOrConfirm`, `oneSeparatedSharedJointCannotProvePartialBodiesDistinct` | Unknown stays unavailable; no unsafe confirmation |
| C1 `repeatedUnknownPairsFreezeHistoryAndCannotResurrect`, `unknownPairResetRequiresOriginalControlAndNewGeneration` | Expiry, loss, control/reset/history protections |
| C1 `inferenceFailureDuringAcquisitionReportsFailureAndClearsDwell` | Independent diagnostic correction unchanged |
| C2 `opposingPartialDisplacementsCannotConfirmIndependentBodies`, `restoringOpposingFixtureHipsRetainsSupportedOverlap`, `opposingPairsAreInvariantUnderCandidateOrderAndLocalIDs` | Both-direction refusal and restored supported-overlap behavior |
| C2 `incompleteCancellationCannotBecomeIndependentTranslation`, `largeMeanDisplacementStillNeedsSupportFromEverySharedJoint` | Retain all negative scenes/history assertions; Option A refuses below-floor evidence without needing a projection calculation |
| C2 `repeatedOpposingObservationsFreezeHistoryThroughExpiration` | No learning from refusal, no lost resurrection, bounded state |
| Earlier cross-slot, same-frame, overflow, stale/context/control, no-frame expiry and long-sequence tests | Preserve substantive safety assertions; no new eligibility or history bypass |

### 8.2 Supported positive/recovery cases: preserve

- C1 `fullTorsoShapeExclusionPreservesIndependentOverlap`, earlier `differentTorsoGeometryCanDisambiguateCrossing` and distinguishable-path tests: both full torsos provide the existing supported geometry.
- C1 `independentPlayerSurvivesComplementaryPartialCompetition` and earlier independently explained/unaffected-player controls: preserve the healthy side where its own full competition model permits it; the ambiguous pair need not be given positive output.
- Existing `partialTorsoUsesComparableAnatomicalSupport`: one partial against a full current peer still has the required three common joints under its test policy.
- C1 `unknownPairAllowsDwellRecoveryOnlyAfterSeparation` and C2 `opposingUncertaintyRecoversOnlyAfterSupportedSeparationAndDwell`: initial sparse scene refuses, later adequate full separation recovers only after dwell.
- C1 separation-matrix same-missing-joint combinations: three mutually observed core joints remain comparable under the unchanged fixture floor.

### 8.3 Disputed heuristic positives: approval required to revise

| Test | Current expectation | Proposed intentional revision after approval |
|---|---|---|
| C2 `coherentPartialSeparationSupportsDifferentTranslationDirections` | Four parameter executions expect dual tracking from complementary missing hips/two shared shoulders | Keep those inputs as unavailable/ordinary-uncertain history-freeze controls. Add independently comparable positive fixtures to preserve useful directional coverage; do not merely remove the old tests. |
| C1 `separatedPartialCoverageRemainsSupported` | Four executions loop over sixteen ordered missing-core combinations and expect all to track | Preserve the four same-missing combinations as positives. The twelve complementary combinations have only two shared joints and become explicit refusal controls. Split expectations clearly; loop combinations are not sixteen separate executions. |

These are the two identified C1/C2 definitions with positive assumptions directly dependent on the disputed fallback. The other eighteen C1/C2 definitions retain their substantive safety/positive requirements. This classification is source-based design analysis, not an executed trial of Option A. If later execution identifies another impacted positive, stop and explain its premise before revising it. Do not silently weaken assertions or promise future test counts now.

## 9. Proposed implementation scope after approval

Only a separately authorized pure-core change is proposed:

| File | Proposed scope |
|---|---|
| `Sedactive/Shared/BodyTracking/Processing/PlayerTracker.swift` | Keep the C1 three-state classifier, all call sites, costs, competitor evidence, transaction and diagnostic fix. Replace the below-coverage fallback with unavailable; preserve full-shape and comparable-proximity decisions. No numeric policy/default changes. |
| `SedactiveTests/Shared/BodyTrackingTests/PlayerTrackerTests.swift` | Add the coherent-shoulder/opposite-torso review scene and metamorphic controls; explicitly revise only approved heuristic expectations; retain prior regressions and supported positives. |
| A subsequent corrective verification report | Record approval, exact diff, intentional expectation changes, actual execution counts and persistent evidence. No existing architecture/history rewrite. |

C1's separation of independence from anchor evidence and its proposal/resolution guards are retained. C2's cancellation findings and permanent regressions are retained; its production projection fallback is superseded as v1 authoritative evidence, rather than augmented again. The acquisition-stage inference-failure diagnostic remains independent and retained.

No public contract or type expansion is required: existing `.distinct`, `.overlapping`, `.unavailable` and uncertain/lost/rebind outputs express the policy. CP1 TrackingStatus, PlayerID, PoseFrame, source envelope, camera/FrameStore, MotionEngine, renderer, gameplay and settings remain unchanged. No new inference, calibration or appearance feature is needed for Option A.

## 10. Required independent acceptance tests and review gates

| Gate | Required evidence after implementation authorization |
|---|---|
| Coverage boundary | Full/full, full/three-core, same-missing three/three positives; complementary three/three with two common joints refuses, regardless of distance, direction or IDs. Cover each missing core joint and configured floor three/four. |
| Latest policy counterexample | Exact §1 scene and its complete restored counterpart, mirrored acquisition/current geometry, order/ID permutations. Assert same-frame nil outputs/history freeze for unsupported partials; do not require identical permanent-latch status between unavailable partial and supported full ambiguity. |
| Missing-support metamorphism | With source/anchors fixed, dropping mutual support below the required floor cannot retain/create distinct through an exception. Distinguish this from a universal hidden-completion guarantee, which Option A does not claim. |
| Comparable model | Preserve same-missing partial positives, adequate paired support, full shape-distinguishable crossings and existing close/duplicate behavior, including boundary/tie cases under explicit test policies. |
| Competition and healthy continuation | Original excluded/lost competitor, reverse-unavailable and same-frame ambiguity regressions; positive healthy peer; lower cost alone cannot establish safe exclusion. |
| Time/history/lifecycle | Recovery dwell and interrupted dwell, repeated unavailable evidence through expiry, lost latch, no-frame expiry, malformed/stale input transactional rejection, new-generation/control reset. |
| Boundedness/determinism | Eight-candidate worst cases, at most 73 hypotheses, finite state/history, long streams, symmetric slot cases and array permutations. |
| Verification | Focused and full Simulator suites; app/test/Release and applicable iOS SDK builds; complete warnings-as-errors SIL/WMO/object checks and meaningful ownership negatives. Use fresh persistent bundles, hashes and manifest tied to the new source; C2 passes do not certify it. |
| Independent acceptance | Reviewer checks approved semantics, unchanged protected assertions and intentionally changed positives, not just aggregate pass counts. B2a acceptance remains pure-core only. |

Do not add numeric thresholds merely to make a fixture pass. If the selected comparable-core model itself proves inadequate under a required product guarantee, return to an evidence-model review; do not create a new sparse-geometry exception without justification.

## 11. B2b and physical-validation implications

Option A fits one worker-owned pure tracker with the same B1 source/control adaptation, staged publication, immediate lifecycle invalidation and no-frame expiry. No second FrameStore consumer, camera, identity store, observer or gameplay reader is introduced. B2b is not authorized by this document or by a later pure-core test pass.

Expected usability cost: alternating/complementary missing hips or shoulders can interrupt both current matches even when people look widely separated. Expiry can eventually require rebind; lost/latched evidence can also interrupt a visible peer. Dwell must not be shortened or a source generation fabricated to conceal these effects. Jevon retains phase/readiness/pause/recovery decisions; Edo owns source and tracker validity.

After separate integration approval, record on the target iPad Pro M4: observed core/mutual-coverage patterns, per-slot uncertainty/loss and rebind frequency, recovery time, one-sided refusal versus healthy continuation, crossings/leans/partial exits/overlap/third entrants, different parent/child heights, camera stop/background/geometry reset, preview independence and resource bounds. Distinguish camera FPS, inference cadence, tracker cost and result age. Use finite consented scenarios and numeric diagnostics, not stored participant imagery or claimed identity accuracy from counts alone.

Device evidence must determine whether the refusal policy is usable and whether additional reviewed evidence is warranted. No confidence/distance/accuracy/latency/30-FPS production acceptance threshold is selected here. B1's successful two-person extraction does not validate persistent identity. Kevin's future exact-source skeleton overlay remains separately reviewed; it cannot become identity evidence.

## 12. Open decisions, affected reviewers and documentation verification

| Decision | Required review / status |
|---|---|
| Adopt Option A's observed-comparable v1 claim and remove below-floor exceptions | **Tech Lead approval required**, then independent tracking correctness review |
| Accept current configurable three/four mutual-core model as v1, without a universal completion certificate | Edo/Tech Lead must explicitly approve this scope; numerical live tuning still unapproved. If stronger certification is required, defer implementation for Option B/stricter-model design review. |
| Intentionally change the two heuristic-positive definitions and preserve their scenes | Tech Lead approval with documented rationale, then independent test review |
| Accept conservative continuity/rebind UX cost | Edo + Jevon before live activation; future pause/recovery/interface behavior remains Jevon-owned |
| Need certified partial behavior later | Deferred pending measured refusal patterns and an explicit model/proof; no assumption that it is mandatory or already feasible |
| Display uncertainty/fallback and future overlays | Kevin reviews later presentation integration; no renderer/coordinate change or renderer sign-off on pure algorithm code is required by this document |
| Player-facing explanations | Theo's later UX review with Edo/Jevon; no automatic engineering assignment |

There is no recorded sign-off on these new policy choices. Overall status is **PROPOSED — REQUIRES TECH LEAD APPROVAL**. Approval of this design must precede a separately scoped implementation request; it is not permission to implement immediately.

This task creates only this Markdown file. Existing source/tests, C1/C2 reports and artifacts, B2 architecture/history, CP1/CP2, Architecture V2, workplan, project/signing and primary checkout remain untouched. Documentation verification checks source-method/test-name correspondence, model/claim consistency, approved-versus-proposed wording, links, whitespace, Git scope and pre-existing file hashes. No tests/builds/device runs or Git mutations are performed. Skills used: swift-architecture-skill for pure-state responsibility fit, plus the previously read swift-concurrency and swift-testing-expert guidance for ownership and deterministic acceptance boundaries; no architecture framework is adopted.
