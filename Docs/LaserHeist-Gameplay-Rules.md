# LaserHeist gameplay rules and comfort limits

> **Status: Proposed — LH-01 review draft, 29 October 2026.**
> Owner: Jevon. Reviewers: Theo (player instructions), Edo (body-input feasibility), Kevin (screen communication).
> Product progression updated from Jevon's instructions on 29 October 2026, including 50 scheduled obstacle targets per player, per-player damage, vault behavior and automatic tracking recovery. **Confirmed — task owner** below records those instructions, not collaborator sign-off. Other policies remain **Proposed**; unresolved contracts remain **TBD**. Section G tracks outstanding decisions.

## A. Scope, sources and vocabulary

Follow [TEAM_ALIGNMENT.md](TEAM_ALIGNMENT.md), including its source precedence and contract workflow. The relevant [Architecture Reference](LaserHeist-Architecture-Reference.md) sections are “Session state versus game state”, “Scheduling versus judgement versus presentation” and “Confirmed judgement and geometry contracts”. Older drafts and prototype behavior are historical context, not rule authority.

**Confirmed by those references:** `GameClock` is the only game time; floor-relative Y points upward in game units; high clearance uses crown geometry; low clearance needs sole geometry AND airborne phase; missing/stale/invalid required data is UNAVAILABLE; Domain does not query rendering geometry. Production rendering is RealityKit.

**MVP scope:** two explicitly assigned players (parent and child), fixed individual lanes, shared health, high/low/split-lane encounters, random diamonds and a Dual Key Vault (the Co-op Gate). No lane switching, running or physical obstacle is required. Lane and role are separate from identity and never inferred from apparent height. The per-player obstacle grid is specified in A1. Virtual hand touches need Edo's contract review; actual physical-rep counting is outside MVP scope.

### A1. Progressive round — Confirmed by task owner

Each row's squat/jump target applies to **each player**, not the combined team. Diamond spawn counts, including the finale, are **total team counts**. **Latest task-owner clarification:** schedule 50 obstacle targets per player over the five activity minutes; fewer successful clears are allowed. There is no mandatory 50-success/physical-rep requirement, no catch-up extension and no failure solely for missing that count. Reaching the end with remaining health and all vaults opened determines success. This supersedes the earlier mandatory-completion wording.

| Activity progress | High / squat targets per player | Low / jump targets per player | Random diamond spawns | Obstacle targets / player |
|---|---:|---:|---:|---:|
| 0:00–1:00 | 5 | 3 | 2–4 | 8 |
| 1:00–2:00 | 6 | 3 | 4–6 | 9 |
| 2:00–3:00 | 6 | 4 | 6–8 | 10 |
| 3:00–4:00 | 7 | 4 | 8–10 | 11 |
| 4:00–5:00 | 8 | 4 | 10–12 | 12 |
| 5:00–5:10 Diamond Time | 0 | 0 | 15 | 0 |
| **Total / player** | **32** | **18** | **30–40 normal + 15 finale** | **50** |

- At each minute boundary (1:00, 2:00, 3:00, 4:00 and 5:00), enter a Dual Key Vault. Its opening opportunity lasts **5 seconds**; failure to open ends the round regardless of remaining health.
- Each side has **three virtual buttons**, located at the top, middle and bottom of its own side. Players may use either hand and activate them in any order; both sides must finish before timeout, without requiring simultaneous completion. Contact measurement details remain TBD in B4.
- The activity progress bar **stops during vaults**. The fifth vault must open before the final 10 seconds of Diamond Time. Normal activity progress totals 300 seconds, then 10 seconds of Diamond Time; elapsed session time may be longer because vaults, setup, countdowns and pauses are separate.
- Normal diamonds spawn randomly within each minute's count range. Every diamond is available for **2 seconds**. The final 10 seconds spawn **15 diamonds** for rapid collection; no additional squat/jump quota is added there.
- Shared health is **5**. Each player's HIT removes one health, so two HITs in one encounter remove two. Five health is a team damage budget, not five guaranteed failed encounters or five failures for each player. **Confirmed — task owner:** all points accumulate in one shared team score; each CLEAR laser target contributes 100, so two CLEAR players contribute 200 for one encounter. A CLEAR player still contributes 100 when the partner is HIT. Diamond value remains proposed in B3/G14.

**Confirmed — task owner:** high targets may be cleared by remaining crouched; a fresh squat is not required. Failed obstacles advance without an immediate retry or later catch-up for the miss. Schedule 32 high/squat and 18 low/jump targets per player. A split encounter supplies one target to each affected player, so target counts need not equal the number of shared encounters. Vault buttons/diamonds are additional interactions outside the 50-target grid. G13 still requires schedule validation, including tracking-recovery retries; never compress recovery spacing to catch up.

The Architecture Reference's high-clearance predicate remains crown-based. A held crouch can earn multiple target clears but cannot truthfully be displayed as multiple completed squat cycles. Actual-rep counting is outside this MVP's completion condition and metrics; no new squat-cycle contract is required for the selected rule.

| Term | Meaning |
|---|---|
| Target | One identified player's beam band, required move and crossing time within an encounter |
| Crossing | The instant the target's beam reaches that player's interaction plane in game time |
| PENDING | Required evidence/result is not finalized; no health or score consequence yet |
| CLEAR | Required evidence is available and satisfies the target rule at crossing |
| HIT | Required evidence is available and fails the target rule at crossing |
| UNAVAILABLE | Required evidence cannot support a verdict; never counted as CLEAR or a player mistake |
| Attempt | A particular presentation of a logical encounter; recovery may create a new attempt |

