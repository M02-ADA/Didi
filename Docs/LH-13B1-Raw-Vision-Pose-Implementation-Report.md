# LH-13B1 — Bounded Raw Vision Pose Extraction

5 November 2026 · Owner: Edo · Branch: `feat/vision-pose`.

**Final disposition: ACCEPTED — bounded raw multi-person Vision extraction (LH-13B1) only.** The original REVIEW disposition is retained as history; §11 records the final technical acceptance audit on 5 November 2026. This is raw pose extraction, not stable player tracking, standing calibration, calibrated body evidence or gameplay readiness. LH-13B2 is not authorized by this report.

## 1. Actual baseline and scope

Starting HEAD: `c45f8cd13b9880cc62a261a03d92b1f6d6b4aa0a`, the merge of camera-foundation PR #18. The existing feature branch, local `origin/staging` and a read-only `git ls-remote origin refs/heads/staging` query all matched that commit before editing. No branch/worktree was created or switched and no fetch, merge or rebase was performed.

Inspected AGENTS, TEAM_ALIGNMENT, the game-oriented architecture, the LH-13 proposal, A1 and both A2 reports including the final ACCEPTED addendum, CP1 models/provider, capture source/worker/metrics, DEBUG diagnostics and relevant tests. Actual code takes precedence over old proposal skeleton/status tables. Camera/preview infrastructure and CP1/CP2 are implemented. PoseEstimator, PlayerTracker, MotionEngine and CalibrationSession started as skeletons; only PoseEstimator is implemented in B1. LH-22 standing calibration remains unimplemented.

Entry working tree had only preserved untracked `Scripts/`. During device verification an external app signing-team edit appeared in `.pbxproj` (LG4M4S46YZ → PVFTHNYZFD). This task did not make or revert that edit. Successful signed verification uses the configuration then present; it is not part of the B1 source change.

## 2. Exact source/test changes

Paths below are repository-relative.

| File | Change |
|---|---|
| `Sedactive/Shared/BodyTracking/Capture/PoseEstimator.swift` | Implement synchronous real Vision adapter, explicit joint-name mapping, immutable numeric adapter and internal result envelope. |
| `Sedactive/Shared/BodyTracking/Capture/CameraPoseResults.swift` | New one-result, context/token/order-protected store and bounded numeric statistics; no image resources, stream or gameplay subscriber. |
| `Sedactive/Shared/BodyTracking/Capture/FrameStore.swift` | Tie raw result invalidation to existing begin/end/suspend/resume. Extend the existing reconstruction sink with worker-confined Vision; scope reconstruction writes before inference. |
| `Sedactive/Shared/BodyTracking/Capture/CameraPipeline.swift` | One default-sink wiring change: supply `store.poses` alongside existing metrics. Native camera ownership/lifecycle code unchanged. |
| `Sedactive/Games/LaserHeist/Debug/LiveInputDiagnosticsView.swift` | Add numeric-only raw candidate/joint/confidence/provenance, inference cadence/latency and rejection/failure readings through existing refresh. |
| `SedactiveTests/Shared/BodyTrackingTests/PoseEstimatorTests.swift` | New numeric adapter/result-gate suite and deterministic reconstruction/slow-worker/failure tests with test-only detector injection. |
| `Docs/LH-13B1-Raw-Vision-Pose-Implementation-Report.md` | This report. |

MotionEngine, PlayerTracker, CalibrationSession, CameraCaptureMetrics, preview implementation, CP1/CP2 models/provider/replay/fixtures, App composition, Kevin's renderer and Jevon's gameplay/session are unchanged. No package, target, persistent setting or framework-ownership layer was added.

## 3. Actual processing architecture

```text
one retained capture session / explicit nonisolated delegate
  → original bounded independent Data source copy / latest FrameStore mailbox
  → existing single processing lease and loop
  → CameraCopySink actor: private single-buffer reconstructed CV workspace
  → scoped write/copy/unlock → synchronous worker-local PoseEstimator
  → VNImageRequestHandler(.up).perform([VNDetectHumanBodyPoseRequest])
  → numeric observations → existing immutable PoseFrame + exact internal source envelope
  → one latest CameraPoseResults value / bounded statistics
  → existing DEBUG numeric refresh (no stream or additional status observer)
```

The default CameraPipeline sink uses real inference. Reconstruction-only sink mode remains explicit for existing capture tests; inference failure never silently switches production to a mock or copy-only path. A small synchronous `CameraPoseDetecting` seam permits immutable/test-controlled observations; its factory creates the non-Sendable detector inside the worker actor. Test implementations are only in the test target.

The installed iOS 26.5 SDK and compiler verify `VNDetectHumanBodyPoseRequest`, `VNImageRequestHandler(cvPixelBuffer:orientation:options:)`, `perform(_:)`, typed `results`, `recognizedPoints(.all)` and typed body-joint names. The 2D body-pose API is available from iOS 14. No hand-pose maximum-count API, 3D pose API, largest-person filter or persistent Vision identity is assumed.

Each inference uses a scoped handler/request and autorelease pool; handler, request, observations and reconstructed CV storage remain in the synchronous worker scope. Only numeric values leave it. Reconstruction's write lock is balanced and released before Vision reads the buffer. The pool buffer stays retained until inference/point extraction completes; reset releases the detector and pool only after worker completion.

### Candidate and joint policy

