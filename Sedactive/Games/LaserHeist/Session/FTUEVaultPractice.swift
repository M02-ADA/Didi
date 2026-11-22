import Foundation
import Observation

/// Owns a single pre-round gate opportunity. The live session lends only read-only input.
@MainActor @Observable
final class FTUEVaultPractice {
    struct Inputs {
        let round: FTUEDiamondTimeSession.Inputs
        let zones: [LaserVaultZone]
    }

    let inputs: Inputs
    let presentationID = UUID()
    private let vaultID = UUID()
    @ObservationIgnored private var game: LaserGame
    private(set) var vault: LaserVaultState?
    @ObservationIgnored private var clock: GameClock
    @ObservationIgnored private var consumer: LaserWristDiamondConsumer
    @ObservationIgnored private var lastTick: Double
    private(set) var events: [GameEvent] = []
    private(set) var openedAt: Double?
    private(set) var failedAt: Double?

    init(inputs: Inputs, at now: Double) throws {
        let round = inputs.round
        try requireLaserValue(round.context.wristContact != nil && round.configuration.missionGateTarget > 1
            && Set(inputs.zones.map(\.playerID)) == Set(round.roster)
            && Set(round.context.calibrationRevisions.keys) == Set(round.roster), "tutorial vault inputs")
        self.inputs = inputs
        clock = try GameClock(sourceTime: now)
        lastTick = now
        var game = try LaserGame(configuration: round.configuration, context: round.context, historyCapacityPerPlayer: 1)
        #if DEBUG
        if round.roster == [.player1] { game.soloPracticePlayer = .player1 }
        #endif
        try game.openVault(id: vaultID, at: clock.gameTime)
        consumer = try LaserWristDiamondConsumer(configuration: round.diamonds, context: round.context,
                                                  lifetime: presentationID, afterCapturedAt: now)
        try consumer.openVault(id: vaultID, zones: inputs.zones, game: game, atHostTime: now)
        self.game = game
        vault = game.vault
        collectEvents(self.game.drainEvents())
    }

    var didOpen: Bool { game.vault?.id == vaultID && game.vault?.opened == true && openedAt != nil }
    var state: LaserGameState { state(health: nil) }

    func state(health: Int?) -> LaserGameState {
        var state = LaserGameState(sessionGeneration: presentationID, phase: game.roundPhase,
                                   gameTime: max(clock.gameTime, game.gameTime), activityProgress: 0, teamHealth: health ?? game.teamHealth,
                                   teamScore: game.teamScore, encounters: [])
        state.vault = vault
        return state
    }

    func suspend(at now: Double) {
        guard clock.isRunning else { return }
        try? clock.pause(at: lastTick)
        consumer.invalidate(atHostTime: now)
    }

    func update(at now: Double, snapshot: BodySnapshot?, zoneShifts: [PlayerID: Double]) throws {
        let resumed = !clock.isRunning
        if resumed { try clock.resume(at: now) }
        try clock.advance(to: now)
        lastTick = now
        guard openedAt == nil, failedAt == nil else { return }
        // Record the reactivation watermark even if the first resumed frame has no usable packet.
        if resumed { try consumer.refresh(game: game, context: inputs.round.context, atHostTime: now) }
        var next = game
        // Re-anchoring on resume can round the same active time down by an ulp.
        let time = max(clock.gameTime, game.gameTime)
        if let snapshot, snapshot.sessionGeneration == inputs.round.context.sessionGeneration,
           snapshot.cameraGeometryRevision == inputs.round.context.cameraGeometryRevision,
           let capture = clock.gameTime(forCaptureTime: snapshot.capturedAt) {
            _ = try consumer.receive(snapshot, context: inputs.round.context, atHostTime: now,
                capturedGameTime: capture, arrivedGameTime: time, game: &next,
                vaultZoneShifts: zoneShifts)
        }
        try next.advance(to: time)
        let updates = next.drainEvents()
        game = next
        if next.vault != vault { vault = next.vault }
        collectEvents(updates)
    }

    private func collectEvents(_ updates: [GameEvent]) {
        for event in updates {
            if case .coopGateSucceeded(let id, _) = event.kind, id == vaultID { openedAt = event.gameTime }
            if case .coopGateFailed(let id) = event.kind, id == vaultID { failedAt = event.gameTime }
            events.append(GameEvent(id: event.id, sessionGeneration: presentationID,
                sequence: event.sequence, gameTime: event.gameTime, kind: event.kind))
        }
    }
}
