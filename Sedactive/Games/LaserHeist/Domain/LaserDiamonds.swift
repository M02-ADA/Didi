import Foundation

/// Explicit domain placement; no image/rig mapping or physical reach is inferred.
nonisolated struct LaserDiamondPosition: Equatable, Sendable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) throws {
        try requireLaserValue(x.isFinite && y.isFinite, "diamond position")
        self.x = x
        self.y = y
    }
}

/// A planned approach and interaction passage, not an arbitrary expiry lifetime.
/// Coordinate/reach and actual trajectory approval remain integration prerequisites.
nonisolated struct LaserDiamondSpawn: Equatable, Sendable {
    let id: UUID
    let position: LaserDiamondPosition
    let eligiblePlayers: Set<PlayerID>
    let spawnedAt: Double
    let entry: Double
    /// Normal passage exit. Bonus eligibility uses the state's phase deadline.
    let exit: Double

    init(id: UUID, position: LaserDiamondPosition, eligiblePlayers: Set<PlayerID>,
         spawnedAt: Double, entry: Double, exit: Double) throws {
        try requireLaserValue(!eligiblePlayers.isEmpty && [spawnedAt, entry, exit].allSatisfy { $0.isFinite }
                              && spawnedAt >= 0 && spawnedAt < entry && entry < exit, "diamond passage")
        self.id = id
        self.position = position
        self.eligiblePlayers = eligiblePlayers
        self.spawnedAt = spawnedAt
        self.entry = entry
        self.exit = exit
    }
}

nonisolated enum LaserDiamondOutcome: Equatable, Sendable {
    case collected(hand: LaserContactHand, at: Double)
    case missed(at: Double)
    case closed
}

nonisolated enum LaserDiamondLifetime: Equatable, Sendable {
    case passage
    case diamondTime(deadline: Double)
}

nonisolated struct LaserDiamondState: Equatable, Sendable {
    let spawn: LaserDiamondSpawn
    let lifetime: LaserDiamondLifetime
    var outcome: LaserDiamondOutcome?

    var interactionDeadline: Double {
        switch lifetime {
        case .passage: spawn.exit
        case .diamondTime(let deadline): deadline
        }
    }
}

/// Owned only by LaserGame. No score, independent clock, random placement or input reader.
nonisolated struct LaserDiamondField: Sendable {
    private(set) var states: [UUID: LaserDiamondState] = [:]

    var active: [LaserDiamondSpawn] {
        states.values.filter { $0.outcome == nil }.map(\.spawn).sorted { $0.id.uuidString < $1.id.uuidString }
    }
    var collectedCount: Int {
        states.values.filter { if case .collected = $0.outcome { true } else { false } }.count
    }

    mutating func spawn(_ spawns: [LaserDiamondSpawn], at time: Double, before boundary: Double,
                        maximumActive: Int? = nil, bonusDeadline: Double? = nil) throws {
        try requireLaserValue(time.isFinite && boundary.isFinite && boundary > time
            && Set(spawns.map(\.id)).count == spawns.count
            && spawns.allSatisfy { spawn in
                states[spawn.id] == nil && spawn.spawnedAt == time
                    && (bonusDeadline.map { $0 == boundary && spawn.entry < $0 } ?? (spawn.exit <= boundary))
            },
                              "diamond spawn plan")
        let combined = active + spawns
        if let maximumActive {
            try requireLaserValue(combined.count <= maximumActive, "active diamond cap")
        }
        for (index, spawn) in combined.enumerated() {
            try requireLaserValue(!combined.prefix(index).contains { $0.position == spawn.position },
                                  "distinct diamond positions")
        }
        for spawn in spawns {
            states[spawn.id] = LaserDiamondState(spawn: spawn,
                lifetime: bonusDeadline.map { .diamondTime(deadline: $0) } ?? .passage)
        }
    }

    mutating func advance(to time: Double) {
        for id in states.keys {
            if let state = states[id], state.outcome == nil, state.lifetime == .passage, time >= state.spawn.exit {
                states[id]?.outcome = .missed(at: state.spawn.exit)
            }
        }
    }

    mutating func close() {
        for id in states.keys where states[id]?.outcome == nil { states[id]?.outcome = .closed }
    }

    /// Verified entry commands only. Exact capture/arrival eligibility is checked again.
    /// Build on a value copy so a rejected replacement plan cannot partially award.
    mutating func collect(_ contacts: [LaserContactActivation], capturedAt: Double, arrivedAt: Double,
                          replacements: [LaserDiamondSpawn], bonusDeadline: Double?) throws
        -> [LaserContactActivation] {
        var next = self
        next.advance(to: arrivedAt)
        var accepted: [LaserContactActivation] = []
        for spawn in next.active {
            guard let deadline = next.states[spawn.id]?.interactionDeadline,
                  capturedAt >= spawn.entry, capturedAt < deadline, arrivedAt < deadline else { continue }
            if let hand = LaserContactHand.ordered.first(where: { hand in
                spawn.eligiblePlayers.contains(hand.playerID)
                    && contacts.contains { $0.targetID == spawn.id && $0.hand == hand }
            }) {
                accepted.append(LaserContactActivation(targetID: spawn.id, hand: hand))
            }
        }
        if let bonusDeadline {
            try requireLaserValue(replacements.count == accepted.count && arrivedAt < bonusDeadline,
                                  "one replacement per bonus collection")
            for (contact, replacement) in zip(accepted, replacements) {
                try requireLaserValue(replacement.position != next.states[contact.targetID]?.spawn.position,
                                      "replacement must move position")
            }
        } else {
            try requireLaserValue(replacements.isEmpty, "no normal collection replacement")
        }
        for contact in accepted {
            next.states[contact.targetID]?.outcome = .collected(hand: contact.hand, at: arrivedAt)
        }
        if let bonusDeadline, !replacements.isEmpty {
            try next.spawn(replacements, at: arrivedAt, before: bonusDeadline, maximumActive: 4,
                           bonusDeadline: bonusDeadline)
        }
        self = next
        return accepted
    }
}