- `PoseEstimator.maximumCandidates = 8` is a finite B1 retained-value default, not a two-player selection or detection guarantee. All returned observations are counted. At most the first eight SDK-returned observations are converted; an excess is visible as observation count greater than retained count. There is no size sorting or largest-person selection. This cap bounds application-owned result values, not Vision's internal allocations.
- `candidateID` is an index **within that frame only**, as permitted by PoseFrame. Its reuse/reordering has no player-identity meaning. There is no PlayerID assignment or tracking in B1.
- Map all **14 existing BodyJoint cases**: nose, eyes, ears, neck, shoulders, wrists, hips and ankles. The SDK also has joints not represented by the approved model, such as elbows/knees/root; no CP1 fields were added to carry them.
- Preserve Vision's anatomical names, normalized bottom-left X/Y and finite positive confidence. Positive low-confidence points remain raw values, not approved reliable evidence. Zero confidence, nonfinite or out-of-range points are omitted; absent joints remain absent dictionary entries, never fabricated `(0,0)` points. A real `(0,0)` point with positive valid confidence is not rejected merely for being zero.
- Masks and all head/foot boundary estimates remain nil/unavailable. No crown/sole, airborne, squat-form, calibration or verdict is inferred.

## 4. Source, ordering and coordinate invariants

`CameraPoseResult` holds the original complete `CameraFrameMetadata` plus PoseFrame, observation count and invalid-returned-joint count. Metadata includes session generation, internal epoch, original capture-sequence frameID, host-clock capturedAt, geometry revision, source dimensions/stride/format, applied rotation and mirror state. PoseFrame receives its existing matching fields; epoch/orientation remain capture-internal without modifying CP1.

Capture already rotates pixels upright and enforces unmirrored output. Vision receives `.up`; applying the numeric 0°/180° capture angle again would rotate twice. Conversion rejects mirrored or unsupported portrait provenance and preserves coordinates without display reflection. Existing Kevin-approved DEBUG transform and preview remain unchanged. B1 adds no skeleton or image/pose overlay, and the latest numeric pose is not presented as the displayed preview's matching source frame.

The result store is independent of raw storage and has one current immutable result, not a pose history or replacement for CP1 delivery. Future calibrated publication must run through the reviewed per-source processing/provider path, not a DEBUG polling timer. Before inference it issues a source/context ticket with increasing frameID. Completion checks its exact token/context/source metadata, frame-to-source correspondence, order, monotonic valid times and cancellation. Stop/failure/suspension clears compatible output without another frame. Resume/context replacement changes its token; old results cannot reappear even on same-context resume. Duplicate/older or wrong-context completions are rejected; an old failure cannot wipe a newer successful result. No completion adopts a newer frame's metadata.

No arbitrary production freshness timeout was added. Slow compatible results retain their actual capture time and visible age; source/context/order staleness and cancellation are rejected. Consumers must not mistake old numeric observations for fresh gameplay evidence.

## 5. Ownership, boundedness and cancellation

Exactly one AVCaptureSession and one FrameStore processing consumer remain. Raw limits are unchanged: 4 MiB per source, 12 MiB total raw copies, one construction/latest pending/processing topology, and final-owner accounting across stop. The existing reconstruction pool retains at most one checked-out buffer under its separate 4 MiB cap. Optional DEBUG preview keeps its independent 12 MiB / three-backing budget and 5 Hz cap. Vision does not acquire preview images, and preview does not consume the primary worker.

There is no per-frame Task, request queue, extra historical raw-frame cache, source CV transfer, VN-object transfer or second CP1 reader. When inference is slow, capture's existing latest-pending replacement policy handles pressure. Vision's own model/cache/framework allocations are outside the explicit pixel ledger and must be measured as process memory, not claimed covered by the 28 MiB configured raw/workspace/preview ceiling.

Synchronous Vision inference is not forcibly reclaimed or replaced on cancellation. Stop invalidates publication immediately, then the existing lifecycle waits for the in-flight worker to return and reset. A never-returning framework call can delay awaited shutdown/restart; it does not spawn unlimited replacement workers or free a live buffer. Physical stop responsiveness must be measured. No cross-thread request cancellation shortcut or unsafe sendability is introduced.

Complete strict checking uses Swift 5 with existing default MainActor, approachable-concurrency flags and MemberImportVisibility. Both device and Simulator pass warnings-as-errors SIL/WMO, object/WMO and test SIL compilation. The production delegate is also registered/invoked from an explicitly nonisolated positive probe. Retained mutable CV workspace, actor-isolated delegate and retained mutable Vision-request workspace negative controls are rejected for their intended ownership diagnostics on both SDKs (**six expected rejections**). No unchecked Sendable, unsafe isolation, preconcurrency suppression or project migration was used.

## 6. Deterministic verification

Focused B1: **11 definitions / 18 executions, 0 failures, 0 skips**, two suites (`PoseEstimatorTests`, `RawPoseWorkerTests`).

Coverage includes zero/one/two/four/twelve detected observations and explicit candidate truncation; reordered candidates without stable identity; missing, zero-confidence, nonfinite and out-of-range joints; preserved low confidence, anatomical names and canonical corners; source ID/time/dimensions/epoch preservation; unsupported source presentation; duplicate/older/spoofed results and stale failure callbacks; generation, epoch, geometry and same-context resume invalidation; no-frame Stop; actual synthetic CV reconstruction/readback; inference failure without fallback; slow synchronous inference with one processing owner and latest pending source; cancellation while the source/workspace remains pinned; final release/reset; and preview independence.

The slow test uses a controlled test-only synchronous gate to model a blocking Vision call, while the async test awaits entry without sleeping. It admits twenty further source frames, observes nineteen replacements, retains two current raw owners and at most three peak owners, then invalidates/cancels and proves eventual zero raw/workspace bytes only after releasing the gate. Test-only detectors return immutable numeric fixtures; these tests do **not** demonstrate actual Vision detection accuracy or performance.

