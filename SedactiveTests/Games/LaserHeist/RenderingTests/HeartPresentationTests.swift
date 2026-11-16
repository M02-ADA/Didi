import Foundation
import RealityKit
import Testing
@testable import Sedactive

@MainActor struct HeartPresentationTests {
    @Test func approvedHeartLoadsWithOriginalBoundsMaterialsAndPivot() async throws {
        let art = try await HeartArt.load()
        let heart = art.makeHeart(generation: UUID())
        let bounds = heart.root.visualBounds(relativeTo: heart.root)
        #expect(abs(bounds.extents.x - 0.300) < 0.001)
        #expect(abs(bounds.extents.y - 0.276855) < 0.001)
        #expect(abs(bounds.extents.z - 0.105) < 0.001)
        #expect(simd_length(bounds.center) < 0.001)
        let mesh = try #require(heart.root.findEntity(named: "GEO_LH_Heart") as? ModelEntity)
        #expect(mesh.model?.materials.count == 4)
        #expect(mesh.model?.materials.allSatisfy { $0 is PhysicallyBasedMaterial } == true)
    }

    @Test func instancesAreIndependentAndRetirementIsTerminal() async throws {
        let art = try await HeartArt.load()
        let generation = UUID()
        let first = art.makeHeart(generation: generation)
        let second = art.makeHeart(generation: generation)
        let host = Entity()
        host.addChild(first.root); host.addChild(second.root)
        #expect(first.target != second.target)
        #expect(first.generation == generation)
        first.root.position = [1, 2, 3]
        #expect(simd_distance(first.collectionWorldPosition, [1, 2, 3]) < 0.001)
        #expect(simd_length(second.root.position) == 0)
        first.retire(); first.retire()
        #expect(first.phase == .retired && first.root.parent == nil)
        #expect(second.phase == .ready && host.children.count == 1)
    }
    @Test(arguments: [false, true]) func idlePreservesPlacementAndRetiredInstancesCannotRestart(reduceMotion: Bool) async throws {
        let art = try await HeartArt.load()
        let heart = art.makeHeart(generation: UUID())
        let other = art.makeHeart(generation: UUID())
        heart.root.position = [0.5, 1.8, 0.1]
        let placement = heart.root.transform
        heart.showIdle(reduceMotion: reduceMotion)
        heart.showIdle(reduceMotion: reduceMotion)
        #expect(heart.phase == .idle && other.phase == .ready)
        #expect(heart.root.transform == placement, "idle must never move the target root")
        if reduceMotion {
            #expect(abs(heart.root.visualBounds(relativeTo: heart.root).extents.y - 0.276855) < 0.001)
        }
        heart.retire(); heart.showIdle(reduceMotion: reduceMotion)
        #expect(heart.phase == .retired)
    }

    @Test(arguments: [false, true]) func collectionIsIdentityFencedOnceAndRetiresAfterEffects(reduceMotion: Bool) async throws {
        let art = try await HeartArt.load()
        let generation = UUID()
        let heart = art.makeHeart(generation: generation)
        let other = art.makeHeart(generation: generation)
        let host = Entity(); host.addChild(heart.root); host.addChild(other.root)
        heart.showIdle(reduceMotion: reduceMotion)
        #expect(!heart.collect(generation: UUID(), target: heart.target, now: 1))
        #expect(!heart.collect(generation: generation, target: UUID(), now: 1))
        #expect(!heart.collect(generation: generation, target: heart.target, now: .nan))
        #expect(heart.phase == .idle)
        #expect(heart.collect(generation: generation, target: heart.target, now: 1, reduceMotion: reduceMotion))
        #expect(!heart.collect(generation: generation, target: heart.target, now: 1.01))
        #expect(other.phase == .ready)
        #expect(heart.root.findEntity(named: "heart.flash")?.isEnabled == !reduceMotion)
        let stars = heart.root.children.filter { $0.name.hasPrefix("heart.sparkle.") }
        #expect(stars.count == 6 && stars.allSatisfy { $0.isEnabled == !reduceMotion })
        heart.update(now: 0.9, generation: generation)
        heart.update(now: 1 + HeartCollectible.effectLifetime - 0.001, generation: generation)
        #expect(heart.phase == .collected && heart.root.parent != nil)
        heart.update(now: 1 + HeartCollectible.effectLifetime, generation: generation)
        #expect(heart.phase == .retired && heart.root.parent == nil)
        #expect(!heart.collect(generation: generation, target: heart.target, now: 2))
        heart.showIdle()
        #expect(heart.phase == .retired && host.children.count == 1)
    }

    @Test func generationCutoverInvalidatesIdleAndCollectedVisuals() async throws {
        let art = try await HeartArt.load()
        let generation = UUID()
        let idle = art.makeHeart(generation: generation)
        let collected = art.makeHeart(generation: generation)
        idle.showIdle()
        collected.collect(generation: generation, target: collected.target, now: 0)
        for heart in [idle, collected] {
            heart.update(now: 0.1, generation: UUID())
            #expect(heart.phase == .retired && heart.root.parent == nil)
        }
        let replacement = art.makeHeart(generation: UUID())
        #expect(replacement.phase == .ready && replacement.target != collected.target)
    }

    @Test func previewStopRetryAndReplacementLeaveNoOldVisuals() async throws {
        let scene = LaserScene()
        let preview = HeartAnimationPreview()
        let firstGeneration = UUID()
        try await preview.start(scene: scene, generation: firstGeneration)
        let old = try #require(preview.heart)
        preview.collect(now: 1, reduceMotion: false)
        preview.collect(now: 1.01)
        #expect(preview.collections == 1)
        preview.showAnother(reduceMotion: true)
        let replacement = try #require(preview.heart)
        #expect(old.phase == .retired && old.root.parent == nil)
        #expect(replacement.target != old.target)
        preview.update(now: 2)
        #expect(replacement.phase == .idle, "old retirement must not remove a replacement")
        preview.stop(); preview.collect(now: 3); preview.update(now: 4)
        #expect(replacement.phase == .retired && replacement.root.parent == nil)
        #expect(preview.heart == nil && preview.status == "Stopped")
        #expect(!scene.root.children.contains { $0.name.hasPrefix("heart.") })
        let newGeneration = UUID()
        try await preview.start(scene: scene, generation: newGeneration)
        #expect(preview.generation == newGeneration && preview.collections == 0)
        #expect(preview.heart?.generation != old.generation)
        preview.collect(now: 5, reduceMotion: true)
        preview.update(now: 5 + HeartCollectible.effectLifetime)
        #expect(preview.heart == nil && preview.status == "Retired")
        preview.stop()
    }

}