## B. Encounters, judgement and team consequences

### B1. Per-player judgement

**Proposed boundary rule:** let a player's beam occupy `[lowerEdge, upperEdge]`, with positive clearance margin `m`, all in that player's calibrated game space. High CLEAR requires `crownY + m < lowerEdge`. Low CLEAR requires valid airborne phase AND `min(leftSoleY, rightSoleY) > upperEdge + m`. Equality is HIT when required evidence is valid. An unknown jump phase or either missing sole makes a low target UNAVAILABLE; one raised foot cannot clear it. High targets do not need soles, a squat classifier, a fresh squat, or a knee angle. Remaining below a high beam can CLEAR it.

Tracking/identity and the measurements required by that target must be valid, fresh and associated with the expected player and calibration revision. Jump phase and soles must come from the same observation. Never combine unrelated frames, silently swap players, or bank an earlier clear pose for a later crossing.

**TBD — G2:** Edo and Jevon must agree capture-to-game-time mapping, evidence-selection algorithm, freshness limits, permitted tolerance and finalization deadline. The candidate window in B5 is for review, not an agreed evidence-selection algorithm. Evidence not yet final is PENDING; if no usable evidence exists by the agreed deadline it becomes UNAVAILABLE. No production crossing judge should ship until G2 is resolved.

### B2. MVP encounter table

All entries below are **Proposed**. Every attempt advertises its affected player IDs, move, beam geometry, warning and crossing time. Both players remain in their own lanes.

| Encounter | Who is affected | Required move | When judged | Consequence |
|---|---|---|---|---|
| High | Both players, independently scaled high bands | Lower the head comfortably below own band | Each target's declared crossing | Combine the two verdicts using B3 |
| Low | Both players, independently scaled low bands | Small two-foot jump over own band; valid airborne phase required | Each target's declared crossing | Combine the two verdicts using B3 |
| Split-lane | Both; one high target and one low target; assignments explicit in cue | High player lowers head; low player makes a small two-foot jump; no lane exchange | Each target's declared crossing; MVP script uses a common time | Combine the two verdicts using B3; only the low player consumes a required-jump slot |
| Dual Key Vault / Co-op Gate | Both; three virtual buttons on each player's side | Touch own top, middle and bottom buttons | During the 5-second vault opportunity; activation details in B4 | Open only when both sides complete; timeout ends round, independent of health |
| Diamond | Team-total spawn count; eligible collector/lane policy TBD | Touch/collect the virtual diamond; tracked body contact definition TBD | During its 2-second lifetime, ending before a vault | Award diamond points once on valid pickup; expiry gives no points and no health loss (proposed) |

The previous draft's simultaneous head-lowering Co-op Gate is superseded by the task owner's Dual Key Vault. B3 applies to laser encounters only; vault failure uses B4. Split assignments must satisfy each player's quota and comfort budget, never requiring the child to match adult clearance.

### B3. Complete damage and reward policy

**Confirmed — task owner:** start with **5 shared health**; each player's HIT costs one health, so HIT/HIT costs two. Each player's CLEAR contributes **100 to the same team score**, including when the partner is HIT; CLEAR/CLEAR contributes **200 for one encounter**. There is one authoritative team score in game state, displayed as one total in the HUD and results. Laser, jump-target and diamond awards all accumulate into that total; no separate parent/child score balances or individual leaderboard are required. Health is clamped at zero. **Proposed finalization:** apply both target results atomically once per encounter after evidence finalizes, preventing per-frame/repeated-callback damage. Provisional evidence does not immediately change health.

**Laser scoring confirmed by task owner:** a high CLEAR or low CLEAR contributes 100 to the team total; the low CLEAR includes its required jump as one award. A held crouch that validly clears a high target contributes the same 100. **Remaining scoring recommendations — Proposed:** 25 points per team diamond collected, no points for voluntary jumps outside a target, and no vault bonus, combo, score deduction or height bonus. Diamond value still awaits owner selection. These values prioritize the core laser task while making diamonds useful, with simple increments.

| Parent | Child | Shared health change | Team score change | Encounter result |
|---|---|---|---|---|
| CLEAR | CLEAR | 0 | +200 to team score | Both players contribute 100 |
| CLEAR | HIT | -1 | +100 to team score | Parent contributes; child takes damage |
| HIT | CLEAR | -1 | +100 to team score | Child contributes; parent takes damage |
| HIT | HIT | -2, clamped at zero health | 0 | Both take damage |
| CLEAR | UNAVAILABLE | 0 | 0 | Unscored attempt; recovery |
| HIT | UNAVAILABLE | 0 | 0 | Unscored attempt; recovery, including suppression of provisional hit |
| UNAVAILABLE | CLEAR | 0 | 0 | Unscored attempt; recovery |
| UNAVAILABLE | HIT | 0 | 0 | Unscored attempt; recovery, including suppression of provisional hit |
| UNAVAILABLE | UNAVAILABLE | 0 | 0 | Unscored attempt; recovery |

**Still Proposed:** UNAVAILABLE takes precedence for the whole laser attempt's effects, so available results paired with it remain unscored and undamaged pending recovery. The owner's partial-player reward decision above covers CLEAR/HIT, not technical UNAVAILABLE. UNAVAILABLE never becomes CLEAR. No practice mode is included. Laser awards and the shared score are confirmed; diamond value and optional reward exclusions remain proposed in G14.

