import RealityKit

/// An illustrative laser owned only by the held tutorial scene. No target, collider,
/// verdict, damage event, input subscription or clock. Never touches the gameplay laser.
@MainActor final class HeartTutorialDemo {
    private(set) var beam: LaserHazard?
    func update(scene: LaserScene, visible: Bool) {
        guard visible else { stop(); return }
        guard beam == nil else { return }
        let k = scene.mapping.metersPerGameUnit
        guard k.isFinite, k > 0 else { return }
        let height = RobotAvatarLayer.standingHeight * 0.8 / k
        let demo = LaserHazard(name: "heartTutorialDemo", span: scene.fullLaserSpan,
            band: (height - 0.009 / k)...(height + 0.009 / k), mapping: scene.mapping, fallbackThickness: 0.018)
        demo.setDepth(scene.mapping.interactionPlaneZ + 0.08)
        demo.setState(.active)
        scene.root.addChild(demo.root)
        beam = demo
    }
    func stop() { beam?.root.removeFromParent(); beam = nil }
}
