import Foundation
import Testing
@testable import Sedactive

@MainActor struct HeartTrainingEncounterTests {
    @Test(arguments: [false, true])
    func crossingAuthorizesOneSharedDeductionWithoutNormalVerdicts(coop: Bool) throws {
        let input = try LaserReplayScript.load().input
        let roster: Set<PlayerID> = coop ? Set(PlayerID.allCases) : [.player1]
        let context = BodyInputContext(sessionGeneration: input.configuration.sessionGeneration, cameraGeometryRevision: 1,
            calibrationRevisions: input.configuration.calibrations.mapValues(\.revision), cutovers: [:], isActive: true)
        var lesson = try HeartTrainingEncounter(configuration: try LaserReplayScript.load().configuration, context: context, roster: roster)
        for i in 0...17 { lesson.update(at: Double(i) / 10, eligible: true, context: context) }
        #expect(lesson.damage == nil && lesson.state.teamHealth == 5)
        for i in 18...60 { lesson.update(at: Double(i) / 10, eligible: true, context: context) }
        #expect(lesson.damage?.players == roster && lesson.state.teamHealth == 4)
        #expect(lesson.events.map(\.kind) == [.teamDamaged(amount: 1, remainingHealth: 4)])
        #expect(lesson.state.teamScore == 0 && lesson.state.encounters.isEmpty && lesson.state.activityProgress == 0)
        lesson.finishFeedback(id: UUID(), generation: context.sessionGeneration)
        #expect(!lesson.feedbackFinished)
        lesson.finishFeedback(id: lesson.id, generation: UUID())
        #expect(!lesson.feedbackFinished)
        lesson.finishFeedback(id: lesson.id, generation: context.sessionGeneration)
        #expect(lesson.feedbackFinished)
        let ordinary = try LaserGame(configuration: try LaserReplayScript.load().configuration, context: context, historyCapacityPerPlayer: 8)
        #expect(ordinary.teamHealth == 5, "existing fresh-round initialization, no UI healing")
        var normal = ordinary
        #expect(normal.commitHeartTrainingDamage(id: lesson.id, players: roster) == nil)
        #expect(normal.teamHealth == 5 && normal.drainEvents().isEmpty)
    }
    @Test(arguments: [false, true])
    func airborneInputCannotEarnTrainingClearOrPreventScriptedDeduction(coop: Bool) throws {
        let script = try LaserReplayScript.load(), input = script.input
        let roster: Set<PlayerID> = coop ? Set(PlayerID.allCases) : [.player1]
        let context = BodyInputContext(sessionGeneration: input.configuration.sessionGeneration, cameraGeometryRevision: 1,
            calibrationRevisions: input.configuration.calibrations.mapValues(\.revision), cutovers: [:], isActive: true)
        let sequence = try RobotDemoSequence(configuration: input.configuration,
            cameraGeometryRevision: input.cameraGeometryRevision, only: .bothJump)
        let frames = try (UInt64(1)...120).map { try sequence.frame($0).snapshot }
        let airborne = try #require(frames.first { $0.players[.player1]?.jumpState.phase == .airborne })
        #expect(airborne.players[.player1]?.jumpState.validity == .valid)
        let id = UUID()
        var game = try LaserGame.heartTraining(configuration: script.configuration, context: context, id: id)
        // Real input semantics are preserved; the explicit teaching policy simply has no
        // avoidance targets. It must never turn this valid airborne evidence into a fake HIT.
        try game.receive(airborne, capturedGameTime: 0.1, arrivedAt: 0.1)
        #expect(throws: LaserDataError.self) { try game.register(script.encounters[0]) }
        try game.advance(to: HeartTrainingEncounter.crossingTime)
        #expect(game.commitHeartTrainingDamage(id: id, players: roster)?.remainingHealth == 4)
        #expect(game.commitHeartTrainingDamage(id: id, players: roster) == nil)
        #expect(game.drainEvents().map(\.kind) == [.teamDamaged(amount: 1, remainingHealth: 4)])
        #expect(game.teamScore == 0)
    }

    @Test func pauseGapsAndContextReplacementCannotProduceHiddenOrDuplicateDamage() throws {
        let input = try LaserReplayScript.load().input
        let context = BodyInputContext(sessionGeneration: input.configuration.sessionGeneration, cameraGeometryRevision: 1,
            calibrationRevisions: input.configuration.calibrations.mapValues(\.revision), cutovers: [:], isActive: true)
        var lesson = try HeartTrainingEncounter(configuration: try LaserReplayScript.load().configuration, context: context, roster: [.player1])
        lesson.update(at: 0, eligible: true, context: context)
        lesson.update(at: 0.1, eligible: true, context: context)
        lesson.update(at: 0.05, eligible: true, context: context)
        lesson.update(at: 0.1, eligible: true, context: context)
        #expect(abs(lesson.elapsed - 0.1) < 0.001, "older and duplicate ticks do not move the anchor")
        lesson.update(at: 0.2, eligible: false, context: context)
        lesson.update(at: 20, eligible: false, context: context)
        lesson.update(at: 21, eligible: true, context: context)
        #expect(abs(lesson.elapsed - 0.1) < 0.001 && lesson.damage == nil)
        lesson.update(at: 80, eligible: true, context: context)
        #expect(abs(lesson.elapsed - 0.1) < 0.001)
        lesson.update(at: 80.1, eligible: true, context: nil)
        #expect(lesson.invalidated)
        for i in 0...30 { lesson.update(at: 81 + Double(i) / 10, eligible: true, context: context) }
        #expect(lesson.damage == nil && lesson.state.teamHealth == 5)
    }
    @Test func zappedPauseAndCanceledViewCannotCompleteFeedback() {
        let model = LaserTeamCalloutModel(), start = Date(timeIntervalSince1970: 100)
        model.show(.zapped, compact: false, at: start)
        let serial = model.shown!.serial
        model.setTutorialSuspended(true, at: start.addingTimeInterval(0.2))
        model.finish(serial)
        #expect(model.shown != nil && model.finishedSerial == nil)
        model.setTutorialSuspended(false, at: start.addingTimeInterval(10.2))
        #expect(model.shown!.start == start.addingTimeInterval(10))
        model.finish(serial)
        #expect(model.shown == nil && model.finishedSerial == serial)
        model.clear()
        #expect(model.finishedSerial == nil)
    }
}
