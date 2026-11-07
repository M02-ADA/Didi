# WP-E02A4 — Full-Rebind Lifecycle and Idempotence Correction

7 November 2026 · Edo · **READY FOR INDEPENDENT RE-REVIEW**

Scoped correction of the three WP-E02A3 findings. This is implementation/verification evidence, not independent acceptance, physical tracking validation, production parameter approval, live CP1, calibration, gameplay or avatar integration.

## 1. Baseline and scope

Checkout: `/Users/edwardgk/Desktop/APPLE/Sedactive-B2b`; branch `feat/live-player-tracking`; HEAD and available `origin/staging` remain `93254b097b1f44aac95c181077f38a59534632c6`. No refs were fetched or changed. Existing uncommitted A2 work, both decision documents, the A2 report and all earlier evidence were preserved.

Reviewed the actual source, D02/D03, A2 report and A3 findings before editing production. The source confirmed both defects: the source channel removed its background observer during cleanup, and completed restart deduplication depended solely on a discarded Task handle.

**A4-only delta** (line references in final source):

| File | Correction / principal references |
|---|---|
| [CameraPipeline.swift](../Sedactive/Shared/BodyTracking/Capture/CameraPipeline.swift) | Retained lifecycle wiring (233), sealed request facade (249), bounded/idempotent restart (265), private source-start authorization and reservation (328–361), async cutover checks (407–468). |
| [CameraPoseResults.swift](../Sedactive/Shared/BodyTracking/Capture/CameraPoseResults.swift) | Opaque request receipt; gate-owned command state; lifetime observation (275), background revocation (288), issuance (304), restart deduplication (329), atomic source reservation (347), final activation (361). |
| [LiveInputDiagnosticsView.swift](../Sedactive/Games/LaserHeist/Debug/LiveInputDiagnosticsView.swift) | Capture request at button intent before Task scheduling (106–123); protect old UI completion by its existing control token; historical coverage label (258). |
| [LivePlayerTrackingTests.swift](../SedactiveTests/Shared/BodyTrackingTests/LivePlayerTrackingTests.swift) | Preserve prior assertions with receipt-aware calls; controlled worker helper (579), correction suite (644–917), and 11 corrective definitions / 13 executions. |
| This report | Before/after semantics, failures, verification and preservation. |

FrameStore, MotionEngine/B2bExperimentalPolicyV1, PoseEstimator, accepted PlayerTracker/tests, CP1/CP2, calibration, gameplay, avatar/rendering, App composition, project/signing/compiler settings and generated resources have no A4 changes.

## 2. Root causes and before/after transitions

### Background during pending cleanup

**Before:** full rebind stopped the old source and finished CameraEventChannel, removing its background observer. The restart Task awaited worker cleanup. A background/foreground cycle in that interval did not revoke it; after cleanup it created and armed another source using the old request.

**After:** the existing gate observes application background/active notifications for its retained lifetime, independently of the per-source channel. Background synchronously revokes issued, restarting and active requests, advances control revision, clears current publication/ack and marks the application nonforeground under the same mutex. Foreground only changes availability; it never restores a request or increments authorization merely because of resume.

The native source channel still owns raw-source interruption/suspension behavior. NotificationCenter injection isolates tests while using the same production observation path. There is one capture facade and one control authority, not a second controller. Observer callbacks use weak capture; tokens are removed at gate destruction.

### Completed full-rebind duplicate

**Before:** the only duplicate check consulted bindingRestart. After that Task handle cleared, retrying the still-active request revoked it and started a new generation.

**After:** the gate retains the bounded request receipt and phase. A pending duplicate awaits the same Task; an active completed duplicate returns without stopping/starting, allocating a source, changing revision, clearing the ack, or touching worker state. This branch is independent of whether acquisition is waiting, bound or uncertain, so it cannot reset acquisition dwell. A genuinely new explicit receipt follows the real new-generation path.

### Historical coverage

**Before:** expiry could leave mutualCoreCount as diagnostic history while latest was unavailable, yet the UI called the count current.

**After:** the display says **Last accepted pair coverage**. The value remains history rather than a readiness certificate. The expired-state diagnostics test exercises actual model formatting after publication expires without another frame; no B2a or measurement policy changed.

## 3. Why opaque receipts are necessary and bounded

