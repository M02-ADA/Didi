//
//  GameplayScenePresenter.swift
//  Sedactive
//

import RealityKit
import UIKit

/// Presents Jevon's authoritative LaserHeist game state in the RealityKit
/// scene (LH-24). Kevin owns this; Jevon's session owns the frame loop,
/// `GameClock`, scheduling, evidence, verdicts and scoring.
///
/// Each call to `apply` is a pure function of what the session reports:
/// - Forward travel: the players ride through the corridor. The corridor
///   streams at `LaserWorldLayout.travelSpeed` while the round travels, and
///   each laser gate is an obstacle standing still in that corridor: it sits
///   `travelSpeed × (crossingTime − t)` ahead of the players, so it passes
///   them with the corridor and reaches the interaction plane at exactly its
///   `crossingTime`. Everything follows game time, so pauses hold it still.
/// - Lasers: one lane-local gate per judged target, at that target's own band.
///   It shows unarmed (`.inactive`) once it is within view down the corridor,
///   warns from `warningTime`, turns solid at the action cue (`cueLead` from
///   the round's configuration), and powers down from that player's own
///   judgement.
/// - The shared move cue follows the earliest unresolved target, and only
///   during the activity phase.
/// - One-time effects come from ordered `GameEvent`s, deduplicated by
///   sequence: `targetJudged` for each player's CLEAR/HIT/UNAVAILABLE,
///   `teamEffectsCommitted` for the shared effect, `attemptWithdrawn` to stop
///   a hazard at once.
/// - The pictogram is fitted to the latest body sample; the player's
///   placement and any live cutout never move with it.
///
/// It keeps no clock and decides nothing.
@MainActor
final class GameplayScenePresenter {
    struct Diagnostics: Equatable {
        var badges = 0
        var teamEffects = 0
        var withdrawnTargets = 0
        var createdHazards = 0
        var peakVisibleHazards = 0
        /// Pending hazards that could not be shown. Always 0: a laser gameplay
        /// still expects a player to avoid is never hidden for lack of pool space.
        var droppedHazards = 0
        /// Cosmetic power-down tails skipped beyond the expected peak.
        var droppedTails = 0
        /// Gates created beyond the schedule's expected peak (the pool grew).
        var poolGrowth = 0
    }

    /// A passed gate is hidden this close to the camera (meters), by when it
    /// has already left the frame above or below.
    static let cameraClearance: Float = 0.5

    private struct Slot {
        let hazard: LaserHazard
        var target: LaserTarget
    }

    private let scene: LaserScene
    private var hiddenPawBoardLanes: [PlayerID: Bool] = [:]
    private let configuration: LaserRoundConfiguration
    /// Gates each player is expected to need at once, from the schedule known
    /// at the start. A guide, not a limit: pending hazards are always shown and
    /// the pool grows if needed; only cosmetic tails are trimmed beyond it.
    let capacity: [PlayerID: Int]
    private var slots: [LaserTargetKey: Slot] = [:]
    private var free: [PlayerID: [LaserHazard]] = [:]
    private var created: [PlayerID: Int] = [:]
    private var judgedAt: [LaserTargetKey: Double] = [:]
    private var withdrawnAt: [UUID: Double] = [:]
    private var endedAt: Double?
    private var generation: UUID?
    private var nextEvent = 0
    private var lastSequence: UInt64?
    /// Meters travelled so far this round, and the game time it was last advanced to.
    private(set) var travelDistance: Float = 0
    private var travelledUntil: Double?
    private var isTravelling = false
    /// Travel distance at which a gate that is no longer a hazard stands, so it
    /// stays put in the corridor, including when the team stops.
    private var anchors: [LaserTargetKey: Float] = [:]
    private let debug = Entity()
    private var markers: [ModelEntity] = []
    private var bandEdges: [PlayerID: [ModelEntity]] = [:]
    private(set) var diagnostics = Diagnostics()
    /// The Dual Key Vault's door, countdown and button indicators (LH-18).
    let vault: VaultPresentation
    /// Diamond Time's diamonds (J05 pending: Debug fixture only).
    let diamondTime: DiamondTimePresentation
    /// K06: the activity's normal (passage) diamonds, from the domain's states.
    let normalDiamonds: NormalDiamondPresentation
    /// The final vault at the end of the corridor, the scripted entry and the room inside.
    let finalVault: FinalVaultPresentation
    /// Game time of the authoritative `phaseChanged(.diamondTime)` event, if seen.
    private(set) var diamondTimeStartedAt: Double?

