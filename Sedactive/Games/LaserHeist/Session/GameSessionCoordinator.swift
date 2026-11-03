//
//  GameSessionCoordinator.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation
import Observation

/// Single replay driver. Frame host supplies absolute synthetic source time; no camera lifecycle.
@MainActor @Observable
final class GameSessionCoordinator {
    let script: LaserReplayScript
    private(set) var phase: SessionState = .idle
    private(set) var state: LaserGameState?
    private(set) var summary: RoundSummary?
    private(set) var results: [ReplayTargetResult] = []
    private(set) var latestSnapshot: BodySnapshot?
    private var provider: ReplayBodyInput?
    private var iterator: AsyncStream<BodySnapshot>.Iterator?
    private var clock: GameClock?
    private var game: LaserGame?
    private var cursor = 0
    private var committed: Set<UUID> = []
    private var advancing = false

    init(script: LaserReplayScript) { self.script = script }

    func start() async throws {
        guard phase == .idle else { return }
        let input = try ReplayBodyInput(fixture: script.input)
        try await input.start(configuration: script.input.configuration)
        let stream = try input.snapshotStream(generation: script.input.configuration.sessionGeneration)
        guard let context = input.currentContext else { throw LaserDataError.invalidValue("missing replay context") }
        var engine = try LaserGame(configuration: script.configuration, context: context, historyCapacityPerPlayer: 120)
        for encounter in script.encounters { try engine.register(encounter) }
        provider = input
        iterator = stream.makeAsyncIterator()
        clock = try GameClock(sourceTime: 0)
        game = engine
        phase = .running
        refresh(at: 0)
    }

    /// Serialized absolute-time updates: large frames still process every delivery/deadline in order.
    func advance(to sourceTime: Double) async throws {
        guard phase == .running, !advancing else { return }
        advancing = true
        defer { advancing = false }
        guard let provider, var clock, var game, var iterator else { return }
        let time = min(sourceTime, script.duration)
        try requireLaserValue(time.isFinite && time >= clock.gameTime, "replay frame time")
        while cursor < script.input.records.count, script.input.records[cursor].deliveredAt <= time {
            let record = script.input.records[cursor]
            // Snapshot-only, compatible scripted source; drain each packet before advancing again.
            try provider.advance(to: record.deliveredAt)
            guard let packet = await iterator.next(isolation: MainActor.shared) else { throw LaserDataError.invalidValue("replay ended early") }
            guard phase == .running, !Task.isCancelled else { return }
            try clock.advance(to: record.deliveredAt)
            guard let captured = clock.gameTime(forCaptureTime: packet.capturedAt) else {
                throw LaserDataError.invalidValue("unmapped replay capture")
            }
            try game.receive(packet, capturedGameTime: captured, arrivedAt: clock.gameTime)
            latestSnapshot = packet
            cursor += 1
        }
        try clock.advance(to: time)
        try game.advance(to: clock.gameTime)
        self.clock = clock
        self.game = game
        self.iterator = iterator
        refresh(at: time)
        if time == script.duration || state?.teamHealth == 0 {
            let outcome: LaserRoundOutcome = state?.teamHealth == 0 ? .healthDepleted : .completed
            summary = RoundSummary(sessionGeneration: script.input.configuration.sessionGeneration, outcome: outcome,
                gameDuration: time, activityDuration: time, remainingTeamHealth: state?.teamHealth ?? 5,
                teamScore: state?.teamScore ?? 0,
                targets: PlayerID.allCases.map { player in
                    let values = results.filter { $0.playerID == player }.map(\.judgement)
                    return LaserPlayerTargetCounts(playerID: player, scheduled: script.encounters.count,
                        cleared: values.filter { $0 == .clear }.count,
                        hit: values.filter { if case .hit = $0 { true } else { false } }.count,
                        unavailable: values.filter { if case .unavailable = $0 { true } else { false } }.count)
                }, diamondsCollected: 0, vaultsOpened: 0, withdrawnAttempts: 0)
            phase = .finished
            refresh(at: time)
            await provider.stop()
        }
    }

    func stop() async {
        phase = .finished
        game?.exit()
        await provider?.stop()
        iterator = nil
    }

    func fail(_ error: any Error) async {
        await stop()
        phase = .failed(String(describing: error))
    }

    private func refresh(at time: Double) {
        guard let game else { return }
        var encounters: [LaserEncounterState] = []
        for encounter in script.encounters {
            var verdicts: [PlayerID: Judgement] = [:]
            for target in encounter.targets {
                let key = LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: target.playerID)
                verdicts[target.playerID] = game.judgement(for: key) ?? .pending(.awaitingFinalization)
            }
            let finalized = verdicts.values.allSatisfy { if case .pending = $0 { false } else { true } }
            if finalized, committed.insert(encounter.id).inserted {
                for player in PlayerID.allCases {
                    let key = LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: player)
                    var frame: UInt64?
                    if case .selected(let evidence) = game.selection(for: key) { frame = evidence.snapshot.frameID }
                    results.append(ReplayTargetResult(encounterID: encounter.id, playerID: player,
                                                     judgement: verdicts[player]!, selectedFrameID: frame))
                }
            }
            encounters.append(LaserEncounterState(encounter: encounter, judgements: verdicts,
                                                  effectsCommitted: committed.contains(encounter.id)))
        }
        state = LaserGameState(sessionGeneration: script.input.configuration.sessionGeneration,
            phase: summary.map { .ended($0.outcome) } ?? .activity, gameTime: time, activityProgress: time,
            teamHealth: game.teamHealth, teamScore: game.teamScore, encounters: encounters)
    }
}
