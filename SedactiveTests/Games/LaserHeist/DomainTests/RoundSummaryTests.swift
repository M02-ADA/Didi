import Foundation
import Testing
@testable import Sedactive

nonisolated struct RoundSummaryTests {
    private func setup() throws -> (LaserReplayScenario, LaserGame) {
        let scenario = try LaserReplayScenarios.make()[0]
        let context = BodyInputContext(sessionGeneration: scenario.input.configuration.sessionGeneration,
            cameraGeometryRevision: 1, calibrationRevisions: [.player1: 1, .player2: 1], cutovers: [:], isActive: true)
        let config = try LaserRoundConfiguration(evidenceTiming: scenario.configuration.evidenceTiming,
            clearanceMargin: 0.01, diamondPoints: nil, actionCueLead: 1.4)
        return (scenario, try LaserGame(configuration: config, context: context, historyCapacityPerPlayer: 120))
    }

    @Test func clearWithoutCycleEventsCannotCreateJumpCyclesAndSummaryFreezes() throws {
        let (scenario, initial) = try setup()
        var game = initial
        try game.register(scenario.encounter)
        try game.receive(#require(scenario.input.records[0].snapshot), capturedGameTime: 10, arrivedAt: 10.05)
        try game.advance(to: 10.35)
        for player in PlayerID.allCases {
            try game.recordTrackedInterval(playerID: player, from: 8, to: 10, observedAt: 10.35)
        }
        game.exit()
        let summary = try #require(game.summary)
        #expect(summary.outcome == .aborted)
        #expect(summary.teamScore == game.teamScore)
        #expect(summary.remainingTeamHealth == game.teamHealth)
        #expect(summary.gameDuration == game.gameTime)
        #expect(summary.primaryPlayerID == nil)
        for player in summary.playerResults {
            #expect(player.successfulHighAvoidances == 1)
            #expect(player.successfulLowAvoidances == 0)
            #expect(player.validatedJumpCycles == nil)
            #expect(abs(try #require(player.movementChallengeSeconds) - 1.4) < 1e-9)
        }
        try game.advance(to: 50)
        game.exit(outcome: .completed)
        #expect(game.summary == summary)
        #expect(game.drainEvents().filter { if case .roundEnded = $0.kind { true } else { false } }.count == 1)
    }

    @Test func overlappingWindowsAndCoverageDoNotDoubleCountRequestedTime() throws {
        let (scenario, initial) = try setup()
        var game = initial
        try game.register(scenario.encounter)
        let second = try LaserEncounter(id: UUID(uuidString: "17000000-0000-4000-8000-000000000001")!,
            attemptID: UUID(uuidString: "17000000-0000-4000-8000-000000000002")!,
            targets: scenario.encounter.targets.map {
                try LaserTarget(playerID: $0.playerID, calibrationRevision: 1, requiredMove: .duck, beam: $0.beam,
                                warningTime: 7.25, crossingTime: 10.25)
            })
        try game.register(second)
        try game.receive(#require(scenario.input.records[0].snapshot), capturedGameTime: 10, arrivedAt: 10.05)
        try game.advance(to: 11)
        for _ in 0..<2 { try game.recordTrackedInterval(playerID: .player1, from: 8, to: 10.25, observedAt: 11) }
        game.exit()
        let player = try #require(game.summary?.playerResults.first)
        #expect(player.successfulHighAvoidances == 2)
        #expect(abs(try #require(player.movementChallengeSeconds) - 1.65) < 1e-9)
        #expect(game.summary?.playerResults.last?.movementChallengeSeconds == nil)
    }

    @Test func pausedSourceTimeIsExcludedAndWithdrawnChallengeClosesAtPause() throws {
        let (scenario, initial) = try setup()
        var game = initial
        var clock = try GameClock(sourceTime: 100)
        try game.register(scenario.encounter)
        try clock.pause(at: 109)
        try game.advance(to: clock.gameTime)
        try game.recordTrackedInterval(playerID: .player1, from: 8, to: 9, observedAt: 9)
        game.pause()
        try clock.advance(to: 119)
        try clock.resume(at: 119)
        game.resume()
        try clock.advance(to: 120)
        try game.advance(to: clock.gameTime)
        try game.recordTrackedInterval(playerID: .player1, from: 9, to: 10, observedAt: 10)
        game.exit()
        let summary = try #require(game.summary)
        #expect(summary.gameDuration == 10) // Twenty source seconds minus ten paused seconds.
        #expect(summary.withdrawnAttempts == 1)
        #expect(abs(try #require(summary.playerResults.first?.movementChallengeSeconds) - 0.4) < 1e-9)
        #expect(summary.playerResults.first?.successfulHighAvoidances == 0)
    }

    @Test func failedVaultSummaryPreservesGameResultsAndUnavailableMetrics() throws {
        let (scenario, initial) = try setup()
        var game = initial
        try game.openVault(id: scenario.encounter.id, at: 0)
        try game.advance(to: 5)
        let summary = try #require(game.summary)
        #expect(summary.outcome == .vaultFailed)
        #expect(summary.gameDuration == 5)
        #expect(summary.activityDuration == 0)
        #expect(summary.remainingTeamHealth == 5)
        #expect(summary.missionProgress == 0)
        #expect(summary.coopResults.first?.outcome == .timedOut)
        #expect(summary.playerResults.allSatisfy { $0.validatedJumpCycles == nil && $0.movementChallengeSeconds == nil })
        #expect(LaserPlayerRoundResult.challengeTimeLimitation.contains("not measured physical activity"))
    }
}
