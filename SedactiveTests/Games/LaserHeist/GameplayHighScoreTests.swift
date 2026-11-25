import Foundation
import Testing
@testable import Sedactive

@MainActor
struct GameplayHighScoreTests {
    @Test func recordsStrictImprovementsAndKeepsEachRoundDecision() throws {
        try withDefaults { defaults in
            let store = GameplayHighScore(defaults: defaults)
            #expect(store.highScore == 0)

            let zero = summary(0, .healthDepleted)
            let first = summary(75, .healthDepleted)
            let equal = summary(75, .completed)
            let lower = summary(25, .healthDepleted)
            let higher = summary(100, .completed)
            for round in [zero, first, equal, lower, higher, first] {
                store.record(round, isNormalGameplay: true)
            }

            #expect(store.record(for: zero.sessionGeneration) == .init(highScore: 0, isNew: false))
            #expect(store.record(for: first.sessionGeneration) == .init(highScore: 75, isNew: true))
            #expect(store.record(for: equal.sessionGeneration) == .init(highScore: 75, isNew: false))
            #expect(store.record(for: lower.sessionGeneration) == .init(highScore: 75, isNew: false))
            #expect(store.record(for: higher.sessionGeneration) == .init(highScore: 100, isNew: true))

            let reopened = GameplayHighScore(defaults: defaults)
            #expect(reopened.highScore == 100)
            #expect(reopened.record(for: higher.sessionGeneration) == nil)
        }
    }

    @Test func ignoresPreviewsTutorialAndUnfinishedRounds() throws {
        try withDefaults { defaults in
            let store = GameplayHighScore(defaults: defaults)
            for outcome in [LaserRoundOutcome.completed, .healthDepleted, .vaultFailed] {
                let round = summary(100, outcome)
                store.record(round, isNormalGameplay: false)
                #expect(store.record(for: round.sessionGeneration) == nil)
            }
            for outcome in [LaserRoundOutcome.aborted, .technicalInterruption] {
                let round = summary(100, outcome)
                store.record(round, isNormalGameplay: true)
                #expect(store.record(for: round.sessionGeneration) == nil)
            }
            #expect(GameplayHighScore(defaults: defaults).highScore == 0)
        }
    }

    @Test func vaultTimeoutScoresSurviveReopeningAndOnlyStrictImprovementsWin() throws {
        try withDefaults { defaults in
            let store = GameplayHighScore(defaults: defaults)
            #expect(store.highScore == 0)

            let first = try vaultTimeout(collecting: 65)
            #expect(first.teamScore == 1625)
            store.record(first, isNormalGameplay: true)
            let record = try #require(store.record(for: first.sessionGeneration))
            #expect(record == .init(highScore: 1625, isNew: true))
            #expect(ResultsView.title(for: first.outcome, isNewHighScore: record.isNew) == "CONGRATULATIONS")

            let reopened = GameplayHighScore(defaults: defaults)
            #expect(reopened.highScore == 1625)
            for diamondCount in [12, 65] {
                let round = try vaultTimeout(collecting: diamondCount)
                #expect(round.teamScore == diamondCount * 25)
                reopened.record(round, isNormalGameplay: true)
                let unchanged = try #require(reopened.record(for: round.sessionGeneration))
                #expect(unchanged == .init(highScore: 1625, isNew: false))
                #expect(ResultsView.title(for: round.outcome, isNewHighScore: unchanged.isNew) == "Vault timed out")
                #expect(defaults.integer(forKey: GameplayHighScore.key) == 1625)
            }

            let higher = try vaultTimeout(collecting: 66)
            #expect(higher.teamScore == 1650)
            reopened.record(higher, isNormalGameplay: true)
            #expect(reopened.record(for: higher.sessionGeneration) == .init(highScore: 1650, isNew: true))
            #expect(GameplayHighScore(defaults: defaults).highScore == 1650)
        }
    }

    private func vaultTimeout(collecting count: Int) throws -> RoundSummary {
        // Each round needs its own generation. The domain awards every point
        // and generates the terminal summary when the unopened vault expires.
        let context = BodyInputContext(sessionGeneration: UUID(), cameraGeometryRevision: 1,
            calibrationRevisions: [.player1: 1, .player2: 1], cutovers: [:], isActive: true)
        let configuration = try LaserRoundConfiguration(
            evidenceTiming: LaserEvidenceTiming(windowBefore: 0.125, windowAfter: 0.125, deliveryAllowance: 0.125),
            clearanceMargin: 0.005, diamondPoints: LaserRoundConfiguration.approvedDiamondPoints)
        var game = try LaserGame(configuration: configuration, context: context, historyCapacityPerPlayer: 20)

        let vaultTime = Double(count) * 2
        for index in 0..<count {
            let time = Double(index) * 2
            let spawn = try LaserDiamondTests.spawn(index + 1, at: time, exit: time + 2)
            try game.advance(to: time)
            try game.spawnNormalDiamonds([spawn], beforeVaultAt: vaultTime)
            let accepted = try game.collectDiamonds([.init(targetID: spawn.id, hand: LaserDiamondTests.firstHand)],
                generation: context.sessionGeneration, calibrationRevisions: context.calibrationRevisions,
                capturedAt: time + 1, arrivedAt: time + 1)
            try #require(accepted.count == 1)
        }
        let scoreBeforeTimeout = game.teamScore
        try game.openVault(id: UUID(), at: vaultTime)
        try game.advance(to: vaultTime + configuration.vaultDuration)
        let summary = try #require(game.summary)
        #expect(summary.outcome == .vaultFailed)
        #expect(summary.teamScore == scoreBeforeTimeout)
        return summary
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "GameplayHighScoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func summary(_ score: Int, _ outcome: LaserRoundOutcome) -> RoundSummary {
        RoundSummary(sessionGeneration: UUID(), outcome: outcome, gameDuration: 30,
                     activityDuration: 20, remainingTeamHealth: outcome == .healthDepleted ? 0 : 1,
                     teamScore: score, targets: [], diamondsCollected: 0, vaultsOpened: 0,
                     withdrawnAttempts: 0, playerResults: [], coopResults: [],
                     missionProgress: 0, missionTarget: 5, primaryPlayerID: nil)
    }
}
