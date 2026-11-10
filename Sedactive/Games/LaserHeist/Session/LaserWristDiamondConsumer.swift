import Foundation

/// Explicit integration input. No production radius/layout is selected here. Synthetic fixtures
/// may supply their existing numeric circles; live use requires joint geometry/reach approval.
nonisolated struct LaserWristDiamondConfiguration: Sendable {
    let layout: PlayerPlaneLayout
    let radius: Double
    let replacementPlanner: LaserDiamondPlanner
    init(layout: PlayerPlaneLayout, radius: Double, replacementPlanner: LaserDiamondPlanner) throws {
        try layout.validate()
        try requireLaserValue(radius.isFinite && radius > 0, "reviewed diamond interaction radius")
        self.layout = layout; self.radius = radius; self.replacementPlanner = replacementPlanner
    }
}

/// J07 preparation INSIDE the sole CP1 consumer. No polling, subscription, clock, calibration
/// acceptance, renderer query or game authority. Staged together with the existing LaserGame.
nonisolated struct LaserWristDiamondConsumer: Sendable {
    private struct Activation: Sendable { let frame: UInt64; let hostTime: Double }
    private let configuration: LaserWristDiamondConfiguration
    private let lifetime: UUID
    private var context: BodyInputContext
    private var entries: LaserContactEntryTracker
    private let emptyEntries: LaserContactEntryTracker
    private var planner: LaserDiamondPlanner
    private var targets: [UUID: LaserContactTarget] = [:]
    private var activations: [UUID: Activation] = [:]
    private var capturedAfter: Double
    private var lastFrame: UInt64 = 0
    private var lastCapture: Double?

    init(configuration: LaserWristDiamondConfiguration, context: BodyInputContext,
         lifetime: UUID, afterCapturedAt: Double) throws {
        try requireLaserValue(afterCapturedAt.isFinite && afterCapturedAt >= 0, "wrist start watermark")
        self.configuration = configuration; self.context = context; self.lifetime = lifetime
        capturedAfter = afterCapturedAt; planner = configuration.replacementPlanner
        let initial = try LaserContactEntryTracker(lifetime: lifetime,
            maximumContactAge: context.wristContact?.freshness ?? B2bExperimentalPolicyV1.value.freshness)
        entries = initial; emptyEntries = initial
    }

    /// Pause/source loss/cutover erases entry but never domain outcomes. New source frame IDs
    /// may restart; original host time still fences queued/pre-pause captures.
    mutating func invalidate(atHostTime time: Double) {
        targets.removeAll(); activations.removeAll(); lastFrame = 0; lastCapture = nil
        if time.isFinite { capturedAfter = max(capturedAfter, time) }
        // Reconstruct only transient entry state; target identity/outcomes remain domain-owned.
        entries = emptyEntries
    }

    /// Called even without a packet. Activation records the ORIGINAL host/frame watermark;
    /// no cached pre-activation capture can establish an outside baseline.
    mutating func refresh(game: LaserGame, context current: BodyInputContext, atHostTime time: Double) throws {
        try requireLaserValue(time.isFinite && time >= 0, "wrist host clock")
        if current != context { invalidate(atHostTime: time); context = current }
        let active = game.activeDiamonds
        let retired = Set(targets.keys).subtracting(active.map(\.id))
        entries.retireDomainTargets(retired)
        for id in retired { targets.removeValue(forKey: id); activations.removeValue(forKey: id) }
        for spawn in active {
            guard let state = game.diamonds[spawn.id] else { continue }
            if targets[spawn.id] == nil {
                let target = try LaserContactTarget(id: spawn.id, eligiblePlayers: spawn.eligiblePlayers,
                    activation: spawn.entry, deadline: state.interactionDeadline)
                try entries.addTargets([target]); targets[spawn.id] = target
            }
            if game.gameTime >= spawn.entry, activations[spawn.id] == nil {
                activations[spawn.id] = Activation(frame: lastFrame, hostTime: time)
            }
        }
    }

    var retainedTargetCount: Int { entries.retainedTargetIdentityCount }

    @discardableResult
    mutating func receive(_ snapshot: BodySnapshot, context current: BodyInputContext,
                          atHostTime hostTime: Double, capturedGameTime: Double,
                          arrivedGameTime: Double, game: inout LaserGame) throws -> [LaserContactActivation] {
        // Invalid plans cannot consume entry or partially award score/replacements.
        var next = self, nextGame = game
        try next.refresh(game: nextGame, context: current, atHostTime: hostTime)
        guard snapshot.frameID > next.lastFrame,
              next.lastCapture.map({ snapshot.capturedAt > $0 }) ?? true else { self = next; return [] }
        let afterCapture = max(next.capturedAfter, next.lastCapture ?? next.capturedAfter)
        var locations: [UUID: [LaserContactHand: LaserContactLocation]] = [:]
        for spawn in nextGame.activeDiamonds {
            var hands: [LaserContactHand: LaserContactLocation] = [:]
            for player in PlayerID.allCases {
                let admitted = current.acceptsWristContact(snapshot, playerID: player, at: hostTime,
                    afterFrameID: next.lastFrame, afterCapturedAt: afterCapture)
                for wrist in LaserContactWrist.allCases {
                    let hand = LaserContactHand(playerID: player, wrist: wrist)
                    guard admitted, let a = next.activations[spawn.id], snapshot.frameID > a.frame,
                          snapshot.capturedAt > a.hostTime, let p = snapshot.wristContact?.players[player] else {
                        hands[hand] = .unavailable; continue
                    }
                    let observation = wrist == .left ? p.left : p.right
                    guard observation.observationRefusal == nil, observation.contactRefusal == nil,
                          let xy = observation.playerPlane else { hands[hand] = .unavailable; continue }
                    // Same accepted Y-up/unmirrored plane as E08. No rig coordinates or offsets.
                    hands[hand] = hypot(xy.x - spawn.position.x, xy.y - spawn.position.y) <= configuration.radius
                        ? .inside : .outside
                }
            }
            locations[spawn.id] = hands
        }
        // Invalid/missing/stale wrists feed UNAVAILABLE, clearing only their own pending entry.
        // Original host eligibility is separate from active GameClock eligibility below.
        let contacts = try next.entries.evaluate(lifetime: lifetime, frameID: snapshot.frameID,
            capturedAt: capturedGameTime, arrivedAt: arrivedGameTime, locations: locations)
        next.lastFrame = snapshot.frameID; next.lastCapture = snapshot.capturedAt
        var replacements: [LaserDiamondSpawn] = []
        if nextGame.roundPhase == .diamondTime, !contacts.isEmpty {
            let ids = Set(contacts.map(\.targetID)), active = nextGame.activeDiamonds
            let collected = active.filter { ids.contains($0.id) }
            if let deadline = collected.first.flatMap({ nextGame.diamonds[$0.id]?.interactionDeadline }) {
                replacements = try next.planner.bonusReplacements(collected: collected,
                    surviving: active.filter { !ids.contains($0.id) }, at: arrivedGameTime, deadline: deadline)
            }
        }
        let accepted = try nextGame.collectDiamonds(contacts, generation: current.sessionGeneration,
            calibrationRevisions: current.calibrationRevisions, capturedAt: capturedGameTime,
            arrivedAt: arrivedGameTime, replacements: replacements)
        try next.refresh(game: nextGame, context: current, atHostTime: hostTime)
        self = next; game = nextGame
        return accepted
    }
}
