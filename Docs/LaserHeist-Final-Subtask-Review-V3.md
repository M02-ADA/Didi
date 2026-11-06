# Laser Heist — Subtask Finalization & Ownership Review V3

**Prepared:** 6 November 2026  
**Status:** **TECH LEAD RECOMMENDATION — READY FOR TEAM SIGN-OFF, NOT YET AN APPROVED GITHUB BACKLOG**  
**Working repository branch:** `feat/architecture` at `7cab612`.  
**Source-verified revision (6 November 2026, Kevin, Claude Code audit):** claims below were checked read-only against `origin/feat/architecture` `7cab612`, the avatar spike `origin/spike/front-facing-avatar` `b130d5a` and the unmerged `origin/feat/lh18-vault-presentation` `665b06c`. The revision re-scopes K01/K02/K06/K07 around existing POC work, adds the board's LH-24 mapping, corrects the asset references to the final orange mascot, keeps U04 ownership open and records user-reported single-player iPad feasibility. **No decision, ADR or owner assignment is approved by this revision.**  
**Source materials:** `LaserHeist-SUBTASK-DRAFT-OLD.md` (v0.9, 28 Oct; not in the repository — the checked-in [historical backlog](LaserHeist-Cooperative-Active-Gameplay-DRAFT.md) holds LH-00–LH-23), [Architecture V2](LaserHeist-Architecture-V2-Avatar-Pivot.md) (PROPOSED), the [Technical Workplan V2](LaserHeist-Technical-Workplan-V2.md) (41-package catalog and the source of acceptance criteria) and the Current Architecture Baseline Audit supplied in conversation (not a repository artifact).

> **What this document does:** makes a final *recommended* owner allocation, dependency/parallelization strategy, anti-collision file rules, and migration plan from old subtasks to the V2 packages. It does **not** modify GitHub Issues, declare architecture accepted, endorse untested device behavior, or authorize code changes. All `WP-*` IDs are local planning IDs.

## 1. Executive technical decision

**Retain the existing Lean Game-Oriented modular monolith.** Keep `Sedactive/App/`, `Sedactive/Shared/BodyTracking/`, `Sedactive/Shared/GameRuntime/`, `Sedactive/Games/LaserHeist/{Domain,Session,Rendering,UI,Debug}/`, the existing test target, and `RealityKitContent`. The *only new principal code location* for the representation pivot is **`Sedactive/Games/LaserHeist/Rendering/Avatar/`**, with an immutable game-specific adapter/pose packet and the rig/retargeting code. Other changes implement missing behavior in existing folders and make App composition/provider injection work; they are not folder migrations.

**Product direction:** two humans operate the game in front of the iPad; two rear-view 3D avatars represent them in the corridor. Preserve **one camera, one trusted association, one accepted calibration authority, one CP1 gameplay stream consumer, one GameClock, one LaserGame**. The avatar gets a separate, bounded, original-source-correlated **numeric** output. No avatar-derived gameplay verdict or duplicate live stack from the spike.

**Authority invariants (RETAINED, not reopened):** exactly one camera source, one player-association authority, one accepted-calibration authority, one authoritative CP1 gameplay evidence stream with one consumer, one GameClock and one LaserGame per round, and a **separate** source-correlated numeric avatar presentation packet. Kevin's renderer never produces gameplay data, evidence, identity, calibration, time or verdicts.

**Do not directly publish 41 new GitHub coding issues.** The 41 V2 packages are a rigorous coverage catalog: **10 architecture decisions + 31 review/implementation/validation packages**. Close decisions as four coordinated review meetings/ADRs, then publish only the authorized actionable implementation/review packages in progressive waves. An already-completed foundation is not reissued; K07 is an existing foot-planting POC awaiting a separate adoption decision, not a release gate.

## 2. Review verdict: what the old backlog gets wrong today