Existing source-copy, padded-row, clock conversion, context/lifecycle, preview provider-lifetime and CP1/CP2/gameplay tests are preserved and run in the full suite.

## 7. Build and test results

Environment: Xcode **26.6 (17F113)**, Swift **6.3.3**, iOS/iPhoneSimulator SDK **26.5**, deployment **26.5**, Swift **5**, default MainActor / approachable concurrency unchanged. Simulator: iPad mini A17 Pro 26.5, UUID `1E1C6B07-B356-4303-8756-4C0D2A4CDF05`.

| Verification | Actual result |
|---|---|
| Final Simulator app build | PASS |
| Simulator test-target build | PASS |
| Focused B1 run | PASS: 11 definitions / 18 executions |
| Full Simulator regression | PASS: **180 definitions / 273 executions in 24 suites; 0 failures/skips** |
| Complete concurrency / WAE SIL+object WMO | PASS, device and Simulator SDKs; expected negatives rejected |
| Release Simulator build | PASS; DEBUG numeric presentation excluded |
| Unsigned iOS-device compile/link | PASS; not a deployable or physical execution claim |
| Initial signed device builds | Failed for missing configured LG4M4S46YZ account/profile, including a provisioning-update attempt. No project edit was made to bypass this. |
| Signed device build after external signing edit | PASS using current PVFTHNYZFD configuration; installation on M4 succeeded |
| Swift compiler/concurrency warnings | None in successful checks/builds. Existing AppIntents metadata-extraction warning remains, not a concurrency warning. |
| Membership/resources | 59 unique app / 29 unique test Swift entries; no test source in app. Four replay JSON resources occur once each with exact source bytes in the installed tested Simulator bundle. |
| Preservation/whitespace | Intended files only, plus preserved external signing edit; `git diff --check` passes. |

The merged staging baseline contains additional gameplay tests beyond A2's historical 145/223. This B1 result is the actual current suite, not a claim that all test-count growth is caused by B1.

### Commands and evidence

All commands use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```bash
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/lh13b1/Derived SWIFT_STRICT_CONCURRENCY=complete build

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/lh13b1/Derived SWIFT_STRICT_CONCURRENCY=complete build-for-testing
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/lh13b1/Derived \
  -resultBundlePath /private/tmp/lh13b1/Focused.xcresult \
  -only-testing:SedactiveTests/PoseEstimatorTests \
  -only-testing:SedactiveTests/RawPoseWorkerTests \
  SWIFT_STRICT_CONCURRENCY=complete test-without-building
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/lh13b1/Derived \
  -resultBundlePath /private/tmp/lh13b1/Regression.xcresult \
  SWIFT_STRICT_CONCURRENCY=complete test-without-building

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/lh13b1/ReleaseDerived SWIFT_STRICT_CONCURRENCY=complete build

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS,id=00008132-000668913A05001C' \
  -derivedDataPath /private/tmp/lh13b1/DeviceDerived SWIFT_STRICT_CONCURRENCY=complete build

bash /private/tmp/lh13b1/verify-strict.sh
```

The isolated strict script preserves project-equivalent upcoming flags, `-swift-version 5 -default-isolation MainActor -strict-concurrency=complete -warnings-as-errors`, `-emit-sil -whole-module-optimization` and object compilation. Scratch probes/logs are outside the repository and production targets. Exact commands/flags are in that script; final summary is `strict-final.log`. Xcode logs are `app-build-final.log`, `test-build.log`, `focused.log`, `regression.log`, `release-build.log`, `unsigned-device-build.log` and `device-build-current-signing.log`. Test counts are extracted from actual xcresult bundles into `focused-summary.json`, `regression-summary.json` and final `regression-final-summary.json` (`FinalRegression.xcresult`, also 180/273 with zero failures/skips). Final source builds are `app-build-final.log`, `test-build-final.log`, `release-build-final.log`, `device-build-final.log`; final full-suite log is `regression-final.log`. Final signed installation is recorded in `install-final.log`; no camera auto-run followed that installation.

Native Xcode/Simulator/CoreDevice/cache access required normal sandbox escalation. The shell's global developer selection initially pointed at CommandLineTools; the explicit DEVELOPER_DIR selected installed Xcode without changing global or project settings. Remote staging verification used read-only ls-remote, not fetch. No camera imagery or joint-coordinate recordings are saved.

## 8. Physical M4 validation

Device is available/paired: iPad Pro 13-inch M4 (`iPad16,5`), iPadOS **26.7.1 (23H30)**. Signed build and installation succeeded. Edo agreed to help with no-person, one-person and two-person checks. Actual numeric device observations and manual scenario confirmations follow; availability/installation alone was not treated as successful Vision inference.

### Automatically collected run E — nominal empty scene

Edo selected “Ready — no person in frame” before launch. A DEBUG finite 30-second run, with preview enabled, produced `/private/tmp/lh13b1/empty.txt`; its numeric export is automatic evidence. Edo subsequently confirmed a person was visible for the first 1–2 seconds. This is therefore a transition-to-empty run, not a strictly empty 30-second accuracy trial. This is not a participant recording.

