# LH-00 CP2 synthetic spike — blocked at ownership gate

Edo / 3 November 2026. **Result: executable contract is not ready to finalize.** Work stopped at the explicit compiler-ownership gate; no live input, GPU bridge or renderer integration was implemented.

## Branch and preserved work

- Active branch: `feat/cutout-handoff` (already active on arrival).
- `git fetch origin staging` succeeded. HEAD and fetched origin/staging both resolved to `269c5c849e7020a3c686d4ef56ea5a552d20fc6b`; ahead/behind was 0/0. No switch, merge, commit, push, rebase or reset.
- Existing project-file blank-line modification and untracked CP2 proposal preserved byte-for-byte. CP1, production renderer, tests, schemes and project settings unchanged.
- Default command-line selection points to CommandLineTools. Commands explicitly used `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; no global xcode-select change.
- Actual toolchain: Xcode 26.6 / 17F113, Apple Swift 6.3.3. Project remains Swift 5, default MainActor, approachable concurrency, iPadOS 26.5.

## Files created

| File | Purpose |
|---|---|
| `Scripts/CP2Spike/PooledOwnershipProbe.swift` | Small failing reproduction: bounded Core Video pool, asymmetric premultiplied synthetic BGRA writer, P1/P2 buffers, non-Sendable completed-pixels wrapper, actor producer and MainActor receiver. References the real CP1 BodySnapshot. |
| `Scripts/CP2Spike/OwnershipControls.swift` | Intended positive producer-to-store call path. |
| `Scripts/CP2Spike/NegativeOwnershipControl.swift` | Separate deliberate mutable writer-alias violation. Expected to fail independently of the pooled producer. |
| `Scripts/CP2Spike/verify-ownership.sh` | Reproducible complete-checking SIL compilation, positive/negative logs and nonzero exit if the positive gate fails or the negative control is not diagnosed. |
| This report | Actual results, limitations and review alternatives. |

The Swift probe files are **outside** both filesystem-synchronized roots (`Sedactive/` and `SedactiveTests/`); they are not added to app/test target membership. An initial partial upload experiment was removed from the new app-source location before stopping; no unverified store/GPU code remains in production sources. The proposal itself was not edited to pretend this gate passed.

## Exact compiler check

Run from repository root:

```bash
CP2_SPIKE_OUTPUT=/private/tmp/cp2-spike/final-ownership \
  bash Scripts/CP2Spike/verify-ownership.sh
```

The script runs swiftc with the real CP1 identity/geometry/snapshot/calibration/provider files and isolated probes. Important arguments:

```text
-emit-sil -whole-module-optimization -o /dev/null
-swift-version 5 -strict-concurrency=complete -warnings-as-errors
-default-isolation MainActor
-enable-upcoming-feature NonisolatedNonsendingByDefault
-enable-upcoming-feature InferIsolatedConformances
-enable-upcoming-feature InferSendableFromCaptures
-enable-upcoming-feature GlobalActorIsolatedTypesUsability
-enable-upcoming-feature DisableOutwardActorInference
-target arm64-apple-ios26.5-simulator
```

The Simulator SDK is discovered with `xcrun --sdk iphonesimulator --show-sdk-path`; module cache and logs stay outside the repository. These are command-scoped flags, not project changes. `-emit-sil` matters: the preliminary **typecheck-only** experiment accepted both cases and did not expose the region-based ownership diagnostic. That preliminary result is not a passed ownership proof.

## Actual results

| Check | Result |
|---|---|
| Pooled positive path, complete checking + SIL | **FAILED: one relevant diagnostic**, promoted to error under Swift 5 by warnings-as-errors. No suppression applied. |
| Separate negative control, same checking + SIL | **Expected failure confirmed:** compiler diagnosed the retained writer alias used after sending to MainActor. |
| Script exit | 1, correctly blocking downstream implementation. |
| Runtime image generation/pool reuse | Not executed; source availability/typechecking does not establish runtime behavior. |
| App build / test-target build / existing Swift Testing suite | Not run after the blocking gate, following the explicit instruction to stop if sending does not compile safely. No pass or regression claim. |
| GPU pin/release/cancel/failure tests | Not performed. |
| CVMetalTextureCache, sRGB mapping/plain blit, actual rendering device | Not exercised. |
| Front/back activation, alpha/color, laser transparent depth, orientation/culling | Not rendered or visually validated. |
| Physical iPad | Not performed. |

A booted iPad mini (A17 Pro), iOS 26.5 Simulator was discovered (`1E1C6B07-B356-4303-8756-4C0D2A4CDF05`). Simulator unavailability is **not** the blocker. Discovery alone is not a Simulator test run.

### Positive diagnostic

`Scripts/CP2Spike/PooledOwnershipProbe.swift:42:9`:

```text
error: task or actor-isolated value cannot be sent; this is an error in the Swift 6 language mode
return CutoutSpikePixels(buffers)
```

The proposal assumes an actor's persistent pool can produce a disconnected completed buffer pair for exclusive transfer. This actual create/fill/dictionary/return path is not accepted by the installed compiler's region-based analysis. The diagnostic does not pinpoint which imported Core Video alias or local collection operation connects the result; do not assert a runtime data race has been proven, or promise a superficial syntax change will fix it.

### Negative diagnostic

`Scripts/CP2Spike/NegativeOwnershipControl.swift:11:24`:

```text
error: sending 'value' risks causing data races
note: 'value' used after being passed as a 'sending' parameter; Later uses could race
```

The receiver stores the sent mutable probe; the actor producer subsequently writes through its retained alias. This independent expected failure confirms the harness actually runs the required analysis. It does **not** make the failed pooled positive case safe.

## Smallest safe alternatives for review — not implemented

1. **Conservative boundary change:** keep raw pooled CV resources entirely producer-confined and export an explicit deep copy of immutable pixel bytes in checked Sendable `Data`, with immutable descriptors/CP1 metadata. The consumer owns separate staging/upload storage. This removes the raw pooled-buffer actor transfer assumption but adds copying; Edo/Kevin must agree staging execution/bounds and measure cost before adopting it. It is a contract adjustment, not evidence that the current zero-shared-writer handoff works.
2. **Preserve pooled-buffer carrier, investigate ownership topology:** a separately authorized compiler-only follow-up could test a genuinely disconnected producer scope/exclusive whole-pool ownership transfer instead of returning buffers linked to an actor-owned pool. This is a candidate investigation, **not a demonstrated safe fix**. Any version must still pass the positive/negative gate and runtime pool/alias/GPU lifetime tests without suppressions.

Do not use unchecked Sendable, unsafe nonisolation, @preconcurrency warnings suppression, language-mode migration or a MainActor image-processing workaround to bypass this failure. The stopped spike implements neither alternative.

## Kevin/Jevon integration and next gate

Kevin's files need no edit to reproduce the blocker. Before a later rendering spike, Kevin still supplies/verifies the actual RealityView resource device, hidden-back replacement abort recovery, full-canvas/UV/mirror transforms, material/alpha compatibility and transparent laser ordering. No successful GPU completion or visual synchronization is claimed here. Jevon retains evidence selection and the reviewed presentation-expiry hook coordination.

**Next decision:** approve a revised ownership boundary or a narrower compiler investigation. Then repeat the complete-checking gate before resuming runtime Metal/RealityKit work. CP2 and LH-14 remain unproven; CP1 is preserved. Skills read/applied: Swift concurrency, Swift architecture and Swift Testing guidance for isolated checks and honest separation of compiler results from runtime tests.