| Old assumption or task | V3 treatment | Why |
|---|---|---|
| LH-14: live human cutouts as the production representation | **Supersede the future visual deliverable.** Preserve completed CP2 handoff/texture work and tests; replace the **new primary representation** scope with K01–K05. | Mentor pivot; cutout producer is not required for avatar imagery. Do not delete CP2 yet. |
| LH-13 as one large task for all camera, Vision, tracking, calibration and live input | **Decompose** into E01–E09 and relevant decisions, without repeating accepted A1/A2/B1. | Current Camera/Vision diagnostics exist; B2a needs re-review; downstream live processing/provider are incomplete. |
| LH-08 as a complete live session and replay interchangeable by a mere type switch | **J01–J03** separate provider injection, replay-only driving, and live phases/recovery. | Current coordinator directly constructs ReplayBodyInput, with synthetic time assumptions. |
| LH-01/LH-10 high laser only checks crown | **Follow current game contract:** high laser requires crown **and both wrists**; low laser requires soles and valid airborne evidence. | Older backlog descriptions precede newer authoritative checker. |
| LH-16: maximum one team health loss per encounter | **Do not carry this into implementation.** Current game commits per-player HIT; two HIT may cost two health. Change only via a separately approved game-rule decision. | Old backlog policy conflicts with current code audit. |
| Parent/child as stored `Player` roles/profiles | **Keep anonymous P1/P2** with explicit binding; no extra persistent player/profile model. | Existing accepted CP1 identity contract. |
| Camera mirrored/unmirrored = avatar screen mapping | **Separate transforms.** Canonical capture remains unmirrored; co-facing anatomical controls are the working proposal. | Body-facing-camera and avatar-facing-corridor have different local bases. |
| LH-15/16/17/19 or LH-11 listed as if wholly unimplemented | **Preserve implemented domain/replay/world work.** Only scope unimplemented connections or new behavior. | Verified source has LaserGame, WaveDirector, CollisionJudge, replay presentation/results, and RealityKit world. |
| Entire game consists only of high/low lasers and cutouts | **Add mandatory full-game scope:** vault contact, diamond spawn/collect/replacement, all phases, Home/Setup/Calibration, recovery/results/retry, event-driven audio and device/parent–child testing. | Actual product scope and V2 workplan. |
| Old source paths and old migration requirements | **Do not use as current file paths.** Source-audit paths and current V2 module layout supersede them. | LH-23 migration, A1/A2/B1 and additional rendering/domain files already happened. |
| Avatar spike as "renderer concepts only" | **Recognize a substantial reusable POC:** final orange mascot, 20-joint rig, two avatars, retargeting, IK, crouch/jump, arms, smoothing, foot planting/lateral stepping, tests and DEBUG gameplay hosts. K01/K02 are production **adaptation**, K07 is an existing POC awaiting review. | Spike `b130d5a`. Its live camera/Vision/identity/calibration/jump/session stack is excluded and never copied. User-reported single-player iPad feasibility only. |
| Vault presentation as future K06 work | **Integrate the existing LH-18 vault presentation** (`feat/lh18-vault-presentation`, tested, unmerged); K06 adds diamonds and phase cleanup. | Prevents rebuilding finished work. |

**Important historical distinction:** the old v0.9 document is a record, not a checklist to mark done en masse. Classify each mapped LH task as **retained-completed portion**, **re-scoped remainder**, **superseded goal**, or **deferred**, based on verified current source and separately accepted checkpoints. Do not infer that all old work is merged or complete.

## 3. Final recommended assignment — no UNASSIGNED engineering packages

These four owner choices are **proposals to be confirmed by the people concerned**, not decisions made on their behalf. They deliberately minimize cross-file editing and keep Edo off additional screen/audio implementation. Rebalance after reviewing workload and capacity; a package count is **not** a time estimate.

| Package | Proposed engineer | Owns these implementation files/scope | Required reviewers / hard boundary | Priority |
|---|---|---|---|---|
| **U01 — Home/navigation** | **Kevin** | `UI/HomeView.swift`, display-side onboarding; supplies route requirements | Edo owns final `App/RootView.swift` wiring; Jevon reviews actions; Theo designs | P2 |
| **U02 — Setup/calibration/recovery UI** | **Jevon** | `UI/PlayerSetupView.swift`, `PlayerSetupState.swift`, `CalibrationView.swift`, session-action bindings | Edo owns measurement/calibration results, not the SwiftUI phase; Kevin reviews lane visuals; Theo designs | **P1** |
| **U03 — Results/retry presentation** | **Kevin** | `UI/ResultsView.swift` and presentation-only route/actions | Jevon owns authoritative `RoundSummary`, retry/outcome state; Edo App wiring; Theo copy | P2 |
| **U04 — Audio/event cues** | **OPEN — Jevon (V3 proposal) or Kevin (alternative)** | `Shared/Audio/AudioService.swift` + a narrow game-specific event-to-cue adapter (if needed) | Owner consumes read-only committed events; Edo reviews Shared lifetime/App composition; the other engineer reviews; Theo audio design/assets | P2 |

**Result after provisional allocation:** Edo **13**, Kevin **13**, Jevon **14** (or Kevin 14 / Jevon 13 if U04 moves), Theo **1 design-review package**; **0 unassigned engineering packages** once D10 closes (previously Edo 13 / Kevin 11 / Jevon 12 / Theo 1 / unassigned 4). U01 Kevin, U02 Jevon and U03 Kevin are provisionally supported by Kevin; **U04 is not accepted** and stays a team decision.

