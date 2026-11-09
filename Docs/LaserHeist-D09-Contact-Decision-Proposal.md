# D09 — wrist interaction decisions for vaults and diamonds

10 November 2026 · Jevon consumer handoff · **PROPOSED / OPEN — no owner sign-off recorded here**

## Finding and scope

No approved D09 decision or complete validated wrist-contact surface was found in the inspected sources. This is a scoped finding, not a claim about private conversations outside those sources.

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
- Diamond: wrist interaction during the declared passage through the interaction area; no fixed arbitrary lifetime and no reclaim after passage. All awards go to one team score.
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

### 3. Jevon product choices, still open

| Decision | Existing rule | Candidate for review — not selected |
|---|---|---|
| Points per accepted diamond | Team reward, exactly once per diamond | `25` is the existing candidate; keep configuration unset until a value is chosen. |
| Initial Diamond Time population | At most four active team diamonds, distinct positions | Start with four, or approve a smaller/scheduled initial population. |
| Missed-slot behavior | Collection-triggered replacement is confirmed | No automatic missed-slot refill, or an explicit separately specified refill schedule. Neither is assumed. |
| Normal diamond placement/passage | Confirmed total-team per-minute ranges; finish before vault entry | Seed/positions, separation, speed/passage windows and simultaneous/boundary rules need explicit selection. |

No candidate above is implemented or treated as collaborator approval by this document.

## Sign-off ledger

| Decision | Producer / required review | Status |
|---|---|---|
| Evidence, source/context and delivery | Edo; Jevon, with Kevin for visible mapping | OPEN |
| Capture/arrival/phase/deadline semantics | Edo + Jevon; Kevin/Theo for cues | OPEN |
| Reach and interaction zones | Edo/Jevon/Kevin; Theo usability | OPEN |
| Diamond points/population/refill | Jevon; Edo feasibility, Kevin/Theo presentation | OPEN |

Record the actual choice, interface/fixture version, named approvers and verification implications here or link the team's authoritative decision. Do not close D09 from a planning table or an unrelated PR approval.

## Implementation boundary

Already authorized consumer work can continue against existing contracts: laser/session/clock logic, safe Stop/Retry, and the existing vault phase/deadline lifecycle. The phase bridge adds no detected wrist contacts. These foundations do not close J04/J05/J07.

Once the relevant decisions are agreed: complete contact-driven vault and diamond domain fixtures (J04/J05), full replay phase integration (J06), then validated E08 evidence to J07 and actual final outcomes/counts/Retry (J08). Consumer implementation remains in scope; the missing prerequisite is affected-owner agreement on evidence, timing and product choices.

No production contact, points, spawn/miss policy, physical readiness or complete-game delivery is claimed. Do not weaken the current collision/readiness rules to bypass these dependencies.
