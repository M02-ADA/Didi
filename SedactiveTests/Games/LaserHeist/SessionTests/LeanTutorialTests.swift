import Foundation
import Testing
@testable import Sedactive

@MainActor struct LeanTutorialTests {
    struct Fixture {
        let generation = UUID(), epoch = UUID(), binding = UUID()
        let defaults = UserDefaults(suiteName: "LeanAuto.\(UUID())")!
        var roster: [PlayerID] = [.player1]
        var context: BodyInputContext {
            .init(sessionGeneration: generation, cameraGeometryRevision: 1,
                calibrationRevisions: Dictionary(uniqueKeysWithValues: roster.map { ($0, 1) }),
                cutovers: Dictionary(uniqueKeysWithValues: roster.map { ($0, .init(frameID: 0, capturedAt: 0)) }),
                isActive: true, wristContact: .init(sourceEpoch: epoch, controlRevision: 1, bindingRequestID: binding,
                    bindingFrameID: 0, bindingCapturedAt: 0, acceptedContextRevision: 1, freshness: 0.25))
        }
        func observation(_ id: UInt64, _ time: Double, _ command: Float, _ velocity: Float, _ x: Float,
                         players: [PlayerID]? = nil) -> LeanMovementObservation {
            .init(source: .init(context: .init(generation: generation, epoch: epoch, geometryRevision: 1,
                imageWidth: 1920, imageHeight: 1080, rotationAngle: 0, mirrored: false),
                frameID: id, capturedAt: time, controlRevision: 1), context: context,
                players: Dictionary(uniqueKeysWithValues: (players ?? roster).map {
                    ($0, .init(command: command, velocity: velocity, x: x + ($0 == .player1 ? -0.7 : 0.7))) }))
        }
        func tutorial() -> LeanTutorial {
            let tutorial = LeanTutorial(defaults: defaults)
            tutorial.prepare(generation: generation, roster: roster)
            tutorial.beginIfEligible(generation: generation, eligible: true)
            tutorial.introductionVisible(true, generation: generation)
            tutorial.finishIntroduction(generation: generation)
            tutorial.practiceVisible(.practiceLeft, generation: generation, at: 0)
            return tutorial
        }
        func send(_ tutorial: LeanTutorial, _ id: UInt64, _ command: Float, _ velocity: Float, _ x: Float,
                  players: [PlayerID]? = nil) {
            let t = Double(id) / 10
            tutorial.observe(observation(id, t, command, velocity, x, players: players), generation: generation, at: t + 0.01)
        }
        func finishLean(_ tutorial: LeanTutorial) {
            send(tutorial, 1, 0, 0, 0); send(tutorial, 2, -1, -1, -0.1); send(tutorial, 3, -1, -1, -0.2)
            tutorial.practiceVisible(.practiceRight, generation: generation, at: 0.31)
            send(tutorial, 4, 0, 0, -0.2); send(tutorial, 5, 1, 1, -0.1); send(tutorial, 6, 1, 1, 0)
        }
        func finishPhase(_ tutorial: LeanTutorial, _ phase: HeartTutorialPhase, generation: UUID? = nil) {
            let gen = generation ?? self.generation
            if phase == .hurt {
                let input = try! LaserReplayScript.load().freshRound(generation: gen).input
                let context = BodyInputContext(sessionGeneration: gen, cameraGeometryRevision: 1,
                    calibrationRevisions: Dictionary(uniqueKeysWithValues: roster.map { ($0, 1) }),
                    cutovers: Dictionary(uniqueKeysWithValues: roster.map { ($0, .init(frameID: 0, capturedAt: 0)) }), isActive: true)
                var training = try! HeartTrainingEncounter(configuration: try LaserReplayScript.load().configuration, context: context, roster: Set(roster))
                for i in 0...20 { training.update(at: Double(i) / 10, eligible: true, context: context) }
                training.finishFeedback(id: training.id, generation: gen)
                tutorial.finishTrainingEncounter(training, generation: gen)
            } else { tutorial.finishHeart(phase, generation: gen) }
        }
        func finishHeart(_ tutorial: LeanTutorial) {
            for phase in HeartTutorialPhase.allCases {
                tutorial.heartVisible(phase, visible: true, generation: generation)
                finishPhase(tutorial, phase)
            }
        }
        func finishPractice(_ tutorial: LeanTutorial, generation: UUID? = nil) {
            let gen = generation ?? self.generation
            tutorial.finishJumpDuckIntroduction(generation: gen)
            var p = try! FTUELaserPracticeTests.make(coop: roster.count == 2, generation: gen)
            for i in 0...1 {
                try! FTUELaserPracticeTests.run(&p, clear: Set(roster), start: 1000 + Double(i) * 10)
                try! p.feedbackFinished(attempt: p.attemptID, generation: gen)
                tutorial.synchronizePractice(p, generation: gen)
            }
        }
        func finishProgress(_ tutorial: LeanTutorial, generation: UUID? = nil) {
            let generation = generation ?? self.generation
            for i in 0...40 { tutorial.progressJourney.update(stage: tutorial.stage, generation: generation, at: Double(i) / 50, active: true) }
            for phase in ProgressTutorialPhase.allCases {
                tutorial.progressVisible(phase, visible: true, generation: generation)
                tutorial.finishProgress(phase, generation: generation)
            }
        }
        func finish(_ tutorial: LeanTutorial) { finishLean(tutorial); finishHeart(tutorial); finishPractice(tutorial); finishProgress(tutorial) }
    }