**Workload, not counts (for D10):** Edo carries the input critical path (E01→E09) plus review of every App change — the real bottleneck. Jevon carries the session critical path (J01→J03), all remaining vault/diamond rules (J04–J08) and P1-critical U02. Kevin's K01/K02/K07 and the K06 vault part already exist as POC/branch work, so his remaining load is adaptation, K03/K04, K05 live integration and diamond/phase visuals. Arguments for U04 → Kevin: audio cues fire on the same committed events as K06/LaserFeedback visuals (one place to enforce one cue per event) and relieve Jevon. Arguments for Jevon: events originate in his domain and he defines their identities. Either way the cue source must be committed domain events, never render callbacks or a timer. These counts include decisions and QA leads, not just implementation effort. Kevin's avatar and Jevon's session/gameplay remain substantial; U01/U03/U04 should be time-boxed to essential functionality. If either engineer cannot accept the load, reopen **D10** and explicitly reassign or obtain help *before* publishing those issues—not after they become late blockers.

**Why split UI this way?** Kevin implements visual Home/Results using stable actions/data; Jevon implements setup/recovery views closely tied to his phase state. The separation is by **screen file**, not by duplicating lifecycle authority. Audio is event-driven but not a second timer or a renderer-created scoring event. Theo remains an art/UX reviewer, not an assumed Swift developer.

## 4. One owner per state and source file — contract of engagement

| Single authoritative owner | Files/domain | Incoming data/action boundary | Forbidden overlap |
|---|---|---|---|
| **Edo** | `App/AppDependencies.swift`, `App/RootView.swift`, `Shared/BodyTracking/**`, CP1 provider and real calibration | Jevon submits session requests/complete calibration intent; Kevin specifies packet capability; App composes dependencies | No camera or source generation created in views/renderer; no duplicate tracker, baseline acceptance, CP1 reader or republishing from cached latest observations. |
| **Jevon** | `Games/LaserHeist/Domain/**`, `Session/**`, `Shared/GameRuntime/GameClock.swift` | Consumes exactly one CP1 gameplay iterator/context/status; exposes immutable session/game state/events | No Vision inference, world/mesh contact judgment, camera ownership, rendered-time gameplay clock, or accepted baseline store. |
| **Kevin** | `Games/LaserHeist/Rendering/**`, `UI/PlayView.swift`, `Debug/PoseDebugOverlay.swift`, new `Rendering/Avatar/**` | Consumes independent game-specific immutable avatar packets and read-only domain/session state | No identity rematching, asset-as-evidence, calibrated-body authority, second camera/FrameStore consumer, GameClock, or HIT/CLEAR. |
| **Jevon (U02)** | `UI/PlayerSetupView.swift`, `UI/PlayerSetupState.swift`, `UI/CalibrationView.swift` | Calls approved session actions; displays returned readiness/progress, never locally infers it | No direct capture start; does not commit calibration from UI or identify people from view coordinates. |
| **Kevin (U01/U03)** | `UI/HomeView.swift`, `UI/ResultsView.swift` | Receives navigation and immutable summary/action models; passes intents to coordinator/App | No duplicate session coordinator or retry generator. |
| **U04 owner (pending D10)** | `Shared/Audio/AudioService.swift` and narrow cue adapter | Responds to committed game event IDs; App provides service | No sound-driven game logic or independent time-based event generation. |
| **Theo** | Art/UI/UX/copy/participant playtest designs | Produces approved spec/asset/source record and reviews cues and legibility | No hidden engineering task or license approval without the required technical review. |

**Hotspot rule:** no one edits an owner-hotspot from a separate branch without a small owner-approved patch/PR. For example, Kevin's Avatar hook and Jevon's provider injection may require App composition changes, but **Edo lands the final `App/` wiring**. Similarly, Jevon supplies domain event schemas and Kevin connects only rendering. One person merges *each hotspot change* at a time. Prefer small integration PRs to simultaneous entire-scene/whole-session rewrites.

**Contract-first rule:** an interface change starts with the **producer** plus consumer reviewers; then use immutable fixtures/mock ports to unblock downstream work. If a joint, status, metadata or calibration field is missing, **do not define a parallel version on the consumer side**.

## 5. The 41-package catalog — owner, priority, order

The full acceptance criteria and exclusions remain in `LaserHeist-Technical-Workplan-V2.md`. This register is the concise execution/assignment overlay, not a second contradictory source of technical specifications. “Review” below does not authorize coding.

