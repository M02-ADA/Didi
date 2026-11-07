# WP-E02A1 — D02/D03 Recording and Experimental Tracking Policy Proposal

7 November 2026 · Edo / camera and motion architecture

**Disposition: POLICY PROPOSED — REQUIRES TECH LEAD VALUE APPROVAL. No B2b implementation or physical tracking activation is authorized by this document.**

## 1. Decision authority and recording

The Tech Lead's current WP-E02A1 request explicitly selects D02/D03 v1. The accompanying [decision record](LaserHeist-D02-D03-Tech-Lead-Decision-V1.md) is a byte-for-byte repository copy of the supplied `LaserHeist-D02-D03-Tech-Lead-Decision-V1.md`. Its historical “repository recording pending” and commit/merge wording is preserved rather than silently rewritten. This task records the selection locally; repository publication remains pending a separately authorized commit/merge. Neither file claims Jevon independently approved the session behavior.

The attachment is decision evidence, not permission to commit, implement, or bypass the user's documentation-only scope. D02/D03 select technical binding/recovery semantics and a future session product direction; they do **not** select tracking numbers, accept D06 field definitions, or authorize live gameplay.

The WP-E02A0 preflight is available in this conversation, not as a checked-in report in this checkout. Its earlier unapproved-D02/D03 blocker is addressed by the Tech Lead selection. Its identified admission, worker-commit and no-frame integration gaps remain.

## 2. Verified source baseline

- Checkout: `/Users/edwardgk/Desktop/APPLE/Sedactive-B2b`.
- Branch: `feat/live-player-tracking`.
- HEAD and available `origin/staging`: `93254b097b1f44aac95c181077f38a59534632c6`; no divergence at inspection. No fetch or reference mutation performed; this is the latest locally available verified staging reference.
- Initial working tree: clean.
- Accepted Option A [PlayerTracker](../Sedactive/Shared/BodyTracking/Processing/PlayerTracker.swift) SHA-256: `4cc0a4a648e7250910303826bd5a3a14d27efea023d4f9ff861f094eff01fd34`.
- [PlayerTrackerTests](../SedactiveTests/Shared/BodyTrackingTests/PlayerTrackerTests.swift) SHA-256: `906defbadd128ff938700367c6f829a06958bd52e5c28df761a3a007a13e8a75`.
- Existing B2 design: [stable-tracking proposal](LH-13B2-Stable-Player-Tracking-Architecture-Proposal.md); implementation and correction history remain unchanged.
- Architecture V2 and Technical Workplan V2 are available through `origin/feat/architecture`, not merged documents in this checkout. They remain historical/proposed planning references; the new selection does not rewrite them.

This proposal uses actual source and its validators as authority. Existing pure-core acceptance is not evidence of physically validated live thresholds.

## 3. Source-contract compatibility

