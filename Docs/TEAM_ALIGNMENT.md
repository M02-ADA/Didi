# Sedactive Team Alignment

> **Status: DRAFT — not yet approved by the team.**
> This is the single source of truth for cross-team engineering rules. `AGENTS.md` (Codex) and `CLAUDE.md` (Claude Code) both point here.
> **Labels:** **Confirmed** = agreed by the team. **Proposed** = needs agreement from the affected owners. **TBD** = requires team approval; treat it as open.

**Precedence:** when sources disagree, follow the first that applies.
1. Approved current team decisions.
2. This file and the agreed shared contracts.
3. `Docs/Architecture/Game-Oriented-Architecture.md` for the current lean game-oriented folder structure; `Docs/LaserHeist-Architecture-Reference.md` for responsibility explanations subject to approved current contracts. Folder modules remain logical boundaries in the existing app target.
4. `LaserHeist-Architecture-Draft.md`, `LaserHeist-Prototype-Comparison.md` and prototype findings: historical context only.

## A. Ownership

Paths are relative to `Sedactive/`.

| Owner | Owns | Main folders |
|---|---|---|
| **Edo** (Codex) | Camera, Vision, segmentation, player tracking, calibration data processing, Motion, shared body-input contracts | `Shared/BodyTracking/` (Models, Processing, Capture and live/replay entry points), `Shared/Players/` |
| **Jevon** (Codex) | Game rules, laser checker, encounters, `GameClock`, session lifecycle including running the calibration step, co-op scoring, round summary | `Games/LaserHeist/Domain/`, `Games/LaserHeist/Session/`, `Shared/GameRuntime/GameClock.swift` |
| **Kevin** (Claude Code) | RealityKit world, spatial positioning, laser visuals, live cutout presentation, HUD/VFX integration, rendering debug view, the rendering update mechanism | `Games/LaserHeist/Rendering/`, `Games/LaserHeist/UI/PlayView.swift`, `Games/LaserHeist/Debug/PoseDebugOverlay.swift` |
| **Theo** (design) | UI/UX, art direction, visual assets, animation specs, design handoff | Design files; where game assets live is TBD with Kevin |

- **Rendering** (Confirmed): production LaserHeist rendering uses RealityKit, with mostly 2D assets placed in a virtual 3D space.
- **Unowned until assigned:** the Home, Setup and Results screens, and `Shared/Audio/AudioService.swift`.
- **One owner per file.** To change another owner's file, propose it to that owner and change it only after they agree.
- **Shared hotspot — `App/` (`AppDependencies.swift`, `RootView.swift`):** Edo maintains these files. Jevon and Kevin coordinate their wiring with Edo and keep each change small.
- **Structural decision (31 October 2026):** Lean Game-Oriented Modular Architecture with Shared systems and game-specific RealityKit ECS is the Tech Lead-approved layout. See [the current structure](Architecture/Game-Oriented-Architecture.md) and [migration history](Architecture/Structural-Migration-Report.md).
  - Edo explicitly authorized all structural relocations in this migration, including Jevon/Kevin files, without further owner approval solely for moves. This exception does not authorize functional edits, API/algorithm changes or changes of ownership.
  - LH-23's separate root test target, `GameWorldMapping.swift` / `PlayerCutoutEntity.swift` names and calibration-processing separation are preserved. The calibration process now lives at `Shared/BodyTracking/Processing/CalibrationSession.swift`.
  - App source has App, Games and Shared plus the existing Assets.xcassets. There is no global Features layer. Shared BodyTracking uses Models/Processing/Capture; existing source filenames remain unchanged.
  - No packages/targets, gameplay features or B2 settings are added/changed. All feature work remains paused.

## B. Integration contracts

Approved current body-input details are recorded in [the CP1 baseline](LH-00-Checkpoint-1-Contract-Proposal.md); the older summary below is not an exhaustive field list and does not override that baseline. This structural publication changes no contract or gameplay decision.

