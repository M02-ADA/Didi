# LH-00 CP2 — Bounded runtime ownership comparison

Edo / 3 November 2026. **Recommendation: Data-copy as the candidate for Edo/Kevin's next integration review; no production model is selected or approved by this experiment.** Both candidates passed the bounded CPU-only ownership checks. Data preserves producer/consumer overlap; whole-owner serializes them and stalls production while ownership is away. Data costs extra copying/memory and did not win every latency comparison.

**These are native macOS development-host results, not physical-iPad, Simulator, Metal or RealityKit benchmarks.** No camera, Vision, segmentation, GPU command, actual GPU completion or participant imagery was used.

## 1. Exact implementation, environment and commands

Checkout remained `staging`, HEAD `269c5c849e7020a3c686d4ef56ea5a552d20fc6b`. No Git state mutation, branch switch/worktree, project-setting change, production Swift/test edit or proposal edit. The two prior investigation reports and the 31-case characterization are preserved; the 31 experiments were not repeated.

New implementation files (all experiment code outside app/test target roots):

| File | Responsibility |
|---|---|
| `Scripts/CP2Spike/Runtime/RuntimeCommon.swift` | Checked arithmetic, common deterministic BGRA pattern and byte verifier, bounded CPU Core Video pool, private raw-buffer pairs, independently copied immutable Data pairs, checked-Sendable mutex ledger. |
| `Scripts/CP2Spike/Runtime/Scenario.swift` | One latest capture slot, one latest Data slot, controlled consumer/handoff gates, independent simulated CP1 publisher, serial whole-owner and actor-confined copying pumps, monotonic metrics. |
| `Scripts/CP2Spike/Runtime/RuntimeTests.swift` | 25 deterministic assertion groups, explicit completion permits, scoped actual task cancellation, pool exhaustion and cleanup checks. |
| `Scripts/CP2Spike/Runtime/ComparisonMain.swift` | Bounded CLI, warmup, finite arrival schedule and measurement window; real ownership negative-control flag. |
| `Scripts/CP2Spike/Runtime/run-comparison.py` | Correctness first, two counterbalanced benchmark trials, fresh processes, finite watchdogs, raw JSON and percentile aggregation. |
| `Scripts/CP2Spike/RuntimeBackingProbe.swift` | Separate reproducible CPU-vs-requested-IOSurface Core Video allocation diagnostic; no GPU work. |
| `Scripts/CP2Spike/run-runtime-comparison.sh` | Complete-checking SIL/build, two diagnosed negative controls, optimized native executable and runner. |
| `Scripts/CP2Spike/Runtime/Results/macos-m5-2026-11-03.json` | Retained raw timing/resource records, correctness results, diagnostics, environment and source SHA-256 hashes. No pixel arrays or recordings. |

This standalone assertion executable needs no new package/Xcode target or unstable test-runner entry point. Failures cause nonzero exit; it is not an app-target Swift Testing run. Existing CP1 tests were not modified or rerun.

Reproduce everything from repository root:

```bash
CP2_RUNTIME_OUTPUT=/private/tmp/cp2-runtime/final \
  bash Scripts/CP2Spike/run-runtime-comparison.sh
```

Compile/negative-control gates only:

```bash
CP2_RUNTIME_OUTPUT=/private/tmp/cp2-runtime/final CP2_RUNTIME_BUILD_ONLY=1 \
  bash Scripts/CP2Spike/run-runtime-comparison.sh
```

Individual execution after building:

```bash
/private/tmp/cp2-runtime/final/comparison --correctness \
  --output /private/tmp/cp2-runtime/final/correctness.json
/private/tmp/cp2-runtime/final/comparison --model copy --scenario slow \
  --warmup 12 --frames 90 --hz 60 \
  --output /private/tmp/cp2-runtime/final/example-copy-slow.json
/private/tmp/cp2-runtime/final/backing-probe /private/tmp/cp2-runtime/final/backing.json
```

Environment: Mac17,2 / Apple M5 / 24 GiB RAM, macOS 26.5.2 (25F84), Xcode 26.6 (17F113), Apple Swift 6.3.3, MacOSX26.5 SDK, native arm64 macOS 26.0 target. Global xcode-select settings were untouched; commands explicitly set DEVELOPER_DIR. The app still uses Swift 5/default MainActor/approachable concurrency/iPadOS 26.5.

