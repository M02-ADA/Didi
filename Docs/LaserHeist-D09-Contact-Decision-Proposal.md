# D09 — wrist interaction decisions for vaults and diamonds


**Latest task-owner clarification, 10 November 2026:** Diamond Time has four persistent targets for ten active seconds. Uncollected targets do not pass/miss/disappear; collection alone spawns a replacement, with at most four active. Only normal diamonds are permanently missed after passage. This supersedes earlier bonus passage/missed-slot assumptions below. Bonus contact admission uses the phase deadline, not the spawn's normal passage exit.
10 November 2026 · Jevon consumer handoff · **D09 v1 architecture/behavior APPROVED by Edo; exact CP1 fields and coordinate mapping remain OPEN**

## Subsequent D09 v1 approval

Jevon forwarded Edo's Tech Lead architecture decision after reviewing this proposal. Edo approves the optional atomic single-stream wrist-evidence direction; independent left/right validity; fresh outside→inside circular-zone entry with no dwell/interpolation; capture and arrival strictly before deadline with timeout winning equality; deterministic deduplicated batches followed by transitions/replacements; ignoring out-of-order captures; and clearing pending entry on pause, source loss, calibration/rebind, Stop and Retry.

Edo explicitly authorizes **J04/J05 synthetic fixtures now**, while he checks CP1 compatibility and implements E08. This supersedes the earlier requirement below to wait for a fully frozen producer fixture surface before doing synthetic domain work. The tracker consumes domain zone membership, not an invented CP1 attachment; J07 still waits for Edo's actual schema and agreed coordinate mapping.

Edo delegates the tie policy to Jevon's fixtures: target output order is UUID lexical order, and simultaneous entrants on one target choose **P1 left → P1 right → P2 left → P2 right** as a representative. This never adds personal points or multiplies team rewards. Radii, placement, comfortable reach, mapping and numeric freshness remain unapproved production parameters.

**Confirmed by task owner, 10 November 2026:** Jevon approves **25 team points per diamond, four initial Diamond Time diamonds, and persistent uncollected bonus targets until collection or phase end**. Collection-triggered replacement remains required. These product choices do not approve measurement/reach/mapping or source compatibility.

The earlier proposal/search record follows for provenance. Its OPEN/PROPOSED labels are superseded only for the specifically approved items above; they do not negate this later decision.

### First implementation checkpoint

`LaserContactEntryTracker` implements the approved domain entry/batch rules. Its input is per-target membership (`outside`, `inside`, `unavailable`) already classified from an eligible capture; it carries **no producer measurement schema**. A revocable domain lifetime rejects old work but does not replace producer source/binding/calibration checks. J07 must perform those checks using Edo's eventual exact interface before classifying zones.

The tracker keeps one frame high-water mark, one newest capture time and bounded active-target hand state. It ignores older frames/captures, checks conflicting duplicates of the retained latest frame, rejects invalid timelines, requires explicitly configured freshness, and keeps round-wide used target IDs. Domain time/cutovers are GameClock values; no camera timestamps are retimed here. Removed targets release transient state, while used IDs remain reserved for the round.

Eleven focused test definitions passed on the iPad Simulator (`/private/tmp/sedactive-d09-entry.log`), covering independent wrists, held poses, invalidation, staleness, deadlines, duplicates/order, deterministic same-frame ties and new-target isolation. This is synthetic rule verification, not E08, physical reach or CP1 compatibility validation.

## Edo follow-up and this revision

Jevon supplied Edo's D09 reply on 10 November 2026. Edo explicitly confirms that D09/LH-24 is **not approved/frozen**, proposes independently valid wrist evidence through the single CP1 consumer, and requests agreement on contact semantics **before** J04/J05 integration. He asks Jevon to specify zones, one-time activation, simultaneous contacts and the CP1 representation.

The concrete v1 proposal below answers those questions. It is Jevon's review proposal, not Edo's acceptance of these details. No Swift producer type, runtime threshold, product choice or new contact path is introduced by this revision.

## Finding and scope

The earlier repository review found no approved D09 decision or complete validated wrist-contact surface in the inspected sources. Edo's later reply confirms the open status in his records too. The source search remains a scoped finding, not a claim about other private conversations.

Inspected: the current checkout; all locally available `origin/*` branches after fetch; architecture/workplan decision records; repository issue/PR searches; relevant PR discussions; and available related Sedactive chats.

