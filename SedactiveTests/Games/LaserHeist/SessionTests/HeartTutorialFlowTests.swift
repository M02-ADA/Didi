import Foundation
import CoreGraphics
import Testing
@testable import Sedactive

@MainActor struct HeartTutorialFlowTests {
    @Test(arguments: [false, true])
    func collectiblesFeedIntoHeartAndOnlyFinalWarningCompletes(coop: Bool) {
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
            f.finishPhase(tutorial, phase)
        }
        #expect(tutorial.stage == .jumpDuckIntroduction && !tutorial.isCompleted)
        f.finishPractice(tutorial)
        f.finishProgress(tutorial)
        #expect(tutorial.stage == .completed && tutorial.isCompleted)
        tutorial.prepare(generation: UUID(), roster: f.roster)
        #expect(tutorial.stage == .completed)
    }
    @Test func existingLeanGraduateGetsCollectiblesBeforeMissingHeartButHelpStartsAtLean() {
        let f = LeanTutorialTests.Fixture()
        // A valid completed Lean record exists from the previous version.
        f.defaults.set(true, forKey: LeanTutorial.completionKey)
        defer { f.defaults.removeObject(forKey: LeanTutorial.completionKey); f.defaults.removeObject(forKey: LeanTutorial.heartCompletionKey) }
        let returning = LeanTutorial(defaults: f.defaults)
        returning.prepare(generation: f.generation, roster: f.roster)
        returning.beginIfEligible(generation: f.generation, eligible: false)
        #expect(returning.stage == .notStarted)
        returning.beginIfEligible(generation: f.generation, eligible: true)
        #expect(returning.stage == .collectiblesIntroduction)
        f.finishCollections(returning)
        #expect(returning.heartPhase == .introduction)
        f.finishHeart(returning)
        #expect(returning.stage == .jumpDuckIntroduction && !returning.isCompleted)
        f.finishPractice(returning)
        f.finishProgress(returning)
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
        var f = LeanTutorialTests.Fixture(); f.roster = PlayerID.allCases
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
        let context = BodyInputContext(sessionGeneration: gen, cameraGeometryRevision: 1,
            calibrationRevisions: f.context.calibrationRevisions, cutovers: f.context.cutovers, isActive: true)
        f.finishCollections(tutorial, context: context)
        for phase in HeartTutorialPhase.allCases {
            flow.releaseCompletedLeanTutorial()
            #expect(session.preRoundTutorialPending && session.state == nil && session.events.isEmpty)
            tutorial.heartVisible(phase, visible: true, generation: gen)
            f.finishPhase(tutorial, phase, generation: gen)
        }
        #expect(session.preRoundTutorialPending && tutorial.stage == .jumpDuckIntroduction)
        f.finishPractice(tutorial, generation: gen)
        flow.releaseCompletedLeanTutorial()
        #expect(session.preRoundTutorialPending && tutorial.progressPhase == .bar)
        f.finishProgress(tutorial, generation: gen)
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
