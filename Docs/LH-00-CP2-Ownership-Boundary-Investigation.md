# LH-00 CP2 — Focused ownership-boundary investigation

Edo / 3 November 2026. **Compiler-only result:** pooled transfer is not disproved. The original persistent-actor/per-buffer return remains rejected. An alternative that transfers the entire bounded pool owner through serial sending scopes compiles, including repeat use of the same pool. Its runtime/CF/GPU lifetime safety is still unverified; it is not the original independently reusable producer/lease-store topology.

## Scope and preserved state

Read the CP2 proposal, original spike report, all four reproduction files, current project concurrency settings and the Swift concurrency skill/reference. The installed toolchain remains Xcode 26.6 / 17F113, Apple Swift 6.3.3 / swiftlang-6.3.3.1.3, targeting arm64 iOS 26.5 Simulator with the same SDK.

The checkout is now `staging`, not the previous turn's feat/cutout-handoff. No branch switch/fetch/merge or other Git mutation was performed in this investigation. All pre-existing source, tests, CP1 contracts, proposal/report, four original reproduction files and the project-file user modification are preserved. New files live outside the two filesystem-synchronized app/test source roots.

Added: 29 independent cases plus shared declarations in `Scripts/CP2Spike/BoundaryProbes/`, a case manifest, `verify-boundaries.sh`, and this report. No production Swift, test target, project setting, Metal or RealityKit implementation was changed.

## Exact verification and meaning of results

```bash
CP2_BOUNDARY_OUTPUT=/private/tmp/cp2-boundary/final \
  bash Scripts/CP2Spike/verify-boundaries.sh
```

The runner asserts that its compiler flags exactly match `verify-ownership.sh`: Swift 5, complete strict concurrency, warnings-as-errors, SIL emission with whole-module compilation, default MainActor and the same five upcoming-feature flags. No flag is weakened, no typecheck-only result counts, and no unsafe annotation/suppression is used. SDK/module-cache arguments are unchanged in meaning. All allocation calls remain ordinary checked Core Video imports; no pointer conversion or ownership cast detaches a region.

**Final run:** 31 separate SIL compilations: **12 ordinary accepted cases with no diagnostics; 17 diagnosed/rejected cases including original and additional negative controls; 2 deliberately unsafe literal controls accepted by this compiler.** Runner exited 0 because all expected observations matched. This is a characterization result, **not 31 safety tests passing**. The original `verify-ownership.sh` gate is unchanged and still fails its original positive case.

Exact compiler logs and `results.tsv` are in `/private/tmp/cp2-boundary/final/`. Re-running with a different output directory records fresh logs. Failure cases must contain an ownership/Sendable diagnostic, not an unrelated parse/import error. Unsafe accepted controls are labeled explicitly and never promoted to the recommended implementation.

## Experiment matrix

Each row is compiled independently with only shared nonisolated value declarations, except the original reproduction which includes the actual CP1 types. Non-Sendable buffer wrappers have immutable stored references; they do not claim that the referenced pixels are immutable or Sendable.