| ID | Primary engineer/reviewer | Priority | Gate / recommended order | Deliverable summary |
|---|---|---|---|---|
| D01 | Kevin | P0 | Review with D02/D03 | Co-facing/anatomical-world transform |
| D02 | Jevon | P0 | Review with D01/D03 | Explicit binding-to-lane confirmation |
| D03 | Jevon | P0 | Review with D01/D02/D05 | Full-rebind/lifecycle policy |
| D04 | Edo | P0 | Review with D05; before E03/E04 | Same-source masks; calibration request/result/cancel/acceptance |
| D05 | Jevon | P0 | Review with D03/D04; before J01 | Provider injection, replay/live clock and retained source lifetime |
| D06 | Kevin | P0 | Review with Edo; before E07/K02/K03 | Original-source avatar packet, joints, fallback |
| D07 | Jevon | P0 | Review with Edo/Kevin; before K04 | Human-body collision/visual fairness protocol |
| D08 | Kevin | P0 | Before K01 | Rights/provenance record for the orange mascot (`mascot.usdz`, from Asset 13), rig axes, distribution/resources |
| D09 | Edo | P0 | Review with Jevon; before E08/J04/J05 | Wrist/contact evidence + interaction rules |
| D10 | Edo | P0 | Team sign-off now; before U01–U04 | Engineering UI/audio owners and review boundaries |
| E01 | Edo | P0 | First technical safety gate | Independent B2a core review; accept/revise, **not B2b** |
| E02 | Edo | P1 | E01 + D02/D03 | One worker-owned B2b tracking, no unsafe swaps |
| E03 | Edo | P1 | E02 + D04 | Bounded same-source calibration masks |
| E04 | Edo | P1 | E03 + D04 | Validated real standing candidates, no acceptance store |
| E05 | Edo | P1 | E04 + D04/D05 | Live provider accepted-context transaction |
| E06 | Edo | P1 | E05 | Measured crown/wrists/soles/airborne CP1 evidence |
| E07 | Edo | P1 | E02 + D06; **parallel with E03–E06** | Trusted reusable numeric pose/status fork for Kevin |
| E08 | Edo | P2 | E06 + D09 | Validated live hand/wrist gameplay evidence |
| E09 | Edo | P1 | E06 | Two-person physical input gate |
| K01 | Kevin | P1 | D08 | **Adapt existing spike rig** (two avatars, axes, joints, teardown, tests): remove DEBUG gate, fail clearly on missing asset, replace placeholders |
| K02 | Kevin | P1 | K01 + D01/D06 | **Adapt existing spike retargeter/IK** to the D06 packet; keep fixtures; record D07 size/arm policy |
| K03 | Kevin | P1 | K01 + D06; parallel with K02 (separate files) | Packet adapter, latest-only, expiration/fallback |
| K04 | Kevin | P1 | K02/K03 + D07 | Visual versus human geometry synthetic fairness |
| K05 | Kevin | P1 | E06/E07/E09 + K04 + J03 | Calibrated live avatar under same source/session |
| K06 | Kevin | P2 | Vault part: **PR now** (existing LH-18 branch); diamond/phase: J04/J05 | Integrate existing vault presentation; add diamond and phase visuals from read-only domain events |
| K07 | Kevin | P3 | K02 + D07; separate adoption decision | **Existing POC** foot planting/lateral stepping with deterministic tests; review/adopt, not a release gate unless the team decides |
| J01 | Jevon | P1 | D05; early parallel work | Same coordinator, injected provider, replay-only driver |
| J02 | Jevon | P1 | J01 + D02/D03/D04 | Explicit bind/calibrate/setup phase core + controlled tests |
| J03 | Jevon | P1 | J02 + E09 | Actual live ready/countdown/pause/recovery/GameClock |
| J04 | Jevon | P2 | D09; **parallel with camera work** | Complete vault domain semantics against fixtures |
| J05 | Jevon | P2 | D09; **parallel with camera work** | Diamond spawn/collect/miss/replacement and score |
| J06 | Jevon | P2 | J01 + J04/J05 | Full cooperative game-phase replay integration |
| J07 | Jevon | P2 | E08 + J03/J04/J05/J06 | Live vault/diamond event acceptance (one evidence path) |
| J08 | Jevon | P2 | J03/J06/J07 | Live summary, teardown, retry contract |
| U01 | **Kevin** (proposed) | P2 | D10; early fixtures | Home/navigation interface, Edo owns final RootView patch |
| U02 | **Jevon** (proposed) | **P1** | D10 + J02 + binding/calibration decisions | Setup/calibration/recovery SwiftUI against session actions |
| U03 | **Kevin** (proposed) | P2 | D10 + J08; can mock summaries earlier | Results/retry presentation against J08 output |
| U04 | **OPEN:** Jevon (proposed) or Kevin (alternative) | P2 | D10; basic cues on existing event fixtures | AudioService/event-to-cue path; Edo reviews Shared |
| T01 | Theo (design review) | P2 | K02 + relevant decisions | Rear-view character, cues, recovery comprehension |
| Q01 | Edo (joint acceptance lead) | P2 | All complete-product gates, after Q02 | Physical two-person/parent–child game and safety gate |
| Q02 | Kevin (release verification lead) | P2 | Required integrated candidate | Simulator/Release, asset/license and performance gate |

