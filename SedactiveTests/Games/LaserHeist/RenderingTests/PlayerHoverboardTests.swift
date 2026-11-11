import RealityKit
import Testing
import UIKit
@testable import Sedactive

/// The players' 3D hoverboards: the asset as RealityKit loads it, one board
/// per mascot that never moves the lane, `ride` or the mascot, and the
/// cosmetic hover and bank (deterministic, bounded, neutral without tracking).
@MainActor
struct PlayerHoverboardTests {
    typealias Motion = PlayerHoverboard.Motion
    typealias Input = PlayerHoverboard.Input

    private static func run(_ motion: inout Motion, _ input: Input, seconds: Float, dt: Float = 1 / 60) {
        for _ in 0..<Int((seconds / dt).rounded()) { motion.step(dt: dt, input: input) }
    }

    // MARK: Motion

    @Test("A lean to screen right dips the board's right side, smoothly and at most about 3°")
    func bankFollowsLean() {
        var motion = Motion()
        let lean = Input(lean: 0.15, available: true)
        motion.step(dt: 1 / 60, input: lean)
        #expect(motion.bank > 0 && motion.bank < Motion.bankTarget(for: lean), "eases in, never snaps")
        Self.run(&motion, lean, seconds: 1)
        #expect(abs(motion.bank - PlayerHoverboard.bankPerLean * 0.15) < 1e-3)
        #expect(motion.roll < 0, "negative roll about +Z lowers +X, screen right")
        Self.run(&motion, Input(lean: 5, available: true), seconds: 1)
        #expect(abs(motion.bank - PlayerHoverboard.maximumBank) < 1e-4)
        Self.run(&motion, Input(lean: -5, available: true), seconds: 1)
        #expect(abs(motion.bank + PlayerHoverboard.maximumBank) < 1e-4)
    }

    @Test("Tracking loss keeps no stale lean or push-off: the board levels out")
    func trackingLossLevelsTheBoard() {
        var motion = Motion()
        Self.run(&motion, Input(lean: 0.3, lift: 0.2, available: true), seconds: 1)
        #expect(motion.bank > 0.05 && motion.recoil > 0.005)
        Self.run(&motion, Input(lean: 0.3, lift: 0.2, available: false), seconds: 1)
        #expect(abs(motion.bank) < 1e-4 && abs(motion.recoil) < 1e-4)
        Self.run(&motion, Input(lean: .nan, lift: .infinity, available: true), seconds: 1)
        #expect(abs(motion.bank) < 1e-4 && motion.recoil <= PlayerHoverboard.maximumRecoil, "invalid input is neutral")
    }

    @Test("The deck never rises above the soles' plane, whatever the hover, bank, pitch or push-off")
    func deckNeverRisesIntoTheFeet() {
        var motion = Motion()
        var lowest: Float = 0
        for step in 0..<1200 {
            let t = Float(step) / 60
            motion.step(dt: 1 / 60, input: Input(lean: 0.4 * sin(t * 2.3), lift: max(0, 0.3 * sin(t * 1.7)), available: step % 400 < 300))
            // The raised side of the deck under each foot, including the bank and pitch.
            let rise = PlayerHoverboard.footHalfSpan * sin(abs(motion.roll)) + PlayerHoverboard.footHalfLength * sin(abs(motion.pitch))
            #expect(motion.height + rise <= 1e-6)
            lowest = min(lowest, motion.height)
        }
        // Subtle: never more than a few centimetres below the feet.
        #expect(lowest > -0.03)
    }

