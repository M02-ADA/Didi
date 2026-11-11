import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// The corridor's atmospheric depth: one haze curve shared by the hall, its
/// streaming parts and the laser gates, which emerge from deep inside it.
@MainActor
struct CorridorDepthTests {
    @Test("The haze is clear near the players and deepens smoothly down the hall")
    func hazeCurve() {
        #expect(CorridorDepth.haze(atDistance: 0) == 0)
        #expect(CorridorDepth.haze(atDistance: CorridorDepth.hazeStart) == 0)
        #expect(abs(CorridorDepth.haze(atDistance: 200) - CorridorDepth.maximumHaze) < 1e-6)
        var previous: Float = 0
        for d in stride(from: Float(0), through: 80, by: 0.5) {
            let h = CorridorDepth.haze(atDistance: d)
            #expect(h >= previous - 1e-6)
            previous = h
        }
        // Where a warning begins (about 15.6 m out), the gate is still essentially clear.
        #expect(CorridorDepth.haze(atDistance: 3.1 + 15.6) < 0.05)
    }

    @Test("A gate fades with its distance and is fully clear near the players")
    func gatesFadeByDistance() {
        let scene = LaserScene()
        let hazard = scene.makeLaneHazard(for: .player1)
        hazard.setDepth(-55)
        let far = hazard.root.components[OpacityComponent.self]?.opacity ?? 1
        hazard.setDepth(-30)
        let middle = hazard.root.components[OpacityComponent.self]?.opacity ?? 1
        hazard.setDepth(-2)
        #expect(far < 0.3 && middle > far && middle < 1)
        #expect(hazard.root.components[OpacityComponent.self] == nil, "no fade at the players")
    }

    @Test("Gates come into view from deep in the haze, not at the old 22 m spawn point")
    func gatesEmergeFromFarAway() {
        let scene = LaserScene()
        let lead = GameplayScenePresenter.approachLead(in: scene)
        #expect(abs(lead - Double((scene.mapping.interactionPlaneZ - scene.layout.laserEmergeZ) / scene.layout.travelSpeed)) < 1e-9)
        #expect(scene.layout.laserEmergeZ < scene.layout.laserSpawnZ - 30)
    }
}