**Count:** 10 decisions + 31 other packages = **41**. Original V2 technical owner totals are unchanged except the four explicit **proposed** U reassignments. Package descriptions remain in their existing source-of-truth workplan. Avoid both copying the 41 sections into tickets indiscriminately and using this summary in place of detailed acceptance criteria.

## 6. Close P0 decisions as FOUR joint review bundles, not ten disconnected debates

| Review bundle | Combine | Decision meeting outcome | Required sign-off |
|---|---|---|---|
| **ADR-A — Control, binding, and recovery** | D01/D02/D03 | Signed physical left/right and arm examples, unmirrored setup vs P1/P2 lane mapping, explicit binding, ordinary loss vs full rebind/new real generation and restart UX | Edo/Kevin/Jevon; Theo for usability |
| **ADR-B — Source/clock/calibration/packet** | D04/D05/D06 | One source/lifetime/consumer, exact provenance, replay vs live clock, request-cancel-acceptance boundary, bounded avatar status and missing joints | Edo/Jevon/Kevin |
| **ADR-C — Fairness, assets, and contact** | D07/D08/D09 | Human evidence remains judge; visible avatar/laser comparisons (including the equal-size and outward-arm presentation choices), mascot rig/art clearance, hand/reach input and Jevon interaction policy | Edo/Jevon/Kevin; Theo for character/zone clarity |
| **ADR-D — Delivery ownership** | D10 | Accept/adjust U01–U04 proposed owners, App hotspot, reviewer availability, consent/safety/playtest and audio asset handoff | Edo/Kevin/Jevon/Theo |

Each D01–D10 keeps a separate decision row and acceptance condition inside its bundle. A meeting does not automatically accept all issues. Record decision, alternate rejected, interface version, tests/fixtures impacted, named approvers, and implementation authorization separately.

## 7. Parallel execution waves — not calendar promises

### Wave 0 — Architecture and safety decisions (no implementation without separate approval)

- **Edo:** E01 independent B2a audit, D04/D09/D10; coordinate ADRs.
- **Kevin:** D01/D06/D08; inspect rig/license and synthetic fixture needs.
- **Jevon:** D02/D03/D05/D07; define time, bind and failure policy.
- **Theo:** character and directions, review relevant signed examples.
- **Deliverable:** recorded ADR-A–D decisions and B2a ACCEPT/REVISE; owner-approved interfaces. Stop any blocked implementation until its own gates close.

### Wave 1 — Independent, controlled components

- **Edo:** E02 B2b, then E03 mask topology; E07 trusted numeric source fork **after E02** can proceed independently of calibration, using explicitly uncalibrated capability.
- **Kevin:** open the existing LH-18 vault presentation PR to `staging` (K06 part 2) first; after D08/D01/D06, one "avatar foundation" PR adapting the spike rig + retargeter (K01+K02) on a synthetic DEBUG host, without `Live/`; then K03 packet lifecycle in separate files and the K07 adoption review.
- **Jevon:** J01 provider-injection/replay split, J02 controlled phase core; J04 vault fixtures and J05 diamond fixtures **after D09**, without live input.
- **UI/design:** Kevin U01 draft presentation; Jevon U02 after J02, Theo instructions. Keep those changes outside Edo's App hotspot until patch review.
- **Milestone:** replay still works; synthetic rear-view input remains explicitly synthetic; no fake physical identity.

### Wave 2 — Validated human evidence + full replay completeness

- **Edo:** E04 validated standing candidates → E05 accepted context → E06 human measurements/live CP1 → E09 device gate. E08 measured hand evidence when approved; do not delay laser slice for contacts.
- **Kevin:** K04 synthetic spatial/temporal fairness; K06 vault/diamond presentation against Jevon's event fixtures.
- **Jevon:** J06 full-domain replay phases; extend live phase/recovery tests, preparing J03; U04 event-driven audio can be built against committed fixture events.
- **Milestone:** deterministic full game with fixture controls, and independently verified calibrated two-person input (not yet an integrated product).