    /// Sound for what this presenter shows, at the moment it shows it: a
    /// final CLEAR/HIT verdict, the DUCK/JUMP action cue, a new vault button,
    /// the vault's last seconds, the door opening, Diamond Time and a
    /// collected diamond. Each fires once per event; UNAVAILABLE stays silent.
    var onSound: ((SoundCue) -> Void)?
    /// Attempts whose action cue has sounded, by attempt and move.
    private var cuedAttempts: Set<String> = []
    #if DEBUG
    /// `[LaserJumpTiming]`: targets whose drawn crossing was logged.
    private var tracedCrossings: Set<LaserTargetKey> = []
    #endif
    /// Active vault buttons last seen, per vault.
    private var vaultButtonsSeen: (id: UUID, count: Int)?
    private var lastVaultTick: (id: UUID, second: Int)?
    private var diamondsHeard = 0

    /// - Parameters:
    ///   - encounters: the round's schedule as known now, used only to estimate
    ///     the pool's expected peak (encounters added later are still shown).
    ///   - showsDebugMarkers: replay body and band-edge markers (Debug aid).
    init(scene: LaserScene, configuration: LaserRoundConfiguration, encounters: [LaserEncounter],
         showsDebugMarkers: Bool = false) {
        self.scene = scene
        self.configuration = configuration
        capacity = Self.capacity(for: encounters, configuration: configuration,
                                 approachLead: Self.approachLead(in: scene))
        vault = VaultPresentation(scene: scene, configuration: configuration)
        diamondTime = DiamondTimePresentation(scene: scene)
        normalDiamonds = NormalDiamondPresentation(scene: scene)
        finalVault = FinalVaultPresentation(scene: scene)
        debug.name = "gameplay.debug"
        debug.isEnabled = showsDebugMarkers
        scene.isLaserVisible = false
        scene.root.addChild(debug)
    }

    /// How long before its crossing a gate comes into view: the time to travel
    /// from where gates emerge, deep in the corridor's haze, to the interaction plane.
    static func approachLead(in scene: LaserScene) -> Double {
        let distance = scene.mapping.interactionPlaneZ - scene.layout.laserEmergeZ
        return scene.layout.travelSpeed > 0 ? Double(distance / scene.layout.travelSpeed) : 0
    }

    /// Visible windows run from when a gate comes into view (or its warning,
    /// if earlier) until it has powered down after its target is finalized.
    /// The most each player needs at once, plus one for frame-granular
    /// finalization.
    static func capacity(for encounters: [LaserEncounter], configuration: LaserRoundConfiguration,
                         approachLead: Double) -> [PlayerID: Int] {
        let tail = 2 * LaserGate.longestTransition
        var result: [PlayerID: Int] = [:]
        for player in PlayerID.allCases {
            var edges: [(time: Double, step: Int)] = []
            for target in encounters.flatMap(\.targets) where target.playerID == player {
                let end = configuration.evidenceTiming.finalizationTime(crossing: target.crossingTime) + tail
                edges.append((min(target.warningTime, target.crossingTime - approachLead), 1))
                edges.append((end, -1))
            }
            // Closings first at equal times: a window that ends as another starts doesn't overlap it.
            edges.sort { $0.time == $1.time ? $0.step < $1.step : $0.time < $1.time }
            var open = 0, most = 0
            for edge in edges {
                open += edge.step
                most = max(most, open)
            }
            result[player] = max(most, 1) + 1
        }
        return result
    }

    /// The hazard shown for a target, if any (tests and debugging).
    func hazard(for key: LaserTargetKey) -> LaserHazard? { slots[key]?.hazard }
    var visibleHazardCount: Int { slots.count }

    // MARK: - Applying game state

    /// Presents `state` at its own game time, after handling the session's
    /// ordered `events` (the full list so far; already handled ones are skipped).
    /// - Parameter upcomingVaultIn: activity seconds until the next vault
    ///   begins, from the session's schedule (see `VaultPresentation.update`).
    /// - Parameter finalVault: the live session's final vault entry; `nil` before it and in
    ///   replay, where Diamond Time shows the vault room at once.
    func apply(state: LaserGameState, events: [GameEvent], snapshot: BodySnapshot?, upcomingVaultIn: Double? = nil,
               finalVault entry: LaserFinalVaultEntry? = nil, showsPawBoard: Bool = false) {
        if generation != state.sessionGeneration {
            reset()
            generation = state.sessionGeneration
        }
        handle(events, state: state)
        let time = state.gameTime
        if case .ended = state.phase, endedAt == nil { endedAt = time }
        let stage = finalVaultStage(state: state, entry: entry)
        // The approach to the final vault moves the corridor (cosmetic, while game time is held).
        let approach = finalVault.update(stage)
        showPawBoard(showsPawBoard)
        travel(state: state, to: time, plus: approach, upcomingVaultIn: upcomingVaultIn, holding: vault.holdsTravel(for: state))
        vault.update(state: state, travelDistance: travelDistance + approach, upcomingVaultIn: upcomingVaultIn)
        soundVault(state)
        // Diamond Time's diamonds appear once the team is inside the vault.
        diamondTime.update(state: state, diamondTimeStartedAt: diamondTimeStartedAt,
                           hidden: showsPawBoard || { if case .entry = stage { true } else { false } }())
        normalDiamonds.update(state: state)
        // One pickup sound per collection shown, normal or Diamond Time.
        let collected = diamondTime.collections + normalDiamonds.collections
        if collected > diamondsHeard { onSound?(.diamondCollect) }
        diamondsHeard = collected
        updateHazards(state: state, at: time)
        updateCue(state: state, at: time)
        scene.setTimingPresentation(endedAt == nil && scene.timingVariant != .approved ? LaserTimingPresentation.make(state: state,
            configuration: configuration, withdrawn: Set(withdrawnAt.keys)) : nil)
        if let snapshot, snapshot.sessionGeneration == state.sessionGeneration { present(snapshot) }
        updateBandEdges()
    }