A UUID-only retry cannot distinguish a canceled old request from a new authorization without remembering every historical UUID. Such a growing ledger would violate the bounded requirement.

The existing gate now issues an immutable internal `CameraBindingRequest` containing readable requestID and a private monotonically advancing serial. Callers cannot construct/re-stamp a receipt from an old UUID. The gate retains one current receipt/phase and a scalar serial; a canceled old receipt fails even after later requests replace it. There is no UUID tombstone array or request-event history.

Internal facade usage:

1. `makeBindingRequest()` synchronously prepares a genuinely new intent and revokes/supersedes previous authorization.
2. Retain that exact receipt for retries; do not mint one on retry or after an asynchronous continuation.
3. `armBinding(request:)` or `requestFullRebind(request:)` submits it.
4. `cancelBinding()` revokes pending/active authorization; old receipts cannot reauthorize.
5. Create a fresh receipt only for a genuinely fresh explicit action.

This is an internal API hardening within D02's expressly reviewable API spelling, not a CP1 change or a new policy decision. Current production callers are the existing DEBUG controls and were updated. Future Jevon integration must retain the original receipt; no session source was changed.

**Issued** is not armed. **Restarting** permits cleanup and a future genuine source. **Active** is the current authorized request. **Revoked** cannot recover for that receipt. The request serial is not a camera generation, source frame ID, timestamp, admission controlRevision or D06 status sequence. Original frame stamps still carry the existing controlRevision unchanged in representation.

New intent issuance and revocation advance control revision. Native source transitions retain their existing revision behavior. Foreground alone does not advance it. Serial/revision exhaustion fails closed.

## 4. Revocation and asynchronous cutover argument

Restart revalidates the original receipt:

- Before cleanup.
- Immediately after cleanup returns.
- Before source identity allocation; the actual facade allocation runs synchronously under the gate.
- After camera permission status/request awaits.
- After waiting for a previous processing worker.
- Before entering the capture driver.
- After driver startup returns.
- Under the gate again when activating the request on the expected new context.

A background event during the missing-channel interval therefore revokes the receipt without waiting for the actor. Releasing the old worker cannot make it valid again: foreground never changes its phase/serial back. Final activation and current-request acknowledgment eligibility remain fail-closed.

Source identity reservation uses a nonescaping synchronous closure that only updates capture-owned UUID/epoch/geometry bookkeeping. No notification, observer callback, native API, await or inference runs inside that critical section. Background before reservation prevents allocation; background after reservation revokes subsequent activation. Generation creation remains in CameraPipeline, never in PlayerTracker.

The expected old-source shutdown during an explicitly authorized restart does not consume its future-run intent. Once the restart is attached to its new source, source invalidation revokes it. Background and explicit cancellation revoke regardless of source attachment.

Cancellation propagates to the single restart Task and the matching request. Its operation slot remains occupied until actual cleanup exits. Superseding can replace the gate's intent, but cannot allocate another restart Task while the previous slot is occupied. Old completion only abandons its matching receipt and only clears its matching operation token, so it cannot revoke a newer intent or clear a newer operation.

The DEBUG model creates the receipt synchronously at button handling, before scheduling its Task. Otherwise an old queued button action could incorrectly mint a fresh authorization after background/foreground. Its existing UI control token also prevents a late old completion from clearing newer UI work.

A native start already entered before revocation cannot be undone retroactively. The driver-return regression verifies that such a start cannot then arm; it is cleaned up. No forced SDK cancellation or immediate release of still-owned buffers is claimed.

## 5. Preserved safety boundaries

Artifact comparison proves these A2 sections remain byte-identical:

- CameraTrackingGate.finish: final validation, authoritative worker assignment, publication and ack critical section.
- Worker publication/synchronization and deadline scheduling/expiry/watermark section.

FrameStore is byte-identical to A2, including admission stamping, single processing consumer, raw ownership/reservation and preview isolation. MotionEngine and its 20 literal policy values are also byte-identical. No policy was tuned.

Accepted hashes remain:

| File | SHA-256 |
|---|---|
| PlayerTracker.swift | `4cc0a4a648e7250910303826bd5a3a14d27efea023d4f9ff861f094eff01fd34` |
| PlayerTrackerTests.swift | `906defbadd128ff938700367c6f829a06958bd52e5c28df761a3a007a13e8a75` |
| FrameStore.swift | `63a026688fcec17cf5e5fbd7a3a7af2dd7835915e420f916c2f803f8efb22397` |
| MotionEngine.swift | `cd50f4c58988c3e7f3dd999cb33381cf9881c3d17621a832c7f0b39d8c778b63` |