The **producer** defines each contract type once. Consumers import it and do not redefine it. Every body-data and cutout contract carries **player ID, capture timestamp, frame ID and calibration revision**, using the coordinate rules in C. Field names and Swift interfaces stay TBD until the producer's contract change is agreed (see E).

| Handoff | Minimum content | TBD |
|---|---|---|
| **Edo → Jevon** (`BodySnapshot`) | The common fields above. Per player: estimated crown and left/right soles in game units, each with a validity state; jump phase; tracking status. | Exact validity states; optional jump-cycle events |
| **Edo → Kevin** (per-player cutout, output of `PlayerCutoutCompositor.swift`) | The common fields above, plus cutout image, orientation/mirroring state, placement metadata, and a flag for masks that could not be matched to a player | Image or texture format |
| **Jevon → Kevin** (read-only for Kevin) | Encounters: ID, per-player beam band, warning time, crossing time. Game state: phase, game time, health, progress, score. Verdicts: PENDING / CLEAR / HIT / UNAVAILABLE. Game events. | Event list; how Kevin observes state |
| **Theo → Kevin** | Assets with layers, pivot/anchor point, transparency and intended depth layer; animation states; a trigger table mapping each game event to its effect | File format and location |

## C. Shared technical conventions

- **Coordinates:** one game space — a player plane in game units, with Y pointing up from the calibrated floor (Confirmed).
  - Edo converts the camera image into game space using each player's standing calibration.
  - Kevin converts game space into RealityKit world positions through one mapping, shared by lasers, cutouts and debug views. The mapping parameters are TBD.
- **Mirroring:** body data, game logic and replay data stay unmirrored. Display mirroring happens only in Kevin's world mapping. TBD — requires team approval.
- **Body estimates:** Vision has no crown or sole landmarks, so crown and soles are estimates built from landmarks plus each player's standing calibration.
- **Missing data:** missing, stale or invalid body data produces **UNAVAILABLE**, never CLEAR (Confirmed).
- **Rendering boundary:** game logic (`Games/LaserHeist/Domain/`) imports no SwiftUI, RealityKit, Vision, AVFoundation or Core Image. The laser checker works only on game data, never on RealityKit entities, transforms or physics (Confirmed).
- **Concurrency:** camera, Vision and segmentation work runs off the main actor. Only immutable values, or explicitly owned image handles, cross into main-actor code.
  - The project-wide convention (`nonisolated`/`Sendable` usage, Swift 6 mode) is TBD — requires team approval.

**Time, GameClock and the RealityKit frame loop** (high-priority contract)

- **Clock (Confirmed):** `GameClock` (Jevon) is the only game time. Jevon's session/game code owns time progression and every gameplay decision: encounter timing, pause and resume, and any time scaling such as slow motion. Capture timestamps (camera time) stay separate, and Jevon converts them to game time.
- **Kevin's side:** Kevin's rendering integration supplies one agreed frame-update signal to Jevon's code, then updates visual entities from the resulting game state and events. Rendering keeps no clock that advances gameplay. Purely cosmetic animation may run on RealityKit time, provided judged geometry is never moved.
- **Verified API facts** (Apple documentation, 28 Oct 2026):
  - `RealityView`'s `update` closure (iPadOS 18+) runs when SwiftUI view state changes, so it is **not** a per-frame game loop.
  - Per-frame options include `SceneEvents.Update` (iPadOS 13+) and ECS `System.update(context:)` (iPadOS 15+).
- **Exact update mechanism:** TBD — chosen jointly by Kevin and Jevon.

**Body data vs. cutout display — two different moments**

1. **Live display:** Kevin shows each live cutout together with the placement data from its own source frame ID, or within an agreed, device-validated lag.
2. **Judgment:** Jevon judges each laser crossing from the body sample selected for that crossing time. That sample may belong to a different frame than the one on screen.

- The renderer keeps showing live video; it does not freeze to display the judged frame.
- How frames are associated, the permitted lag, and how visual feedback stays consistent with the verdict are **TBD — agreed and verified on device**. Do not hard-code a lag value before it has been measured.

## D. Coding, architecture and skills