Store effects against logical encounter identity and attempt identity so duplicate frames, callbacks, retry results and finalization cannot award or damage twice. A withdrawn attempt has no committed effects; an already committed encounter is never retried. Tracking failure cannot erase health already committed by earlier encounters.

### B4. Dual Key Vault and diamond interaction

**Confirmed — task owner:** five vault opportunities, one after each activity minute; 5 seconds to open; three buttons on each side at top/middle/bottom; failure to open is game over. Activity progress freezes while the vault opportunity runs.

**Confirmed — task owner (G11):** each player activates all three buttons on their own side in any order, using either hand. The vault opens when both sides are complete before timeout; simultaneous completion is not required. Repeated contact with an already activated button cannot add progress. Show each side's three states and one shared countdown. This is virtual tracked hand contact, not a presumed touchscreen tap. Edo/Theo/Kevin must agree the hand/wrist estimate, overlap/dwell, target size, reach calibration and deadline equality. Never infer hand contact from crown/sole data.

**Confirmed — task owner:** diamond spawn counts are total for the team, including the finale's 15; all normal diamonds must finish before vault entry so the vault screen is clear. **Proposed pickup rule (G12):** one pickup consumes a team diamond and awards team points once. Spawn IDs carry eligibility, spawn time and expiry; repeated frames cannot recollect them. Valid contact must precede expiry (exact boundary pending review); a miss causes no health damage. Which player may collect a given diamond and the body contact rule remain TBD. Do not infer a pickup from missing contact evidence.

Normal diamond counts/timings should be replayable from a recorded random seed, with positions inside calibrated comfortable reach. **Proposed boundary policy:** stop normal spawns no later than two activity seconds before each minute boundary so each receives its full lifetime and the vault starts clear. Stop finale spawns no later than second 8 of Diamond Time so all can expire by second 10. The finale cutoff was not explicitly decided by the owner; it remains a G12 recommendation. Fifteen finale spawns require overlapping diamonds to keep the full lifetime. Random distribution, simultaneous count cap, collector eligibility and precise boundary ordering remain TBD. No normal diamond carries into a vault.

Neither optional diamond collection nor mandatory vault buttons may require extra jumps, deep squats, lane crossing or adult-sized reach. Button/diamond reach calibration is not supplied by the minimum body-input contract and is an explicit integration gap (G1/G11/G12).

### B5. Warning, action cue and judgement window

**Proposed from task-owner input — to tune, G2/G16:** distinguish initial hazard preview from the action cue. Retain the candidate initial warning at least 3 active seconds before crossing; show the explicit jump/squat cue at `crossing - 1.4 seconds` (`cueLead`). For a crossing at 10.00, the action cue appears at 8.60. Both presentation times derive from the target's authoritative game-clock crossing time; cosmetic animation cannot move that crossing.

The cue announces the upcoming action; it does not prove that immediately jumping 1.4 seconds early will clear a later crossing. Theo/Kevin must make the expected contact moment clear with approach/countdown feedback. Validate comprehension and movement timing on device before adopting this value.

The candidate evidence window is `[crossing - 0.35 seconds, crossing + 0.25 seconds]`, based on capture timestamps mapped into game time, not callback arrival times. This is an envelope for designing evidence selection, not automatic acceptance of any clear pose anywhere inside it. The Architecture Reference still requires evidence supporting clearance at crossing and forbids banking an unrelated earlier clear. Selecting any qualifying sample as success would be a changed gameplay contract requiring explicit agreement in G2; this draft does not adopt it.

Positive look-ahead means the verdict may remain PENDING after crossing. An implementation using the full window cannot finalize before `crossing + 0.25`; it also needs an agreed bounded processing-arrival deadline, freshness policy and same-tick ordering. Never finalize HIT at crossing and later reverse committed damage because a delayed sample arrived. Minute/vault transitions must allow due verdicts to finalize consistently; neither the window nor callback latency silently consumes a vault's opening opportunity. Review this together with G13's full schedule. The 0.6-second lost timeout is not a substitute for judgement freshness.

## C. Round lifecycle and recovery

**Updated flow:** assignment → calibration → brief visual instructions → ready countdown → (activity minute → vault) × 5 → 10-second Diamond Time → terminal summary. **Confirmed — task owner:** no practice mode. Calibration and instructions are retained; they do not require completing unscored practice obstacles. Both calibrations and initial readiness are prerequisites. Countdowns do not consume activity progress.

- Complete all five vaults and the final Diamond Time with positive health to win. The five-minute activity schedule provides 50 target obstacles per player; successful clears may be fewer. Do not add catch-up targets or an extension for HIT results and do not fail solely for an unmet success/rep count. Tracking pauses/recovery still follow their own rules. A vault timeout ends as **vault failed**, even at full health. No laser/activity target is scheduled inside a vault or Diamond Time.
- Health reaching zero ends as **health depleted** immediately after atomic resolution. Resolve due laser effects before entering a vault or declaring completion; do not invent success from unresolved/unavailable evidence. Exact same-tick ordering of deadline/contact/end events requires G2/G11/G12 agreement.
- `GameClock` remains the only gameplay time source. **Proposed phase timing:** it advances during activity, vault and Diamond Time and freezes on pause; activity progress accumulates only activity/Diamond Time deltas and remains fixed during vaults. A vault deadline is a phase deadline derived from the same clock, not a separate rendering timer. These are distinct values, not two independently advancing game clocks.
- The progress bar represents 310 seconds of activity progression, with checkpoints at the five vaults. The vault's 5-second countdown must be visible separately while the bar is stopped. Pauses and vault duration make wall-clock time longer than 5:10. Do not shorten a later minute to compensate for time spent in a vault.
- Player Stop/Exit ends as **aborted**, not defeated or completed; discard unresolved attempts. An unrecoverable input/service failure ends as **technical interruption**, without player blame. Manual pause and app interruption freeze gameplay.
- End once, cancel pending encounters and emit one immutable summary. No score/health changes occur after termination. Summary includes outcome, active duration, health, score, finalized encounter counts and unavailable/withdrawn counts, with metric limitations from E.

