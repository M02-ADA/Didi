# LH-13A2 — Bounded DEBUG Preview Implementation

**Disposition: implementation candidate ready for review; LH-13A2 remains REVISE, not fully accepted.**

Owner: Edo. Date: 4 November 2026. Branch: `feat/camera-foundation`.
Starting and current HEAD: `499f865494e65a2e8b35a4e228ef963eb936f650`.

The bounded owned-frame preview is implemented. Compiler, ownership, deterministic regression and initial physical comparison evidence are recorded below. Edo confirmed uprightness, mirror-like movement, full-image aspect fit and disappearance after Stop. Additional physical lifecycle/orientation coverage, Kevin's review and extended performance validation remain open. LH-13B is not implemented or authorized.

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

## 7. Physical confirmations and repeatable remaining protocol

**Developer-observed:** Edo confirmed the image is upright, movement is mirrored, the camera image is visible within the yellow aspect-fit border, and Stop removes the photo and displays “No current compatible preview.” This is manual confirmation, not automated visual analysis. Numeric export separately confirms actual pixel format/rates/resources. No claim is made about exact display-frame atomicity.

Remaining device protocol:

1. For extended repeatability, repeat longer alternating off/on windows using the same mount, lighting and UI. Save each numeric export before another run overwrites it. The final-build 30-second comparison above is complete; longer performance/thermal stability is still open.
2. Use asymmetric top/bottom/left/right markers and move each arm; verify the full field and fitted borders, readable UI labels, one image mirror, and exact corner mapping. Existing manual upright/mirror confirmation does not replace all marker tests.
3. Rotate between landscape positions. A1's geometry guard may stop capture; expect immediate stale-image clearing, then explicit Stop/Start under the new accepted orientation. Do not bypass that guard or apply a second image rotation.
4. With preview visible, background/foreground, deny/re-enable permission, close/reopen and repeat Start/Stop. Verify clear-without-new-frame, new generation/epoch metadata, no old image reappearing and eventual provider-credit release. Earlier numeric-only A2 lifecycle passes remain separate.
5. Repeat longer alternating windows with UI load. Record callbacks, primary drops, preview skips/age, explicit memory and RSS trend; distinguish framework caches from pinned Data. Agree performance limits from observations, not invented thresholds.

Kevin's effective preview/overlay transform review and future same-source pose overlay integration remain open. No pose data/gestures or new gameplay readiness were added.

## 8. Reproduction and final status

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

No fundamental ownership/compiler/budget blocker remains in the implementation. Full A2 acceptance is nevertheless **not** claimed: remaining physical lifecycle/orientation cases, extended performance validation, cadence usability and Kevin's review are explicit gates. Final-build paired measurements are complete. LH-13B remains untouched.

No stage, commit, push, merge, rebase, reset or branch switch occurred. The existing signing edit, untracked review and Scripts remain preserved. Skills applied: swift-concurrency, swift-testing-expert, swiftui-expert-skill.