| Probe | One-step question / observation | Actual SIL result |
|---|---|---|
| [original-pooled](../Scripts/CP2Spike/PooledOwnershipProbe.swift) | Original pooled producer remains rejected | Rejected as recorded |
| [original-negative](../Scripts/CP2Spike/NegativeOwnershipControl.swift) | Original writer-after-transfer negative control | Rejected as recorded |
| [A_reference](../Scripts/CP2Spike/BoundaryProbes/A_reference.swift) | Fresh non-Sendable reference, sending actor result | Accepted; no diagnostics |
| [A_reference_helper](../Scripts/CP2Spike/BoundaryProbes/A_reference_helper.swift) | Fresh reference after synchronous helper mutation | Accepted; no diagnostics |
| [B_fresh_raw](../Scripts/CP2Spike/BoundaryProbes/B_fresh_raw.swift) | Fresh non-pooled CVPixelBuffer, sending actor result | Accepted; no diagnostics |
| [B_fresh_wrapper](../Scripts/CP2Spike/BoundaryProbes/B_fresh_wrapper.swift) | Fresh non-pooled CVPixelBuffer inside immutable reference wrapper | Accepted; no diagnostics |
| [B_cv_import_sendable](../Scripts/CP2Spike/BoundaryProbes/B_cv_import_sendable.swift) | Imported CVBuffer cannot satisfy Sendable | Rejected as recorded |
| [C_pool_raw](../Scripts/CP2Spike/BoundaryProbes/C_pool_raw.swift) | Persistent actor pool, direct raw sending result | Rejected as recorded |
| [C_pool_wrapper](../Scripts/CP2Spike/BoundaryProbes/C_pool_wrapper.swift) | Persistent actor pool, single-image wrapper | Rejected as recorded |
| [C_pool_raw_no_sending](../Scripts/CP2Spike/BoundaryProbes/C_pool_raw_no_sending.swift) | Removing sending result fails actor boundary | Rejected as recorded |
| [D_fresh_loop](../Scripts/CP2Spike/BoundaryProbes/D_fresh_loop.swift) | Non-pooled fresh buffers accumulated in dictionary | Accepted; no diagnostics |
| [D_pool_literal](../Scripts/CP2Spike/BoundaryProbes/D_pool_literal.swift) | Single pooled buffer, dictionary literal | Accepted; no diagnostics |
| [D_pool_insert](../Scripts/CP2Spike/BoundaryProbes/D_pool_insert.swift) | Single pooled buffer, dictionary subscript insertion | Rejected as recorded |
| [D_pool_loop](../Scripts/CP2Spike/BoundaryProbes/D_pool_loop.swift) | Two pooled buffers, dictionary loop accumulation | Rejected as recorded |
| [D_pool_loop_read](../Scripts/CP2Spike/BoundaryProbes/D_pool_loop_read.swift) | Pooled accumulation with inline CV metadata read | Rejected as recorded |
| [D_pool_loop_helper](../Scripts/CP2Spike/BoundaryProbes/D_pool_loop_helper.swift) | Pooled accumulation with synchronous CV helper | Rejected as recorded |
| [C_pool_literal_two](../Scripts/CP2Spike/BoundaryProbes/C_pool_literal_two.swift) | Two pooled buffers, dictionary literal | Accepted; no diagnostics |
| [C_pool_literal_two_helper](../Scripts/CP2Spike/BoundaryProbes/C_pool_literal_two_helper.swift) | Two pooled buffers, literal after metadata helper | Accepted; no diagnostics |
| [C_pool_literal_retained_mutated](../Scripts/CP2Spike/BoundaryProbes/C_pool_literal_retained_mutated.swift) | Pooled literal wrongly accepts retained producer writer alias | Accepted UNSAFE control; not a solution |
| [A_actor_retained_literal_mutated](../Scripts/CP2Spike/BoundaryProbes/A_actor_retained_literal_mutated.swift) | Plain Swift literal wrongly accepts retained actor-state writer | Accepted UNSAFE control; not a solution |
| [A_actor_retained_insert_mutated](../Scripts/CP2Spike/BoundaryProbes/A_actor_retained_insert_mutated.swift) | Same plain Swift actor-state writer with subscript insertion | Rejected as recorded |
| [E_borrowed_pool_helper](../Scripts/CP2Spike/BoundaryProbes/E_borrowed_pool_helper.swift) | Nonisolated helper with ordinary borrowed pool parameter | Rejected as recorded |
| [E_disconnected_class_pool](../Scripts/CP2Spike/BoundaryProbes/E_disconnected_class_pool.swift) | Ordinary producer parameter is task-isolated, not disconnected | Rejected as recorded |
| [E_local_pool_actor_clean](../Scripts/CP2Spike/BoundaryProbes/E_local_pool_actor_clean.swift) | Fresh local pool control only, not a reusable allocation strategy | Accepted; no diagnostics |
| [E_whole_owner_roundtrip](../Scripts/CP2Spike/BoundaryProbes/E_whole_owner_roundtrip.swift) | Whole-owner sending with mutable loop reassignment | Rejected as recorded |
| [E_whole_owner_immutable_roundtrip](../Scripts/CP2Spike/BoundaryProbes/E_whole_owner_immutable_roundtrip.swift) | Same bounded pool owner reused via two immutable round trips | Accepted; no diagnostics |
| [E_whole_owner_recursive_roundtrip](../Scripts/CP2Spike/BoundaryProbes/E_whole_owner_recursive_roundtrip.swift) | Finite three-frame serial sending scopes, same pool owner | Accepted; no diagnostics |
| [E_whole_owner_without_sending_parameter](../Scripts/CP2Spike/BoundaryProbes/E_whole_owner_without_sending_parameter.swift) | Whole-owner worker without sending parameter | Rejected as recorded |
| [E_whole_owner_negative](../Scripts/CP2Spike/BoundaryProbes/E_whole_owner_negative.swift) | Whole-owner post-transfer producer alias mutation | Rejected as recorded |
| [E_whole_owner_child_alias](../Scripts/CP2Spike/BoundaryProbes/E_whole_owner_child_alias.swift) | Consumer retains child CV buffer while returning whole owner | Rejected as recorded |
| [F_data_bounded_copy](../Scripts/CP2Spike/BoundaryProbes/F_data_bounded_copy.swift) | Producer-confined pool, explicit deep-copy bounded Sendable Data | Accepted; no diagnostics |

## Earliest failing boundary

A fresh mutable Swift reference returned `-> sending Box` passes. A fresh `CVPixelBufferCreate` result returned raw or inside an immutable reference wrapper also passes. Therefore neither `sending` results nor the imported CVPixelBuffer type categorically prevent disconnected transfer.