    @Test func introRequiresVisibleCurrentGenerationAndDoesNotInferPractice() {
        let f = Fixture(), tutorial = LeanTutorial(defaults: Fixture().defaults)
        tutorial.prepare(generation: f.generation)
        tutorial.beginIfEligible(generation: f.generation, eligible: false)
        #expect(!tutorial.isActive)
        tutorial.beginIfEligible(generation: f.generation, eligible: true)
        tutorial.finishIntroduction(generation: f.generation)
        #expect(tutorial.stage == .introduction)
        tutorial.introductionVisible(true, generation: f.generation)
        tutorial.finishIntroduction(generation: UUID())
        #expect(tutorial.stage == .introduction)
        tutorial.finishIntroduction(generation: f.generation)
        tutorial.finishIntroduction(generation: f.generation)
        #expect(tutorial.stage == .practiceLeft && !tutorial.isCompleted)
    }
    @Test(arguments: [false, true]) func bothDirectionsPersistOnlyAfterRosterDemonstration(coop: Bool) {
        var f = Fixture(); if coop { f.roster = PlayerID.allCases }
        defer { f.defaults.removeObject(forKey: LeanTutorial.completionKey); f.defaults.removeObject(forKey: LeanTutorial.heartCompletionKey) }
        let tutorial = f.tutorial(); f.finish(tutorial)
        #expect(tutorial.stage == .completed && tutorial.isCompleted)
        let relaunched = LeanTutorial(defaults: f.defaults)
        relaunched.prepare(generation: UUID(), roster: f.roster)
        #expect(relaunched.stage == .completed && !relaunched.isActive)
        tutorial.resetForNextPlay(); #expect(!tutorial.isCompleted)
    }
    @Test func staticPositionHeldLeanCoastingAndDuplicateFramesCannotComplete() {
        let f = Fixture(), tutorial = f.tutorial()
        f.send(tutorial, 1, -1, -1, -1); f.send(tutorial, 2, -1, -1, -2)
        #expect(tutorial.demonstrated.isEmpty, "already-held lean has no fresh neutral")
        f.send(tutorial, 3, 0, 0, -2); f.send(tutorial, 4, 0, -1, -3)
        f.send(tutorial, 5, -1, -1, -4)
        #expect(tutorial.demonstrated.isEmpty, "coasting is not intentional commanded movement")
        f.send(tutorial, 6, 0, 0, -4); f.send(tutorial, 7, -1, -1, -4)
        #expect(tutorial.demonstrated.isEmpty, "a static wall position is not proof")
        f.send(tutorial, 8, 0, 0, -4); f.send(tutorial, 9, -1, -1, -4.1)
        f.send(tutorial, 9, -1, -1, -4.2)
        #expect(tutorial.stage == .practiceLeft)
        f.send(tutorial, 10, -1, -1, -4.3)
        #expect(tutorial.stage == .practiceRight)
    }
    @Test(arguments: ["valid", "free", "wrong", "held", "stale", "paused", "generation", "missing"])
    func boundaryProofRequiresFreshRearmedDirectionalInput(scenario: String) {
        let f = Fixture(), tutorial = f.tutorial()
        func send(_ id: UInt64, command: Float, blocked: Float, generation: UUID? = nil) {
            let t = Double(id) / 10
            let observation = f.observation(id, t, command, 0, -2)
            tutorial.observe(.init(source: observation.source, context: observation.context,
                players: [.player1: .init(command: command, velocity: 0, x: -2, blockedDirection: blocked)]),
                generation: generation ?? f.generation, at: t + 0.01)
        }
        if scenario != "held" { send(1, command: 0, blocked: 0) }
        if scenario == "paused" {
            tutorial.setSuspended(true, generation: f.generation)
            tutorial.setSuspended(false, generation: f.generation)
            tutorial.practiceVisible(.practiceLeft, generation: f.generation, at: 0.15)
        }
        if scenario == "missing" { tutorial.observe(nil, generation: f.generation, at: 0.15) }
        let command: Float = scenario == "wrong" ? 1 : -1
        let blocked: Float = scenario == "free" ? 0 : -1
        send(2, command: command, blocked: blocked, generation: scenario == "generation" ? UUID() : nil)
        send(scenario == "stale" ? 2 : 3, command: command, blocked: blocked,
             generation: scenario == "generation" ? UUID() : nil)
        let accepted = scenario == "valid"
        #expect(tutorial.stage == (accepted ? .practiceRight : .practiceLeft))
        if !accepted {
            // BODY neutral rearms at the SAME world position, no opposite translation.
            send(4, command: 0, blocked: 0)
            send(5, command: -1, blocked: -1); send(6, command: -1, blocked: -1)
            #expect(tutorial.stage == .practiceRight)
        }
        tutorial.practiceVisible(.practiceRight, generation: f.generation, at: 0.65)
        send(7, command: 0, blocked: 0)
        send(8, command: 1, blocked: 1); send(9, command: 1, blocked: 1)
        #expect(tutorial.stage == .heart(.introduction))
    }

