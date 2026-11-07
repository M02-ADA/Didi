# Laser Heist — D02/D03 Tech Lead Decision V1

**Date:** 7 November 2026  
**Decision owner:** Edo (Tech Lead, Body Tracking / App integration)  
**Scope:** B2b live PlayerTracker control, binding, source cutover, lifecycle and recovery; game-session behavior is a Tech Lead v1 product rule for Jevon to implement/review.  
**Status:** **TECH LEAD SELECTED — repository recording pending.** This text becomes the authoritative project record when Edo explicitly adopts it and commits/merges the ADR into the agreed repository branch. It is not evidence that Jevon has independently approved it.  
**Basis:** WP-E02A0 B2b Live Tracking Integration Preflight; independently accepted B2a Option A pure core; previous ADR packet and revised D06 AvatarPoseFrame proposal.

## D02 — Explicit player binding and identity authorization

**D02.1 — Authority.** Binding starts only after an explicit setup/session command routed through an Edo-owned App/body-input control facade. Camera start, two visible people, or a renderer event never authorizes binding. DEBUG-only controls may issue the same command for diagnostics, but must not create another authority.

**D02.2 — Slot convention.** Preserve accepted B2a source convention: P1 is the body on canonical **image-right**; P2 is on canonical **image-left** during atomic acquisition. Canonical coordinates remain upright and unmirrored. A mirrored selfie preview/display may put P1 on the displayed left. Never swap identities based on later screen position or frame-local candidate IDs. Setup UI must visibly identify P1/P2 and require user confirmation before entering calibration/gameplay; the tracker is not an identity verifier.

**D02.3 — Request and revision.** The control facade owns a bounded current request (`requestID`) and monotonically advancing `binding/controlRevision` scoped to the capture/control lifetime. Commands include `arm`, `cancel/revoke`, and later `requestFullRebind`; a duplicate of the same active request ID is idempotent. A genuinely new or revoked authorization advances the revision and invalidates earlier results. Never fabricate source generations or re-stamp already admitted work. Exact API spelling is left to the E02 implementation review.

**D02.4 — Admission cutover.** An authorization takes effect at the **synchronized source admission boundary**, before frame copy/inference. Stamp the actual accepted frame/lease with the then-effective original control revision. Pending or in-flight work retains its prior stamp and cannot later borrow a new revision. Enforce this using one shared source/control linearization gate; no current-value lookup after Vision completes.

**D02.5 — Atomic acknowledgment.** `armed` means waiting, not bound. Success requires both slots bound atomically by the accepted B2a tracker on a frame consistent with the current source and request/revision. Emit one source-correlated acknowledgement with `requestID`, revision, original frame/source identity, and P1/P2 results. A canceled, superseded, stale or source-mismatched request must never acknowledge success. User-facing lane confirmation is a separate setup action after technical binding succeeds.

**D02.6 — One tracker and fail-closed publication.** The existing CameraCopySink/Vision worker is the sole mutable PlayerTracker owner. Evaluate frames on a staged tracker copy; commit/publish only after source, control, ordering, freshness and revocation gates pass. A rejected result must not mutate authoritative tracking history, even if Vision completed successfully. Publish numeric tracking diagnostics; do not implement live CP1/gameplay or avatar rendering in E02.

## D03 — Recovery, lifecycle and full rebind

**D03.1 — Ordinary uncertainty.** `uncertain`/temporarily unavailable observations keep existing B2a identity/history, evidence refusal, expiry and capture-time recovery dwell. No automatic identity swap, history confirmation, full rebind, new generation or premature lost-state reset. Worker reports status; renderer and gameplay do not override tracker truth.

**D03.2 — Lost/rebind-required.** If B2a requires full rebind (including an unrecoverable lost identity), require explicit full-**pair** rebind. Revoke prior binding, clear published tracking immediately, restart the **real capture run with a capture-owned new source generation**, and authorize a new atomic two-player acquisition. Preserve the retained native camera session owner as designed. Do not create a fake generation in PlayerTracker or reset retained guards to allow same-generation resurrection. A single player's lost status cannot silently relabel the other.

**D03.3 — Stop, interruption, background, failure.** On loss of capture authority, synchronously invalidate published tracking and revoke the active binding/control authorization, including while Vision is in-flight. Revocation advances `controlRevision` under the same control gate. Raw camera hardware may use existing native resume behavior, but that is not implicit identity reauthorization. Returning to foreground or native same-generation resume leaves tracking **disarmed**. Fresh explicit authorization is required; if a previously bound pair needs reacquisition, use the full-rebind/new-generation path. Do not assert that every resume itself increments the binding revision: it is the revocation/new authorization that advances the revision.

