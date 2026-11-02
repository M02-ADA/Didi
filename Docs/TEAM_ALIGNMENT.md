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

- Label statements **Confirmed**, **Proposed** or **TBD**.
- Coordinate, timing and data-meaning changes always go through the contract workflow in E.
- Update this file only for an approved decision or a recurring problem. The person proposing the change drafts the edit, and the team approves it.