| D02/D03 requirement | Existing implemented contract | Required B2b seam / assessment |
|---|---|---|
| Explicit arm and atomic pair binding | `PlayerTracker.reset`, `armBinding`, `acquire`; full torso acquisition, capture-time dwell, mirrored-display-left P1 / canonical-right P1 | Compatible. Add one Edo facade request/revision authority and one source-correlated acknowledgment. Seeing two people or starting camera must never arm it. Setup lane confirmation is a later UI/session action. |
| Request idempotence and revision changes | Core checks exact control revision; reset/invalidate require increasing revision; repeated arm does not reset dwell | Facade requestID/duplicate/cancel semantics are absent. Preserve same-active-request idempotence; fail closed on revision exhaustion rather than wrap. Bound request/status retention. |
| Original admission stamp | FrameStore owns source admission and bounded leases; metadata preserves generation, epoch, frame/time, geometry and orientation | No binding-control stamp exists on admitted work. Add an internal immutable stamp at synchronized acceptance before copying/inference. Reading a new revision after Vision is incompatible with D02.4. No CP1 field expansion is needed. |
| One mutable tracker | `CameraCopySink.consume` is the existing actor-isolated synchronous reconstruction/Vision path; `MotionEngine` is a skeleton | Compose exactly one authoritative core there, directly or through worker-local MotionEngine. A staged value copy is a transaction, not another live tracker/consumer. No CV/VN object transfer, additional inference or reader. |
| Atomic source/control gated commit | `CameraPoseResults.Ticket` contains source and invalidation token; `finish` validates and returns Bool under its mutex | Ticket has no binding revision. Sink currently ignores the Bool because B1 has no tracker state to commit. “Mutate tracker then discard publication” is unsafe for B2b. A separate Bool check followed by mutation also leaves a revocation race. Final source/control acceptance, state commitment and publication need one reviewed linearization protocol; exact actor/mutex API feasibility still needs compiler/race proof. Existing B1 gate is not that proof. |
| Preserve whole-frame B2a safety | Accepted evaluate → resolve → commit, retained competitor evidence, Option A comparable core; refused/tentative history frozen | Retain all core rules unchanged. Stage the whole input transition and discard its state on external rejection, not just its output. |
| Full rebind | Core retains `lastBoundGeneration` across reset/invalidate and refuses another binding on that generation | Compatible with a real stop/start on a fresh source generation. Do not reconstruct a fresh tracker to erase this guard. |
| Capture-owned generation | `CameraPipeline.start(generation:configuration:)` accepts a caller-supplied UUID, rejects reused generations, and creates a new epoch/geometry context | “Capture-owned” means Edo's capture-control facade requests an actual new run and supplies the UUID to this API. The tracker never allocates it. CameraPipeline does not currently allocate the generation UUID internally; requiring that literal allocation location would be a further API decision, not an existing contract. No such change is needed for the selected real-run semantics. |
| Stop/interruption/background/failure | FrameStore `end` / `suspend` synchronously invalidate raw pose/preview publication and pending frames; native resume exists | Extend the same authority cutover to revoke binding and clear tracking immediately, even while inference occupies the worker. Native resume is not reauthorization. Resume itself need not increment revision; revocation and explicit new authorization do. |
| No-frame expiry | Core `expire(at:controlRevision:)` uses injected host time; watermark rejects older captured input; no synthetic frame | Add one lifecycle-owned bounded deadline/wakeup path serialized with worker mutation. Immediate public invalidation cannot await a blocked worker. Later worker expiry and staged commit must honor the authoritative watermark. Treat stale tracking rejection as refusal, not automatically a fatal camera error. |
| Diagnostics and outputs | Camera has one observer; raw poses use a latest-value snapshot; DEBUG numeric diagnostics already exist | Extend existing reporting, without another status observer/FrameStore consumer. One bounded latest tracking/status result; numeric values only, no images/joint-coordinate persistence. Raw unbound candidates may remain visible as raw B1 diagnostics, never relabeled as trusted players. |
| Future session product behavior | `BodyInputService` is a skeleton; GameSessionCoordinator currently constructs replay input | D03.6 is a future Jevon session implementation/review handoff. B2b must not pause GameClock, change rounds/scores, calibrate, or publish live CP1. This absence is not a diagnostic-integration blocker. |

Source locations: [CameraPipeline](../Sedactive/Shared/BodyTracking/Capture/CameraPipeline.swift), [FrameStore and CameraCopySink](../Sedactive/Shared/BodyTracking/Capture/FrameStore.swift), [CameraPoseResults](../Sedactive/Shared/BodyTracking/Capture/CameraPoseResults.swift), [PoseEstimator and CameraPoseResult](../Sedactive/Shared/BodyTracking/Capture/PoseEstimator.swift), [PoseFrame](../Sedactive/Shared/BodyTracking/Models/PoseFrame.swift).

**Conclusion:** no demonstrated conflict requires changing accepted B2a Option A or CP1. There are missing implementation seams, especially atomic external commit, rather than existing implementations of these new guarantees. Their compiler and deterministic race gates must pass before integration acceptance.

## 4. Proposed B2bExperimentalPolicyV1

**Explicit candidate only; NOT SELECTED, implemented, physically tuned, or a production default.**

`PlayerTrackingPolicy` supplies **no default policy**. Its 20 fields must be explicitly constructed and validated. The only inspected default values are the synthetic `TrackingFixtures.policy()` helper in the test target. This proposal deliberately names every carry-over below so the Tech Lead can approve or replace it. Production must never import fixtures or obtain an implicit fallback from them.

Rationale for proposing the existing tested configuration first: keep the accepted geometric model and establish a controlled baseline while measuring actual live confidence/coverage/uncertainty. There is no live B2 tracking evidence to justify claiming better numbers. Synthetic support makes these values reproducible; it does not make them physically suitable. Approval should cover the complete versioned set, including coupled costs and deadlines.

All distances below use aspect-corrected **image-height units**, unless specifically marked normalized X. Capture/dwell/expiry time is monotonic host-clock seconds, never GameClock or an assumed frame count.

