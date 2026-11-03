# LH-12 — First playable, camera-free replay slice

Implemented 3 November 2026 by Jevon. The user explicitly authorized PlayView integration in Kevin's area; renderer artwork/scene and Edo's Shared input implementation are unchanged. Kevin/Edo review is still required for production handoff.

## What runs

App startup already routes to PlayView. It now starts an 18.5-second synthetic body replay rather than the old debug-only preview with hard-coded outcomes. RealityView uses its virtual camera, not device capture. The same slice runs in Debug and Release; debug body/band markers are Debug-only.

| Crossing | Move | Expected P1 / P2 | Team effect |
|---|---|---|---|
| 4.0 | High / duck | CLEAR / CLEAR | +200 points, no damage |
| 10.0 | Low / jump | HIT / CLEAR | +100 points, -1 health |
| 16.0 | High / duck | HIT / CLEAR | +100 points, -1 health |

The final result is completed, score 400, remaining health 3, and six target results. A 3-second warning and 1.4-second action cue are replay candidates. The window/delivery values are the LH-07 fixture values, and the explicit replay margin is 0.005 game units; none are new production tuning approvals.

The task's split-laser line is superseded by the owner's high/low-horizontal-only product decision. No mixed-movement encounter is reintroduced. The demo uses a common horizontal band for both players, which the current renderer supports; final per-player difficulty/artwork behavior remains LH-15/renderer integration. A child may already be below a common high band, consistent with the held-posture rule. This synthetic slice is not a parent/child exercise-safety validation.

## Data and cycle ownership

- `Session/Fixtures/laser-replay-slice.json`: schema-v2 synthetic data derived from Edo's existing cooperative-v2 test calibration/body fixture. Fixed IDs, timestamps and delivery order; no participant recordings, images or video. Four packets: initial standing pose and three crossing samples. The snapshot-only/context guard prevents a transport record that cannot yield from hanging the slice's controlled stream drain.
- `LaserReplayScript`: loads the bundled fixture through Shared ReplayFixture decoding and constructs fixed high/low encounters/configuration. Missing resources surface as a startup error; no source-path fallback or fabricated camera sample.
- `GameSessionCoordinator`: starts Edo's real ReplayBodyInput, acquires its single stream, advances source time, drains each synthetic packet before advancing to the next, converts capture time through GameClock, and passes evidence/ticks to production LaserGame. It exposes observable immutable state, ordered per-target results and one RoundSummary. Large render-frame deltas still process every delivery chronologically. It stops the provider at completion/exit; overlapping advance calls are guarded.
- `LaserGame`: retains evidence/locked verdict ownership and now performs minimal replay-slice team aggregation once per logical encounter. No second mutable health/score copy lives in the coordinator. HIT costs one health/player, CLEAR contributes 100/player, and a technically UNAVAILABLE pair is unscored/undamaged under the existing proposal. Full co-op gates, diamond rewards, production retry/recovery and the five-minute director remain future work.
- `LaserReplayPresentation`: the only SceneEvents.Update subscription in this PlayView path. It accumulates absolute synthetic frame time and forwards it serially; only GameClock/game/session make decisions. It adapts the current encounter into Kevin's existing beam-depth/band, move-cue and outcome APIs. The old LaserApproachPreview remains available in source but is not also started, avoiding competing drivers.
- `ReplaySliceHUD`: essential health, shared score, progress, P1/P2 lane labels, persistent last-verdict text, errors and completion feedback. Per-player verdict badges come from the renderer; the HUD retains their meaning after the cosmetic animation ends. No audio is needed to understand the result.

This is a minimal replay lifecycle, not completion of the live-camera/calibration flow or every LH-08/LH-16/LH-17 behavior. Production pause/retry, live frame association and five-minute content remain separate work. Session/Domain imports no camera/renderer framework; presentation stays under UI. Shared never depends on LaserHeist.

## Debug agreement

Both `scene.setLaserBand` and the debug yellow band-edge lines consume the same target lower/upper values through GameWorldMapping. Cyan crown, purple wrist and green sole markers use the current packet's Y values and the same game-to-world scale. Placeholder silhouettes stretch/translate to crown/sole height; wrists have schematic fixed horizontal offsets because this is Y-only laser evidence, not hand-contact geometry. P1/P2 map to the renderer's existing parent/child lane aliases only in the adapter.

The HUD shows source frame/capture time, judged band and margin. Each scripted crossing has one eligible pose packet, so the pose shown at verdict agrees with that selected frame. This does not settle live cutout/pose lag or CP2. Use `-hideDebugOverlay` to hide the spatial replay markers; `-showWorldGuides` adds Kevin's older corridor/origin guides. The default omits those large construction labels so the move cue remains legible.

## Validation

- The existing LH-07/LH-09/LH-10 R1–R9 expectations still execute through production selection/verdict code.
- New ReplaySliceTests run the complete coordinator twice at 60 Hz and compare ordered results and final summaries. Both runs produce score 400/health 3. Tests also cover one large frame, repeated end ticks without duplicate effects, and stop preventing later verdicts.
- The application bundle includes its own synthetic fixture; hosted Simulator tests load that production resource. The temporary macOS harness uses its explicit fixture resource bundle.
- Xcode Simulator build and the selected real SedactiveTests target succeeded on iPad Pro 13-inch (M5), iOS 27.0: 25 Swift Testing tests in four suites passed. The isolated strict-concurrency/warnings-as-errors harness also passed the 25 tests before the final presentation-only adjustments. Xcode logs include framework/asset diagnostic messages, not a claim of warning-free third-party artwork rendering.
- Visual verification completed in the actual Simulator app: the slice reaches Replay complete, health 3/5, team score 400 and last verdicts P1 HIT/P2 CLEAR. Yellow band edges cross the higher P1 crown while the P2 crown/wrists remain below them, consistent with those results. The final HUD-only change was rebuilt successfully and inspected on screen. No camera input was used. Physical iPad validation, final HUD design, production gesture comfort and Kevin/Edo sign-off remain pending.

No commits, pushes, merges or project-setting changes are part of this implementation. Xcode may insert a cosmetic blank line in project.pbxproj; that tool-generated whitespace is excluded from the feature change.
