import Foundation
import RealityKit
import Testing
@testable import Sedactive

@MainActor struct Diamond3DPresentationTests {
    private func art() async throws -> DiamondArt {
        let artwork = try #require(await LaserScene.loadDiamondArtwork())
        let gem = try #require(artwork.findEntity(named: "Gem"))
        #expect(artwork.findEntity(named: "Sparkle") != nil)
        let bounds = gem.visualBounds(relativeTo: gem)
        #expect(abs(bounds.extents.x - 0.3) < 0.001)
        #expect(abs(bounds.extents.y - 0.2543) < 0.001)
        #expect(abs(bounds.extents.z - 0.09) < 0.001, "true depth, not the old flat quad")
        #expect(length(bounds.center) < 0.001, "resetting Gem.transform must preserve its pivot")
        func materialCount(_ e: Entity) -> Int {
            (e as? ModelEntity)?.model?.materials.count ?? e.children.reduce(0) { $0 + materialCount($1) }
        }
        #expect(materialCount(gem) == 8)
        return try #require(DiamondArt(artwork: artwork))
    }
    @Test func approvedResourceLoadsWithDepthAndSparkle() async throws { _ = try await art() }
    @Test func collectionIsOnceAndFourClonesAreIndependent() async throws {
        let art = try await art()
        let diamonds = (0..<4).map { _ in art.makeDiamond() }
        for d in diamonds { d.showIdle(); #expect(d.phase == .idle) }
        let first = diamonds[0]
        first.collect(); let count = first.root.children.first?.children.count
        first.collect(); first.showIdle()
        #expect(first.phase == .collected)
        #expect(first.root.children.first?.children.count == count)
        #expect(diamonds.dropFirst().allSatisfy { $0.phase == .idle })
        for d in diamonds { d.retire() }
    }
    @Test func reduceMotionHasNoFlashAndRetirementCannotRevive() async throws {
        let diamond = try await art().makeDiamond()
        diamond.showIdle(reduceMotion: true)
        diamond.collect(reduceMotion: true)
        #expect(diamond.root.findEntity(named: "diamond.flash")?.isEnabled == false)
        let host = Entity(); host.addChild(diamond.root)
        diamond.retire(); diamond.reset(); diamond.showIdle(); diamond.collect()
        #expect(diamond.phase == .removed && diamond.root.parent == nil)
        #expect(host.children.isEmpty)
    }
    @Test func bonusEffectRetiresEvenWhenCollectedOutcomeRemainsInSource() async throws {
        let scene = LaserScene()
        scene.installDiamondArt(try #require(await LaserScene.loadDiamondArtwork()))
        let view = DiamondTimePresentation(scene: scene)
        var collected = false
        view.source = { _ in [DiamondTimeDiamond(id: 1, lane: .player1, offsetX: 0,
            heightAboveFloor: 1, collected: collected)] }
        let generation = UUID()
        func state(_ time: Double) -> LaserGameState {
            LaserGameState(sessionGeneration: generation, phase: .diamondTime, gameTime: time,
                activityProgress: 300, teamHealth: 5, teamScore: collected ? 25 : 0, encounters: [])
        }
        view.update(state: state(0), diamondTimeStartedAt: 0)
        #expect(view.floatingIDs == [1])
        collected = true
        view.update(state: state(0.01), diamondTimeStartedAt: 0)
        view.update(state: state(0.02), diamondTimeStartedAt: 0)
        #expect(view.collections == 1)
        view.update(state: state(0.5), diamondTimeStartedAt: 0)
        #expect(scene.root.findEntity(named: "diamondTime.diamond.1") == nil)
        view.update(state: state(1), diamondTimeStartedAt: 0)
        #expect(view.collections == 1 && view.floatingIDs.isEmpty)
        view.clear()
    }
}
