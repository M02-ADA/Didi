import Foundation
import RealityKit
import RealityKitContent
import UIKit

/// Immutable approved artwork is loaded once; every collectible owns independent entities.
@MainActor
final class HeartArt {
    private let template: Entity
    private static var loading: Task<HeartArt, Error>?

    private init(_ template: Entity) { self.template = template }

    static func load() async throws -> HeartArt {
        if let loading { return try await loading.value }
        let task = Task { @MainActor in
            let asset = try await Entity(named: "Heart3D.usdz", in: realityKitContentBundle)
            return HeartArt(asset)
        }
        loading = task
        do { return try await task.value }
        catch { loading = nil; throw error }
    }

    func makeHeart(generation: UUID, target: UUID = UUID()) -> HeartCollectible {
        HeartCollectible(artwork: template.clone(recursive: true), generation: generation, target: target)
    }
}

/// Cosmetic lifecycle only. No contact, reward, health, input stream or gameplay clock.
/// A retired instance is terminal; a replacement gets a new target and fresh entities.
@MainActor
final class HeartCollectible {
    enum Phase { case ready, idle, collected, retired }
    static let idleCycle: TimeInterval = 1.8
    static let floatHeight: Float = 0.018
    static let popDuration: TimeInterval = 0.08
    static let shrinkDuration: TimeInterval = 0.16
    static let flashDuration: TimeInterval = 0.10
    static let sparkleDuration: TimeInterval = 0.36
    static let effectLifetime: TimeInterval = 0.39
    let generation: UUID
    let target: UUID
    let root = Entity()
    private(set) var phase: Phase = .ready
    private let body = Entity()
    private let artwork: Entity
    private let flash: Entity
    private let sparkles: [ModelEntity]
    private var collectedAt: TimeInterval?

    fileprivate init(artwork: Entity, generation: UUID, target: UUID) {
        self.artwork = artwork
        flash = artwork.clone(recursive: true)
        flash.name = "heart.flash"
        Self.tintFlash(flash)
        flash.isEnabled = false
        sparkles = (0..<6).map { index in
            let star = ModelEntity(mesh: Self.starMesh, materials: [UnlitMaterial(color:
                index.isMultiple(of: 2) ? UIColor(red: 1, green: 0.62, blue: 0.69, alpha: 1) : .white)])
            star.name = "heart.sparkle.\(index)"
            star.isEnabled = false
            return star
        }
        self.generation = generation
        self.target = target
        root.name = "heart.\(target)"
        body.name = "heart.body"
        root.addChild(body)
        body.addChild(artwork)
        body.addChild(flash)
        for sparkle in sparkles { root.addChild(sparkle) }
        // Preserve all authored asset transforms, dimensions, pivot and materials.
    }

    /// Future HUD projection starts from the rendered heart, never physical wrist coordinates.
    /// No HUD reward is emitted here; an authoritative pickup contract is still required.
    var collectionWorldPosition: SIMD3<Float> { artwork.visualBounds(relativeTo: nil).center }

    func showIdle(reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled) {
        guard phase == .ready else { return }
        phase = .idle
        guard !reduceMotion else { return }
        var raised = Transform.identity
        raised.translation.y = Self.floatHeight
        raised.scale = .init(repeating: 1.025)
        loop(body, to: raised, duration: Self.idleCycle / 2)
        var rocked = artwork.transform
        rocked.rotation *= simd_quatf(angle: .pi / 40, axis: [0, 1, 0])
        loop(artwork, to: rocked, duration: 1.0)
    }

