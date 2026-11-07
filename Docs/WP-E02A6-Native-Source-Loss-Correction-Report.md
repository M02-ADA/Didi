# WP-E02A6 — Native Source-Loss Authorization Correction

7 November 2026 · Edo · **READY FOR INDEPENDENT RE-REVIEW**

This is a scoped diagnostic B2b correction, not independent acceptance. D02/D03, accepted B2a Option A and all 20 approved experimental policy values remain unchanged. No physical testing, calibration, live CP1, gameplay or avatar work was performed.

## 1. Exact baseline and changed files

Checkout: `/Users/edwardgk/Desktop/APPLE/Sedactive-B2b`; branch `feat/live-player-tracking`; HEAD and available `origin/staging`: `93254b097b1f44aac95c181077f38a59534632c6`. These are locally available references; no fetch or ref mutation was performed. All pre-existing uncommitted A2/A4 work, decision records and reports were retained.

Read the current D02/D03 decision, A2/A4 reports, A5 findings, actual source and tests before modifying production. Applied the Swift concurrency, architecture and Swift Testing skills, retaining Swift 5/default MainActor/Approachable Concurrency project settings.

**A6-only changes:**

| File | Change / final source reference |
|---|---|
| `Sedactive/Shared/BodyTracking/Capture/CameraPoseResults.swift` | Add exact-source unexpected-loss revocation, `sourceLost` at line 257. No retained state added. |
| `Sedactive/Shared/BodyTracking/Capture/CameraPipeline.swift` | Native interruption/stopped/failure/overflow routing at lines 158–173; exact-receipt pre-attachment failure revocation at line 395; direct failure revocation before native teardown at line 507. |
| `SedactiveTests/Shared/BodyTrackingTests/LivePlayerTrackingTests.swift` | Append controlled A6 helpers and `LiveTrackingNativeSourceLossTests` at line 968: 9 definitions / 14 executions. Existing A2/A4 assertions remain byte-identical. |
| This report | Root cause, lifecycle proof, fresh verification, hashes and preservation. |

FrameStore, MotionEngine/policy, PoseEstimator, accepted PlayerTracker/tests, DEBUG UI, CP1/CP2, calibration, gameplay, avatar/rendering, project/signing/compiler settings and generated resources have no A6 changes.

## 2. Root cause and production-call review before the fix

A4's generic `CameraTrackingGate.invalidate` retained an `.issued` receipt and retained `.restarting` while retiring its old generation. This preservation was needed for intentional full-rebind cleanup. Native source events reached that same generic path through FrameStore, however, so a pre-event issued receipt survived an unexpected source loss. The control revision advanced, but validation of the opaque command/serial/phase still accepted the old receipt. The actual DEBUG button correctly captured its receipt synchronously; the queued Task subsequently submitted that still-valid old intent and restarted/armed a new generation.

The defect was not in atomic final commitment or B2a association. It was incomplete receipt revocation before the queued operation entered its restart path.

Reviewed all production invalidation routes:

- `CameraEventChannel.emit`: native interruption/stopped suspend, native failure ends, overflow terminates.
- `CameraPipeline.fail`: permission/configuration/runtime/processing failure handling, with asynchronous native teardown.
- `stopCapture`: explicit owner-controlled source retirement used during authorized restart.
- Public `stop`: explicitly cancels binding before retirement.
- Startup cancellation/teardown and deinit: existing source cleanup; receipt cancellation/matching-operation protection remains.
- FrameStore begin/end/suspend/resume: existing exact-source admission, raw pose, preview and worker ownership lifecycle.
- Receipt validation at submission, restart preparation, cleanup/permission/worker/driver cutovers, source reservation and final activation.

No source/event metadata extension was needed. Native event channels already carry original generation/epoch/geometry context, and the gate already owns the current context and opaque receipt.

## 3. Before-fix executable evidence

Before editing production, appended the two permanent reproduction definitions and ran them against unchanged A4 production source on the verified available iPad mini (A17 Pro), iOS Simulator 26.5, UUID `1E1C6B07-B356-4303-8756-4C0D2A4CDF05`.

`BeforeFix.xcresult`: **2 definitions / 5 executions failed**, zero skips, 21 recorded assertion issues; xcodebuild exit 65. The assertions demonstrated replacement generations/driver starts and nonnil old authorization, not a compilation failure.