### Backing limitation discovered, not hidden

Core Video created both pools successfully, but requesting IOSurface-backed buffers failed with `kCVReturnAllocationFailed` (-6662) for both alignments. The failure persisted in an outside-sandbox diagnostic attempt. The runtime logged `kIOSurfaceMethodSetCoreVideoBridgedKeys failed: 10000003`; its underlying cause is not established. **Do not interpret -6662 as proven physical-memory exhaustion.**

The comparison therefore explicitly uses **CPU-backed** pools for both models, appropriate to this CPU-only scope. It is not a workaround proving future Metal compatibility. The retained backing probe reproduces the limitation:

| Requested storage | Row alignment | Pool status | Buffer status | Actual stride |
|---|---:|---:|---:|---:|
| CPU | 64 | 0 | 0 | 2048 |
| CPU | 4096 | 0 | 0 | 4096 |
| IOSurface requested | 64 | 0 | -6662 | unavailable |
| IOSurface requested | 4096 | 0 | -6662 | unavailable |

Core Video also emitted a denied `kern.hv_vmm_present` query diagnostic in this tool environment; CPU allocations and checks still succeeded. Initial IOSurface runs were failed attempts, excluded from accepted results. Error propagation now opens **test** gates, lets CPU readers finish, and joins tasks on a failed run rather than leaving an assertion driver suspended. It is not a GPU cancellation/reclamation policy.

## 2. Compiler verification

Positive runtime and backing-probe **SIL compilation passed with zero compiler diagnostics**, followed by clean optimized executable builds. Runtime flags retain Swift 5, `-strict-concurrency=complete`, `-warnings-as-errors`, default MainActor, and the same applicable features:

```text
-parse-as-library -swift-version 5 -strict-concurrency=complete -warnings-as-errors
-default-isolation MainActor
-enable-upcoming-feature NonisolatedNonsendingByDefault
-enable-upcoming-feature InferIsolatedConformances
-enable-upcoming-feature InferSendableFromCaptures
-enable-upcoming-feature GlobalActorIsolatedTypesUsability
-enable-upcoming-feature DisableOutwardActorInference
```

The gate uses `-emit-sil -whole-module-optimization`; timed executables use `-O -whole-module-optimization`. Only SDK/target are native macOS for execution. No project/global settings changed, no typecheck-only acceptance and no unchecked Sendable, unsafe nonisolation, preconcurrency suppression, ownership casts or detached tasks.

Both independent negative controls were rejected as expected:

1. The actual runtime WholeWorkspace retained in a producer alias and written after `prepareWhole(owner, ...)` sends it: `sending 'owner' risks causing data races`.
2. The original `NegativeOwnershipControl.swift` writer-after-transfer example: `sending 'value' risks causing data races`.

Those rejections are successful guard checks, not successful compilation of unsafe code. The known dictionary-literal diagnostic gap was not used. Mutex protects only scalar/identity/resource instrumentation across executors and synchronous ARC destruction; no image reference is stored in it. Scoped pointer access paints/verifies/copies bytes, never transports pointer ownership.

## 3. Equivalent workloads and measurement method

Each logical frame contains deterministic P1/P2 **512×768 premultiplied BGRA8** canvases: P1 red/P2 blue, sequence-dependent green pattern, opaque interior, alpha-128 soft edge and zero-alpha/zero-RGB border. Independent known-byte anchors validate BGRA byte order and premultiplication; every visible pixel and every padding byte is checked. Consumer verification runs **before and after its hold** for both models. No color-management/sRGB sampling or material behavior is inferred from these bytes.

Normal stride is 2048 bytes: 1.5 MiB/image, 3 MiB/pair. Padded-row correctness uses actual stride 4096: 3 MiB/image, 6 MiB/pair, with 0xA5 padding checked separately. Checked multiplication rejects overflow, short stride and image sizes above 8 MiB. Only fixed supported synthetic dimensions enter pixel access.