    @Test func coopBoundaryProofBelongsOnlyToTheObservedPlayer() {
        var f = Fixture(); f.roster = PlayerID.allCases
        let tutorial = f.tutorial()
        func send(_ id: UInt64, _ players: [PlayerID: LeanMovementObservation.Reading]) {
            let t = Double(id) / 10, original = f.observation(id, Double(id) / 10, 0, 0, 0)
            tutorial.observe(.init(source: original.source, context: original.context, players: players),
                generation: f.generation, at: t + 0.01)
        }
        send(1, [.player1: .init(command: 0, velocity: 0, x: -2)])
        for id: UInt64 in [2, 3] {
            send(id, [.player1: .init(command: -1, velocity: 0, x: -2, blockedDirection: -1)])
        }
        #expect(tutorial.stage == .practiceLeft && tutorial.demonstrated == [.player1])
        // Missing P2, static position, and inward-to-the-wrong-constraint cannot substitute.
        send(4, [.player2: .init(command: 0, velocity: 0, x: -1)])
        send(5, [.player2: .init(command: -1, velocity: 0, x: -1, blockedDirection: 1)])
        #expect(tutorial.stage == .practiceLeft)
        send(6, [.player2: .init(command: 0, velocity: 0, x: -1)])
        for id: UInt64 in [7, 8] {
            send(id, [.player2: .init(command: -1, velocity: 0, x: -1, blockedDirection: -1)])
        }
        #expect(tutorial.stage == .practiceRight)
    }