| Reading | Actual value |
|---|---:|
| Start-request interval, including startup/shutdown | 30.647 s |
| Delivered / admitted / sink-completed | 901 / 901 / 898 |
| Camera / successful Vision FPS | 30.003 / 30.026 |
| Successful / context-order-cancellation rejected / failed pose results | 898 / 0 / 0 |
| Raw count buckets zero / one / two / more | 864 / 24 / 10 / 0 |
| Vision inference p50 / p95 | 7.531 / 8.558 ms |
| Capture → pose completion p50 / p95 | 56.637 / 57.754 ms |
| Callback p50 / p95 | 0.571 / 1.839 ms |
| AV drops / pending replacements / capacity drops | 0 / 3 / 0 |
| Source/workspace/preview peaks | 11,059,200 / 3,686,400 / 11,059,200 B |
| Simultaneous explicit pixel peak | 18,432,000 B |
| Raw / workspace current at Stop export | 0 / 0 B |
| Preview current at immediate Stop export | 3,686,400 B (one still-retained provider) |
| Preview acceptance rate | 4.556 Hz |
| Process RSS first / last / peak | 127,156,224 / 244,416,512 / 252,198,912 B |
| Thermal state | 0 (nominal at export) |
| Awaited shutdown | 99.575 ms |

Actual front Ultra Wide capture negotiated native/output 1280×720 BGRA, stride 5,120 / 3,686,400 bytes, Center Stage inactive, stabilization off, unmirrored source rotation metadata 0°. Original host timestamps and generation/epoch/geometry/frame ID are included in the export. Stop cleared the compatible raw pose; an export after Stop intentionally contains aggregate metrics rather than a retained current pose. A live saved snapshot is needed for joint-presence/confidence detail.

This run demonstrates successful real Vision requests on the physical iPad, not perfect no-person accuracy. The 34 positive results must not be discarded or relabeled as zero. The initial visible-person interval may account for positive results, but the aggregate histogram does not locate them in time or exclude later false positives; this is not evidence of correct two-person association. The three pending replacements explain the difference between admitted and completed frames without an unbounded backlog. Successful-FPS endpoint arithmetic can slightly exceed capture FPS over a finite interval; it is not an inference capacity guarantee.

The one preview backing still charged at the immediate Stop export is not forced free: final provider lifetime follows the accepted A2 contract. It is distinct from zero raw/workspace bytes and from process RSS. A later numeric sample is required to establish final preview release for this B1 run. No CPU, physical display latency, model-isolated memory or long-term thermal measurement is claimed.

### Live one-person and two-person snapshots

Edo manually confirmed the scene composition, used Stop/Start between cases, waited and saved the numeric snapshot while capture remained running. Retrieved exports are `/private/tmp/lh13b1/one-person.txt` and `two-people.txt`. The actual displayed request intervals are **30.084 s** and **38.715 s**, not identical steady-state benchmark windows. Preview was enabled for both. They are runtime numeric evidence with developer-supplied scene ground truth, not saved imagery or automated person-identity validation.

| Reading | One centered person | Two side-by-side people |
|---|---:|---:|
| Start-request interval | 30.084 s | 38.715 s |
| Geometry revision / latest raw frameID | 3 / 896 | 4 / 1,153 |
| Delivered / admitted / sink-completed | 896 / 896 / 895 | 1,153 / 1,153 / 1,152 |
| Successful pose results | 896 | 1,153 |
| Camera / successful Vision FPS | 30.003 / 30.001 | 30.003 / 30.006 |
| Raw count buckets zero / one / two / more | 0 / 892 / 4 / 0 | 0 / 0 / 1,150 / 3 |
| Latest SDK observations / retained candidates | 1 / 1 | 2 / 2 |
| Inference p50 / p95 | 8.163 / 8.886 ms | 7.756 / 8.480 ms |
| Capture → pose result p50 / p95 | 58.307 / 59.644 ms | 58.112 / 59.702 ms |
| Current pose age at numeric refresh | 0.061 s | 0.065 s |
| Callback p50 / p95 | 0.584 / 1.704 ms | 0.535 / 1.700 ms |
| Total copy/processing sink p50 / p95 | 14.449 / 15.610 ms | 13.903 / 15.178 ms |
| AV / pending / capacity / stale drops | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 |
| Pose rejected / failures | 0 / 0 | 0 / 0 |
| Raw / workspace / preview peaks | 11,059,200 / 3,686,400 / 11,059,200 B | 11,059,200 / 3,686,400 / 11,059,200 B |
| Simultaneous explicit pixel peak | 18,432,000 B | 18,432,000 B |
| RSS first / last / peak | 239,812,608 / 251,445,248 / 255,098,880 B | 229,163,008 / 251,543,552 / 254,967,808 B |
| Thermal state | 0 (nominal at snapshot) | 0 (nominal at snapshot) |
| Preview acceptance cadence | 4.563 Hz | 4.593 Hz |

Snapshot joint/confidence summaries (candidate numbers are **frame-local**, not P1/P2):

| Snapshot / candidate | Present / missing of 14 | Positive low confidence (<0.3) | Confidence min / mean / max |
|---|---:|---:|---:|
| One person, candidate 0 | 10 / 4 | 3 | 0.111 / 0.383 / 0.708 |
| Two people, candidate 0 | 11 / 3 | 2 | 0.135 / 0.476 / 0.775 |
| Two people, candidate 1 | 14 / 0 | 0 | 0.445 / 0.820 / 0.940 |

These demonstrate actual physical-iPad multi-observation Vision extraction and nonzero joint/confidence output while two people were reported visible. They do not establish persistent association, perfect human counts, limb accuracy or tracking. Four one-person-run frames reported two observations; three two-person-run frames reported more than two. No excess detections were silently discarded to enforce a two-person story. Missing/weak joints and extra candidates must inform B2's separately approved uncertainty/binding policy.

A numeric refresh reads capture metrics, ownership gauges and pose metrics at successive instants while capture continues; their totals are not one global atomic transaction. The single-frame difference between sink-completed and pose counts is not classified as a lost frame. Individual pose envelope metadata and its accepted statistics are protected together. p50/p95 for the two-person snapshot retain the most recent 1,024 samples of 1,153 successes; one-person/transition runs had fewer samples.

