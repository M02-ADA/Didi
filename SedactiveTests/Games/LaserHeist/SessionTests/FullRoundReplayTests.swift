import Foundation
import Testing
@testable import Sedactive

@MainActor struct FullRoundReplayTests {
    private func scenario(_ mode: FullRoundReplayCase) throws -> FullRoundReplayScenario {
        try FullRoundReplayScenario.make(mode, base: LH00TestData.load("cooperative-v2"))
    }

    @Test func fullFiveMinuteRoundAndFiveVaultsCompleteWithExpectedResults() async throws {
        let replay = try scenario(.allClear)
        let trace = try await FullRoundReplayHarness.run(replay)
        #expect(trace.summary.outcome == .completed)
        #expect(trace.results.count == 100)
        #expect(trace.results.allSatisfy { $0.judgement == .clear })
        #expect(trace.summary.teamScore == 10_000)
        #expect(trace.summary.remainingTeamHealth == 5)
        #expect(trace.summary.vaultsOpened == 5)
        #expect(trace.summary.missionProgress == 5)
        #expect(abs(trace.summary.gameDuration - 316) < 1e-8) // 300 activity + 6 vault + 10 bonus.
        #expect(abs(trace.summary.activityDuration - 310) < 1e-8)
        for player in trace.summary.playerResults {
            #expect(player.successfulHighAvoidances == 32)
            #expect(player.successfulLowAvoidances == 18)
            #expect(player.validatedJumpCycles == nil)
            #expect(abs(try #require(player.movementChallengeSeconds) - 70) < 1e-8)
        }
        #expect(trace.maximumHistoryCount <= 240)
    }

    @Test(arguments: FullRoundReplayCase.allCases)
    func everyScenarioIsReproducibleAndEndsExactlyOnce(_ mode: FullRoundReplayCase) async throws {
        let input = try scenario(mode)
        let first = try await FullRoundReplayHarness.run(input)
        let second = try await FullRoundReplayHarness.run(input)
        #expect(first == second)
        #expect(first.events.filter { if case .roundEnded = $0.kind { true } else { false } }.count == 1)
        #expect(Set(first.events.map(\.id)).count == first.events.count)
        #expect(first.maximumHistoryCount <= 240)
        #expect((0...5).contains(first.summary.remainingTeamHealth))
    }

    @Test func duplicateDeliveryCannotRepeatScoreDamageOrProgress() async throws {
        let original = try await FullRoundReplayHarness.run(scenario(.allClear))
        let duplicate = try await FullRoundReplayHarness.run(scenario(.duplicateFrames))
        #expect(duplicate.summary == original.summary)
        #expect(duplicate.results == original.results)
        #expect(duplicate.events == original.events)
    }

    @Test func missingLandmarkRemainsUnavailableWithNoTeamPenalty() async throws {
        let trace = try await FullRoundReplayHarness.run(scenario(.missingLandmark))
        #expect(trace.summary.outcome == .completed)
        #expect(trace.results.filter { if case .unavailable = $0.judgement { true } else { false } }.count == 1)
        #expect(trace.summary.teamScore == 9800)
        #expect(trace.summary.remainingTeamHealth == 5)
        #expect(trace.summary.vaultsOpened == 5)
        #expect(trace.events.allSatisfy { if case .teamDamaged = $0.kind { false } else { true } })
    }

    @Test(arguments: [FullRoundReplayCase.trackingLossRecovery, .uncertainIdentityRecovery])
    func lostOrUncertainTrackingWithdrawsThenRecoversWithoutBankedEvidence(_ mode: FullRoundReplayCase) async throws {
        let trace = try await FullRoundReplayHarness.run(scenario(mode))
        #expect(trace.summary.outcome == .completed)
        #expect(trace.summary.withdrawnAttempts == 1)
        #expect(trace.results.count == 100)
        #expect(trace.results.allSatisfy { $0.judgement == .clear })
        #expect(trace.summary.teamScore == 10_000)
        #expect(trace.summary.remainingTeamHealth == 5)
        #expect(abs(trace.summary.gameDuration - 325) < 1e-8) // Excludes the injected 5.4 source seconds paused.
    }

    @Test(arguments: [FullRoundReplayCase.healthFailure, .vaultTimeout, .earlyExit, .providerFailure])
    func failureAndExitFreezeAtTheirExpectedTerminalOutcome(_ mode: FullRoundReplayCase) async throws {
        let trace = try await FullRoundReplayHarness.run(scenario(mode))
        switch mode {
        case .healthFailure:
            #expect(trace.summary.outcome == .healthDepleted)
            #expect(trace.summary.remainingTeamHealth == 0)
            #expect(trace.summary.teamScore == 0)
            #expect(trace.events.compactMap { if case .teamDamaged(let n, _) = $0.kind { n } else { nil } } == [2,2,1])
        case .vaultTimeout:
            #expect(trace.summary.outcome == .vaultFailed)
            #expect(trace.summary.remainingTeamHealth == 5)
            #expect(trace.summary.vaultsOpened == 0)
            #expect(abs(trace.summary.gameDuration - 65) < 1e-8)
        case .earlyExit:
            #expect(trace.summary.outcome == .aborted)
            #expect(trace.summary.teamScore == 0)
            #expect(trace.results.isEmpty)
        case .providerFailure:
            #expect(trace.summary.outcome == .technicalInterruption)
            #expect(trace.summary.teamScore == 0)
        default: Issue.record("Unexpected terminal scenario")
        }
        #expect(trace.events.last?.kind == .roundEnded(trace.summary.outcome))
    }
}
