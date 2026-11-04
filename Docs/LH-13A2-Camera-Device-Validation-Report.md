# LH-13A2 — Live Camera Diagnostics & Physical iPad Validation

Date: 4 November 2026. Owner: Edo. Branch: `feat/camera-foundation`.
Baseline HEAD: `172550be3d8eea870c7963d5394fb93122ca16a7` (A1 present).

**Disposition: REVISE / acceptance incomplete.** The initial physical capture/reconstruction and cleanup run passed. The physical denied → re-enabled permission lifecycle is now **PASS by Edo's manual confirmation**, recorded separately from automated diagnostic evidence in §6. Visual orientation/mirroring and Kevin's preview review, additional lifecycle scenarios and further performance validation remain open. Do not treat these passed cases as completion of the remaining gates. No LH-13B implementation is authorized by this report.

## 1. Baseline, scope and changed files

Read AGENTS, TEAM_ALIGNMENT, the current architecture/proposal, A1 report, A1 capture/tests, CP1/CP2 contracts and App wiring. On entry there were no staged/tracked modifications; only pre-existing untracked `Scripts/`. A SHA-256 inventory of 280 existing files is retained at `/private/tmp/lh13a2/baseline.json`.

| File | A2 change |
|---|---|
| `Sedactive/App/AppDependencies.swift` | DEBUG-only stable AppDependencies composition retains one CameraPipeline and one diagnostics controller across view reconstruction. |
| `Sedactive/App/RootView.swift` | DEBUG-only Camera diagnostics button/full-screen route, explicit diagnostic launch arguments, coordinated dismiss cleanup. Existing PlayView remains default; no Kevin file edited. |
| `Sedactive/Games/LaserHeist/Debug/LiveInputDiagnosticsView.swift` | New Edo-owned numeric diagnostics UI/controller, Start/Stop, finite 30-second observation, lifecycle descriptions, 500 ms numeric polling, explicit shutdown on close/background and numeric-only export. |
| `Sedactive/Shared/BodyTracking/Capture/CameraCaptureMetrics.swift` | New checked-Sendable bounded statistics: counters, five 1024-sample latency rings, nearest-rank p50/p95, capture/sink rates and simultaneous raw/workspace byte accounting. |
| `Sedactive/Shared/BodyTracking/Capture/CameraPipeline.swift` | Read-only permission query, scoped callback/worker measurements, selected-camera configuration description and metrics-enabled default reconstruction sink. Existing ownership/configuration/lifecycle policy preserved. |
| `Sedactive/Shared/BodyTracking/Capture/FrameStore.swift` | Copy-completion scheduling timestamp separate from original capture time, independent-copy timing, admission/rejection diagnostics, reservation-linked source accounting and pool lifetime measurements. |
| `SedactiveTests/Shared/BodyTrackingTests/CameraDiagnosticsTests.swift` | Seven deterministic Swift Testing tests covering ring bounds/percentiles, context rejection, resource accounting, real synthetic CV reconstruction/reset and retained App composition/permission observation without camera startup. |
| `Docs/LH-13A2-Camera-Device-Validation-Report.md` | This report. |

**External project edit:** while the developer resolved signing in Xcode, `Sedactive.xcodeproj/project.pbxproj` changed the app's Debug/Release DEVELOPMENT_TEAM from `LG4M4S46YZ` to `PVFTHNYZFD`. The agent did not edit this file and preserved that external change. No deployment target, language mode, default actor isolation, approachable-concurrency, source membership, bundle ID or scheme change was made. This signing change must be reviewed separately from A2 source changes.

CP1/CP2 models, implementations, fixtures, gameplay/session, Kevin renderer/RCP assets, existing tests, A1 documentation and pre-existing Scripts are unchanged. No Vision, tracking, calibration, BodyInputService or cutout production is implemented.

## 2. Diagnostics ownership and operation

`AppDependencies.shared` owns the stable camera/controller. The screen receives that controller; neither body reevaluation, polling nor observers construct a source. The native session stays confined to A1's driver actor. Start delegates through the reviewed CameraPipeline API with a fresh generation. Stop cancels pending diagnostic control/observation work and awaits native/worker shutdown; it never force-reclaims retained readers.

DEBUG entry points:

- Default app flow: open **Camera diagnostics** using the DEBUG button.
- Developer launch `--camera-diagnostics`: show numeric diagnostics without starting capture.
- Explicit experimental launch `--camera-diagnostics-run`: show diagnostics and request capture for one finite 30-second interval **after successful start**. An authorization prompt may precede the interval. It automatically stops and exports; ordinary launches never auto-start.
- **Start Camera**, **Stop Camera**, **Observe 30 seconds**, **Close** remain explicit UI controls. Backgrounding invokes coordinated diagnostic shutdown; foregrounding does not silently restart. This is a diagnostic policy, not Jevon's future gameplay recovery policy.
- Numeric export overwrites one file: app `Documents/LH13A2-observation.txt`. It contains configuration/measurements/status metadata only, no image bytes, pose data or participant recordings. No camera images were saved or retrieved. Capture instrumentation remains internal/bounded in Release builds; the interactive route/controller and automatic diagnostic launch behavior compile only in DEBUG.

The screen explicitly says “Capture diagnostics only — not calibrated gameplay evidence.” Latest metadata remains labeled last-known after stop. The Start-request interval freezes at shutdown/failure; the explicitly labeled last-frame age continues increasing to show staleness. Source context/status does not claim both players are bound/calibrated or gameplay ready.

## 3. Toolchain, physical device and deployment

- Xcode 26.6 (17F113), Swift 6.3.3, iPhoneOS/iPhoneSimulator SDK 26.5.
- Target detected by CoreDevice: iPad Pro 13-inch M4 (`iPad16,5`), iPadOS 26.7.1 build 23H30; paired/available, Developer Mode enabled, developer-device services available. Developer kept it unlocked and landscape-mounted for the observation.
- SDK/device OS difference did not prevent a successful signed build, installation or capture.
- Initial signed build failed: no account/profile for configured team `LG4M4S46YZ`. Provisioning-update retry confirmed that account error.
- After the external team change, signed device build succeeded using `PVFTHNYZFD` without changing the app's bundle ID.
- Initial installation attempts were rejected because the existing app's `LG4M4S46YZ` application identifier differed. One early launch command opened the old installed app after installation had failed; that is **not** A2 execution or camera evidence. Later launch commands were explicitly gated on successful installation.
- Edo confirmed the old test app's data was disposable and manually deleted it. No device app was uninstalled by the agent. After CoreDevice confirmed the old bundle absent, installation of the new build succeeded and the explicit diagnostic run launched successfully.

The installation and physical observation evidence is stored outside the repository under `/private/tmp/lh13a2/`.

## 4. Observed native camera configuration

These are measurements from the actual first device export, not values inferred from a synthetic adapter:

| Item | Physical observation |
|---|---|
| Camera | Front Ultra Wide Camera, `AVCaptureDeviceTypeBuiltInUltraWideCamera` |
| Active native format | 1280×720; selected supported range 1–30 FPS |
| Requested / delivered | 1280×720 / 1280×720 |
| Pixel format | `0x42475241`, BGRA8 |
| Actual bytes per row | 5120 |
| Source payload | 3,686,400 bytes (stride-inclusive), below 4 MiB |
| Requested / achieved source rate | 30 / 30.003 FPS |
| Completed controlled-sink rate | 30.003 FPS |
| Center Stage | Supported by selected format; inactive in the run |
| Stabilization | Off |
| Zoom | A1 required/set zoom 1; native setup validation succeeded; no observed geometry-change failure |
| Rotation / mirror provenance | Capture connection 0° / false; actual callback checks passed |
| Session preset | `AVCaptureSessionPresetInputPriority` |
| Clock | Session synchronization-clock conversion yielded valid original host-domain capturedAt through frame 901 |
| Generation / geometry revision | Fresh generation, revision 1 in initial run; frameIDs advanced to 901 |

No rear/audio/format fallback occurred. Global Center Stage settings were not modified. Supported/active flags and numeric rotation do not prove optical uprightness or correct display mirroring; that visual gate remains open.

## 5. Physical measurement method and results

**Run 1:** actual signed DEBUG app, finite 30-second capture/reconstruction interval after native start, with the numeric diagnostics screen visible. The normal RealityKit PlayView remains the underlying DEBUG app flow; this was not an isolated Release performance benchmark. No Vision/pose/calibration/segmentation/GPU upload work was part of the sink. The developer granted camera access; the report's permission query reads authorized.