The existing export label “Reconstruction sink” covers reconstruction **plus Vision and conversion**, not an isolated reconstruction benchmark in B1. Separate “Vision inference” measures the synchronous adapter/request interval, while capture-to-pose age ends at inference completion. The final DEBUG presentation renames that line to “Total processing sink (copy + optional Vision)”; this is a label-only clarification after the measured runs and changes no processing behavior. Inference and ownership code used for these measurements is unchanged.

### Mixed height/partial-field/movement/overlap exercise

Edo reported completing the requested different-height (where applicable), partly-out-of-view, arm/leg movement and overlap/separation sequence, then saving `/private/tmp/lh13b1/movement-overlap.txt` while capture continued. No individual stage timings, height measurements or per-stage count/joint readings were supplied. This is manual scenario confirmation plus an automatic **aggregate**, not an independently segmented accuracy trial for each case.

The export is **326.663 seconds since Start in the same generation/epoch/geometry as the 38.715-second two-person snapshot**. These snapshots overlap and must not be added together as independent sample populations.

| Mixed-session reading | Actual value |
|---|---:|
| Delivered / admitted / sink-completed / successful pose results | 9,792 / 9,792 / 9,792 / 9,792 |
| Camera / Vision result FPS | 30.003 / 30.004 |
| Raw count buckets zero / one / two / more | 321 / 3,308 / 6,131 / 32 |
| Latest raw frame / observations | 9,792 / 2 |
| Latest candidate joint presence | 8/14 and 12/14 |
| Latest confidence min / mean / max | 0.138 / 0.408 / 0.607 and 0.381 / 0.761 / 0.907 |
| Inference p50 / p95 | 8.151 / 8.904 ms |
| Capture → pose result p50 / p95 | 58.088 / 59.466 ms |
| Current result age at refresh | 0.077 s |
| Callback p50 / p95 | 0.715 / 1.901 ms |
| AV / pending / capacity / stale drops; pose rejects / failures | All zero |
| Explicit simultaneous pixel peak | 18,432,000 B |
| Raw / workspace / preview peaks | 11,059,200 / 3,686,400 / 11,059,200 B |
| RSS first / last / peak | 229,163,008 / 252,329,984 / 256,294,912 B |
| Preview acceptance cadence | 4.607 Hz |
| Thermal state | 0 (nominal at snapshot) |

Joint absence and observation-count changes are exposed without filling old joints or assigning identities. The mixed run shows sustained raw extraction without a reported source failure, but cannot attribute any zero/one/extra result to a particular exercise or prove accurate detection throughout occlusion. The p50/p95 describe the latest 1,024 samples, not all 9,792. RSS remained in a similar range to the static snapshots; finite samples and nominal thermal readings do not prove no leaks or indefinite thermal stability.

### Stop/restart, rotation and final cleanup

Edo explicitly confirmed **all requested lifecycle checks passed**: Stop cleared preview/current raw pose; Start followed by 180° rotation produced “Geometry changed” and cleared output; explicit Start in the new orientation produced fresh detections; final Stop followed by a delayed numeric save succeeded. This is **developer-observed manual evidence**. The intervening geometry-failure notification is not in the final generation's reset history and is not invented as an automatic log.

The automatically retrieved `/private/tmp/lh13b1/stopped-after-rotation.txt` separately records:

- New generation `DE21A1D1-8A20-4AB2-9F4C-97D00276211E`, epoch `77BF4E8D-90A8-4EAB-BED6-363701EE7FE3`, **geometry revision 6**, source rotation **180°**, unmirrored 1280×720 BGRA.
- **5.349 s** Start-request interval; 148 delivered/admitted/completed and successful pose results, 30.003 capture FPS, 30.041 finite-window pose FPS, 0 pose rejects/failures and 0 AV/pending/capacity/stale drops.
- Inference p50/p95 **7.950 / 8.783 ms**; capture-to-pose **57.927 / 59.719 ms**. Histogram 22 zero / 126 one / 0 two / 0 more; no claim of two people during this short restart sample.
- Stopped state, **no compatible current raw pose**, and **zero current raw, reconstructed workspace and preview bytes**, with **zero preview backings**. The preview lifetime peak remains 11,059,200 B, rather than being falsely reset to conceal old ownership.
- Awaited shutdown **56.228 ms**, thermal state 0 at export, RSS first/last/peak **227,229,696 / 230,555,648 / 249,233,408 B**. Last source frame 148 has host age 2.935 s because the sample was saved after Stop; it is historical source metadata, not a fresh pose.

These data support fresh-generation extraction after rotation and eventual owner release. They do not prove every startup/cancellation race or absence of all framework leaks. The final telemetry-label-only binary was built/installed after these measurements without starting another camera run; the inference/ownership implementation is identical, and the metric-label version distinction above is retained.

### Physical protocol coverage and remaining limits

| Requested scenario | Evidence / limits |
|---|---|
| No person | Transition-to-empty run: Edo confirmed a person in first 1–2 s; 864 zero-observation results. Strictly empty-from-first-frame accuracy was not established. |
| One centered person | Manual scene confirmation and live numeric snapshot; one current candidate with 10/14 joints; 892 one / 4 two results. |
| Two side by side | Manual scene confirmation and numeric snapshot; two current candidates, 11/14 and 14/14 joints; 1,150 two / 3 more results. Actual raw multi-person extraction demonstrated. |
| Noticeably different heights | Edo reported the requested sequence done; no individual height measurements or isolated case export supplied. No claim of calibrated height/scale correctness. |
| Partly out of field | Same manual sequence confirmation and mixed aggregate; no isolated per-case counts/accuracy assertion. Missing joints remain explicit. |
| Both moving arms/legs | Same manual confirmation and mixed aggregate; no jump/gesture classifier or anatomical overlay validation. |
| Overlap then separation | Same manual confirmation and mixed aggregate with variable counts; no persistent association or successful tracking claim. |
| Stop/Start and geometry invalidation | Explicit manual PASS plus new-generation 180° extraction and final zero-byte export. |