    /// Caller supplies an already committed pickup's identity. The DEBUG fixture may call this
    /// explicitly as a synthetic visual trigger. This function never decides pickup eligibility.
    @discardableResult
    func collect(generation: UUID, target: UUID, now: TimeInterval,
                 reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled) -> Bool {
        guard self.generation == generation, self.target == target, now.isFinite,
              phase == .ready || phase == .idle else { return false }
        phase = .collected
        collectedAt = now
        body.stopAllAnimations(recursive: true)
        let contact = artwork.transform
        fade(artwork, from: 1, to: 0, duration: Self.popDuration + Self.shrinkDuration)
        guard !reduceMotion else { return true }
        var popped = contact; popped.scale *= 1.3
        var gone = contact; gone.scale *= 0.035
        sequence(artwork, [(contact, popped, Self.popDuration), (popped, gone, Self.shrinkDuration)])
        flash.transform = contact
        flash.scale *= 1.08
        flash.isEnabled = true
        fade(flash, from: 0.65, to: 0, duration: Self.flashDuration)
        for (index, sparkle) in sparkles.enumerated() {
            let angle = Float(index) * .pi / 3 + .pi / 6
            let direction = SIMD3<Float>(cos(angle), sin(angle), 0)
            let start = Transform(translation: body.position + direction * 0.04 + [0, 0, 0.065])
            let end = Transform(scale: .init(repeating: 0.12),
                rotation: simd_quatf(angle: .pi / 3, axis: [0, 0, 1]),
                translation: body.position + direction * 0.24 + [0, 0, 0.065])
            sparkle.isEnabled = true
            sequence(sparkle, [(start, end, Self.sparkleDuration)])
            fade(sparkle, from: 1, to: 0, duration: Self.sparkleDuration)
        }
        return true
    }

    /// Call from the existing presentation render tick using host time. No timer or callback is
    /// retained by the collectible. Generation replacement retires it even before collection.
    func update(now: TimeInterval, generation: UUID) {
        guard generation == self.generation else { retire(); return }
        guard now.isFinite, let collectedAt, now >= collectedAt + Self.effectLifetime else { return }
        retire()
    }

    private static let starMesh: MeshResource = {
        var points: [SIMD3<Float>] = [.zero]
        for index in 0..<8 {
            let angle = Float(index) * .pi / 4
            let radius: Float = index.isMultiple(of: 2) ? 0.022 : 0.006
            points.append([cos(angle) * radius, sin(angle) * radius, 0])
        }
        var mesh = MeshDescriptor(name: "heart.sparkle")
        mesh.positions = MeshBuffers.Positions(points)
        var indices: [UInt32] = []
        for index in 0..<8 { indices += [0, UInt32(index + 1), UInt32((index + 1) % 8 + 1)] }
        mesh.primitives = .triangles(indices)
        // Fixed, valid eight-triangle mesh, generated once for all Heart instances.
        return try! MeshResource.generate(from: [mesh])
    }()

    private static func tintFlash(_ entity: Entity) {
        if let model = entity as? ModelEntity {
            model.model?.materials = model.model?.materials.map { _ in
                UnlitMaterial(color: UIColor(red: 1, green: 0.72, blue: 0.78, alpha: 1))
            } ?? []
        }
        for child in entity.children { tintFlash(child) }
    }

    private func sequence(_ part: Entity, _ steps: [(Transform, Transform, TimeInterval)]) {
        let resources = steps.compactMap { from, to, duration in
            try? AnimationResource.generate(with: FromToByAnimation(from: from, to: to,
                duration: duration, timing: .easeOut, bindTarget: .transform))
        }
        if let resource = try? AnimationResource.sequence(with: resources) {
            part.transform = steps[0].0
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

    private func loop(_ part: Entity, to: Transform, duration: TimeInterval) {
        let definition = FromToByAnimation(from: part.transform, to: to, duration: duration,
            timing: .easeInOut, bindTarget: .transform, repeatMode: .autoReverse)
        if let animation = try? AnimationResource.generate(with: definition).repeat() {
            part.playAnimation(animation, handoffType: .compose)
        }
    }

    func retire() {
        phase = .retired
        root.stopAllAnimations(recursive: true)
        root.removeFromParent()
    }
}