Host-clock seconds are used throughout. `capturedAt` comes from the original sample PTS converted from the actual session clock. Instrumentation never rewrites capture time. Scheduling timestamps are separate values.

Five finite rings retain at most 1024 samples each. Nearest-rank p50/p95 are calculated from the retained samples; the first run contains all 901 samples. Counters remain bounded/saturating. Numeric UI refresh runs at 2 Hz, not once per image. Instrumentation has nonzero overhead and these DEBUG results are observations, not production guarantees.

| Measurement | Run 1 result |
|---|---|
| Delivered / admitted / completed | 901 / 901 / 901 |
| Source / sink FPS | 30.003 / 30.003 |
| Admission / replacement mean rate | 30.037 / 0 per capture-span second (count/span, hence one-frame endpoint difference versus FPS) |
| AV dropped callbacks | 0 |
| Pending replacements | 0 |
| Capacity / construction / owner-byte budget rejects | 0 / 0 / 0 |
| Stale / sink rejects | 0 / 0 |
| Callback total p50 / p95 | 0.548 / 0.738 ms |
| Independent Data-copy p50 / p95 | 0.487 / 0.667 ms |
| Copy-complete → worker wait p50 / p95 | 0.048 / 0.061 ms |
| Reconstruction-only sink p50 / p95 | 6.260 / 7.225 ms |
| Capture → sink completion p50 / p95 | 50.395 / 51.552 ms |
| Start request → ready | 4476.800 ms, includes first authorization interaction |
| Awaited shutdown | 65.163 ms |
| Total elapsed since Start request at export | 34.575 s |
| Current / peak raw owners | 0 / 1 after stop |
| Current / peak raw payload bytes | 0 / 3,686,400 |
| Current / peak reconstructed CV bytes | 0 / 3,686,400 |
| Current / simultaneous peak owned pixel bytes | 0 / 7,372,800 (about 7.03 MiB) |
| Thermal state at export | 0 (`nominal`) |
| CPU utilization / process RSS | Not measured; pixel accounting is not RSS |

Method boundaries:

- Callback total covers `didOutput`, metadata validation/copy/admission and measurement work before the final timer read; AV dropped callbacks are counted separately. It does not include all framework scheduling before entry.
- Data-copy time includes fresh Data allocation/zeroing and visible row copies, excluding source lock acquisition and earlier metadata validation. Padding is initialized rather than copied from unrelated source memory.
- Worker wait starts at owned-frame construction after copy completion; it includes mailbox admission/scheduling overhead. Sink timing is actual worker reconstruction, not pose inference.
- Capture-to-completion includes upstream capture/delivery delay as well as application processing. The measured ~50 ms must not be replaced with the ~6 ms sink time. This run alone does not identify the source of upstream delay or authorize latency compensation in GameClock.
- The largest measured application stage is the reconstruction-only sink. No backlog/drop or budget-pressure bottleneck was observed at 30 FPS in this finite run; future Vision work may change the result. No sustained/thermal/production threshold is inferred.
- Current and peak raw resource counts remain tied to final owners, including retired contexts; pool lifetime is accounted until reset. Combined peak tracks simultaneous raw/workspace totals, rather than adding unrelated historical peaks. AVFoundation-owned buffers, allocators, framework/renderer memory and total RSS are excluded.

## 6. Physical lifecycle and visual acceptance ledger