- **Reuse:** reuse existing types and services, and make the smallest change that completes the task.
- **State:** keep exactly one copy of each piece of state. Health, time, calibration and player identity each live with their owner.
- **Abstractions:** add abstractions, layers or generic frameworks only when the current task needs them.
- **Testability:** keep gameplay logic testable with replay data, without a camera or renderer.
- **Skills:**
  - Use relevant, installed skills when they materially improve the task.
  - Read the skill's `SKILL.md` before applying it.
  - Installed skills differ per machine, so load only the ones that match the task. Routine changes may need none.
  - Install a skill only with the developer's permission.
  - Report a skill as used only if you actually read and applied it.

  Agent-specific skill guidance lives in `AGENTS.md` and `CLAUDE.md`.

## E. Workflow (risk-based)

- **Small change inside your own area:** inspect → implement → run relevant tests → report.
- **Shared contract, another owner's code, or any change to coordinate, timing or data meaning:** inspect → propose the change (what, why, who is affected) → agree with the affected owners → implement → integration test → report.
- **Git:**
  - Work on your assigned feature branch.
  - Check `git status` before editing, and leave other people's changes untouched.
  - Keep each change scoped to its task.
  - Announce contract changes before merging.
  - Commit, push, merge, rebase or reset only when your developer asks.
  - The branch and PR flow (feature → `staging` → `main`)

## F. Testing, privacy and reporting

- **Small changes:** run targeted tests. **Contract changes:** add a cross-component integration test.
  - Gameplay: use deterministic replay data.
  - Camera, texture streaming, transparent cutouts and rendering performance: validate on a physical iPad.
- **Test foundation:** LH-23 provides the separate root `SedactiveTests` target. Shared tests live in `SedactiveTests/Shared/`; Laser Heist domain/session tests live in `SedactiveTests/Games/LaserHeist/`. Report tests as passed only if they actually ran.
- **How far you got:** state which level you reached — **builds**, **tests pass**, **Simulator checked** or **device checked**.
- **Privacy:** keep participant recordings, camera frames, biometric pose data and secrets out of the repository. Use only approved, consented test recordings.
- **Report:** changed files, tests run and their results, skills used, known limitations, and integration work other owners need to do.

## G. Decisions

