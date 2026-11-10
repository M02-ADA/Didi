# LaserHeist — Integration Test Checklist

**Owner:** Kevin (rendering and presentation). **Status:** Proposed for the next integration session.

Simulator results use synthetic or replay data. They say nothing about real-camera accuracy, latency, frame rate or thermals.

## 1. Verifiable in Simulator today

Launch arguments are Debug-only unless noted.

| Check | How | Expected | Failure signal |
|---|---|---|---|
| Replay with mascots | Debug, no arguments | Lemon left, Tangerine right, rear-facing, equal size, on the board | White figure in Debug; two bodies in one lane; floating or sunken feet |
| Release fallback | Release, no arguments | White pictograms, no mascots, no Debug HUD items | Mascots frozen in Release; `Camera diagnostics` visible |
| Laser sequence | Replay | Gate approaches, warns, arms; DUCK/JUMP cue; gate powers down at the verdict | Cue during the vault; gate still armed after its verdict |
| Verdict feedback | Replay | One CLEAR/HIT badge per player, above the head; spark only on HIT | Badge inside the head; repeated badge |
| Vault | Replay | Corridor stops, door and countdown, indicators turn green, door opens, travel resumes | Corridor moves while stopped at the vault; door remains after the round |
| Diamond Time | `-diamondFixture` | Title, timer, `FIXTURE` tag, diamonds appear and are collected | Fixture tag or diamonds in Release |
| Packet-driven mascots | `-robotDemo <key> -avatarPackets`, keys `p2-duck`, `arms`, `step-right`, `both-jump` | Each mascot moves independently; no root lift on jumps (no airborne evidence yet) | One mascot follows the other; a mascot lifts off without evidence |
| Tracking loss | `-robotDemo tracking-loss -avatarPackets` | The lost player dims and relaxes, then recovers; the other is unaffected | Frozen pose at full opacity; snap on recovery |
| Cutouts | `-syntheticCutouts <scenario>` | Cutouts replace pictograms with matching frame IDs | Halo around padding; wrong player's image |
| End round and Retry | Tap in the running app, or run `RoundSmokeUITests` | Results, then a new round at full health and zero score | Old badges, lasers or mascots after Retry |
| Pause | Tap in the running app | Pause is greyed out and does nothing | Pause opens a menu the session can't honour |

Automated: `RoundLifecycleTests`, `LiveAvatarPresenterTests`, `LiveCutoutTests`, `AvatarFairnessTests`, `AuthoredSceneConsistencyTests`, and the `RoundSmokeUITests` launch, End round and Retry tap path.

## 2. Requires Edo's E07 feed

**Status: Proposed.** The Kevin-owned consumer is in place: `PlayView.avatarSource` returns an `AvatarPosePump`, which the render tick runs before it refreshes the avatars. These steps connect Edo's producer and need the named owners' agreement. Nothing here is a D06 field freeze.

1. **Git (developer):** merge `origin/feat/vision-live-pipeline`. It merges cleanly with this branch.
2. **Edo (App-owned files):** apply [E07-K03-Live-Binding.patch](E07-K03-Live-Binding.patch). It adds `VisionK03PacketFactory`, `VisionK03MailboxPump` and `VisionK03IntegrationTests`. The pump differs from Edo's draft in two ways: it conforms to `AvatarPosePump`, and a refused packet no longer ends the feed.
3. **Edo (`VisionNumericPoseChannel`):** fix the stall in section 2a, then remove `withKnownIssue` from `aCameraStallDoesNotEndDeliveryForTheRestOfTheSession`.
4. **Edo + Jevon (start order):** see section 2b.
5. **Edo (`RootView`), only once a live session exists:**
   ```swift
   PlayView(avatarSource: { try VisionK03MailboxPump(bridge: AppDependencies.shared.visionPoseBridge, mailbox: $0) })
   ```
   Don't add this for replay rounds: the mascots would stay dimmed for the whole round.

### 2a. Delivery stops after a camera stall (Edo)

