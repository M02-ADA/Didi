import SwiftUI
import RealityKit
import Testing
@testable import Sedactive

@MainActor struct HeartTutorialPresentationTests {
    @Test func suppliedThreeHeartImageAndFiniteExplanationsAreAvailable() throws {
        let image = try #require(UIImage(named: "LaserHeistUI/ftue-hearts"))
        #expect(image.size.width / image.size.height == 1240.0 / 588)
        #expect(HeartTutorialPhase.allCases.map(\.duration) == [4, 2, 4])
        #expect(HeartTutorialPhase.introduction.next == .hurt)
        #expect(HeartTutorialPhase.hurt.next == .warning)
        #expect(HeartTutorialPhase.warning.next == nil)
        #expect(HeartTutorialPhase.warning.copy.replacingOccurrences(of: "\n", with: " ") == "Your health will be deducted if you get hit by lasers")
    }
    @Test func trainingObstacleAndCorridorShareNormalTravelAndPauseCleanup() async throws {
        let scene = LaserScene(), demo = HeartTutorialDemo(), callouts = LaserTeamCalloutModel()
        scene.installEnvironment(authored: try #require(await LaserScene.loadAuthoredEnvironment()))
        let travelRoot = try #require(scene.root.findEntity(named: "Travel"))
        let input = try LaserReplayScript.load().input
        let context = BodyInputContext(sessionGeneration: input.configuration.sessionGeneration, cameraGeometryRevision: 1,
            calibrationRevisions: input.configuration.calibrations.mapValues(\.revision), cutovers: [:], isActive: true)
        var training = try HeartTrainingEncounter(configuration: try LaserReplayScript.load().configuration,
            context: context, roster: Set(PlayerID.allCases))
        training.update(at: 0, eligible: true, context: context)
        demo.update(scene: scene, training: training, callouts: callouts, suspended: false)
        let beam = try #require(demo.beam), start = beam.worldZ
        let camera = scene.layout.cameraPosition
        let players = scene.players.mapValues { $0.position }
        for i in 1...10 { training.update(at: Double(i) / 10, eligible: true, context: context) }
        demo.update(scene: scene, training: training, callouts: callouts, suspended: false)
        let travelled = scene.layout.travelSpeed * Float(training.elapsed)
        #expect(abs(beam.worldZ - start - travelled) < 0.0001)
        #expect(abs(travelRoot.position.z - travelled) < 0.0001)
        #expect(abs(scene.travelOffset - travelled) < 0.0001)
        #expect(abs(beam.worldZ - GameplayScenePresenter.obstacleDepth(in: scene,
            crossingTime: HeartTrainingEncounter.crossingTime, at: training.elapsed)) < 0.0001)
        #expect(scene.layout.cameraPosition == camera && scene.players.mapValues { $0.position } == players)
        let target = try LaserReplayScript.load().encounters[0].targets[0]
        let presenter = GameplayScenePresenter(scene: scene, configuration: try LaserReplayScript.load().configuration,
            encounters: [])
        #expect(presenter.depth(of: target, at: 0.7) == GameplayScenePresenter.obstacleDepth(in: scene,
            crossingTime: target.crossingTime, at: 0.7))
        training.update(at: 1.1, eligible: false, context: context)
        training.update(at: 9, eligible: false, context: context)
        demo.update(scene: scene, training: training, callouts: callouts, suspended: true)
        #expect(abs(beam.worldZ - start - travelled) < 0.0001 && training.damage == nil)
        demo.stop()
        #expect(beam.root.parent == nil && scene.travelOffset == 0 && travelRoot.position.z == 0)
    }

    @Test func trainingBeamUsesActualSceneAndCleansUp() throws {
        let scene = LaserScene(), demo = HeartTutorialDemo(), callouts = LaserTeamCalloutModel()
        let input = try LaserReplayScript.load().input
        let context = BodyInputContext(sessionGeneration: input.configuration.sessionGeneration, cameraGeometryRevision: 1,
            calibrationRevisions: input.configuration.calibrations.mapValues(\.revision), cutovers: [:], isActive: true)
        var training = try HeartTrainingEncounter(configuration: try LaserReplayScript.load().configuration, context: context, roster: Set(PlayerID.allCases))
        let normalVisibility = scene.isLaserVisible
        training.update(at: 0, eligible: true, context: context)
        demo.update(scene: scene, training: training, callouts: callouts, suspended: false)
        let root = try #require(demo.beam?.root)
        #expect(root.parent === scene.root && demo.beam?.span == scene.fullLaserSpan)
        #expect(root.components[CollisionComponent.self] == nil && callouts.shown == nil)
        let startZ = demo.beam!.worldZ
        for i in 1...20 { training.update(at: Double(i) / 10, eligible: true, context: context) }
        demo.update(scene: scene, training: training, callouts: callouts, suspended: false)
        #expect(demo.beam!.worldZ > startZ)
        #expect(abs(demo.beam!.worldZ - scene.mapping.interactionPlaneZ) < 0.001)
        #expect(callouts.shown?.kind == .zapped && training.state.teamHealth == 4)
        let serial = try #require(callouts.shown?.serial)
        demo.update(scene: scene, training: training, callouts: callouts, suspended: false)
        #expect(callouts.shown?.serial == serial)
        callouts.finish(serial)
        #expect(demo.feedbackFinished(callouts)?.id == training.id)
        demo.stop()
        #expect(root.parent == nil && demo.beam == nil && scene.isLaserVisible == normalVisibility)
    }
}
