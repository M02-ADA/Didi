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
    /// Game time of the authoritative `phaseChanged(.diamondTime)` event, if seen.
    private(set) var diamondTimeStartedAt: Double?

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
        debug.name = "gameplay.debug"
        debug.isEnabled = showsDebugMarkers
        scene.isLaserVisible = false
        scene.root.addChild(debug)
    }

    /// How long before its crossing a gate comes into view: the time to travel
    /// from the corridor's laser spawn point to the interaction plane.
    static func approachLead(in scene: LaserScene) -> Double {
        let distance = scene.mapping.interactionPlaneZ - scene.layout.laserSpawnZ
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
    func apply(state: LaserGameState, events: [GameEvent], snapshot: BodySnapshot?) {
        if generation != state.sessionGeneration {
            reset()
            generation = state.sessionGeneration
        }
        handle(events, state: state)
        let time = state.gameTime
        if case .ended = state.phase, endedAt == nil { endedAt = time }
        travel(state: state, to: time)
        vault.update(state: state, travelDistance: travelDistance)
        diamondTime.update(state: state, diamondTimeStartedAt: diamondTimeStartedAt)
        updateHazards(state: state, at: time)
        updateCue(state: state, at: time)
        if let snapshot, snapshot.sessionGeneration == state.sessionGeneration { present(snapshot) }
        updateBandEdges()
    }

    /// Hides everything this presenter shows; called when the session stops.
    func stop() {
        for key in Array(slots.keys) { release(key) }
        scene.setMoveCue(nil, actionRemaining: nil)
        scene.clearLaserFeedback()
        vault.stop()
        diamondTime.clear()
        debug.removeFromParent()
    }

    private func reset() {
        for key in Array(slots.keys) { release(key) }
        travelDistance = 0
        travelledUntil = nil
        anchors = [:]
        scene.setTravelDistance(0)
        vault.reset()
        diamondTime.clear()
        diamondTimeStartedAt = nil
        judgedAt = [:]
        withdrawnAt = [:]
        endedAt = nil
        nextEvent = 0
        lastSequence = nil
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
                judgedAt[key] = judgedAt[key] ?? event.gameTime
                let outcome: LaserFeedback.Outcome? = switch judgement {
                case .clear: .clear
                case .hit: .hit
                case .unavailable: .unavailable
                case .pending: nil
                }
                if let outcome {
                    scene.presentOutcome(outcome, for: player, band: displayedBand(target))
                    diagnostics.badges += 1
                }
            case .teamEffectsCommitted(_, let healthDelta, let scoreDelta):
                scene.presentTeamEffect(healthDelta: healthDelta, scoreDelta: scoreDelta)
                diagnostics.teamEffects += 1
            case .attemptWithdrawn(_, let attemptID):
                withdrawnAt[attemptID] = withdrawnAt[attemptID] ?? event.gameTime
            case .coopGateSucceeded(let gateID, _):
                vault.markSucceeded(gateID)
            case .coopGateFailed(let gateID):
                vault.markFailed(gateID)
            case .roundEnded:
                endedAt = endedAt ?? event.gameTime
            case .phaseChanged(.diamondTime):
                diamondTimeStartedAt = event.gameTime
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
    private func travel(state: LaserGameState, to time: Double) {
        let moving = (state.phase == .activity || state.phase == .diamondTime) && endedAt == nil
        isTravelling = moving
        if let last = travelledUntil, time > last, moving {
            travelDistance += scene.layout.travelSpeed * Float(time - last)
        }
        travelledUntil = max(travelledUntil ?? time, time)
        scene.setTravelDistance(travelDistance)
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
        for (key, target, status) in kept {
            let hazard = slots[key]?.hazard ?? acquire(key, target)
            show(hazard, target: target, status: status, depth: depth(key, target, status, at: time), at: time)
        }
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

    /// The band a target's gate is drawn at: its judged band, or with the D07
    /// candidate (`RobotAvatarLayer.normalizesLaserBands`, DEBUG flag, off by
    /// default) that band in the player's normalized avatar space. Display only.
    func displayedBand(_ target: LaserTarget) -> ClosedRange<Float> {
        let band = Float(target.beam.lowerY)...Float(target.beam.upperY)
        guard let scale = scene.robotAvatars?.laserBandScale(for: target.playerID, mapping: scene.mapping) else { return band }
        return (band.lowerBound * scale)...(band.upperBound * scale)
    }

    /// The same display mapping for one body height (the Debug evidence markers).
    private func displayedHeight(_ y: Float, for player: PlayerID) -> Float {
        y * (scene.robotAvatars?.laserBandScale(for: player, mapping: scene.mapping) ?? 1)
    }

    private func show(_ hazard: LaserHazard, target: LaserTarget, status: Status, depth: Float, at time: Double) {
        let band = displayedBand(target)
        hazard.setBand(lowerEdge: band.lowerBound, upperEdge: band.upperBound)
        hazard.setDepth(depth)
        let cue = cueTime(for: target)
        switch status {
        case .stopped:
            hazard.setState(.disabled)
        case .judged(let judgement, let at):
            if case .hit = judgement, time < at + LaserGate.longestTransition {
                hazard.setState(.hit)
            } else {
                hazard.setState(.disabled)
            }
        case .pending where time < target.warningTime:
            hazard.setState(.inactive)
        case .pending where time < cue:
            hazard.setState(.warning)
            let span = cue - target.warningTime
            hazard.setWarningProgress(span > 0 ? Float((time - target.warningTime) / span) : 1)
        case .pending:
            hazard.setState(.active)
        }
        // A passed gate keeps travelling with the corridor until it nears the camera.
        hazard.root.isEnabled = depth < scene.layout.cameraPosition.z - Self.cameraClearance
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
        depth(of: target, at: time) >= scene.layout.laserSpawnZ
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
        for encounter in state.encounters where withdrawnAt[encounter.encounter.attemptID] == nil {
            for target in encounter.encounter.targets
            where time >= target.warningTime && time < target.crossingTime
                && encounter.judgements[target.playerID]?.isPending != false
                && target.crossingTime < (next?.crossingTime ?? .infinity) {
                next = target
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
    }

    // MARK: - Body

    /// Fits each pictogram to the latest body sample and places the Debug body markers.
    private func present(_ snapshot: BodySnapshot) {
        if markers.isEmpty { buildMarkers() }
        #if DEBUG
        // DEBUG-only synthetic bridge: in the replay round the avatars show the
        // bundled historical replay fixture's frame (labelled synthetic). The
        // production avatars never read CP1: they take `AvatarPoseFrame`s (K03).
        scene.robotAvatars?.apply(snapshot)
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