A controlled strictly empty rerun, isolated per-scenario count/confidence measurements, broader device/lighting/distance coverage and longer thermal/RSS profiling remain useful review/characterization follow-ups. They are not fabricated as completed accuracy gates. This report does not mark B1 ACCEPTED automatically or impose a production 30 FPS requirement.

Repeatable protocol (DEBUG diagnostics only; preview remains optional and bounded):

1. Keep the M4 unlocked, landscape-mounted, with Center Stage inactive and supported 1280×720 BGRA/30 FPS configuration. Do not silently substitute unsupported settings.
2. Use a fresh explicit Start for each scenario so count buckets have a known generation. Observe a finite interval (initial candidate: 30 seconds after native readiness). Save only the numeric snapshot outside the repository, preserving each scenario before the app's single export is overwritten.
3. Run: empty frame; one centered person; two side-by-side; two noticeably different heights; one partly out of view; both moving arms/legs; brief overlap/separation; Stop/Start and 180° geometry invalidation/restart.
4. Record actual interval, source generation/epoch/geometry/frame ID, input FPS, Vision result FPS, inference and capture-to-result p50/p95, current result age, raw observation buckets/latest counts, joint presence/confidence, AV/primary replacement/reject counts, explicit current/peak pixel bytes, process RSS and thermal state. Counters/latency are measurements, not identities or detection accuracy ground truth.
5. Record Edo's visible-person/scenario confirmation separately from automatic numbers. Stop should clear compatible raw results and preview, then eventually release workspace/source owners; geometry change requires explicit restart. No automatic tracking/recovery behavior is introduced.

There is no requirement that Vision achieve 30 FPS. Input FPS, successful inference cadence and optional preview acceptance cadence are different measurements. p50/p95 use existing bounded 1,024-sample windows. Current raw result age/inference completion is not display-to-photon latency; CPU utilization is not measured by these diagnostics. Full process RSS includes Vision model/framework caches and is not the explicit pixel-memory ledger.

## 9. Limitations and integration boundaries

Raw frame-local candidates are not P1/P2. Occlusion/reentry, anatomical correctness under real movement, model accuracy, offscreen bodies and candidate ordering require device review and later tracking rules. No known person is recognized or reassigned here. Zero SDK observations is a valid successful raw result, not evidence that calibration/gameplay is ready.

Physical Vision throughput, stop responsiveness and model RSS are distinct from A2's reconstruction-only measurements; A2 results are not reused as B1 benchmarks. Compiler checks do not establish framework runtime alias safety or detection quality. A synchronous framework hang remains a bounded-but-stalled worker requiring review, not permission to spawn replacements.

LH-22 still owns real standing head/independent foot calibration and same-frame pose/mask association. LH-13C later owns calibrated measurements, jump evidence and provider integration; Jevon owns acceptance-driven session readiness and gameplay. CP2 live segmentation/rendering is not implemented here.

## 10. Initial LH-13B2 readiness and Git handoff (REVIEW history)

B1’s software seams and demonstrated physical two-person extraction are ready for Edo’s review. No fundamental compiler, ownership or signed-deployment blocker remains. B2 is ready for a separately scoped proposal/authorization, not automatic implementation: agree stable P1/P2 binding/reacquisition, confidence and ambiguity rules using the observed missing/extra detections. Review the retained-candidate cap and partial/extra-person policy before relying on candidate selection. Candidate IDs must never become persistent player IDs. For any later DEBUG skeleton, match the exact displayed source generation/frameID/internal epoch/geometry and fitted rectangle, mirror once and omit unmatched overlays. Kevin's DEBUG approval does not authorize production GameWorldMapping changes.

LH-22 must still establish real independent standing references and reviewed same-source pose/mask processing; a cached raw result is not permission to pair it with an unrelated mask or retain unbounded historical sources. No B2 tracking, skeleton overlay, calibration, BodySnapshot publication, GameClock/gameplay integration, segmentation or production cutout rendering is included. No source image or pose-coordinate dataset was persisted. Skills used: `swift-concurrency` and `swift-testing-expert`.

No staging, commit, push, merge, rebase, reset, branch switch or new worktree. Preserve the unrelated signing diff and existing untracked Scripts when reviewing/committing B1 later. Final preservation audit: the only changed baseline Swift files are the four listed source edits. The sole additional changed baseline file is the external two-line signing-team edit in `.pbxproj`; no missing baseline file and no changed existing Scripts, contracts, tests, fixtures, assets or generated packages. New files are the production result store, test suite and this report. Nothing is staged. HEAD/branch remain the initial `c45f8cd` / `feat/vision-pose`. `git diff --check` passes.

At the implementation handoff, B1 was **REVIEW**, with physical raw two-person extraction demonstrated and remaining quality/characterization limits explicit. The final audit in §11 supersedes that disposition with scoped ACCEPTED status. Separate B2 design and implementation authorization is still required.


## 11. Final Acceptance Addendum — 5 November 2026

### 11.1 Decision and evidence boundary

**LH-13B1: ACCEPTED**, scoped to bounded real Vision 2D multi-person extraction, immutable raw joint/confidence values, exact source provenance, numeric diagnostics and safe integration with the existing camera worker. No mandatory B1 acceptance blocker was found.

