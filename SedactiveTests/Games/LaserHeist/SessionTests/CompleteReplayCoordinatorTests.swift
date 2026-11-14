import Foundation
import Testing
@testable import Sedactive

@MainActor
struct CompleteReplayCoordinatorTests {
    private func run(_ script: LaserReplayScript, step: Double) async throws -> GameSessionCoordinator {
        let session = try LaserReplayDriver.makeSession(script: script)
        try await session.start()
        var time = 0.0
        while time < script.duration {
            try await session.advance(to: time)
            time += step
        }
        try await session.advance(to: script.duration)
        return session
    }

    @Test func fullCooperativeRoundRunsThroughTheProductionCoordinator() async throws {
        let script = try LaserReplayScript.complete(seed: 1)
        let plan = try #require(script.fullRound)
        let passages = plan.steps.compactMap { step -> LaserDiamondSpawn? in
            if case .normalDiamond(let spawn, _) = step.action { return spawn }
            return nil
        }
        let overlappingMoves = script.encounters.flatMap(\.targets).filter { target in
            passages.contains { spawn in
                spawn.eligiblePlayers.contains(target.playerID) && (spawn.entry..<spawn.exit).contains(target.crossingTime)
            }
        }.map(\.requiredMove)
        #expect(overlappingMoves.contains(.duck) && overlappingMoves.contains(.jump))
        let session = try await run(script, step: 0.25)
        let summary = try #require(session.summary)
        let normalCount = try #require(script.fullRound?.normalDiamondCount)
        #expect(session.isCompleteReplay && session.phase == .finished)
        #expect(summary.outcome == .completed && summary.remainingTeamHealth == 5 && summary.vaultsOpened == 5)
        #expect(summary.targets.allSatisfy { $0.scheduled == 50 && $0.cleared == 50 })
        #expect(session.results.count == 100 && session.results.allSatisfy { $0.judgement == .clear })
        #expect((70...80).contains(normalCount))
        #expect((normalCount + 4 ... normalCount + 8).contains(summary.diamondsCollected))
        #expect(summary.teamScore == 10_000 + 25 * summary.diamondsCollected)
        #expect(summary.diamondsCollected == session.diamondsCollected)
        #expect(abs(summary.gameDuration - 316) < 1e-8 && abs(summary.activityDuration - 310) < 1e-8)
        #expect(session.diamondStates.values.filter { $0.outcome == .closed }.count == 4)
        #expect(session.inputStatus == .stopped)
        #expect(session.events.filter { if case .roundEnded = $0.kind { true } else { false } }.count == 1)
    }

    @Test func largeFramesPreservePacketsActionsSelectedFramesAndAllEffects() async throws {
        let script = try LaserReplayScript.complete(seed: 7)
        let fine = try await run(script, step: 0.1)
        let skipped = try await run(script, step: 10_000)
        let fineSummary = try #require(fine.summary)
        let skippedSummary = try #require(skipped.summary)
        #expect(abs(fineSummary.activityDuration - skippedSummary.activityDuration) < 1e-8)
        #expect(fineSummary.outcome == skippedSummary.outcome && fineSummary.gameDuration == skippedSummary.gameDuration)
        #expect(fineSummary.teamScore == skippedSummary.teamScore && fineSummary.remainingTeamHealth == skippedSummary.remainingTeamHealth)
        #expect(fineSummary.diamondsCollected == skippedSummary.diamondsCollected && fineSummary.vaultsOpened == skippedSummary.vaultsOpened)
        #expect(fineSummary.targets == skippedSummary.targets && fineSummary.coopResults == skippedSummary.coopResults)
        #expect(fine.results == skipped.results)
        #expect(fine.events == skipped.events)
        #expect(fine.diamondStates == skipped.diamondStates)
        #expect(fine.summary?.playerResults.map(\.movementChallengeSeconds) == skipped.summary?.playerResults.map(\.movementChallengeSeconds))
    }

    @Test func standingPlayersLoseAllHealthThroughRealLaserJudgements() async throws {
        let script = try LaserReplayScript.complete(seed: 1, scenario: .healthDepleted)
        let session = try await run(script, step: 0.25)
        let summary = try #require(session.summary)
        #expect(summary.outcome == .healthDepleted)
        #expect(summary.remainingTeamHealth == 0 && summary.vaultsOpened == 0)
        #expect(!session.results.isEmpty)
        #expect(session.results.allSatisfy { result in
            if case .hit = result.judgement { return true }
            return false
        })
        #expect(summary.gameDuration < 60)
    }

    @Test func untouchedFirstVaultReachesItsDeadline() async throws {
        let script = try LaserReplayScript.complete(seed: 1, scenario: .vaultTimeout)
        let session = try await run(script, step: 0.25)
        let summary = try #require(session.summary)
        #expect(summary.outcome == .vaultFailed)
        #expect(summary.remainingTeamHealth == 5 && summary.vaultsOpened == 0)
        #expect(abs(summary.gameDuration - (60 + script.configuration.vaultDuration)) < 1e-8)
    }

    @Test func abortAndRetryDoNotReuseAPreviousRoundLifetime() async throws {
        let script = try LaserReplayScript.complete(seed: 1)
        let first = try LaserReplayDriver.makeSession(script: script)
        try await first.start()
        try await first.advance(to: 65)
        await first.stop()
        let frozen = try #require(first.summary)
        #expect(frozen.outcome == .aborted)
        let next = try script.freshRound(generation: UUID())
        let retry = try await run(next, step: 10_000)
        #expect(retry.summary?.outcome == .completed)
        #expect(retry.summary?.sessionGeneration != frozen.sessionGeneration)
        #expect(first.summary == frozen)
        #expect(first.inputStatus == .stopped && retry.inputStatus == .stopped)
    }

    @Test func diamondTimeTargetsRemainVisibleUntilPhaseEnd() async throws {
        let script = try LaserReplayScript.complete(seed: 1)
        let session = try LaserReplayDriver.makeSession(script: script)
        try await session.start()
        try await session.advance(to: 315)
        #expect(session.state?.phase == .diamondTime)
        #expect(session.diamondStates.values.filter { $0.outcome == nil }.count == 4)
        let score = session.state?.teamScore
        try await session.advance(to: 316)
        #expect(session.summary?.teamScore == score)
        #expect(session.diamondStates.values.filter { $0.outcome == nil }.isEmpty)
    }
}