    private func showPawBoard(_ visible: Bool) {
        if visible {
            for (player, lane) in scene.players where hiddenPawBoardLanes[player] == nil {
                hiddenPawBoardLanes[player] = lane.isEnabled
                lane.isEnabled = false
            }
        } else {
            for (player, enabled) in hiddenPawBoardLanes { scene.players[player]?.isEnabled = enabled }
            hiddenPawBoardLanes.removeAll()
        }
    }

    /// Hides everything this presenter shows; called when the session stops.
    func stop() {
        showPawBoard(false)
        for key in Array(slots.keys) { release(key) }
        scene.setMoveCue(nil, actionRemaining: nil)
        scene.clearLaserFeedback()
        vault.stop()
        diamondTime.clear()
        normalDiamonds.clear()
        finalVault.remove()
        debug.removeFromParent()
    }

    private func reset() {
        showPawBoard(false)
        for key in Array(slots.keys) { release(key) }
        scene.clearLaserFeedback()
        travelDistance = 0
        travelledUntil = nil
        anchors = [:]
        scene.setTravelDistance(0)
        vault.reset()
        diamondTime.clear()
        normalDiamonds.clear()
        finalVault.stop()
        bandScales = [:]
        diamondTimeStartedAt = nil
        judgedAt = [:]
        withdrawnAt = [:]
        endedAt = nil
        nextEvent = 0
        lastSequence = nil
        cuedAttempts = []
        #if DEBUG
        tracedCrossings = []
        #endif
        vaultButtonsSeen = nil
        lastVaultTick = nil
        diamondsHeard = diamondTime.collections + normalDiamonds.collections
    }

    // MARK: - Sound

    /// Play accepted button sounds and one countdown tick per displayed second.
    private func soundVault(_ state: LaserGameState) {
        guard let current = state.vault, endedAt == nil else { return }
        let count = current.buttons.values.reduce(0) { $0 + $1.count }
        // Only while the door is still shut: once it opens, buttons are no longer part of the task.
        if let seen = vaultButtonsSeen, seen.id == current.id, count > seen.count, !current.opened, state.phase == .vault {
            onSound?(.vaultButton)
        }
        vaultButtonsSeen = (current.id, count)
        guard state.phase == .vault, !current.opened else { return }
        // Match the displayed digit. A slow frame or seek plays only the new digit.
        let second = Int(max(0, current.deadline - state.gameTime).rounded(.up))
        guard second > 0 else { return }
        if let tick = lastVaultTick, tick.id == current.id, second >= tick.second { return }
        lastVaultTick = (current.id, second)
        onSound?(.vaultWarning)
    }

    // MARK: - Events