- **Confirmed — task owner (Kevin), 19 November 2026:** one gate activation button per player, drawn as a Blender asset.
  - **Rule (Jevon's `LaserGame`):** `LaserVaultButton` has one case, `activate`. A vault opens once every player in the roster has pressed their own button: both players in co-op, P1 in the DEBUG Solo Test.
  - **Unchanged:** deadline, timeout, entry and freshness rules, deduplication, scoring, health and stage progression.
  - **Judged zone (`LaserLiveRoundGeometryV1`):** the former MIDDLE zone, unchanged: (0.42 h out, 0.715 h up), radius 0.105 h. The HIGH and LOW zones are removed. The zone was not widened for the larger drawn button; that would need device data.
  - **Asset (Kevin):** `GateButton.usdz`, modelled in Blender (`Art/LaserHeist/GateButton/`: `.blend` master, build and export scripts, README).
    - Shape: a 0.30 m red cap in a recessed socket and bevelled collar, on a 0.44 m octagonal plate with screws.
    - Parts: `Housing`, `Collar`, `Socket`, `Cap` and `Accents` are separate prims.
    - Size: 11,464 triangles, about 0.5 MB, UsdPreviewSurface only.
  - **Stand (Kevin, same day):** `GateConsole.usdz`, modelled in Blender (`Art/LaserHeist/GateConsole/`), replaces the leaning column housing. That housing's open face pointed along the wall, so the game camera saw it side-on.
    - Shape: a front-facing octagonal head (0.58 × 0.54 m, 0.50 m deep at the bottom, chamfered top-back) with a recessed dark panel the button plate sits on, a 0.17 m post with an emissive strip, and a floor foot.
    - Size: 1,196 triangles, about 57 KB.
    - The head is symmetric; P1 and P2 mirror the placement, never the mesh.
  - **Console (Kevin):** the dock, the stand's floor position (the post 0.36 m outward of the console face), the corridor, the camera and the player positions are unchanged.
    - **Mounting:** the button is level and keeps the orientation it had on the former column's inner front corner: turned 80 % of the way from the corridor toward the game camera. P1 and P2 mirror each other. The head is built round it, and the post is yawed with the head.
    - **Hand alignment:** the button sits at chest height at the mascot's depth (0.011 m in front of the players' plane), 0.075 m outward of the console face.
      - Its contact point lies on the reach plane the mascot's hand already stops at. A straight arm's fist now ends 0.10 m from it, sideways only, instead of 0.26 m (0.20 m of that toward the camera).
      - The stand's post moved 5.5 cm to stay under the head.
      - The docked body clears the head by at least 8 cm.
      - The reach, the judged zone and the thresholds are unchanged.
    - **Mascot stop and arm (20 November 2026, iPad review):** during a gate only, the mascot's stop (dock) is 20 cm further from its wall, so it stands clearly apart from its console. The button's contact is where its arm ends when it opens wide toward the wall: 97 % straight, 15° down, 20° into the scene.
      - **Presentation only; the game state is unchanged:** `LaserBoards` docks and bounds stay ±1.746, and LEAN placement is unaffected. A first version that moved the game state's docks left boards 17 cm off the wall after a gate and voided a LEAN laser in the full co-op replay, so it was reverted.
      - While a gate's consoles show (no laser is judged then), the drawn mascot is eased back from its game-state board onto the gate's dock (0.2 s), and eased out again when the gate opens (`RobotAvatarLayer.gateHold`). Covered by `LaserGateConsoleTests`.
      - Rendering's own steering (replays, previews) docks at the gate dock while `docksActive`; its bounds are the wall stops (`LaserGateConsole.wallStopX`, matched by `LaserBoardGeometryConsistencyTests`).
      - The judge still measures from the dock (`vaultReachShift`).
      - The fist snaps onto the cap within 1.2 radii of the judged zone (in about 0.05 s) and lets go beyond 1.4. The hand is kept on the console's surface, never inside it. This is presentation only.
      - Earlier depth-only passes were superseded because they did not read on screen.
      - The docked body clears the button by at least 15 cm.
      - DEBUG launch arguments (`-gateDockBack`, `-gateArmBack`, `-gateSetBack`, `-gateSetOut`) tried other placements on a device. They were removed with the side-wall mount.
    - **Fist contact:** the fist lands on the cap's face, on its side toward the mascot. The docked body keeps 0.038 m of clearance from the whole button.
    - **States:**
      - unavailable: cap sunk 12 mm, accents dark;
      - available: the cap springs up, red accents that brighten as the fist approaches (`RobotAvatarLayer.consoleApproach`, presentation only);
      - pressed: 25 mm travel along the cap's own axis with an overshoot and rebound, then locked at 20 mm; the accents flash white, then settle green, and the post strip turns green;
      - gate opened: a white surge.
    - **Fallback:** a stand-in with the same part names is shown only while the asset has not loaded.
  - **On the gate's door frame (Kevin, 20 November 2026, after the iPad review of the side-wall mount):** this replaces the free-standing stand, the wall-mounted box, the wall jamb, and then buttons on the corridor's side walls. Nothing new is built: the corridor and the door look as they always did.
    - **Why not the side walls:** the walls (±4.41 m) are outside the camera's view at the players' depth (±2.58 m on 4:3, ±2.81 m on the iPad). A mascot beside a wall button had to stop 2.8 m deep, where it showed at 53 % of its size. No camera position fixes this in co-op (measured).
    - **Mount:** one button per player on its side of the door's frame (`LaserGateConsole.frameX` ±2.45 m, 0.62 m high), facing the camera, on a compact 0.26 m collar 0.15 m deep (`standoff`). The collar sits wholly on the frame's jamb (2.405–2.785 m), under the plate, so the panels slide open behind it.
    - **Door:** with the buttons, the door stops 0.35 m behind the players (`doorDepth`; `VaultPresentation.doorStopZ`). The mascot's head reaches 0.31 m forward of its root and stays 3.7 cm clear of the door. Without the buttons the door keeps its authored stop.
    - **Why the collar:** a cap flat on the door would sit 0.27 m in front of the shoulder, so the 0.37 m arm could reach only 0.22 m sideways and the body would hide 84–90 % of the cap. With the collar the arm reaches 0.34 m sideways and the body hides 0–2 % of the cap (measured on the iPad).
    - **Mascot:** it stays at the players' depth and normal size. The lean still steers the board to its dock (±1.746, unchanged). While the gate's button is live and the board is at its dock, the drawn mascot glides 0.21 m sideways to its `station` (±1.952 m), where the arm opened sideways (97 % straight) ends on the cap's front (`RobotAvatarLayer.gateTravel`, presentation only). It glides back when the gate opens or times out, and is at its dock before travel resumes (0.85 s).
      - The glide sets off within 8 cm of the dock and lets go only beyond 12 cm (hysteresis), so a lean wobbling at the threshold never sends the mascot back and forth. A glide still under way when the final vault's walk-in starts settles to zero instead of staying in the walk.
      - The dock is the wall stop (the earlier `dockBack` and `gateHold` are removed: with equal values they had no effect).
    - **Unchanged:** the steering, `LaserBoards`, the judge (the tracked wrist, the approved zone and `vaultReachShift`), the snap and all gate rules. The hand is kept on the cap, collar or door surface (`outsideConsole`).
    - **Clearances:** the body at the station clears the button by at least 2.8 cm and the door by 3.7 cm. When the opened door rides past, the button misses the docked mascot by at least 12.6 cm, and the board passes under the plate. The board at the station stays on both 4:3 and iPad screens.
    - **Look:**
      - the button, its materials and its press are unchanged;
      - idle: a red cap with a red halo on the door's surface;
      - pressed while the gate is closed: the cap stays red (it locks down, the accents flash white and settle red);
      - gate open: a green cap, green halo and a green point light, for both players at once, from the game's unlock (`vault.opened` / `coopGateSucceeded`) as the door starts opening and throughout its opening (`VaultPresentation.showOpenButtons`; red = gate closed, green = gate open, 20 November 2026). A gate that times out never shows green;
      - the halo does not write depth, so it never cuts into the translucent mascot.
    - **Access module (Kevin, 20 November 2026, visual integration only):** the button is built into a compact access module on the jamb (`GateAccessModule`), so it reads as part of the gate rather than an object fixed to it. Positions, the cap, its press, the materials, the glow and the interaction are unchanged.
      - A shallow chamfered access panel (0.25 × 0.80 m, 2.5 cm deep) flush on the jamb's lavender band, with the frame art's dark outline, its header plate's lighter top bevel and inset line, and two vent grooves.
      - A stepped chamfered neck (with a seam groove) from the panel to the plate's back replaces the plain collar box.
      - An indicator bar above the button, like the header's bar, follows the button: dark, red while live, green once activated.
      - Flat unlit tones read from the door art (`vault_frame.png`), with no tone mapping, like the door itself.
      - The button asset's stand body (`Body`, now its own part with unchanged geometry) is hidden: on the frame it hung in front of the door.
      - The hand is kept on the panel's face too (`outsideConsole`); the clearances are unchanged.
    - **Check:** Simulator checked only; it still needs an iPad check.
  - **Instruction:** in co-op the gate says each player presses their own button; in Solo Practice it says "PRESS YOUR BUTTON".
  - **Replay fixtures:** P1 presses at 18.6 s and P2 at 21 s, so the gate opens when it did before.
  - **Integration for Jevon:** review the domain change (`LaserGameState.swift`, `LaserGame.swift`, `LaserLiveRoundDirector.swift`, `LaserReplayScript.swift`) and the updated domain and session tests.

