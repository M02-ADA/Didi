//
//  Diamond.swift
//  Sedactive
//

import RealityKit
import UIKit

/// The diamond artwork (Diamonds.png) from the `Diamond` Reality Composer Pro
/// scene. It loads once; every diamond is a clone that shares its mesh and
/// texture.
@MainActor
final class DiamondArt {
    private let gem: Entity
    private let sparkle: Entity

    /// Returns `nil` when the artwork lacks a named part.
    init?(artwork: Entity) {
        guard let diamond = artwork.findEntity(named: "Diamond"),
              let gem = diamond.findEntity(named: "Gem"), let sparkle = diamond.findEntity(named: "Sparkle")
        else { return nil }
        self.gem = gem
        self.sparkle = sparkle
    }

    func makeDiamond() -> Diamond {
        Diamond(gem: gem.clone(recursive: true), sparkles: (0..<4).map { _ in sparkle.clone(recursive: true) })
    }
}

/// One diamond's look: floating while it approaches, then collected or
/// removed. Where it is and whether it was collected come from game state
/// (Jevon's diamonds and wrist contact); this only presents what it is told.
/// The flat image never spins, so it never turns edge-on.
@MainActor
final class Diamond {
    /// Temporary tuning values, not approved constants.
    static let floatHeight: Float = 0.035
    static let collectDuration: TimeInterval = 0.24
    static let sparkleDistance: Float = 0.22

    /// Place this; the float and effects move only its children.
    let root = Entity()
    private let body = Entity()
    private let gem: Entity
    private let sparkles: [Entity]

    fileprivate init(gem: Entity, sparkles: [Entity]) {
        self.gem = gem
        self.sparkles = sparkles
        gem.transform = .identity
        root.name = "diamond"
        root.addChild(body)
        body.addChild(gem)
        for sparkle in sparkles {
            sparkle.transform = .identity
            root.addChild(sparkle)
        }
        reset()
    }

    /// Gentle float and a small scale pulse. Static with Reduce Motion.
    func showIdle() {
        reset()
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        var raised = Transform.identity
        raised.translation.y = Self.floatHeight
        loop(body, from: .identity, to: raised, duration: 0.85)
        var swollen = Transform.identity
        swollen.scale = .init(repeating: 1.05)
        loop(gem, from: .identity, to: swollen, duration: 0.6)
    }

    /// A brief pop and fade, with four sparkles flying out. With Reduce Motion
    /// the diamond only fades.
    func collect() {
        stopMotion()
        fade(gem, from: 1, to: 0, duration: Self.collectDuration)
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        var popped = Transform.identity
        popped.scale = .init(repeating: 1.4)
        settle(gem, from: .identity, to: popped, duration: Self.collectDuration)
        for (sparkle, direction) in zip(sparkles, [SIMD2<Float>(1, 1), [-1, 1], [1, -1], [-1, -1]]) {
            var start = Transform.identity
            start.scale = .init(repeating: 0.3)
            var end = Transform.identity
            end.translation = SIMD3(normalize(direction) * Self.sparkleDistance, 0.01)
            sparkle.isEnabled = true
            settle(sparkle, from: start, to: end, duration: 0.36)
            fade(sparkle, from: 1, to: 0, duration: 0.36)
        }
    }

    /// Disappears cleanly, e.g. a missed diamond leaving play.
    func remove() {
        stopMotion()
        fade(gem, from: 1, to: 0, duration: 0.2)
    }

    /// Visible and still, ready to be shown again.
    func reset() {
        stopMotion()
        gem.transform = .identity
        gem.components.remove(OpacityComponent.self)
        for sparkle in sparkles {
            sparkle.stopAllAnimations()
            sparkle.isEnabled = false
        }
    }

    private func stopMotion() {
        body.stopAllAnimations()
        body.transform = .identity
        gem.stopAllAnimations()
    }

    private func loop(_ part: Entity, from: Transform, to: Transform, duration: TimeInterval) {
        let animation = FromToByAnimation(from: from, to: to, duration: duration, timing: .easeInOut,
                                          bindTarget: .transform, repeatMode: .autoReverse)
        if let resource = try? AnimationResource.generate(with: animation).repeat() {
            part.playAnimation(resource, handoffType: .compose)
        }
    }

    private func settle(_ part: Entity, from: Transform, to: Transform, duration: TimeInterval) {
        part.transform = to
        let animation = FromToByAnimation(from: from, to: to, duration: duration, timing: .easeOut, bindTarget: .transform)
        if let resource = try? AnimationResource.generate(with: animation) {
            part.playAnimation(resource, handoffType: .compose)
        }
    }

    private func fade(_ part: Entity, from: Float, to: Float, duration: TimeInterval) {
        part.components.set(OpacityComponent(opacity: to))
        let animation = FromToByAnimation<Float>(from: from, to: to, duration: duration, timing: .easeIn, bindTarget: .opacity)
        if let resource = try? AnimationResource.generate(with: animation) {
            part.playAnimation(resource, handoffType: .compose)
        }
    }
}