**Tracking loss / unavailable evidence:** pause the whole team when either assigned player loses reliable tracking/identity, required input becomes unusable, or the camera/service is interrupted. Withdraw unresolved attempts without damage or reward. Freeze `GameClock`, encounter progression and scoring; show “Tracking paused — stand comfortably in your own space.” Do not tell a player to keep holding a crouch or jump during pause.

**Confirmed — task owner:** tracking recovery automatically starts a visible 3..2..1 countdown once both players are reliably tracked/settled, assignments/calibrations are valid and all other pause blockers clear; no Resume button is required for tracking-only recovery. One good frame alone is insufficient. Recalibrate if identity/calibration cannot be trusted. An outstanding manual pause or inactive-app blocker still prevents automatic continuation; tracking recovery cannot clear it.

After recovery, retry each withdrawn laser encounter with a fresh attempt, a full warning and revalidated comfort budgets; keep already committed totals. A retry consumes another physical jump-demand slot even if the earlier attempt was unscored. Defer low targets that cannot fit the budget; never compress pending quotas into the remaining minute. Reset jump evidence across pause. Repeated recovery failures leave the session paused with Retry Setup or Exit; threshold TBD in G3.

**Confirmed — task owner:** an interrupted vault continues with its remaining time and completed buttons after recovery/countdown, rather than restarting the five-second opportunity. **Proposed timing mechanics:** tracking/app/manual interruption freeze vault deadlines and diamond lifetimes with `GameClock`; tracking failure is not a player timeout. Retain committed activations/pickups, discard in-flight contact evidence and never respawn collected diamonds.

### C1. Tracking grace, settling and countdown

**Proposed from task-owner input — to tune, G15:** `lostTimeout = 0.6 seconds` per player, measured with a monotonic input/service clock since the last reliable captured pose, not the paused game clock or a count of missed frames. A missing player initially becomes uncertain; after 0.6 seconds without reliable evidence, mark that player lost. A watchdog must still detect loss if camera callbacks stop. Camera interruption or ambiguous identity can invalidate input immediately without waiting for this timer.

The grace interval preserves identity/visual continuity; it does not make old geometry valid. Keep the existing immediate gameplay pause when required evidence becomes unusable (including during the grace interval), withdraw unresolved laser attempts without damage, and prevent clearance/pickup/button awards from invalid evidence. Missing a required point affects rules that depend on it: a missing wrist does not by itself invalidate otherwise reliable crown clearance, but it cannot activate a button. Edo defines the precise validity states and freshness thresholds in G1/G2/G15. Kevin decides how briefly retained cutouts communicate uncertainty; a retained image is never gameplay evidence.

After reacquisition, require `settleDuration = 0.4 seconds` of continuously reliable, correctly assigned input for **both** players before readiness. New invalid evidence restarts settling. Warm/reset smoothing and movement history during this interval, with no button, diamond or laser-clear awards. A recovered low posture is not a newly completed squat; a recovered airborne-looking pose cannot by itself validate a new jump phase. Actual physical rep counting is not an MVP metric. After recovery, a held crouch may still validly clear a high target at its new crossing.

Settling does **not** overwrite standing calibration or derive a new standing height from a crouch. Reuse the validated revision when trustworthy; otherwise return to standing calibration. After settling and all other blockers clear, tracking-only recovery **automatically** starts the **3..2..1** countdown, as confirmed by the owner. Settling/countdown consume no activity progress, vault time or diamond lifetime. Loss during countdown cancels readiness and returns to recovery. Manual pause still requires a manual resume intent before continuation.

## D. Comfort envelope and first-round experience

### D1. Per-player limits

**Proposed for review, not validated safety thresholds.** Standing calibration supplies a baseline, not a measurement of jump ability, physical reach, floor friction, pain or fatigue. These numbers are conservative design candidates marked **to tune**, not evidence that an activity is safe for any individual. Required jumps remain disabled for live play until G4 review and device/playtest validation; replay can exercise proposed low/split rules.

For each player `p`, define `H[p]` as standing crown height above that player's calibrated floor. This is a proposed interpretation of calibration data, pending Edo confirmation (G1); it does not add a Swift field or redefine his contract. Express beam heights, thickness and margins as fractions of that player's own `H[p]`. Never reuse an adult's absolute band for a child or substitute the team's average height.

- High target: required crown drop `D = H - (lowerEdge - m)` must be positive and no more than `0.10H`. Candidate `D = 0.08H`, `m = 0.01H`; therefore candidate lower edge is `0.93H`. Strict boundary clearance still needs a little extra movement; schedule below the maximum drop, not at it.
- Low target: required sole lift `L = upperEdge + m` must be positive and no more than `0.04H`. Candidate upper edge `0.01H` and margin `0.01H` give `L = 0.02H`, leaving headroom below the maximum. Do not encourage a higher jump for more points.
- A candidate band thickness is `0.01H`. Its entire band and required clearance must satisfy the envelope. If geometry, confidence or a user's comfort choice cannot support it, do not spawn that target. Do not reduce measurement margins merely to force a target to fit.
- The adult confirms both players are comfortable with the instructed movements before play; either player can pause or stop. If small jumps are not comfortable, do not start a round that requires low/split jumps. A non-jumping mode is outside this MVP and remains a product question in G4. **Confirmed — task owner:** the intended audience is young children with a parent; do not advertise a specific numerical supported age range without validation. Omitting a public age number does not establish suitability; G4 still needs participant/suitability criteria for playtesting. No practice mode is included.

