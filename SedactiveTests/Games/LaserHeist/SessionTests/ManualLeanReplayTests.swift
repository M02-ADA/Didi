import Foundation
import Testing
@testable import Sedactive

@MainActor struct ManualLeanReplayTests {
    @Test(arguments: [false, true], [false, true])
    func firstPlayAndExplicitReplayChooseOnlyTheInitialHold(completed: Bool, manual: Bool) async throws {
        let defaults = UserDefaults(suiteName: "LeanManual.\(UUID())")!
        defer { defaults.removeObject(forKey: LeanTutorial.completionKey); defaults.removeObject(forKey: LeanTutorial.heartCompletionKey) }
        defaults.set(completed, forKey: LeanTutorial.completionKey)
        defaults.set(completed, forKey: LeanTutorial.heartCompletionKey)
        let tutorial = LeanTutorial(defaults: defaults)
        var constructed = 0
        let flow = LaserInputFlow(leanTutorial: tutorial, makeLiveSession: {
            constructed += 1
            let script = try LaserReplayScript.load().freshRound(generation: UUID())
            return GameSessionCoordinator(provider: ControlledSessionInput(), inputConfiguration: script.input.configuration)
        })
        if manual {
            #expect(flow.requestLeanTutorialReplay())
            #expect(!flow.requestLeanTutorialReplay(), "one Home intent; no duplicated setup")
            #expect(constructed == 0 && flow.session == nil)
        }
        await flow.startSelectedSetup()
        #expect(constructed == 1 && !flow.tutorialReplayRequested)
        let session = try #require(flow.session)
        #expect(session.preRoundTutorialPending == (!completed || manual))
        #expect(session.state == nil && !session.canStartLiveRound)
        flow.presentLeanTutorialIfReady()
        #expect(!tutorial.isActive, "Help never grants readiness/calibration")
        #expect(tutorial.isCompleted == completed, "manual entry must not reset persistence")
        #expect(!flow.requestLeanTutorialReplay())
        await flow.closeLiveSetup()
        #expect(!flow.tutorialReplayRequested && tutorial.generation == nil)
    }

    @Test func completedPlayerReplaysBothDirectionsWithoutResettingCompletion() {
        let f = LeanTutorialTests.Fixture()
        f.defaults.set(true, forKey: LeanTutorial.completionKey)
        f.defaults.set(true, forKey: LeanTutorial.heartCompletionKey)
        defer { f.defaults.removeObject(forKey: LeanTutorial.completionKey); f.defaults.removeObject(forKey: LeanTutorial.heartCompletionKey) }
        let tutorial = LeanTutorial(defaults: f.defaults)
        tutorial.prepare(generation: f.generation, roster: f.roster, replayRequested: true)
        tutorial.beginIfEligible(generation: f.generation, eligible: true)
        #expect(tutorial.stage == .introduction && tutorial.isCompleted)
        tutorial.introductionVisible(true, generation: f.generation)
        tutorial.finishIntroduction(generation: f.generation)
        tutorial.practiceVisible(.practiceLeft, generation: f.generation, at: 0)
        f.finish(tutorial)
        #expect(tutorial.stage == .completed && tutorial.isCompleted)
        tutorial.prepare(generation: UUID(), roster: f.roster)
        #expect(tutorial.stage == .completed && !tutorial.isActive, "Retry / normal visit does not repeat")
        let relaunched = LeanTutorial(defaults: f.defaults)
        relaunched.prepare(generation: UUID())
        #expect(relaunched.stage == .completed)
    }

    @Test(arguments: ["cancel", "background", "replay", "diagnostics"])
    func canceledHomeRequestNeverSurvivesNavigation(action: String) async {
        var constructions = 0
        let flow = LaserInputFlow(makeLiveSession: { constructions += 1; throw CameraFailure.permissionDenied })
        #expect(flow.requestLeanTutorialReplay())
        switch action {
        case "background": await flow.handleBackground()
        case "replay": flow.showReplay()
        case "diagnostics": flow.showDiagnostics()
        default: flow.cancelLeanTutorialReplay()
        }
        #expect(!flow.tutorialReplayRequested && constructions == 0 && flow.session == nil)
    }

    @Test func manualVisitIsConsumedBeforeFailureAndCannotLeakThroughRetry() async throws {
        let defaults = UserDefaults(suiteName: "LeanFailure.\(UUID())")!
        defaults.set(true, forKey: LeanTutorial.completionKey)
        defaults.set(true, forKey: LeanTutorial.heartCompletionKey)
        defer { defaults.removeObject(forKey: LeanTutorial.completionKey); defaults.removeObject(forKey: LeanTutorial.heartCompletionKey) }
        var fail = true
        let flow = LaserInputFlow(leanTutorial: LeanTutorial(defaults: defaults), makeLiveSession: {
            if fail { throw CameraFailure.permissionDenied }
            let script = try LaserReplayScript.load().freshRound(generation: UUID())
            return GameSessionCoordinator(provider: ControlledSessionInput(), inputConfiguration: script.input.configuration)
        })
        flow.requestLeanTutorialReplay()
        await flow.startSelectedSetup()
        #expect(flow.session == nil && !flow.tutorialReplayRequested && flow.leanTutorial.isCompleted)
        fail = false
        await flow.retryLiveSetup()
        #expect(flow.session?.preRoundTutorialPending == false)
        #expect(flow.leanTutorial.stage == .completed)
        await flow.closeLiveSetup()
        flow.requestLeanTutorialReplay()
        await flow.startSelectedSetup()
        #expect(flow.session?.preRoundTutorialPending == true)
        await flow.retryLiveSetup()
        #expect(flow.session?.preRoundTutorialPending == false)
        await flow.handleBackground()
        #expect(flow.route == .selection && !flow.tutorialReplayRequested)
    }
    @Test(arguments: [false, true])
    func helpKeepsTheExistingSelectedModeAndRoster(solo: Bool) async throws {
        func make(_ solo: Bool) throws -> GameSessionCoordinator {
            let script = try LaserReplayScript.load().freshRound(generation: UUID())
            var configuration = script.input.configuration
            if solo { configuration.soloPlayer = .player1 }
            return GameSessionCoordinator(provider: ControlledSessionInput(), inputConfiguration: configuration)
        }
        let flow = LaserInputFlow(makeLiveSession: { try make(false) }, makeSoloSession: { try make(true) })
        flow.selectPlayerMode(soloPractice: solo)
        flow.requestLeanTutorialReplay()
        await flow.startSelectedSetup()
        #expect(flow.isSolo == solo)
        #expect(flow.leanTutorial.roster == (solo ? [.player1] : PlayerID.allCases))
        await flow.closeLiveSetup()
    }

    @Test func debugPreviewIntentIsSingleUseAndCanBeCanceledBeforeLoading() {
        LeanFTUEPreviewLaunch.requestManualReplay()
        #expect(LeanFTUEPreviewLaunch.consumeManualReplay())
        #expect(!LeanFTUEPreviewLaunch.consumeManualReplay())
        LeanFTUEPreviewLaunch.requestManualReplay()
        LeanFTUEPreviewLaunch.cancelManualReplay()
        #expect(!LeanFTUEPreviewLaunch.consumeManualReplay())
    }

}
