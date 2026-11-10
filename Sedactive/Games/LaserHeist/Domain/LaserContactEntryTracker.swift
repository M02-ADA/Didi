import Foundation

nonisolated enum LaserContactWrist: Int, CaseIterable, Sendable { case left, right }

/// Domain tie order only. This is not a producer-owned wrist measurement type.
nonisolated struct LaserContactHand: Hashable, Sendable {
    let playerID: PlayerID
    let wrist: LaserContactWrist

    static let ordered = PlayerID.allCases.flatMap { player in
        LaserContactWrist.allCases.map { Self(playerID: player, wrist: $0) }
    }
}

nonisolated enum LaserContactLocation: Equatable, Sendable {
    case outside, inside, unavailable
}

/// A domain interaction opportunity in GameClock time; no camera/rig coordinates.
nonisolated struct LaserContactTarget: Equatable, Sendable {
    let id: UUID
    let eligiblePlayers: Set<PlayerID>
    let activation: Double
    let deadline: Double

    init(id: UUID, eligiblePlayers: Set<PlayerID>, activation: Double, deadline: Double) throws {
        try requireLaserValue(!eligiblePlayers.isEmpty && activation.isFinite && deadline.isFinite
                              && activation >= 0 && deadline > activation, "contact target")
        self.id = id
        self.eligiblePlayers = eligiblePlayers
        self.activation = activation
        self.deadline = deadline
    }
}

nonisolated struct LaserContactActivation: Equatable, Sendable {
    let targetID: UUID
    /// Deterministic representative, not extra score or a physical activity metric.
    let hand: LaserContactHand
}

/// D09 outside→inside rule, fed with domain membership after input eligibility
/// and capture-time zone classification. No CP1 schema, coordinate mapping,
/// confidence threshold or live adapter is defined here. Synthetic fixtures can
/// exercise the approved behavior while Edo freezes the actual producer schema.
nonisolated struct LaserContactEntryTracker: Sendable {
    private struct Opportunity: Sendable {
        let target: LaserContactTarget
        var outside: [LaserContactHand: Double] = [:]
        var consumed = false
    }
    private struct Frame: Equatable, Sendable {
        let id: UInt64
        let capturedAt: Double
        let locations: [UUID: [LaserContactHand: LaserContactLocation]]
    }

    private var opportunities: [UUID: Opportunity] = [:]
    private var usedTargets: Set<UUID> = []
    /// A revocable domain interaction lifetime, not a substitute for CP1 source identity.
    private var lifetime: UUID
    private var capturedAfter: Double?
    private var newestCapture: Double?
    private var lastFrame: Frame?
    private var lastArrival = 0.0
    let maximumContactAge: Double

    init(lifetime: UUID, maximumContactAge: Double) throws {
        try requireLaserValue(maximumContactAge.isFinite && maximumContactAge > 0, "contact freshness")
        self.lifetime = lifetime
        self.maximumContactAge = maximumContactAge
    }

    /// New targets cannot consume an already processed frame. IDs are round-unique.
    mutating func replaceTargets(_ targets: [LaserContactTarget]) throws {
        try requireLaserValue(Set(targets.map(\.id)).count == targets.count
                              && targets.allSatisfy { !usedTargets.contains($0.id) }, "contact target identity")
        opportunities = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, Opportunity(target: $0)) })
        usedTargets.formUnion(targets.map(\.id))
    }

    /// Pause/source loss/rebind/calibration/Stop/Retry revoke transient entry.
    /// Committed target states remain consumed. A new source may restart frame IDs.
    mutating func invalidate(lifetime: UUID, capturedAfter: Double) throws {
        try requireLaserValue(capturedAfter.isFinite && capturedAfter >= 0
                              && (self.capturedAfter.map { capturedAfter >= $0 } ?? true), "contact cutover")
        self.lifetime = lifetime
        self.capturedAfter = capturedAfter
        newestCapture = nil
        lastFrame = nil
        for id in opportunities.keys { opportunities[id]?.outside.removeAll() }
    }

    /// Missing targets/hands mean UNAVAILABLE, never an implicit outside baseline.
    /// Caller supplies membership from the same validated capture, in game time.
    mutating func evaluate(lifetime: UUID, frameID: UInt64, capturedAt: Double, arrivedAt: Double,
                           locations: [UUID: [LaserContactHand: LaserContactLocation]]) throws
        -> [LaserContactActivation] {
        guard lifetime == self.lifetime else { return [] }
        try requireLaserValue(capturedAt.isFinite && arrivedAt.isFinite && capturedAt >= 0
                              && capturedAt <= arrivedAt && arrivedAt >= lastArrival, "contact timeline")
        let frame = Frame(id: frameID, capturedAt: capturedAt, locations: locations)
        if let lastFrame, frameID <= lastFrame.id {
            if frameID == lastFrame.id {
                try requireLaserValue(frame == lastFrame, "conflicting contact frame")
            }
            return []
        }
        lastArrival = arrivedAt
        lastFrame = frame
        guard capturedAfter.map({ capturedAt > $0 }) ?? true,
              newestCapture.map({ capturedAt > $0 }) ?? true else { return [] }
        newestCapture = capturedAt
        let fresh = arrivedAt - capturedAt <= maximumContactAge
        var result: [LaserContactActivation] = []
        // All target membership is evaluated before the caller applies any effects.
        for id in opportunities.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard var opportunity = opportunities[id], !opportunity.consumed else { continue }
            let target = opportunity.target
            guard fresh, capturedAt >= target.activation, capturedAt < target.deadline,
                  arrivedAt < target.deadline else {
                opportunity.outside.removeAll()
                opportunities[id] = opportunity
                continue
            }
            var entrants: [LaserContactHand] = []
            for hand in LaserContactHand.ordered where target.eligiblePlayers.contains(hand.playerID) {
                switch locations[id]?[hand] ?? .unavailable {
                case .unavailable: opportunity.outside.removeValue(forKey: hand)
                case .outside: opportunity.outside[hand] = capturedAt
                case .inside:
                    if let outside = opportunity.outside.removeValue(forKey: hand),
                       capturedAt > outside, capturedAt - outside <= maximumContactAge {
                        entrants.append(hand)
                    }
                }
            }
            if let first = entrants.first {
                opportunity.consumed = true
                opportunity.outside.removeAll()
                result.append(LaserContactActivation(targetID: id, hand: first))
            }
            opportunities[id] = opportunity
        }
        return result
    }
}