### Wave 3 — Live integration at narrow ownership seams

- **Edo:** source/provider branch and App wiring reviewed into integration, maintains original host-clock provenance and one observer/stream owner.
- **Jevon:** J03 live session recovery; J07 real interaction evidence; J08 summary and retry. U02/U04 production wiring under Jevon's UI/Audio authority.
- **Kevin:** K05 joins live avatar input to the one RealityKit host, synchronizes visible hazard/rig, preserves Source/ID invalidation; U03 outcome UI and U01 Home routes through Edo-reviewed App wiring.
- **Milestone:** P1 laser vertical slice first, then vault/diamond full run. Each integration step has its own device check; do not defer all human testing to final QA.

### Wave 4 — Completion and release evidence

- **Kevin:** Q02 release/performance/resource audit; fix rendering defects in owner branch; T01 with Theo.
- **Edo:** Q01 leads integrated two-person/parent–child test plan, with input acceptance artifacts.
- **Jevon:** exact GameClock/verdict/event/retry correctness and full replay regression; resolve session defects in owner branch.
- **Theo:** actual usability and comprehension observations; safe participation/consent plan.
- **Milestone:** complete product tested under recorded real conditions. K07 is not required unless the team adopts it as a gate.

## 8. Branch, PR, and merge safety protocol (recommended, not a claim of current team policy)

**Architecture source:** `feat/architecture` holds the V2/docs and can be published for review; do not merge experimental avatar spike wholesale. **Code integration destination:** verify the team's actual `staging` policy before opening implementation PRs. Do not implement feature code directly inside `feat/architecture` merely because the `Avatar/` folder has been created there.

1. Before starting a coding package, identify its **approved** contract/ADR, owner, expected paths, dependencies, acceptance tests, base commit, and review pair. Create one independently scoped feature branch/PR from the agreed current integration baseline; do not open two active PRs changing one owner-hotspot unless explicitly coordinated.
2. **Producer contract first:** e.g., D06 signed → E07 reusable original-source fork → K03 adapter fixtures → K05 integration. D04 signed → E03/E04 results → E05 atomic acceptance → J03 live status/phase. D09 signed → E08 measured interaction values → J07 acceptance. These are owner-specific, not invitations to share state ownership.
3. **One owner of source edits per hotspot:** Edo `App` and capture/provider, Jevon coordinator/domain/setup/audio, Kevin scene/avatar/Home/Results. If another owner needs a small addition, send an owner-reviewed patch or agree on a serial integration change; never duplicate a manager/service in a parallel branch.
4. **Review/acceptance before merge:** focused tests, applicable whole regression, Debug/Release checks for resources/host, ownership/concurrency checks, and source/context negative cases. Reviewers record accepted limits; a synthetic or Simulator pass does not prove physical parent/child fairness.
5. **Source of truth:** current accepted contracts and actual source beat old backlog path/status descriptions. B2a re-review is independent of B2b approval. Do not close old issue IDs automatically; cross-link and supersede only by explicit owner agreement.
6. **When a merge conflict occurs:** stop, inspect the concrete base/ours/theirs diff, ask the file owner for the intended merge, rerun the affected regression. No `git add .` assumption, no unsafe force push/rebase, no copying the entire spike's Live folder.

**Recommended first PR order (each from its own feature branch to `staging`, owner-reviewed):**

1. `feat/architecture` docs (this revision) → team review; merge once sign-offs are recorded or explicitly as PROPOSED docs.
2. LH-18 vault presentation (`feat/lh18-vault-presentation`, Kevin) — already built; review against current domain events. Touches GameplayScenePresenter/LaserScene/VaultDoor, so land it before other scene work.
3. In parallel, no shared files: J01 provider injection + direct GameClock/coordinator tests (Jevon, Session/Domain); E01 B2a review then E02 (Edo, Shared/BodyTracking).
4. Avatar foundation K01+K02 (Kevin, `Rendering/Avatar/**` + a small DEBUG scene/PlayView hook), rebased after step 2. It replaces the five `7cab612` placeholder files.
5. K03 adapter after D06 (Kevin, separate files); E07 producer side (Edo) against the same packet fixtures.
6. K07 adoption PR if approved; K06 diamond/phase after J05.

`App/` changes are always a small Edo-landed patch. Never merge the spike branch; copy only reviewed `Rendering/Avatar/**` files and their tests.