- Both use one persistent pool with allocation threshold **six on every allocation**. Same paint and validation functions, frame keys, arrival schedule, fault strategy and work ceilings.
- One latest metadata request, one active production job, at most one pending Data pair and one consumer-held pair. Whole-owner cannot use all of those overlapping slots simultaneously. No camera/YUV source frames or masks exist; “source buffers” below mean pooled synthetic BGRA buffers.
- Heavy painting/copy/verification runs on background concurrent functions or the producer actor, not MainActor. MainActor performs gates, bounded metadata and measurement bookkeeping.
- A finite serial whole-owner sending scope is reused across frames; the producer is unavailable until its consumer returns it. No per-frame task, unbounded input FIFO or replacement-pool loop. Its finite recursive driver is an experiment, not a production infinite-pump implementation.
- Data's producer actor retains all raw CV resources, deep-copies completed bytes using Data(bytes:count:) under read-only locks, then returns only checked Sendable immutable bytes/scalars. No Data(bytesNoCopy:), escaped base address or CV alias crosses executors. Data can outlive source reuse.
- Each of 20 fresh benchmark processes uses **12 fully validated warmup pairs**, then **90 scheduled frames at nominal 60 Hz** (1.5-second observation). Five scenarios × two models × two trials. Trial 1 runs whole then copy; trial 2 reverses order. Total **240 warmup pairs and 1800 offered measurement frames** across all benchmark processes.
- No-delay, 8-ms requested delay, 50-ms requested delay, 8-ms with faults, and no completion during observation. Fault requests alternate fail/cancel after acquisition every tenth measurement offer. Correctness tests additionally cover pre-production cancellation/failure and actual Task.cancel.
- Correctness uses explicit milestones/permits, **no sleep-based pass criterion**. Only benchmarks use monotonic sleep scheduling. Process watchdogs fail hung tests; they never establish successful ownership recovery.

Times use DispatchTime uptime nanoseconds; synchronous producer/copy stages also use CLOCK_THREAD_CPUTIME_ID. Per-frame CPU values cover allocation/fill/copy-stage work; some ARC cleanup after the sample and actor hops are outside that CPU interval. Copy time includes read locks, Data allocation and explicit copying. p50/p95 use linear interpolation over pooled per-frame samples from the two final trials. No GPU time is measured.

Completion means **simulated CPU consumer completion**, not display/scanout. Admission-to-acquire and admission-to-completion start at actual frame offer, separate from nominal schedule lateness. Consumers validate twice; that extra CPU validation is part of reported end-to-end latency. Requested sleeps may overshoot because of OS scheduling; actual hold times are recorded. Runs were not thermally isolated, frequency-locked or isolated from other Mac workloads. Two short trials characterize this harness, not statistical/device certification or maximum possible throughput; the 60-Hz input caps no-delay FPS.

## 4. Deterministic runtime correctness

**25/25 scenario groups passed; 0 failed, 0 skipped** in the final run. These are standalone runtime assertions, not Xcode/Simulator test results. All final benchmark consumers also validated their admitted bytes without error.

| Scenario group | Result | Evidence |
|---|---|---|
| whole: exact two-player bytes, packed rows and reuse | PASS | 5 P1/P2 frames checked byte-for-byte twice; checked row padding and pool identities |
| whole: exact two-player bytes, padded rows and reuse | PASS | 5 P1/P2 frames checked byte-for-byte twice; checked row padding and pool identities |
| whole: delayed/never-in-window, CP1 progress, immutable hold, latest-frame resume | PASS | 16 offers while first consumer gated; no replacement pools; explicit return only after observation; no permanent-loss recovery claimed |
| whole: cancelBefore | PASS | safe cleanup and next frame progress |
| whole: failBefore | PASS | safe cleanup and next frame progress |
| whole: failAfter | PASS | safe cleanup and next frame progress |
| whole: cancelAfter | PASS | safe cleanup and next frame progress |
| whole: generation invalidation | PASS | old acquired output rejected at completion; one pool |
| whole: six sessions | PASS | same pool across generations, zero checked-out/copy resources after join |
| whole: pool exhaustion | PASS | 7th buffer rejected; releasing holders restored capacity; balanced locks |
| whole: actual Task.cancel while consumer owns resources | PASS | cancel did not force-release held resources; explicit completion returned ownership before join |
| whole: actual cancellation during handoff | PASS | explicit pre-acquisition gate; no forced resource release; cancelled output never accepted |
| copy: exact two-player bytes, packed rows and reuse | PASS | 5 P1/P2 frames checked byte-for-byte twice; checked row padding and pool identities |
| copy: exact two-player bytes, padded rows and reuse | PASS | 5 P1/P2 frames checked byte-for-byte twice; checked row padding and pool identities |
| copy: delayed/never-in-window, CP1 progress, immutable hold, latest-frame resume | PASS | 16 offers while first consumer gated; no replacement pools; explicit return only after observation; no permanent-loss recovery claimed |
| copy: cancelBefore | PASS | safe cleanup and next frame progress |
| copy: failBefore | PASS | safe cleanup and next frame progress |
| copy: failAfter | PASS | safe cleanup and next frame progress |
| copy: cancelAfter | PASS | safe cleanup and next frame progress |
| copy: generation invalidation | PASS | old acquired output rejected at completion; one pool |
| copy: six sessions | PASS | same pool across generations, zero checked-out/copy resources after join |
| copy: pool exhaustion | PASS | 7th buffer rejected; releasing holders restored capacity; balanced locks |
| copy: actual Task.cancel while consumer owns resources | PASS | cancel did not force-release held resources; explicit completion returned ownership before join |
| copy: actual cancellation during handoff | PASS | explicit pre-acquisition gate; no forced resource release; cancelled output never accepted |
| checked image arithmetic | PASS | overflow/short-stride rejected |