| Scenario | Evidence / disposition |
|---|---|
| First request → authorized → native running | Real first run: requestingPermission → configuring → running; final permission query authorized. Native record does not itself prove exact OS prompt artwork. |
| Finite capture → explicit coordinated Stop | Observed: 901 completions; raw/workspace current bytes zero; stopped status; measured shutdown 65.163 ms. |
| Repeated Start/Stop, new generations | A subsequent real numeric export reached geometry revision 10 with a different generation, frameID 144 and 144 completions, the same negotiated format, zero drops/rejects and zero retained bytes after stop. This proves repeated native generations, not arbitrary race coverage. |
| Close/reopen and retained view composition | Single retained source/controller proven structurally and by deterministic test; physical Close/reopen still pending confirmation. |
| SwiftUI view recreation without another camera | Stable dependency composition tested; arbitrary physical recreation not instrumented. |
| Background/foreground | Diagnostic code stops on background, requires explicit restart. Observed in corrected device export: explicit scene-background shutdown reason, then native interruption reason 1, then stopped; last frame 294, raw/workspace bytes zero. Edo also confirmed the corrected background check passed (stopped status, fixed frameID/interval, zero bytes). Diagnostic policy requires explicit restart after foreground, not gameplay recovery. |
| Denied access / Settings change | **PASS — developer-observed physical test, confirmed by Edo on 4 November 2026.** With Camera disabled in Settings, Start Camera reported access denied and instructed enabling access in Settings. After re-enabling permission and returning, Start Camera succeeded and capture operated normally. This updates the earlier untested status; it is manual confirmation, not a new automated diagnostic export. |
| Stop during startup/permission | Deterministic continuation tests pass; no physical startup-race evidence yet. |
| Native interruption/recovery without a subsequent frame | Real background interruption reason 1 was observed before coordinated stop, with last capture preceding it; generic phone/system interruption and automatic recovery were not tested. Deterministic native-event tests remain separate. |
| Late callbacks/worker cleanup across restart | Deterministic tests pass; real initial shutdown releases measured payloads. Further physical restart races untested. |
| Source failure without frames | Deterministic tests pass; no fabricated physical fault injection. |
| Optical uprightness / displayed mirror | Not visually tested: no preview implemented. Numeric source rotation/mirroring is insufficient. |

### Developer-observed permission lifecycle confirmation

On **4 November 2026**, Edo confirmed both checks on the **iPad Pro 13-inch M4 running iPadOS 26.7.1**:

1. **Camera permission disabled → Start Camera: PASS.** Sedactive correctly reported camera access denied and displayed the instruction to enable access in Settings.
2. **Camera permission re-enabled → return to Sedactive → Start Camera: PASS.** The camera started successfully and capture operated normally.

**Evidence source:** Edo's direct manual device observations supplied in this chat. No new automated diagnostic export, frame counters, latency measurements or memory measurements were supplied for these two checks; none are inferred from the confirmation. Existing automated tests and numeric exports remain separately identified in §5–7. This closes the physical denied → re-enabled permission lifecycle gate only; it does not close preview/orientation review, other lifecycle scenarios or further performance validation.

### Preview ownership gate

The proposed DEBUG transform is physically upright unmirrored source followed by **one horizontal display reflection** inside the preview content area, with any debug overlay using the same effective transform. No global RealityKit/lane flip is proposed. Kevin has not accepted/visually reviewed that integration here.

A minimal compiler probe attempted to return the retained actor-owned AVCaptureSession for MainActor AVCaptureVideoPreviewLayer attachment. Complete checking with warnings-as-errors rejects it: “non-Sendable AVCaptureSession-typed result can not be returned from actor-isolated instance method … to main actor-isolated context.” The same result occurs for both SDKs.

Therefore that direct borrowing path was not added to production. This is not a claim that every possible safe preview adapter is impossible. Edo/Kevin must review a safe same-session adapter or a separately bounded image-preview option/budget before implementation. No unchecked Sendable, unsafe nonisolation or second session is used. Numeric diagnostics work independently. Production PlayView/renderer/overlays are untouched.

### Corrected physical background export

`/private/tmp/lh13a2/physical-background-corrected.txt` records a later native run on the corrected screen: generation FF959191-7151-4851-8163-A6726C2D1309, geometry revision 3, 294 delivered/admitted/completed frames at 30.003 source FPS, zero drops/rejects, and zero raw/workspace bytes after stop. Its request interval is frozen at 10.415 seconds; awaited shutdown is 5.369 ms. The bounded history explicitly records `diagnostics shutdown requested: scene background`, then real interruption reason 1, then stopped. This confirms background shutdown on device; it does not test automatic recovery, since diagnostic foreground behavior requires explicit Start.

## 7. Verification