**Problem.** `drain` invalidates the channel when `time - lastCapture >= freshness`, and only a publication refreshes `lastCapture`. After a stall that long, each new frame reactivates the channel at admission. The render tick then drains during that frame's Vision inference, sees the old `lastCapture`, and invalidates again, so the frame's publication is refused. This repeats until the capture context changes.

**Evidence.** `aCameraStallDoesNotEndDeliveryForTheRestOfTheSession` reproduces it with the real gate and tracker. How often real stalls reach the 0.5 s limit hasn't been measured.

**Candidate fix, checked in a scratch merge with all of Edo's bridge and adapter tests.** Keep `lastCapture` as the ordering watermark and time freshness from a separate value:

```diff
   private var lastCapture: Double?
+  private var freshFrom: Double?
 // endSession
-    invalidate(); attachment = nil; context = nil; lastFrame = 0; lastCapture = nil
+    invalidate(); attachment = nil; context = nil; lastFrame = 0; lastCapture = nil; freshFrom = nil
 // admit
-      context = c; active = authorized
+      context = c; active = authorized; freshFrom = source.capturedAt
 // publish
-    lastFrame = original.frameID; lastCapture = original.capturedAt
+    lastFrame = original.frameID; lastCapture = original.capturedAt; freshFrom = original.capturedAt
 // drain
-    if active, let lastCapture, !time.isFinite || time < lastCapture || time - lastCapture >= freshness {
+    if active, let freshFrom, !time.isFinite || time < freshFrom || time - freshFrom >= freshness {
```

### 2b. Attach only after the body session has started (Edo + Jevon)

`reserveBodySession` and `stopBodySession` retire the pose lease, and `PlayView` attaches while it builds each scene. So the session must already have started when the scene is built, on first launch and on Retry: stop the old session, release it, start the new one, then rebuild the scene. A lease retired after attachment ends that scene's feed, and its mascots stay dimmed and neutral until a new scene attaches.

| Check | Expected | Failure signal |
|---|---|---|
| Identity | P1 always on Lemon, left lane; P2 on Tangerine | Mascots swap when players cross or rebind |
| Mirroring | Player's right arm raises the mascot's right arm | Opposite arm moves |
| Calibrated pose | Duck follows the player's own proportions for short and tall players | Same crouch regardless of player; `directionOnly` after calibration |
| Stop and rebind | Status change resets to neutral at once, without a new frame | Old pose held after stop |
| Feed ends | Mascots go neutral and dim at once and stay that player's only body | Last pose held at full opacity; pictogram beside a mascot |
| Camera stall | Mascots recover without a rebind once frames return | Mascots stay dimmed while the camera is running (section 2a) |
| Stale frames | Late frames rejected; mascot relaxes after 0.25 s | Mailbox `rejected` empty while frames arrive late |
| Jump | Needs airborne evidence added to D06 first | Mascots never lift off |
| Cutouts | Pass `cutoutSource` with Edo's provider, no `avatarSource` | Pictograms stay while frames are arriving |

## 3. Requires Jevon's live session

| Check | Expected | Failure signal |
|---|---|---|
| Session source | Live round drives the existing presenter unchanged | Rendering needs a replay script |
| Pause and Resume | `hudActions` receives both; corridor, gates and cue hold, then continue | Gates move during pause |
| Tracking loss during play (D03.6) | Outcomes suspended; mascot dims | HIT shown while input is unavailable |
| Round readiness | The clock starts only after the scene can be seen (see section 6) | A warning, crossing or verdict happens before the first drawn frame |
| Withdrawn attempts | `.attemptWithdrawn` is emitted; gate stops at once | Gate keeps arming during a vault |
| Different crossing times | Each player's badge appears at their own verdict | Badge waits for the other player |
| Diamonds (J05) | Real diamonds replace the fixture | Fixture tag present in a real round |

## 4. Physical iPad, later