Pool exhaustion holds three two-buffer pairs, observes rejection of the seventh requested buffer with kCVReturnWouldExceedAllocationThreshold, releases holders, then successfully allocates again. It never frees a still-owned buffer to satisfy allocation. Standard cases reuse fewer buffer identities than frames; repeated-session tests use one pool through six synthetic generations.

The delayed correctness test withholds completion while 16 CP1 offers arrive. Whole-owner produces only the first pair while away and replaces metadata. Data continues production, replaces its one pending pair and preserves the first immutable pair while raw sources are repainted through sequence 16. After an explicit permit, each resumes with the latest frame. Full before/after checks detect changed held bytes.

## 5. Actual performance results

Aggregated counts are over two measured windows per row. CPU/copy/latency columns are **p50 / p95 milliseconds**. Completed FPS is within-window successful completion, not offered FPS. Drained-after-window frames are excluded. A dash means not applicable/no completion, never a fabricated zero-latency success.

| Scenario | Model | Produced / completed | Producer CPU ms | Copy stage CPU ms | Admission→completion ms | Completed FPS |
|---|---|---:|---:|---:|---:|---:|
| No delay | Whole owner | 180 / 180 | 1.946 / 1.987 | — / — | 5.414 / 5.861 | 59.85 |
| No delay | Data copy | 180 / 180 | 2.331 / 2.811 | 0.541 / 0.831 | 5.677 / 6.828 | 59.84 |
| 8 ms requested | Whole owner | 180 / 179 | 1.951 / 2.209 | — / — | 16.453 / 18.802 | 59.62 |
| 8 ms requested | Data copy | 180 / 179 | 2.619 / 3.033 | 0.571 / 0.806 | 15.829 / 19.211 | 59.61 |
| 50 ms requested | Whole owner | 50 / 48 | 2.701 / 3.029 | — / — | 67.965 / 76.219 | 15.95 |
| 50 ms requested | Data copy | 180 / 50 | 3.456 / 6.244 | 0.868 / 1.288 | 71.385 / 80.505 | 16.62 |
| 8 ms + faults | Whole owner | 180 / 162 | 1.949 / 2.209 | — / — | 16.486 / 19.568 | 53.93 |
| 8 ms + faults | Data copy | 180 / 162 | 2.552 / 2.793 | 0.562 / 0.785 | 16.377 / 16.725 | 53.96 |
| No completion in window | Whole owner | 2 / 0 | 1.173 / 1.225 | — / — | — / — | 0.00 |
| No completion in window | Data copy | 180 / 0 | 4.672 / 6.312 | 0.964 / 1.449 | — / — | 0.00 |

Whole-owner's never-completing row has only **two producer samples** (one per trial), so its CPU percentiles are descriptive, not robust tail estimates. Failed/canceled frames are not counted as successful completions. Late post-window outcomes remain outside the table; full records are retained.

### Handoff/return and actual hold

“Handoff” includes coordinator/queue age from producer completion to consumer acquisition; it is not a bare Swift executor microbenchmark. Whole-owner return is completion→background worker resumption. Data has no resource owner to return. Actual median wait shows why requested delay must not be treated as exact elapsed time.