| Evidence | What it establishes |
|---|---|
| [Workplan D09](https://github.com/M02-ADA/Didi/blob/feat/architecture/Docs/LaserHeist-Technical-Workplan-V2.md#L220-L232) and its decision register | Contact evidence, timing/reach, points, initial population and missed-slot policy still require affected-owner agreement. These are planning proposals, not approved producer interfaces. |
| [Final Review V3](https://github.com/M02-ADA/Didi/blob/feat/architecture/Docs/LaserHeist-Final-Subtask-Review-V3.md) remaining sign-offs | Edo/Jevon contact feasibility/semantics and any CP1 extension remain a distinct sign-off. |
| [Gameplay Rules G1/G11/G12/G14](LaserHeist-Gameplay-Rules.md) | Wrist-only product intent exists; input/reach/timing, diamond value and missed-slot details remain open. The 25-point value is a candidate. |
| [PR #16](https://github.com/M02-ADA/Didi/pull/16) and [PR #7](https://github.com/M02-ADA/Didi/pull/7) | Implemented vault commands/replay use synthetic contacts. The PR review does not define or approve a live wrist-contact contract. PR #7's older 15-second finale is superseded by the current 10-second rule. |
| [CP1 geometry](../Sedactive/Shared/BodyTracking/Models/BodyGeometry.swift) and [live measurement extraction](../Sedactive/Shared/BodyTracking/Processing/BodyMeasurementExtractor.swift) | Current gameplay geometry has wrist Y, not a complete calibrated 2D wrist/reach surface. Raw Vision/experimental anatomy is not accepted contact evidence. |
| Edo's published `feat/vision-live-pipeline` at `f163a36` | Sequential Stop/Retry is implemented. That change does not supply D09 or validated crown/independent soles/airborne. |

## Retained product rules

- Vault: three buttons per player, either wrist, free order; both sides complete before the existing five-second opportunity ends. Repeated activation does not add progress. Pause retains committed buttons and remaining game time.
- Normal diamond: wrist interaction during passage; permanently missed afterward. Diamond Time targets persist until collection or phase end. All awards go to one team score.
- Finale: ten active seconds, at most four team diamonds at distinct positions, a valid collection creates a replacement elsewhere, and no total collection quota.
- Human input remains authoritative. Avatar joints, IK and RealityKit contacts cannot establish a pickup or button activation. Missing/invalid evidence cannot become an award or player damage.
- One game clock and one authoritative session consumer. Existing accepted calibration/context and source cutovers remain producer-owned.

## Decisions needed before dependent implementation

### 1. Edo evidence and the single-consumer route

Edo defines the smallest producer-owned surface; Jevon reviews its gameplay use. Required meanings to resolve:

- Player and left/right wrist identity, calibrated position/reach semantics, and independent validity.
- Original generation, frame/capture time, geometry and accepted calibration provenance; internal control/source checks must reject revoked work.
- Missing/weak/stale/occluded wrists, uncertain identity, geometry changes, pause, stop and rebind behavior.
- Delivery through the sole session evidence path, including replay/fixture compatibility. No second CP1 subscriber or unrelated latest-pose join.

This proposal freezes no Swift names or fields. Any CP1 extension needs explicit producer/consumer and replay-compatibility review. Jevon will not manufacture accepted references from candidate observations or normalize raw Vision wrists into a parallel contract.

### 2. Contact eligibility and timing

Edo/Jevon agree capture eligibility, arrival cutoff, deduplication and boundary ordering. Kevin/Theo review visible/reachable zones.

- Select target zone shape/size, calibrated reach, entry/overlap/dwell behavior and hand/player eligibility without invented production radii or thresholds.
- Define how contact capture time maps through GameClock, including late and simultaneous input and phase transitions.
- Preserve the existing vault-command behavior: at its current deadline, timeout wins. Decide explicitly whether the measured-input admission design requires any different reviewed handling; do not silently reuse the laser evidence window.
- Agree diamond passage boundaries and phase-end ordering. Ten active seconds and no late post-phase awards remain the product intent.
- Cancel/revoke in-flight contacts across pause, source/context changes and Retry; a held/old pose cannot create a new award automatically.

### 3. Jevon product choices — resolved after the original proposal

| Decision | Existing rule | Candidate for review — not selected |
|---|---|---|
| Points per accepted diamond | Team reward, exactly once per diamond | **25 points — task-owner confirmed, 10 Nov.** App interaction stays unconfigured until a reviewed plan is supplied. |
| Initial Diamond Time population | At most four active team diamonds, distinct positions | **Start with four — task-owner confirmed, 10 Nov.** |
| Lifetime | Collection-triggered replacement is confirmed | **Bonus targets persist until collected/phase end; normal diamonds miss permanently after passage.** |
| Normal diamond placement/passage | Confirmed total-team per-minute ranges; finish before vault entry | Seed/positions, separation, speed/passage windows and simultaneous/boundary rules need explicit selection. |

Normal placement/speed and physical reach remain open. The three explicit product choices above are implemented in synthetic/domain tests; they are not physical acceptance or approval of a producer interface.

## Jevon's concrete D09 v1 proposal for agreement

This preserves the original proposal. The later approval at the top supersedes its PROPOSED label only for the listed architecture/behavior items. Extra placement/separation, reach, coordinate and numeric parameter details still require review; there are no production geometry/freshness defaults here.

### A. Evidence representation and ownership

Prefer one **optional, producer-owned wrist-contact evidence attachment on the existing CP1 snapshot**, published atomically with that snapshot. This is a conceptual representation for Edo to review, not a requested Swift API name. Do not alter the meaning of the existing scalar wrist Y fields or join CP1 with an independently read latest E07 pose.

| Part | Proposed meaning |
|---|---|
| Attachment source envelope | Original source generation, epoch, geometry revision, frame ID, capture timestamp, control revision and binding/calibration context. Inherited snapshot fields must match exactly; additional source fields must be checkable against a producer-approved current context. |
| Per-player evidence | Explicit confirmed player ID and accepted calibration revision; left and right wrists remain separate. No reassignment based on height or proximity. |
| Each wrist | Measured/calibrated `(x, y)` in the shared unmirrored, floor-relative player plane; independent confidence and validity. Valid coordinates must be finite; unavailable evidence carries no usable position. |
| Absent attachment / unsupported recording | Contact capability UNAVAILABLE; existing laser snapshots and older replay files retain their prior meaning. A fixture must explicitly supply synthetic contact evidence to exercise contact decisions. |
| Confidence | Edo defines confidence semantics and the validated acceptance threshold. Jevon consumes explicit validity and checks current provenance/freshness; he does not invent a confidence threshold or upgrade weak evidence. |
| Consumer checks | Reject mismatched source, binding, control or accepted calibration context. Epoch/control acceptance must use Edo's reviewed atomic context semantics; current CP1 does not yet expose the complete proposed surface. |

Edo chooses the smallest backward-compatible schema after checking live and Codable/replay compatibility. If a snapshot attachment cannot be safely represented, review an equivalent atomic single-stream envelope before coding; do not add a second subscriber. No image, Vision object, rig joint or physical-depth claim crosses into the game domain.

### B. Interaction zones and contact meaning

1. Use **projected wrist-point entry into a disk on the player plane**, not a claim of physical 3D contact. For wrist `w`, center `c(t)` and explicit radius `r > 0`, inside means squared distance `|w - c(t)|² <= r²`; outside means `> r²`. Exact boundary counts as inside. No dwell, swept-path interpolation or invented wrist-volume radius in v1.
2. Jevon's domain owns target ID, eligible player set, disk/trajectory and active game-time interval. Kevin draws that same zone/trajectory through the reviewed mapping. The domain evaluates the position at **original capture game time**, never the renderer's current position.
3. Vault buttons are stationary disks during that vault, owned by the respective player; either anatomical wrist may activate them. Diamond eligibility is an explicit player set in the spawn description, constrained to each eligible player's validated comfortable reach. Collector/lane allocation still requires review; do not default every diamond to both players.
4. Edo/Jevon/Kevin must agree how valid reach is established. Theo reviews target size and player comprehension. Radius, placement, separation, path, speed and reach bounds remain explicit unresolved parameters; no existing standing-height calibration is assumed to prove comfortable lateral reach.
5. Reject configurations whose simultaneously eligible zones overlap or touch for the same player (`distance <= r1 + r2`) rather than inventing a nearest-target tie-break. Revalidate moving zones through their interaction intervals. Invalid/missing reach or ambiguous geometry blocks that plan; it does not become a missed pickup or player failure.
6. This candidate can miss fast movement between samples and can be sensitive to edge jitter. Evaluate those limitations with measured input before acceptance; do not add smoothing, hysteresis, dwell or larger targets silently to make tests pass.

### C. Fresh entry and exactly-once activation

Maintain a bounded contact state per active target, eligible player and wrist: **needs outside → armed → consumed**. Only retained product progress/terminal target state survives a pause; a pending entry does not.

- On target activation or resume, start at needs outside. Require a fresh, valid outside observation at/after target activation and strictly after the applicable resume/source cutover, followed by a strictly newer valid inside observation in the same accepted source/binding/calibration context. A first inside sample or a held wrist alone cannot activate it.
- Missing/weak/stale evidence or a continuity break clears that wrist's pending arm. An inside sample after invalid input needs another fresh outside → inside sequence. A gap beyond the explicitly reviewed contact freshness limit also breaks continuity.
- No extrapolated crossing between captures. A zone moving over a stationary wrist can satisfy entry only if the same target previously observed that wrist validly outside after activation. Review this behavior with Theo/Kevin; a newly spawned target under a held wrist does not collect itself.
- Vault deduplication key is `(vault ID, player ID, button ID)`; a committed button remains committed regardless of which wrist touched it. Diamond terminal key is its unique spawn ID, shared across hands and players. Replacements always get new IDs.
- A duplicate frame has no new effect and cannot arm/disarm a target. Conflicting data under the same source frame identity is rejected. Strictly older/out-of-order captures do not rewind contact state or create awards in this proposed v1; this differs from the laser's bounded-history selection and needs Edo's explicit agreement.
- Pause clears transient arms and freezes the existing GameClock/deadlines. Rebind, changed calibration, epoch/control cutover, Stop and Retry revoke in-flight evidence. Existing coordinator restart/termination gates retain authority; contact logic does not add a shortcut to resume an old context.

### D. Capture, arrival and deadline ordering

| Situation | Proposed v1 result |
|---|---|
| Ordinary eligible entry | Both observations belong to the active target/context and current clock segment. Capture is in the target's active interval; arrival is while that interval and session are still active and within an explicitly reviewed maximum contact age. |
| Capture before activation / passage entry | Does not arm or collect. A new target cannot reuse a previous target's evidence. |
| Exact target activation | May establish outside only; an award needs a later inside capture. No banked entry. |
| Vault deadline `d` | Retain existing timeout-wins behavior: capture and arrival must be **strictly before** `d`. At `d`, timeout closes first. No laser delivery allowance is copied. |
| Normal diamond passage `[entry, exit)` | Capture before entry or at/after exit cannot collect. Arrival at/after exit also cannot collect under this proposal, even if captured earlier. No award after the diamond has passed. |
| Diamond Time deadline | Capture and arrival must both precede phase end. At the deadline close collection/spawn/replacement first, then finalize once. |
| Pause / inactive app / current readiness loss | No contact commits. Old observations cannot queue an award for resume. This does not weaken the existing full live-readiness gates. |
| Buffered/out-of-order input | Ignore duplicates/older contact captures; evaluate fresh eligible captures once in delivered order. A dropped frame never proves an unobserved entry. |

This deliberately conservative admission policy gives no extra post-deadline grace. Edo must review measured delivery latency and feasibility before it is frozen. If grace/reordering is needed, specify the pending state, cutoff and displayed feedback in a revised proposal; do not change current timeout semantics implicitly. Parameter values remain open.

### E. Simultaneous hands, players and transitions

- Evaluate all eligible wrists in **one immutable capture** against the targets active at the start of that evaluation. Deduplicate the resulting contact set before applying effects. Both wrists on one button activate it once; two wrists on two distinct valid buttons may activate both.
- P1/P2 can complete their final vault buttons in the same capture. Apply the entire batch, then open the vault/advance progress once if both sides are complete before timeout. Non-simultaneous completion still works.
- Both players/hands on one diamond produce one terminal collection and one team reward. Attribution, if later required, may use a documented deterministic order (capture time, P1/P2, left/right) for diagnostics only; it cannot multiply rewards or change team eligibility. No personal diamond metric is introduced here.
- Collecting different diamonds in one capture can produce multiple awards, one per spawn ID. Commit terminal states before reserving replacement slots; active team count never exceeds four, including approaching diamonds.
- Apply phase transitions and spawn replacements **after** the batch. New phase/target IDs require new observations; the same capture cannot open the final vault and collect its newly spawned bonus diamonds. Replacement positions differ from the consumed target and other active diamonds.
- Normal diamonds finish passage before vault entry. Invalid/unfinished plans hold the transition for review rather than silently carrying a diamond into a vault. Whether unresolved evidence requires a revised plan is not grounds to manufacture a miss or award.

### F. Proposed synthetic acceptance table (not executable contact tests yet)

Fixtures will include explicit target IDs, geometry/config version, source envelope, capture/arrival game times, validity and expected event/score counts. Coordinates below are relational (`outside`, `inside`, `boundary`), not approved real-world dimensions.

| ID | Input sequence | Expected v1 result |
|---|---|---|
| C01 | Fresh outside → inside, same eligible wrist/context, before deadline | One activation/collection. |
| C02 | Fresh outside → exact disk boundary | One entry; boundary is inside. |
| C03 | First sample inside; further inside/held samples | No award; outside then inside is required. |
| C04 | Invalid wrist while other wrist has a valid entry | Invalid wrist contributes nothing; other wrist can qualify only if the session is otherwise running/ready. |
| C05 | Outside → missing/weak/stale → inside | No entry; pending arm cleared. |
| C06 | Duplicate entry; conflicting duplicate; older entry after newer data | No second effect; conflict rejected; older capture cannot rewind contact state. |
| C07 | Pre-activation outside/inside, or entry outside eligible player set | No arm or award for that target. |
| C08 | Outside → inside captured before deadline but arriving at/after deadline | Timeout/pass/phase closure wins; no late award. |
| C09 | Entry capture exactly at vault deadline, passage exit or phase end | No award; applicable terminal action once. |
| C10 | Same frame: both wrists on one button/diamond | Exactly one effect for that target. |
| C11 | Same frame: two distinct buttons; both players finish | Both eligible buttons commit; vault opens/progress advances once. |
| C12 | Same frame: both players collect one diamond | One team reward, one terminal ID, one replacement request if phase active. |
| C13 | Same frame: multiple diamonds collected with four active | Each unique collection once; replacement reservations preserve cap and distinct positions. |
| C14 | Pause/rebind/calibration/epoch/control change between outside and inside | Old pending arm revoked; follow existing restart gates and require fresh entry. |
| C15 | Stop/Retry and late old-generation evidence | No mutation in the new session; empty/new contact state. |
| C16 | Final vault opens; replacement/bonus target spawns under held wrist | No reuse of opening/collection capture; new target requires fresh outside → inside. |
| C17 | Missing optional attachment / older replay format | Existing laser behavior unchanged; contact capability unavailable. |
| C18 | Overlapping zones, invalid radius/reach or incompatible coordinate provenance | Reject plan/evidence; no guessed target, reward or player penalty. |
| C19 | Freshness gap exceeds reviewed limit, then inside | No entry until a new valid outside → inside sequence. |
| C20 | Normal approaching diamond outside interaction passage, then permanent pass | No early or post-pass award; miss never damages health. |

Edo's later approval explicitly permits J04/J05 synthetic domain fixtures using admitted membership now. These do not define Edo's wire/replay schema or imply live E08 validation; source-specific compatibility fixtures still wait for his exact surface.

## Sign-off ledger

| Decision | Producer / required review | Status |
|---|---|---|
| Evidence, source/context and delivery | Edo; Jevon, with Kevin for visible mapping | Architecture direction APPROVED; exact CP1 schema/compatibility still pending Edo |
| Capture/arrival/phase/deadline semantics | Edo + Jevon; Kevin/Theo for cues | D09 v1 behavior APPROVED; actual clock/mapping adapter and device measurements pending |
| Reach and interaction zones | Edo/Jevon/Kevin; Theo usability | Circular fresh-entry behavior APPROVED; parameters, coordinate mapping and feasible reach OPEN |
| Diamond points/population/refill | Jevon; Edo feasibility, Kevin/Theo presentation | Task-owner CONFIRMED: 25 points, initial four, persistent bonus targets; normal misses are permanent; physical/presentation review pending |

Record the actual choice, interface/fixture version, named approvers and verification implications here or link the team's authoritative decision. Do not close D09 from a planning table or an unrelated PR approval.

## Implementation boundary

The approved domain entry rules, vault batch commands, diamond passage/replacement/score accounting and combined round fixtures are now implemented. The live phase bridge still adds no detected wrist contacts: E08 admission, source-field freeze, coordinate/reach/trajectory review and presentation remain prerequisites to actual gameplay integration.

Next: consume Edo's frozen producer interface via the existing stream, complete J07 and the interactive full replay/live presentation with the reviewed plan, then validate complete-game outcomes/Retry on hardware. J04/J05 synthetic rule coverage and actual summary counts are verified; do not equate this with full-package or production acceptance.

No production live contact, placement/reach approval, physical readiness or complete-game UI delivery is claimed. The confirmed points/refill rules and synthetic domain accounting are implemented; do not weaken current collision/readiness gates to bypass the remaining integration dependencies.