**The first failing step is C_pool_raw:** use a persistent **actor property** CVPixelBufferPool in `CVPixelBufferPoolCreatePixelBufferWithAuxAttributes`, then return the single raw result as `sending CVPixelBuffer`. No dictionary, image wrapper, second buffer, pixel-writing helper or CP1 packet is needed to fail.

The direct diagnostic is more precise than the original wrapper diagnostic:

```text
sending 'result' risks causing data races
'self'-isolated 'result' cannot be a 'sending' result.
'self'-isolated uses may race with caller uses
```

The original collection wrapper hides that provenance behind `task or actor-isolated value cannot be sent`. Removing `sending` does not fix it: crossing the actor method's ordinary non-Sendable result is rejected. A nonisolated helper taking an ordinary pool parameter is also rejected as task-isolated; renaming a class nonisolated does not make its caller-owned pool disconnected.

**Imported behavior:** the SDK declares the Core Video pool non-Sendable and the actual generic-conformance probe reports CVBuffer's Sendable conformance unavailable. The C out-parameter allocation signature does not promise a Swift disconnected/sending result. The measurements support region connection through the persistent pool/allocation boundary; they do not prove a real runtime alias race in Core Video, nor establish a single root cause in Swift's implementation.

A fresh locally created pool control passes. It is not a production solution: a new pool per frame could undermine global bounds and reuse. No unbounded allocator replaces the persistent pool in the recommended candidate.

## Collection acceptance is not a safe workaround

An immutable wrapper around a dictionary **literal** is accepted for one and two pooled buffers, including a synchronous metadata helper. Building the corresponding dictionary using subscript insertion/loop accumulation is rejected. Fresh non-pooled dictionary accumulation passes, so collections alone are not the original cause.

Crucially, the compiler also accepts:

- A literal returning the pooled buffer while the actor deliberately retains the buffer and subsequently mutates its attachments.
- A literal returning an ordinary mutable Swift Box still owned by the actor, followed by a producer mutation after the consumer accepts it.

The latter contains no Core Video dependency in the ownership relationship. The equivalent ordinary Swift insertion control is rejected. This is an **observed collection-dependent diagnostic gap on this toolchain**, not an approved way to erase isolation. No runtime exploit/race was executed. Source audit already shows retained writable aliases, so these controls cannot establish safe ownership despite a zero compiler exit status. Do not fix the original probe by merely replacing dictionary insertion with a literal.

## Minimal compiler-accepted pooled design

See [the immutable whole-owner round-trip probe](../Scripts/CP2Spike/BoundaryProbes/E_whole_owner_immutable_roundtrip.swift). It retains a single bounded pool inside a nonisolated, deliberately non-Sendable `Workspace`. The workspace also owns its current buffer dictionary. It is neither actor state nor borrowed/shared producer state during the handoff.

The relevant signatures are:

```swift
@concurrent nonisolated
func produce(_ owner: sending Workspace) async throws -> sending Workspace

@MainActor
func consume(_ owner: sending Workspace) async -> sending Workspace
```

The compiler-accepted sequence uses new immutable bindings:

```swift
let initial = try Workspace()                  // One pool, created once.
let firstProduced = try await produce(initial)
let firstReturned = await consume(firstProduced)
let secondProduced = try await produce(firstReturned)
let secondReturned = await consume(secondProduced)
```

The same workspace/pool travels with its images; no actor retains the pool while detachable images cross separately. Allocation threshold 6 is supplied on every pooled allocation, with at most two current images. The producer clears/replaces those images only after the consumer returns the owner. A finite three-frame recursive sending-scope variant also compiles; this is not an infinite task scheduler or production recursion recommendation.

A mutable-variable loop reassignment is rejected; the accepted immutable scopes are materially different to the compiler. Removing the worker's `sending` parameter is rejected as well. These controls show that the annotations and binding structure matter; no unsafe cast changes them.

### Alias checks and practical limits

- Retaining the **whole owner** on the producer side, sending it and then mutating through that alias is diagnosed.
- Retaining a **child CVPixelBuffer** in MainActor state while returning the owner is diagnosed.
- The accepted consumer only reads the image count and returns the owner. It stores no CV objects in an actor/global/cache, creates no escaping closures over them and exports no writer alias. The worker returns the entire connected resource graph rather than detaching a child. The current source audit finds no retained application writer outside that owner.

**Runtime safety remains unverified.** No Core Video pool was allocated or exercised at runtime, and no buffer lock/write/recycle/GPU read was run. The compiler cannot prove all CF/C aliases, imported function behavior or pool reuse. The dictionary diagnostic gap is an additional reason to keep source audit and runtime lifetime tests mandatory.