| Scenario | Model | Handoff p50/p95 ms | Return p50/p95 ms | Admission→acquire p50/p95 ms | Actual hold p50 ms | Completion samples |
|---|---|---:|---:|---:|---:|---:|
| No delay | Whole owner | 0.0057 / 0.0081 | 0.0049 / 0.0060 | 1.980 / 2.028 | 0.000 | 180 |
| No delay | Data copy | 0.0287 / 0.0546 | — / — | 2.400 / 2.948 | 0.000 | 180 |
| 8 ms requested | Whole owner | 0.0056 / 0.0074 | 0.0049 / 0.0067 | 2.253 / 3.870 | 10.084 | 179 |
| 8 ms requested | Data copy | 0.0307 / 0.0397 | — / — | 2.689 / 3.124 | 10.075 | 179 |
| 50 ms requested | Whole owner | 0.0104 / 0.0195 | 0.0112 / 0.0148 | 7.779 / 15.490 | 53.184 | 48 |
| 50 ms requested | Data copy | 8.3674 / 18.4861 | — / — | 12.653 / 22.775 | 53.192 | 50 |
| 8 ms + faults | Whole owner | 0.0056 / 0.0076 | 0.0052 / 0.0072 | 2.259 / 3.939 | 10.072 | 162 |
| 8 ms + faults | Data copy | 0.0304 / 0.0356 | — / — | 2.617 / 2.857 | 10.067 | 162 |
| No completion in window | Whole owner | 0.0036 / 0.0036 | — / — | 1.193 / 1.246 | — | 0 |
| No completion in window | Data copy | 0.0215 / 0.0232 | — / — | 1.434 / 1.499 | — | 0 |

### Per-trial completion counts and throughput

| Trial | Scenario | Model | Produced / completed in window | FPS |
|---|---|---|---:|---:|
| 1 | No delay | Whole owner | 90 / 90 | 59.98 |
| 1 | No delay | Data copy | 90 / 90 | 59.93 |
| 1 | 8 ms requested | Whole owner | 90 / 90 | 59.95 |
| 1 | 8 ms requested | Data copy | 90 / 90 | 59.96 |
| 1 | 50 ms requested | Whole owner | 25 / 24 | 15.96 |
| 1 | 50 ms requested | Data copy | 90 / 25 | 16.63 |
| 1 | 8 ms + faults | Whole owner | 90 / 81 | 53.96 |
| 1 | 8 ms + faults | Data copy | 90 / 81 | 53.96 |
| 1 | No completion in window | Whole owner | 1 / 0 | 0.00 |
| 1 | No completion in window | Data copy | 90 / 0 | 0.00 |
| 2 | No delay | Data copy | 90 / 90 | 59.75 |
| 2 | No delay | Whole owner | 90 / 90 | 59.72 |
| 2 | 8 ms requested | Data copy | 90 / 89 | 59.26 |
| 2 | 8 ms requested | Whole owner | 90 / 89 | 59.29 |
| 2 | 50 ms requested | Data copy | 90 / 25 | 16.61 |
| 2 | 50 ms requested | Whole owner | 25 / 24 | 15.94 |
| 2 | 8 ms + faults | Data copy | 90 / 81 | 53.96 |
| 2 | 8 ms + faults | Whole owner | 90 / 81 | 53.91 |
| 2 | No completion in window | Data copy | 90 / 0 | 0.00 |
| 2 | No completion in window | Whole owner | 1 / 0 | 0.00 |

## 6. Memory, resource bounds and full-pipeline responsiveness

Each benchmark process created **one pool** for warmup plus measurement; all ended with zero live pool wrappers, checked-out source buffers and copied pairs, and balanced lock/unlock counts. No simulated staging buffer was allocated: **staging bytes = 0**. Real future staging memory is additional and unmeasured.