- `issuedReceiptCannotSurviveNativeLoss`: interruption, geometry failure and stopped event through the actual CameraPipeline/source event channel.
- `queuedDiagnosticsIntentCannotSurviveNativeLoss`: interruption and geometry failure through the actual DEBUG model button-intent path.

The receipt is captured and the Task queued while on MainActor, then the native event is synchronously delivered before yielding. This deterministic ordering needs no sleeps. Saved `before-fix-tests.swift`, original production snapshots in `before/`, command, log, result bundle and reopened summaries preserve the failing source/evidence separately.

## 4. Source-event and receipt-phase transition table

| Event and source relationship | Prior phase | A6 transition and revision | Publication / continuation |
|---|---|---|---|
| Unexpected native loss on exact current context | issued | revoked; advance once | Clear current result/ack/deadline; queued receipt submission fails. |
| Unexpected native loss before intentional retirement | restarting | revoked; advance once | Cannot reserve/start/activate replacement from that receipt. Restart pending is not a bypass. |
| Unexpected loss on replacement/current context | restarting or active | revoked; advance once | No final activation or late acknowledgment; existing cleanup follows. |
| Repeated loss on already-inactive, already-revoked source | revoked | Remains revoked; no extra advance | No resurrection or revision churn. |
| A genuinely fresh intent was issued while source remains suspended, then another loss occurs | issued | revoked; advance once despite inactive raw source | Fresh intent cannot survive a later authority loss. |
| Authorized old-source retirement via `stopCapture` / FrameStore.end | restarting for old generation | Preserve replacement receipt; existing retirement revision applies | Cleanup may complete and new real source may be authorized. |
| Delayed event from retired source | any newer request phase | No change to newer context/revision | Closed channel ignores it; gate also checks exact source atomically. |
| Foreground or native same-generation resume | revoked | No reauthorization or unconditional revision advance | Fresh explicit intent remains required. |
| Explicit stop / background | issued/restarting/active | Existing explicit revocation paths retained | No old queued submission can arm. |
| Replacement permission/configuration failure before FrameStore attaches | restarting | Revoke only matching receipt before awaiting teardown | Old completion cannot revoke a superseding receipt. |

Native `.stopped` conservatively counts as loss even if subsequent native readiness inspection finds raw capture running; this preserves the pre-existing disarm behavior for active requests and extends it to pending intent.

## 5. Linearization and intentional-cleanup preservation

`sourceLost(context)` acquires the existing gate mutex, checks the exact current context, changes the command phase to revoked, advances control revision when authority/intent changed, clears current publication/ack and marks source authority inactive. It yields the existing coalesced wake without waiting for Vision. Context comparison and receipt revocation are one critical section.

If loss wins before a queued submission, validation rejects it. If restart preparation wins but the old source has not been intentionally retired, native loss still revokes `.restarting`. Existing checks reject it before allocation or activation. If final tracking commitment wins first, subsequent loss acquires the same gate and clears publication/ack; if loss wins first, final validation fails without assigning staged tracker state.

Intentional retirement does not call `sourceLost`. The existing `stopCapture` retires source ownership with FrameStore.end, finishes the old event channel, and only then awaits the driver and worker. Its future-run receipt remains valid under the existing A4 generic retirement rule. The replacement uses the existing capture-owned generation/epoch allocation and final receipt/context checks. A native event before that retirement is unexpected and revokes; an old event after retirement cannot affect the replacement. There is no generic exemption for all events while rebind is pending.

The event channel first checks its closed flag. The new gate operation independently checks generation/epoch/geometry context under the mutex. FrameStore also checks source identity. Thus a closed old channel or an old callback that races with newer attachment cannot revoke the newer context. A new explicit receipt issued after synchronous loss is not retroactively stamped onto old work.

For permission/configuration failure before replacement FrameStore.begin, the gate has no attached new source context yet. The existing start operation already holds its exact receipt and facade context, so its failure catch now abandons that matching receipt before awaiting native teardown. The gate's matching-command check prevents old failure completion from revoking a newer intent. A controlled teardown barrier tests this timing.

### Isolation, locks and bounds

