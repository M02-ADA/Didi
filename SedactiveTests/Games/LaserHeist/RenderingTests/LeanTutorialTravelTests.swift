import Foundation
import RealityKit
import Testing
@testable import Sedactive

@MainActor struct LeanTutorialTravelTests {
    private func scene() async throws -> LaserScene {
        let scene = LaserScene()
        scene.installEnvironment(authored: try #require(await LaserScene.loadAuthoredEnvironment()))
        return scene
    }
    @Test func practiceScrollsAtNormalSpeedWithoutCompletingAnythingAndHandsOffToHeart() async throws {
        let scene = try await scene(), travel = LeanTutorialTravel(), f = LeanTutorialTests.Fixture()
        let tutorial = f.tutorial()
        // Actual authored streaming group transforms, not a proxy world-space avatar Z.
        let group = try #require(scene.root.findEntity(named: "Travel"))
        func tick(_ t: Double, eligible: Bool = true) {
            travel.update(scene: scene, tutorial: tutorial, generation: f.generation, at: t, eligible: eligible)
        }
        tick(1); tick(1.1)
        #expect(abs(scene.travelOffset - scene.layout.travelSpeed * 0.1) < 0.00001)
        #expect(group.position.z == scene.travelOffset && tutorial.stage == .practiceLeft)
        let before = scene.travelOffset
        tick(1.2); #expect(scene.travelOffset > before)
        #expect(tutorial.demonstrated.isEmpty, "travel cannot fabricate Lean completion or progress")
        #expect(tutorial.progressJourney.fillEnd == FTUEProgressJourney.initial)
        // Complete LEFT with existing accepted synthetic evidence; travel continues in RIGHT.
        f.send(tutorial, 1, 0, 0, 0); f.send(tutorial, 2, -1, -1, -0.1); f.send(tutorial, 3, -1, -1, -0.2)
        #expect(tutorial.stage == .practiceRight)
        tick(1.3); #expect(scene.travelOffset > before)
        tutorial.practiceVisible(.practiceRight, generation: f.generation, at: 0.31)
        f.send(tutorial, 4, 0, 0, -0.2); f.send(tutorial, 5, 1, 1, -0.1); f.send(tutorial, 6, 1, 1, 0)
        #expect(tutorial.heartPhase == .introduction)
        let handoff = scene.travelOffset
        tick(1.4); tick(1.5)
        #expect(scene.travelOffset == handoff, "no backwards reset or competing writes at Heart entry")
        // Later presenter owns travel; the Lean owner must not overwrite it.
        scene.setTravelDistance(handoff + 1); tick(1.6)
        #expect(abs(scene.travelOffset - handoff - 1) < 0.00001)
        travel.stop(); #expect(scene.travelOffset == 0)
    }
    @Test func pauseTrackingLossGenerationReplacementAndStopCannotAccumulateOrLeakTravel() async throws {
        let scene = try await scene(), travel = LeanTutorialTravel(), f = LeanTutorialTests.Fixture()
        let tutorial = f.tutorial()
        func tick(_ t: Double, _ eligible: Bool = true, _ generation: UUID? = nil) {
            travel.update(scene: scene, tutorial: tutorial, generation: generation ?? f.generation, at: t, eligible: eligible)
        }
        tick(1); tick(1.1); let moved = scene.travelOffset
        tutorial.setSuspended(true, generation: f.generation); tick(2)
        tutorial.setSuspended(false, generation: f.generation); tick(10)
        #expect(scene.travelOffset == moved)
        tick(10.1, false); tick(20)
        #expect(scene.travelOffset == moved, "no missing-readiness catch-up")
        travel.suspend(); tick(40)
        #expect(scene.travelOffset == moved)
        tick(40.1, true, UUID()); #expect(scene.travelOffset == moved)
        travel.stop(); tick(41); tick(41.1)
        #expect(scene.travelOffset == 0, "late callbacks cannot restart a retired generation")
        tutorial.prepare(generation: UUID(), replayRequested: true)
        tutorial.beginIfEligible(generation: tutorial.generation!, eligible: true)
        tutorial.introductionVisible(true, generation: tutorial.generation!)
        tutorial.finishIntroduction(generation: tutorial.generation!)
        tick(50, true, tutorial.generation); tick(50.1, true, tutorial.generation)
        #expect(scene.travelOffset > 0, "a new Help/session generation owns its own travel")
        tutorial.abandon(); let stopped = scene.travelOffset
        tick(51); #expect(scene.travelOffset == stopped)
        travel.stop()
    }
}