| Scenario | Model | Superseded capture / Data frames | Peak checked-out buffers / copied pairs | Peak copied MiB | Peak owned source+Data MiB | Peak process RSS MiB |
|---|---|---:|---:|---:|---:|---:|
| No delay | Whole owner | 0 / 0 | 2 / 0 | 0.0 | 3.0 | 11.33 |
| No delay | Data copy | 0 / 0 | 2 / 2 | 6.0 | 9.0 | 20.23 |
| 8 ms requested | Whole owner | 0 / 0 | 2 / 0 | 0.0 | 3.0 | 11.23 |
| 8 ms requested | Data copy | 0 / 0 | 2 / 1 | 3.0 | 6.0 | 14.25 |
| 50 ms requested | Whole owner | 130 / 0 | 2 / 0 | 0.0 | 3.0 | 11.33 |
| 50 ms requested | Data copy | 0 / 126 | 2 / 3 | 9.0 | 12.0 | 29.38 |
| 8 ms + faults | Whole owner | 0 / 0 | 2 / 0 | 0.0 | 3.0 | 11.31 |
| 8 ms + faults | Data copy | 0 / 0 | 2 / 1 | 3.0 | 6.0 | 15.75 |
| No completion in window | Whole owner | 176 / 0 | 2 / 0 | 0.0 | 3.0 | 11.19 |
| No completion in window | Data copy | 0 / 176 | 2 / 3 | 9.0 | 12.0 | 17.34 |

Resource counters describe **logical checked-out sources and owned Data groups**. They are not a malloc/CF/VM heap profiler: ARC destruction transients, allocator retention and internal Core Video caches are not exactly represented. Peak RSS is actual native getrusage(RUSAGE_SELF).ru_maxrss (Darwin bytes), maximum over the two fresh processes, including startup/warmup/runtime/instrumentation. It is a high-water mark, not current/private footprint. Zero logical owners after cleanup does not mean the allocator returned every page to the OS.

Pool-cached storage is accounted separately: the normal six-buffer threshold permits up to **9 MiB of raw pool pixels**, even when checked-out count is zero. Peak Data payload cap is three pairs / **9 MiB** at packed dimensions; a conservative pool+Data reservation is therefore **18 MiB**, excluding runtime/cache/staging overhead. The actual source buffers checked out in benchmark peaks were two / 3 MiB; pool-exhaustion correctness deliberately reached six / 9 MiB. Padded fixtures have doubled source/Data byte sizes but the same count limits. Shape's safety cap is a ceiling, not a production memory budget.

All scenarios delivered **90/90 simulated CP1 publications per trial**, even when the cutout consumer held indefinitely during observation. CP1 is a separate actor published before the nonblocking metadata offer; no path awaits painting, copying or consumer completion. This demonstrates no programmed completion dependency. It does **not** establish absence of CPU contention or real camera/Vision latency: CP1 nominal-schedule lateness p95 ranged 1.162–7.294 ms across final rows, and real CP1 processing is not implemented here. No GPU resource-contention claim is possible.

## 7. Cancellation, failures and stalled consumers

- **Before production/transfer:** cancel/failure requests are skipped without allocating another pool or publishing a partial pair. A subsequent valid frame progresses.
- **During handoff and after acquisition:** scoped actual Task.cancel tests hold at explicit gates. Cancellation does not reclaim the workspace/Data while the reader owns it. The gate is explicitly acknowledged, read verification finishes, canceled output is not accepted, then resources release and tasks join. These are selected interleavings, not exhaustive cancellation/model-checking coverage.
- **After acquisition failure:** consumer reports failure and returns/releases safely; no image is accepted as a successful frame. Neither case changes CP1 or a gameplay verdict.
- **Generation changes:** pending metadata/Data are invalidated; a prior acquired generation is rejected at completion. This tests synthetic generation keys, not the entire camera/calibration-revision integration contract.
- **Repeated sessions:** six synthetic generations per model reuse one pool; no per-generation replacement allocator. Pixel identities and lock counts support actual reuse/cleanup, but no Instruments/TSan/ASan leak/race certification was performed.

### Never-returning consumer: honest boundary

During each 1.5-second observation, completion is withheld. Whole-owner remains with **one pool and one P1/P2 pair**, produces no further image pairs, drops/replaces incoming metadata and flags a held/stalled consumer at observation end. Across the two windows it produced 2 pairs total and completed zero. It cannot safely touch the transferred owner, force-release it, or allocate replacement pools indefinitely.

Data also cannot fix a permanently hung consumer. However, that consumer pins only its independent immutable pair; the producer-owned pool continues recycling and the pending copied pair is replaceable. Across the two windows it produced 180 pairs and completed zero, with bounded resources. This continued work costs CPU/power without visible progress; a production cadence/stall policy needs review rather than endless unnecessary copying.