- **Proposed — Kevin, 19–20 November 2026; needs Edo's review (body-input code and data meaning):** bystanders outside the calibration boxes.
  - **Linking:** only a person whose torso centre is inside a calibration box can be linked as P1/P2 (`PlayerAcquisitionZones`; `PlayerTracker`, `LaserSessionSetup.peopleInView`). After linking, identity stays the tracker's. Two people in one box still refuse.
  - **Zones from the drawn boxes:** each zone is the drawn box's X range in the unmirrored source, through the calibration stage's own display transform (`CalibrationStageLayout`), for the delivered frame's shape. The built-in 1280 × 720 camera keeps its earlier zones; staging's external cameras (e.g. 960 × 720) get the boxes their players see (`CalibrationZoneGeometryTests`).
  - **Person mask:** other people may be in view (staging refused every frame with an extra person). A player's instance is admitted only when shown to be theirs alone: every person Vision saw is a pose candidate, and no observed joint of anyone else, at any confidence, lies on it; another person who cannot be located refuses everyone (`PersonMaskSeparationTests`). Limit: a person the pose request misses entirely cannot be checked, as before.
  - **Status:** Simulator and unit tests only; not checked on an iPad with a bystander or an external camera.

- **Confirmed — task owner (Kevin, calibration implementation ownership), 18 November 2026:** standing calibration `StandingCollectionPolicyV1.2` and setup reliability.
  - **Stability rule:** a player is stable once 10 valid samples within the existing 10 s span agree within the unchanged tolerance (max of 3 px and 2 mask rows) on head-top and both soles.
    - The samples must come after the feet last moved (both soles elsewhere for two samples in a row).
    - They must be at least 60 % of the valid samples across their span.
    - The reference is the mean of the latest 10 agreeing samples. Acceptance still requires exactly 10.
  - **What changes:** head-top jumps no longer restart the window. On the iPad, a still player's head-top jumped 5–8 rows in 35 of 126 samples, which restarted V1.1's window (progress 70 % → 20–30 %).
  - **What still blocks calibration:** a real step, sustained movement and an evenly alternating estimate.
  - **Unchanged:** freshness, identity and the landmark and anatomy checks.
  - **Comparison:** [LaserHeist-Calibration-Algorithm-Comparison.md](LaserHeist-Calibration-Algorithm-Comparison.md) (option D, plus the movement-boundary and share refinements).
  - **Setup:**
    - every failed automatic attempt counts and pauses 2 s;
    - after 3 attempts the players always get Try again;
    - a progress drop names its reason;
    - Vision's mask model is warmed once per body session, off the camera worker, so the first-use load never costs a calibration attempt.