    @Test func coopPlayersDemonstrateIndependentlyAndNeitherCanSubstituteForTheOther() {
        var f = Fixture(); f.roster = PlayerID.allCases
        let tutorial = f.tutorial()
        f.send(tutorial, 1, 0, 0, 0, players: [.player1])
        f.send(tutorial, 2, -1, -1, -0.1, players: [.player1])
        f.send(tutorial, 3, -1, -1, -0.2, players: [.player1])
        #expect(tutorial.demonstrated == [.player1] && tutorial.stage == .practiceLeft)
        f.send(tutorial, 4, 0, 0, 0, players: [.player2])
        f.send(tutorial, 5, -1, -1, -0.1, players: [.player2])
        f.send(tutorial, 6, -1, -1, -0.2, players: [.player2])
        #expect(tutorial.stage == .practiceRight && tutorial.demonstrated.isEmpty)
    }
    @Test func missingEvidencePauseAndGenerationCutoverRequireFreshNeutral() {
        let f = Fixture(), tutorial = f.tutorial()
        f.send(tutorial, 1, 0, 0, 0); f.send(tutorial, 2, -1, -1, -0.1)
        tutorial.observe(nil, generation: f.generation, at: 0.21)
        f.send(tutorial, 3, -1, -1, -0.2); f.send(tutorial, 4, -1, -1, -0.3)
        #expect(tutorial.stage == .practiceLeft)
        tutorial.setSuspended(true, generation: f.generation)
        f.send(tutorial, 5, 0, 0, -0.3); f.send(tutorial, 6, -1, -1, -0.4)
        tutorial.setSuspended(false, generation: f.generation)
        tutorial.practiceVisible(.practiceLeft, generation: f.generation, at: 0.65)
        tutorial.observe(f.observation(7, 0.7, -1, -1, -0.5), generation: UUID(), at: 0.71)
        f.send(tutorial, 7, -1, -1, -0.5)
        #expect(tutorial.demonstrated.isEmpty)
        f.send(tutorial, 8, 0, 0, -0.5); f.send(tutorial, 9, -1, -1, -0.6); f.send(tutorial, 10, -1, -1, -0.7)
        #expect(tutorial.stage == .practiceRight)
        tutorial.abandon()
        tutorial.finishIntroduction(generation: f.generation)
        #expect(!tutorial.isCompleted && tutorial.generation == nil)
    }
    @Test func sourceContextCutoverAndStaleCaptureCannotReuseProof() {
        let f = Fixture(), tutorial = f.tutorial()
        f.send(tutorial, 1, 0, 0, 0); f.send(tutorial, 2, -1, -1, -0.1)
        let old = f.observation(3, 0.3, -1, -1, -0.2)
        tutorial.observe(old, generation: f.generation, at: 2)
        #expect(tutorial.stage == .practiceLeft)
        let changed = BodyInputContext(sessionGeneration: f.generation, cameraGeometryRevision: 2,
            calibrationRevisions: f.context.calibrationRevisions, cutovers: f.context.cutovers,
            isActive: true, wristContact: f.context.wristContact)
        tutorial.observe(.init(source: old.source, context: changed, players: old.players), generation: f.generation, at: 0.31)
        #expect(tutorial.demonstrated.isEmpty)
    }
    @Test(arguments: [false, true]) func flowRequiresAcceptedSetupAndRetainsCompletionAcrossRetry(solo: Bool) async throws {
        let f = Fixture(), tutorial = f.tutorial(); f.finish(tutorial)
        defer { f.defaults.removeObject(forKey: LeanTutorial.completionKey); f.defaults.removeObject(forKey: LeanTutorial.heartCompletionKey) }
        func make() throws -> GameSessionCoordinator {
            let script = try LaserReplayScript.load().freshRound(generation: UUID())
            return GameSessionCoordinator(provider: ControlledSessionInput(), inputConfiguration: script.input.configuration)
        }
        let flow = LaserInputFlow(leanTutorial: LeanTutorial(defaults: f.defaults), makeLiveSession: make, makeSoloSession: make)
        await flow.startLiveSetup(solo: solo)
        #expect(flow.session?.preRoundTutorialPending == false && flow.isSolo == solo)
        await flow.retryLiveSetup()
        #expect(flow.session?.preRoundTutorialPending == false && !flow.leanTutorial.isActive)
        await flow.handleBackground()
        #expect(flow.route == .selection)
        tutorial.resetForNextPlay()
        await flow.startLiveSetup(solo: solo)
        flow.presentLeanTutorialIfReady()
        #expect(!flow.leanTutorial.isActive && flow.session?.preRoundTutorialPending == true)
        await flow.closeLiveSetup()
        #expect(flow.leanTutorial.generation == nil)
    }
}
