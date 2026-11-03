import RealityKit
import Testing
import UIKit
@testable import Sedactive

/// LH-03 environment presentation: corridor travel, the hoverboard, the vault
/// door and diamonds. These check the resting values each call leaves behind;
/// they do not tick RealityKit animations.
@MainActor
struct EnvironmentPresentationTests {
    private func child(_ name: String, of parent: Entity, _ model: Entity? = nil) -> Entity {
        let entity = model ?? Entity()
        entity.name = name
        parent.addChild(entity)
        return entity
    }

    @Test func travelWrapsAtTheAuthoredLoopAndNeverMovesPlayersOrLaser() {
        let authored = Entity()
        let travel = child("Travel", of: authored)
        child("TravelLoop", of: child("Anchors", of: authored)).position = [0, 0, -12]
        let scene = LaserScene()
        let players = scene.players.mapValues(\.position)
        let laserZ = scene.laserWorldZ
        scene.installEnvironment(authored: authored)

        scene.advanceTravel(by: 13)
        #expect(abs(travel.position.z - 1) < 1e-4)
        scene.advanceTravel(by: -2)
        #expect(abs(travel.position.z - 11) < 1e-4)
        #expect(scene.players.mapValues(\.position) == players)
        #expect(scene.laserWorldZ == laserZ)
    }

    @Test func hoverboardBackHalfProjectsToTheSamePixels() throws {
        let board = Entity()
        let back = child("Back", of: board)
        let front = child("Front", of: board)
        let frontLayers = ["Edge", "Art", "Underglow", "FootShadowParent"].map { child($0, of: front) }
        board.position = [0, 0, -0.02]
        back.position = [0.4, 0.15, 0]
        let camera = SIMD3<Float>(0, 1.05, 3.1)
        let before = back.position(relativeTo: nil)
        let corner = back.convert(position: [1.3, 0.18, 0], to: nil)

        let hoverboard = try #require(Hoverboard(entity: board, camera: camera, backDepth: -0.7))
        hoverboard.stopHovering()
        let after = back.position(relativeTo: nil)
        let movedCorner = back.convert(position: [1.3, 0.18, 0], to: nil)

        #expect(abs(after.z - -0.7) < 1e-4)
        // Thickness under the art, then the glow, foot shadows on top, whatever the origins.
        #expect(frontLayers.map { $0.components[ModelSortGroupComponent.self]?.order } == [0, 1, 2, 3])
        // Same direction from the camera means the same place on screen.
        for (old, new) in [(before, after), (corner, movedCorner)] {
            let a = normalize(old - camera), b = normalize(new - camera)
            #expect(simd_distance(a, b) < 1e-4)
        }
    }

    @Test func vaultDoorStopComesFromTheAuthoredAnchor() {
        let authored = Entity()
        child("VaultDoorStop", of: child("Anchors", of: authored)).position = [0, 0, -6]
        let scene = LaserScene()
        scene.installEnvironment(authored: authored)
        #expect(scene.layout.vaultDoorStopZ == -6)
    }

    @Test func ridingMovesOnlyThePresentationOffsetNeverThePlacement() throws {
        let board = Entity()
        _ = child("Back", of: board)
        _ = child("Front", of: board)
        let player = PlayerCutoutEntity(lane: .child, size: [0.52, 1.2], color: .white)
        player.position = [0.7, 0, 0]
        let hoverboard = try #require(Hoverboard(entity: board, camera: [0, 1.05, 3.1], backDepth: -1.0))

        hoverboard.setRiders([player.ride])
        hoverboard.startHovering()
        hoverboard.stopHovering()

        #expect(player.position == [0.7, 0, 0])
        #expect(player.ride.transform == .identity)
        #expect(player.findEntity(named: "player.child.surface")?.parent === player.ride)
    }

    @Test func vaultDoorOpensBehindTheFrameAndResetsClosedAndLocked() throws {
        let artwork = Entity()
        let door = child("VaultDoorRoot", of: artwork)
        let light = child("UnlockedLight", of: door)
        let left = child("LeftDoorPanel", of: door)
        let right = child("RightDoorPanel", of: door)
        for panel in [left, right] {
            _ = child("Art", of: panel, ModelEntity(mesh: .generatePlane(width: 2, height: 2.8)))
        }
        let vault = try #require(VaultDoor(artwork: artwork))
        #expect(!light.isEnabled)

        vault.setState(.open, animated: false)
        #expect(light.isEnabled)
        #expect(abs(left.position.x - -2) < 1e-4)
        #expect(abs(right.position.x - 2) < 1e-4)

        vault.setState(.locked, animated: true)
        vault.reset()
        #expect(vault.state == .locked)
        #expect(!light.isEnabled)
        #expect(left.position.x == 0 && right.position.x == 0)
    }

    @Test func diamondResetLeavesNoCollectEffectBehind() throws {
        let artwork = Entity()
        let shape = child("Diamond", of: artwork)
        _ = child("Gem", of: shape, ModelEntity(mesh: .generatePlane(width: 0.3, height: 0.25)))
        _ = child("Sparkle", of: shape, ModelEntity(mesh: .generatePlane(width: 0.12, height: 0.12)))
        let diamond = try #require(DiamondArt(artwork: artwork)).makeDiamond()
        let sparkles = diamond.root.children.filter { $0.name == "Sparkle" }
        let gem = try #require(diamond.root.findEntity(named: "Gem"))
        #expect(sparkles.count == 4)

        diamond.collect()
        #expect(gem.components[OpacityComponent.self]?.opacity == 0)
        diamond.reset()
        #expect(gem.components[OpacityComponent.self] == nil)
        #expect(gem.transform == .identity)
        #expect(sparkles.allSatisfy { !$0.isEnabled })
    }
}