| Gate | Result |
|---|---|
| Debug Simulator app build | PASS |
| Signed M4 iPad app build | PASS after external signing fix |
| Physical installation / explicit diagnostic launch | PASS after manual old-app deletion |
| Test-target build | PASS |
| Focused A1/A2 tests, final | 33 definitions / 40 executions; 0 failures/skips |
| Full Simulator regression | 133 definitions / 209 executions in 17 suites; 0 failures/skips |
| Existing CP1/CP2/gameplay suites | Included and passed; source/assertions unchanged |
| Release Simulator build | PASS, arm64/x86_64; DEBUG controller/route/launch strings absent from resulting binary |
| Strict concurrency + WAE SIL/WMO | PASS for Capture, new diagnostics view/controller, AppDependencies and focused tests, both iPhoneOS and Simulator SDKs |
| Actual nonisolated sample delegate registration/invocation | Compiler probe passes against production delegate, both SDKs |
| Ownership negative controls | Retained mutable workspace and actor-isolated delegate registration each rejected as expected on both SDKs |
| Preview boundary characterization | Expected non-Sendable actor-to-MainActor session transfer rejection on both SDKs |
| Source membership | 54 app / 25 test compile entries, no duplicates; new tests excluded from app |
| Replay fixtures | All four JSON fixtures byte-identical, one copy each in test bundle; actual replay tests pass |
| Git whitespace / preservation | `git diff --check` passes; no baseline file missing; only intended source files and external two-line team edit differ |

No successful strict gate used unsafe suppression or weakened settings. Observation macros are loaded explicitly in isolated compiler commands; an initial sandboxed macro-plugin-server attempt failed due sandbox execution restrictions and was rerun with the compiler's supported macro-library loading option. These failures are distinguished from successful source/compiler results.

Build logs contain the existing AppIntents metadata-extraction warning (no AppIntents dependency). Hosted Simulator tests also retain the existing renderer asset-path startup message. No Swift/concurrency diagnostic remains in successful verification. These are not hidden by modifying renderer/resources or assertions.

### Actual commands and evidence paths

All commands use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```bash
xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/lh13a2/Derived SWIFT_STRICT_CONCURRENCY=complete build

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS,id=00008132-000668913A05001C' \
  -derivedDataPath /private/tmp/lh13a2/DeviceDerived -allowProvisioningUpdates \
  SWIFT_STRICT_CONCURRENCY=complete build

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/lh13a2/Derived SWIFT_STRICT_CONCURRENCY=complete build-for-testing

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/lh13a2/Derived \
  -resultBundlePath /private/tmp/lh13a2/FocusedFinalA2.xcresult \
  -only-testing:SedactiveTests/CameraPipelineTests \
  -only-testing:SedactiveTests/FrameStoreTests \
  -only-testing:SedactiveTests/CameraDiagnosticsTests \
  SWIFT_STRICT_CONCURRENCY=complete test-without-building

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive \
  -destination 'platform=iOS Simulator,id=1E1C6B07-B356-4303-8756-4C0D2A4CDF05' \
  -derivedDataPath /private/tmp/lh13a2/Derived \
  -resultBundlePath /private/tmp/lh13a2/FinalA2.xcresult \
  SWIFT_STRICT_CONCURRENCY=complete test-without-building

xcodebuild -project Sedactive.xcodeproj -scheme Sedactive -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/lh13a2/ReleaseDerived SWIFT_STRICT_CONCURRENCY=complete build

bash /private/tmp/lh13a2/verify-strict.sh
```

The isolated script compiles Swift 5/default MainActor/approachable upcoming features with complete checking, warnings as errors, SIL/WMO and object/WMO; verifies actual explicitly nonisolated callbacks; builds the focused test module with Swift Testing; and checks A0 negative controls plus the preview probe. No project settings are rewritten. Scratch scripts/probes stay outside the repository.

Device installation/launch were run sequentially with shell `set -e` after the early failed-install/old-launch mistake:

```bash
xcrun devicectl device install app --device EACE936C-8830-54AE-B2B1-60654C90B8EA \
  /private/tmp/lh13a2/DeviceDerived/Build/Products/Debug-iphoneos/Sedactive.app
xcrun devicectl device process launch --device EACE936C-8830-54AE-B2B1-60654C90B8EA \
  --terminate-existing com.Edward-Kristian.Sedactive --camera-diagnostics-run
xcrun devicectl device copy from --device EACE936C-8830-54AE-B2B1-60654C90B8EA \
  --domain-type appDataContainer --domain-identifier com.Edward-Kristian.Sedactive \
  --source Documents/LH13A2-observation.txt \
  --destination /private/tmp/lh13a2/physical-observation-1.txt
```

`physical-observation-1.txt` is the actual numeric export used in §4–5; `physical-lifecycle-latest.txt` preserves the secondary pre-correction revision-10 export. Its no-op shutdown timing is not used as a valid shutdown benchmark. Successful installation/launch JSON is `install-cleared.json` / `launch-diagnostics.json`. Builds: `app-build-final.log`, `device-build-current-team.log`, `device-build-corrected.log`, `test-build-final-a2.log`, `release-build-final.log`; strict result: `strict-final-a2.log`; test bundles: `FocusedFinalA2.xcresult` and `FinalA2.xcresult`. Earlier failed signing/install logs remain explicitly separate evidence.

