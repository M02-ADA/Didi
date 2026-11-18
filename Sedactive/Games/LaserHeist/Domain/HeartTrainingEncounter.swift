import Foundation

/// Proof of a scripted instructional deduction, NEVER a normal collision verdict.
nonisolated struct HeartTrainingDamage: Equatable, Sendable {
    let id: UUID
    let generation: UUID
    let players: Set<PlayerID>
    let remainingHealth: Int
}

/// A bounded training round. The existing render host supplies source timestamps; no timer,
/// input subscription, ordinary encounter schedule, scoring or second GameClock is installed.
nonisolated struct HeartTrainingEncounter {
    static let crossingTime = 1.8
    let id: UUID
    let context: BodyInputContext
    let roster: Set<PlayerID>
    private var game: LaserGame
    private var anchor: Double?
    private(set) var elapsed = 0.0
    private(set) var events: [GameEvent] = []
    private(set) var damage: HeartTrainingDamage?
    private(set) var feedbackFinished = false
    private(set) var invalidated = false

    init(configuration: LaserRoundConfiguration, context: BodyInputContext, roster: Set<PlayerID>, id: UUID = UUID()) throws {
        try requireLaserValue(!roster.isEmpty && roster.allSatisfy { context.calibrationRevisions[$0] != nil }, "training roster")
        self.id = id; self.context = context; self.roster = roster
        game = try .heartTraining(configuration: configuration, context: context, id: id)
    }
    var state: LaserGameState {
        LaserGameState(sessionGeneration: context.sessionGeneration, phase: .activity, gameTime: elapsed,
            activityProgress: 0, teamHealth: game.teamHealth, teamScore: game.teamScore, encounters: [])
    }
    mutating func update(at now: Double, eligible: Bool, context current: BodyInputContext?) {
        guard !invalidated, !feedbackFinished else { return }
        guard current == context else { invalidated = true; anchor = nil; return }
        guard eligible, now.isFinite, now >= 0 else { anchor = nil; return }
        if let previous = anchor, now < previous { return }
        defer { anchor = now }
        guard let previous = anchor, now >= previous else { return }
        // A stalled/background render callback cannot jump over the visible approach.
        guard now - previous <= 0.25 else { return }
        elapsed = min(Self.crossingTime, elapsed + now - previous)
        if elapsed >= Self.crossingTime, damage == nil {
            try? game.advance(to: Self.crossingTime)
            damage = game.commitHeartTrainingDamage(id: id, players: roster)
            events = game.drainEvents()
        }
    }
    mutating func finishFeedback(id: UUID, generation: UUID) {
        guard !invalidated, damage?.id == id, context.sessionGeneration == generation else { return }
        feedbackFinished = true
    }
}