No actor, Task, timer, lock, queue, receipt registry or history was added. The native channel can call the Sendable gate synchronously. It releases the gate before entering FrameStore; there is no new nested gate-to-FrameStore lock edge. Direct failure handling also revokes before teardown. Existing FrameStore-to-gate nesting and the synchronous reservation closure are unchanged; callbacks do not suspend or reenter the gate.

The existing `finish` implementation, worker synchronization/publication and expiry/watermark section are byte-identical to A4. One CameraPipeline, FrameStore consumer, Vision worker and worker-owned authoritative PlayerTracker remain. Staged copies remain disposable transactions. No numerical policy, source stamp or raw resource ownership changed. Rejected staged inference cannot advance authoritative history.

## 6. Permanent regression coverage

| Definition | Executions / assertion focus |
|---|---|
| issuedReceiptCannotSurviveNativeLoss | 3: interruption/failure/stopped; exact +1 native-loss revision, receipt validation refusal, unchanged source/no replacement start, no arm/ack/latest. |
| queuedDiagnosticsIntentCannotSurviveNativeLoss | 2: actual DEBUG model plus actual native path, without UI lifecycle help. |
| unexpectedLossWhileRestartPreparedRevokesBeforeRetirement | 1: controlled restarting-before-retirement gate phase, actual event channel; no source-reservation closure runs. |
| intentionalRetirementAndLateOldEventsPreserveNewAcknowledgment | 1: real full rebind, original +3 retirement/begin/activation revision, atomic pair acknowledgment, old channel events and direct stale-context gate defense; completed retry preserves source/ack/revision/driver counts. |
| nativeResumeDoesNotRestoreIssuedReceiptAndFreshIntentCanRebind | 1: actual facade event handling/resume with observer barrier; no revision advance on resume, old receipt fails, a fresh request gets a new real generation, old replay still fails. |
| issuedReceiptStillRevokesThroughExistingLifecycleControls | 2: Stop and background; original queued intent refused, exact existing +2 revision behavior, no replacement. |
| repeatedLossRevokesNewPendingIntentEvenWhileSourceAlreadySuspended | 1: new pending intent revoked by subsequent loss, repeated already-revoked loss is idempotent. |
| replacementNativeLossCannotActivateRestart | 2: interruption/failure at replacement driver return; no final arm/ack, receipt revoked and source cleanup. |
| preAttachmentFailureRevokesExactReceiptBeforeAwaitingTeardown | 1: permission denial before attachment, native teardown held; receipt already revoked, exact retirement+revoke revision, no replacement driver start. |

Private phase representation is not exposed for tests: stale receipt/restart validation, denied reservation and resulting source/control/publication behavior establish revocation. No production test-only phase API was added.

All 11 A4 definitions / 13 executions passed unchanged, including blocked cleanup, cancel/supersede/caller-cancellation, bounded operation ownership and canceled receipt replay. Existing blocked-inference revocation/expiry, age-boundary, Option A, admission stamp, preview independence and cleanup tests also passed unchanged.

## 7. Fresh verification results

| Gate | Actual result |
|---|---|
| Before-fix reproductions | 2 definitions / 5 executions failed as intended; preserved separately. |
| Corrected A6 suite (`Native.xcresult`) | 9 definitions / 14 executions passed; zero failures/skips. |
| Focused B2b + B2a (`Focused.xcresult`) | 144 definitions / 256 executions passed; zero failures/skips. |
| Accepted unchanged B2a subset | 95 definitions / 187 executions passed. |
| Prior A4 subset | 11 definitions / 13 executions passed. |
| Full staging-based regression (`Regression.xcresult`) | 375 definitions / 594 executions passed; zero failures/skips. |
| Debug app/test build-for-testing | Passed. |
| Release Simulator build | Passed. |
| Unsigned iOS SDK Debug build | Passed; no device installation/testing. |
| Both-SDK complete strict concurrency / warnings-as-errors | Passed; production SIL/WMO/object, testable module and Shared-test SIL/WMO gates. |
| Six ownership negatives | Rejected as intended: mutable CV workspace alias, mutable Vision workspace alias, actor-isolated native delegate, on each SDK. |
| Diff whitespace / scope | `git diff --check` passed; only the three listed existing files and this new report differ from the A6 baseline. |