| Exact policy field | Proposed V1 value | Source provenance, rationale and expected tradeoff |
|---|---:|---|
| minimumJointConfidence | 0.5 | Explicit fixture carry-over; accepts joints at or above cutoff. May reject usable weak child/partial joints. Not association probability; B1 DEBUG low-confidence label 0.3 is not this policy. |
| minimumTorsoExtent | 0.02 image heights | Fixture carry-over; rejects degenerate torso length / observed shoulder or hip pair width. Not a physical minimum height or calibrated size. |
| minimumPairSeparation | 0.12 image heights | Fixture carry-over; acquisition separation and comparable-pair duplicate/independence boundary. Larger rejects close players; smaller risks overlapping ambiguity. |
| centerGuardFraction | 0.04 normalized X | Fixture carry-over; acquisition centers must be strictly right of 0.54 for P1 and left of 0.46 for P2. Setup placement constraint, not later identity sorting. |
| acquisitionDwell | 0.125 s | Fixture carry-over with exact synthetic boundaries; still at least two supported observations. Short initial evidence window; not a device-validated stable-binding duration. |
| recoveryDwell | 0.125 s | Fixture carry-over; at least two uniquely supported recovery observations. No recovery of lost/latched identity. Fast recovery candidate, potentially restrictive under intermittent joints. |
| maximumObservationGap | 1.0 s | Fixture carry-over; bounds source gaps AND confirmed-anchor prediction age. A nominal 2 s recovery window does not guarantee match support after this 1 s limit. |
| recoveryWindow | 2.0 s | Fixture carry-over; expiry/loss horizon since last confirmed identity, not since last raw frame. Rebind may be required earlier by irreversible ambiguity. |
| freshness | 0.5 s | Fixture carry-over; no-frame expiry threshold since last confirmed match. A 500 ms nominal window may be visually stale; this is not approved gameplay tolerance or a scheduler-latency guarantee. |
| maximumSpeed | 0.5 image heights/s | Fixture carry-over; clamps prediction velocity and expands position gate with elapsed capture time. Can refuse brisk motion or permit wider competition after gaps. |
| positionGate | 0.15 image heights | Fixture carry-over; base prediction-position gate. Wider allows movement but more plausible competitors. Acquisition continuity uses the unexpanded base gate. |
| jointResidualGate | 0.22 image heights | Fixture carry-over; upper gate on confidence-weighted mean shared-joint residual. Not a raw pixel or world-space collision tolerance. |
| maximumLogScaleChange | 0.35 absolute log ratio | Fixture carry-over; torso-length compatibility gate and full-torso shape-distinction boundary. Apparent pose/scale change can exclude continuity or distinguish candidates; neither is biometric identity. |
| positionWeight | 0.4 dimensionless | Fixture carry-over; weights gated position residual in assignment cost. Must be reviewed jointly with unmatched cost/margin. |
| jointWeight | 0.4 dimensionless | Fixture carry-over; weights gated shared-joint residual. Missing data cannot receive zero-error credit. |
| shapeWeight | 0.2 dimensionless | Fixture carry-over; weights available normalized log torso-scale change. Missing shape pays a penalty instead. |
| missingEvidencePenalty | 0.3 cost per absent term | Fixture carry-over; per missing shared core joint plus unavailable shape term. Does not restore missing evidence or prove independence. |
| unmatchedCost | 2.0 cost per slot | Fixture carry-over; rejection alternative in global assignment. Relatively high compared with a valid edge; not a confidence cutoff and cannot override competitor/independence vetoes. |
| assignmentMargin | 0.15 absolute cost | Fixture carry-over; includes hypotheses within this cost band of the best, including ties. Not 15% confidence. More alternatives can produce conservative uncertainty/latching. |
| minimumSharedCoreJoints | 3 joints (allowed 3 or 4) | Explicitly select approved Option A's configurable lower floor for initial characterization. Corresponding anatomical shoulder/hip pair still required; full four-joint acquisition unchanged. Complementary partial candidates with only two mutual joints remain UNAVAILABLE, however far their shoulders appear. |

Every table row requires **Edo's explicit approval before active on-device B2b tracking**. That includes selecting 3 rather than 4 shared joints. The allowed 3/4 model is already approved; this particular live selection is not.

Recommended selection record: policy name/version, all 20 literal values, approving owner/date, source commit/hash, and diagnostic run context. A value change creates a new recorded experimental selection and fresh affected evidence; do not silently tune during a run. Invalid configuration fails closed rather than falling back. No public CP1 field is proposed for policy version.

