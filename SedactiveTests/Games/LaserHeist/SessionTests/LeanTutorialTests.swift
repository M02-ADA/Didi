import Foundation
import Testing
@testable import Sedactive

@MainActor struct LeanTutorialTests {
    private func store() -> UserDefaults { UserDefaults(suiteName: "LeanTests.\(UUID())")! }

    @Test(arguments: [false, true]) func explicitCompletionPersistsWithoutJudgingMovement(skip: Bool) {
        let defaults = store(), generation = UUID()
        let tutorial = LeanTutorial(defaults: defaults)
        defer { defaults.removeObject(forKey: LeanTutorial.completionKey) }
        tutorial.prepare(generation: generation)
        tutorial.beginIfEligible(generation: generation, eligible: false)
        #expect(!tutorial.isActive && !tutorial.isCompleted)
        tutorial.beginIfEligible(generation: UUID(), eligible: true)
        #expect(!tutorial.isActive)
        tutorial.beginIfEligible(generation: generation, eligible: true)
        #expect(tutorial.stage == .introduction)
        tutorial.advance(generation: UUID())
        #expect(tutorial.stage == .introduction)
        if skip { tutorial.skip(generation: generation) }
        else {
            tutorial.advance(generation: generation)
            #expect(tutorial.stage == .practiceLeft && !tutorial.isCompleted)
            tutorial.advance(generation: generation)
            #expect(tutorial.stage == .practiceRight && !tutorial.isCompleted)
            tutorial.advance(generation: generation)
        }
        #expect(tutorial.stage == .completed && tutorial.isCompleted)
        let relaunched = LeanTutorial(defaults: defaults)
        relaunched.prepare(generation: UUID())
        #expect(relaunched.stage == .completed && !relaunched.isActive)
        tutorial.resetForNextPlay()
        #expect(!tutorial.isCompleted && tutorial.stage == .notStarted)
    }

    @Test func completedVisitDoesNotHoldRetryOrPlayAgain() async throws {
        let defaults = store(), tutorial = LeanTutorial(defaults: store())
        // A separate isolated store verifies real relaunch construction as well.
        let persisted = LeanTutorial(defaults: defaults), generation = UUID()
        persisted.prepare(generation: generation)
        persisted.beginIfEligible(generation: generation, eligible: true)
        persisted.skip(generation: generation)
        defer { defaults.removeObject(forKey: LeanTutorial.completionKey) }
        func make() throws -> GameSessionCoordinator {
            let script = try LaserReplayScript.load().freshRound(generation: UUID())
            return GameSessionCoordinator(provider: ControlledSessionInput(), inputConfiguration: script.input.configuration)
        }
        let flow = LaserInputFlow(leanTutorial: LeanTutorial(defaults: defaults), makeLiveSession: make)
        await flow.startLiveSetup()
        let first = flow.session?.inputConfiguration.sessionGeneration
        #expect(flow.session?.preRoundTutorialPending == false)
        await flow.retryLiveSetup()
        #expect(flow.session?.preRoundTutorialPending == false)
        #expect(flow.session?.inputConfiguration.sessionGeneration != first)
        await flow.closeLiveSetup()
        await flow.startLiveSetup()
        #expect(!flow.leanTutorial.isActive && flow.session?.preRoundTutorialPending == false)
        await flow.closeLiveSetup()
        #expect(!tutorial.isCompleted, "unrelated store does not inherit completion")
    }

    @Test func interruptedVisitDoesNotPersistOrAcceptLateActions() {
        let tutorial = LeanTutorial(defaults: store()), old = UUID(), new = UUID()
        tutorial.prepare(generation: old)
        tutorial.beginIfEligible(generation: old, eligible: true)
        tutorial.advance(generation: old)
        tutorial.abandon()
        tutorial.skip(generation: old)
        #expect(!tutorial.isCompleted)
        tutorial.prepare(generation: new)
        tutorial.beginIfEligible(generation: new, eligible: true)
        tutorial.advance(generation: old)
        #expect(tutorial.stage == .introduction)
    }

    @Test(arguments: [false, true]) func flowPreparesSoloOrCoopAndBackDoesNotComplete(solo: Bool) async throws {
        let tutorial = LeanTutorial(defaults: store())
        func make() throws -> GameSessionCoordinator {
            let script = try LaserReplayScript.load().freshRound(generation: UUID())
            return GameSessionCoordinator(provider: ControlledSessionInput(),
                inputConfiguration: script.input.configuration.replacingCalibrations([:]))
        }
        let flow = LaserInputFlow(leanTutorial: tutorial, makeLiveSession: make, makeSoloSession: make)
        await flow.startLiveSetup(solo: solo)
        #expect(flow.session?.preRoundTutorialPending == true)
        flow.presentLeanTutorialIfReady()
        #expect(!tutorial.isActive, "unaccepted setup cannot enter tutorial")
        await flow.closeLiveSetup()
        #expect(!tutorial.isCompleted && tutorial.generation == nil)
        await flow.startLiveSetup(solo: solo)
        #expect(flow.session?.preRoundTutorialPending == true)
        await flow.handleBackground()
        #expect(tutorial.generation == nil && flow.route == .selection)
    }
}
