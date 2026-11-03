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
        for _ in 0..<2 {
            let session = GameSessionCoordinator(script: input)
            try await session.start()
            for tick in 0...1120 { try await session.advance(to: Double(tick) / 60) }
            #expect(session.phase == .finished)
            #expect(session.results.map(\.judgement) == [.clear, .clear, .hit(.insufficientClearance), .clear,
                                                          .hit(.insufficientClearance), .clear])
            #expect(session.summary?.teamScore == 400)
            #expect(session.summary?.remainingTeamHealth == 3)
            #expect(session.summary?.outcome == .completed)
            if let previous { #expect(session.results == previous) }
            if let previousSummary { #expect(session.summary == previousSummary) }
            previous = session.results
            previousSummary = session.summary
        }
    }

    @Test func largeFrameUsesEveryDeliveryAndDoesNotDuplicateEffects() async throws {
        let session = GameSessionCoordinator(script: try script())
        try await session.start()
        try await session.advance(to: 30)
        let summary = session.summary
        try await session.advance(to: 31)
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
        #expect(session.summary == nil)
    }
}