**Teardown opens the controlled gate only after the observation snapshot. This models a late eventual return solely for safe test cleanup. It is not recovery from permanently lost ownership.** If the whole owner truly never returns, cutout production cannot resume within this topology. If the Data consumer truly never releases its pair, those bytes remain held; producer progress is still isolated and memory must remain capped. Neither timeout nor cancellation proves an unknown reader has stopped. Stall detection here is observation-window instrumentation, not an approved production timeout or automatic game pause.

## 8. Decision against CP2 requirements

| Criterion | Whole-owner | Producer-confined Data copy |
|---|---|---|
| Complete compiler checking | Pass with diagnosed writer alias control | Pass; only checked Sendable copied bytes/scalars leave actor |
| Tested CPU ownership/release | Pass within controlled scenarios; whole graph moves serially | Pass; held Data unchanged through raw source reuse |
| Bounded memory | Lowest observed footprint; one held pair blocks further production | Higher footprint, but latest pending/in-flight/active copy bounds held |
| Slow/never consumer | Producer stalls while ownership is away; metadata and CP1 continue | Producer continues/replaces pending; consumer may still be stalled |
| Original CP2 overlap | **Cannot preserve independent production/pending/upload overlap from one owner** | **Structurally preserves overlap** without raw CV resources crossing actors |
| Native performance | Lower copy cost and memory; lower slow-consumer throughput here | Explicit CPU copy/allocation and more memory; some throughput benefit, not universal latency benefit |
| Edo/Kevin integration | Requires serialization/round-trip lifecycle change; asynchronous GPU lifetime would hold the entire pool | Requires Data carrier + bounded staging agreement; actual upload/memory/copy cost still unknown |

On the final 50-ms-request workload, whole-owner completed 15.95 FPS versus Data 16.62 FPS, but admission→completion p95 was 76.219 ms versus 80.505 ms. Data did **not** win that latency comparison. Median explicit pair-copy stage ranged 0.541–0.964 ms across these M5 scenarios, including lock/allocation/copy work; these are not physical-iPad or pure-memcpy numbers.

**Recommendation: Data-copy for the next jointly approved integration candidate when preserving CP2 overlap is the priority.** It removed the raw pooled-buffer executor-transfer problem and isolated producer progress under consumer retention, at measured bounded CPU/memory cost. Whole-owner remains viable only if Edo/Kevin explicitly accept serialization, lower throughput under a slow consumer and inability to resume while ownership is permanently away. Neither model is approved for production from synthetic CPU performance alone.

## 9. Remaining gates before Metal/RealityKit validation

1. Edo/Kevin approve the ownership/carrier choice and any CP2 proposal change; the proposal and production contracts are untouched here.
2. Agree Data staging format, row handling, executor, global memory/admission limits and retention through **actual GPU** completion. This experiment allocated zero staging bytes. No raw Data pointer may outlive a scoped access without a proven resource-lifetime mechanism.
3. Validate actual device/format/sRGB/alpha upload and errors. Retest IOSurface/Metal-compatible allocation for any path that uses it; CPU-pool success is not evidence for that bridge. A Data-staging alternative may avoid a source CVMetalTextureCache, but its behavior/cost has not been measured.
4. Restore all CP1 snapshot/camera/calibration compatibility checks and independent lifecycle integration in the separately authorized adapter; this experiment used generation/sequence fixture keys, not a replacement BodySnapshot contract.
5. Kevin validates front/back activation, same-frame placement/debug association, full canvas/UV/mirror/culling, material/transparent laser depth, failure recovery and visual fallback. Nothing was rendered.
6. Validate physical-iPad throughput, thermal/memory, real segmentation/camera workload, source/frame latency, bounded upstream captured-frame retention and Jevon's presentation-expiry/update hook. A separate simulated CP1 counter is not the live CP1 pipeline.

## 10. Evidence and finish state

[Raw retained results, diagnostics and source hashes](../Scripts/CP2Spike/Runtime/Results/macos-m5-2026-11-03.json) accompany this standalone report. Full transient binaries/logs remain in `/private/tmp/cp2-runtime/final/`; rerunning the script reproduces the procedure, not identical timings. Compilation errors and the initial allocation/gate issues were corrected or explicitly excluded before the final accepted run; no failed final case was relabeled as a pass.

Swift concurrency and Swift Testing guidance informed explicit isolation, gate-based assertions and separation of runtime/benchmark claims. Production CP1, renderer, project settings, prior proposals/reports/scripts and user changes remain unchanged. No commit, push, merge, rebase, reset or automatic continuation to a GPU spike.