**D03.4 — Status and late frames.** Invalidation must be available without a new camera frame and must not depend on the DEBUG view. Status ordering may have a separate bounded monotonic `status.sequence` for consumers (D06); it must not substitute for `controlRevision` or original frame identity. Late old-revision/source work cannot mutate the worker's committed state, republish an old match or reactivate an avatar. A shared synchronized gate owns current authorization/invalidation; keep control/status delivery bounded. No unbounded status-event backlog.

**D03.5 — No-frame expiry.** Use one lifecycle-owned deadline/wakeup path, serialized with the existing processing worker; no polling tied to diagnostics, no per-frame tasks, no fake PoseFrame. Preserve capture timestamps and treat expiry's evaluation watermark as authoritative: input captured before an applied watermark cannot later be accepted as fresh. A stalled inference remains resource-owned until it actually exits, while published data can invalidate immediately.

**D03.6 — Session product rule, v1 (Jevon implementation boundary).** When the authoritative **gameplay input** for either player becomes unavailable during active play, the game session pauses/suspends outcomes: freeze GameClock, laser HIT/CLEAR processing and diamond/scoring progression until trustworthy evidence and a controlled resume. Temporary uncertainty may recover through the accepted B2a/CP1 gates, with a setup-owned re-entry/continue affordance rather than silently resuming mid-laser. A full rebind, generation change or invalid accepted standing calibration invalidates the current round for v1: repeat player binding and standing calibration and **restart the round from the beginning**; do not transfer partial-round results to the new run. This is a Tech Lead *product direction*, not B2b code. Jevon owns precise GameSessionCoordinator phases, transitions and any UX refinements, subject to keeping the fail-closed invariants; Theo reviews wording and controls. B2b never changes score, hearts, GameClock or round state itself.

## Implementation guards and relationship to D06

- CameraPipeline / FrameStore / CameraCopySink / B1 remain single-source. No second camera, Vision worker, tracker, FrameStore reader or live CP1 reader.
- Do not copy fixture policy thresholds into the live build implicitly. Before active two-person on-device diagnostics, Edo must explicitly select and version an **experimental B2b tracking policy**, recording every value and rationale from the actual source. This ADR approves behavior/control semantics **but not numeric values**.
- D06 avatar producer/consumer accepts only original same-source, same-control authorized results. Revocation and accepted calibration changes produce bounded status invalidation independent of frames. The D06 proposal must **remove its unconditional rule that resume itself increments controlRevision**: a stop/interruption revokes, and a future explicit authorization advances it. Presentation `status.sequence` is separate from binding authority. Synthetic K03 tests can proceed against the frozen semantic portion; field-level D06 freeze waits for this compatibility to be reflected.
- E02 scope is numeric tracking diagnostics and deterministic tests only; D04 calibration authority, D05 provider/session composition, E07 avatar producer, K03 avatar adapter and live gameplay are separate checkpoints.

## Required evidence before E02 merge / live activation

1. Source-admission stamping; arm/cancel/duplicate/supersede request race tests; original request/source atomic acknowledgments.
2. Staged same-source worker commit and rejected late inference; stop/background/interruption immediate invalidation without a next frame.
3. Real capture generation replacement and full-pair rebind; no same-generation resurrection; native camera resume without tracking reauthorization.
4. No-frame expiry with capture-time watermark and serial ordering; preview-on/off independence; one worker and existing pixel ownership bounds.
5. Focused deterministic integration suite, full staging regression, strict concurrency/WAE checks, and fresh persistent evidence.
6. Explicitly documented versioned experimental live policy values before enabling physical tracking; iPad Pro M4 characterization after software gates, not evidence of real identity accuracy from synthetic tests.
7. Jevon's review of session pause/restart flow is an implementation handoff, **not a prerequisite to the B2b diagnostic-control implementation**, unless source-level conflict with the decided technical contract is found.

## Decision ledger

| Decision | Disposition | Accountable owner | Implementation owner / reviewer |
|---|---|---|---|
| D02 binding, source cutover and acknowledgment | Tech Lead selected; record in repo | Edo | Edo; Jevon reviews setup/session API use |
| D03 tracking lifecycle, full rebind, expiry | Tech Lead selected; record in repo | Edo | Edo; Jevon reviews recovery UX integration |
| D03 v1 game-session pause/restart product behavior | Tech Lead selected; session implementation handoff | Edo | Jevon; Theo reviews UX |
| Versioned experimental B2b tracking *numbers* | **OPEN, separate explicit approval** | Edo | Edo |
| D06 field-level packet freeze | **OPEN until updated against D02/D03** | Edo + Kevin | E07 Edo / K03 Kevin |

**Non-goals:** production identity guarantees, calibrated body measurements, gameplay scoring changes within E02, alternative avatar collision authority, changes to accepted B2a Option A, and implicit application of synthetic fixture defaults to live gameplay.
