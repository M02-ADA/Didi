import Foundation
import Observation

/// Owns only the bonus round that follows the authorized tutorial Vault handoff.
@MainActor @Observable
final class FTUEDiamondTimeSession {
    struct Inputs {
        let configuration: LaserRoundConfiguration
        let diamonds: LaserWristDiamondConfiguration
        let context: BodyInputContext
        let roster: [PlayerID]
    }

    let inputs: Inputs
    let presentationID = UUID()
    let events: [GameEvent]
    private(set) var entry: LaserFinalVaultEntry
    private(set) var game: LaserGame
    private(set) var paws: [LaserContactHand: LaserDiamondPosition] = [:]
    private var consumer: LaserWristDiamondConsumer
    private var entryStamp: Double?
    private var clock: GameClock?
    private var lastTick: Double?

    init(inputs: Inputs, at now: Double) throws {
        try requireLaserValue(inputs.context.wristContact != nil
            && Set(inputs.roster) == Set(inputs.context.calibrationRevisions.keys)
            && Set(inputs.roster) == Set(inputs.diamonds.standingHeights.keys), "tutorial Diamond Time roster")
        self.inputs = inputs
        entry = LaserFinalVaultEntry(roster: inputs.roster)
        var game = try LaserGame.tutorialDiamondTime(configuration: inputs.configuration, context: inputs.context)
        let renderGeneration = presentationID
        events = game.drainEvents().map {
            GameEvent(id: $0.id, sessionGeneration: renderGeneration, sequence: $0.sequence,
                      gameTime: $0.gameTime, kind: $0.kind)
        }
        self.game = game
        consumer = try LaserWristDiamondConsumer(configuration: inputs.diamonds, context: inputs.context,
                                                 lifetime: presentationID, afterCapturedAt: now)
        entryStamp = now
    }

    var isComplete: Bool { game.roundOutcome == .completed }
    var showsPawBoard: Bool { entry.isComplete && game.roundPhase == .diamondTime }

    func state(health: Int?) -> LaserGameState {
        LaserGameState(sessionGeneration: presentationID, phase: game.roundPhase,
                       gameTime: game.gameTime, activityProgress: game.activityProgress,
                       teamHealth: health ?? game.teamHealth, teamScore: game.teamScore, encounters: [])
    }

    func suspend(at now: Double) {
        entryStamp = nil
        guard var clock, clock.isRunning else { return }
        // Freeze at the last accepted tick. The next valid frame starts a new capture epoch.
        let cutoff = lastTick ?? now
        try? clock.pause(at: cutoff)
        self.clock = clock
        consumer.invalidate(atHostTime: now)
        paws = [:]
    }

    func update(at now: Double, snapshot: BodySnapshot?) throws {
        guard !isComplete else { return }
        if !entry.isComplete {
            entry.advance(by: now - (entryStamp ?? now))
            entryStamp = now
            guard entry.isComplete else { return }
            clock = try GameClock(sourceTime: now)
            lastTick = now
            consumer.invalidate(atHostTime: now)
            return
        }
        guard var clock else { return }
        if !clock.isRunning { try clock.resume(at: now) }
        try clock.advance(to: now)
        self.clock = clock
        lastTick = now

        var next = game
        if let snapshot, snapshot.sessionGeneration == inputs.context.sessionGeneration,
           snapshot.cameraGeometryRevision == inputs.context.cameraGeometryRevision, let capture = clock.gameTime(forCaptureTime: snapshot.capturedAt) {
            try consumer.receivePawBoard(snapshot, context: inputs.context, atHostTime: now,
                capturedGameTime: capture, arrivedGameTime: clock.gameTime, game: &next)
        }
        try next.advance(to: clock.gameTime)
        _ = next.drainEvents()
        if next.gameTime != game.gameTime || next.diamondsCollected != game.diamondsCollected { game = next }
        let visible = consumer.visiblePaws(at: now)
        if visible != paws { paws = visible }
    }
}
