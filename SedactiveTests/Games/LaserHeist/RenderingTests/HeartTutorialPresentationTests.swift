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
    @Test func illustrativeBeamIsIndependentDeduplicatedAndRemoved() {
        let scene = LaserScene(), demo = HeartTutorialDemo()
        let normalVisibility = scene.isLaserVisible
        demo.update(scene: scene, visible: true)
        let root = demo.beam?.root
        #expect(root?.parent === scene.root)
        #expect(demo.beam?.span == scene.fullLaserSpan)
        #expect(root?.components[CollisionComponent.self] == nil)
        demo.update(scene: scene, visible: true)
        #expect(demo.beam?.root === root)
        #expect(scene.isLaserVisible == normalVisibility)
        demo.update(scene: scene, visible: false)
        #expect(demo.beam == nil && root?.parent == nil)
        demo.stop()
        #expect(scene.isLaserVisible == normalVisibility)
    }
}
