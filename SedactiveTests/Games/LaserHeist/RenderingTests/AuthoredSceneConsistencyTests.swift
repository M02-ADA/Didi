import RealityKit
import Testing
@testable import Sedactive

/// The compiled Reality Composer Pro scene and the runtime world agree, and
/// the scene's editor references never reach gameplay as a second set of players.
@MainActor
struct AuthoredSceneConsistencyTests {
    private let previewNames: [(PlayerID, String)] = [(.player1, "P1LemonPreview"), (.player2, "P2TangerinePreview")]

    private func authored() async throws -> Entity {
        try #require(await LaserScene.loadAuthoredEnvironment())
    }

    private func descendants(of entity: Entity) -> [Entity] {
        entity.children.flatMap { [$0] + descendants(of: $0) }
    }

    /// Scenes are read once and cloned: what one round changes in its copy
    /// must never reach the next round's.
    @Test func eachLoadIsAnIndependentCopy() async throws {
        let first = try await authored()
        let second = try await authored()
        #expect(first !== second)
        LaserScene().installEnvironment(authored: first)
        #expect(first.findEntity(named: LaserScene.editorPreviewsName) == nil)
        #expect(second.findEntity(named: LaserScene.editorPreviewsName) != nil)
        let later = try await authored()
        #expect(later.findEntity(named: LaserScene.editorPreviewsName) != nil)
    }

    @Test func editorReferencesAreStaticMascotsOnTheirLanesAtTheSharedHeight() async throws {
        let scene = try await authored()
        let previews = try #require(scene.findEntity(named: LaserScene.editorPreviewsName))
        let lanes = GameWorldMapping().laneCenterX
        for (player, name) in previewNames {
            let preview = try #require(previews.findEntity(named: name))
            let bounds = preview.visualBounds(relativeTo: scene)
            #expect(abs(preview.position(relativeTo: scene).x - lanes[player]!) < 0.001)
            #expect(abs(bounds.min.y) < 0.001)
            #expect(abs(bounds.max.y - RobotAvatarLayer.standingHeight) < 0.001)
            // Real volume, not a flat picture: the mascot is about 0.6 m deep.
            #expect(bounds.extents.z > 0.5)
        }
        #expect(previews.findEntity(named: "ParentPreview") == nil)
        #expect(previews.findEntity(named: "ChildPreview") == nil)
        // No rigged character is authored here: the runtime owns every skeleton.
        let rigged = descendants(of: scene).compactMap { $0 as? ModelEntity }.filter { !$0.jointNames.isEmpty }
        #expect(rigged.isEmpty)
    }

    @Test func gameplayShowsExactlyOneMascotPerPlayerOnTheirLane() async throws {
        let scene = LaserScene()
        scene.installEnvironment(authored: try await authored())
        #expect(scene.root.findEntity(named: LaserScene.editorPreviewsName) == nil)

        let layer = RobotAvatarLayer(scene: scene, players: Set(PlayerID.allCases),
                                     templates: try await RobotAvatarLayer.sharedTemplates())
        scene.robotAvatars = layer
        defer {
            layer.remove()
            scene.robotAvatars = nil
        }
        for player in PlayerID.allCases {
            let entity = try #require(scene.players[player])
            #expect(entity.findEntity(named: "player.\(player.rawValue).surface")?.isEnabled == false)
            #expect(entity.children.filter { $0.name == "player.\(player.rawValue).robot" }.count == 1)
            #expect(entity.position.x == scene.mapping.laneCenterX[player])
            let robot = try #require(layer.robots[player])
            #expect(abs(robot.container.scale.y * RobotSkeleton.modelHeight - RobotAvatarLayer.standingHeight) < 0.001)
        }
        #expect(try #require(scene.players[.player1]).position.x < 0)
        #expect(try #require(scene.players[.player2]).position.x > 0)
    }

    @Test func runtimeWorldMatchesTheAuthoredGeometry() async throws {
        let authored = try await authored()
        let layout = LaserWorldLayout()
        func y(_ name: String) throws -> Float { try #require(authored.findEntity(named: name)).position(relativeTo: authored).y }
        func z(_ name: String) throws -> Float { try #require(authored.findEntity(named: name)).position(relativeTo: authored).z }

        // Taken before installing, which removes the editor references.
        #expect(abs(try y("Gate") - layout.laserHeightAboveFloor) < 0.001)
        #expect(try z("VaultDoorPreview") == z("VaultDoorStop"))
        let floor = try #require(authored.findEntity(named: "Corridor")?.findEntity(named: "Floor"))
        #expect(abs(floor.visualBounds(relativeTo: authored).min.y - layout.corridorFloorY) < 0.001)

        let scene = LaserScene()
        let spawn = try z("LaserSpawnPoint"), stop = try z("VaultDoorStop")
        scene.installEnvironment(authored: authored)
        #expect(scene.environmentSource == .realityComposerPro)
        #expect(scene.mapping.laneCenterX == GameWorldMapping().laneCenterX)
        #expect(scene.mapping.interactionPlaneZ == GameWorldMapping().interactionPlaneZ)
        #expect(scene.layout.laserSpawnZ == spawn)
        #expect(scene.layout.laserSpawnZ == layout.laserSpawnZ)
        #expect(scene.layout.vaultDoorStopZ == stop)
        #expect(scene.layout.vaultDoorStopZ == layout.vaultDoorStopZ)
        // Lane hazards reach the authored wall mounts; the mapping puts the floor at game Y = 0.
        #expect(abs(scene.laneSpan(for: .player1).lowerBound + 3.08) < 0.001)
        #expect(abs(scene.laneSpan(for: .player2).upperBound - 3.08) < 0.001)
        #expect(scene.mapping.playerPosition(.player1).y == 0)
    }
}
