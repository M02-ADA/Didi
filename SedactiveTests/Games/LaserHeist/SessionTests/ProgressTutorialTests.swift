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
        #expect(tutorial.stage == .vaultButtonIntroduction && !tutorial.isCompleted)
        tutorial.finishVaultButtonIntroduction(generation: UUID())
        #expect(tutorial.stage == .vaultButtonIntroduction)
        tutorial.setSuspended(true, generation: f.generation)
        tutorial.finishVaultButtonIntroduction(generation: f.generation)
        #expect(tutorial.stage == .vaultButtonIntroduction)
        tutorial.setSuspended(false, generation: f.generation)
        tutorial.finishVaultButtonIntroduction(generation: f.generation)
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
    @Test func syntheticOutcomeRequiresCurrentUnpausedEncounterAndIsConsumedOnce() throws {
        let f = LeanTutorialTests.Fixture()
        for key in [LeanTutorial.completionKey, LeanTutorial.heartCompletionKey, LeanTutorial.jumpDuckCompletionKey] {
            f.defaults.set(true, forKey: key)
        }
        let tutorial = LeanTutorial(defaults: f.defaults)
        func reachIntroduction(_ generation: UUID) {
            tutorial.prepare(generation: generation)
            tutorial.beginIfEligible(generation: generation, eligible: true)
            for i in 0...40 {
                tutorial.progressJourney.update(stage: tutorial.stage, generation: generation, at: Double(i) / 50, active: true)
            }
            for phase: ProgressTutorialPhase in [.bar, .vault] {
                tutorial.progressVisible(phase, visible: true, generation: generation)
                tutorial.finishProgress(phase, generation: generation)
            }
        }
        let generation = f.generation
        reachIntroduction(generation)
        tutorial.acceptSyntheticVaultButtonPreview(generation: generation, encounterID: UUID())
        #expect(tutorial.stage == .vaultButtonIntroduction)
        tutorial.beginVaultButtonPreview(generation: generation)
        let encounter = try #require(tutorial.vaultButtonEncounterID)
        tutorial.finishVaultButtonIntroduction(generation: generation)
        tutorial.acceptSyntheticVaultButtonPreview(generation: UUID(), encounterID: encounter)
        tutorial.acceptSyntheticVaultButtonPreview(generation: generation, encounterID: UUID())
        tutorial.setSuspended(true, generation: generation)
        tutorial.acceptSyntheticVaultButtonPreview(generation: generation, encounterID: encounter)
        #expect(tutorial.vaultButtonEncounterID == encounter && !tutorial.isCompleted)
        tutorial.setSuspended(false, generation: generation)
        tutorial.acceptSyntheticVaultButtonPreview(generation: generation, encounterID: encounter)
        tutorial.acceptSyntheticVaultButtonPreview(generation: generation, encounterID: encounter)
        #expect(tutorial.progressPhase == .diamond && tutorial.vaultButtonEncounterID == nil)
        #expect(tutorial.progressJourney.fillEnd == 0.5)
        #expect(!tutorial.progressJourney.hasReachedExplanationEndpoint(.diamond))
        tutorial.progressVisible(.diamond, visible: true, generation: generation)
        tutorial.finishProgress(.diamond, generation: generation)
        #expect(tutorial.progressPhase == .diamond && !tutorial.isCompleted)
        for i in 41...90 {
            tutorial.progressJourney.update(stage: tutorial.stage, generation: generation, at: Double(i) / 50, active: true)
        }
        #expect(tutorial.progressJourney.fillEnd == GameplayHUDModel.diamondPosition)
        #expect(tutorial.progressJourney.hasReachedExplanationEndpoint(.diamond))
        tutorial.finishProgress(.diamond, generation: generation)
        #expect(tutorial.stage == .diamondCollectionIntroduction && !tutorial.isCompleted)
        tutorial.progressJourney.update(stage: tutorial.stage, generation: generation, at: 1.84, active: true)
        #expect(tutorial.progressJourney.fillEnd == GameplayHUDModel.diamondPosition)
        tutorial.finishDiamondCollectionIntroduction(generation: UUID())
        #expect(tutorial.stage == .diamondCollectionIntroduction)
        tutorial.finishDiamondCollectionIntroduction(generation: generation)
        #expect(tutorial.stage == .diamondTimeDemo && !tutorial.isCompleted)
        tutorial.progressJourney.update(stage: tutorial.stage, generation: generation, at: 1.86, active: true)
        #expect(tutorial.progressJourney.fillEnd == GameplayHUDModel.diamondPosition)
        tutorial.advanceDiamondTimeDemo(generation: generation, at: 2, active: true)
        tutorial.setSuspended(true, generation: generation)
        tutorial.advanceDiamondTimeDemo(generation: generation, at: 2.1, active: true)
        #expect(tutorial.diamondTimeDemo.elapsed == 0)
        tutorial.setSuspended(false, generation: generation)
        tutorial.advanceDiamondTimeDemo(generation: UUID(), at: 2.15, active: true)
        #expect(tutorial.diamondTimeDemo.elapsed == 0)
        for i in 11...42 {
            tutorial.advanceDiamondTimeDemo(generation: generation, at: Double(i) / 5, active: true)
        }
        #expect(tutorial.stage == .completed && tutorial.isCompleted)
        #expect(tutorial.diamondTimeDemo.elapsed == 0)

        tutorial.abandon()
        #expect(tutorial.progressJourney.fillEnd == FTUEProgressJourney.initial)
        let next = UUID()
        tutorial.prepare(generation: next, replayRequested: true)
        tutorial.beginIfEligible(generation: next, eligible: true)
        tutorial.progressJourney.update(stage: .progressExplanation(.diamond), generation: generation, at: 2, active: true)
        #expect(tutorial.stage == .introduction && tutorial.progressJourney.fillEnd == FTUEProgressJourney.initial)

        f.defaults.removeObject(forKey: LeanTutorial.progressCompletionKey)
        reachIntroduction(next)
        tutorial.beginVaultButtonPreview(generation: next)
        tutorial.acceptSyntheticVaultButtonPreview(generation: generation, encounterID: encounter)
        #expect(tutorial.vaultButtonEncounterID != nil && tutorial.progressPhase == nil)
    }

    @Test func copyIsExact() {
        #expect(VaultButtonIntroduction.copy == "Press the buttons\nto open vault door")
        #expect(ProgressTutorialPhase.diamond.copy == "Reach the Diamond\nVault at the end!")
        #expect(ProgressTutorialPhase.bar.copy == "This bar shows how far\nyou've gone")
        #expect(ProgressTutorialPhase.vault.copy == "Each circle is a vault\ndoor to open")
    }
}