This alternative changes scheduling: one serial owner is unavailable to the producer while the consumer owns it. A future consumer must hold it until every CPU/GPU read completes, then return it; cancellation must not return it before the GPU fence. It cannot simultaneously supply the proposal's composing/pending/uploading overlap from one owner. No independent per-player leases, new generation allocation, stream, revision handling or GPU completion mechanism is implemented here.

Thus there is a **compiler-accepted bounded ownership topology**, but no validated drop-in repair for the original persistent-actor pool plus independently released image leases. Its changed scheduling/lifetime boundary needs Edo/Kevin approval before any spike uses it.

## Conservative Data-copy comparison

[The bounded Data probe](../Scripts/CP2Spike/BoundaryProbes/F_data_bounded_copy.swift) passes complete checking. Its actor retains the same persistent raw pool; only a checked Sendable `CopiedImage` with Data and scalar dimension/stride fields crosses to MainActor. It needs no `sending` result because the returned value is Sendable.

**Where the copy occurs:** on the producer actor, after future image completion, while the source pixel buffer is locked read-only. `Data(bytes: base, count: rowStride * height)` explicitly copies into independently owned Data; the source is then unlocked and can be released/recycled. It is not Data(bytesNoCopy:), a reinterpretation or a retained raw source pointer. The probe uses a scoped source-memory read only; it does not bypass ownership analysis. Apple distinguishes [the copying initializer](https://developer.apple.com/documentation/foundation/data/init(bytes:count:)) from [the no-copy initializer](https://developer.apple.com/documentation/foundation/data/init(bytesnocopy:count:deallocator:)).

**Bounds:** the compiler-only probe uses 64×96 source buffers, a six-buffer pool threshold and a hard per-image copied-byte cap of 65,536, rejecting invalid/over-cap byte counts. It returns one image, not an implemented P1/P2 delivery queue. A future pair at that cap is at most 128 KiB, but a finite number of pending/in-flight pairs must also be enforced globally; Sendable alone does not bound memory. Production canvas limits must include actual row stride, dimensions and checked arithmetic, not assume width×4.

**Future consumer staging, not implemented:** consumer-owned bounded upload storage would receive a copy of the independent Data bytes (preserving or explicitly repacking rows), then feed the reviewed GPU upload/conversion. Keep staging alive until GPU completion. A scoped read of Data must not leave an escaped pointer. The executor for CPU staging/copy must be reviewed to keep heavy work off MainActor; moving Metal objects between executors needs its own proof. This would be a revised bridge, not evidence for the current CVMetalTexture handoff.

**Costs to measure:** at least the explicit producer CPU copy/allocation, potential second CPU copy into staging, row repacking/conversion, GPU upload and peak memory while source+Data+staging coexist. At the illustrative 512×768 BGRA8 resolution, packed pixels alone are 1.5 MiB per image / 3 MiB per pair before row alignment and object/framework overhead. No CPU, memory or latency measurement occurred. Copying is a conservative alternative, not a promise of acceptable performance.

## Recommendation for Edo and Kevin

1. Reject the dictionary-literal shortcut as an ownership proof; the retained-writer controls expose why.
2. Prefer **reviewing the serial whole-owner model for the next bounded synthetic ownership/lifetime spike**, if serialization is acceptable. It preserves one reusable bounded pool, has a clean positive compile and diagnosed whole-owner/child-alias controls. Approval must explicitly accept the scheduling change; do not silently rewrite CP2's lease-store contract.
3. Keep **explicit Data copying** as the conservative fallback if the intended independent producer/store overlap is required or whole-owner runtime behavior cannot be validated. Agree its staging executor, memory caps and measured copy budget first.

This recommendation selects a narrow next question, not a production architecture or automatic implementation step.

## Remaining gates before GPU validation

- Edo/Kevin choose and approve the ownership boundary/scheduling model; keep the original contract unchanged until then.
- Runtime Core Video tests must prove bounded allocation/recycling, no retained writers, source immutability, cancellation/stop/context retirement and resource lifetime. Compiler-only acceptance is insufficient.
- For the whole-owner candidate, define a scoped consumer that returns ownership only after terminal reads, including failure/cancel paths; prohibit cached child buffers and uncontrolled per-generation pools. Do not assume the current MainActor store can return a property-held owner through sending without a new compiler check.
- For Data, approve a bounded staging/executor/copy plan and measure it separately.
- Only after separate authorization may the device/cache/sRGB upload, pre-commit abort recovery, RealityKit activation/alpha/depth, geometry and physical-device latency gates resume. Jevon's gameplay and hook ownership stay unchanged.

No application build, Simulator execution, runtime test, Metal/RealityKit work, new production contract or device validation was performed. Existing CP1/renderer/tests/settings/user work are unchanged. Skill used: Swift concurrency, including its Sendable/region-isolation guidance. No commit, push, merge, reset or branch switch.
