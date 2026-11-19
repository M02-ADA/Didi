import Foundation
import Testing
@testable import Sedactive

@MainActor struct FTUEProgressJourneyTests {
    @Test func milestonesArePresentationOnlyAndRetriesCannotReachCheckpoint() {
        let journey = FTUEProgressJourney(), generation = UUID()
        journey.reset(generation: generation)
        #expect(journey.fillEnd == FTUEProgressJourney.initial)
        var time = 0.0
        for stage: LeanTutorial.Stage in [.introduction, .freeLean, .collectiblesIntroduction, .collection(.diamond), .collection(.heart), .heart(.introduction),
            .heart(.hurt), .heart(.warning), .jumpDuckIntroduction, .laserPractice(.jump), .laserPractice(.duck)] {
            let before = journey.fillEnd
            for _ in 0..<80 {
                time += 0.025; journey.update(stage: stage, generation: generation, at: time, active: true)
            }
            #expect(journey.fillEnd >= before && journey.fillEnd < 0.5)
            #expect(journey.fillEnd == FTUEProgressJourney.endpoint(for: stage))
        }
        // An arbitrary number of failed attempts do not change the current stage's endpoint.
        for _ in 0..<1000 { time += 0.025; journey.update(stage: .laserPractice(.duck), generation: generation, at: time, active: true) }
        #expect(journey.fillEnd == 0.46)
    }
    @Test func animationFreezesWithoutCatchupAndGenerationResetStartsAtInitial() {
        let journey = FTUEProgressJourney(), generation = UUID()
        journey.reset(generation: generation)
        journey.update(stage: .freeLean, generation: generation, at: 1, active: true)
        journey.update(stage: .freeLean, generation: generation, at: 1.1, active: true)
        let partial = journey.fillEnd
        #expect(partial > FTUEProgressJourney.initial && partial < 0.22)
        journey.update(stage: .completed, generation: generation, at: 10, active: false)
        journey.update(stage: .completed, generation: UUID(), at: 11, active: true)
        #expect(journey.fillEnd == partial)
        journey.update(stage: .freeLean, generation: generation, at: 12, active: true)
        #expect(journey.fillEnd == partial, "no paused time catch-up")
        journey.reset(generation: UUID())
        #expect(journey.fillEnd == FTUEProgressJourney.initial)
    }
}