Strict gate scope: all Shared sources, AppDependencies, DEBUG diagnostics and native-delegate probe; all Shared tests compiled against the testable module. Full app builds separately cover standard target compilation. No claim of a new strict audit of unrelated production rendering. Swift language/default-isolation/project flags were not changed. Commands and actual diagnostics are retained, including expected negative diagnostics.

## 8. Persistent evidence and source identity

Evidence root:
`/Users/edwardgk/LaserHeistReviewArtifacts/WP-E02A6/run-2026-11-07-dd1530fc/`

Contains `BeforeFix.xcresult`, `Native.xcresult`, `Focused.xcresult`, `Regression.xcresult`, logs/commands, original and final snapshots, `A6-only.diff`, cumulative final diff, strict commands/results, source hashes, preservation checks and `artifact-manifest.json`. All four actual bundles were reopened using xcresulttool after execution. The manifest is verified by reading files from this persistent location; build/module caches are excluded. Large artifacts are not stored in Git.

All runs are fresh A6 execution, not relabeled A2/A4 successes. Earlier evidence directories remain unchanged. No captured camera image or personal joint recording was saved; tests use synthetic numeric fixtures and bounded synthetic pixels.

| File | Final SHA-256 |
|---|---|
| `Sedactive/Shared/BodyTracking/Capture/CameraPipeline.swift` | `2ff4d711ada3cf15dd9210e3f89cd9dc04ed824cc8ca3c25592d36fa7763459f` |
| `Sedactive/Shared/BodyTracking/Capture/CameraPoseResults.swift` | `9ab4f7d24f8bf34e3f61c20c7c4a2cba92a1624ed9eef02390a185b6f820b0e1` |
| `SedactiveTests/Shared/BodyTrackingTests/LivePlayerTrackingTests.swift` | `1895cce3c1df3b413fee112739123cbacf2ed23a982f263918758daeac782a37` |
| `Sedactive/Shared/BodyTracking/Capture/FrameStore.swift` | `63a026688fcec17cf5e5fbd7a3a7af2dd7835915e420f916c2f803f8efb22397` |
| `Sedactive/Shared/BodyTracking/Capture/PoseEstimator.swift` | `790b50cd8fe6c41b962217b73d1567fc8ea74f729e2c419eceb755b4bd3992bc` |
| `Sedactive/Shared/BodyTracking/Processing/MotionEngine.swift` | `cd50f4c58988c3e7f3dd999cb33381cf9881c3d17621a832c7f0b39d8c778b63` |
| `Sedactive/Shared/BodyTracking/Processing/PlayerTracker.swift` | `4cc0a4a648e7250910303826bd5a3a14d27efea023d4f9ff861f094eff01fd34` |
| `SedactiveTests/Shared/BodyTrackingTests/PlayerTrackerTests.swift` | `906defbadd128ff938700367c6f829a06958bd52e5c28df761a3a007a13e8a75` |

## 9. Git preservation and disposition

The primary `/Users/edwardgk/Desktop/APPLE/Sedactive` architecture checkout, its refs and untracked `Scripts/CP2Spike/` remain untouched. Baseline/final file hashes and status are recorded in the external preservation check. All pre-existing B2b decision/report files, DEBUG UI changes, signing/project configuration, untracked files and unrelated sources remain unchanged relative to the A6 starting snapshot. A2/A4/A5 manifests were rechecked without rewriting historical evidence.

Final working-tree status (includes earlier A2/A4 work, not all introduced by A6):

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
?? Docs/WP-E02A6-Native-Source-Loss-Correction-Report.md
```

No stage, commit, push, merge, rebase, reset, clean, branch switch, new worktree, PR or physical-device run occurred.

**READY FOR INDEPENDENT RE-REVIEW.** A separate reviewer should check native loss versus intentional retirement, exact-context stale callback guards, pre-attachment matching-receipt teardown, preserved final commit/expiry critical sections and source-corresponding execution evidence. This correction is not B2b acceptance or merge permission.

Remaining limitations: native SDK work can remain blocked and retain its owned resources until it exits; revocation does not promise immediate SDK cancellation. Tests do not exhaust every possible scheduler interleaving. Actual two-person identity accuracy, operational threshold tuning, latency/thermal/device performance, calibration, live CP1, gameplay and avatar integration remain unvalidated and separately authorized.