The earlier **REVIEW** status reflected an implementation awaiting this acceptance audit; it remains part of the report's history. This acceptance does not complete the original combined LH-13B pose-and-tracking milestone, LH-22, LH-13C/D, calibrated gameplay input or production rendering. It grants no permission to implement B2, commit or merge.

The audit read the actual CameraPipeline processing loop, FrameStore/reconstruction sink, PoseEstimator/adapter/result store, DEBUG numeric integration, B1 tests, CP1 PoseFrame/PlayerID/BodySnapshot/provider contracts and accepted LH-13/A2 boundaries. The current branch remains `feat/vision-pose`, HEAD `c45f8cd13b9880cc62a261a03d92b1f6d6b4aa0a`; B1 changes and the unrelated signing edit remain local. Technical acceptance is separate from Git integration.

**Existing evidence re-inspected, not newly executed verification:**

- Final regression result summary and `FinalRegression.xcresult` record **180 definitions / 273 executions, zero failures/skips**; focused B1 results record **11 definitions / 18 executions**. Existing successful Simulator app/test, Release and signed-iPad build logs remain those listed in §7.
- `strict-final.log` records complete-checking SIL/WMO, object/WMO and test positives on both SDKs and all **six expected negative rejections**. The source still uses the same checked ownership path; no unsafe suppression or project-wide concurrency migration was added.
- Previously retrieved numeric exports `two-people.txt`, `movement-overlap.txt` and `stopped-after-rotation.txt` corroborate §8. Scene composition, exercise completion and the intervening geometry-change notification retain Edo's manual-confirmation provenance. Numeric exports do not independently identify people or establish per-stage motion accuracy.
- This request performed read-only source/artifact inspection, arithmetic/consistency and file-preservation checks, then documentation editing. **No builds, tests, camera runs or physical measurements were rerun for acceptance.** The earlier label-only final-build qualification and non-atomic cross-metric snapshot caveats remain unchanged.

### 11.2 Answers to the acceptance questions

| Question | Audit finding / scoped conclusion |
|---|---|
| **1 — Real inference, single worker and safe ownership** | **Supported.** The default camera sink receives `store.poses` and constructs the real detector in the existing CameraCopySink actor. One FrameStore consumer/processing loop reconstructs the buffer and calls synchronous Vision. CV/VN objects stay worker-local; only immutable numeric results/metadata reach the result store. DEBUG refresh is a read, not another stream or camera observer. No second session, raw-frame consumer or per-frame Task was introduced. |
| **2 — Original provenance and canonical coordinates** | **Supported.** The immutable source envelope retains generation, epoch, original frameID/capturedAt, geometry revision, dimensions and rotation/mirroring provenance. Existing PoseFrame fields copy the matching values; epoch stays internal. Source/token/order gates reject incompatible or delayed completions. Already-upright, unmirrored buffers use Vision `.up`; normalized joint values are not reflected for display. This is contract/code and numeric-test verification, not a new optical skeleton-alignment claim. |
| **3 — Raw points/confidence without invented observations** | **Supported.** All 14 existing joint names retain anatomical identity. Missing/zero-confidence/nonfinite/out-of-range points are absent, not zero-filled or replaced by old limbs. Finite positive low-confidence values remain explicitly raw. No mask, crown/sole estimate, calibration or reliability verdict is manufactured. |
| **4 — Frame-local candidate IDs** | **Supported.** Candidate index reuse belongs to a specific source frame and has no PlayerID meaning. Reorder tests demonstrate that the same numeric candidate index can denote different observations in later frames. No persistent identity assignment or two-largest-person selection occurs. The eight-candidate retained-value cap and total SDK count are explicit. |
| **5 — Adequate tests and physical evidence** | **Supported for B1.** Deterministic conversion, provenance, context/order, cancellation, failure and bounded-worker tests complement real physical requests. The controlled two-person snapshot has two candidates with 11/14 and 14/14 joints; its reported capture/result rates are 30.003/30.006 FPS and inference p50/p95 7.756/8.480 ms. This establishes extraction, not tracking or perfect joint accuracy. |
| **6 — Contaminated empty-scene trial** | **Nonblocking accuracy-characterization limitation.** A person was visible for the first 1–2 seconds, so the run cannot establish a strictly empty negative-trial false-positive rate. Zero-result handling is tested deterministically and occurred in 864 physical results. No approved B1 criterion required zero false positives or an accuracy target; this limitation does not undermine the demonstrated ownership/provenance/extraction path. Do not relabel it a clean empty-scene accuracy PASS. |
| **7 — Missing joints, extra detections and uncertainty** | **Correctly exposed and deferred.** Four one-person-run frames reported two observations; three static two-person-run frames reported more than two. Raw values/counters expose these variations instead of enforcing a two-person story. B2 must decide association, confidence, ambiguity and reacquisition before assigning stable slots. The diagnostic `<0.3` label is not approval of a B2 tracking or gameplay threshold. |
| **8 — Throughput, memory and lifecycle sufficiency** | **Supported for this bounded milestone.** The overlapping 326.663-second mixed session records 9,792 successful results, zero reported AV drops/processing failures and an 18,432,000-byte simultaneous explicit pixel peak. Deterministic slow-worker tests preserve the bounds under backpressure. Manual lifecycle PASS plus revision-6/180° restart and final zero raw/workspace/preview bytes support invalidation and cleanup. Neither production gameplay performance nor a required 30 FPS Vision rate follows. |