### D2. Jump demand budget

**Proposed, to tune:** per player, at most 3 required jump crossings in any rolling 30 seconds, at least 8 seconds between required jump crossings, and at most 1 consecutive jump encounter (insert a high encounter or breather before another). A vault supplies no scheduled jump demand and does not prove recovery movement occurred. No overlapping required actions for the same player. Include tracking-recovery retries in demand accounting; HIT obstacles are not retried. A1 requires 3/3/4/4/4 jump targets per player by activity minute; G13 must validate that full schedule. No extra targets are added for missed clears. Quotas do not override comfort limits.

Game-time limits alone do not cover a pause: preserve a separate session demand history for comfort checks, using monotonic elapsed real time, without advancing gameplay. Enforce both active-time spacing and real-time recovery spacing. On recovery allow at least 8 real seconds from the start of the recovery countdown to any required jump crossing. This proposal needs owner agreement (G5); it does not introduce a second gameplay clock. Voluntary extra jumps are not controlled or reliably counted by this budget.

Difficulty may choose patterns within these limits; it must never increase clearance or jump frequency past a player's caps. If there is no eligible pattern, schedule a breather, never bypass a limit.

### D3. Play space and first round

**Proposed space check:** each player has a separate marked area with room for a small jump and head-lowering movement without touching the other player, device, furniture, overhead objects or other obstacles. Use a clear, stable, non-slip floor; secure the iPad outside movement areas; keep both full bodies visible. No forward travel or real obstacle is required. Camera visibility alone cannot certify space suitability. Minimum lane dimensions, device distance, lighting and young-child suitability criteria remain TBD in G4/G6; do not invent meters from game units.

**Proposed player-facing copy for Theo review:**

1. “Make room together. Stay in your own marked space. You can pause or stop at any time.”
2. “Stand comfortably so we can set each player's height.” Show each player's readiness separately.
3. “High laser: lower your head a little. You can stay down while it passes.” Show a visual example without requiring a practice action.
4. “Low laser: make a small jump with both feet.” Show a visual example; no reward for height and no practice obstacle.
5. “Split laser: follow the symbol in your own lane.” Explain head-down/jump symbols with labels, not color alone.
6. “Each minute, open the vault together. Touch all three buttons on your side with either hand, in any order, before five seconds run out.” Show top/middle/bottom and both-side completion visually, without a practice phase.
7. “Collect diamonds before they disappear — each lasts two seconds. The final ten seconds are Diamond Time!” Show collection visually without implying extra jumps are required.
8. “You share five health. Jumps, dodging lasers and collecting diamonds earn points.” Explain that vault timeout ends the round even if health remains.
9. “Ready together?” Both acknowledge; show a 3-second countdown, then begin scored play with a high encounter and a full warning.

There is no practice mode or mandatory physical demonstration. Theo reviews brief instructions, comprehension and automatic recovery countdown; Kevin confirms moves, warnings, paused states and results are clear on screen with muted audio. Asset/HUD implementation stays with their owners.

## E. Activity metrics and limitations

No raw body recordings are required. MVP activity metrics count scheduled obstacle targets and clearance outcomes, not physical repetitions. Virtual hand contact needs the contract review in G1/G11/G12; minimum crown/sole data cannot establish it.

| Metric | Definition | Stated limitation |
|---|---|---|
| Activity progress duration | Accumulated activity and Diamond Time deltas from `GameClock` | 310-second base grid; excludes vault/pause; no HIT catch-up extension; not exercise intensity |
| Vault duration | Game-clock time spent in each vault opportunity | Separate from activity progress; pause excluded |
| Team score | One authoritative sum of both players' committed laser contributions and team diamond awards | One combined HUD/results total; individual target outcomes are not separate score balances |
| Team clear rate | CLEAR/CLEAR committed encounters ÷ all committed encounters | Excludes withdrawn/unavailable attempts; show unavailable count; no denominator displays “—”, not 100% |
| Per-player target clears | Available CLEAR targets in committed scored encounters, by player | A high CLEAR may be a held posture; not squat reps. Available targets inside a withdrawn encounter do not count |
| Jump targets cleared | Committed low targets with valid airborne phase and both soles clearing | Counts successful game targets, not all jumps or unique jump cycles; no validated takeoff/landing event IDs yet |
| Unavailable attempts | Withdrawn attempts with at least one UNAVAILABLE target | Tracking quality indicator, not player performance; repeated attempts remain visible |
| Required jump demands | Scheduled jump attempts actually cued to each player, including tracking-recovery retry/withdrawal | Used for comfort budgeting; not proof that the player jumped |
| Scheduled squat/jump targets | Per-player demands against the five-minute grid (32 squat, 18 jump) | Not measured completed repetitions; vault/diamond actions excluded |
| Diamonds collected | Unique valid pickups committed once under G12 ownership policy | Not all spawned diamonds are necessarily collected; no fitness measure |
| Vaults opened | Number of vault opportunities with both sides complete (0–5) | Not evidence of squat/jump repetitions |