- Real-camera tracking accuracy and P1/P2 identity with two people.
- End-to-end pose latency and how the 0.25 s hold and 30 ms smoothing feel.
- Frame rate and thermals with camera, Vision and two skinned mascots.
- Live cutout edges, transparency and texture streaming.
- Time from launch or Retry to the first drawn frame, and how much game time passes before it (section 6 has the Simulator figures).
- `maximumDisplayAge` and the cutout lag limit, which must be measured, not assumed.

## 5. Handoffs needed to run real gameplay

| From | To | Item |
|---|---|---|
| Edo + Kevin | Team | D06 field freeze against D02/D03, including jump evidence and `visual` body values |
| Edo | Kevin | E07 producer wired through `RootView`, after the steps and stall fix in section 2 |
| Edo + Jevon | Kevin | Body session started before each scene attaches, including Retry (section 2b) |
| Edo | Kevin | Production `PlayerCutoutProviding` and accepted layout, if cutouts ship |
| Jevon | Kevin | Live session with pause, resume and D03.6 behaviour |
| Jevon | Kevin | Round readiness before the game clock starts (section 6) |
| Team | Kevin | Decisions on foot planting (K07) and normalized lasers (D07) |
| Unassigned | Team | Owner for the Results screen visual design |
| Theo + Tech Lead | Kevin | Player representation policy (section 7) |

## 6. Round readiness handoff (Jevon)

**Problem.** The replay frame loop starts the game clock when the round starts, and RealityKit can't report when the first frame has been drawn. So some game time always passes unseen.

Simulator measurements from clock start to the first visible frame (instrumented scratch build, sampled from screenshots about every 0.3 s):

| Path | Unseen game time |
|---|---|
| Launch, Debug or Release, cold or warm install | 0.12 to 0.36 s |
| Retry, Debug or Release, run programmatically | Under one screenshot interval with cached scenes (0.05 to 0.32 s before caching) |
| Retry after an XCTest tap and UI query | 4.2 s, with RealityKit requesting drawables at its normal rate and no asset work running |

The 4.2 s case didn't appear when the same Retry ran programmatically under XCTest, so it comes from the XCTest tap and query path, not from asset loading. A real finger tap and device timing are unmeasured. The replay's first laser warns at 1.0 s, cues at 2.6 s and crosses at 4.0 s, so a delay of a few tenths of a second doesn't hide it. A slower device or a live first laser that warns at 0 s could.

**Needed from the session:**
1. An explicit pre-round state in which `GameClock` does not advance and no encounter can warn, arm or be judged.
2. An explicit `begin` from that state, reached through a countdown or readiness step. Its length must come from a measured device value, with no value assumed here.
3. The first laser's warning scheduled no earlier than the end of that step.
4. Retry passing through the same state.

**Kevin then:** shows the countdown from that session state, and measures launch and Retry first-frame time on a device.

**Expected:** the scene is visible with the HUD before the first warning, on launch and after Retry. **Failure signal:** score or health changes on the first visible frame.

## 7. Player representation policy (decision needed: Theo + Tech Lead)

**Status: TBD.** No approved document chooses between mascots and cutouts. `TEAM_ALIGNMENT` sections A to C still describe live cutouts as the presentation contract. D02/D03 approves the E07 and K03 avatar checkpoints as work, not mascots as the product's player representation. Code keeps its current safe behaviour until this is decided.

| Input attached | What each player shows | When that player's data is missing or stale |
|---|---|---|
| E07 pose feed | Mascot | The same mascot dims and relaxes to neutral; the other player is unaffected |
| Cutout feed only | Live cutout | That player's pictogram; the other player is unaffected |
| Neither, Release | Pictogram (temporary) | Not applicable |
| Neither, Debug | Mascot driven by replay | Not applicable |

**Decisions needed:**
1. Which representation ships: mascots, live cutouts, or both as a selectable mode.
2. What a tracking-lost player looks like. Today it's a dimmed, relaxed mascot.
3. When the temporary Release pictograms can be removed.
4. The display mirroring rule, still marked TBD in `TEAM_ALIGNMENT` section C.