One retained native session, one Vision/processing worker and one mutable PlayerTracker remain. No additional image buffers, FrameStore consumer, calibration authority, CP1 consumer, per-frame Tasks or rendering output were added. Additional control state is fixed-size, with two lifetime observer tokens and one pending restart Task including canceled cleanup. The original pixel and descriptor bounds remain unchanged.

## 6. Before-fix execution evidence

Before production edits, three permanent regressions were executed against the actual A2 source in `BeforeFix.xcresult`:

| Definition | Before-fix result |
|---|---|
| backgroundDuringCleanupCannotRestartOrArmOldRequest | Failed: old request completed/restarted/armed after background. |
| completedFullRebindDuplicatePreservesSourceDwellAndAcknowledgment | Failed: duplicate changed driver counts/context/revision, cleared bound ack/latest. |
| expiredCoverageIsExplicitlyHistoricalInDiagnostics | Failed: historical label absent and old current label present. |

**3 definitions / 3 executions failed, zero skips.** This is actual runtime evidence, not an arithmetic prediction. A separate earlier `BeforeFixCompileFailure.xcresult` records a corrected test actor-property assertion and is not used as bug reproduction evidence.

`before-fix-tests.swift` preserves the original UUID API calls. Final tests use opaque receipts and private notification centers, retaining the original scenes and safety expectations. Existing B2b assertions were not removed or weakened; accepted B2a tests were not edited.

## 7. Final corrective regression coverage

All tests use actual CameraPipeline lifecycle/facade wiring with controlled permission/driver/worker boundaries and isolated NotificationCenters. Driver counts are controlled protocol invocations, not physical AVFoundation observations. The ack-preservation test forwards synthetic B1 observations through the actual CameraCopySink; it does not claim real Vision body detection.

| Corrective definition | Coverage |
|---|---|
| backgroundDuringCleanupCannotRestartOrArmOldRequest | Missing-source-channel interval, blocked cleanup, no restart/arm/ack, subsequent fresh request succeeds. |
| completedFullRebindDuplicatePreservesSourceDwellAndAcknowledgment | Completed retry preserves source/epoch, revision, driver start/stop counts, nonnil ack and full latest snapshot; a new receipt gets a new run. |
| expiredCoverageIsExplicitlyHistoricalInDiagnostics | Accepted coverage, expiry without a frame, actual DEBUG model label and unavailable tracking. |
| backgroundBeforeRestartTaskRunsRevokesReceipt | Background before queued facade operation begins. |
| backgroundAfterCleanupDuringPermissionCannotStartReplacement | Permission barrier after cleanup; no replacement driver call; fresh request later works. |
| backgroundAtDriverReturnCannotAuthorizeCompletedRestart | Background at driver return before final activation; already-entered start cannot arm. |
| staleCleanupCompletionCannotRevokeNewerRequest | Cancel, supersede and caller-Task cancellation variants; bounded pending slot, newer intent survives old completion, old receipt replay refused, raw cleanup. |
| pendingDuplicateSharesOneRestartTask | Two pending callers share one operation and one new source; no extra revision. |
| revokedReceiptCannotBeReplayedAfterLaterRequests | Canceled receipt stays invalid after later authorization. |
| queuedDiagnosticsButtonIntentCannotBecomeFreshAfterBackground | Actual model captures receipt before queuing, independent of view lifecycle observation. |
| revokedRestartCannotAllocateSourceIdentity | Revocation prevents the allocation closure from executing. |

No arbitrary sleeps were added. Continuations, actor barriers, source status and worker completion drive the races. Existing B2a ambiguity, lost/rebind, same-frame commit, coverage, provenance and memory tests remain intact.

## 8. Actual final verification

| Gate | Definitions | Executions | Result |
|---|---:|---:|---|
| A4 correction suite | 11 | 13 | Passed |
| All B2b suites (A2 + A4) | 40 | 55 | Passed |
| Unchanged B2a suite | 95 | 187 | Passed |
| Focused combined | 135 | 242 | Passed |
| Full current staging-based regression | 366 | 580 | Passed |
| Debug app/test build | — | — | Passed |
| Release Simulator build | — | — | Passed |
| Unsigned iOS SDK build | — | — | Passed; no deployment |

