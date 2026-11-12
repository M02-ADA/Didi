import RealityKit
import UIKit

/// Loaded once by LaserScene. Gem references the approved static 3D asset; Sparkle remains
/// the original artwork template. Clones share meshes/materials, never load on collection.
@MainActor
final class DiamondArt {
    private let gem: Entity
    private let sparkle: Entity
    init?(artwork: Entity) {
        guard let diamond = artwork.findEntity(named: "Diamond"),
              let gem = diamond.findEntity(named: "Gem"), let sparkle = diamond.findEntity(named: "Sparkle")
        else { return nil }
        self.gem = gem; self.sparkle = sparkle
    }
    func makeDiamond() -> Diamond {
        Diamond(gem: gem.clone(recursive: true), sparkles: (0..<4).map { _ in sparkle.clone(recursive: true) })
    }
}

/// Presentation only. Collection is requested by the existing committed domain outcome.
/// No tasks, clocks, event subscriptions, contacts or score authority live here.
@MainActor
final class Diamond {
    enum Phase { case ready, idle, collected, removed }
    private(set) var phase: Phase = .ready
    static let floatHeight: Float = 0.015
    static let collectDuration: TimeInterval = 0.24
    static let sparkleDuration: TimeInterval = 0.36
    static let effectLifetime: TimeInterval = 0.39
    static let sparkleDistance: Float = 0.22
    let root = Entity()
    private let body = Entity()
    private let gem: Entity
    private let flash: Entity
    private let sparkles: [Entity]

    fileprivate init(gem: Entity, sparkles: [Entity]) {
        self.gem = gem; self.sparkles = sparkles
        gem.transform = .identity
        flash = gem.clone(recursive: true)
        flash.name = "diamond.flash"
        Self.flashMaterial(flash)
        flash.isEnabled = false
        root.name = "diamond"
        root.addChild(body); body.addChild(gem); body.addChild(flash)
        for sparkle in sparkles {
            sparkle.transform = .identity; sparkle.isEnabled = false; root.addChild(sparkle)
        }
    }

    private static func flashMaterial(_ entity: Entity) {
        if let model = entity as? ModelEntity {
            model.model?.materials = model.model?.materials.map { _ in
                UnlitMaterial(color: UIColor(red: 0.7, green: 0.95, blue: 1, alpha: 1))
            } ?? []
        }
        for child in entity.children { flashMaterial(child) }
    }

    func showIdle(reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled) {
        guard phase == .ready else { return }
        phase = .idle
        guard !reduceMotion else { return }
        var raised = Transform.identity; raised.translation.y = Self.floatHeight
        loop(body, to: raised, duration: 0.85)
        var rocked = Transform.identity
        rocked.rotation = simd_quatf(angle: .pi / 60, axis: [0, 1, 0])
        loop(gem, to: rocked, duration: 1.2)
    }

    func collect(reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled) {
        guard phase == .ready || phase == .idle else { return }
        phase = .collected
        // Preserve the visible float offset when idle stops; the target root never moves.
        body.stopAllAnimations(); gem.stopAllAnimations()
        gem.transform = .identity
        fade(gem, from: 1, to: 0, duration: Self.collectDuration)
        guard !reduceMotion else { return }
        var popped = Transform.identity; popped.scale = .init(repeating: 1.3)
        var gone = Transform.identity; gone.scale = .init(repeating: 0.05)
        sequence(gem, transforms: [(.identity, popped, 0.08), (popped, gone, 0.16)])
        flash.isEnabled = true
        var halo = Transform.identity; halo.scale = .init(repeating: 1.08)
        flash.transform = halo
        fade(flash, from: 0.65, to: 0, duration: 0.10)
        for (sparkle, direction) in zip(sparkles, [SIMD2<Float>(1, 1), [-1, 1], [1, -1], [-1, -1]]) {
            var start = Transform.identity; start.scale = .init(repeating: 0.25)
            var end = Transform.identity; end.scale = .init(repeating: 0.08)
            end.translation = SIMD3(normalize(direction) * Self.sparkleDistance, 0.01)
            sparkle.isEnabled = true
            sequence(sparkle, transforms: [(start, end, Self.sparkleDuration)])
            fade(sparkle, from: 1, to: 0, duration: Self.sparkleDuration)
        }
    }

    func remove() {
        guard phase == .ready || phase == .idle else { return }
        phase = .removed
        body.stopAllAnimations(); gem.stopAllAnimations()
        fade(gem, from: 1, to: 0, duration: 0.2)
    }

    /// Explicit reset for a reusable, still-owned visual. A retired target is terminal.
    func reset() {
        guard phase != .removed else { return }
        root.stopAllAnimations(recursive: true)
        body.transform = .identity
        gem.transform = .identity
        gem.components.remove(OpacityComponent.self)
        flash.isEnabled = false
        for sparkle in sparkles {
            sparkle.components.remove(OpacityComponent.self)
            sparkle.isEnabled = false
        }
        phase = .ready
    }

    /// Stops all native animation controllers on teardown; no completion callback can revive it.
    func retire() {
        phase = .removed
        root.stopAllAnimations(recursive: true)
        root.removeFromParent()
    }

    private func loop(_ part: Entity, to: Transform, duration: TimeInterval) {
        let definition = FromToByAnimation(from: Transform.identity, to: to, duration: duration,
            timing: .easeInOut, bindTarget: .transform, repeatMode: .autoReverse)
        if let animation = try? AnimationResource.generate(with: definition).repeat() {
            part.playAnimation(animation, handoffType: .compose)
        }
    }
    private func sequence(_ part: Entity, transforms: [(Transform, Transform, TimeInterval)]) {
        let resources = transforms.compactMap { from, to, duration in
            try? AnimationResource.generate(with: FromToByAnimation(from: from, to: to,
                duration: duration, timing: .easeOut, bindTarget: .transform))
        }
        if let resource = try? AnimationResource.sequence(with: resources) {
            part.transform = transforms[0].0
            part.playAnimation(resource, handoffType: .compose)
        }
    }
    private func fade(_ part: Entity, from: Float, to: Float, duration: TimeInterval) {
        part.components.set(OpacityComponent(opacity: to))
        if let resource = try? AnimationResource.generate(with: FromToByAnimation(from: from, to: to,
            duration: duration, timing: .easeIn, bindTarget: .opacity)) {
            part.playAnimation(resource, handoffType: .compose)
        }
    }
}