The original architecture's stable binding, tracking-loss/reacquisition and third-person gates belong to separately authorized B2 work. They are not silently marked complete because B1 raw extraction passed. Likewise, CP1 remains the authoritative future gameplay transport; the latest-only raw diagnostic cache does not replace its buffered delivery or Jevon's evidence selection.

### 11.3 Remaining risks and nonblocking characterization

- Detection quality varies with scene, distance, lighting, partial bodies and overlap. Repeat a strictly empty-from-first-frame trial and isolate future per-scenario observations if accuracy characterization is needed. The mixed-session histogram cannot allocate errors to individual exercises, and its earlier two-person snapshot is a subset, not an additional independent run.
- Missing/weak joints and extra candidates can make identity association ambiguous. Do not derive reliable P1/P2, calibrated measurements or collision evidence from raw candidate count or array order.
- The eight-candidate cap bounds retained application values, not Vision's internal work/model allocations. Its treatment of overflow and crowds needs explicit B2 review; truncation cannot imply that the correct two players were selected.
- Synchronous Vision can delay cooperative shutdown. The implementation invalidates output and waits for the existing owner, rather than reclaiming a live buffer or spawning replacement workers. There is no hard shutdown-latency or framework-hang-recovery guarantee.
- Explicit pixel accounting excludes model caches, allocator/framework/renderer memory and total process RSS. Finite cleanup observations and bounded producer state do not prove the absence of all leaks or indefinite thermal stability. CPU utilization and display-to-photon latency were not measured; nominal thermal readings apply to the observed windows only.
- Reported throughput/latency is from the tested M4/configuration and finite windows; p50/p95 use the latest at most 1,024 samples. No production threshold, universal 30 FPS inference requirement or other-device guarantee is established. Optical raw-joint-to-image alignment awaits a separately reviewed same-source diagnostic overlay.

These limits require honest characterization and future design choices, not an additional feature or new acceptance threshold imposed retrospectively on B1.

### 11.4 Recommended separately authorized B2 design sequence

**Recommendation: authorize a B2 design/proposal phase next, not PlayerTracker implementation yet.** Preserve the A → B → LH-22 → C → D dependency direction and the existing CP1 contracts.

1. **Define identity and reset invariants.** Specify initial anonymous displayed-left → `.player1` and displayed-right → `.player2` binding using the approved mirror convention at the intended binding/calibration entry. Candidate IDs remain source-local. After binding, crossing the screen or changing array order must never rename slots. Define clearing/rebinding on generation/epoch/geometry changes and explicit session resets. Keep Jevon's phase/readiness authority separate from Edo's association algorithm.
2. **Propose the minimum association evidence and confidence policy.** Decide which existing joints can support candidate location/continuity when some are missing; how confidence, motion and capture-time gaps affect eligibility; and when there is insufficient evidence. Do not invent numeric cutoffs in this acceptance audit or reuse the DEBUG confidence label as an approved threshold. Preserve anatomical sides and actual capture timestamps.
3. **Design ambiguity, temporary loss and reacquisition together.** Work through reordered observations, one/zero candidates, partial bodies, overlap/separation and crossings. Prefer explicit unbound/uncertain/lost state over an unjustified match; decide how a missing person may safely re-enter without a silent identity swap. No participant recognition, profile identity or calibrated baseline algorithm is implied.
4. **Define extra-person and overflow behavior.** Review three-or-more detections, spurious candidates and the eight-value cap. Do not automatically select the first/largest two, transfer a bound slot to a newcomer, or treat an ignored candidate as proven background. Agree the conservative behavior and review parameters before coding.
5. **Specify bounded state and deterministic fixtures.** Choose finite per-track state/history and source-age/gap policies; no historical raw-image cache or unbounded matching queue. Plan immutable PoseFrame sequences with injected capture times, reordered frame-local IDs, missing/low-confidence joints, overlap, loss/re-entry, third entrants, cap overflow, stale contexts and reset. Assert stable identity when supported and explicit uncertainty when not; never assert success by forcing a pairing. Review the tests and physical acceptance matrix before implementation.
6. **Review future same-source DEBUG overlays with Kevin.** A later bounded image/pose join must use the exact displayed generation/frameID/internal epoch/geometry and fitted rectangle; omit an unmatched overlay rather than attach the latest pose to older pixels. Mirror once using the accepted DEBUG transform. Do not retain unlimited source frames to obtain a match or modify production CutoutPlacement/GameWorldMapping. Actual overlay implementation and physical alignment validation need their own scoped authorization.
7. **Approve the design and implementation boundary.** Edo owns tracking/state; coordinate affected preview interfaces with Kevin and lifecycle/readiness interfaces with Jevon. Agree the minimum internal output seam and tunable parameters without altering CP1/CP2 implicitly. LH-22 still owns real standing calibration and same-frame pose/mask work; C owns accepted calibration cutover and BodySnapshot publication. Only after the separate design review should a bounded B2 implementation be authorized.

### 11.5 Documentation and Git boundary

Only this report changes in the final acceptance audit: the current scoped disposition, a historical clarification of the prior REVIEW handoff, and this dated addendum. Original implementation details, measurements, evidence provenance, limitations and REVIEW history are retained. The report was already untracked at audit entry, so the exact incremental documentation diff is measured against its pre-audit copy, not mistaken for a Git-tracked modification.

Existing B1 Swift/test work, the external `.pbxproj` signing edit and untracked Scripts are preserved. No source, test, contract, renderer, gameplay, signing or generated-package edit, new branch/worktree, staging, commit, push, merge or branch switch occurs in this acceptance task. This acceptance is not permission to proceed automatically to B2. Review skill applied: `swift-concurrency`; existing test evidence was inspected without rerunning tests.