Final focused/full bundles have **zero failures and skips**, verified by reopening with xcresulttool and inspecting per-suite test trees. Counts distinguish definitions from parameterized executions.

Both-SDK strict/WAE gates passed: production WMO SIL, production WMO object, testable module and Shared-test WMO SIL. All six ownership negatives rejected with expected data-transfer/isolation diagnostics. Complete checking covers Shared, AppDependencies, existing DEBUG diagnostics and delegate probe; complete-target app builds are separate evidence. No unsafe Sendable, nonisolated(unsafe), preconcurrency suppression or weakened compiler flags were added.

Xcode 26.6 (17F113), Swift 6.3.3, SDK 26.5; Simulator iPad mini (A17 Pro), iOS 26.5, destination `1E1C6B07-B356-4303-8756-4C0D2A4CDF05`. Explicit DEVELOPER_DIR selects installed Xcode without changing the system selection. A test-only missing inner try was corrected; its failed compiler logs are retained separately from final results.

## 9. Persistent evidence and source identity

Fresh root:

`/Users/edwardgk/LaserHeistReviewArtifacts/WP-E02A4/run-2026-11-07-fc228da0/`

Retained and readable:

- BeforeFix.xcresult, Focused.xcresult, Regression.xcresult, command/log files and reopened summaries/test trees.
- Debug/Release/unsigned iOS logs and command JSON; verify-builds.py and build-test-results.json.
- Both-SDK strict command/log/SIL/object artifacts, verify-strict.py, strict-results.json and six negative sources.
- before/ A2 source snapshots; before-fix-tests.swift; final/ source/config/report snapshots.
- A4-only.diff against the saved uncommitted A2 baseline; final-head.diff for cumulative Git changes.
- final-source-hashes.json, preserved-critical-sections.json, preservation.json, final-git-status.txt.
- artifact-reopen.json and artifact-manifest.json with source-corresponding readable-file hashes.

Only final-named bundles establish current verification; initial-pass and compiler-failure artifacts are iteration history. Earlier A2 and A3 evidence was not overwritten, renamed or relabeled. Build/cache directories are retained outside Git and excluded from the manifest's bulky-cache scan.

## 10. Git status and remaining limitations

A4 changes only the three production files, existing integration test file and this new report. The cumulative working tree still includes earlier A2 changes to FrameStore/MotionEngine and earlier untracked decision/report files:

```text
 M Sedactive/Games/LaserHeist/Debug/LiveInputDiagnosticsView.swift
 M Sedactive/Shared/BodyTracking/Capture/CameraPipeline.swift
 M Sedactive/Shared/BodyTracking/Capture/CameraPoseResults.swift
 M Sedactive/Shared/BodyTracking/Capture/FrameStore.swift
 M Sedactive/Shared/BodyTracking/Processing/MotionEngine.swift
?? Docs/LaserHeist-D02-D03-Tech-Lead-Decision-V1.md
?? Docs/WP-E02A1-Experimental-Tracking-Policy-Proposal.md
?? Docs/WP-E02A2-Live-Tracking-Integration-Report.md
?? Docs/WP-E02A4-Lifecycle-Correction-Report.md
?? SedactiveTests/Shared/BodyTrackingTests/LivePlayerTrackingTests.swift
```

File-hash preservation verifies no other existing file changed. Primary feat/architecture remains at `7cab6121eea5351b3b2a51256c9d433cb2d497dd`, including unchanged untracked Scripts/CP2Spike. Git whitespace/scope checks pass. No staging, commit, push, merge, reset, branch/worktree operation or PR occurred.

Independent re-review must assess the receipt state machine, lifecycle cutovers, guarded old completion and unchanged final commit/expiry contracts. Future consumers must retain receipts rather than reconstruct requests from UUIDs. This internal API requires review at the later session handoff; no Jevon interface was changed here.

No physical device run, real identity accuracy, performance/thermal benchmark, production threshold selection, calibration, live CP1, gameplay or avatar acceptance is established. Stalled SDK work remains resource-owned until it exits; immediate revocation does not promise immediate SDK termination. D02/D03 policy is unchanged.

Skills applied: swift-concurrency, swift-architecture-skill and swift-testing-expert. Stop after the correction/report; physical testing and acceptance remain separately authorized.
