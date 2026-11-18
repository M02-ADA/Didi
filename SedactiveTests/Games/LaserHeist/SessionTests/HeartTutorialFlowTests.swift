import Foundation
import CoreGraphics
import Testing
@testable import Sedactive

@MainActor struct HeartTutorialFlowTests {
    @Test(arguments: [false, true])
    func leanFeedsImmediatelyIntoHeartAndOnlyFinalWarningCompletes(coop: Bool) {
        var f = LeanTutorialTests.Fixture(); if coop { f.roster = PlayerID.allCases }
        let tutorial = f.tutorial()
        defer { tutorial.resetForNextPlay() }
        f.finishLean(tutorial)
        #expect(tutorial.stage == .heart(.introduction) && tutorial.isActive)
        #expect(tutorial.hasCompletedLean && !tutorial.isCompleted)
        tutorial.finishHeart(.introduction, generation: f.generation)
        #expect(tutorial.heartPhase == .introduction, "invisible explanation cannot finish")
        for phase in HeartTutorialPhase.allCases {
            #expect(!tutorial.isCompleted)
            tutorial.heartVisible(phase, visible: true, generation: f.generation)
            tutorial.finishHeart(phase, generation: f.generation)
        }
        #expect(tutorial.stage == .completed && tutorial.isCompleted)
        tutorial.prepare(generation: UUID(), roster: f.roster)
        #expect(tutorial.stage == .completed)
    }
    @Test func existingLeanGraduateGetsOnlyMissingHeartButHelpStartsAtLean() {
        let f = LeanTutorialTests.Fixture()
        // A valid completed Lean record exists from the previous version.
        f.defaults.set(true, forKey: LeanTutorial.completionKey)
        defer { f.defaults.removeObject(forKey: LeanTutorial.completionKey); f.defaults.removeObject(forKey: LeanTutorial.heartCompletionKey) }
        let returning = LeanTutorial(defaults: f.defaults)
        returning.prepare(generation: f.generation, roster: f.roster)
        returning.beginIfEligible(generation: f.generation, eligible: false)
        #expect(returning.stage == .notStarted)
        returning.beginIfEligible(generation: f.generation, eligible: true)
        #expect(returning.heartPhase == .introduction)
        f.finishHeart(returning)
        #expect(returning.isCompleted)
        returning.prepare(generation: f.generation, roster: f.roster, replayRequested: true)
        returning.beginIfEligible(generation: f.generation, eligible: true)
        #expect(returning.stage == .introduction && returning.isCompleted)
        returning.abandon()
        returning.prepare(generation: UUID())
        #expect(returning.stage == .completed, "canceling Help never resets either record")
    }
    @Test func pauseInvisibilityDuplicatesAndOldGenerationCannotAdvance() {
        let f = LeanTutorialTests.Fixture(), tutorial = f.tutorial()
        defer { tutorial.resetForNextPlay() }
        f.finishLean(tutorial)
        tutorial.heartVisible(.introduction, visible: true, generation: f.generation)
        tutorial.setSuspended(true, generation: f.generation)
        tutorial.finishHeart(.introduction, generation: f.generation)
        tutorial.setSuspended(false, generation: f.generation)
        tutorial.finishHeart(.introduction, generation: f.generation)
        #expect(tutorial.heartPhase == .introduction)
        tutorial.heartVisible(.introduction, visible: true, generation: f.generation)
        tutorial.finishHeart(.introduction, generation: UUID())
        #expect(tutorial.heartPhase == .introduction)
        tutorial.finishHeart(.introduction, generation: f.generation)
        tutorial.finishHeart(.introduction, generation: f.generation)
        #expect(tutorial.heartPhase == .hurt)
        tutorial.heartVisible(.hurt, visible: true, generation: f.generation)
        tutorial.heartVisible(.hurt, visible: false, generation: f.generation)
        tutorial.finishHeart(.hurt, generation: f.generation)
        #expect(tutorial.heartPhase == .hurt)
        tutorial.abandon()
        tutorial.finishHeart(.hurt, generation: f.generation)
        #expect(!tutorial.isActive && !tutorial.isCompleted)
    }
    @Test func heartRetainsPreRoundHoldAndCompletionCannotGrantReadiness() async throws {
        let f = LeanTutorialTests.Fixture()
        f.defaults.set(true, forKey: LeanTutorial.completionKey)
        let tutorial = LeanTutorial(defaults: f.defaults)
        defer { tutorial.resetForNextPlay() }
        let flow = LaserInputFlow(leanTutorial: tutorial, makeLiveSession: {
            let input = try LaserReplayScript.load().freshRound(generation: UUID()).input.configuration
            return GameSessionCoordinator(provider: ControlledSessionInput(), inputConfiguration: input)
        })
        await flow.startSelectedSetup()
        let session = try #require(flow.session), gen = session.inputConfiguration.sessionGeneration
        #expect(session.preRoundTutorialPending && !session.canStartLiveRound)
        flow.presentLeanTutorialIfReady()
        #expect(tutorial.stage == .notStarted)
        // Unit-only presentation completion events do not make the actual session ready.
        tutorial.beginIfEligible(generation: gen, eligible: true)
        for phase in HeartTutorialPhase.allCases {
            flow.releaseCompletedLeanTutorial()
            #expect(session.preRoundTutorialPending && session.state == nil && session.events.isEmpty)
            tutorial.heartVisible(phase, visible: true, generation: gen)
            tutorial.finishHeart(phase, generation: gen)
        }
        flow.releaseCompletedLeanTutorial()
        #expect(!session.preRoundTutorialPending && session.state == nil && !session.canStartLiveRound)
        await flow.closeLiveSetup()
    }
    @Test func hudGeometryIsGenerationQualifiedAndClearedOnStop() {
        let f = LeanTutorialTests.Fixture(), tutorial = f.tutorial()
        tutorial.setHealthHUDFrame(CGRect(x: 60, y: 58, width: 268, height: 64), generation: UUID())
        #expect(tutorial.healthHUDFrame == nil)
        tutorial.setHealthHUDFrame(CGRect(x: 60, y: 58, width: 268, height: 64), generation: f.generation)
        #expect(tutorial.healthHUDFrame?.width == 268)
        tutorial.abandon()
        #expect(tutorial.healthHUDFrame == nil)
    }
}