Reserve jump demand slots before scheduling, and retain a demand once its warning is shown even if withdrawn before crossing. An uncued cancelled future demand can release its reservation. Retaining cued withdrawals is deliberately conservative. E's displayed demands can therefore exceed actual jumps and finalized low targets.

Do not report target clears as actual squat/jump repetitions. Any future physical-rep metric requires separate agreement and validated movement-cycle evidence. Do not infer calories, heart rate, jump height in centimeters, clinical exercise quality or fitness/safety ratings from these game metrics.

## F. Tuning table and review scenarios

Task-owner product values are labeled **Confirmed — task owner**. Other numbers remain **Proposed — to tune**. A stricter individual comfort choice wins; no quota may bypass the comfort envelope.

| Parameter | Candidate | Constraint / review |
|---|---|---|
| Shared health | **5 — Confirmed, task owner** | -1 per HIT player, -2 for HIT/HIT; clamp at zero; vault timeout separately terminal |
| Activity progression | **300 + 10 seconds — Confirmed, task owner** | Progress stops during five vault opportunities and pauses |
| Obstacle grid / player | **32 high/squat + 18 low/jump — Confirmed, task owner** | 50 scheduled targets; successful count may be lower; no catch-up extension |
| Vault opportunity | **5 seconds, five vaults — Confirmed, task owner** | Three buttons per side; timeout ends round |
| Diamond lifetime | **2 seconds — Confirmed, task owner** | Pickup/expiry boundary and contact evidence TBD |
| Normal diamond spawns | **2–4 / 4–6 / 6–8 / 8–10 / 10–12 — Confirmed, task owner** | Total team; random per minute; all expire before vault |
| Diamond Time | **15 team spawns / final 10 seconds — Confirmed, task owner** | Concurrent placement TBD; candidate last spawn at finale second 8 |
| Laser / jump target points | **100 per CLEAR player — Confirmed, task owner** | One shared team total; +200 for CLEAR/CLEAR; +100 for CLEAR/HIT or HIT/CLEAR |
| Diamond points | Candidate **25 per team pickup** | Once per diamond; G14 |
| Practice mode | **None — Confirmed, task owner** | Retain calibration, short visual instructions and ready countdown |
| Warning lead | At least 3 active seconds | Full warning on every attempt; Kevin/Theo validate readability |
| Ready/resume countdown | 3 real seconds | Game time remains frozen; jump recovery can require a longer breather |
| Any consecutive target crossings | At least 5 active seconds | Same player; no overlapping required actions |
| High crown drop | Candidate 0.08H; cap 0.10H | Per player's calibration; strict clearance below cap |
| Low sole lift threshold | Candidate 0.02H; cap 0.04H | Includes margin; live jumps disabled pending G4 |
| Beam thickness / margin | 0.01H / 0.01H | Per player; validate noise before acceptance |
| Required jumps / rolling window | Maximum 3 / 30 seconds | Per player; tracking retries included; active and real-time constraints |
| Required jump spacing | At least 8 seconds | Active-time crossing gap and real-time recovery; G5 |
| Maximum consecutive jump encounters | 1 | High or breather between jumps |
| Action cue lead | Candidate **1.4 active seconds** | Separate from initial 3-second preview; to tune, G16 |
| Judgement evidence window | Candidate **-0.35 / +0.25 active seconds** relative to crossing | Selection/freshness/arrival deadline still TBD; no any-clear banking; G2 |
| Lost status timeout | Candidate **0.6 monotonic seconds** | Identity grace only; never permits stale evidence; G15 |
| Reacquisition settling | Candidate **0.4 continuous reliable seconds** | Both players, no awards, no automatic standing recalibration; G15 |
| Stable recovery / retry threshold | Settling candidate above; retry threshold TBD | Automatic 3-second countdown after tracking recovery; other blockers still apply; G3/G15 |
| Physical space / camera distance | TBD; no inferred meters | G6; manual space check still required |

### F1. Capture backpressure and adaptive pose processing

**Proposed engineering handoff — G15, Edo owns implementation:** explicitly set `AVCaptureVideoDataOutput.alwaysDiscardsLateVideoFrames = true` for live gameplay. Apple's [TN2445](https://developer.apple.com/library/archive/technotes/tn2445/_index.html) describes a one-frame queue at the output and recommends this setting for processing live video. It limits capture-output backlog; it does not cancel a running Vision request or bound an asynchronous application queue. The user's Frame 1/Frame 4 example illustrates latest-frame preference, not a guarantee about exact delivered frame numbers.

Use bounded latest-frame delivery into Vision as well: at most one pose operation in flight and at most one pending latest frame (replace obsolete pending work). No task per arriving frame with an unbounded queue. Preserve capture timestamp, frame ID, player ID and calibration revision through processing; reject stale/old-session results regardless of configured FPS. Expensive processing stays off the main actor, with image-resource ownership and cancellation handled by Edo. These are implementation proposals, not new Swift contract declarations in this document.

The following rates are **candidate pose-detection request rates**, not camera capture FPS, rendering FPS, cutout/segmentation FPS or guaranteed throughput. Keep those budgets separate and measure them together on a physical iPad. Changing the camera's capture rate, if needed, is a separate producer-owned decision using supported device formats; do not equate skipping pose requests with throttling capture.