## 8. A1 fixes, remaining work and ownership

No actual A1 camera/ownership bug was exposed by the completed initial physical run, so no A1 behavior was relaxed.

**Device-exposed A2 corrections:** Edo reported that the elapsed label continued increasing after backgrounding. The numeric device export showed stopped status, fixed frame 144 and zero source/workspace bytes; it did not show ongoing capture. The label had been computing time-since-request indefinitely. It now freezes after completed shutdown/failure, with an injected-clock deterministic regression; last-frame age intentionally remains an increasing staleness diagnostic. Repeated Close/onDismiss/Stop requests previously overwrote the first awaited shutdown duration with a near-zero no-op (0.002 ms in the secondary export). Cleanup is now coalesced and idempotent at the diagnostics-controller level; the first completed shutdown measurement is preserved. Background shutdown requests also add an explicit bounded reason entry to the numeric history. The corrected app was built, installed and launched on the same device without a signing identity change or app-data deletion.

The first version of the new test used a mutable captured local clock value. The isolated complete/WAE SIL gate rejected that capture even though the app test build accepted it. It was replaced by an explicitly MainActor-owned test clock, not a diagnostic suppression. Final complete/WAE SIL gates passed with that checked test implementation. Changes are diagnostics, internal timing metadata and source/workspace accounting. No camera ownership rule, capture geometry setting or CP1 semantics changed. CP1 capture timestamps, revisions and contracts remain intact.

Required to finish A2 acceptance:

1. Record outstanding physical lifecycle cases (or explicitly agree a narrower acceptance ledger), including Close/reopen confirmation, arbitrary view recreation, stop during startup, broader interruption/recovery and restart/failure races. Permission denial/re-enabling is now closed by manual confirmation; keep it distinct from automated numeric evidence.
2. Edo/Kevin review the safe preview ownership/transform before implementing it, then verify optical orientation/mirroring on the real mounted iPad. No unsafe session sharing to bypass the compiler gate.
3. Review the measured DEBUG latency and bounds; obtain further device/thermal/CPU/RSS/optimized-build evidence if needed before performance acceptance. This does not authorize alternate raw-frame architecture, format changes or Vision implementation.
4. Review/preserve the external signing-team edit separately when integrating Git changes.

**Permission-confirmation documentation follow-up:** only this report was revised. Consistency, whitespace and file-preservation checks were performed; no Swift, tests, project settings or other documents changed, and no build, automated test or device run was repeated for this documentation update. Previously reported automated results retain their original provenance.

Jevon's session/GameClock/recovery policy is unchanged. Kevin's production renderer and visual fallback are unchanged. There is no new gameplay consumer, no fake calibrated BodySnapshot and no live BodyInputService wiring.

## 9. Git and skills

Branch and HEAD remain the baseline above. No stage, commit, push, merge, rebase, reset or branch switch was performed.

Final changed/untracked paths (all unstaged):

```text
 M Sedactive.xcodeproj/project.pbxproj                         # external developer signing-team edit
 M Sedactive/App/AppDependencies.swift
 M Sedactive/App/RootView.swift
 M Sedactive/Shared/BodyTracking/Capture/CameraPipeline.swift
 M Sedactive/Shared/BodyTracking/Capture/FrameStore.swift
?? Docs/LH-13A2-Camera-Device-Validation-Report.md
?? Scripts/                                                  # pre-existing; byte-preserved
?? Sedactive/Games/LaserHeist/Debug/LiveInputDiagnosticsView.swift
?? Sedactive/Shared/BodyTracking/Capture/CameraCaptureMetrics.swift
?? SedactiveTests/Shared/BodyTrackingTests/CameraDiagnosticsTests.swift
```

No source/resource was deleted. All baseline files outside the four intended implementation/App changes and external team edit retain their original hashes. No staged changes exist.

Skills read/applied: `swift-concurrency`, `swift-testing-expert`, `swiftui-expert-skill` (checked actor ownership, real negative gates, bounded observation/metrics, stable SwiftUI dependency lifetime and deterministic tests).
