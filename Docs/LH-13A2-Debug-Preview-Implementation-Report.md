# LH-13A2 — Bounded DEBUG Preview Implementation

**Final disposition: ACCEPTED — bounded DEBUG camera preview milestone only.** The initial REVISE disposition is preserved below as historical context; the [Final Acceptance Addendum](#9-final-acceptance-addendum--4-november-2026) records the evidence closing its remaining gates.

Owner: Edo. Date: 4 November 2026. Branch: `feat/camera-foundation`.
Implementation starting HEAD: `499f865494e65a2e8b35a4e228ef963eb936f650`. Published preview implementation and final-audit HEAD: `202448e397d3c3f08035fcd156c60fa5a852a540` (`feat: add bounded debug camera preview`).

The bounded owned-frame preview is implemented and accepted for its DEBUG diagnostic scope. Sections 1–8 preserve implementation, verification and initial-review history. At that review the disposition was **REVISE** because additional physical lifecycle/orientation coverage, Kevin's review and extended comparison evidence were outstanding. The dated addendum records their closure without claiming production tracking/rendering validation. LH-13B is ready for separately scoped authorization, but is not implemented or authorized by this audit.

## 1. Exact changes and preserved baseline

| File | Change |
|---|---|
| `Sedactive/Shared/BodyTracking/Capture/CameraDiagnosticPreview.swift` | New DEBUG-only configuration, budget/reservations, provider-backed immutable pixels, one conversion worker, bounded mailbox, context/subscription gates, statistics, process-RSS query and aspect-fit/mirror math. |
| `Sedactive/Shared/BodyTracking/Capture/FrameStore.swift` | Retains one optional DEBUG preview service. Publishes primary work before the scoped optional deep copy; forwards begin/end/suspend/resume invalidation. |
| `Sedactive/Shared/BodyTracking/Capture/CameraCaptureMetrics.swift` | Includes actual outstanding preview reservations in simultaneous explicit pixel-memory accounting, preserving old readers across context resets. |
| `Sedactive/Games/LaserHeist/Debug/LiveInputDiagnosticsView.swift` | Retained worker task, enable toggle, mirrored full-canvas panel, frame metadata, freshness checks, preview telemetry, numeric snapshot button and finite RSS observation. |
| `SedactiveTests/Shared/BodyTrackingTests/CameraPreviewTests.swift` | New 12 test definitions / 14 executions, including parameterized context-component invalidation. |
| `SedactiveTests/Shared/BodyTrackingTests/CameraDiagnosticsTests.swift` | Existing frozen-shutdown regression now compares its shutdown line rather than the entire report, which legitimately changes with live RSS measurements. Its elapsed and single-stop assertions remain. |
| `Docs/LH-13A2-Debug-Preview-Implementation-Report.md` | This report. |

`CameraPipeline.swift` and `AppDependencies.swift` did not need edits: existing camera/frame ownership and retained diagnostics composition are reused. The session remains private to its existing actor. No second AVCaptureSession, FrameStore processing consumer, CV pool, Metal system, CP1/CP2 model, gameplay/session change, renderer/RCP edit, package or target was added.

On entry `.pbxproj` already contained the developer's signing-team change and `Scripts/` plus the architecture review were untracked. Their contents are preserved. No project setting or scheme was edited by this task. All preview source and integration hooks are guarded by `#if DEBUG`; Release builds contain no preview service, provider class, toggle or launch flag.

## 2. Actual data flow and concurrency

```text
A1 primary reservation/copy/publication
  → optional try-reservation (skip when disabled/busy/contended/cadence-limited/full)
  → independent Data(bytes:count:) clone within existing scoped source access
  → one retained preview worker / one converter actor
  → immutable CGImage + exact CameraFrameMetadata + subscription token
  → one latest pending image → MainActor diagnostics presenter
```

Primary work is published and the FrameStore state lock released before optional copying. The preview never retains a CameraSourceFrame after that scoped call. It never calls FrameStore.acquire, waits for the primary worker, consumes CP1 or publishes body evidence. Capture still pays the admitted optional copy cost; scheduling independence is not a claim of zero CPU/bandwidth contention.

One lifetime-claimed worker drains a bounded Void wakeup. There is at most one pending-input-or-conversion job, one pending output image and one displayed packet. No Task is created per frame. View recreation and enable/disable reuse the same service and worker. A never-returning converter retains its existing reservation and busy token; incoming preview work is skipped, not queued or assigned replacement workers.

Mutable CVPixelBuffers remain inside A1's native/worker ownership scopes. Preview crossing values are independently owned Data, immutable metadata and checked-Sendable CGImage. No unchecked Sendable, unsafe nonisolation, preconcurrency suppression or detached Task was used. The observable controller's worker-task token is ObservationIgnored because it is not UI state, allowing safe cancellation from deinit without an actor-isolated synthesized accessor.

## 3. Provider lifetime and explicit memory bounds

Defaults are configurable DEBUG experiments:

| Limit | Implemented value |
|---|---|
| Maximum preview cadence | 5 Hz |
| Checked payload | 4 MiB, actual stride × height |
| Additional explicit preview bytes | 12 MiB |
| Outstanding preview backings | At most 3, also constrained by bytes |
| Conversion | One worker; no input backlog |
| Output | One pending image and one displayed packet |
| Freshness | 1 second, DEBUG-only configurable candidate; not a camera-stall/gameplay timeout |

Reservation happens before the independent copy. Existing descriptor overflow/stride/BGRA validation is preserved. Copies occur outside preview/primary metadata locks. The independent Data contains the complete source canvas, including initialized padding.

**Important implementation refinement:** a simple CFData provider or packet-owned reservation would not expose final backing release reliably. The implementation therefore uses Core Graphics' documented `CGDataProviderDirectCallbacks` read-at-position/release-info interface. An opaque C context pins a checked-Sendable owner containing immutable Data and its reservation. Every read copies through scoped Data access into the framework's callback buffer; `getBytePointer` is nil, so no pixel address escapes. The final provider release balances the ARC pin. A synchronized pin gate also covers synchronous failed-creation cleanup; CGImage construction failure lets the local provider release normally.

This is explicit C API context ownership, not a raw pixel-pointer transfer or a Sendable workaround. The image/provider may outlive its packet or a generation. Credits remain charged until the final owner releases the backing. Tests retain only CGDataProvider after discarding the image packet and prove that capacity remains consumed until provider release.

The worker's completed-job input/image locals are scoped in a separate async function before it waits again. A regression verifies final pixel release while the long-lived worker is still waiting, without cancellation or another frame.

Raw 12 MiB + reconstructed workspace 4 MiB + preview 12 MiB yield a configured **28 MiB explicit pixel-allocation ceiling**, not a total process-memory guarantee. Framework decoded/display surfaces, allocator overhead and the underlying RealityKit scene are outside that ledger and are observed separately through process RSS. Preview reservations are not reset to zero on restart or wrapper disposal while providers still retain them.

## 4. Presentation and lifecycle

The diagnostics panel shows the complete CGImage using the calculated aspect-fit rectangle and a yellow border. It applies one horizontal image-only reflection and `.up` orientation; it does not apply the already-applied capture rotation again. Labels remain readable and are not mirrored. Source metadata is displayed with the packet. No pose landmarks, calibration or player identity are fabricated.

The shared overlay convention for normalized canonical bottom-left `(x,y)` and fitted top-left UI rectangle `(ox,oy,w,h)` is:

`screenX = ox + (1-x)*w; screenY = oy + (1-y)*h`.

The opaque raw-camera BGRA interpretation uses little-endian 32-bit, ignored alpha and an sRGB image candidate. Synthetic channel tests pass; this is not CP2 cutout alpha handling or a color-calibration claim.

Opening/enabling permits optional preview work; closing/disabling clears pending/displayed imagery and changes the subscription token. Native end/suspend/failure and generation/epoch/geometry replacement invalidate the preview through existing source lifecycle/status paths. The existing controller remains the sole capture-status observer. Late completed images cannot match a replacement token/context. A 100 ms diagnostic tick also expires stale imagery without requiring a new frame; numeric diagnostics remain at 500 ms cadence. These are UI diagnostics, not another GameClock.

The image and its frame metadata update together at application level. This does not prove atomic display scanout. No camera imagery is saved: the snapshot button writes only the existing numeric text report.

## 5. Verification results

Toolchain: Xcode 26.6 (17F113), Swift 6.3.3, iOS SDK 26.5; Swift 5/default MainActor/approachable concurrency settings preserved. Simulator: iPad mini A17 Pro, iOS 26.5. Physical target: iPad Pro 13-inch M4, iPadOS 26.7.1.

| Gate | Actual result |
|---|---|
| Simulator app build / test build | PASS |
| Signed physical-device app build and installation | PASS |
| Full final regression | **145 definitions / 223 executions**, 18 suites; 0 failures, 0 skips |
| New preview cases | 12 definitions / 14 executions, included above |
| Existing CP1/CP2/gameplay/smoke suites | Included; preserved |
| Complete checking + warnings-as-errors + SIL/WMO | PASS, device and Simulator SDKs, production preview/diagnostics and relevant tests |
| Production object/WMO | PASS on both SDKs |
| Meaningful ownership negatives | Retained mutable workspace and isolated delegate controls rejected as expected on both SDKs |
| Native explicitly nonisolated delegate registration | Positive production-boundary probe passes |
| Provider-only lifetime runtime probe | PASS on development Mac; separate from Simulator and iPad evidence |
| Release app build | PASS; preview symbols/UI strings/launch flag absent from binary |
| Membership | 55 app / 26 test Swift entries, no duplicates; new tests excluded from app |
| Fixtures | Four original JSON resources byte-identical in the actual installed/tested Simulator bundle; replay decoding tests passed |
| Preservation / whitespace | `git diff --check` passes; no baseline file lost; only intended files changed |

Tests cover immutable source reuse, padded BGRA/opaque channel drawing, provider retention beyond packet lifetime, payload/budget exhaustion, cadence/duplicates/expiry, latest-only output, delayed conversion, cancellation, generation/epoch/geometry changes, disable/reattach token protection, single-worker reuse, completed-job cleanup and aspect-fit/single-mirror geometry. A never-started preview consumer also proves primary admission continues without accumulating extra raw-source owners. Async cases use controlled continuations and bounded completion hints, not sleeps.

An earlier regression run had one failed whole-report equality assertion after adding RSS telemetry; it was narrowed to the intended frozen shutdown measurement. Final results above include that correction. Temporary compile/macro issues were resolved with checked storage/types; no diagnostics were suppressed. Existing AppIntents metadata-extraction warnings and renderer asset-path console messages remain documented framework/startup diagnostics, not Swift/concurrency warnings.

## 6. Physical preview-off/on measurements

The final-source comparison used the **same final DEBUG binary** for both windows, fresh launches, the same landscape-mounted M4, 1280×720 BGRA / 30 FPS configuration and underlying RealityKit app. Each window observed 30 seconds after native start; no warmup samples were discarded. Total Start-request intervals were 30.414 seconds off and 30.711 seconds on, including startup/shutdown. Center Stage was supported but inactive; source rotation metadata was 0°, source mirroring false, stride 5,120 and source bytes 3,686,400. Physical uprightness was separately confirmed by Edo, not inferred from 0°.

An earlier denied-permission attempt produced zero frames and is excluded. Initial candidate windows were preserved separately. The final-build comparison was temporarily interrupted by an automatic-approval usage limit and unavailable device; after Edo reconnected it, normal tool execution completed both final windows. Results below are from the final build, including the worker-local scoping refinement.

| Measurement | Preview off | Preview on |
|---|---:|---:|
| Delivered / admitted / reconstructed | 900 / 900 / 900 | 901 / 901 / 901 |
| Capture FPS | 30.003 | 30.003 |
| Reconstruction FPS | 29.998 | 29.998 |
| AV drops / primary replacements / capacity rejects | 0 / 0 / 0 | 0 / 0 / 0 |
| Construction / byte-budget / sink rejects | 0 / 0 / 0 | 0 / 0 / 0 |
| Callback p50 / p95 | 0.628 / 1.126 ms | 0.572 / 1.704 ms |
| Primary Data-copy p50 / p95 | 0.600 / 1.022 ms | 0.496 / 0.695 ms |
| Source-to-worker wait p50 / p95 | 0.026 / 0.072 ms | 0.031 / 0.055 ms |
| Reconstruction p50 / p95 | 6.521 / 7.273 ms | 6.586 / 7.476 ms |
| Capture-to-completion p50 / p95 | 50.464 / 51.314 ms | 50.301 / 51.423 ms |
| Preview admitted / converted / accepted | 0 / 0 / 0 | 137 / 137 / 137 |
| Preview acceptance cadence | — | 4.568 Hz |
| Preview independent-copy p50 / p95 | — | 1.061 / 1.514 ms |
| Lazy image-construction p50 / p95 | — | 0.013 / 0.017 ms |
| Image age at MainActor acceptance p50 / p95 | — | 99.804 / 149.740 ms |
| Preview cadence skips | 0 | 764 |
| Preview busy / budget / conversion failures | 0 / 0 / 0 | 0 / 0 / 0 |
| Peak provider-backed preview bytes | 0 | 7,372,800 |
| Combined explicit pixel peak | 7,372,800 | 14,745,600 |
| Raw / workspace / preview bytes at Stop export | 0 / 0 / 0 | 0 / 0 / 0 |
| RSS first / last / peak | 99,844,096 / 198,426,624 / 202,145,792 B | 99,958,784 / 205,144,064 / 212,549,632 B |
| Thermal state at export | nominal | nominal |
| Start request → native ready | 333.079 ms | 596.241 ms |
| Awaited native/worker shutdown | 66.782 ms | 99.977 ms |

Interpretation: no primary FPS degradation, drops or budget breach was observed in these finite runs. Callback p95 increased from 1.126 to 1.704 ms; these two windows do not establish a causal or production performance guarantee. The preview is deliberately sampled, not a 30 FPS video display. Edo reported visible lag/stepping in the initial candidate window. The final 4.568 Hz acceptance cadence corresponds to roughly 219 ms between accepted images. This is a limitation of the approved 5 Hz candidate, not evidence that 30 FPS capture is inherently laggy. No cadence/budget increase was applied. Adequacy for positioning diagnostics remains a review decision; this is not dynamic two-person tracking validation.

Conversion timing measures lazy CGImage construction, **not** later Core Graphics reads, display upload, rendering or photon latency. Image age is measured at MainActor acceptance, not physical presentation. RSS includes cold-start/framework/renderer behavior and is not isolated preview allocation or proof of long-term stability. CPU utilization and a sustained thermal/RSS soak were not measured.

Both final Stop exports reported zero raw, workspace and preview bytes, with zero remaining preview backings. Earlier candidate evidence also demonstrated that an immediate Stop export could still charge one 3,686,400-byte provider backing until its actual final release. The accounting does not force credits to zero on Stop; deterministic provider-lifetime tests and the final measurements distinguish clearing UI from actual backing release.

Evidence files outside the repository: `/private/tmp/lh13-preview-impl/final-off.txt` and `final-on.txt`. Earlier candidate reports remain `device-preview-off.txt`, `device-preview-on.txt` and `device-after-stop.txt`; denied attempt `device-denied.txt`. No images were collected. Numeric metrics do not prove every rendered frame is synchronized.

## 7. Initial physical confirmations and remaining protocol (historical)

**Developer-observed:** Edo confirmed the image is upright, movement is mirrored, the camera image is visible within the yellow aspect-fit border, and Stop removes the photo and displays “No current compatible preview.” This is manual confirmation, not automated visual analysis. Numeric export separately confirms actual pixel format/rates/resources. No claim is made about exact display-frame atomicity.

The following protocol was outstanding at the initial REVISE review. Its acceptance-relevant results are now recorded in §9; it is retained to preserve that history. Longer soak and future overlay work remain nonblocking follow-ups.

Remaining device protocol at that time:

1. For extended repeatability, repeat longer alternating off/on windows using the same mount, lighting and UI. Save each numeric export before another run overwrites it. The final-build 30-second comparison above is complete; longer performance/thermal stability is still open.
2. Use asymmetric top/bottom/left/right markers and move each arm; verify the full field and fitted borders, readable UI labels, one image mirror, and exact corner mapping. Existing manual upright/mirror confirmation does not replace all marker tests.
3. Rotate between landscape positions. A1's geometry guard may stop capture; expect immediate stale-image clearing, then explicit Stop/Start under the new accepted orientation. Do not bypass that guard or apply a second image rotation.
4. With preview visible, background/foreground, deny/re-enable permission, close/reopen and repeat Start/Stop. Verify clear-without-new-frame, new generation/epoch metadata, no old image reappearing and eventual provider-credit release. Earlier numeric-only A2 lifecycle passes remain separate.
5. Repeat longer alternating windows with UI load. Record callbacks, primary drops, preview skips/age, explicit memory and RSS trend; distinguish framework caches from pinned Data. Agree performance limits from observations, not invented thresholds.

At the initial review, Kevin's effective preview/overlay transform review and future same-source pose overlay integration remained open. Section 9 records his transform approval; actual pose overlay integration remains future LH-13B work. No pose data/gestures or new gameplay readiness were added.

## 8. Reproduction and initial review status (historical)

All commands used `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```bash
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/lh13-preview-impl/Derived \
  SWIFT_STRICT_CONCURRENCY=complete build

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/lh13-preview-impl/Derived \
  SWIFT_STRICT_CONCURRENCY=complete build-for-testing

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/lh13-preview-impl/Derived \
  -resultBundlePath /private/tmp/lh13-preview-impl/ScopedFinal.xcresult \
  SWIFT_STRICT_CONCURRENCY=complete test-without-building

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS,id=00008132-000668913A05001C' \
  -derivedDataPath /private/tmp/lh13-preview-impl/DeviceDerived \
  SWIFT_STRICT_CONCURRENCY=complete build

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/lh13-preview-impl/ReleaseDerived \
  SWIFT_STRICT_CONCURRENCY=complete build

bash /private/tmp/lh13-preview-impl/verify-strict.sh
```

The strict script performs complete/WAE SIL/WMO and object compilation on both SDKs using the unchanged Swift 5/default MainActor/upcoming-feature conventions. Source callback and ownership negative controls remain included. Final log: `strict-scoped.log`; full test result: `ScopedFinal.xcresult` / `test-summary.json`; builds: `app-build-final.log`, `device-build-final.log`, `release-final.log`.

Physical runs use `devicectl device process launch --terminate-existing com.Edward-Kristian.Sedactive --camera-diagnostics-run`, adding `--camera-preview-on` for the on window. Installation is gated on successful signing/build. Numeric reports are copied only from app `Documents/LH13A2-observation.txt`. The usage-limit approval failure executed no command. After the user resumed and reconnected the temporarily unavailable device, normal execution completed the final off/on comparison. No approval mechanism was bypassed.

At the initial review, no fundamental ownership/compiler/budget blocker remained, but full A2 acceptance was **not** claimed: remaining physical lifecycle/orientation cases, extended comparison evidence, cadence usability and Kevin's review were explicit gates. Final-build paired measurements were complete. Section 9 supersedes this REVISE disposition with the final bounded-DEBUG acceptance decision. LH-13B remains untouched.

No stage, commit, push, merge, rebase, reset or branch switch occurred during the implementation task. The existing signing edit, then-untracked review and Scripts were preserved. Edo subsequently committed the preview and review in `202448e`; the final audit makes no Git mutations. Skills applied: swift-concurrency, swift-testing-expert, swiftui-expert-skill.


## 9. Final Acceptance Addendum — 4 November 2026

### 9.1 Decision, audit baseline and evidence provenance

**LH-13A2: ACCEPTED**, specifically the bounded, optional DEBUG camera preview and its capture diagnostics on the tested iPad Pro 13-inch M4 / iPadOS 26.7.1 configuration. The previous **REVISE** status accurately described the earlier incomplete evidence; it is superseded by this addendum, not erased.

This audit inspected the committed preview implementation, FrameStore, metrics, diagnostics controller/view, relevant tests, CP1 coordinates/provenance and accepted LH-13 milestone plan. Branch is `feat/camera-foundation`, HEAD `202448e397d3c3f08035fcd156c60fa5a852a540`. Entry working tree contained only the pre-existing `.pbxproj` signing-team edit and untracked `Scripts/`. Neither is part of this documentation update. No source, test, project or contract change was required.

Evidence is separated as follows:

- **Previously executed, now re-inspected automated evidence:** the existing `ScopedFinal.xcresult`, build logs and complete-concurrency logs cited in §8. Reading the result bundle again confirms **145 definitions / 223 executions, zero failures/skips**. Simulator app/test, physical-device app and Release build logs contain their successful completion markers. Strict logs record both SDKs' SIL/WMO and object/WMO positives and the expected negative-control rejections. The checked script uses Swift 5, complete checking and warnings-as-errors; successful logs have no relevant Swift/concurrency diagnostics. The previously disclosed AppIntents metadata warning remains separate.
- **Previously collected numeric device exports:** §6's final 30-second off/on reports remain available and distinct from the extended comparison below.
- **Developer-observed physical evidence:** Edo supplied the five manual PASS results below and the extended A/B/C screenshot readings in this chat. The original extended-run screenshots and numeric exports were not supplied for this audit; no new device logs, sampling conditions or automated visual analysis are invented. Kevin's approval is recorded from Edo's explicit account of his review.
- **Newly performed in this audit:** source/document consistency inspection, read-only extraction of the existing xcresult summary, arithmetic checks, Git/diff and file-preservation checks. **No builds, tests, camera runs or physical measurements were rerun.**

The older architecture proposal and numeric-only A2 report describe earlier implementation/approval states. Their historical open preview gates are superseded for this milestone by this addendum; those documents were not edited. Their later B/LH-22/C/D scope boundaries remain intact.

### 9.2 Kevin's transform review: APPROVED

Canonical normalized bottom-left image coordinates map into the top-left aspect-fit UI rectangle `(ox, oy, w, h)` as:

```text
screenX = ox + (1-x) * w
screenY = oy + (1-y) * h
```

Kevin explicitly approved the DEBUG transform with these invariants:

1. A future skeleton overlay must match the displayed preview's exact source frame identity, camera geometry revision and fitted rectangle. Use generation/frameID plus capture-internal epoch/context compatibility; never place the latest pose over an older preview. Preserve source capture time and dimensions rather than manufacturing a match.
2. Apply horizontal mirroring **exactly once**. The formula above gives final screen coordinates. An overlay inside a container already mirroring its contents must not apply another reflection. Preserve anatomical joint identities.
3. This is a **DEBUG-preview-only** transform. Production cutouts retain canonical player-plane coordinates, `CutoutPlacement` and lane-local mirroring through `GameWorldMapping`.

Kevin confirmed no `GameWorldMapping` or production-renderer change is required. This approval does not authorize changes to production cutout mapping, materials, sorting or overlays. Same-frame skeleton rendering has not yet been implemented or validated.

### 9.3 Completed physical manual tests

All results below are **PASS — developer-observed by Edo**, on iPad Pro 13-inch M4 / iPadOS 26.7.1, reported for this 4 November acceptance. They are not additional automated executions.

| Test | Observed result |
|---|---|
| **1 — Orientation and mirroring** | Upright image; TOP/BOTTOM/LEFT/RIGHT marker checks passed; intended horizontal mirror; readable labels; full-image aspect fit without unintended crop. No double mirror or unexpected rotation observed. |
| **2 — Stop and restart** | Repeated Stop/Start succeeded. Stop removed imagery and displayed “No current compatible preview”. Old imagery did not reappear; Start produced fresh imagery. |
| **3 — Background and foreground** | Leaving the app stopped capture and invalidated preview. Return required explicit Start; fresh imagery then appeared without stale preview. This confirms existing manual-restart behavior; automatic restart is not requested. |
| **4 — Permission denied and re-enabled** | Revoking Camera in Settings produced the denied state without stale preview. Re-enabling permission and pressing Start restored capture/preview without restarting the iPad. |
| **5A — View reopen** | Closing diagnostics stopped capture and cleared imagery. Reopening and Start produced fresh imagery. Together with retained-composition tests/code inspection, this supports reuse of the single camera across diagnostic view lifecycles. |
| **5B — Landscape rotation** | A 180° rotation stopped capture, cleared preview and reported “Geometry changed (rotation, zoom, framing, or format)”. Explicit restart in the new landscape orientation produced upright, correctly mirrored imagery without reusing an old frame. This is expected geometry invalidation, not automatic in-place rotation. |

These observations do not instrument every possible SwiftUI recreation, native interruption or startup race. Single retained composition and synthetic race/no-frame failure tests complement the tested physical paths; exhaustive hardware fault coverage is not claimed.

### 9.4 Extended physical A/B/C comparison

Edo performed consecutive **A OFF → B ON → C OFF** observations on the same device, reading the running diagnostics UI. Durations are the displayed **Start-request intervals**, not independently timed steady-state inference windows. A/B/C are approximately **4.760 / 4.910 / 4.293 minutes**, respectively; they are not three full five-minute sessions. These are screenshot transcriptions, not newly retrieved numeric exports. Warmup, exact screenshot timing and other environmental controls were not independently recorded here.

| Reading | A — OFF | B — ON | C — OFF again |
|---|---:|---:|---:|
| Start-request interval | 285.595 s | 294.578 s | 257.579 s |
| Input FPS | 30.003 | 30.003 | 30.003 |
| Sink FPS | 30.004 | 30.005 | 30.005 |
| Delivered / admitted / completed | 8,558 / 8,558 / 8,558 | 8,828 / 8,828 / 8,827 | 7,718 / 7,718 / 7,718 |
| AV drops | 0 | 0 | 0 |
| Pending / capacity / stale drops | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| Callback p50 / p95 | 0.484 / 0.809 ms | 0.512 / 1.960 ms | 0.665 / 1.041 ms |
| Reconstruction p50 / p95 | 6.535 / 7.338 ms | 6.610 / 7.460 ms | 6.384 / 7.301 ms |
| Preview admitted / converted / presented | Not supplied | 1,386 / 1,386 / 1,385 | Not supplied |
| Preview presented FPS | Not supplied | 4.572 | Not supplied |
| Preview cadence skips | Not supplied | 7,702 | Not supplied |
| Preview busy / budget / context / stale / failure drops | Not supplied | 0 / 0 / 0 / 0 / 0 | Not supplied |
| Provider-backed preview bytes current / peak | 0 / 0 | 11,059,200 / 11,059,200 | 0 / 11,059,200 |
| Preview backing count | Not supplied | Not supplied | 0 |
| RSS first / last / peak, bytes | 183,156,736 / 218,300,416 / 218,333,184 | 203,309,056 / 236,765,184 / 236,814,336 | 216,645,632 / 218,988,544 / 222,658,560 |
| Thermal state | 0 (nominal) | 0 (nominal) | 0 (nominal) |
| Preview independent-copy p50 / p95 | Not supplied | 1.050 / 2.040 ms | Not supplied |
| Preview age at MainActor acceptance p50 / p95 | Not supplied | 87.895 / 140.860 ms | Not supplied |

**Capture and latency.** No primary FPS or observed AV/pending/capacity/stale-drop regression appears in these readings. Callback p95 is higher with preview ON: **1.960 ms**, versus **0.809 / 1.041 ms** in the OFF observations. This is measurable callback-tail overhead in the supplied comparison; it is not evidence of zero preview cost or a controlled causal benchmark. Reconstruction p95 is 7.460 ms ON versus 7.338 / 7.301 ms OFF. Vision is not running in this reconstruction benchmark, so none of these rates predict pose inference throughput.

**Preview admission.** Reported presentation acceptance is **4.572 Hz**, below the configured 5 Hz cap. The UI calls this “presented”, but the implementation counts MainActor acceptance, not physical display frames. Intentional cadence skips keep optional work bounded and are not AV camera failures. A live read showing one fewer completed primary frame and one fewer presented preview is compatible with in-progress/latest-pending work; it is not a final drained assertion or proof of failure.

**Counter qualification.** The supplied B preview admissions plus cadence skips equal **9,088**, exceeding the reported 8,828 primary admissions. They cannot be reconciled as one exact atomic frame ledger from these transcriptions. The cause is not established; readings may have been taken at different instants, but this audit does not assert that explanation. No exact per-window skip percentage or resource leak is inferred. Preserve atomic numeric exports if future telemetry reconciliation is required. This limits cross-counter analysis without invalidating the independently tested bounded admission policy or observed capture continuity.

**Explicit backing lifetime.** B's 11,059,200 bytes equal three 3,686,400-byte BGRA backings, within the approved **12 MiB (12,582,912-byte)** preview cap and three-backing limit. It is live accounted memory, not a demonstrated leak. C reports **zero current bytes and zero backings**, while retaining the historical peak. Code inspection confirms the budget peak is lifetime-scoped and is not reset merely by disabling preview; a nonzero peak in C is expected. This supports actual owner release rather than hiding it by zeroing counters. These readings do not supply an extended-run combined raw/workspace/preview peak; the configured bounds and earlier exports/tests remain separate evidence.

**RSS comparison.** Ending RSS was **218,300,416 B in A** and **218,988,544 B in C**, a difference of **688,128 B (0.65625 MiB)**. B ended at **236,765,184 B**, **18,464,768 B (17.609375 MiB)** above A and **17,776,640 B (16.953125 MiB)** above C. The ON increase and later near-baseline ending RSS are consistent with temporary preview/framework workload and release, but cannot allocate the difference specifically to Data versus decoded surfaces, caches or other app behavior. Process RSS includes the app/renderer/frameworks and differs from the explicit pixel ledger; it is not governed by the preview's 12 MiB cap. Finite samples neither prove absence of every leak nor establish indefinite RSS stability.

**Measurement limits.** p50/p95 use the implementation's bounded **most-recent 1,024 valid samples**, not all samples across these multi-minute intervals. Preview acceptance age is not display-to-photon latency; lazy CGImage construction excludes deferred decoding/render work. CPU utilization was not measured. Thermal state 0 is nominal at the observed readings, not proof of long-term thermal behavior. No unapproved production throughput, latency or memory acceptance threshold is imposed on this DEBUG milestone.

### 9.5 Final gate assessment and nonblocking limits

| Gate | Evidence and final assessment |
|---|---|
| Checked ownership and concurrency | Existing immutable Data/metadata boundary, one retained session/worker, scoped CV access; strict positives and meaningful negatives verified from prior logs. **Satisfied for this implementation.** |
| Bounded image lifetime | Provider final-owner tests, three-backing/12 MiB cap, prior Stop exports and extended final-OFF zero current backings. **Satisfied.** |
| Deterministic regression | Existing xcresult re-read: **145 definitions / 223 executions, 0 failures/skips**. No tests rerun in this audit. **Satisfied.** |
| Simulator, test-target, device and Release builds | Prior successful logs re-inspected; DEBUG exclusion documented and source guards confirmed. **Satisfied; no new build claimed.** |
| Physical camera and primary-path independence | Earlier actual format/stride/clock exports plus OFF/ON/OFF ~30 FPS and zero reported drops. No waiting dependency on preview; finite-window CPU contention still exists. **Satisfied for capture diagnostics.** |
| Uprightness, aspect fit and single mirror | Manual Test 1 and 5B; synthetic transform tests. **Satisfied.** |
| Kevin transform approval | §9.2, including all three constraints and unchanged production mapping. **Satisfied.** |
| Stop/restart, background/foreground, permission recovery and view reopen | Manual Tests 2–5A plus retained-composition and lifecycle tests. No automatic foreground restart. **Satisfied for tested paths.** |
| Geometry/context invalidation | Manual 180° rotation/explicit restart and delayed context/token tests. **Satisfied.** |
| Extended comparison and cleanup | Actual 257.579–294.578-second readings; bounded backing, zero final current bytes and no observed primary regression. Screenshot provenance/counter limitations retained. **Sufficient for bounded DEBUG scope.** |
| Scope isolation | All preview code/hooks DEBUG-only; CP1/CP2, gameplay, renderer, signing and production ownership unchanged by this audit. **Satisfied.** |

No mandatory gate remains unsupported for this bounded DEBUG diagnostic milestone. Nonblocking follow-ups are longer thermal/RSS soaks and broader hardware fault/race coverage, atomic numeric exports to reconcile extended counters, and reassessment of low-cadence preview usability for future moving-skeleton diagnostics. Existing UI text still saying review is required is historical wording in the committed diagnostic implementation; this documentation-only audit leaves it unchanged. Acceptance does not require removing those labels or increasing cadence.

This decision **does not validate live two-person tracking, standing calibration, jump inference, calibrated BodySnapshot production, production cutout rendering, full LH-13 or a production performance budget**. No physical frame-atomic display claim is made.

### 9.6 LH-13B readiness — recommendation only

**Ready for Edo to authorize a separately bounded first LH-13B phase; no LH-13B implementation is authorized or begun here.** Reuse the accepted A1/A2 infrastructure rather than creating another camera or raw-source consumer.

- **Reusable capture foundation:** one retained CameraPipeline, latest bounded FrameStore, checked BGRA dimensions/stride/bytes, worker-owned reconstruction, source host-clock capture seconds, `generation`, `epoch`, capture-sequence `frameID`, `geometryRevision`, applied rotation and unmirrored provenance. Preserve every source key through processing; reset/reject work on incompatible context changes.
- **Vision entry point:** implement the current skeleton `Shared/BodyTracking/Capture/PoseEstimator.swift` around one serial `VNDetectHumanBodyPoseRequest` / `VNImageRequestHandler` path, owned with its reconstructed CV workspace by the existing processing worker. Recheck exact SDK signatures at implementation. Do not transfer mutable VN/CV objects across actors; emit existing immutable `Models/PoseFrame.swift` candidates/joints/confidences, retaining full capture-internal context for stale-result rejection. `PoseFrame` has no epoch field; keep epoch gating internal rather than changing CP1.
- **First suggested phase — B1 raw source-correlated poses only:** bounded Vision processing and adapter tests for joint mapping, missing points/confidence, exact provenance, cancellation/context changes and memory cleanup. Measure actual two-person detection cadence/latency on iPad separately. Keep the single processing lease/loop; do not add a second FrameStore consumer or implement live BodySnapshot publication. Place only minimal reviewed raw-pose composition in MotionEngine if required. PoseEstimator, PlayerTracker, MotionEngine and CalibrationSession remain skeletons at this audit.
- **Next B boundary — stable binding/tracking:** initial displayed-left → `.player1`, displayed-right → `.player2`, interpreted using the approved single-mirror transform. Candidate IDs/order are frame-local, not player identity. Preserve slots across reordered detections and movement; overlap, unbound/lost/ambiguous cases remain unknown/uncertain/lost, never silently swap or accept a third entrant as a replacement. Raw Vision detections alone are not accepted calibration or reliable gameplay evidence. Tracking association and reacquisition policies need their own scoped review/tests.
- **Same-frame overlay requirement:** if subsequently authorized, match image and pose by generation/frameID/geometry and internal epoch plus the displayed fitted rect. Use a separately reviewed bounded join or omit an unmatched overlay; never use “latest pose” as a substitute. Apply the approved reflection once. Do not retain extra raw frames or create unbounded matching history to obtain overlays. Actual overlay implementation/physical validation remains future work coordinated with Kevin.
- **LH-22 dependency:** B's raw joints and identity continuity can proceed without standing calibration. Real crown/independent soles/floor offsets and player-plane scaling still require LH-22's validated standing results and same-frame pose/mask association; LH-13C later owns accepted calibration replacement/cutover and calibrated publication. No fake baseline, airborne estimate or gameplay-ready signal is introduced in B1.
- **Ownership/risk:** Edo owns Vision/tracking and source memory. Kevin reviews any diagnostic overlay integration and retains production mapping/rendering. Jevon retains calibration phase/readiness, pause/recovery, GameClock and the sole gameplay consumer. Serial inference can reduce sink cadence even when capture remains 30 FPS; benchmark Vision and preserve bounds under slow/never-finishing work. Do not allocate unbounded Tasks/requests or promise tracking quality from A2 capture measurements.

The accepted dependency direction remains **A → B → LH-22 → C → D**. Later milestones each require separate approval; no backward dependency on a live provider is added to calibration correctness.

### 9.7 Documentation-only change and Git handoff

Only `Docs/LH-13A2-Debug-Preview-Implementation-Report.md` changed in this audit: current disposition/commit context, explicitly historical labels for the initial open-gate protocol and status, and this dated acceptance/readiness addendum. Implementation details, earlier measurements, compiler evidence and prior REVISE rationale are retained.

Final verified working-tree status is the modified report, the unchanged pre-existing modified `Sedactive.xcodeproj/project.pbxproj`, and preserved untracked `Scripts/`. No source/test/fixture/other-document changes, staging, commit, push, merge, rebase, reset or branch switch are part of this audit. Suggested next manual commit contains **only this report**. Skill used for this acceptance audit: `swift-concurrency`.