| Game/input state | Candidate pose rate | Purpose / qualification |
|---|---|---|
| Setup / calibration | 15–30 FPS | Find both players, validate standing calibration and identity |
| Normal, no interaction | 5–10 FPS | Presence and tracking continuity; retain validated standing calibration |
| Laser warning | 10–15 FPS | Prepare stable input before the action |
| Within 1–1.5 seconds before/after crossing | 20–30 FPS | Responsive coherent crown/sole/jump evidence; exact boost interval to tune |
| Recovery after resolved laser | 5–10 FPS | Confirm stable return when no other sensitive interaction is active |
| Before a diamond spawn | 10–15 FPS | Prepare wrist/hand input, subject to agreed contact contract |
| Diamond active / floating | 20–30 FPS | Track pickup contact during its 2-second lifetime |
| After diamond collection / expiry | 5–10 FPS | Only when no other active target needs a higher rate |
| Vault idle, no active body target | About 5 FPS | Presence only; does not apply to active button touches |
| Before vault target activation | 10–15 FPS | Prepare wrist/hand input |
| Vault button targets active | 20–30 FPS | Responsive contact detection during the 5-second opportunity |
| All vault targets completed | 5–10 FPS | Only if no subsequent interaction needs a higher rate |

The vault's top/middle/bottom layout and free activation order remain the product rule. This rate table does not introduce random/sequential activation. "Idle vault" must never select 5 FPS while mandatory buttons are active. During Diamond Time, request the active-diamond profile while any target is available; do not drop to idle merely because one diamond was collected.

**Proposed arbitration:** the coordinator supplies upcoming/active interaction needs from the game schedule; Edo chooses the achievable processing profile, taking the highest overlapping requirement across both players, lasers, diamonds, vaults and tracking recovery. Prime ahead of scheduled interaction, apply rate-change hysteresis to avoid rapid oscillation, and keep recovery sampling sufficient to establish continuous settling. Exact lead/hysteresis durations and interface are TBD. Do not slow rendering or advance game time from the sampling scheduler.

These rates target compute/energy headroom; reduced battery use, thermal load or frame drops are hypotheses to measure, not guaranteed outcomes. Log requested/achieved pose rate, request duration, capture-to-result age, dropped-frame reasons, tracking availability, thermal state and visible cutout alignment without retaining participant images/pose recordings. Under sustained overload, reduce optional visual/segmentation work only through owner agreement or pause/degrade the supported mode; never silently widen judgement windows, reuse stale evidence or award a hit/clear from missing samples.

Review examples for later deterministic fixtures (not executable tests in LH-01):

- B3's nine combinations, HIT/HIT removes two health, CLEAR player scores alongside HIT partner, UNAVAILABLE suppression, duplicate callbacks, no double effects after tracking retry, and health clamping from one to zero.
- Crown/sole equality is HIT; missing required landmark/phase is UNAVAILABLE; one raised foot and grounded phase fail low clearance; high does not require a jump/squat detector.
- A child's bands derive only from the child's baseline; mismatched calibration revision withdraws the attempt. The same percentage yields different absolute bands for different baselines.
- Split targets retain independent geometry and declared crossing times; Dual Key Vault needs both sides' three buttons completed within its opportunity, rather than two laser CLEAR verdicts.
- Verify each player's grid totals 32 high/squat and 18 low/jump targets; do not combine the two players into 50 team targets. Held crouches can CLEAR multiple high targets. Fewer successful clears do not cause catch-up, extension or failure if health remains and all vaults open.
- Vault at each 60-second activity boundary, fifth vault before Diamond Time, stopped activity progress but advancing vault deadline, timeout at full health, and both-side button completion/deduplication.
- Seeded total-team diamond ranges, 2-second lifetimes, collector eligibility and duplicate contacts, overlapping finale pickups, clean screen before vault, and pause/resume do not double-award.
- Rolling-window boundaries, jump-spacing boundaries and tracking retry/resume demands cannot bypass caps; no eligible encounter yields a breather.
- Free-order vault buttons accept either hand, both sides need completion but not simultaneously; interrupted vault retains completed buttons/remaining time; tracking-only recovery automatically starts countdown and never clears a manual pause.
- Pause freezes active time; recovery cannot score pre-pause evidence; overlapping interruption blockers prevent resume; round end is emitted once, including simultaneous zero-health/time-expiry.
- At 0.59/0.60 seconds without reliable input, distinguish uncertain/lost status from unusable judgement evidence; no stale CLEAR during grace, and a stopped camera callback stream still triggers recovery.
- Reacquisition while crouched does not count a squat or change standing height; 0.39/0.40-second settling boundaries, new invalid input, and loss during countdown all preserve pause/award rules.
- Cue at crossing minus 1.4; evidence just inside/outside -0.35/+0.25; late arrival after finalization; no early-clear banking or premature damage; pending judgement cannot steal vault time.
- A deliberately slow Vision consumer has bounded in-flight/pending work and processes latest available input; dropped frames cannot cause repeated movement or pickup awards.
- Overlapping laser/diamond/two-player needs select the highest required pose profile; active vault buttons never use idle 5 FPS; measure achieved rates/latency/thermal behavior over the full 5-minute-plus session on device.

## G. Open decisions and reviewer agreement

No collaborator confirmation has been obtained in this document. Resolving an item requires the affected owner's actual review; do not infer agreement from this draft or mark LH-01 complete merely because it exists.

