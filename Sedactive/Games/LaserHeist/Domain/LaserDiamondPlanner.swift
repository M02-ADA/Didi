import Foundation

/// Reviewed placement catalogs are injected. This planner does not derive reach or camera coordinates.
nonisolated struct LaserDiamondPlacement: Equatable, Sendable {
    let position: LaserDiamondPosition
    let eligiblePlayers: Set<PlayerID>
}

/// Stable seeded game planning, not a random source shared with Vision or rendering.
nonisolated struct LaserDiamondPlanner: Sendable {
    private var randomState: UInt64
    private var sequence: UInt64 = 0
    let placements: [LaserDiamondPlacement]
    let approachLead: Double
    let passageDuration: Double

    init(seed: UInt64, placements: [LaserDiamondPlacement], approachLead: Double, passageDuration: Double) throws {
        try requireLaserValue(placements.count >= 5 && placements.allSatisfy { !$0.eligiblePlayers.isEmpty }
            && approachLead.isFinite && approachLead > 0 && passageDuration.isFinite && passageDuration > 0,
                              "diamond planner configuration")
        for (index, placement) in placements.enumerated() {
            try requireLaserValue(!placements.prefix(index).contains { $0.position == placement.position },
                                  "duplicate placement")
        }
        self.randomState = seed
        self.placements = placements
        self.approachLead = approachLead
        self.passageDuration = passageDuration
    }

    private mutating func random() -> UInt64 {
        randomState &+= 0x9e3779b97f4a7c15
        var value = randomState
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }

    /// IDs are monotonic within this round. The domain can reject retired IDs without retaining all of them.
    private mutating func makeSpawn(at time: Double, entry: Double, exit: Double,
                                   excluding positions: [LaserDiamondPosition]) throws -> LaserDiamondSpawn {
        let available = placements.filter { !positions.contains($0.position) }
        try requireLaserValue(!available.isEmpty && sequence < 0xffffffffffff, "placement/identity exhausted")
        let placement = available[Int(random() % UInt64(available.count))]
        sequence += 1
        let id = UUID(uuidString: String(format: "D1A00000-0000-4000-8000-%012llX", sequence))!
        return try LaserDiamondSpawn(id: id, position: placement.position, eligiblePlayers: placement.eligiblePlayers,
                                     spawnedAt: time, entry: entry, exit: exit)
    }

    mutating func normalMinute(_ minute: Int, from start: Double, until boundary: Double) throws -> [LaserDiamondSpawn] {
        try requireLaserValue((0..<5).contains(minute) && start.isFinite && boundary.isFinite && start >= 0
            && boundary - start > approachLead + passageDuration, "normal diamond segment")
        var next = self
        let minimum = 2 + minute * 2
        let count = minimum + Int(next.random() % 3)
        let available = boundary - start - approachLead - passageDuration
        var result: [LaserDiamondSpawn] = []
        for index in 0..<count {
            let time = start + available * Double(index + 1) / Double(count + 1)
            result.append(try next.makeSpawn(at: time, entry: time + approachLead,
                exit: time + approachLead + passageDuration,
                excluding: result.filter { $0.exit > time }.map(\.position)))
        }
        self = next
        return result
    }

    mutating func bonusInitial(at time: Double, deadline: Double) throws -> [LaserDiamondSpawn] {
        var next = self
        var result: [LaserDiamondSpawn] = []
        for _ in 0..<LaserRoundConfiguration.initialBonusDiamondCount {
            result.append(try next.makeSpawn(at: time, entry: time, exit: deadline, excluding: result.map(\.position)))
        }
        self = next
        return result
    }

    /// Pair results in the caller's stable collection order; replacements exist immediately.
    mutating func bonusReplacements(collected: [LaserDiamondSpawn], surviving: [LaserDiamondSpawn],
                                    at time: Double, deadline: Double) throws -> [LaserDiamondSpawn] {
        try requireLaserValue(collected.count + surviving.count <= 4, "bonus replacement slots")
        var next = self
        var result: [LaserDiamondSpawn] = []
        for old in collected {
            result.append(try next.makeSpawn(at: time, entry: time, exit: deadline,
                excluding: surviving.map(\.position) + result.map(\.position) + [old.position]))
        }
        self = next
        return result
    }
}