- **Confirmed — task owner, 16 November 2026:** Diamond Time lasts **20 active seconds** in Solo and Co-op. This supersedes the earlier ten-second duration. The live paw board supports six active diamonds initially, eight at ten seconds remaining, and ten at five seconds remaining.

- **Confirmed — task owner (Kevin), 11 November 2026 (evening):** head-top estimate fix and setup framing.
  - **Head-top (`AnatomicalCandidatePolicyV1`):**
    - The "nothing above the head" check now tests columns outside the ears by 25 % of the ear span. Previously it tested the ear columns themselves; real ears lie on the head's outline, so every real head was refused, as a synthetic test against the committed code shows.
    - Head-top rays may differ by up to 15 % of half the ear span, not a fixed 2 px, which had refused players standing near the camera.
    - A head-top more than 1.2 ear spans above the eyes is refused (hands on the head).
  - **Feet and confidence:** the foot rules and all confidence rules are unchanged.
  - **Refusal reasons:** each refusal now carries its own reason. The players' hints no longer merge head and foot problems.
  - **Joints:** B1 also keeps Vision's knees, for diagnostics only. B2 identity, gameplay and K03 do not read them.
  - **Setup screen:** shows the whole camera frame (aspect fit), with guides sized as shares of the image.
- **Confirmed — task owner (Kevin), 11 November 2026 (later the same day):** automatic onboarding and faster standing calibration.
  - **Automatic setup:** the setup steps run by themselves, each only when its existing conditions hold: pair search, linking, an "upright" prompt (1.5 s) before any sample, calibration, acceptance, and the countdown. No step buttons remain. Retries are bounded: 3 calibration attempts, then "Try again"; 2 automatic setup restarts after identity loss, then "Restart setup".
  - **Calibration sampling (`StandingCollectionPolicyV1.1`):**
    - One sample every 0.25 s instead of 1 s.
    - Each player keeps their own window of 10 consecutive stable samples (within 10 s). A refused sample is skipped for that player only; only an identity failure restarts a window.
    - The 3 px stability limit is kept but never set below one row of the person mask the estimate comes from (quantization). Confidence, freshness, identity and the landmark consistency checks are unchanged.
  - **Pending:** real device spread and timing data, logged as `[LaserSetupTiming]` in DEBUG.