**Git detail:** Git does **not** track empty directories. If `Rendering/Avatar/` contains no tracked file, a push will not publish that folder. After the team agrees, place a small `README.md` or `.gitkeep` in that directory if you intend to version an empty placeholder; otherwise let the first approved avatar code introduce it. This is a filesystem/Git fact, not confirmation of what is already inside the user's local folder.

## 9. Acceptance gates and exact handoffs

| Gate | Acceptance evidence | Sign-off / handoff |
|---|---|---|
| **G0 — architecture/contract review** | ADR-A–D decided; D01–D10 marked agreed or explicitly blocked; B2a pure-core result separately evidenced | Edo coordinates; affected producer/consumer owners accept |
| **G1 — safe input** | B2b no-swap/ambiguous/overflow tests and physical pilot; same-source calibration/head+both soles; CP1 accepted context/full replacement; no-frame invalidation | Edo produces, Jevon reviews evidence/session consequences; Kevin reviews numeric fork |
| **G2 — synthetic avatar** | Rights-cleared rig, anatomical left/right, two independent avatars, limited missing-joint behavior, source packet freshness/fallback, synthetic beam visual comparison | Kevin produces, Edo approves source/anatomy, Jevon fairness, Theo art |
| **G3 — P1 live laser slice** | Two bound/calibrated persons, high/low lasers, exact original sample provenance, one GameClock, safe pause/rebind/recovery, rear-view avatar and usable setup | Edo input; Jevon session/rules; Kevin visuals; device checks |
| **G4 — complete game** | Validated real wrist evidence, vault/diamond domain, full replay phase event history, live phase transitions, final summary/retry and readable Home/results/audio | Jevon rules/session; Edo evidence; Kevin visual feedback; Theo UX |
| **G5 — release / participation** | Required Debug/Release resources, consent/safety, two-person device matrix, real parent–child observations, bounded resource/performance and honest limitation report | Q02 Kevin technical release lead; Q01 Edo joint acceptance lead; team review |

**Physical testing must be incremental.** E02/E03/E04/E09, K05 and J03 have scoped device evidence; Q01 is the final *integrated* acceptance, not the team's first encounter with real movements. Parent–child usability and safety evidence is distinct from engineering tests with two adults. Do not retain identifiable camera recordings without explicit permission and appropriate controls.

## 10. Old-to-new subtask migration crosswalk

| Legacy ID | Mapping to V2 packages | Status interpretation / action |
|---|---|---|
| LH-23 | Completed foundation, no new WP | Preserve accepted test-target/structure; do not reopen migrations. |
| LH-00 | CP1/CP2 completed foundations; E05/E06/E07 | Preserve accepted contracts; add numeric avatar handoff rather than rename cutout packet. |
| LH-22 | D04, E03, E04; C acceptance E05 | Calibration still required; source/acceptance kept separate. |
| LH-01 | D07, D09, J04/J05/J06 | Latest game rules and accepted source prevail over legacy one-damage/crown-only wording. |
| LH-02 | T01, U01/U02, K05/K06 | Theo's cue/HUD design review retained, no automatic Swift duty. |
| LH-03 | D08, T01, K01/K06 | Update art to rear-view avatar visual context; existing corridor work retained. |
| LH-04 | D07, K04/K06, T01 | Beam core must align with judged band, not render-only physics. |
| LH-05 | K02/K06, T01 | Animation event state table and safe cues adapted for avatar. |
| LH-06 | D10, U04 | Assign engineer and licensed assets; event-driven audio. |
| LH-07 | Completed foundations, D09/J04/J05/J06 | Extend only missing domain/fixture vocabulary. |
| LH-08 | D05, J01/J02/J03/J08 | Keep GameClock; adapt replay/live composition and recovery. |
| LH-09 | Existing CollisionJudge/evidence tests; E06/J03 | Preserve selection semantics and add live bridge. |
| LH-10 | Existing judge; D07/K04 | Human-body verdict authority unchanged; visual agreement reviewed. |
| LH-11 | Existing LaserScene/WorldMapping; K01–K06/Q02 | Reuse corridor/lanes, add avatar and full phase visuals. |
| LH-12 | Existing replay slice; J01/J06 | Preserve and expand replay, don't repeat a completed demo as new feature. |
| LH-13 | E01–E09, D02–D06; J03 | Decompose live input; earlier A1/A2/B1 not re-created. |
| LH-14 | **SUPERSEDED** future primary cutout display; K01–K05 | Keep CP2 production handoff/rendering code and tests; deprecate only after authorized replacement. The avatar spike (`b130d5a`) supplies K01/K02/K07 adaptation sources. |
| LH-15 | Existing WaveDirector; J06, D07 | Preserve comfort/schedule contracts; complete phase integration, no rewrite. |
| LH-16 | Existing LaserGame rules; J04–J06, D09 | Honor current HIT/health semantics; don't reinstate outdated one-damage rule. |
| LH-17 | Existing RoundSummary/Results, J08/U03 | Complete live terminal/retry/summary, not redo replay ResultsView. |
| LH-18 | **Vault presentation implemented** on `feat/lh18-vault-presentation` (`665b06c`, tested, unmerged) → K06 integration; remaining art/feedback scope K02/K04/K06, U04/T01 | Integrate, do not rebuild; adapt aesthetic and feedback scope to avatar, avoid redundant sound triggers. |
| LH-19 | J01/J06/J08, E/K focused regressions, Q02 | Maintain replay/domain regressions across all integrations. |
| LH-20 | E09, K05, Q01/Q02 | Scoped physical checks plus integrated final matrix; remove cutout-only cases from required avatar acceptance. Kevin's user-reported single-player iPad avatar feasibility (spike lab) is input, not acceptance. |
| LH-21 | T01, Q01, Theo UX report | Actual consented parent–child comprehension and comfort remains required. |
| LH-24 (board) | D09 → E08 → J04/J05 → J07; K06 presentation only | **Build Hand Contact for Vault Buttons & Diamonds**, from previously supplied board information (this audit could not read the Project board; status/owner to confirm). Edo produces validated hand/wrist evidence, Jevon accepts contacts in the one session, Kevin shows zones/feedback and never detects contact. Not the earlier informal LH-24 label for gameplay-scene integration. |

