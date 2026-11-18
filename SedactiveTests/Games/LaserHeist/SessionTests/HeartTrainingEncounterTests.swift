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
    @Test func pauseGapsAndContextReplacementCannotProduceHiddenOrDuplicateDamage() throws {
        let input = try LaserReplayScript.load().input
        let context = BodyInputContext(sessionGeneration: input.configuration.sessionGeneration, cameraGeometryRevision: 1,
            calibrationRevisions: input.configuration.calibrations.mapValues(\.revision), cutovers: [:], isActive: true)
        var lesson = try HeartTrainingEncounter(configuration: try LaserReplayScript.load().configuration, context: context, roster: [.player1])
        lesson.update(at: 0, eligible: true, context: context)
        lesson.update(at: 0.1, eligible: true, context: context)
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
