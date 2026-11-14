import Foundation

/// Explicit integration input. No production radius/layout is selected here. Synthetic fixtures
/// may supply their existing numeric circles; live use requires joint geometry/reach approval.
nonisolated struct LaserWristDiamondConfiguration: Sendable {
    let layout: PlayerPlaneLayout
    let radius: Double
    let replacementPlanner: LaserDiamondPlanner
    let standingHeights: [PlayerID: Double]
    init(layout: PlayerPlaneLayout, radius: Double, replacementPlanner: LaserDiamondPlanner,
         standingHeights: [PlayerID: Double] = [:]) throws {
        try layout.validate()
        try requireLaserValue(radius.isFinite && radius > 0, "reviewed diamond interaction radius")
        try requireLaserValue(standingHeights.values.allSatisfy { $0.isFinite && $0 > 0 }, "diamond standing height")
        self.layout = layout; self.radius = radius; self.replacementPlanner = replacementPlanner
        self.standingHeights = standingHeights
    }

    func admitsReach(_ wrist: WristPlanePoint, to target: LaserDiamondPosition, player: PlayerID,
                     geometry: BodyGeometry?) -> Bool {
        guard let height = standingHeights[player] else { return true }
        if target.y > height {
            guard let crown = geometry?.crownY, crown.validity == .valid, let top = crown.value else { return false }
            return wrist.y - top >= height * LaserLiveRoundGeometryV1.diamondOverheadClearanceShare
        }
        guard let center = geometry?.centerX, center.validity == .valid, let x = center.value else { return false }
        return abs(wrist.x - x) >= height * LaserLiveRoundGeometryV1.diamondMinimumLateralReachShare
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

    /// What the last packet's vault evaluation saw, per zone and wrist (diagnostics only, from the
    /// same conditions the judge used): why a wrist was unavailable, its distance to the (shifted)
    /// zone centre, and whether that zone's press was emitted.
    struct VaultReadout: Sendable, Equatable {
        let playerID: PlayerID
        let button: LaserVaultButton
        let wrist: LaserContactWrist
        /// The wrist in the unmirrored plane, when it had one.
        let point: WristPlanePoint?
        /// The zone centre as judged (approved place + shift) and its radius.
        let center: WristPlanePoint
        let radius: Double
        let distance: Double?
        /// "inside", "outside", or the unavailable reason.
        let status: String
        var pressed = false
    }
    private(set) var lastVaultReadout: [VaultReadout] = []

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

    /// Body overlaps are sampled by the attached scene after steering. The game still owns
    /// phase admission, target eligibility, scoring and replacement.
    mutating func receiveBodyContacts(_ contacts: [UUID: Set<PlayerID>], context: BodyInputContext,
                                      atHostTime: Double, game: inout LaserGame) throws {
        let time = game.gameTime
        let active = game.activeDiamonds
        let collected = active.filter { spawn in
            guard let deadline = game.diamonds[spawn.id]?.interactionDeadline,
                  time >= spawn.entry, time < deadline, let players = contacts[spawn.id] else { return false }
            return spawn.eligiblePlayers.contains { player in
                players.contains(player) && (context.calibrationRevisions[player] ?? 0) > 0
            }
        }
        guard !collected.isEmpty else { return }
        let ids = Set(collected.map(\.id))
        var replacements: [LaserDiamondSpawn] = []
        if game.roundPhase == .diamondTime,
           let deadline = game.diamonds[collected[0].id]?.interactionDeadline {
            replacements = try planner.bonusReplacements(collected: collected,
                surviving: active.filter { !ids.contains($0.id) }, at: time, deadline: deadline)
        }
        try game.collectDiamonds([], generation: context.sessionGeneration, calibrationRevisions: context.calibrationRevisions,
            capturedAt: time, arrivedAt: time, replacements: replacements, bodyContacts: contacts)
        try refresh(game: game, context: context, atHostTime: atHostTime)
    }

    /// - Parameter vaultZoneShifts: live rounds with mascots (`GameSessionCoordinator`): how far
    ///   each player's vault zones sit from their approved place for THIS capture (unmirrored
    ///   plane, game units, added to X): the player's own body centre and the mascot's distance from
    ///   its button console. A non-finite shift means the zone cannot be placed for this capture:
    ///   that player's wrists are UNAVAILABLE for it. Absent: the approved zones as they are.
    @discardableResult
    mutating func receive(_ snapshot: BodySnapshot, context current: BodyInputContext,
                          atHostTime hostTime: Double, capturedGameTime: Double,
                          arrivedGameTime: Double, game: inout LaserGame,
                          vaultZoneShifts: [PlayerID: Double] = [:]) throws -> [LaserContactActivation] {
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
                    guard hypot(xy.x - spawn.position.x, xy.y - spawn.position.y) <= configuration.radius else {
                        hands[hand] = .outside; continue
                    }
                    hands[hand] = configuration.admitsReach(xy, to: spawn.position, player: player,
                        geometry: snapshot.players[player]?.geometry) ? .inside : .unavailable
                }
            }
            locations[spawn.id] = hands
        }
        var readout: [VaultReadout] = []
        if let open = next.vault, nextGame.roundPhase == .vault {
            for zone in open.zones.values {
                var hands: [LaserContactHand: LaserContactLocation] = [:]
                let admitted = current.acceptsWristContact(snapshot, playerID: zone.playerID, at: hostTime,
                    afterFrameID: next.lastFrame, afterCapturedAt: afterCapture)
                let shift = vaultZoneShifts[zone.playerID] ?? 0
                let center = WristPlanePoint(x: zone.position.x + (shift.isFinite ? shift : 0), y: zone.position.y)
                for wrist in LaserContactWrist.allCases {
                    let hand = LaserContactHand(playerID: zone.playerID, wrist: wrist)
                    func note(_ status: String, _ point: WristPlanePoint? = nil, _ distance: Double? = nil) {
                        readout.append(VaultReadout(playerID: zone.playerID, button: zone.button, wrist: wrist, point: point,
                                                    center: center, radius: zone.radius, distance: distance, status: status))
                    }
                    guard admitted else { hands[hand] = .unavailable; note("UNAVAILABLE: packet not admitted (stale, unbound, rebind or context)"); continue }
                    guard let a = next.vaultActivation, snapshot.frameID > a.frame, snapshot.capturedAt > a.hostTime else {
                        hands[hand] = .unavailable; note("UNAVAILABLE: before the gate's activation"); continue
                    }
                    guard let p = snapshot.wristContact?.players[zone.playerID] else {
                        hands[hand] = .unavailable; note("UNAVAILABLE: no wrist evidence"); continue
                    }
                    let observation = wrist == .left ? p.left : p.right
                    if let refusal = observation.observationRefusal { hands[hand] = .unavailable; note("UNAVAILABLE: \(refusal)"); continue }
                    if let refusal = observation.contactRefusal { hands[hand] = .unavailable; note("UNAVAILABLE: \(refusal)"); continue }
                    guard shift.isFinite else { hands[hand] = .unavailable; note("UNAVAILABLE: zone unplaceable (no body centre or mascot position)"); continue }
                    guard let xy = observation.playerPlane else { hands[hand] = .unavailable; note("UNAVAILABLE: no plane position"); continue }
                    let distance = hypot(xy.x - center.x, xy.y - center.y)
                    let inside = distance <= zone.radius
                    hands[hand] = inside ? .inside : .outside
                    note(inside ? "inside" : "outside", xy, distance)
                }
                locations[zone.targetID] = hands
            }
        }
        // Invalid/missing/stale wrists feed UNAVAILABLE, clearing only their own pending entry.
        // Original host eligibility is separate from active GameClock eligibility below.
        let allContacts = try next.entries.evaluate(lifetime: lifetime, frameID: snapshot.frameID,
            capturedAt: capturedGameTime, arrivedAt: arrivedGameTime, locations: locations)
        if let open = next.vault {
            let pressedZones = Set(allContacts.compactMap { open.zones[$0.targetID].map { "\($0.playerID.rawValue).\($0.button.rawValue)" } })
            for i in readout.indices where pressedZones.contains("\(readout[i].playerID.rawValue).\(readout[i].button.rawValue)") {
                readout[i].pressed = true
            }
        }
        next.lastVaultReadout = readout
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