## 11. Definition of Ready and Definition of Done for every implementation PR

**Ready (must all be true):** owner and reviewers named; package/branch scope bounded; status of every hard prerequisite and ADR recorded; producer/consumer interface version known; affected files and hotspot owner approved; deterministic positive/negative fixtures prepared; resource/time/privacy implications reviewed; target Simulator/device verification specified. A “ready for review” planning row does not satisfy this gate.

**Done (must all be evidenced):** implementation confined to scope, no duplicate authority; focused tests plus relevant regression passing with recorded commit; no stale source/calibration/control resurrection; bounded lifecycle/cancel/cleanup; review approved by affected owners; Debug/Release and physical gates performed **when applicable**; task-specific acceptance fulfilled without changing unrelated policies; Git history/PR traceable; docs and old issue cross-references updated. No fabricated performance, test-count, or participant outcomes.

## 12. Remaining sign-offs — these cannot be assumed complete

1. **Kevin + Jevon + Edo:** approve architecture V2 authority split, anatomical/binding mapping and collision visual fairness; Theo confirms comprehension.
2. **Edo + Jevon:** approve calibration request/result/cancel acceptance and provider source lifetime/recovery/clock semantics.
3. **Edo + Kevin:** approve numeric pose packet, joint sufficiency, no-frame status and rig visual fallback.
4. **Edo + Jevon:** approve wrist/contact input feasibility, vault/diamond judging semantics, and any later CP1 extension.
5. **Kevin + Theo + Edo:** close USDZ origin, rights, rig/resource inclusion and visual direction.
6. **All engineering members:** explicitly accept or rebalance **U01 Kevin, U02 Jevon, U03 Kevin, U04 Jevon**, check capacity and shared editing hotspots.
7. **Whole team:** confirm implementation branching/PR review workflow and supervised device/playtest schedule, without assuming a specific Academy deadline or unseen resources.

**Open questions by person (answers become the recorded decisions):**

- **Edo:** Will E07 publish B1's 14 joints plus per-player standing reference values in game units, and is an elbow extension to B1 wanted (the retargeter works without it)? Will you drop the five placeholder avatar files or let K01 replace them? Can you reserve App-patch review time for J01/K01?
- **Jevon:** Do you accept the human-body judge plus the two avatar presentation departures (equal 1.6 m size, outward arm envelope) for D07? Which domain events will J04/J05 publish for vault buttons and diamonds, and are today's vault events stable enough to merge the LH-18 presentation now? Do you keep U04 or prefer Kevin to take it?
- **Kevin:** Confirm U01/U03, and whether you would take U04. Confirm K07 adoption timing after the avatar foundation.
- **Theo:** Confirm rights/provenance for Asset 13 and the derived mascot (D08), the outward raised-arm look, and the setup copy explaining that the image-right person is P1 on the left avatar lane.

**If approvals are not yet recorded:** keep both architecture and workplan `PROPOSED`, and treat this document as a recommended team-ready allocation rather than a unilateral final assignment. Once accepted, record signed decisions in a small decision/ownership section, then authorize packages individually. Old backlog remains historical and is not silently replaced in GitHub.
