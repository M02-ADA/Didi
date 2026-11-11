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
    /// The open vault's button zones (live rounds only). Contacts go through the same
    /// admission, freshness and outside→inside entry rule as diamonds.
    private var vault: (id: UUID, zones: [UUID: LaserVaultZone])?
    private var vaultActivation: Activation?

    /// - Parameter planner: the round's current replacement planner, when it has moved on
    ///   from the configuration's (a recreated consumer must not reuse spent identities).
    init(configuration: LaserWristDiamondConfiguration, context: BodyInputContext,
         lifetime: UUID, afterCapturedAt: Double, planner: LaserDiamondPlanner? = nil) throws {
        try requireLaserValue(afterCapturedAt.isFinite && afterCapturedAt >= 0, "wrist start watermark")
        self.configuration = configuration; self.context = context; self.lifetime = lifetime
        capturedAfter = afterCapturedAt; self.planner = planner ?? configuration.replacementPlanner
        let initial = try LaserContactEntryTracker(lifetime: lifetime,
            maximumContactAge: context.wristContact?.freshness ?? B2bExperimentalPolicyV1.value.freshness)
        entries = initial; emptyEntries = initial
    }

    /// Pause/source loss/cutover erases entry but never domain outcomes. New source frame IDs
    /// may restart; original host time still fences queued/pre-pause captures.
    var replacementPlanner: LaserDiamondPlanner { planner }
    /// Diamond Time's replacements continue from the planner that placed its first targets.
    mutating func adoptPlanner(_ value: LaserDiamondPlanner) { planner = value }

    /// Live vault: the six button zones become contact targets until the vault closes.
    /// Activation records the current watermark: no earlier capture can be the outside baseline.
    mutating func openVault(id: UUID, zones: [LaserVaultZone], game: LaserGame, atHostTime time: Double) throws {
        try requireLaserValue(game.roundPhase == .vault && game.vault?.id == id
            && Set(zones.map(\.targetID)).count == zones.count && !zones.isEmpty, "live vault zones")
        vault = (id, Dictionary(uniqueKeysWithValues: zones.map { ($0.targetID, $0) }))
        vaultActivation = nil
        try refresh(game: game, context: context, atHostTime: time)
    }

    mutating func invalidate(atHostTime time: Double) {
        targets.removeAll(); activations.removeAll(); lastFrame = 0; lastCapture = nil
        vaultActivation = nil
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
        if let open = vault {
            if game.roundPhase != .vault || game.vault?.id != open.id || game.vault?.opened == true {
                entries.retireDomainTargets(Set(open.zones.keys))
                vault = nil; vaultActivation = nil
            } else if vaultActivation == nil, let deadline = game.vault?.deadline, deadline > game.gameTime {
                // (Re)arm after opening or after an invalidation erased transient entry.
                try entries.addTargets(open.zones.keys.sorted { $0.uuidString < $1.uuidString }.map {
                    try LaserContactTarget(id: $0, eligiblePlayers: [open.zones[$0]!.playerID],
                                           activation: game.gameTime, deadline: deadline)
                })
                vaultActivation = Activation(frame: lastFrame, hostTime: time)
            }
        }
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
        if let open = next.vault, nextGame.roundPhase == .vault {
            for zone in open.zones.values {
                var hands: [LaserContactHand: LaserContactLocation] = [:]
                let admitted = current.acceptsWristContact(snapshot, playerID: zone.playerID, at: hostTime,
                    afterFrameID: next.lastFrame, afterCapturedAt: afterCapture)
                for wrist in LaserContactWrist.allCases {
                    let hand = LaserContactHand(playerID: zone.playerID, wrist: wrist)
                    guard admitted, let a = next.vaultActivation, snapshot.frameID > a.frame,
                          snapshot.capturedAt > a.hostTime, let p = snapshot.wristContact?.players[zone.playerID] else {
                        hands[hand] = .unavailable; continue
                    }
                    let observation = wrist == .left ? p.left : p.right
                    guard observation.observationRefusal == nil, observation.contactRefusal == nil,
                          let xy = observation.playerPlane else { hands[hand] = .unavailable; continue }
                    hands[hand] = hypot(xy.x - zone.position.x, xy.y - zone.position.y) <= zone.radius
                        ? .inside : .outside
                }
                locations[zone.targetID] = hands
            }
        }
        // Invalid/missing/stale wrists feed UNAVAILABLE, clearing only their own pending entry.
        // Original host eligibility is separate from active GameClock eligibility below.
        let allContacts = try next.entries.evaluate(lifetime: lifetime, frameID: snapshot.frameID,
            capturedAt: capturedGameTime, arrivedAt: arrivedGameTime, locations: locations)
        next.lastFrame = snapshot.frameID; next.lastCapture = snapshot.capturedAt
        if let open = next.vault {
            let presses = allContacts.compactMap { contact -> LaserVaultContact? in
                guard let zone = open.zones[contact.targetID],
                      let revision = current.calibrationRevisions[zone.playerID] else { return nil }
                return LaserVaultContact(playerID: zone.playerID, button: zone.button, calibrationRevision: revision)
            }
            if !presses.isEmpty {
                try nextGame.touchVaultBatch(id: open.id, contacts: presses, generation: current.sessionGeneration,
                                             at: arrivedGameTime)
            }
        }
        let contacts = allContacts.filter { next.vault?.zones[$0.targetID] == nil }
        var replacements: [LaserDiamondSpawn] = []
        if nextGame.roundPhase == .diamondTime, !contacts.isEmpty {
            let ids = Set(contacts.map(\.targetID)), active = nextGame.activeDiamonds
            let collected = active.filter { ids.contains($0.id) }
            if let deadline = collected.first.flatMap({ nextGame.diamonds[$0.id]?.interactionDeadline }) {
                let wrists = try Set(contacts.map(\.hand)).compactMap { hand -> LaserDiamondPosition? in
                    guard let player = snapshot.wristContact?.players[hand.playerID] else { return nil }
                    let observation = hand.wrist == .left ? player.left : player.right
                    guard let point = observation.playerPlane else { return nil }
                    return try LaserDiamondPosition(x: point.x, y: point.y)
                }
                replacements = try next.planner.bonusReplacements(collected: collected,
                    surviving: active.filter { !ids.contains($0.id) }, at: arrivedGameTime, deadline: deadline,
                    avoiding: (points: wrists, radius: configuration.radius))
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
