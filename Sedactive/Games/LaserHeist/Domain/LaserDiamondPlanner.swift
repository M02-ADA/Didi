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
                                   excluding positions: [LaserDiamondPosition],
                                   avoiding wrists: (points: [LaserDiamondPosition], radius: Double)? = nil) throws -> LaserDiamondSpawn {
        let available = placements.filter { !positions.contains($0.position) }
        try requireLaserValue(!available.isEmpty && sequence < 0xffffffffffff, "placement/identity exhausted")
        let preferred = wrists.map { wrists in
            available.filter { placement in
                wrists.points.allSatisfy {
                    hypot($0.x - placement.position.x, $0.y - placement.position.y) > wrists.radius
                }
            }
        } ?? available
        // A replacement is still due when every legal zone overlaps a collecting wrist.
        let candidates = preferred.isEmpty ? available : preferred
        let placement = candidates[Int(random() % UInt64(candidates.count))]
        return try spawn(placement, at: time, entry: entry, exit: exit)
    }

    private mutating func spawn(_ placement: LaserDiamondPlacement, at time: Double, entry: Double, exit: Double) throws -> LaserDiamondSpawn {
        try requireLaserValue(sequence < 0xffffffffffff, "diamond identity exhausted")
        sequence += 1
        let id = UUID(uuidString: String(format: "D1A00000-0000-4000-8000-%012llX", sequence))!
        return try LaserDiamondSpawn(id: id, position: placement.position, eligiblePlayers: placement.eligiblePlayers,
                                     spawnedAt: time, entry: entry, exit: exit)
    }

    mutating func normalMinute(_ minute: Int, from start: Double, until boundary: Double) throws -> [LaserDiamondSpawn] {
        try requireLaserValue((0..<5).contains(minute) && start.isFinite && boundary.isFinite && start >= 0
            && boundary - start > approachLead + passageDuration, "normal diamond segment")
        var next = self
        // Diamond passages may overlap laser crossings, giving players a choice of action.
        let minimum = 8 + minute * 3
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

    /// Keep empty slots when the board has no safe placement for this input frame.
    mutating func refillPawBoard(at time: Double, deadline: Double, roster: Set<PlayerID>,
                                active: [LaserDiamondSpawn], recent: [LaserDiamondPosition],
                                paws: [LaserDiamondPosition]) throws -> [LaserDiamondSpawn] {
        guard active.count < LaserRoundConfiguration.initialBonusDiamondCount else { return [] }
        var occupied = active.map(\.position)
        var spawns: [LaserDiamondSpawn] = []
        let positions = LaserDiamondTimeBoard.positions(solo: roster.count == 1)
        while occupied.count < LaserRoundConfiguration.initialBonusDiamondCount {
            let safe = positions.filter { candidate in
                !recent.contains(candidate)
                    && occupied.allSatisfy { LaserDiamondTimeBoard.distance($0, candidate) >= LaserDiamondTimeBoard.interDiamondSpacing }
                    && paws.allSatisfy { LaserDiamondTimeBoard.distance($0, candidate) >= LaserDiamondTimeBoard.spawnClearance }
            }
            guard !safe.isEmpty else { break }
            let position = safe[Int(random() % UInt64(safe.count))]
            let placement = LaserDiamondPlacement(position: position, eligiblePlayers: roster)
            spawns.append(try spawn(placement, at: time, entry: time, exit: deadline))
            occupied.append(position)
        }
        return spawns
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
                                    at time: Double, deadline: Double,
                                    avoiding wrists: (points: [LaserDiamondPosition], radius: Double)? = nil) throws -> [LaserDiamondSpawn] {
        try requireLaserValue(collected.count + surviving.count <= 4, "bonus replacement slots")
        var next = self
        var result: [LaserDiamondSpawn] = []
        for old in collected {
            result.append(try next.makeSpawn(at: time, entry: time, exit: deadline,
                excluding: surviving.map(\.position) + result.map(\.position) + [old.position], avoiding: wrists))
        }
        self = next
        return result
    }
}