    @Test("The board glides under the stance, never far enough to meet the other lane's board")
    func boardGlidesWithTheStance() throws {
        var motion = Motion()
        Self.run(&motion, Input(stanceX: 0.1, available: true), seconds: 1)
        #expect(abs(motion.offsetX - 0.1) < 1e-3)
        Self.run(&motion, Input(stanceX: 5, available: true), seconds: 1)
        #expect(abs(motion.offsetX - PlayerHoverboard.maximumGlide) < 1e-3)
        Self.run(&motion, Input(stanceX: .nan, available: true), seconds: 1)
        #expect(abs(motion.offsetX) < 1e-3)
        // Toward the partner's lane (P1's partner is at +X) the glide stops short...
        var p1 = Motion(inward: 1)
        Self.run(&p1, Input(stanceX: 5, available: true), seconds: 1)
        #expect(abs(p1.offsetX - PlayerHoverboard.maximumInwardGlide) < 1e-3)
        Self.run(&p1, Input(stanceX: -5, available: true), seconds: 1)
        #expect(abs(p1.offsetX + PlayerHoverboard.maximumGlide) < 1e-3, "outward it glides fully")
        // ...so both boards gliding fully toward each other stay apart.
        let halfWidth: Float = 0.58 * PlayerHoverboard.scale
        let lanes = GameWorldMapping().laneCenterX
        let distance = abs(try #require(lanes[.player2]) - (try #require(lanes[.player1])))
        #expect(distance - 2 * (PlayerHoverboard.maximumInwardGlide + halfWidth) > 0.1)
    }

    @Test("The same inputs give the same motion")
    func deterministic() {
        var a = Motion(hoverPhase: 0.3), b = Motion(hoverPhase: 0.3)
        for step in 0..<300 {
            let input = Input(lean: Float(step % 50) / 100, centerX: 0, lift: step % 90 < 10 ? 0.2 : 0, available: true)
            a.step(dt: 1 / 60, input: input)
            b.step(dt: 1 / 60, input: input)
        }
        #expect(a == b)
    }

    // MARK: Asset

    @Test("The asset loads from the Reality Composer Pro package at game scale, facing the camera")
    func assetLoadsAtGameScale() async throws {
        let template = try #require(await PlayerHoverboard.sharedTemplate())
        let bounds = template.visualBounds(relativeTo: nil)
        #expect(abs(bounds.extents.x - 1.16) < 0.02, "width \(bounds.extents.x)")
        #expect(bounds.extents.z > 0.44 && bounds.extents.z < 0.56, "depth \(bounds.extents.z)")
        // Origin on the deck: the rim rises about 2 cm above it, the body hangs below.
        #expect(bounds.max.y > 0.01 && bounds.max.y < 0.03)
        #expect(bounds.min.y < -0.1 && bounds.min.y > -0.16)
        #expect(abs(bounds.center.x) < 0.01)
        let accent = try #require(template.findEntity(named: "Accent"))
        let display = accent.visualBounds(relativeTo: nil)
        #expect(display.extents.x > 1.0, "end stripes at both ends")
        // Delivered as two meshes: the shared body and the per-player accent.
        #expect(template.findEntity(named: "Body") != nil)
    }

    // MARK: Integration

    private static func sceneWithBoards() async throws -> (LaserScene, RobotAvatarLayer) {
        let scene = LaserScene()
        scene.installEnvironment(authored: await LaserScene.loadAuthoredEnvironment())
        let templates = try await RobotAvatarLayer.sharedTemplates()
        let layer = RobotAvatarLayer(scene: scene, players: Set(PlayerID.allCases), templates: templates)
        scene.robotAvatars = layer
        return (scene, layer)
    }

    @Test("Each board glides short toward its partner's lane")
    func boardsKnowWhereTheirPartnerIs() async throws {
        let (_, layer) = try await Self.sceneWithBoards()
        #expect(layer.hoverboards[.player1]?.motion.inward == 1)
        #expect(layer.hoverboards[.player2]?.motion.inward == -1)
        layer.remove()
    }

    @Test("Each mascot stands on its own board, beside the lane's ride; the shared 2D board is hidden until they leave")
    func oneBoardPerMascot() async throws {
        let lanes = LaserScene().players.mapValues(\.position)
        let (scene, layer) = try await Self.sceneWithBoards()
        let twoD = try #require(scene.hoverboard)
        #expect(!twoD.root.isEnabled)
        #expect(Set(layer.hoverboards.keys) == Set(PlayerID.allCases))
        for (player, board) in layer.hoverboards {
            let lane = try #require(scene.players[player])
            #expect(board.root.parent === lane)
            #expect(lane.ride.transform == .identity)
            #expect(lane.position == lanes[player], "the lane never moves")
            #expect(board.root.transform == .identity, "the board moves only its model inside its own root")
        }
        let p1 = try #require(layer.hoverboards[.player1]).model
        let p2 = try #require(layer.hoverboards[.player2]).model
        #expect(p1 !== p2)
        layer.remove()
        #expect(layer.hoverboards.isEmpty && twoD.root.isEnabled)
        for player in scene.players.values {
            #expect(!player.children.contains { $0.name.hasSuffix(".hoverboard") })
        }
    }

    @Test("Scaled together: each mascot's soles stand on its board's deck, well inside its ends")
    func mascotStandsOnTheScaledBoard() async throws {
        let (scene, layer) = try await Self.sceneWithBoards()
        for player in PlayerID.allCases {
            let lane = try #require(scene.players[player]).position
            let points = try #require(layer.extremityPoints(of: player))
            let board = try #require(layer.hoverboards[player])
            let deck = board.model.visualBounds(relativeTo: nil)
            // The mascot and the board share one scale: about 1.2 m and 0.87 m.
            #expect(abs(points.headTop.y - lane.y - RobotAvatarLayer.standingHeight) < 0.06)
            #expect(abs(deck.extents.x - 1.16 * PlayerHoverboard.scale) < 0.02)
            for sole in [points.leftSole, points.rightSole] {
                #expect(sole.x > deck.min.x + 0.12 && sole.x < deck.max.x - 0.12, "\(player) sole \(sole.x) on deck \(deck.min.x)...\(deck.max.x)")
                #expect(abs(sole.y - lane.y) < 0.02, "\(player) sole on the deck: \(sole.y)")
            }
            #expect(deck.max.y - lane.y < 0.02 && deck.max.y - lane.y > 0, "only the rim rises above the soles")
        }
        layer.remove()
    }

    @Test("Boards take each player's accent colour from one shared model")
    func accentPerPlayer() async throws {
        let (_, layer) = try await Self.sceneWithBoards()
        func accent(_ player: PlayerID) throws -> UIColor? {
            let entity = try #require(layer.hoverboards[player]?.model.findEntity(named: "Accent"))
            let model = try #require(Self.firstModel(in: entity))
            return (model.materials.first as? PhysicallyBasedMaterial)?.baseColor.tint
        }
        func rgb(_ color: UIColor?) -> SIMD3<Float>? {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard let color, color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
            return [Float(r), Float(g), Float(b)]
        }
        for player in PlayerID.allCases {
            let shown = try #require(rgb(try accent(player)))
            let wanted = try #require(rgb(PlayerHoverboard.accentColor[player]))
            #expect(simd_length(shown - wanted) < 0.02, "\(player): \(shown) vs \(wanted)")
        }
        layer.remove()
    }

    @Test("Stepping a board never moves the mascot it carries")
    func boardMotionLeavesTheMascotAlone() async throws {
        let (scene, layer) = try await Self.sceneWithBoards()
        let robot = try #require(layer.robots[.player1])
        let before = robot.container.transform
        let headTop = layer.extremityPoints(of: .player1)?.headTop
        let board = try #require(layer.hoverboards[.player1])
        board.input = .init(lean: 0.3, centerX: 0.1, lift: 0.1, available: true)
        for _ in 0..<120 { board.step(dt: 1 / 60) }
        #expect(robot.container.transform == before)
        #expect(layer.extremityPoints(of: .player1)?.headTop == headTop)
        #expect(board.model.position.y <= 0 && board.motion.bank > 0)
        #expect(scene.players[.player1]?.ride.transform == .identity)
        layer.remove()
    }

    private static func firstModel(in entity: Entity) -> ModelComponent? {
        if let model = entity.components[ModelComponent.self] { return model }
        for child in entity.children { if let model = firstModel(in: child) { return model } }
        return nil
    }
}
