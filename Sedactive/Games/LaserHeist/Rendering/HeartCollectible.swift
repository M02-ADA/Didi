import Foundation
import RealityKit
import RealityKitContent

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
    let generation: UUID
    let target: UUID
    let root = Entity()
    private(set) var phase: Phase = .ready
    private let body = Entity()
    private let artwork: Entity

    fileprivate init(artwork: Entity, generation: UUID, target: UUID) {
        self.artwork = artwork
        self.generation = generation
        self.target = target
        root.name = "heart.\(target)"
        body.name = "heart.body"
        root.addChild(body)
        body.addChild(artwork)
        // Preserve all authored asset transforms, dimensions, pivot and materials.
    }

    /// Future HUD projection starts from the rendered heart, never physical wrist coordinates.
    /// No HUD reward is emitted here; an authoritative pickup contract is still required.
    var collectionWorldPosition: SIMD3<Float> { artwork.visualBounds(relativeTo: nil).center }

    func retire() {
        phase = .retired
        root.stopAllAnimations(recursive: true)
        root.removeFromParent()
    }
}