    private func handle(_ events: [GameEvent], state: LaserGameState) {
        if nextEvent > events.count { nextEvent = 0 }
        for event in events[nextEvent...] where event.sessionGeneration == state.sessionGeneration {
            if let lastSequence, event.sequence <= lastSequence { continue }
            lastSequence = event.sequence
            switch event.kind {
            case .targetJudged(let encounterID, let player, let judgement):
                guard let (key, target) = Self.target(encounterID, player, in: state) else { break }
                // A full-warning recovery moves this logical encounter to a new attempt. Events
                // from its old attempt predate the new crossing and must not badge the new hazard.
                guard event.gameTime >= target.crossingTime else { break }
                judgedAt[key] = judgedAt[key] ?? event.gameTime
                #if DEBUG
                print(String(format: "[LaserJumpTiming] %@ %@ crossing %.3f · verdict %@ at %+.3f s", player.rawValue,
                             target.requiredMove.rawValue, target.crossingTime, "\(judgement)", event.gameTime - target.crossingTime))
                #endif
                let outcome: LaserFeedback.Outcome? = switch judgement {
                case .clear: .clear
                case .hit: .hit
                case .unavailable: .unavailable
                case .pending: nil
                }
                if let outcome {
                    scene.presentOutcome(outcome, for: player, band: displayedBand(target))
                    diagnostics.badges += 1
                    if outcome == .clear { onSound?(.laserClear) }
                    if outcome == .hit { onSound?(.laserHit) }
                }
            case .teamEffectsCommitted(_, let healthDelta, let scoreDelta):
                scene.presentTeamEffect(healthDelta: healthDelta, scoreDelta: scoreDelta)
                diagnostics.teamEffects += 1
            case .attemptWithdrawn(_, let attemptID):
                withdrawnAt[attemptID] = withdrawnAt[attemptID] ?? event.gameTime
            case .coopGateSucceeded(let gateID, _):
                vault.markSucceeded(gateID)
                onSound?(.vaultOpen)
            case .coopGateFailed(let gateID):
                vault.markFailed(gateID)
            case .roundEnded:
                endedAt = endedAt ?? event.gameTime
            case .phaseChanged(.diamondTime):
                diamondTimeStartedAt = event.gameTime
                onSound?(.diamondTime)
            default:
                break
            }
        }
        nextEvent = events.count
    }

