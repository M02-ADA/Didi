# LaserHeist — Phase 1: on-device mask feasibility spike

> **Status (14 November 2026): DEBUG-only spike, Kevin. Not an approved architecture.**
>
> It measures whether Vision person instance masks are affordable and useful **during a round**, next to
> today's pose-only pipeline. Every number on this page comes from your iPad runs; none are filled in yet.
>
> Two hooks sit in Edo's capture worker (`FrameStore.swift`, `CameraPipeline.swift`), and the benchmark core
> sits in his Capture folder. **Edo needs to review them.**

## What it does and does not change

- Nothing changes unless the app is launched with `-maskBench`.
  - Without the argument, the worker holds `nil` and skips the hook.
  - None of the code exists in Release builds.
- **Masks run after the frame's pose evidence is published**, on the same capture worker and the same pixel buffer.
  - A mask therefore never delays its own frame's pose.
  - It can delay *later* frames.
  - When the worker is busy, the frame store drops or supersedes frames instead of queueing them, so no backlog builds up. Those drops are counted.
- The benchmark request is the production calibration request: `VNGeneratePersonInstanceMaskRequest`, revision 1, full frame, `.up`.
- Masks run only while a live round is in progress (countdown, running, paused).
  - They never run while calibration holds a sample stamp, and never on a frame that already ran a calibration mask.
  - Calibration timing and acceptance are untouched.
- Results go only to the console, the recorder, and an optional overlay. Masks never reach:
  - tracking or calibration;
  - `BodySnapshot` or the judge;
  - pausing;
  - the mascots.
- Nothing is written to disk. The overlay shows a 128×72 label thumbnail; no camera image leaves the worker.

## Today's pipeline (relevant to the spike)

| Stage | Where | Facts |
|---|---|---|
| Capture | `CameraPipeline.swift` (`AVCameraDriver`) | Front camera, 1280×720 BGRA, 30 fps, `alwaysDiscardsLateVideoFrames = true`, unmirrored, host-clock capture timestamps |
| Admission | `FrameStore.copy` | One frame under construction, at most 3 owned source frames; extras are counted as capacity or superseded drops |
| Worker | `CameraCopySink` (one actor) | Per frame, in order: reconstruct the buffer → pose → tracker → calibration mask (calibration only, about 4 Hz) → publish measurements → **[benchmark mask]** |
| Pose | `PoseEstimator` | `VNDetectHumanBodyPoseRequest`, 2D; 16 joints kept (elbows dropped) |
| Masks today | `PersonSegmenter` | Instance masks, associated to players by all four torso joints; used for calibration only |

## Modes

