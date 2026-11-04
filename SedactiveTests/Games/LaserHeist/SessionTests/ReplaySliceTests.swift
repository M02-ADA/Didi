import Foundation
import Testing
@testable import Sedactive

@MainActor struct ReplaySliceTests {
    private func script() throws -> LaserReplayScript {
        #if SWIFT_PACKAGE
        try LaserReplayScript.load(bundle: .module)
        #else
        try LaserReplayScript.load() // Hosted test: fixture ships in the application's bundle.
        #endif
    }

    @Test func sliceCompletesThroughSharedReplayAndProductionCheckerTwice() async throws {
        let input = try script()
        var previous: [ReplayTargetResult]?
        var previousSummary: RoundSummary?
        var previousEvents: [GameEvent]?
        for _ in 0..<2 {
            let session = GameSessionCoordinator(script: input)
            try await session.start()
            for tick in 0...Int(input.duration * 60 + 1) { try await session.advance(to: Double(tick) / 60) }
            #expect(session.phase == .finished)
            #expect(session.results.map(\.judgement) == [.clear, .clear, .hit(.insufficientClearance), .clear,
                                                          .hit(.insufficientClearance), .clear])
            #expect(session.summary?.teamScore == 400)
            #expect(session.summary?.remainingTeamHealth == 3)
            #expect(session.summary?.outcome == .completed)
            #expect(session.summary?.vaultsOpened == 1)
            #expect(session.state?.missionProgress == 1)
            #expect(session.summary?.remainingTeamHealth == session.state?.teamHealth)
            #expect(session.summary?.teamScore == session.state?.teamScore)
            #expect(session.summary?.missionProgress == session.state?.missionProgress)
            #expect(session.summary?.playerResults.map(\.successfulHighAvoidances) == [1,2])
            #expect(session.summary?.playerResults.map(\.successfulLowAvoidances) == [0,1])
            #expect(session.summary?.playerResults.allSatisfy { $0.validatedJumpCycles == nil } == true)
            if let previous { #expect(session.results == previous) }
            if let previousSummary { #expect(session.summary == previousSummary) }
            if let previousEvents { #expect(session.events == previousEvents) }
            previous = session.results
            previousSummary = session.summary
            previousEvents = session.events
        }
    }

    @Test func largeFrameUsesEveryDeliveryAndDoesNotDuplicateEffects() async throws {
        let session = GameSessionCoordinator(script: try script())
        try await session.start()
        try await session.advance(to: 100)
        let summary = session.summary
        try await session.advance(to: 101)
        #expect(session.summary == summary)
        #expect(session.results.count == 6)
        #expect(session.state?.teamScore == 400)
    }

    @Test func stopPreventsFurtherVerdicts() async throws {
        let session = GameSessionCoordinator(script: try script())
        try await session.start()
        try await session.advance(to: 1)
        await session.stop()
        try await session.advance(to: 30)
        #expect(session.results.isEmpty)
        #expect(session.summary?.outcome == .aborted)
    }

    @Test func replayExposesCooperationAndFreezesProgressUntilBothSidesFinish() async throws {
        let session = GameSessionCoordinator(script: try script())
        try await session.start()
        try await session.advance(to: 17)
        #expect(session.state?.phase == .vault)
        let progress = session.state?.activityProgress
        try await session.advance(to: 18.6)
        #expect(session.state?.vault?.buttons[.player1]?.count == 3)
        #expect(session.state?.vault?.buttons[.player2]?.count == 0)
        #expect(session.state?.missionProgress == 0)
        #expect(session.state?.activityProgress == progress)
        try await session.advance(to: 21)
        #expect(session.state?.phase == .diamondTime)
        #expect(session.state?.missionProgress == 1)
        #expect(session.state?.activityProgress == progress)
        try await session.advance(to: 35.9)
        #expect(session.summary == nil)
        try await session.advance(to: 36)
        #expect(session.summary?.outcome == .completed)
        #expect(session.summary?.activityDuration == 32)
        #expect(session.state?.playerStats[.player1]?.cleared == 1)
        #expect(session.state?.playerStats[.player2]?.cleared == 3)
        #expect(session.events.filter { if case .coopGateSucceeded = $0.kind { true } else { false } }.count == 1)
        #expect(session.events.filter { if case .roundEnded = $0.kind { true } else { false } }.count == 1)
    }

    @Test func earlyExitProducesOneSummaryAndRetryStartsFreshGeneration() async throws {
        let original = try script()
        let first = GameSessionCoordinator(script: original)
        try await first.start()
        try await first.advance(to: 3.5)
        await first.stop()
        let snapshot = try #require(first.summary)
        #expect(snapshot.outcome == .aborted)
        #expect(snapshot.teamScore == 0)
        #expect(snapshot.playerResults.allSatisfy { $0.validatedJumpCycles == nil })
        await first.stop(reason: .technicalInterruption)
        try await first.advance(to: 100)
        #expect(first.summary == snapshot)
        #expect(first.events.filter { if case .roundEnded = $0.kind { true } else { false } }.count == 1)
        let generation = UUID(uuidString: "17100000-0000-4000-8000-000000000001")!
        let next = try original.freshRound(generation: generation)
        #expect(next.input.configuration.sessionGeneration != original.input.configuration.sessionGeneration)
        #expect(next.input.configuration.calibrations.values.allSatisfy { $0.sessionGeneration == generation })
        #expect(next.input.records.allSatisfy { $0.snapshot?.sessionGeneration == generation })
        let retry = GameSessionCoordinator(script: next)
        try await retry.start()
        #expect(retry.summary == nil && retry.results.isEmpty && retry.events.isEmpty)
        #expect(retry.state?.gameTime == 0 && retry.state?.teamScore == 0 && retry.state?.teamHealth == 5)
        #expect(retry.state?.missionProgress == 0)
        try await retry.advance(to: 100)
        #expect(retry.summary?.sessionGeneration == generation)
        #expect(retry.summary?.playerResults.map(\.successfulLowAvoidances) == [0,1])
        #expect(retry.summary?.playerResults.allSatisfy { $0.validatedJumpCycles == nil } == true)
        #expect(first.summary == snapshot)
    }

    @Test func technicalFailureAlsoProducesExactlyOneFrozenSummary() async throws {
        let session = GameSessionCoordinator(script: try script())
        try await session.start()
        try await session.advance(to: 3.5)
        await session.fail(LaserDataError.invalidValue("synthetic interruption"))
        let snapshot = try #require(session.summary)
        #expect(snapshot.outcome == .technicalInterruption)
        #expect(snapshot.teamScore == 0 && snapshot.remainingTeamHealth == 5)
        await session.stop()
        #expect(session.summary == snapshot)
        #expect(session.events.filter { if case .roundEnded = $0.kind { true } else { false } }.count == 1)
    }
}
