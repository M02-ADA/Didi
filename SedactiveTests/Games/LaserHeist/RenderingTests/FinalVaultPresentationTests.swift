import Foundation
import RealityKit
import Testing
import UIKit
@testable import Sedactive

/// The final vault (Ending Vault assets 42, 43 and Inside Vault) at the end of the
/// corridor, the scripted entry on held game time, and the room for Diamond Time.
@MainActor
struct FinalVaultPresentationTests {
    private let generation = UUID()

    private func scene(robots: Bool = false, players: Set<PlayerID> = Set(PlayerID.allCases)) async throws -> LaserScene {
        let scene = LaserScene()
        scene.installEnvironment(authored: nil)
        scene.installFinalVaultArt(try #require(await FinalVaultArt.load(), "Ending Vault art in the asset catalog"))
        if robots {
            scene.robotAvatars = RobotAvatarLayer(scene: scene, players: players,
                                                  templates: try await RobotAvatarLayer.sharedTemplates())
        }
        return scene
    }

    private func entity(_ scene: LaserScene, _ name: String) throws -> Entity {
        try #require(scene.root.findEntity(named: name))
    }

    /// END WALL (23 November 2026): the corridor (8.82 m) is wider than the art (6.3 m). The art's wall
    /// band used to be stretched out to the side walls; now the art ends where Theo drew it and a plain
    /// wall of its own navy background (its gradient, no band) closes the corridor beside it.
    @Test func theCorridorBesideTheArtIsAPlainWallOfTheArtsNavy() async throws {
        let image = try #require(UIImage(named: "LaserHeistVault/final-vault-closed")?.cgImage)
        let profile = try #require(FinalVaultArt.endWallProfile(image))
        #expect(profile.width == FinalVaultArt.profileWidth && profile.height == image.height)
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return data
        }
        let art = pixels(image), wall = pixels(profile)
        func artPixel(_ row: Int, _ x: Int) -> SIMD3<Int> {
            let i = (row * image.width + x) * 4
            return SIMD3(Int(art[i]), Int(art[i + 1]), Int(art[i + 2]))
        }
        func wallPixel(_ row: Int) -> SIMD3<Int> {
            let i = (row * FinalVaultArt.profileWidth + 1) * 4
            return SIMD3(Int(wall[i]), Int(wall[i + 1]), Int(wall[i + 2]))
        }
        // Every row: the art's own navy margin at that row, on either side (the wall carries it on).
        var worst = 0
        for row in 0..<image.height {
            for x in [10, 30, image.width - 11, image.width - 31] {
                let d = artPixel(row, x) &- wallPixel(row)
                worst = max(worst, abs(d.x), abs(d.y), abs(d.z))
            }
        }
        #expect(worst <= 3, "the end wall is the art's margin, row for row (largest difference \(worst)/255)")
        // A plain wall: no corner marks or bands copied into it (only the margin's gentle gradient).
        // (The art's own outermost pixel rows differ by a few levels: its edge, kept as it is.)
        let rows = (1..<(image.height - 1)).map { wallPixel($0) }
        let jump = zip(rows, rows.dropFirst()).map { a, b in max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) }.max() ?? 0
        #expect(jump <= 3, "no marks or bands in the wall (largest step between rows \(jump))")
        let scene = try await scene()
        let vault = FinalVaultPresentation(scene: scene)
        #expect(vault.hasArt)
        for side in ["Left", "Right"] {
            let strip = try #require(scene.root.findEntity(named: "finalVault.wallExtension\(side)") as? ModelEntity)
            let bounds = strip.visualBounds(relativeTo: strip.parent)
            let edge = scene.layout.corridorWidth / 2
            #expect(abs(min(abs(bounds.min.x), abs(bounds.max.x)) - edge) < 0.02, "\(side): from the art's edge")
            #expect(abs(max(abs(bounds.min.x), abs(bounds.max.x)) - scene.layout.environmentWidth / 2) < 0.01, "\(side): to the side wall")
            #expect(strip.position.z < 0.005, "\(side): behind the art, so the art's own edge is the boundary")
        }
    }

    /// NEW ART (23 November 2026): Image A (closed) and Image B (open) share one canvas, and Image B's
    /// doorway is exactly where the door mechanism cuts Image A's door out, so opening never shifts.
    @Test func theOpenArtsDoorwayIsWhereTheDoorIsCutFromTheClosedArt() throws {
        let closed = try #require(UIImage(named: "LaserHeistVault/final-vault-closed")?.cgImage)
        let open = try #require(UIImage(named: "LaserHeistVault/final-vault-open")?.cgImage)
        #expect(open.width == closed.width && open.height == closed.height, "one canvas")
        #expect(FinalVaultArt.openWidthShare == 1 && FinalVaultDoorArtwork.openInset == 0)
        #expect(abs(Float(closed.width) / Float(closed.height) - FinalVaultArt.closedAspect) < 0.001, "drawn at the art's own aspect")
        var data = [UInt8](repeating: 0, count: open.width * open.height * 4)
        let context = try #require(CGContext(data: &data, width: open.width, height: open.height, bitsPerComponent: 8,
                                             bytesPerRow: open.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(open.height))
        context.scaleBy(x: 1, y: -1) // row 0 = top, as the artwork's pixel values are measured
        context.draw(open, in: CGRect(x: 0, y: 0, width: open.width, height: open.height))
        var count = 0, sx = 0.0, sy = 0.0
        for y in 0..<open.height { for x in 0..<open.width where data[(y * open.width + x) * 4 + 3] < 128 {
            count += 1; sx += Double(x); sy += Double(y)
        } }
        let k = Double(open.width) / Double(FinalVaultDoorArtwork.size.x)
        let center = SIMD2(sx / Double(count), sy / Double(count)), radius = (Double(count) / .pi).squareRoot()
        #expect(abs(center.x - Double(FinalVaultDoorArtwork.center.x) * k) < 3 && abs(center.y - Double(FinalVaultDoorArtwork.center.y) * k) < 3,
                "the doorway's centre \(center)")
        #expect(abs(radius - Double(FinalVaultDoorArtwork.radius) * k) < 3, "the doorway's radius \(radius)")
    }

    @Test func theVaultComesUpTheCorridorToItsStopAndOpens() async throws {
        let scene = try await scene()
        let vault = FinalVaultPresentation(scene: scene)
        let timeline = LaserFinalVaultTimeline(roster: PlayerID.allCases)
        let wall = try entity(scene, "finalVault.wall"), closed = try entity(scene, "finalVault.closed")
        let open = try entity(scene, "finalVault.open"), inside = try entity(scene, "finalVault.inside")
        let mechanism = try entity(scene, "finalVault.mechanism")
        #expect(vault.hasArt && !wall.isEnabled)

        // Approach: from deep in the corridor to the stop, the corridor moving with it.
        #expect(vault.update(.entry(timeline, elapsed: 0)) == 0)
        #expect(wall.isEnabled && scene.isCorridorShown)
        #expect(abs(wall.position.z - (FinalVaultPresentation.stopZ - FinalVaultPresentation.approachDistance)) < 1e-4)
        var last: Float = 0
        for step in 1...30 where LaserFinalVaultTimeline.approach.upperBound * Double(step) / 30 < FinalVaultDoorMotion.start {
            let travelled = vault.update(.entry(timeline, elapsed: LaserFinalVaultTimeline.approach.upperBound * Double(step) / 30))
            #expect(travelled >= last)
            last = travelled
        }
        // Asset 42 whole while it comes up the corridor in the haze.
        #expect(closed.isEnabled && !mechanism.isEnabled && !open.isEnabled && !inside.isEnabled)
        last = vault.update(.entry(timeline, elapsed: LaserFinalVaultTimeline.approach.upperBound))
        #expect(abs(last - FinalVaultPresentation.approachDistance) < 1e-4)
        #expect(abs(wall.position.z - FinalVaultPresentation.stopZ) < 1e-4)
        // Leaves the vault's stop at the team's travel speed: no jump in pace.
        let early = FinalVaultPresentation.approachTravel(at: 0.01, speed: scene.layout.travelSpeed) / 0.01
        #expect(abs(early - scene.layout.travelSpeed) < 0.3)
        // At rest the door is its mechanism (it still looks like Asset 42); the room comes behind it
        // as it opens.
        #expect(!closed.isEnabled && mechanism.isEnabled && open.isEnabled && !inside.isEnabled)
        vault.update(.entry(timeline, elapsed: LaserFinalVaultTimeline.open.upperBound + 0.01))
        #expect(!closed.isEnabled && mechanism.isEnabled && open.isEnabled && inside.isEnabled)
        #expect(inside.position.z < wall.position.z)
        // The push moves the camera, not the wall.
        vault.update(.entry(timeline, elapsed: timeline.push.upperBound))
        #expect(wall.isEnabled && abs(wall.position.z - FinalVaultPresentation.stopZ) < 1e-4 && scene.cameraDolly.z < -1)
        // Through the doorway into the room: corridor and wall go, the room fills the view, and
        // the camera is the gameplay camera again.
        vault.update(.entry(timeline, elapsed: timeline.total))
        #expect(!wall.isEnabled && !scene.isCorridorShown && inside.isEnabled && scene.cameraDolly == .zero)
        #expect(inside.position.z < scene.mapping.interactionPlaneZ)
        vault.update(.hidden)
        #expect(!wall.isEnabled && !inside.isEnabled && scene.isCorridorShown && scene.cameraDolly == .zero)
    }

    /// 14 November 2026: the door used to fade from Asset 42 to Asset 43 (growing 4 %), so nothing
    /// turned or moved and it read as a transparent doorway appearing. Now the wheel turns half a
    /// turn (with a counter-turn first and a click back into its detent), the bolt slides home
    /// into the door, and the door sinks and swings in on its hinges until it is out of sight;
    /// the frame never moves, and nothing fades or scales.
    @Test func theWheelTurnsTheBoltSlidesHomeAndTheDoorSwingsIn() async throws {
        let scene = try await scene()
        let vault = FinalVaultPresentation(scene: scene)
        let timeline = LaserFinalVaultTimeline(roster: PlayerID.allCases)
        let wall = try entity(scene, "finalVault.wall"), frame = try entity(scene, "finalVault.wallFront")
        let jamb = try entity(scene, "finalVault.open"), door = try entity(scene, "finalVault.door")
        let wheel = try entity(scene, "finalVault.wheel"), bolt = try entity(scene, "finalVault.bolt")
        let hinge = try entity(scene, "finalVault.hinge")
        let unlock = LaserFinalVaultTimeline.unlock.lowerBound
        typealias Motion = FinalVaultDoorMotion

        // At rest the parts sit exactly where Asset 42 draws them.
        vault.update(.entry(timeline, elapsed: Motion.start))
        #expect(Motion.at(Motion.start) == .rest && Motion.at(Motion.start - 0.2) == .rest)
        let frameAt = frame.transformMatrix(relativeTo: nil), jambAt = jamb.transformMatrix(relativeTo: nil)
        let doorAt = door.transformMatrix(relativeTo: nil), boltAt = bolt.position(relativeTo: nil)
        func angle(_ e: Entity) -> Float {   // signed turn about the door's normal
            let q = e.orientation
            return 2 * atan2(q.imag.z, q.real)
        }

        var lastWheel: Float = 0, lastSwing: Float = 0, maxWheelStep: Float = 0, lowestWheel: Float = 0
        var swingStarted: Double?, boltHome: Double?
        let dt = 1.0 / 60
        for step in 0...Int((Motion.end - Motion.start + 0.2) / dt) {
            let t = Motion.start + Double(step) * dt
            vault.update(.entry(timeline, elapsed: t))
            let m = Motion.at(t)
            // The frame and the jamb never move; nothing fades or scales.
            #expect(simd_almost_equal_elements(frame.transformMatrix(relativeTo: nil), frameAt, 1e-6), "frame moved at \(t)")
            #expect(simd_almost_equal_elements(jamb.transformMatrix(relativeTo: nil), jambAt, 1e-6), "jamb moved at \(t)")
            #expect(wall.components[OpacityComponent.self] == nil && simd_distance(door.scale(relativeTo: nil), SIMD3(repeating: 1)) < 1e-4,
                    "fade or scale at \(t)")
            // The wheel is readable: under half a spoke spacing (22.5°) per frame at 60 Hz.
            let turn = angle(wheel)
            maxWheelStep = max(maxWheelStep, abs(turn - lastWheel))
            lowestWheel = min(lowestWheel, turn)
            lastWheel = turn
            // The swing only opens, and only once the bolt is home.
            #expect(m.swing >= lastSwing - 1e-6, "door closes again at \(t)")
            if m.swing > 0, swingStarted == nil { swingStarted = t }
            if m.bolt == 1, boltHome == nil { boltHome = t }
            lastSwing = m.swing
            // The door never comes in front of the frame (toward the mascots and the camera).
            #expect(door.visualBounds(relativeTo: wall).max.z <= FinalVaultDoorRig.frameZ, "door in front of the frame at \(t)")
        }
        #expect(lowestWheel < -5 * .pi / 180, "the wheel winds up first")
        #expect(abs(lastWheel - .pi) < 1e-3, "half a turn: \(lastWheel)")
        #expect(maxWheelStep < .pi / 8, "wheel step \(maxWheelStep)")
        let started = try #require(swingStarted), home = try #require(boltHome)
        #expect(home <= started && started > unlock && Motion.end <= LaserFinalVaultTimeline.firstJump)
        // The bolt went home into the door (its right end inside the doorway, behind the face) and is
        // carried with it.
        let metre = scene.layout.corridorWidth / FinalVaultDoorArtwork.size.x
        let doorRadius = FinalVaultDoorArtwork.radius * metre
        #expect(abs(-bolt.position.x - FinalVaultDoorArtwork.boltTravel * metre) < 1e-5)
        #expect(bolt.visualBounds(relativeTo: door).max.x < doorRadius && bolt.position.z < 0)
        #expect(bolt.parent === door && wheel.parent === door && door.parent === hinge)
        // Open: the door hangs in, beyond the doorway's left edge, out of the corridor camera's view.
        let doorNow = door.transformMatrix(relativeTo: nil)
        #expect(!simd_almost_equal_elements(doorNow, doorAt, 1e-3))
        #expect(abs(lastSwing - Motion.openAngle) < 1e-4)
        let camera = scene.layout.cameraPosition
        // The door's outline, front and back, in the world.
        let outline = (0..<48).flatMap { i -> [SIMD3<Float>] in
            let a = Float(i) / 48 * 2 * .pi
            return [0, -FinalVaultDoorRig.thickness].map { door.convert(position: [doorRadius * cos(a), doorRadius * sin(a), $0], to: nil) }
        }
        let doorwayCenterY = wall.convert(position: [0, (0.5 - FinalVaultDoorArtwork.center.y / FinalVaultDoorArtwork.size.y) * scene.layout.corridorWidth / FinalVaultArt.closedAspect, 0], to: nil).y
        for corner in outline {
            // Where the line of sight to this point meets the wall plane: outside the doorway.
            let k = (FinalVaultPresentation.stopZ - camera.z) / (corner.z - camera.z)
            let onWall = camera + (corner - camera) * k
            #expect(corner.x < 0 && simd_distance(SIMD2(onWall.x, onWall.y), SIMD2(0, doorwayCenterY)) > doorRadius,
                    "door point \(corner) seen through the doorway")
        }
        // At the end of the push (the camera just inside the room) the door is out of its field of view
        // (the widest iPad screen: 1.6 wide).
        let end = camera + [0, 0, -vault.pushDistance]
        let halfWidth = tan(scene.layout.cameraVerticalFieldOfView / 2 * .pi / 180) * 1.6
        for corner in outline {
            let depth = end.z - corner.z
            #expect(depth <= 0 || abs(corner.x - end.x) / depth > halfWidth, "door point \(corner) in view at the end of the push")
        }
        // Replaying the entry shows the same opening.
        vault.update(.hidden)
        vault.update(.entry(timeline, elapsed: Motion.start))
        #expect(simd_almost_equal_elements(door.transformMatrix(relativeTo: nil), doorAt, 1e-6) && abs(angle(wheel)) < 1e-6)
        #expect(simd_distance(bolt.position(relativeTo: nil), boltAt) < 1e-6)
    }

    /// The doorway's measured place in Asset 43 lines up with the corridor, and each arc
    /// carries the mascot's middle through it, not through the wall.
    /// 14 November 2026 regression: with the backdrop behind the mascots' landing, the corridor's
    /// floor and ceiling showed through the doorway. The sleeve lines that gap with the room art as
    /// the backdrop projects onto it from the room's camera (from there it is the backdrop), stays
    /// behind the wall and under its top edge (the corridor above the wall stays the corridor), and
    /// exists from when the doorway shows; inside it stays, so nothing changes on screen.
    @Test func theRoomSleeveIsTheBackdropSeenNearerAndStaysBehindTheWall() async throws {
        let scene = try await scene()
        let vault = FinalVaultPresentation(scene: scene)
        let timeline = LaserFinalVaultTimeline(roster: PlayerID.allCases)
        let wall = try entity(scene, "finalVault.wall"), inside = try entity(scene, "finalVault.inside")
        let sleeve = try entity(scene, "finalVault.sleeve")
        vault.update(.entry(timeline, elapsed: LaserFinalVaultTimeline.open.lowerBound - 0.01))
        #expect(!sleeve.isEnabled, "closed door: no room behind it")
        let wallTop = { wall.position.y + scene.layout.corridorWidth / FinalVaultArt.closedAspect / 2 }
        for t in [LaserFinalVaultTimeline.open.upperBound, timeline.push.lowerBound,
                  (timeline.push.lowerBound + timeline.push.upperBound) / 2, timeline.total - 0.02] {
            vault.update(.entry(timeline, elapsed: t))
            #expect(sleeve.isEnabled && inside.isEnabled, "t \(t)")
            let bounds = sleeve.visualBounds(relativeTo: nil)
            #expect(bounds.max.z < wall.position.z && bounds.min.z <= inside.position.z, "t \(t): wall to backdrop")
            #expect(bounds.max.y < wallTop() && bounds.min.y > scene.layout.corridorFloorY, "t \(t): under the wall's top")
            // Any point of the backdrop maps to its own texture coordinate.
            for local in [SIMD3<Float>(0.3, -0.2, 0), [-0.6, 0.35, 0], [0, 0, 0]] {
                let world = inside.convert(position: local, to: nil)
                let uv = vault.roomArtCoordinate(of: world)
                #expect(abs(uv.x - (0.5 + local.x / FinalVaultArt.insideAspect)) < 1e-3 && abs(uv.y - (0.5 + local.y)) < 1e-3,
                        "t \(t) \(local): \(uv)")
            }
        }
        vault.update(.inside(timeline))
        #expect(sleeve.isEnabled && inside.isEnabled, "inside: the same room")
        vault.update(.hidden)
        #expect(!sleeve.isEnabled)
    }

    @Test func tutorialDoorwayDiscardsTransparentTexelsOnBothLayers() async throws {
        let tutorialScene = try await scene()
        let normalScene = try await scene()
        let tutorial = FinalVaultPresentation(scene: tutorialScene, usesDoorwayAlphaCutout: true)
        let normal = FinalVaultPresentation(scene: normalScene)
        let timeline = LaserFinalVaultTimeline(roster: PlayerID.allCases)
        let crossing = FinalVaultPresentation.Stage.entry(timeline, elapsed: 3.45)
        tutorial.update(crossing)
        normal.update(crossing)

        func material(_ scene: LaserScene, _ name: String) throws -> UnlitMaterial {
            let surface = try #require(scene.root.findEntity(named: name) as? ModelEntity)
            return try #require(surface.model?.materials.first as? UnlitMaterial)
        }
        for layer in ["finalVault.wallFront", "finalVault.open"] {
            let tutorialMaterial = try material(tutorialScene, layer)
            let normalMaterial = try material(normalScene, layer)
            #expect(tutorialMaterial.opacityThreshold == 0.02)
            #expect(normalMaterial.opacityThreshold == nil)
        }
    }

    @Test func eachJumpPassesThroughTheDoorway() async throws {
        let scene = try await scene()
        let vault = FinalVaultPresentation(scene: scene)
        #expect(vault.doorwayY > scene.layout.corridorFloorY + 0.5 && vault.doorwayY < scene.layout.corridorFloorY + scene.layout.corridorHeight - 0.5)
        #expect(vault.doorwayRadius > 0.6 && vault.doorwayRadius < 1)
        for player in PlayerID.allCases {
            let laneX = scene.mapping.laneCenterX[player, default: 0]
            let wallZ = FinalVaultPresentation.stopZ - scene.mapping.interactionPlaneZ
            let f = try #require(stride(from: Float(0), through: 1, by: 0.001).first { vault.jumpOffset(player, at: $0).z <= wallZ })
            let at = vault.jumpOffset(player, at: f)
            let middle = SIMD2(laneX + at.x, at.y + 0.5)
            #expect(simd_distance(middle, SIMD2(0, vault.doorwayY)) < vault.doorwayRadius * 0.6, "\(player) at f \(f)")
            #expect(vault.jumpOffset(player, at: 0) == .zero)
            // Up first: a jump, not a slide.
            #expect(vault.jumpOffset(player, at: 0.35).y > 0.8)
        }
    }

    @Test func lemonThenTangerineJumpTheirBoardsStayAndNoBoardsInside() async throws {
        let scene = try await scene(robots: true)
        let robots = try #require(scene.robotAvatars)
        let vault = FinalVaultPresentation(scene: scene)
        let timeline = LaserFinalVaultTimeline(roster: PlayerID.allCases)
        let lemon = try #require(timeline.jump(of: .player1)), tangerine = try #require(timeline.jump(of: .player2))

        vault.update(.entry(timeline, elapsed: lemon.lowerBound + 0.5))
        let p1 = try #require(robots.scriptedMoves[.player1])
        #expect(p1.offset.y > 0 && p1.offset.z < 0 && p1.opacity == 1)
        #expect(robots.scriptedMoves[.player2] ?? RobotAvatarLayer.ScriptedMove.none == RobotAvatarLayer.ScriptedMove.none)
        #expect(robots.hoverboards[.player1]?.root.isEnabled == true) // the board stays behind, fading

        vault.update(.entry(timeline, elapsed: lemon.upperBound + FinalVaultPresentation.continueDuration + 0.05))
        // Lemon has carried the jump on through the doorway and stands inside the vault, visible
        // (13 November 2026: it used to vanish here and drop in from above later).
        let inside = try #require(robots.scriptedMoves[.player1])
        #expect(inside.opacity == 1 && inside.offset.z < FinalVaultPresentation.stopZ - scene.mapping.interactionPlaneZ && abs(inside.offset.y) < 1e-4)
        #expect((robots.scriptedMoves[.player2]?.offset.y ?? 0) > 0 && robots.scriptedMoves[.player2]?.opacity == 1, "Tangerine in flight")
        #expect(robots.hoverboards[.player1]?.root.isEnabled == false)

        vault.update(.inside(timeline))
        for player in PlayerID.allCases {
            let move = try #require(robots.scriptedMoves[player])
            #expect(move.offset == .zero && move.opacity == 1 && move.scale == 1 && move.boardOpacity == 0)
            #expect(robots.hoverboards[player]?.root.isEnabled == false)
        }
        vault.update(.hidden)
        #expect(robots.scriptedMoves.isEmpty)
        #expect(PlayerID.allCases.allSatisfy { robots.hoverboards[$0]?.root.isEnabled == true })
    }

    @Test func soloMovesLemonOnly() async throws {
        let scene = try await scene(robots: true, players: [.player1])
        let robots = try #require(scene.robotAvatars)
        let vault = FinalVaultPresentation(scene: scene)
        let timeline = LaserFinalVaultTimeline(roster: [.player1])
        for t in stride(from: 0.0, through: timeline.total, by: 0.1) {
            vault.update(.entry(timeline, elapsed: t))
            #expect(robots.scriptedMoves[.player2] == nil)
        }
        vault.update(.entry(timeline, elapsed: timeline.total))
        #expect(robots.scriptedMoves[.player1]?.opacity == 1 && robots.scriptedMoves[.player1]?.offset == .zero)
    }

    // MARK: - Presenter and HUD

    private func configuration() throws -> LaserRoundConfiguration {
        try LaserRoundConfiguration(
            evidenceTiming: LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25, deliveryAllowance: 0.1),
            clearanceMargin: 0.005, diamondPoints: nil, missionGateTarget: 5, actionCueLead: 1.4)
    }

    private func state(_ time: Double, _ phase: LaserRoundPhase) -> LaserGameState {
        LaserGameState(sessionGeneration: generation, phase: phase, gameTime: time, activityProgress: 60,
                       teamHealth: 5, teamScore: 0, encounters: [], missionProgress: 5, missionTarget: 5, vault: nil)
    }

    @Test func diamondTimeDiamondsAppearOnlyInsideTheVault() async throws {
        let scene = try await scene()
        scene.installDiamondArt(await LaserScene.loadDiamondArtwork())
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [])
        presenter.diamondTime.source = { _ in
            [DiamondTimeDiamond(id: 1, lane: .player1, offsetX: 0.3, heightAboveFloor: 1.4, collected: false)]
        }
        let events = [GameEvent(id: UUID(), sessionGeneration: generation, sequence: 1, gameTime: 60,
                                kind: .phaseChanged(.diamondTime))]
        var entry = LaserFinalVaultEntry(roster: PlayerID.allCases)
        entry.advance(by: 1)
        presenter.apply(state: state(60, .diamondTime), events: events, snapshot: nil, finalVault: entry)
        #expect(presenter.finalVault.stage == .entry(entry.timeline, elapsed: 1))
        #expect(presenter.diamondTime.floatingIDs.isEmpty && scene.isCorridorShown)
        entry.advance(by: 10)
        presenter.apply(state: state(60.5, .diamondTime), events: events, snapshot: nil, finalVault: entry)
        #expect(presenter.finalVault.stage == .inside(entry.timeline))
        #expect(presenter.diamondTime.floatingIDs == [1] && !scene.isCorridorShown)
        // Replay has no entry: Diamond Time is shown inside at once. Before it, nothing.
        presenter.apply(state: state(61, .diamondTime), events: events, snapshot: nil)
        #expect(presenter.finalVault.stage == .inside(nil))
        let fresh = GameplayScenePresenter(scene: try await self.scene(), configuration: try configuration(), encounters: [])
        fresh.apply(state: state(30, .activity), events: [], snapshot: nil)
        #expect(fresh.finalVault.stage == .hidden)
    }

    @Test func theHudWaitsForTheTeamToBeInsideBeforeDiamondTimesTitleAndSeconds() throws {
        let events = [GameEvent(id: UUID(), sessionGeneration: generation, sequence: 1, gameTime: 60,
                                kind: .phaseChanged(.diamondTime))]
        let entering = GameplayHUDModel(state: state(60, .diamondTime), events: events, configuration: try configuration(),
                                        activityDuration: 60, enteringFinalVault: true)
        #expect(entering.banner == .none && entering.diamondSecondsLeft == nil && entering.diamondReached)
        let inside = GameplayHUDModel(state: state(60, .diamondTime), events: events, configuration: try configuration(),
                                      activityDuration: 60)
        #expect(inside.banner == .retrieveDiamonds && inside.diamondSecondsLeft == 20)
    }

    // MARK: - One continuous jump (13 November 2026)

    /// The rendered mascot through the whole entry at 120 Hz, Solo and co-op: never hidden after
    /// take-off, no jump in place or in on-screen size between frames, never ahead of the wall
    /// while it shows, and on its own place, full size and live at the end.
    @Test(arguments: [false, true]) func theEntryIsOneContinuousMovement(solo: Bool) async throws {
        let roster: [PlayerID] = solo ? [.player1] : PlayerID.allCases
        let scene = try await scene(robots: true, players: Set(roster))
        let robots = try #require(scene.robotAvatars)
        let vault = FinalVaultPresentation(scene: scene)
        let timeline = LaserFinalVaultTimeline(roster: roster)
        // Position as drawn, relative to the camera (it moves in the push); the move's own size and opacity (the layer also dims an untracked
        // mascot, and the take-off's crouch-to-stretch is a change of shape, not of size).
        func rendered(_ player: PlayerID) throws -> (position: SIMD3<Float>, scale: Float, opacity: Float) {
            let container = try #require(robots.robots[player]?.container)
            let move = robots.scriptedMoves[player] ?? .none
            return (container.position(relativeTo: nil) - scene.cameraWorldPosition, move.scale, container.isEnabled ? move.opacity : 0)
        }
        var last: [PlayerID: (position: SIMD3<Float>, scale: Float, opacity: Float)] = [:]
        let dt = 1.0 / 120
        for step in 0...Int(timeline.total / dt) {
            let t = Double(step) * dt
            vault.update(.entry(timeline, elapsed: t))
            for player in roster {
                let now = try rendered(player)
                let jump = try #require(timeline.jump(of: player))
                if t >= jump.lowerBound { #expect(now.opacity == 1, "\(player) visible at \(t)") }
                if let before = last[player] {
                    #expect(simd_distance(now.position, before.position) < 0.12, "\(player) jumps \(simd_distance(now.position, before.position)) m at \(t)")
                    // On-screen size (scale over distance from the camera) changes smoothly.
                    let size = now.scale / -now.position.z, sizeBefore = before.scale / -before.position.z
                    #expect(abs(size / sizeBefore - 1) < 0.05, "\(player) size step \(size / sizeBefore) at \(t)")
                }
                // While the wall shows, the mascot is never in front of it.
                if let wall = scene.root.findEntity(named: "finalVault.wall"), wall.isEnabled, t > jump.upperBound {
                    #expect(now.position.z + scene.cameraWorldPosition.z < wall.position(relativeTo: nil).z, "\(player) behind the wall at \(t)")
                }
                last[player] = now
            }
        }
        vault.update(.entry(timeline, elapsed: timeline.total))
        #expect(robots.walksInVault, "floor walking before Diamond Time starts")
        for player in roster {
            let move = try #require(robots.scriptedMoves[player])
            #expect(move.offset == .zero && move.scale == 1 && move.squash == 1 && move.anchorWeight == 0, "\(player): live at the end")
        }
        // Diamond Time: the same place, no pop.
        let before = try roster.map { try rendered($0).position }
        vault.update(.inside(timeline))
        let after = try roster.map { try rendered($0).position }
        #expect(zip(before, after).allSatisfy { simd_distance($0, $1) < 1e-4 })
    }

    /// 14 November 2026: the push used to slide the wall toward a still camera while the room stayed
    /// locked to the screen, so the doorway grew around a room that did not (it read as zooming out).
    /// Now the gate stands still and the camera dollies forward through its doorway, leaving and
    /// arriving at rest; at the end the camera and the room move back together, so the picture of
    /// the gameplay camera inside is exactly the picture at the end of the push.
    @Test(arguments: [false, true]) func theCameraMovesThroughTheStillGateIntoTheRoom(solo: Bool) async throws {
        let roster: [PlayerID] = solo ? [.player1] : PlayerID.allCases
        let scene = try await scene(robots: true, players: Set(roster))
        let vault = FinalVaultPresentation(scene: scene)
        let timeline = LaserFinalVaultTimeline(roster: roster)
        let wall = try entity(scene, "finalVault.wall"), camera = try entity(scene, "camera")
        let backdrop = try entity(scene, "finalVault.inside"), sleeve = try entity(scene, "finalVault.sleeve")
        let gameplay = scene.layout.cameraPosition
        vault.update(.entry(timeline, elapsed: timeline.push.lowerBound))
        let gate = wall.transformMatrix(relativeTo: nil)
        #expect(scene.cameraDolly == .zero)

        var last = gameplay, steps: [Float] = [], crossed: SIMD3<Float>?
        let dt = 1.0 / 120
        for step in 1...Int((timeline.total - timeline.push.lowerBound) / dt) {
            let t = timeline.push.lowerBound + Double(step) * dt
            guard t < timeline.total else { break }
            vault.update(.entry(timeline, elapsed: t))
            // The gate never moves or scales.
            let now = wall.transformMatrix(relativeTo: nil)
            #expect(simd_almost_equal_elements(now, gate, 1e-5), "gate moved at \(t)")
            // The camera itself moves: straight ahead, never back.
            let eye = camera.position(relativeTo: nil)
            #expect(simd_distance(eye, scene.cameraWorldPosition) < 1e-4)
            #expect(abs(eye.x - gameplay.x) < 1e-5 && abs(eye.y - gameplay.y) < 1e-5)
            #expect(eye.z <= last.z + 1e-6, "camera pulled back at \(t)")
            if crossed == nil, eye.z < wall.position(relativeTo: nil).z { crossed = eye }
            steps.append(last.z - eye.z)
            last = eye
        }
        // Through the doorway (well inside its circle), not the wall, and into the room.
        let crossing = try #require(crossed, "the camera passes the wall")
        #expect(simd_distance(SIMD2(crossing.x, crossing.y), SIMD2(0, vault.doorwayY)) < vault.doorwayRadius * 0.2)
        #expect(abs(last.z - (gameplay.z - vault.pushDistance)) < 0.01)
        // Leaves and arrives at rest, with no jolt between frames.
        let peak = try #require(steps.max())
        #expect(steps.first! < peak * 0.05 && steps.last! < peak * 0.05)
        #expect(zip(steps, steps.dropFirst()).allSatisfy { abs($1 - $0) < peak * 0.05 })

        // The end of the push and the gameplay camera inside show the same picture.
        func relative(_ e: Entity) -> simd_float4x4 { camera.transformMatrix(relativeTo: nil).inverse * e.transformMatrix(relativeTo: nil) }
        vault.update(.entry(timeline, elapsed: timeline.total - 1e-6))
        let before = (relative(backdrop), relative(sleeve))
        vault.update(.inside(timeline))
        #expect(scene.cameraDolly == .zero && simd_distance(camera.position(relativeTo: nil), gameplay) < 1e-5)
        #expect(simd_almost_equal_elements(relative(backdrop), before.0, 1e-4) && simd_almost_equal_elements(relative(sleeve), before.1, 1e-4))
        vault.update(.hidden)
        #expect(scene.cameraDolly == .zero)
    }

    /// The jump hands over to its continuation with the same position and velocity, and comes
    /// down on the mascot's landing still falling, with no sideways or forward speed (no skating).
    @Test func theJumpCarriesOnIntoTheLandingWithoutAKink() async throws {
        let scene = try await scene()
        let vault = FinalVaultPresentation(scene: scene)
        let flight = Float(LaserFinalVaultTimeline.jumpDuration - LaserFinalVaultTimeline.anticipation)
        let span = Float(FinalVaultPresentation.continueDuration)
        let h: Float = 1e-3
        for player in PlayerID.allCases {
            #expect(simd_distance(vault.jumpOffset(player, at: 1), vault.continuation(player, at: 0)) < 1e-5)
            let jumpVelocity = (vault.jumpOffset(player, at: 1) - vault.jumpOffset(player, at: 1 - h)) / (h * flight)
            let carryVelocity = (vault.continuation(player, at: h) - vault.continuation(player, at: 0)) / (h * span)
            #expect(simd_distance(jumpVelocity, carryVelocity) < 0.05 * simd_length(jumpVelocity), "\(player): \(jumpVelocity) vs \(carryVelocity)")
            let down = vault.continuation(player, at: 1)
            #expect(simd_distance(down, [0, 0, -vault.pushDistance]) < 1e-5, "lands on its own place inside")
            let landing = (vault.continuation(player, at: 1) - vault.continuation(player, at: 1 - h)) / (h * span)
            #expect(abs(landing.x) < 0.02 && abs(landing.z) < 0.02 && landing.y < -1, "\(player) touchdown \(landing)")
            // Never below the floor on the way down.
            #expect(stride(from: Float(0), through: 1, by: 0.01).allSatisfy { vault.continuation(player, at: $0).y >= -1e-4 })
        }
    }

    // MARK: - Fixed places in the vault (20 November 2026)

    /// Co-op: P1 left and P2 right of the vault's centre, symmetric, as far apart as the lanes
    /// (wider than a board, so neither mascots nor boards overlap); Solo: the one mascot on the centre.
    @Test func theLandingPlacesAreFixedSymmetricAndOrdered() async throws {
        let scene = try await scene(robots: true)
        let vault = FinalVaultPresentation(scene: scene)
        vault.update(.inside(LaserFinalVaultTimeline(roster: PlayerID.allCases)))
        let p1 = vault.landingX(.player1), p2 = vault.landingX(.player2), c = FinalVaultPresentation.centerX
        #expect(p1 < c && c < p2, "P1 left, P2 right")
        #expect(abs((p1 + p2) / 2 - c) < 1e-6, "symmetric about the vault's centre")
        let lanes = scene.mapping.laneCenterX
        #expect(abs((p2 - p1) - abs(lanes[.player2, default: 0] - lanes[.player1, default: 0])) < 1e-6, "as far apart as the lanes")
        #expect(p2 - p1 > 2 * PlayerHoverboard.halfWidth + 0.2, "clear of each other: \(p2 - p1) m")
        vault.update(.inside(LaserFinalVaultTimeline(roster: [.player1])))
        #expect(vault.landingX(.player1) == c, "Solo: on the centre")
        vault.update(.hidden)
    }

    /// Where each mascot is drawn (world X).
    private func drawnX(_ robots: RobotAvatarLayer, _ player: PlayerID) throws -> Float {
        try #require(robots.robots[player]?.container).position(relativeTo: nil).x
    }

    /// THE FIX: wherever the mascots stand before the vault (far out, near the centre, asymmetric),
    /// the jump starts where they are and lands on the same two places, every time; the drawn mascot
    /// never jumps between frames (no snap), and Diamond Time starts on those places. The live root
    /// is held off-centre throughout (the game state's boards), so nothing of it leaks inside.
    @Test(arguments: [false, true]) func everyEntryLandsOnTheSamePlacesWhereverTheyStarted(solo: Bool) async throws {
        let roster: [PlayerID] = solo ? [.player1] : PlayerID.allCases
        let scene = try await scene(robots: true, players: Set(roster))
        let robots = try #require(scene.robotAvatars)
        robots.smoothing = 0.03
        let vault = FinalVaultPresentation(scene: scene)
        let timeline = LaserFinalVaultTimeline(roster: roster)
        let starts: [[PlayerID: Float]] = solo
            ? [[.player1: -1.7], [.player1: 0], [.player1: 1.6], [.player1: -0.7]]
            : [[.player1: -1.7, .player2: 1.7], [.player1: -0.4, .player2: 0.4], [.player1: -1.5, .player2: 0.2], [.player1: -0.2, .player2: 1.6]]
        var landed: [[PlayerID: Float]] = [], began: [[PlayerID: Float]] = []
        var now = 0.0
        for start in starts {
            vault.update(.hidden)
            robots.authoritativeBoardX = start
            for _ in 0..<30 { now += 1.0 / 60; robots.render(now: now) }
            // Where they really start (the steering keeps its own bounds and spacing).
            began.append(Dictionary(uniqueKeysWithValues: try roster.map { ($0, try drawnX(robots, $0)) }))
            var last: [PlayerID: Float] = [:]
            let dt = 1.0 / 120
            for step in 0...Int(timeline.total / dt) {
                now += dt
                vault.update(.entry(timeline, elapsed: Double(step) * dt))
                robots.render(now: now)
                for player in roster {
                    let x = try drawnX(robots, player)
                    if let before = last[player] { #expect(abs(x - before) < 0.06, "\(player) from \(start[player]!): sideways step \(abs(x - before)) at \(Double(step) * dt)") }
                    last[player] = x
                }
            }
            vault.update(.entry(timeline, elapsed: timeline.total))
            robots.render(now: now + 1.0 / 60)
            vault.update(.inside(timeline))
            for _ in 0..<30 { now += 1.0 / 60; robots.render(now: now) }
            landed.append(Dictionary(uniqueKeysWithValues: try roster.map { ($0, try drawnX(robots, $0)) }))
        }
        for player in roster {
            let xs = began.map { $0[player]! }
            #expect((xs.max()! - xs.min()!) > 1.0, "\(player): the starts really differ (\(xs))")
        }
        print("FINAL VAULT LANDING " + zip(began, landed).map { b, l in
            roster.map { String(format: "%@ %+.3f → %+.3f", $0.rawValue, b[$0]!, l[$0]!) }.joined(separator: ", ") }.joined(separator: " | "))
        for (start, end) in zip(began, landed) {
            for player in roster {
                #expect(abs(end[player]! - vault.landingX(player)) < 0.005, "from \(start): \(player) at \(end[player]!), place \(vault.landingX(player))")
            }
            if !solo { #expect(end[.player1]! < end[.player2]!, "P1 stays left of P2") }
        }
        // Repeated entries: the same places to the millimetre.
        for player in roster { #expect(landed.allSatisfy { abs($0[player]! - landed[0][player]!) < 0.001 }) }
        robots.authoritativeBoardX = [:]
        vault.update(.hidden)
        #expect(!robots.walksInVault)
    }

    /// Replay (inside without the entry) shows the mascots on the same places; leaving the vault
    /// drops them, so the next round starts from the corridor again.
    @Test func theReplaysInsideUsesTheSamePlacesAndLeavingDropsThem() async throws {
        let scene = try await scene(robots: true)
        let robots = try #require(scene.robotAvatars)
        robots.smoothing = 0.03
        let vault = FinalVaultPresentation(scene: scene)
        robots.authoritativeBoardX = [.player1: -1.6, .player2: 0.9]
        var now = 0.0
        for _ in 0..<30 { now += 1.0 / 60; robots.render(now: now) }
        vault.update(.inside(nil))
        for _ in 0..<30 { now += 1.0 / 60; robots.render(now: now) }
        for player in PlayerID.allCases {
            #expect(abs(try drawnX(robots, player) - vault.landingX(player)) < 0.005, "\(player) on its place")
        }
        vault.update(.hidden)
        for _ in 0..<30 { now += 1.0 / 60; robots.render(now: now) }
        #expect(abs(try drawnX(robots, .player1) - -1.6) < 0.02, "back in the corridor: the live position again")
        robots.authoritativeBoardX = [:]
    }

    /// A held root keeps the scripted mascot still against live tracking, then blends back.
    @Test func aHeldRootBlendsBackToTheTrackedRoot() async throws {
        let scene = try await scene(robots: true, players: [.player1])
        let robots = try #require(scene.robotAvatars)
        let tracked = robots.trackedRootPosition(.player1) ?? .zero
        let held = tracked + [0.4, 0, 0]
        robots.scriptedMoves[.player1] = .init(offset: [0, 0.2, 0], anchor: held, anchorWeight: 1)
        let container = try #require(robots.robots[.player1]?.container)
        #expect(simd_distance(container.position, held + [0, 0.2, 0]) < 1e-5)
        robots.scriptedMoves[.player1] = .init(anchor: held, anchorWeight: 0.5)
        #expect(simd_distance(container.position, tracked + [0.2, 0, 0]) < 1e-5)
        robots.scriptedMoves[.player1] = .init(anchor: held, anchorWeight: 0)
        #expect(simd_distance(container.position, tracked) < 1e-5)
    }
}