    private static func target(_ encounterID: UUID, _ player: PlayerID, in state: LaserGameState) -> (LaserTargetKey, LaserTarget)? {
        guard let encounter = state.encounters.first(where: { $0.encounter.id == encounterID })?.encounter,
              let target = encounter.targets.first(where: { $0.playerID == player }) else { return nil }
        return (LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: player), target)
    }

    // MARK: - Travel

    /// Advances the corridor by the game time spent travelling: during the
    /// activity and Diamond Time, not while the team stands at a vault or
    /// after the round ends. Gates don't use this distance: each is placed
    /// from its own crossing time, at the same speed, so the two always agree.
    /// - Parameter extra: cosmetic distance on top (the final vault approach, on held game time).
    private func travel(state: LaserGameState, to time: Double, plus extra: Float = 0, upcomingVaultIn: Double? = nil,
                        holding: Bool = false) {
        // `holding`: an opened gate's door is still opening; the team waits until it is clear.
        let moving = (state.phase == .activity || state.phase == .diamondTime) && endedAt == nil && !holding
        isTravelling = moving
        if let last = travelledUntil, time > last, moving {
            // Eased into a gate's stop (`GateTravelEase`); cruising otherwise.
            travelDistance += scene.layout.travelSpeed * Float(time - last) * GateTravelEase.speedFactor(lead: upcomingVaultIn)
        }
        travelledUntil = max(travelledUntil ?? time, time)
        scene.setTravelDistance(travelDistance + extra)
    }

    /// The final vault from game state: nothing before Diamond Time; the scripted entry while
    /// the live session holds game time for it; then (and in replay) the room inside, kept
    /// after the round ends from Diamond Time.
    private func finalVaultStage(state: LaserGameState, entry: LaserFinalVaultEntry?) -> FinalVaultPresentation.Stage {
        guard state.phase == .diamondTime || (endedAt != nil && diamondTimeStartedAt != nil) else { return .hidden }
        if let entry, !entry.isComplete, state.phase == .diamondTime { return .entry(entry.timeline, elapsed: entry.elapsed) }
        return .inside(entry?.timeline)
    }

    // MARK: - Lasers

    private enum Status {
        case pending, judged(Judgement, at: Double), stopped(at: Double)
    }

    private func updateHazards(state: LaserGameState, at time: Double) {
        let tail = 2 * LaserGate.longestTransition
        var wanted: [(key: LaserTargetKey, target: LaserTarget, status: Status)] = []
        for encounter in state.encounters {
            for target in encounter.encounter.targets where time >= target.warningTime || isInView(target, at: time) {
                let key = LaserTargetKey(encounterID: encounter.encounter.id, attemptID: encounter.encounter.attemptID,
                                         playerID: target.playerID)
                let judgement = encounter.judgements[target.playerID]
                let status: Status
                if let judgement, !judgement.isPending {
                    let at = judgedAt[key] ?? time
                    judgedAt[key] = at
                    status = .judged(judgement, at: at)
                } else if let stopped = withdrawnAt[key.attemptID] ?? endedAt {
                    status = .stopped(at: stopped)
                } else {
                    status = .pending
                }
                switch status {
                case .judged(_, let at), .stopped(let at):
                    if time >= at + tail { continue }
                case .pending:
                    // While the team stands still (a vault), a gate not yet armed
                    // can't approach without sliding along the stopped corridor;
                    // it appears once travel resumes. (The game arms nothing then.)
                    if !isTravelling && time < target.warningTime { continue }
                }
                wanted.append((key, target, status))
            }
        }
        // Every pending hazard is shown, however many there are. Power-down
        // tails (no longer hazards) fill the rest of the expected peak, newest first.
        var kept: [(key: LaserTargetKey, target: LaserTarget, status: Status)] = []
        for player in PlayerID.allCases {
            let mine = wanted.filter { $0.key.playerID == player }
            let pending = mine.filter { Self.isPending($0.status) }
            let tails = mine.filter { !Self.isPending($0.status) }.sorted { $0.target.crossingTime > $1.target.crossingTime }
            let room = max(0, (capacity[player] ?? 1) - pending.count)
            diagnostics.droppedTails += max(0, tails.count - room)
            kept += pending + tails.prefix(room)
        }
        let keys = Set(kept.map(\.key))
        for key in Array(slots.keys) where !keys.contains(key) { release(key) }
        let pairs = sharedPairs(kept)
        // A whole shared beam takes the more urgent of its two players' looks
        // (decided before showing, so its state never flips within a frame).
        var sharedLooks: [LaserTargetKey: (state: LaserGate.VisualState, warningProgress: Float?)] = [:]
        for pair in pairs where pair.coincide {
            let looks = [visual(for: pair.p1.target, status: pair.p1.status, at: time),
                         visual(for: pair.p2.target, status: pair.p2.status, at: time)]
            let urgent = looks.max { Self.urgency($0.state) < Self.urgency($1.state) }!
            sharedLooks[pair.p1.key] = (urgent.state, urgent.state == .warning ? looks.compactMap(\.warningProgress).max() : nil)
        }
        for (key, target, status) in kept {
            let hazard = slots[key]?.hazard ?? acquire(key, target)
            let drawn = depth(key, target, status, at: time)
            show(hazard, target: target, status: status, depth: drawn, at: time, look: sharedLooks[key])
            #if DEBUG
            if Self.isPending(status), drawn >= scene.mapping.interactionPlaneZ { traceCrossing(key, target, at: time) }
            #endif
        }
        joinSharedBeams(pairs)
        // Invariant check: every pending hazard got a gate.
        diagnostics.droppedHazards += wanted.filter { Self.isPending($0.status) && slots[$0.key] == nil }.count
        anchors = anchors.filter { keys.contains($0.key) }
        diagnostics.peakVisibleHazards = max(diagnostics.peakVisibleHazards, slots.count)
    }

    private static func isPending(_ status: Status) -> Bool {
        if case .pending = status { true } else { false }
    }

    /// A hazard is placed from its crossing time, so it meets the players
    /// exactly then. Once it is no longer a hazard it is pinned to the
    /// corridor where it stands, so it stops when the team stops.
    private func depth(_ key: LaserTargetKey, _ target: LaserTarget, _ status: Status, at time: Double) -> Float {
        let scheduled = depth(of: target, at: time)
        guard !Self.isPending(status) else { return scheduled }
        let anchor = anchors[key] ?? travelDistance + (scene.mapping.interactionPlaneZ - scheduled)
        anchors[key] = anchor
        return scene.mapping.interactionPlaneZ - (anchor - travelDistance)
    }

    /// The band a target's gate is drawn at. With the mascots' normalized
    /// presentation (`RobotAvatarLayer.normalizesLaserBands`, on in gameplay)
    /// it is the judged band in that player's normalized avatar space: the beam
    /// meets the fixed-size mascot where it meets the player, relative to their
    /// own height, so both halves of a shared beam line up. Otherwise it is the
    /// judged band itself. Display only: the target, the judge and the verdict
    /// never see this.
    func displayedBand(_ target: LaserTarget) -> ClosedRange<Float> {
        let band = Float(target.beam.lowerY)...Float(target.beam.upperY)
        guard let scale = normalizationScale(for: target.playerID) else { return band }
        return (band.lowerBound * scale)...(band.upperBound * scale)
    }

    /// The same display mapping for one body height (the Debug evidence markers).
    private func displayedHeight(_ y: Float, for player: PlayerID) -> Float {
        y * (normalizationScale(for: player) ?? 1)
    }

    /// One drawing scale for every mascot shown or for none. If any shown mascot
    /// has no avatar scale yet (no compatible accepted calibration), every lane
    /// falls back to its judged band: a shared beam drawn at two unrelated scales
    /// would look aligned while meaning nothing. The judged fallback may step
    /// between lanes, and that step is true. Only the mascots in the round count
    /// (a Solo Test shows Lemon alone), and each keeps its last scale while its
    /// pose briefly carries no reference (until a new calibration replaces it),
    /// so a beam never jumps height mid-approach.
    private func normalizationScale(for player: PlayerID) -> Float? {
        guard let avatars = scene.robotAvatars, !avatars.robots.isEmpty else { return nil }
        for shown in avatars.robots.keys {
            if let scale = avatars.laserBandScale(for: shown, mapping: scene.mapping) { bandScales[shown] = scale }
        }
        guard avatars.robots.keys.allSatisfy({ bandScales[$0] != nil }) else { return nil }
        return bandScales[player]
    }
    /// The last avatar scale of each shown mascot (see `normalizationScale`).
    private var bandScales: [PlayerID: Float] = [:]

    private func show(_ hazard: LaserHazard, target: LaserTarget, status: Status, depth: Float, at time: Double,
                      look shared: (state: LaserGate.VisualState, warningProgress: Float?)? = nil) {
        let band = displayedBand(target)
        hazard.setBand(lowerEdge: band.lowerBound, upperEdge: band.upperBound)
        hazard.setDangerSide(target.requiredMove == .duck ? .above : .below)
        hazard.setDepth(depth)
        let look = shared ?? visual(for: target, status: status, at: time)
        hazard.setState(look.state)
        if let progress = look.warningProgress { hazard.setWarningProgress(progress) }
        // A passed gate keeps travelling with the corridor until it nears the camera.
        hazard.root.isEnabled = depth < scene.layout.cameraPosition.z - Self.cameraClearance
    }

    /// The gate look for one player's target: LH-05's inactive → warning →
    /// active → hit/disabled, from the authoritative status and cue timing.
    private func visual(for target: LaserTarget, status: Status, at time: Double)
        -> (state: LaserGate.VisualState, warningProgress: Float?) {
        let cue = cueTime(for: target)
        switch status {
        case .stopped:
            return (.disabled, nil)
        case .judged(let judgement, let at):
            if case .hit = judgement, time < at + LaserGate.longestTransition { return (.hit, nil) }
            return (.disabled, nil)
        case .pending where time < target.warningTime:
            return (.inactive, nil)
        case .pending where time < cue:
            let span = cue - target.warningTime
            return (.warning, span > 0 ? Float((time - target.warningTime) / span) : 1)
        case .pending:
            return (.active, nil)
        }
    }

    /// Two drawn bands closer than this (game units) are one beam: about the
    /// judge's clearance margin, so neither player is shown a misleading height.
    static let sharedBeamTolerance: Float = 0.006

    private typealias Kept = (key: LaserTargetKey, target: LaserTarget, status: Status)

    /// Both players' members of one attempt crossing together, and whether
    /// their drawn bands coincide (one beam) or differ (two joined halves).
    private func sharedPairs(_ kept: [Kept]) -> [(p1: Kept, p2: Kept, coincide: Bool)] {
        Dictionary(grouping: kept, by: { $0.key.attemptID }).values.compactMap { members in
            guard members.count == 2,
                  let p1 = members.first(where: { $0.key.playerID == .player1 }),
                  let p2 = members.first(where: { $0.key.playerID == .player2 }),
                  abs(p1.target.crossingTime - p2.target.crossingTime) < 0.02 else { return nil }
            // In the mascots' normalized space a shared attempt is always one beam: its bands
            // are the same shares of each player's height (rounding of the judge's margin aside).
            if normalizationScale(for: .player1) != nil, normalizationScale(for: .player2) != nil {
                return (p1, p2, true)
            }
            let a = displayedBand(p1.target), b = displayedBand(p2.target)
            let coincide = abs(a.lowerBound - b.lowerBound) <= Self.sharedBeamTolerance
                && abs(a.upperBound - b.upperBound) <= Self.sharedBeamTolerance
            return (p1, p2, coincide)
        }
    }

    /// One laser, one beam. When both players face the same attempt at the
    /// same crossing:
    /// - If their drawn bands coincide (with the mascots' normalized bands,
    ///   players of any height do), P1's gate draws the whole beam from wall to
    ///   wall at P1's band and P2's gate is hidden. One gate means one core, one
    ///   glow and one set of animations, so no seam can open at the lane
    ///   boundary. It shows the more urgent of the two players' looks (set in
    ///   `updateHazards`): either player's HIT flares it.
    /// - Otherwise the two lane halves join at the boundary, each at its own
    ///   band, stepping between them in the gap between the lanes.
    /// Display only: targets, verdicts and badges stay per player.
    private func joinSharedBeams(_ pairs: [(p1: Kept, p2: Kept, coincide: Bool)]) {
        var joined: Set<LaserTargetKey> = []
        var leads: Set<LaserTargetKey> = []
        for pair in pairs {
            guard let lead = slots[pair.p1.key]?.hazard, let partner = slots[pair.p2.key]?.hazard else { continue }
            joined.formUnion([pair.p1.key, pair.p2.key])
            guard pair.coincide else {
                lead.setJoin(partnerBand: displayedBand(pair.p2.target))
                partner.setJoin(partnerBand: displayedBand(pair.p1.target))
                continue
            }
            if lead.span != scene.fullLaserSpan { lead.setSpan(scene.fullLaserSpan) }
            lead.setEmitters(left: true, right: true)
            lead.setJoin(partnerBand: nil)
            lead.root.isEnabled = lead.root.isEnabled || partner.root.isEnabled
            partner.root.isEnabled = false
            leads.insert(pair.p1.key)
        }
        // Every other gate is its own lane half, with only its own wall's emitter.
        for (key, slot) in slots where !leads.contains(key) {
            let lane = scene.laneSpan(for: key.playerID)
            if slot.hazard.span != lane { slot.hazard.setSpan(lane) }
            slot.hazard.setEmitters(left: key.playerID == .player1, right: key.playerID == .player2)
            if !joined.contains(key) { slot.hazard.setJoin(partnerBand: nil) }
        }
        sharedBeams = leads
    }

    /// The P1 gates drawing a whole shared beam this frame (tests and debugging).
    private(set) var sharedBeams: Set<LaserTargetKey> = []

    private static func urgency(_ state: LaserGate.VisualState) -> Int {
        switch state {
        case .disabled: 0
        case .inactive: 1
        case .warning: 2
        case .active: 3
        case .hit: 4
        }
    }

    /// Where a still-pending gate stands relative to the players:
    /// `travelSpeed` meters per second of remaining time ahead of the
    /// interaction plane, so it is on the plane at exactly `crossingTime`.
    /// While the team travels this moves exactly with the corridor.
    func depth(of target: LaserTarget, at time: Double) -> Float {
        scene.mapping.interactionPlaneZ - scene.layout.travelSpeed * Float(target.crossingTime - time)
    }

    /// A gate is in view once it is no farther down the corridor than the laser spawn point.
    private func isInView(_ target: LaserTarget, at time: Double) -> Bool {
        depth(of: target, at: time) >= scene.layout.laserEmergeZ
    }

    /// When the action cue starts for this target: the round's `cueLead`
    /// before the crossing, never before the warning. Without a cue lead the
    /// beam stays a warning until the crossing.
    private func cueTime(for target: LaserTarget) -> Double {
        let cue = configuration.scheduling?.actionCueTime(for: target)
            ?? configuration.actionCueLead.map { target.crossingTime - $0 }
            ?? target.crossingTime
        return min(max(cue, target.warningTime), target.crossingTime)
    }

    /// A free gate for this player, creating one if none is free. Never fails,
    /// so a pending hazard always has a gate; growth past the expected peak is counted.
    private func acquire(_ key: LaserTargetKey, _ target: LaserTarget) -> LaserHazard {
        let player = key.playerID
        let hazard: LaserHazard
        if let reused = free[player]?.popLast() {
            hazard = reused
        } else {
            hazard = scene.makeLaneHazard(for: player)
            created[player, default: 0] += 1
            diagnostics.createdHazards += 1
            if created[player, default: 0] > capacity[player, default: 1] { diagnostics.poolGrowth += 1 }
        }
        slots[key] = Slot(hazard: hazard, target: target)
        return hazard
    }

    private func release(_ key: LaserTargetKey) {
        guard let slot = slots.removeValue(forKey: key) else { return }
        slot.hazard.root.isEnabled = false
        free[key.playerID, default: []].append(slot.hazard)
    }

    // MARK: - Cue

    private func updateCue(state: LaserGameState, at time: Double) {
        guard state.phase == .activity, endedAt == nil else {
            scene.setMoveCue(nil, actionRemaining: nil)
            return
        }
        var next: LaserTarget?
        var attempt: UUID?
        for encounter in state.encounters where withdrawnAt[encounter.encounter.attemptID] == nil {
            for target in encounter.encounter.targets
            where time >= target.warningTime && time < target.crossingTime
                && encounter.judgements[target.playerID]?.isPending != false
                && target.crossingTime < (next?.crossingTime ?? .infinity) {
                next = target
                attempt = encounter.encounter.attemptID
            }
        }
        guard let next else {
            scene.setMoveCue(nil, actionRemaining: nil)
            return
        }
        let cue = cueTime(for: next)
        let move: LaserFeedback.Move = next.requiredMove == .duck ? .duck : .jump
        let remaining = time >= cue && next.crossingTime > cue ? Float((next.crossingTime - time) / (next.crossingTime - cue)) : nil
        scene.setMoveCue(move, actionRemaining: remaining)
        // The cue sounds when the action is called (the same moment the 3D cue
        // turns solid), once per attempt and move: both players share one sound.
        if time >= cue, let attempt, cuedAttempts.insert("\(attempt)-\(move)").inserted {
            onSound?(move == .duck ? .cueDuck : .cueJump)
        }
    }

    // MARK: - Body

    /// Fits each pictogram to the latest body sample and places the Debug body markers.
    private func present(_ snapshot: BodySnapshot) {
        if markers.isEmpty { buildMarkers() }
        #if DEBUG
        // DEBUG-only synthetic bridge: in the replay round the avatars show the
        // bundled historical replay fixture's frame (labelled synthetic). The
        // production avatars never read CP1: they take `AvatarPoseFrame`s (K03),
        // so a live attachment is the only driver while one exists.
        if scene.liveAvatars == nil { scene.robotAvatars?.apply(snapshot) }
        #endif
        for (index, player) in PlayerID.allCases.enumerated() {
            guard let geometry = snapshot.players[player]?.geometry else { continue }
            if let crown = geometry.crownY.value, let left = geometry.leftSoleY.value, let right = geometry.rightSoleY.value {
                scene.setPlaceholderBody(for: player, floor: min(left, right), crown: crown)
            }
            let points = [geometry.crownY, geometry.leftWristY, geometry.rightWristY, geometry.leftSoleY, geometry.rightSoleY]
            for (offset, point) in points.enumerated() {
                let marker = markers[index * points.count + offset]
                marker.isEnabled = point.validity == .valid
                if let y = point.value {
                    marker.position = scene.mapping.playerPosition(player, heightAboveFloor: displayedHeight(Float(y), for: player))
                    marker.position.x += [Float(0), -0.16, 0.16, -0.08, 0.08][offset]
                    marker.position.z += 0.06
                }
            }
        }
    }

    #if DEBUG
    /// TIMING TRACE (iPad, 13 November 2026, JUMP timing): the frame a pending laser is first drawn
    /// on the players' plane, with how late that is against its authoritative crossing (GameClock),
    /// how old the pose the mascot shows is (camera host clock: capture → this frame) and the
    /// mascot's lift. One line per target; the verdict follows in its own line.
    private func traceCrossing(_ key: LaserTargetKey, _ target: LaserTarget, at time: Double) {
        guard tracedCrossings.insert(key).inserted else { return }
        let age = scene.robotAvatars?.shownCapture[key.playerID].map { CameraHostClock.now() - $0 }
        let lift = scene.robotAvatars?.robots[key.playerID]?.retargeter.lift
        print(String(format: "[LaserJumpTiming] %@ %@ crossing %.3f · drawn on the plane %+.3f s · mascot pose age %@ · lift %@",
                     key.playerID.rawValue, target.requiredMove.rawValue, target.crossingTime, time - target.crossingTime,
                     // Replay and synthetic poses are not stamped with camera time: no age.
                     age.flatMap { (0...5).contains($0) ? String(format: "%.3f s", $0) : nil } ?? "n/a",
                     lift.map { String(format: "%.3f", $0) } ?? "-"))
    }
    #endif

    private func buildMarkers() {
        let colors: [UIColor] = [.cyan, .purple, .purple, .green, .green]
        for _ in PlayerID.allCases {
            for color in colors {
                let marker = ModelEntity(mesh: .generateSphere(radius: 0.025), materials: [UnlitMaterial(color: color)])
                markers.append(marker)
                debug.addChild(marker)
            }
        }
    }

    /// Debug: each player's lane-local band edges for their next unresolved
    /// target, on the interaction plane.
    private func updateBandEdges() {
        guard debug.isEnabled else { return }
        for player in PlayerID.allCases {
            if bandEdges[player] == nil {
                bandEdges[player] = (0..<2).map { _ in
                    let edge = ModelEntity(mesh: .generateBox(size: [1, 0.004, 0.004]), materials: [UnlitMaterial(color: .yellow)])
                    debug.addChild(edge)
                    return edge
                }
            }
            let target = slots.values.map(\.target).filter { $0.playerID == player }.min { $0.crossingTime < $1.crossingTime }
            let span = scene.laneSpan(for: player)
            let band = target.map(displayedBand)
            for (edge, y) in zip(bandEdges[player] ?? [], [band?.lowerBound, band?.upperBound]) {
                edge.isEnabled = y != nil
                guard let y else { continue }
                edge.position = scene.mapping.laserPosition(heightAboveFloor: y, worldZ: scene.mapping.interactionPlaneZ + 0.03)
                edge.position.x = (span.lowerBound + span.upperBound) / 2
                edge.scale.x = span.upperBound - span.lowerBound
            }
        }
    }
}

private extension Judgement {
    var isPending: Bool {
        if case .pending = self { true } else { false }
    }
}