### Static validation and coupled consequences

These proposed values satisfy the inspected validator: positive/nonnegative finite ranges; confidence ≤ 1; center guard < 0.5; shared core count in 3...4; freshness ≤ gap ≤ recovery window; recovery dwell < recovery window; margin < unmatched cost; finite aggregate costs and gate expansion. This is source-level arithmetic, not a newly executed Swift test.

- Aspect correction is `x * width / height`; published normalized coordinates remain unchanged. At 1280×720, pure horizontal distances 0.12 / 0.15 / 0.22 image heights correspond to normalized-X distances 0.0675 / 0.084375 / 0.12375. The 0.02 extent is 14.4 pixels in the image-height metric, not a standing-body acceptance requirement.
- Prediction position gate is `0.15 + 0.5 * dt`, with actual capture dt; supported anchor age is at most 1 s. No 30 FPS assumption is valid for irregular processing.
- With three shared joints and absent full shape, missing-term cost is 0.3 + 0.3 = 0.6 before position/joint error. For admissible edges, full evidence costs at most 1.0; this partial case at most 1.4. Unmatched cost 2.0 therefore favors admissible matches in the cost objective. Safety depends on the unchanged global hypotheses, comparable-pair checks and identity-competitor vetoes, not this cost preference alone.
- Log-scale gate 0.35 corresponds to torso-length ratio approximately 0.705...1.419. This is a 2D descriptor tolerance, not calibrated height, parent/child identity proof or an approved pose-distortion envelope.
- Recovery window 2 s and anchor comparison limit 1 s have different roles. Evidence can become unavailable after 1 s; that is never proof of competitor exclusion. It can interrupt an otherwise visible peer before the nominal recovery window expires.
- Ordinary uncertainty preserves confirmed history; repeated raw frames do not refresh lastConfirmedAt. Freshness 0.5 s can invalidate output while inference is blocked; actual deadline responsiveness must be measured later.
- Proposed adapter freshness rule, also requiring explicit approval: reuse the selected freshness value as the maximum capture-to-final-commit age; reject at age >= 0.5 s, as well as after an applied expiry watermark. This is a distinct check from core lastConfirmedAt expiry, not a gate the current B1 mailbox already enforces. It introduces no extra core policy field. A stale staged result must not commit history or acknowledge binding; assess this conservative age cap during device characterization.
- Duplicate ambiguities may require full rebind. Full-torso acquisition, strict mutual coverage and no automatic lost recovery impose real setup/restart costs. Option A is an observational policy, not a certificate against every hidden-joint completion or physical identity exchange.

## 5. D06 and other owner boundaries

No authoritative standalone D06 packet record was found in this staging checkout. Do not infer that its field-level freeze is complete.

Required D06 follow-up: remove any unconditional “resume increments controlRevision” rule; stop/interruption revokes and future authorization advances revision. Keep presentation status.sequence separate; require exact source/control compatibility and no-frame invalidation. Edo/Kevin must review the corrected fields in that separate work. Numeric B2b diagnostics do not depend on freezing avatar rendering.

Jevon receives the selected session v1 rule: pause outcomes on unavailable authoritative gameplay input, controlled resume for ordinary recovery, restart round after full rebind/generation/calibration invalidation. Jevon owns phases/GameClock and implementation review; Theo reviews comprehension. B2b must not implement this or conflate uncertain raw tracking with an already existing calibrated CP1 readiness result.

D04 calibration, D05 provider composition, E07/K03 avatar output, CP1 publication and gameplay remain separate. No additional CP1 reader or alternative identity/calibration authority is proposed.

## 6. Scoped WP-E02 implementation authorization checklist

All unchecked items are future gates, not work completed by this documentation task.

### Before code implementation

- [x] Inspect actual staging-based checkout and accepted B2a hashes.
- [x] Record Tech Lead-selected D02/D03 verbatim and distinguish session handoff from implemented behavior.
- [x] Specify every proposed experimental value and its synthetic provenance.
- [ ] Tech Lead separately authorizes scoped WP-E02 code/test changes.
- [ ] Review the exact shared source/control gate and staged state-commit API. Prove that revoke between final validation and state assignment cannot advance authoritative history; a publication Bool alone is insufficient.
- [ ] Define bounded requestID/current revision, idempotent duplicate behavior, revocation/exhaustion handling, real full-rebind sequence and exactly-once current-request acknowledgment.
- [ ] Define lifecycle-owned expiry/wakeup and immediate status invalidation independently of worker availability and view lifetime.
- [ ] Confirm numerical selection explicitly before active physical tracking. Controlled deterministic integration can use explicitly identified test policies without treating them as approved live defaults.

