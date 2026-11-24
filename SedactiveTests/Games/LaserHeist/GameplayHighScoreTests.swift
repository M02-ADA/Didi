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
            for outcome in [LaserRoundOutcome.completed, .healthDepleted] {
                let round = summary(100, outcome)
                store.record(round, isNormalGameplay: false)
                #expect(store.record(for: round.sessionGeneration) == nil)
            }
            for outcome in [LaserRoundOutcome.aborted, .technicalInterruption, .vaultFailed] {
                let round = summary(100, outcome)
                store.record(round, isNormalGameplay: true)
                #expect(store.record(for: round.sessionGeneration) == nil)
            }
            #expect(GameplayHighScore(defaults: defaults).highScore == 0)
        }
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) throws {
        let suite = "GameplayHighScoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    private func summary(_ score: Int, _ outcome: LaserRoundOutcome) -> RoundSummary {
        RoundSummary(sessionGeneration: UUID(), outcome: outcome, gameDuration: 30,
                     activityDuration: 20, remainingTeamHealth: outcome == .healthDepleted ? 0 : 1,
                     teamScore: score, targets: [], diamondsCollected: 0, vaultsOpened: 0,
                     withdrawnAttempts: 0, playerResults: [], coopResults: [],
                     missionProgress: 0, missionTarget: 5, primaryPlayerID: nil)
    }
}