| Mode | Argument | Masks |
|---|---|---|
| A — baseline | `-maskBench A` | none (same instrumentation) |
| B — hybrid low | `-maskBench B` | 4 Hz (calibration's rate) |
| C — hybrid medium | `-maskBench C` | 10 Hz |
| D — hybrid high | `-maskBench D` | 15 Hz (every second frame) |
| E — stress (optional) | `-maskBench E` | 30 Hz (every frame). Run it only if D leaves headroom. |

Any rate from 0 to 30 also works, for example `-maskBench 7.5`. The rate is scheduled on **capture time**: at most one mask per interval, with no catch-up burst after a stall.

| Option | What it does | Use in |
|---|---|---|
| `-maskBenchScript` | Large on-screen prompts that walk one tester through the 11 scenarios (about 3.5 min) and tag every sample by scenario | every run |
| `-maskBenchOverlay` | Inspection panel: the mask (followed person white, others grey), pose joints (green ≥ 0.5 confidence, red below), mask top (cyan) and bottom (orange), whether mask and pose come from the same frame | quality runs only; **off for performance runs** |
| `-maskBenchTrace` | One console line per mask, with pose availability, mask extents, nose, ankle and wrist heights | quality runs |
| `-maskBenchLabel <text>` | A free label printed in the summary, e.g. `dark-trousers` or `window-light` | any |

Add `-startSoloTest` to go straight to the DEBUG Solo Test: one player, the real camera, tracker, calibration and round.

## Running it on the iPad

**Xcode.** Edit the scheme, go to Run → Arguments, and add the arguments, one per line. Use the **Debug** configuration, because the spike is DEBUG-only. Run the app with the iPad connected; the results print to Xcode's console.

```
-startSoloTest
-maskBench C
-maskBenchScript
```

**Command line** (no scheme edit). Build once, then launch each mode with the console attached:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Sedactive.xcodeproj -scheme Sedactive -destination 'generic/platform=iOS' -configuration Debug -derivedDataPath /tmp/SedactiveMaskSpike build
```

```bash
xcrun devicectl list devices
```

```bash
xcrun devicectl device install app --device <DEVICE-ID> /tmp/SedactiveMaskSpike/Build/Products/Debug-iphoneos/Sedactive.app
```

```bash
xcrun devicectl device process launch --console --terminate-existing --device <DEVICE-ID> com.Edward-Kristian.Sedactive -- -startSoloTest -maskBench C -maskBenchScript
```

## Protocol (one tester)

**Before each run**

- Same room, light, background and camera position, with the tester 2–3 m away.
- Same clothing (except in the clothing runs). Low Power Mode off, other apps closed.
- Keep the charging state the same for every run, because it affects heat.
- Start each run with the iPad cool: the summary's thermal line should start "nominal".
- Use the same flags in every performance run. Script on and overlay off is recommended.

**Order**

- Performance runs: A, B, C, D, then D, C, B, A in a second sitting, to expose drift and warming.
- Run E only if D leaves headroom.
- Each run is one full Solo round (about 5 min). The script covers the first ~3.5 min; play normally after that.

**Quality runs**

- One run with `-maskBench C -maskBenchScript -maskBenchOverlay -maskBenchTrace`.
- Repeat it for:
  - light versus dark trousers, using `-maskBenchLabel`;
  - one other background or lighting.

**Script scenarios.** Each one is preceded by a 5 s "Next: …" prompt, which is not scored.

| # | Scenario | What to look at |
|---|---|---|
| 01 | Stand still | Baseline: pose and mask both present, top above the nose, bottom below the ankles |
| 02 | Slow squat ×3 | Mask kept while hips drop? |
| 03 | Fast squat ×5 | Same, under motion blur |
| 04 | Deep squat, hold 3 s ×2 | "when hips missing: person x/y" — does the mask still find the person? |
| 05 | Squat, hands behind back ×3 | "wrists missing: clear top x/y" — a top that is not cut off when the wrists are gone |
| 06 | Jump ×5 | Mask bottom rise against lower-ankle rise |
| 07 | Tiptoe, rise and hold ×3 (negative control) | Does the mask bottom stay near the floor while the ankles rise? |
| 08 | Head bow, knees straight ×3 (negative control) | Does the mask top stay put while the nose drops (top−nose grows)? |
| 09 | Lean left/right ×3 | Mask stays one person; side contact |
| 10 | Hide a wrist, then an ankle | Mask present while those joints are missing |
| 11 | Stand still | Drift against 01 |

**Important.** A silhouette's top or bottom is not proof of head clearance or of being airborne:

- hair, clothing, held objects and shadows count as silhouette;
- the mask has coarse rows.

The scenario lines give the raw ranges, and the negative controls (07, 08) decide whether the edges carry the meaning we need.

## What is measured

Lines printed during and after each run:

- **`[MaskBench]`** every 30 s: the last 30 s.
- **`[MaskBenchSummary]`**: the whole run, then one line per minute, which shows sustained degradation.
- **`[MaskBenchScenario]`**: one line per script step.

| Measure | How | Label |
|---|---|---|
| Pose service time p50/p95 | Host clock around the pose request on the worker | stage |
| Capture → pose available p50/p95 | Pose completion minus the frame's capture timestamp | stage |
| Mask request time p50/p95/max | Host clock around `perform` | stage |
| Mask summary time p95 | The benchmark's own scan of the mask (Debug, unoptimized Swift; an upper bound) | instrumentation |
| Capture → mask available | Mask completion minus the same capture timestamp | stage |
| Mask age at each pose | Each processed pose frame's capture time minus the newest mask's capture time: how stale masks are when a pose would use them | freshness |
| Pose and mask throughput | Processed frames and masks per second of capture time | rate |
| Worker per frame p95, busy % | Worker time from pose start to the end of the benchmark | occupancy |
| Frames not processed | AV late-frame drops, superseded frames and capacity drops between round start and end | drops |
| Render fps, long frames | Main-thread `SceneEvents.Update` ticks: interval p95, gaps over 50 ms and over 100 ms (stall proxy, not display presentation) | render loop |
| CPU | Sum of this process's busy threads, sampled 1 Hz (100% = one core) | device |
| Memory | `phys_footprint` peak (what Xcode's gauge shows), sampled 1 Hz | device |
| Thermal | `ProcessInfo.thermalState`, worst state and when it changed | device |
| GPU | **Not measured in the app.** Use Instruments (below). | — |
| Capture → screen | **Not measured.** See "End-to-end latency" below. | — |

**Overhead.**

- The worker records each frame under one lock. CPU and memory are sampled once a second.
- Console lines appear every 30 s, plus one per mask with `-maskBenchTrace`. Use trace only in quality runs.
- The spike runs in Debug, where Swift is unoptimized. Vision's own work is the framework's optimized code. The benchmark's mask scan is timed separately, so it can be subtracted.

**Instruments.**

- The intervals `Pose`, `MaskRequest` and `MaskSummary` are emitted as signposts: subsystem `Sedactive.MaskBenchmark`, category Points of Interest.
- To record, open Instruments, choose the iPad, attach to the running **Debug** `Sedactive`, and use Time Profiler plus Points of Interest and Thermal State.
- Add Metal System Trace for GPU in a separate, short run, because it is heavy.
- Product → Profile builds Release, which removes the spike. Either attach to the Debug app, or set the scheme's Profile configuration to Debug on your own machine.

**End-to-end latency (optional, separate).** Film the tester and the iPad screen together with a phone's slow-motion camera (240 fps). Count frames between the first visible body movement and the mascot's first response, over at least 10 squats per mode. This is the only user-perceived figure. Label it separately from the stage figures above.

## Results

**First device runs (14 November 2026).**

- Device: iPad Pro 11-inch (M5), iPadOS 27.2.1, Debug build.
- One tester, solo round, script on, overlay off.
- Each run measured 300 s of in-round time. Thermal state was "fair" throughout both runs.
- Mode A took 3 rounds; Mode C took 1.
- Mask figures are **stage** times; capture-to-screen latency was not measured.

| Mode | Pose /s | Pose p95 ms | Capture→pose p95 ms | Masks /s | Mask request p50/p95 ms | Mask age p95 ms | Frames not processed | Render fps / >50 ms | CPU mean | Memory peak | Thermal worst |
|---|---|---|---|---|---|---|---|---|---|---|---|
| A | 30.0 | 6.9 | 45.4 | — | — | — | 0 of 8,998 | 59.4 / 4 | 64% | 894 MB* | fair |
| B | | | | | | | | | | | |
| C (10 Hz) | 30.0 | 6.6 | 44.9 | 10.0 | 7.6 / 9.1 (max 10.7) | 66.6 (p50 33.4) | 0 of 9,003 | 59.5 / 0 | 65% | 623 MB | fair |
| D | | | | | | | | | | | |

\* Mode A's memory peak came from a round restart (it spanned three setups), not from steady play: steady minutes peaked at 733–767 MB.

**Other Mode C figures**

- **Worker time per frame (p95):** 10.6 ms in A, 30.6 ms in C. Busy 28% in A, 46% in C. Of the extra time, about 13 ms (p95) is the benchmark's own Debug scan of the mask, which is not part of a production request.
- **Capture → mask available:** p50 63 ms, p95 67 ms.
- **Detection:** of 3,001 masks, 0 failed, 1 found no person, 2,996 found one person and 4 found several.
- **Association:**
  - The production matcher matched 2,960 of 3,001 masks. It refused the rest as: tracker uncertain 26, poses 2 ≠ players 1 7, people 2 ≠ players 1 4, no tracker result 2, tracker lost 1.
  - The relaxed vote matched 3,000.
  - The head-bow scenario had the lowest production match rate: 82%, mostly "tracker uncertain".
- **The mask's top and bottom are not yet usable.** The followed person's **raw box** touched both the top and bottom of the image in about 100% of masks, even when standing still. Stray labelled pixels stretch it, so the edge-based rows below can't be filled from these runs. The benchmark now also reports a **body span** (the longest run of rows the person actually fills) and a per-scenario pixel profile, so the next Mode C run shows what stretches the box.
- **Hips were never lost.** With this tester, clothing and room, the hips were seen in 99–100% of frames in every scenario, including deep squats, in both modes. The case masks were meant to help with did not occur.

**Mode C quality check (overlay and per-mask log on, 210 s, same tester and room)**

- **Cost.** Pose 30.0/s; capture → pose p95 44.4 ms; mask request p50 7.1 ms, p95 8.4 ms; render 59.6 fps with no frame over 50 ms; no dropped frames. The overlay did not change these.
- **Detection and association.**
  - Vision detected one person in all 2,101 masks.
  - The production matcher matched 2,069. It refused the rest as: poses 2 ≠ players 1 28, tracker uncertain 3, rightHip not seen 1.
  - The relaxed vote matched all 2,101.
- **Raw box.** It reaches both image edges because of a few stray labelled pixels: 4–9 in the first and last rows, 16–189 in the border columns. The pixel profiles show this.
- **Body span, bottom.** It reached the image bottom in **86%** of masks, although the ankles sat at about 0.17 of image height. In the other 14%, it ended a median **0.097** image heights below the lower ankle. In this room, the person's mask runs on into the floor below the feet (shadow or reflection: inferred, not verified), so it says nothing about the soles. The tiptoe and jump comparisons can't be read from it.
- **Body span, top.** It sat 0.04–0.08 above the nose, a head, in only **45%** of masks. It was more than 0.10 above the nose in **53%**: something above the head joins the mask about half the time. The head-bow comparison can't be read from it.
- **Hips.** Still never lost, so the presence-without-hips case is still untested.

**What this run shows.** As measured here, the instance mask's global top and bottom are not usable gameplay evidence in this room. They would need local, per-column analysis near the head and feet (as calibration's anatomy extractor does), and this spike did not test that. Masks were cheap at 10 Hz on this iPad, and detection was steady.

| Scenario (mode C quality run) | Hips missing: person found | Ankles missing: clear bottom | Wrists missing: clear top | Mask bottom range vs ankle range | Top−nose range |
|---|---|---|---|---|---|
| 04 deep squat | | | | | |
| 05 hands behind | | | | | |
| 06 jump | | | | | |
| 07 tiptoe | | | | | |
| 08 head bow | | | | | |

## Decision gate (decide from the filled tables only)

- **GO — hybrid candidate.** At some mask rate:
  - pose throughput and capture → pose p95 stay close to A;
  - render fps holds;
  - thermal stays acceptable over a full round;
  - and masks add evidence where pose fails: person found in 04, a clear top in 05, a stable bottom in 07, a stable top in 08.
- **CONDITIONAL GO.** Useful evidence, but only affordable at a lower rate, or only with optimisation such as a cheaper summary or fewer requests while players stand still.
- **NO-GO — pose-only temporal redesign.** Masks cost pose throughput or render stability at every useful rate, or the negative controls show the edges don't carry the meaning.

**About the ~200 ms response target.** The spike measures only stage time, from capture to pose or mask availability. User-perceived latency adds:

- the camera's exposure and transfer before the timestamp;
- the game and render loop;
- display.

Those are measured only by the slow-motion method.

**Choose the rate from the data,** not 10 or 15 Hz by default: the lowest rate whose mask age p95 is acceptable for the movement scenarios, at a cost close to A.

## Not covered by a solo test

- Two-person mask separation and association: touching players, crossing, a bystander, different heights.
- Mask cost with two people in view; the request may scale with the number of people.
- Co-op identity: solo testing proves nothing about P1/P2 safety.

These need consented two-person sessions. The trace line format is the hook for a later offline replay; no replay tool is built in this phase.

## Phase 2, if the gate passes

- Mask summaries per player through `PersonSegmenter`'s association, extended so it does not need all four torso joints (Edo).
- A version-2 evidence contract carrying occupancy intervals next to today's fields (Edo and Jevon).
- Offline replay of consented two-person recordings through the baseline and candidate policies.
- A Release-configuration performance pass, and the slow-motion end-to-end latency check.
