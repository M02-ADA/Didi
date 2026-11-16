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
}
