import RealityKit
import Testing
@testable import Sedactive

/// 14 November 2026: the visible corridor is wider than the playfield (`environmentWidth`), so
/// two players dodging sideways have room; nothing gameplay reads moves with it.
@MainActor
struct CorridorWideningTests {
    private func scene(scale: Float) async throws -> LaserScene {
        var layout = LaserWorldLayout()
        layout.environmentWidthScale = scale
        let scene = LaserScene(layout: layout, mapping: GameWorldMapping())
        scene.installEnvironment(authored: await LaserScene.loadAuthoredEnvironment())
        scene.installVaultDoor(await LaserScene.loadVaultDoorArtwork())
        return scene
    }

    private func bounds(_ scene: LaserScene, _ name: String) throws -> BoundingBox {
        try #require(scene.root.findEntity(named: name)).visualBounds(relativeTo: nil)
    }

    @Test func theWallsFloorCeilingAndLaserMountsWidenAndTheLanesStay() async throws {
        // The selected width: 1.4 × 6.3 m = 8.82 m.
        #expect(LaserWorldLayout().environmentWidthScale == 1.4 && abs(LaserWorldLayout().environmentWidth - 8.82) < 1e-4)
        let narrow = try await scene(scale: 1), wide = try await scene(scale: 1.4)
        let half = wide.layout.environmentWidth / 2
        #expect(abs(half - 1.4 * narrow.layout.corridorWidth / 2) < 1e-5)
        let leftWall = try bounds(wide, "LeftWall"), rightWall = try bounds(wide, "RightWall")
        #expect(abs(leftWall.min.x + half) < 1e-3 && abs(rightWall.max.x - half) < 1e-3)
        for name in ["Floor", "Ceiling", "EndWall"] {
            let b = try bounds(wide, name)
            #expect(abs(b.min.x + half) < 1e-3 && abs(b.max.x - half) < 1e-3, "\(name) spans the wider corridor")
        }
        // Rib posts move out with their walls at their own (authored) thickness.
        let post = try bounds(wide, "PostLeft"), narrowPost = try bounds(narrow, "PostLeft")
        #expect(abs(post.min.x + half) < 1e-3 && abs(post.extents.x - narrowPost.extents.x) < 1e-4)
        // Beams reach the wider walls.
        #expect(wide.fullLaserSpan.lowerBound < narrow.fullLaserSpan.lowerBound - 1.2)
        #expect(abs(wide.fullLaserSpan.upperBound - (half - LaserGate.wallInset)) < 1e-3)
        // Gameplay's world: lanes, the players' plane, the vault stop and the laser spawn are unchanged.
        #expect(wide.mapping.laneCenterX == narrow.mapping.laneCenterX)
        #expect(wide.mapping.interactionPlaneZ == narrow.mapping.interactionPlaneZ)
        #expect(wide.layout.vaultDoorStopZ == narrow.layout.vaultDoorStopZ && wide.layout.laserSpawnZ == narrow.layout.laserSpawnZ)
        #expect(wide.layout.corridorWidth == narrow.layout.corridorWidth)
        for player in PlayerID.allCases {
            #expect(simd_distance(wide.mapping.playerPosition(player), narrow.mapping.playerPosition(player)) < 1e-6)
        }
    }

    @Test func leanSteeringAndTheConsolesDockAreUnchanged() {
        let layout = LaserWorldLayout()
        let visible = LateralSteering.visibleHalfWidth(depth: layout.cameraPosition.z, verticalFieldOfViewDegrees: layout.cameraVerticalFieldOfView,
                                                       aspect: RobotAvatarLayer.narrowestDisplayAspect)
        // Steering reads the playfield (`corridorWidth`), which the widening leaves as it was.
        #expect(LateralSteering.bounds(corridorWidth: layout.corridorWidth, visibleHalfWidth: visible, halfWidth: 0.45)
                == LateralSteering.bounds(corridorWidth: 6.3, visibleHalfWidth: visible, halfWidth: 0.45))
        // Usable space is the camera's whole view at the players' plane, not a strip inside empty floor:
        // a board can reach the screen's edge (less the wall clearance), the walls lie beyond it there,
        // and they come into view a little behind the players (the corridor still frames them).
        let bounds = LateralSteering.bounds(corridorWidth: layout.corridorWidth, visibleHalfWidth: visible, halfWidth: 0.45)
        #expect(abs(bounds.upperBound + 0.45 - (visible - LateralSteering.wallClearance)) < 1e-5)
        #expect(visible < layout.corridorWidth / 2 && visible < layout.environmentWidth / 2)
        let wallInView = layout.environmentWidth / 2 / (visible / layout.cameraPosition.z)   // depth from the camera
        let behindPlayers = wallInView - layout.cameraPosition.z
        #expect(behindPlayers > 0 && behindPlayers < 3, "walls come into view \(behindPlayers) m behind the players")
        // The mascot's dock, the reach plane, the button (on the gate's frame) and its station stay where
        // they are, whichever walls the corridor has.
        let arm = LaserGateConsole.Arm(shoulder: [0, 1.0], length: 0.6)
        for player in PlayerID.allCases {
            let before = LaserGateConsole(player: player, arm: arm, visibleHalfWidth: visible, wallHalfWidth: 3.15, planeZ: 0)
            let after = LaserGateConsole(player: player, arm: arm, visibleHalfWidth: visible, wallHalfWidth: layout.environmentWidth / 2, planeZ: 0)
            #expect(before == after)
        }
    }

    @Test func theVaultDoorsCloseTheWiderCorridor() async throws {
        let scene = try await scene(scale: 1.4)
        let half = scene.layout.environmentWidth / 2
        // The checkpoint door's surround reaches the walls; the door and its frame keep their size.
        let door = try #require(scene.root.findEntity(named: "vaultDoor"))
        let left = try #require(door.findEntity(named: "SurroundLeft")).visualBounds(relativeTo: door)
        let right = try #require(door.findEntity(named: "SurroundRight")).visualBounds(relativeTo: door)
        let frame = try #require(door.findEntity(named: "LockedFrame")).visualBounds(relativeTo: door)
        #expect(abs(left.min.x + half) < 1e-3 && abs(right.max.x - half) < 1e-3)
        #expect(left.max.x >= frame.min.x - 0.01 && right.min.x <= frame.max.x + 0.01, "no gap beside the frame")
        #expect(abs(frame.extents.x - 2 * 2.78545) < 1e-3)

        // The final vault: the art keeps its size; the wall carries on to the side walls.
        scene.installFinalVaultArt(try #require(await FinalVaultArt.load()))
        _ = FinalVaultPresentation(scene: scene)
        let wall = try #require(scene.root.findEntity(named: "finalVault.wall"))
        let closed = try #require(wall.findEntity(named: "finalVault.closed")).visualBounds(relativeTo: wall)
        #expect(abs(closed.extents.x - scene.layout.corridorWidth) < 1e-3)
        let leftStrip = try #require(wall.findEntity(named: "finalVault.wallExtensionLeft")).visualBounds(relativeTo: wall)
        let rightStrip = try #require(wall.findEntity(named: "finalVault.wallExtensionRight")).visualBounds(relativeTo: wall)
        #expect(abs(leftStrip.min.x + half) < 1e-3 && abs(rightStrip.max.x - half) < 1e-3)
        #expect(leftStrip.max.x > closed.min.x && rightStrip.min.x < closed.max.x, "tucked under the art's edges")
    }
}
