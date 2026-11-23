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
        // Never more than a few centimetres below the feet (3.5 cm with the 6° lean bank).
        #expect(lowest > -0.035)
    }

    /// The board itself has no lane limit (12 November 2026): where it may go is
    /// `LateralSteering`'s (walls, partner), tested in `LeanSteeringTests`.
    @Test("The board glides under the stance and sits exactly on a given ride")
    func boardGlidesWithTheStance() throws {
        var motion = Motion()
        Self.run(&motion, Input(stanceX: 0.1, available: true), seconds: 1)
        #expect(abs(motion.offsetX - 0.1) < 1e-3)
        Self.run(&motion, Input(stanceX: 1.8, available: true), seconds: 1)
        #expect(abs(motion.offsetX - 1.8) < 1e-3, "no lane limit")
        Self.run(&motion, Input(stanceX: .nan, available: true), seconds: 1)
        #expect(abs(motion.offsetX) < 1e-3)
        motion.step(dt: 1 / 60, input: Input(available: true, ride: -2.1))
        #expect(motion.offsetX == -2.1, "a ride is followed at once (the feet are planted on it)")
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

    @Test("The boards' steering knows both lanes, the corridor and the loaded board's width")
    func boardsKnowWhereTheirPartnerIs() async throws {
        let (scene, layer) = try await Self.sceneWithBoards()
        let steering = try #require(layer.steering)
        #expect(steering.riders[.player1]?.laneX == scene.players[.player1]?.position.x)
        #expect(steering.riders[.player2]?.laneX == scene.players[.player2]?.position.x)
        #expect(abs(steering.halfWidth - 0.58 * PlayerHoverboard.scale) < 0.02, "from the asset: \(steering.halfWidth)")
        #expect(steering.bounds.upperBound + steering.halfWidth < scene.layout.corridorWidth / 2, "inside the walls")
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

    /// Live lean: the board carries the mascot sideways with its hips and its lean steering, the
    /// feet stay planted ON the board (no sliding), and the board banks toward the lean.
    @Test(arguments: [RobotDemoScenario.leanLeft, .leanRight, .stepLeft, .stepRight])
    func theBoardCarriesTheMascotWithItsLean(_ scenario: RobotDemoScenario) async throws {
        let scene = LaserScene()
        scene.installEnvironment(authored: await LaserScene.loadAuthoredEnvironment())
        let input = try LaserReplayScript.load().input
        let layer = RobotAvatarLayer(scene: scene, calibrations: input.configuration.calibrations,
                                     layout: input.configuration.playerPlaneLayout,
                                     templates: try await RobotAvatarLayer.sharedTemplates())
        scene.robotAvatars = layer
        layer.footPlanting = true
        layer.diagnosticsEnabled = true
        layer.smoothing = 0.03
        let board = try #require(layer.hoverboards[.player1], "boards are part of the live scene")
        let sequence = RobotDemoSequence(configuration: input.configuration,
                                         cameraGeometryRevision: input.cameraGeometryRevision, only: scenario)
        var lastFrame: UInt64 = 0, maxRide: Float = 0, maxBank: Float = 0, maxGap: Float = 0
        var steps = 0, drift: Float = 0
        var anchors: [RobotPoseTargets.Side: Float] = [:]
        for n in 1..<Int(RobotDemoScenario.duration * 60) {
            let time = Double(n) / 60
            let index = UInt64(time * RobotDemoSequence.frameRate)
            if index > lastFrame {
                let f = try sequence.frame(index)
                layer.apply(f.snapshot, joints: f.joints)
                lastFrame = index
            }
            layer.render(now: time)
            board.step(dt: 1 / 60)
            let d = try #require(layer.footDiagnostics[.player1])
            if abs(d.rideX) > abs(maxRide) { maxRide = d.rideX }
            maxBank = max(maxBank, abs(board.motion.bank))
            // The board sits exactly where it carries the feet.
            maxGap = max(maxGap, abs(board.motion.offsetX - d.rideX))
            steps = max(steps, d.steps.values.max() ?? 0)
            for side in RobotPoseTargets.Side.allCases where d.contact[side] == .planted {
                let x = d.actualX[side] ?? 0
                drift = max(drift, abs(x - (anchors[side] ?? x)))
                anchors[side] = anchors[side] ?? x
            }
            for side in RobotPoseTargets.Side.allCases where d.contact[side] != .planted { anchors[side] = nil }
        }
        let toward: Float = scenario == .leanLeft || scenario == .stepLeft ? -1 : 1
        let steering = try #require(layer.steering)
        let lane = try #require(steering.riders[.player1]).laneX
        print(String(format: "BOARD-RIDE %@ ride %.3f m bank %.1f° gap %.4f steps %d drift %.4f",
                     scenario.key, maxRide, maxBank * 180 / .pi, maxGap, steps, drift))
        #expect(maxRide * toward > 0.05, "the board rides the body")
        #expect(lane + maxRide >= steering.bounds.lowerBound - 1e-3 && lane + maxRide <= steering.bounds.upperBound + 1e-3,
                "within the corridor (float rounding at the limit)")
        #expect(maxGap < 1e-4, "board and planted feet move together")
        #expect(drift < 0.003, "planted feet never slide on the board")
        if scenario == .leanLeft || scenario == .leanRight {
            #expect(steps == 0, "a lean never steps")
            #expect(maxBank > 0.03, "the board visibly banks with the lean")
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

    // MARK: Verdict reactions

    @Test("CLEAR and HIT light the board at once, move it within bounds (never sideways, the deck under the rider's soles), and end at rest",
          arguments: [HoverboardReaction.clear, .hit])
    func verdictReactionsStayUnderTheFeet(kind: HoverboardReaction) {
        #expect(kind.duration <= 0.75, "one short beat")
        // The board's own lights change on the first frame (game feel: a big change within 100 ms).
        let first = kind.pose(at: 0, reduceMotion: false)
        #expect(first.core.energy == 1 && first.core.heat == 1, "the core ignites white-hot")
        #expect(kind.segment(23, at: 0, reduceMotion: false).energy > 0.5, "the ring's front segment is lit")
        // Folded into the board's motion, the deck stays at or below the soles every frame (the rider
        // rides the same lift, so the soles' plane moves with it), within a bounded, short motion.
        var motion = PlayerHoverboard.Motion()
        var lowest: Float = 0, highest: Float = 0
        for tau in stride(from: 0.0, through: kind.duration + 0.1, by: 1.0 / 120) {
            motion.reaction = kind.pose(at: tau, reduceMotion: false)
            let rise = PlayerHoverboard.footHalfSpan * sin(abs(motion.roll)) + PlayerHoverboard.footHalfLength * sin(abs(motion.pitch))
            #expect(motion.height + rise <= 1e-6)
            #expect(abs(motion.reaction.lift) <= HoverboardReaction.maximumLift)
            #expect(abs(motion.reaction.roll) <= 0.09 && abs(motion.reaction.yaw) <= 0.04 && abs(motion.reaction.pitch) <= 0.05,
                    "a shudder, never a tumble")
            lowest = min(lowest, motion.reaction.lift); highest = max(highest, motion.reaction.lift)
        }
        if kind == .clear {
            #expect(highest > 0.025, "a buoyant surge of hover power")
            #expect(kind.pose(at: 0.05, reduceMotion: false).lift < 0, "a crouch as the charge gathers")
        } else {
            #expect(kind.pose(at: 0.04, reduceMotion: false).lift < -0.02, "a hard drop on impact")
            #expect(kind.pose(at: 0.45, reduceMotion: false).lift < -0.015, "the hover sags in the failure")
        }
        // Nothing left after the beat.
        #expect(kind.pose(at: kind.duration, reduceMotion: false) == HoverboardReaction.Pose())
        #expect((0..<HoverboardReaction.segments).allSatisfy { kind.segment($0, at: kind.duration, reduceMotion: false) == .init() })
        // Reduce Motion: no sweep, flicker, brownout or shudder; one rise and fall, the ring lit as one.
        var last: Float = 0, falling = false
        for tau in stride(from: 0.0, through: kind.duration, by: 0.01) {
            let calm = kind.pose(at: tau, reduceMotion: true)
            let ring = (0..<HoverboardReaction.segments).map { kind.segment($0, at: tau, reduceMotion: true) }
            #expect(calm.roll == 0 && calm.lift == 0 && calm.pitch == 0 && calm.yaw == 0)
            #expect(calm.bars.energy >= 0 && Set(ring.map(\.energy)).count == 1)
            #expect(kind.pulse(at: tau, reduceMotion: true) == nil && kind.fieldScale(at: tau, reduceMotion: true) == 1)
            if calm.core.energy < last - 1e-6 { falling = true }
            #expect(!falling || calm.core.energy <= last + 1e-6, "no flicker")
            last = calm.core.energy
        }
    }

    @Test("CLEAR charges the rim from the core round to the back and peaks; HIT overloads, flickers and browns out")
    func clearAndHitAreDifferentEnergyStories() {
        let front = 23, side = 31, back = 7 // the front centre, the right end, the back centre
        #expect(HoverboardReaction.frontDistance(front) < 0.05)
        #expect(HoverboardReaction.frontDistance(back) > 0.95 && abs(HoverboardReaction.frontDistance(side) - 0.5) < 0.05)
        // CLEAR: the sweep reaches the side before the back, and the whole ring peaks when it meets.
        let clear = HoverboardReaction.clear
        func lit(_ index: Int, _ tau: Double) -> Bool { clear.segment(index, at: tau, reduceMotion: false).energy > 0.5 }
        let reachesSide = stride(from: 0.0, through: 0.3, by: 1.0 / 240).first { lit(side, $0) } ?? 1
        let reachesBack = stride(from: 0.0, through: 0.3, by: 1.0 / 240).first { lit(back, $0) } ?? 1
        #expect(reachesSide > 0.02 && reachesSide < reachesBack && reachesBack <= HoverboardReaction.meet + 0.01)
        #expect((0..<HoverboardReaction.segments).allSatisfy { clear.segment($0, at: 0.22, reduceMotion: false).energy == 1 })
        let peak = clear.pose(at: 0.22, reduceMotion: false)
        #expect(peak.circuit.energy == 1 && peak.bars.energy == 1 && peak.plates.energy == 1 && peak.vents.energy == 1)
        // CLEAR never flickers or dims below idle, and never shakes the board (only a small settling sway).
        for tau in stride(from: 0.0, to: clear.duration, by: 1.0 / 120) {
            let p = clear.pose(at: tau, reduceMotion: false)
            #expect(abs(p.roll) <= 0.02 && p.yaw == 0 && [p.core, p.bars, p.vents, p.circuit, p.plates, p.hull].allSatisfy { $0.energy >= 0 })
        }
        // HIT: everything surges on frame one, then the ring's segments disagree (a disrupted pattern).
        let hit = HoverboardReaction.hit
        #expect((0..<HoverboardReaction.segments).allSatisfy { hit.segment($0, at: 0, reduceMotion: false) == .init(energy: 1, heat: 1) })
        let disrupted = Set((0..<HoverboardReaction.segments).map { hit.segment($0, at: 0.15, reduceMotion: false).level })
        #expect(disrupted.count >= 4)
        // The core and bars stutter, then the power browns out below idle and reboots.
        let stutter = stride(from: 0.05, to: 0.32, by: 1.0 / 120).map { hit.pose(at: $0, reduceMotion: false).bars.level }
        #expect(Set(stutter).count >= 4 && stutter.contains { $0 < 0 })
        #expect(hit.pose(at: 0.36, reduceMotion: false).core.energy < -0.3, "brownout")
        // The flicker is on twos at most (12 Hz), so it never strobes.
        var changes = 0, previous = hit.pose(at: HoverboardReaction.surgeEnd, reduceMotion: false).core.level
        for tau in stride(from: HoverboardReaction.surgeEnd, to: HoverboardReaction.dischargeStart, by: 1.0 / 240) {
            let level = hit.pose(at: tau, reduceMotion: false).core.level
            if level != previous { changes += 1; previous = level }
        }
        #expect(changes <= 3)
        // A secondary discharge follows the dead gap.
        #expect(hit.pose(at: HoverboardReaction.dischargeStart + 0.01, reduceMotion: false).core.energy == 1)
    }

    @Test("HIT is an electrical shock: arcs on the rim, red-dominant ZAPPED! colours; CLEAR has none and stays gold")
    func hitIsElectricAndRed() {
        let hit = HoverboardReaction.hit, clear = HoverboardReaction.clear
        // Every site on the impact (rim and both end caps), a crackle, a dead gap, the secondary
        // discharge (both end caps and a rim site), then only short single sputters, then nothing.
        #expect(hit.arcs(at: 0, reduceMotion: false).count == HoverboardReaction.arcSites)
        for tau in stride(from: 0.12, to: 0.21, by: 0.01) { #expect(hit.arcs(at: tau, reduceMotion: false).count >= 2, "crackling") }
        #expect(hit.arcs(at: 0.22, reduceMotion: false).isEmpty)
        let secondary = hit.arcs(at: HoverboardReaction.dischargeStart + 0.02, reduceMotion: false)
        #expect(secondary.count == 3 && secondary.allSatisfy(\.secondary) && Set(secondary.map(\.site)).isSuperset(of: [4, 5]))
        var sputters = 0
        for tau in stride(from: HoverboardReaction.dischargeEnd, to: 1, by: 0.01) {
            let arcs = hit.arcs(at: tau, reduceMotion: false)
            #expect(arcs.count <= 1 && arcs.allSatisfy { !$0.secondary && $0.site >= 4 } && (arcs.isEmpty || tau < 0.5))
            sputters += arcs.count
        }
        #expect(sputters > 0, "residual sparking through the failure")
        for tau in stride(from: 0.0, to: 1, by: 0.01) {
            #expect(clear.arcs(at: tau, reduceMotion: false).isEmpty && hit.arcs(at: tau, reduceMotion: true).isEmpty)
        }
        // The ring is mostly red and coral (tones 0–1); white only flashes, pink only accents.
        var tones = [0, 0, 0, 0]
        for tau in stride(from: 0.0, to: hit.duration, by: 1.0 / 60) {
            for i in 0..<HoverboardReaction.segments {
                let glow = hit.segment(i, at: tau, reduceMotion: false)
                if glow.level > 0 { tones[glow.tone] += 1 }
            }
        }
        #expect(tones[0] + tones[1] > 2 * (tones[2] + tones[3]), "\(tones)")
        // The HIT palette is ZAPPED!'s red family; CLEAR's is gold. Never confusable.
        for tone in 0..<3 {
            let red = HoverboardReactionFX.tone(.hit, tone), gold = HoverboardReactionFX.tone(.clear, tone)
            #expect(red.x > 0.9 && red.y < 0.3, "red-coral-pink, no orange")
            #expect(gold.x == 1 && gold.y > 0.5 && gold.z < 0.35, "gold-amber")
        }
        // CLEAR's peak: the whole field stands, a warm-white flash, then radiant gold.
        #expect(clear.field(7, at: HoverboardReaction.meet + 0.01, reduceMotion: false) == .init(energy: 1, heat: 1))
        #expect(clear.segment(7, at: HoverboardReaction.flashEnd + 0.01, reduceMotion: false).tone == 1)
    }

    @Test("The discharges, field, ring and sparks are built on the board's own structure")
    func dischargesStartAndEndOnTheRim() throws {
        for site in 0..<HoverboardReaction.arcSites {
            for variant in 0..<HoverboardReaction.arcVariants {
                let bounds = HoverboardReactionFX.arcMeshes[site][variant].bounds
                if site < 4 {
                    #expect(bounds.min.y > -0.04 && bounds.max.y < 0.2, "rim arcs: over the rim, below the knees")
                } else {
                    #expect(bounds.min.y > -0.14 && bounds.max.y < 0.12, "end-cap bolts: from the thrusters up to the rim")
                    #expect(abs(bounds.center.x) > 0.5, "on its end cap")
                }
                #expect(abs(bounds.max.x) < 0.72 && abs(bounds.min.x) < 0.72 && bounds.max.z < 0.36, "never far off the board")
            }
            let spark = RimOutline.sparkSite(site)
            #expect(abs(spark.x) < 0.62 && spark.y > -0.12 && spark.y < 0.05, "sparks leave the board itself")
        }
        let field = HoverboardReactionFX.fieldMesh.bounds
        #expect(field.min.y > 0.01 && field.max.y < 0.1 && field.max.x < 0.585)
        let ring = HoverboardReactionFX.pulseMesh.bounds
        #expect(ring.max.x > 0.58 && ring.max.x < 0.7 && ring.min.y > 0.01 && ring.max.y < 0.06, "a band just outside the rim")
    }

    /// iPad, 23 November 2026: the HIT discharge's translucent glow was built from separate quads that
    /// overlapped at every bend, so the 45 % glow stacked into visible square blocks and the white
    /// core broke into dashes at the sharp bends. Each ribbon is now one joined strip that never
    /// folds back over itself as the game camera sees it.
    @Test("Each discharge ribbon is one joined strip that never overlaps itself")
    func dischargeRibbonsAreJoinedStripsWithoutOverlap() {
        let camera = RimOutline.towardCamera
        for site in 0..<HoverboardReaction.arcSites {
            for variant in 0..<HoverboardReaction.arcVariants {
                for ribbon in RimOutline.arc(site: site, variant: variant) {
                    let positions = ribbon.positions.elements
                    #expect(positions.count == 2 * 15, "one pair of vertices per path point, shared by both segments")
                    // Seen from the camera, every quad of the strip winds the same way: no fold.
                    // Seen from the camera, every quad splits into two triangles winding the same way
                    // (along whichever diagonal the builder picks), and all quads wind alike: no fold.
                    var signs: Set<Bool> = []
                    for k in 0..<(positions.count / 2 - 1) {
                        let l0 = positions[2 * k], r0 = positions[2 * k + 1], l1 = positions[2 * k + 2], r1 = positions[2 * k + 3]
                        func area(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
                            simd_dot(simd_cross(b - a, c - a), camera)
                        }
                        let first = [area(l0, l1, r1), area(l0, r1, r0)], second = [area(l1, r1, r0), area(l1, r0, l0)]
                        let split = (first[0] > 0) == (first[1] > 0) ? first : second
                        #expect((split[0] > 0) == (split[1] > 0), "site \(site) variant \(variant) quad \(k) is a bow-tie")
                        #expect(split.allSatisfy { abs($0) > 1e-9 }, "no degenerate triangle")
                        signs.insert(split[0] > 0)
                    }
                    #expect(signs.count == 1, "site \(site) variant \(variant): the strip folds over itself")
                }
            }
        }
    }

    @Test("The peaks change the board's outline: an expanding ring and a taller field; sparks at the beats")
    func peaksExpandBeyondTheBoard() {
        let clear = HoverboardReaction.clear, hit = HoverboardReaction.hit
        // CLEAR: no ring before the burst; from it, one ring that grows as it fades.
        #expect(clear.pulse(at: HoverboardReaction.meet - 0.01, reduceMotion: false) == nil)
        var lastScale: Float = 0, lastLevel = 9
        for tau in stride(from: HoverboardReaction.meet, to: HoverboardReaction.meet + 0.29, by: 0.01) {
            guard let ring = clear.pulse(at: tau, reduceMotion: false) else { continue }
            #expect(ring.scale >= lastScale && ring.level <= lastLevel)
            lastScale = ring.scale; lastLevel = ring.level
        }
        #expect(lastScale > 1.4, "well beyond the board")
        #expect(clear.fieldScale(at: HoverboardReaction.meet + 0.04, reduceMotion: false) > 2)
        // HIT: a white-hot shock ring on the first frame, then red.
        #expect(hit.pulse(at: 0, reduceMotion: false)?.tone == 3 && hit.pulse(at: 0.06, reduceMotion: false)?.tone == 0)
        #expect(hit.fieldScale(at: 0.02, reduceMotion: false) > 1.8)
        // Sparks: CLEAR's gold fountain at the burst; HIT's red sparks on impact, secondary and sputter.
        #expect(clear.sparkBursts.map(\.time) == [HoverboardReaction.meet])
        #expect(hit.sparkBursts.first?.time == 0 && hit.sparkBursts.first?.sites.count == HoverboardReaction.arcSites)
        #expect(hit.sparkBursts.allSatisfy { $0.time < hit.duration && $0.sites.allSatisfy { $0 < HoverboardReaction.arcSites } })
    }

    @Test("The mascot rides its board's verdict lift: its feet stay planted while the board surges or sags")
    func mascotRidesTheBoardsVerdictLift() async throws {
        let (scene, layer) = try await Self.sceneWithBoards()
        let board = try #require(layer.hoverboards[.player1]), robot = try #require(layer.robots[.player1])
        let partner = try #require(layer.robots[.player2])
        layer.smoothing = 1e-4 // the render loop places the mascots every frame
        layer.render(now: 0)
        let rest = robot.container.position.y, partnerRest = partner.container.position.y
        let tracked = layer.trackedRootPosition(.player1)
        for kind in [HoverboardReaction.clear, .hit] {
            board.react(kind, reduceMotion: false)
            var t = 0.0, largest: Float = 0
            for _ in 0..<Int(kind.duration * 60) + 4 {
                board.step(dt: 1 / 60); t += 1 / 60
                layer.render(now: t)
                #expect(abs(robot.container.position.y - rest - board.reactionLift) < 1e-5, "\(kind) riding the lift")
                #expect(abs(partner.container.position.y - partnerRest) < 1e-6, "the other mascot is untouched")
                largest = max(largest, abs(board.reactionLift))
            }
            #expect(largest > 0.02, "\(kind) visibly moves board and rider")
            #expect(board.reactionLift == 0 && abs(robot.container.position.y - rest) < 1e-6, "\(kind) ends exactly at rest")
        }
        #expect(layer.trackedRootPosition(.player1) == tracked, "contacts read the tracked root, never the ride")
        #expect(scene.players[.player1]?.ride.transform == .identity)
        layer.remove()
    }

    @Test("Each board's own lights answer only its own player's verdict and come back exactly as authored")
    func boardsFollowEachPlayersVerdict() async throws {
        let (scene, layer) = try await Self.sceneWithBoards()
        let p1 = try #require(layer.hoverboards[.player1]), p2 = try #require(layer.hoverboards[.player2])
        func body(_ board: PlayerHoverboard) throws -> ModelEntity {
            try #require(Self.entity(named: "Body", in: board.model) as? ModelEntity)
        }
        func layers(_ board: PlayerHoverboard) throws -> Entity {
            try #require(board.root.children.first { $0.name == "hoverboard.reaction" })
        }
        func ribbon(_ board: PlayerHoverboard) throws -> ModelEntity {
            try #require(layers(board).children.first { $0.name == "hoverboard.rimEnergy" } as? ModelEntity)
        }
        func emission(_ board: PlayerHoverboard) throws -> [SIMD4<Float>] {
            try body(board).model!.materials.map { material in
                guard let pbr = material as? PhysicallyBasedMaterial else { return .zero }
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                pbr.emissiveColor.color.getRed(&r, green: &g, blue: &b, alpha: &a)
                return [Float(r), Float(g), Float(b), pbr.emissiveIntensity]
            }
        }
        let rest = try emission(p1)
        let r1 = try ribbon(p1), r2 = try ribbon(p2)
        #expect(try emission(p2) == rest)
        #expect(!r1.isEnabled && !r2.isEnabled)
        // One player hit while the other clears: each board shows its own outcome, in its own colour.
        scene.presentOutcome(.hit, for: .player1)
        scene.presentOutcome(.clear, for: .player2)
        #expect(p1.activeReaction?.kind == .hit && p2.activeReaction?.kind == .clear)
        let hitLook = try emission(p1), clearLook = try emission(p2)
        #expect(hitLook != rest && clearLook != rest && hitLook != clearLook)
        #expect(r1.isEnabled && r2.isEnabled)
        let arcs1 = try layers(p1).children.filter { $0.name.hasPrefix("hoverboard.discharge") }
        let arcs2 = try layers(p2).children.filter { $0.name.hasPrefix("hoverboard.discharge") }
        let field1 = try #require(try layers(p1).children.first { $0.name == "hoverboard.energyField" })
        // The layers follow the board exactly and never widen the model the steering measures.
        #expect(try layers(p1).transform == p1.model.transform)
        #expect(abs(p1.model.visualBounds(relativeTo: p1.model).extents.x - 1.168) < 0.01)
        #expect(arcs1.count == HoverboardReaction.arcSites && arcs1.allSatisfy(\.isEnabled), "the struck board crackles")
        #expect(!arcs2.contains { $0.isEnabled } && field1.isEnabled, "the cleared board does not")
        let hot = hitLook.max { $0.w < $1.w }!, gold = clearLook.max { $0.w < $1.w }!
        #expect(hot.x > 0.9 && gold.x > 0.9 && gold.z > 0.7, "near-white surge and cream-white ignition")
        for _ in 0..<12 { p1.step(dt: 1 / 60); p2.step(dt: 1 / 60) }
        let hitRim = r1.model!.materials.compactMap { $0 as? PhysicallyBasedMaterial }
        for _ in 0..<18 { p2.step(dt: 1 / 60) } // CLEAR cooling through gold
        let clearRim = r2.model!.materials.compactMap { $0 as? PhysicallyBasedMaterial }
        func hue(_ m: PhysicallyBasedMaterial) -> SIMD3<Float> {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            m.emissiveColor.color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return [Float(r), Float(g), Float(b)]
        }
        #expect(hitRim.contains { hue($0).x > 0.9 && hue($0).y < 0.3 }, "ZAPPED!'s red on the struck board's ring")
        #expect(clearRim.contains { hue($0).x > 0.98 && hue($0).y > 0.45 && hue($0).z < 0.35 }, "PERFECT!'s gold and amber on the other's ring")
        // The board stays whole and on its ride: full opacity, no resize, no sideways move.
        #expect(p1.model.components[OpacityComponent.self] == nil && p1.root.components[OpacityComponent.self] == nil)
        #expect(abs(p1.model.scale.x - PlayerHoverboard.scale) < 1e-6 && p1.model.position.x == p1.motion.offsetX)
        // Cancelling (a new round) restores the authored look at once.
        layer.cancelHitReactions()
        let cancelled = try emission(p1)
        #expect(p1.activeReaction == nil && cancelled == rest && !r1.isEnabled)
        scene.presentOutcome(.unavailable, for: .player1)
        let unavailable = try emission(p1)
        #expect(p1.activeReaction == nil && unavailable == rest, "UNAVAILABLE is neither a success nor a failure")
        // Consecutive verdicts restart the one reaction; a finished one leaves nothing lit.
        layer.celebrateBoard(.player1)
        for _ in 0..<10 { p1.step(dt: 1 / 60) }
        scene.presentOutcome(.hit, for: .player1)
        #expect(p1.activeReaction?.kind == .hit && p1.activeReaction?.age == 0)
        for _ in 0..<60 { p1.step(dt: 1 / 60); p2.step(dt: 1 / 60) }
        #expect(p1.activeReaction == nil && p2.activeReaction == nil)
        let after1 = try emission(p1), after2 = try emission(p2)
        #expect(after1 == rest && after2 == rest)
        #expect(!r1.isEnabled && !r2.isEnabled)
        #expect(!arcs1.contains { $0.isEnabled } && !field1.isEnabled, "nothing left lit or crackling")
        layer.remove()
    }

    @Test("The rim's energy ribbon hugs the real rim: inside the board's outline, at the rim's height, facing out")
    func ribbonFollowsTheRim() throws {
        let bounds = HoverboardReactionFX.ribbonMesh.bounds
        #expect(abs(bounds.max.x - 0.5722) < 0.003 && abs(bounds.min.x + 0.5722) < 0.003, "just inside the 0.58 m half-width")
        #expect(bounds.max.y < 0.0192 && bounds.min.y > 0.003, "on the rim, from its lip to its top")
        #expect(abs(bounds.max.z - 0.2222) < 0.003)
        #expect(HoverboardReactionFX.ribbonMesh.contents.models.map { $0.parts.count }.reduce(0, +) == HoverboardReaction.segments)
    }

    private static func entity(named name: String, in entity: Entity) -> Entity? {
        if entity.name == name, entity is ModelEntity { return entity }
        for child in entity.children { if let found = self.entity(named: name, in: child) { return found } }
        return nil
    }

    private static func firstModel(in entity: Entity) -> ModelComponent? {
        if let model = entity.components[ModelComponent.self] { return model }
        for child in entity.children { if let model = firstModel(in: child) { return model } }
        return nil
    }
}