| ID | Open item / required confirmation | Responsible reviewers | Status |
|---|---|---|---|
| G1 | Confirm existing clearance inputs/standing baseline and extensions for hand contact/comfortable reach. Actual-rep cycles are no longer required for MVP completion/metrics; crown/sole/jump-phase data alone cannot establish hand touches; exact types remain Edo-owned | Edo + Jevon | **TBD — Edo confirmation pending (AC4); hand interactions need contract review** |
| G2 | Evidence selection, capture/game mapping, freshness, tolerance, finalization deadline, equality/margin policy and stable recovery criterion | Edo + Jevon; Kevin for feedback alignment | **TBD** |
| G3 | Per-HIT damage (-1 each, -2 both) and CLEAR-player rewards alongside a HIT partner are task-owner confirmed. Review UNAVAILABLE suppression, tracking retry/withdrawal, terminal ordering and repeated-recovery threshold | Jevon + Theo + Edo + Kevin | **Partly confirmed by task owner; technical policies Proposed/TBD** |
| G4 | Validate clearance caps, jump budget, young-child suitability/participant criteria and comfort readiness. No numerical supported-age claim or practice mode; non-jumping mode remains outside MVP | Jevon + Theo + Edo; Kevin for cues | **Audience/no-practice direction confirmed by task owner; limits/suitability validation TBD** |
| G5 | Agree active/real-time comfort-demand history, reservation accounting, warning/countdown/crossing spacing and scheduler handoff to LH-15 | Jevon + Edo + Kevin | **Proposed** |
| G6 | Establish physical space dimensions, camera placement/distance, visibility/lighting and device acceptance checks; game units cannot supply meters | Edo + Theo + Kevin | **TBD** |
| G7 | Review brief visual instructions without practice, stop/manual-pause usability, automatic tracking-recovery countdown and non-blaming results | Theo + Jevon | **No practice/automatic tracking countdown confirmed by task owner; copy review pending** |
| G8 | Confirm high/low/split/gate cues, per-player bands/contributions, warnings, shared health and UNAVAILABLE feedback are clear on screen | Kevin + Theo | **Proposed — Kevin confirmation pending** |
| G9 | Approve activity definitions, exclusions, unavailable display and numeric tuning table | Jevon + Theo; Edo for observable facts | **Proposed** |
| G10 | 50 scheduled obstacle targets/player (32 high, 18 low); held crouch allowed; actual physical-rep counting not required; HIT advances, success count may be lower, no catch-up extension | Jevon; Edo/Theo acknowledge metric meaning | **Resolved by task-owner clarification; no actual-rep contract required for MVP** |
| G11 | Free-order buttons, either hand, both sides finish before timeout, progress freeze and interrupted vault continuing remaining time/buttons are confirmed. Agree hand/wrist estimate, reach, overlap/dwell, deadline boundary and phase integration | Jevon + Edo + Theo + Kevin | **Gameplay confirmed by task owner; contact contract/measurement TBD** |
| G12 | Total-team counts and clean screen before vault confirmed. Agree collector eligibility/contact, seeded distribution, placement/concurrency and finale cutoff. Candidate last spawn two seconds before phase end | Jevon + Edo + Theo + Kevin | **Partly confirmed; remaining interaction details TBD; finale cutoff Proposed** |
| G13 | Validate 50-target/player five-minute grid against spacing, warnings, recovery and vaults; no retries/catch-up for HIT, no success-count failure or extension. Decide tracking-withdrawal retry accounting at minute boundaries | Jevon + Edo + Theo + Kevin | **Success rule resolved by task owner; schedule feasibility/tracking retry boundaries TBD** |
| G14 | One combined team score and 100 per CLEAR laser target confirmed (+200 for both CLEAR, +100 for one CLEAR alongside HIT). Candidate diamond value 25 and no optional bonus remain for selection; Kevin consumes the same score total in HUD/results | Jevon + Theo; Kevin for display | **Laser values/team score confirmed by task owner; diamond value and bonus exclusions Proposed** |
| G15 | Agree capture backpressure, bounded Vision work, 0.6-second lost status, 0.4-second settling, invalid-evidence pause, watchdog, profile interface/device acceptance; tracking recovery automatically counts down once settled and other blockers clear | Edo + Jevon; Kevin for display/load | **Automatic tracking countdown confirmed by task owner; technical implementation Proposed/TBD** |
| G16 | Validate 1.4-second action cue versus initial preview, crossing feedback and countdown comprehension; coordinate profile boost with the authoritative timeline | Jevon + Theo + Kevin; Edo for latency | **Proposed — to tune; evidence window remains G2** |

### Acceptance and integration handoff

| LH-01 criterion | Draft coverage | Remaining work |
|---|---|---|
| AC1: affected players, move, judgement time, consequence | B1–B3 | Reviewer agreement, especially G2/G8 |
| AC2: all parent/child CLEAR/HIT combinations and UNAVAILABLE | B3, all nine combinations | G3 agreement |
| AC3: comfort relative to each calibration | D1–D2 and F | G1/G4/G5 validation; numbers remain to tune |
| AC4: Edo confirms feasibility; open items in G | G1–G16 | **Not met yet: actual Edo confirmation required, especially hand-contact evidence and processing/timing policies** |

LH-02/04/05/06 can review this proposal for cues/assets/animation/audio, but should not treat pending rules as approved. LH-00 must reconcile G1/G2 before defining shared interfaces. LH-07 should turn F's cases into deterministic synthetic scenarios after agreement. LH-15 must enforce the approved per-player envelopes and demand budget; LH-16/17 consume approved team/round policies. No other owner's file or shared type is changed by this proposal.

G15's capture/tracking/pose scheduler belongs to Edo's `CameraPipeline`, `BodyInputService` and Motion implementation. Jevon owns pause/resume, encounter/cue timing, judgement selection and supplying interaction demand; Kevin owns visible cues/cutouts and rendering load. Agree the handoff before editing shared types or another owner's code, per TEAM_ALIGNMENT §E. No Swift implementation is claimed by this LH-01 document update.