- **Confirmed — task owner (Kevin, full integration ownership), 11 November 2026:** live end-to-end play on the iPad.
  - **Calibration:** a standing candidate may be accepted with mask-derived head-top and sole **estimates** (`StandingEstimateAcceptancePolicyV1`). Each must be present, uncropped and stable in all 10 samples within the existing 3 px candidate, and must agree with the pose landmarks (head-top above the nose, each sole at or below its ankle, hips between). The players still confirm explicitly. Accepted references keep `referenceQuality = .experimental` and are never relabelled validated; the 3 px spread is a stability check, not proof of accuracy.
  - **Live round:** the complete replay's five-minute wave script, evidence windows, diamond planner and one-vault-per-minute rule. A live director (`LaserLiveRoundDirector`) runs them on the one live `GameClock`, rebasing each minute onto the game time at which it starts. Vault buttons and diamonds use the existing D09 wrist-entry path. The interaction geometry (`LaserLiveRoundGeometryV1`) is scaled to each player's accepted standing height and still needs device comfort testing.
  - **Contract changes:** `CameraPipeline.previewSession` (display only); `BodyInputProviding.acceptedCalibrations` (read only); `PlayerCalibration.referenceQuality` (optional, provenance); `LaserLiveRecovery.validate(boundary:)`. Diamonds are now drawn mirrored about each lane, like the players.
- **Confirmed — task owner, 10 November 2026:** each valid diamond collection awards **25 team points**; Diamond Time starts with **four** diamonds; **Diamond Time targets persist until collected or phase end**, with no passage miss; normal diamonds are permanently missed after passing. This clarification supersedes the earlier missed-slot interpretation for Diamond Time. Collection-triggered replacement, the maximum of four active team diamonds and ten-active-second duration remain unchanged. See the [D09 decision record](LaserHeist-D09-Contact-Decision-Proposal.md#subsequent-d09-v1-approval). This is a product choice, not approval of producer schema, coordinate mapping, reach parameters or physical acceptance.
- **Confirmed — Edo, Tech Lead, forwarded by Jevon on 10 November 2026:** D09 v1 architecture/behavior permits optional atomic wrist evidence on the single CP1 gameplay path, independently valid wrists, fresh projected outside→inside circular-zone entry, strict pre-deadline capture/arrival, timeout on equality, deterministic deduplicated batches, no retroactive out-of-order awards and invalidation on lifecycle/context changes. Jevon may proceed with J04/J05 synthetic fixtures. **Exact field-level freeze remains pending** CP1 compatibility and agreed coordinate mapping; Edo owns E08 and Kevin owns zone rendering. Details and limits are in the [D09 record](LaserHeist-D09-Contact-Decision-Proposal.md#subsequent-d09-v1-approval).

- **Confirmed — task owner, 4 November 2026:** after the final Dual Key Vault, Diamond Time lasts **10 active seconds**. At most **4 diamonds** are active for the team at distinct positions; each collection spawns a replacement elsewhere, with no fixed total collection quota. See [the gameplay rules](LaserHeist-Gameplay-Rules.md#b4a-diamond-time-after-the-final-vault). This records Jevon's product revision, not collaborator sign-off on pending contact/placement details.

- Label statements **Confirmed**, **Proposed** or **TBD**.
- Coordinate, timing and data-meaning changes always go through the contract workflow in E.
- Update this file only for an approved decision or a recurring problem. The person proposing the change drafts the edit, and the team approves it.
