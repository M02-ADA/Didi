import Foundation
import Testing
@testable import Sedactive

@MainActor struct ProgressTutorialTests {
    @Test(arguments: [false, true])
    func duckClearAndFeedbackMustFinishBeforeExplanationsAndFullCompletion(coop: Bool) {
        var f = LeanTutorialTests.Fixture(); if coop { f.roster = PlayerID.allCases }
        let tutorial = f.tutorial()
        f.finishLean(tutorial); f.finishHeart(tutorial)
        #expect(tutorial.stage == .jumpDuckIntroduction)
        f.finishPractice(tutorial)
        #expect(tutorial.stage == .progressExplanation(.bar) && tutorial.isActive && !tutorial.isCompleted)
        tutorial.progressVisible(.bar, visible: true, generation: f.generation)
        tutorial.finishProgress(.bar, generation: f.generation)
        #expect(tutorial.progressPhase == .bar, "cannot explain arrival before the fill actually arrives")
        for i in 0...40 { tutorial.progressJourney.update(stage: tutorial.stage, generation: f.generation, at: Double(i) / 50, active: true) }
        #expect(tutorial.progressJourney.fillEnd == 0.5)
        tutorial.finishProgress(.bar, generation: UUID())
        #expect(tutorial.progressPhase == .bar)
        tutorial.finishProgress(.bar, generation: f.generation)
        tutorial.finishProgress(.bar, generation: f.generation)
        #expect(tutorial.progressPhase == .vault && !tutorial.isCompleted)
        tutorial.progressVisible(.vault, visible: true, generation: f.generation)
        tutorial.setSuspended(true, generation: f.generation)
        tutorial.finishProgress(.vault, generation: f.generation)
        #expect(tutorial.progressPhase == .vault)
        tutorial.setSuspended(false, generation: f.generation)
        tutorial.finishProgress(.vault, generation: f.generation)
        #expect(tutorial.progressPhase == .vault, "resumed artwork must become visible again")
        tutorial.progressVisible(.vault, visible: true, generation: f.generation)
        tutorial.finishProgress(.vault, generation: f.generation)
        #expect(tutorial.stage == .completed && tutorial.isCompleted)
        tutorial.prepare(generation: UUID())
        #expect(tutorial.stage == .completed)
        tutorial.prepare(generation: UUID(), replayRequested: true)
        tutorial.beginIfEligible(generation: tutorial.generation!, eligible: true)
        #expect(tutorial.stage == .introduction && tutorial.progressJourney.fillEnd == FTUEProgressJourney.initial)
    }
    @Test func existingGraduatesGetOnlyNewModuleAndCancellationDoesNotEraseOldFlags() {
        let f = LeanTutorialTests.Fixture()
        for key in [LeanTutorial.completionKey, LeanTutorial.heartCompletionKey, LeanTutorial.jumpDuckCompletionKey] { f.defaults.set(true, forKey: key) }
        let tutorial = LeanTutorial(defaults: f.defaults)
        tutorial.prepare(generation: f.generation); tutorial.beginIfEligible(generation: f.generation, eligible: true)
        #expect(tutorial.progressPhase == .bar)
        tutorial.abandon()
        #expect(f.defaults.bool(forKey: LeanTutorial.jumpDuckCompletionKey) && !tutorial.isCompleted)
        tutorial.prepare(generation: UUID(), replayRequested: true)
        tutorial.beginIfEligible(generation: tutorial.generation!, eligible: true)
        #expect(tutorial.stage == .introduction)
    }
    @Test func copyIsExact() {
        #expect(ProgressTutorialPhase.bar.copy == "This bar shows how far\nyou've gone")
        #expect(ProgressTutorialPhase.vault.copy == "Each circle is a vault\ndoor to open")
    }
}
