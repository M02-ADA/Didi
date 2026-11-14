# K06 normal diamonds and replay readiness — Kevin → Jevon handoff

Status: **Proposed** (10 November 2026). Kevin-owned rendering is implemented on `feat/laserheist-navigation` (combined into that branch and PR scope by the developer). Nothing in Domain, Session, diamond spawning, scoring or `GameClock` changed.

| Item | Implementation | Acceptance |
|---|---|---|
| K06 normal diamonds | **Implemented** (`NormalDiamondPresentation`, complete replay) | **Blocked — visual acceptance.** Normal diamonds spawn only **0.5 s before interaction** and sit **behind the mascots**, so none is visibly seen approaching. Needs the decisions in section 1. |
| Replay first-frame readiness | **Implemented** (`ReplayFrameClock`) | Simulator-traced; a device measurement of actual on-screen timing is still open. Hitch cap proposed, not implemented. |

**Decisions needed:** Jevon — the normal-diamond visual lead (section 1) and the hitch cap (section 2). Kevin + Theo + Edo — production diamond placement and reach (D09 review).

## 1. Normal diamonds (K06)

**Implemented (Kevin):** `NormalDiamondPresentation` draws each `LaserDiamondState` with lifetime `.passage` from `GameSessionCoordinator.diamondStates`, read-only, one entity per domain ID. It is placed like a laser gate: depth = interaction plane − travel speed × (crossing − game time), crossing = middle of `entry…exit`. Collected → the existing pop/sparkles and one pickup sound; missed → keeps travelling past the players, no feedback; closed or any non-activity phase → removed. Wired for the complete replay only (like the Diamond Time hook).

**Finding:** in the seeded plan every normal diamond spawns **0.5 s before entry** (e.g. spawn 11.70, entry 12.20, exit 13.20). A diamond only exists in `diamondStates` from its spawn, so it can first be drawn about **5 m** in front of the players, not down the corridor. With the plan's placements (lane centre ± 0.15, height 0.7–1.0) it is also directly behind that player's mascot for its whole approach. Simulator frames of the first minute show no visible diamond, although the presenter shows exactly the domain's collections (unit-tested on the seeded replay).

**Needed (Jevon), smallest change:** a visual lead for normal diamonds, either
- spawn them at least **4.2 s** before their crossing (the corridor's laser spawn depth, 22 m at 5.2 m/s), keeping `entry`/`exit` unchanged; or
- expose the planned upcoming normal spawns read-only (ID, position, eligible players, entry, exit), as laser encounters already are.

**Needed (Kevin + Theo + Edo, D09 review):** production placement and reach. Positions inside the mascot's silhouette can't be seen; reachable positions beside the body (wrist height) would be. The plan's numbers stay synthetic.

## 2. Replay first-visible-frame readiness

**Measured (Simulator, launch + 3 Retries, debug trace):**

| Step | Launch | Retry |
|---|---|---|
| Scene build starts → assets loaded and scene attached | 0.80 s | ≈ 2 ms (cached) |
| Attached → replay session started | 0.37 s | 25–32 ms |
| Session started → first `SceneEvents.Update` | 0.33 s | 54–66 ms |
| First update's `deltaTime` | 0.030 s | 0.003–0.010 s |

Replay time is the sum of `SceneEvents.Update.deltaTime`, subscribed only after the scene is loaded, attached and the session started, so no game time passes during loading. Each generation has its own presentation and subscription; a stale callback is rejected by session identity.

**Implemented (Kevin):** `ReplayFrameClock` — a generation's first rendered frame is replay time 0 (its delta, which can include a load stall, is not counted). Steady-state timing is unchanged.

**Limits:** a RealityKit update is the earliest frame signal available to `RealityView`; it shows RealityKit rendered, not that the frame was composited on screen. The earlier 4.2 s "unseen" Retry figure occurred only under XCTest's tap/query path and was not reproduced programmatically; a device measurement is still needed.

**Proposed (Jevon), not implemented:** cap a single frame's replay delta (for example at 0.1 s), so a presentation hitch mid-round can't skip game seconds. This changes the frame-update rule (TEAM_ALIGNMENT §C), so it needs agreement. Live rounds already wait for `attachLiveFrameHost` and its first update before countdown.