### Authorized-scope proposal, subject to that separate instruction

Potential modifications: `Shared/BodyTracking/Processing/MotionEngine.swift` for worker-local adaptation; `Capture/FrameStore.swift` for admitted lease/control stamping, sink integration and lifecycle gates; `Capture/CameraPoseResults.swift` for bounded accepted tracking/status publication; `Capture/CameraPipeline.swift` for the Edo control facade and lifecycle; existing `Games/LaserHeist/Debug/LiveInputDiagnosticsView.swift` for numeric controls/reporting; `App/AppDependencies.swift` only if retained policy/control composition requires it. Add focused tests in existing app test folders.

These are proposed paths under `Sedactive/`, not changes made here. Keep accepted PlayerTracker, PoseEstimator, CP1/CP2, renderer, gameplay and calibration unchanged. Any demonstrated need to expand that scope returns for review. No new packages, consumers, persistent raw history or per-frame tasks.

### Software evidence before merge/live activation

- [ ] Arm/duplicate/cancel/supersede races before admission, during copy, pending inference, and after evaluation but before commit; assert state-history freeze and no stale acknowledgment.
- [ ] Preserve original B1 metadata and observation count; never use candidate array IDs as PlayerIDs. Cover generation/epoch/geometry/orientation mismatch and duplicate/out-of-order time/frame rejection.
- [ ] Stop/background/interruption/failure invalidate without another frame; native resume remains disarmed. Verify actual capture restart/new generation for previously bound full-pair rebind; retained tracker guard survives controls.
- [ ] No-frame expiry watermark, delayed inference, deadline coalescing, and worker-unavailable cases; no synthetic frame or diagnostics polling dependency.
- [ ] Option A comparable-core positives/refusals, uncertainty/recovery dwell, latches/loss/overflow and independent unaffected peer; preserve all accepted safety regressions.
- [ ] One worker/consumer, existing raw 4 MiB / total 12 MiB bounds and reconstruction ownership, preview independence, cleanup on cancellation, bounded control/status storage.
- [ ] App/test Debug, Release and device-SDK builds; focused/full regression; complete strict concurrency/WAE/SIL/WMO/object and meaningful ownership-negative controls. Save fresh persistent source-corresponding artifacts.

### Physical characterization after numerical approval and software gates

Use the iPad Pro 13-inch M4, verifying actual installed OS/toolchain/device first. Record finite windows, requested/accepted policy version and source/build identity. Test empty/one/two people, parent/child-height differences, both arms/legs moving, partial bodies, overlap/crossing/order changes, third entrants and duplicate detections. Exercise explicit binding/ack/cancel, no-frame expiry, stop/restart/full rebind, permissions/background/interruption and geometry changes, including preview off/on comparisons.

Collect camera vs Vision vs confirmed-tracking cadence separately; state/reason/rebind counts, observation/mutual-core coverage and confidence summaries, age/inference/adapter latency, rejected source/control/late results, bytes/backpressure, process memory and thermal where measurable. Retain numeric summaries only; no imagery or joint-coordinate recordings. Label manual identity observations separately from automated counters. There is no preselected 30 FPS tracking requirement, production accuracy target or HIT/CLEAR acceptance in E02.

## 7. Readiness and verification for WP-E02A1

**Technical decision readiness: D02/D03 SELECTED AND LOCALLY RECORDED.**
**Implementation readiness: planned scope is compatible, but no implementation authorization is granted here; atomic gate/API proof remains a required integration gate.**
**Physical tracking activation: BLOCKED pending explicit experimental-value selection and fresh software evidence.**
**Session and avatar integration: separate owner handoffs; not blockers to the bounded diagnostic-control implementation.**

Checks in this task are source inspection, policy/validator arithmetic, decision-copy integrity, Markdown/link/field checks, accepted-source hashes and Git/file preservation. No app build, tests, compiler probe or physical run was performed for this documentation task. Historical B2a verification is not reused as new B2b evidence.

Skills applied: swift-architecture-skill (preserve existing deterministic state authority and minimal composition) and swift-concurrency (admission/commit/revocation ownership and stale-response analysis).

Expected task diff: only this proposal and the copied D02/D03 decision record. Architecture/workplan history, Swift/tests/project settings, primary architecture checkout and existing local/untracked files remain untouched. No commit, staging, push, PR, merge or branch switch.
