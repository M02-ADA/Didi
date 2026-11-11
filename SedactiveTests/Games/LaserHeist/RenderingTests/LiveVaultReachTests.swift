import Foundation
import RealityKit
import Testing
@testable import Sedactive

private enum LaserReplayScriptLayout {
    @MainActor static var layout: PlayerPlaneLayout { try! LaserReplayScript.load().input.configuration.playerPlaneLayout }
}

/// Live vault buttons and reach (11 November 2026, owner request): one larger, higher vertical
/// stack beside the mascot, drawn ON each wrist contact zone through the mascot mapping, and the
/// player's wrists shown as reach cursors through the SAME mapping: a cursor on a button is a
/// wrist in its zone, a cursor off every button is a wrist in no zone. The mascot's sideways
/// shift uses the same scale, so leaning toward the wall carries mascot and cursor together.
/// SYNTHETIC player-plane joints (standing proportions); no camera.
@MainActor
struct LiveVaultReachTests {
    private static func setup() throws -> (PlayerCalibration, PlayerPlaneLayout, Double) {
        let input = try LaserReplayScript.load().input
        let c = try #require(input.configuration.calibrations[.player1])
        let layout = input.configuration.playerPlaneLayout
        return (c, layout, LaserLiveRoundGeometryV1.standingHeight(c, layout: layout))
    }

    /// Standing proportions of a player `h` tall in lane `x` (unmirrored plane: their left is +X),
    /// the LEFT (outer, toward P1's wall) wrist at `wrist`, hips and shoulders shifted by `hipShift`.
    private static func pose(_ c: PlayerCalibration, lane x: Double, h: Double, wrist: (Double, Double)?,
                             hipShift: Double = 0) -> PresentationPoseSample {
        let reference = AvatarReference(calibration: c, layout: LaserReplayScriptLayout.layout)
        let s = 0.82 * h, hip = reference.standingHipY, hx = x + hipShift
        let ankle = (reference.standingLeftAnkleY + reference.standingRightAnkleY) / 2
        var j: [PresentationJoint: (Double, Double)] = [
            .leftShoulder: (hx + 0.13 * h, s), .rightShoulder: (hx - 0.13 * h, s),
            .leftElbow: (hx + 0.15 * h, s - 0.2 * h), .rightElbow: (hx - 0.15 * h, s - 0.2 * h),
            .leftWrist: (hx + 0.16 * h, s - 0.38 * h), .rightWrist: (hx - 0.16 * h, s - 0.38 * h),
            .leftHip: (hx + 0.07 * h, hip), .rightHip: (hx - 0.07 * h, hip),
            .leftAnkle: (x + 0.07 * h, ankle), .rightAnkle: (x - 0.07 * h, ankle),
            .nose: (hx, 0.9 * h),
        ]
        if let wrist {
            let shoulder = j[.leftShoulder]!
            j[.leftWrist] = wrist
            j[.leftElbow] = ((shoulder.0 + wrist.0) / 2, (shoulder.1 + wrist.1) / 2)
        }
        return PresentationPoseSample(playerID: .player1, calibrationRevision: c.revision,
                                      joints: j.mapValues { PresentationPoint(x: $0.0, y: $0.1, confidence: 0.9) })
    }

    private static func sample(_ c: PlayerCalibration, center: Double, h: Double) throws -> PlayerBodySample {
        func v(_ x: Double) throws -> EstimatedScalar { try EstimatedScalar(value: x, validity: .valid) }
        return PlayerBodySample(playerID: .player1, calibrationRevision: c.revision, trackingStatus: .reliable,
            geometry: BodyGeometry(crownY: try v(h), leftWristY: try v(0.5 * h), rightWristY: try v(0.5 * h),
                                   leftSoleY: try v(0), rightSoleY: try v(0), centerX: try v(center)),
            jumpState: JumpState(phase: .grounded, validity: .valid))
    }

    /// Where a zone's button is drawn: the mapping the live presentation uses.
    private static func button(_ scene: LaserScene, layout: PlayerPlaneLayout, h: Double,
                               _ b: LaserVaultButton) -> (center: SIMD2<Float>, radius: Float, plane: (Double, Double)) {
        let share = LaserLiveRoundGeometryV1.vaultShares[b]!
        let lane = layout.centerX(for: .player1)
        let x = lane + LaserLiveRoundGeometryV1.outward(.player1) * share.out * h, y = share.y * h
        let shown = scene.mapping.mascotPoint(x: x, y: y, player: .player1, laneCenter: lane, standingHeight: h)
        return (shown.center, Float(LaserLiveRoundGeometryV1.vaultRadiusShare * h) * shown.scale, (x, y))
    }

    /// Feeds `pose` for 1.5 s and returns the left reach cursor's world X/height, if shown.
    private static func cursor(after pose: PresentationPoseSample, sample: PlayerBodySample, scene: LaserScene,
                               layer: RobotAvatarLayer) throws -> SIMD2<Float>? {
        let generation = UUID()
        layer.showsReachCursors = true
        for frame in 1...45 {
            let t = Double(frame) / 30
            let snapshot = BodySnapshot(sessionGeneration: generation, frameID: UInt64(frame), capturedAt: t,
                                        cameraGeometryRevision: 1, players: [.player1: sample])
            layer.apply(snapshot, joints: PresentationPoseFrame(sessionGeneration: generation, frameID: UInt64(frame),
                                                                capturedAt: t, players: [.player1: pose]))
            layer.render(now: t)
        }
        let lane = try #require(scene.players[.player1]).position
        return layer.reachCursorPosition(.player1, .left).map { [lane.x + $0.x, lane.y + $0.y] }
    }

    private static func layer(_ scene: LaserScene, _ c: PlayerCalibration, _ layout: PlayerPlaneLayout) async throws -> RobotAvatarLayer {
        RobotAvatarLayer(scene: scene, calibrations: [.player1: c], layout: layout,
                         templates: try await RobotAvatarLayer.loadTemplates())
    }

    @Test func zonesAreOneRoomyStackAtBodyRelativeReachingHeights() throws {
        let shares = LaserLiveRoundGeometryV1.vaultShares, r = LaserLiveRoundGeometryV1.vaultRadiusShare
        let top = shares[.top]!, middle = shares[.middle]!, bottom = shares[.bottom]!
        #expect(top.out == middle.out && middle.out == bottom.out, "one vertical stack")
        // HIGH: head level, above the shoulder (0.82 h). MIDDLE: chest. LOW: upper thigh, between
        // the knee (~0.28 h) and the hip (~0.53 h), never waist or knee height.
        #expect(top.y > 0.82 && top.y <= 1, "HIGH at head level")
        #expect(middle.y >= 0.62 && middle.y <= 0.78, "MIDDLE at chest")
        #expect(bottom.y >= 0.4 && bottom.y < 0.53, "LOW at the upper thigh")
        #expect(top.y - middle.y >= 0.25 - 1e-9 && middle.y - bottom.y >= 0.25 - 1e-9 && top.y - middle.y > 2 * r, "roomy, no overlap")
        let shoulder = LaserLiveRoundGeometryV1.humanShoulderShare, arm = LaserLiveRoundGeometryV1.humanArmShare
        // HIGH and MIDDLE: a comfortable reach standing upright (under 85 % of an arm).
        for b in [LaserVaultButton.top, .middle] {
            #expect(hypot(shares[b]!.out - shoulder.out, shares[b]!.y - shoulder.y) <= 0.85 * arm, "\(b) comfortable")
        }
        // LOW: a downward reach with a slight knee bend (0.1 h) and lean (0.05 h), not upright, no squat.
        #expect(hypot(bottom.out - shoulder.out, bottom.y - shoulder.y) > arm, "LOW asks for a bend")
        #expect(hypot(bottom.out - shoulder.out - 0.05, bottom.y - (shoulder.y - 0.1)) <= 0.95 * arm, "reached with a slight bend")
        // A resting hand (0.16 h out, 0.44 h up), even with the hips 0.1 h toward the wall, is in no zone.
        for shift in [0.0, 0.1] {
            for share in shares.values { #expect(hypot(share.out - (0.16 + shift), share.y - 0.44) > r) }
        }
    }

    /// The drawn buttons are larger and higher than the first live layout (13 cm, 0.5–0.75 m):
    /// about 34 cm across, from hip to head height of the 1.6 m mascot, beside it on P1's side.
    @Test func buttonsAreLargeAndBesideTheMascot() throws {
        let (_, layout, h) = try Self.setup()
        let scene = LaserScene()
        let lane = try #require(scene.mapping.laneCenterX[.player1])
        for b in LaserVaultButton.allCases {
            let shown = Self.button(scene, layout: layout, h: h, b)
            // Clear of the mascot's head (about 0.32 m each side) through a clear 0.25 m lean; past
            // that the head passes BEHIND them (they are drawn in front of the mascots).
            #expect(shown.radius > 0.15, "\(b): large")
            #expect(lane - shown.center.x - shown.radius > 0.25 + 0.32, "\(b): clear of the head")
            #expect(VaultPresentation.liveButtonDepthInFront > 0 && RobotAvatarLayer.reachCursorDepth > VaultPresentation.liveButtonDepthInFront,
                    "buttons in front of the mascot, cursors in front of the buttons")
        }
        // Head level and upper-thigh level of the 1.6 m mascot world, well above its board.
        #expect(Self.button(scene, layout: layout, h: h, .top).center.y > 1.45)
        #expect(Self.button(scene, layout: layout, h: h, .bottom).center.y > 0.6)
    }

    /// A wrist in a zone puts its reach cursor on that button.
    @Test(arguments: LaserVaultButton.allCases)
    func aWristInTheZoneShowsTheCursorOnItsButton(_ b: LaserVaultButton) async throws {
        let (c, layout, h) = try Self.setup()
        let scene = LaserScene()
        let layer = try await Self.layer(scene, c, layout)
        let target = Self.button(scene, layout: layout, h: h, b)
        let lane = layout.centerX(for: .player1)
        let shown = try #require(try Self.cursor(after: Self.pose(c, lane: lane, h: h, wrist: target.plane),
                                                 sample: Self.sample(c, center: lane, h: h), scene: scene, layer: layer))
        #expect(simd_distance(shown, target.center) < 0.01, "\(b): cursor \(shown) on button \(target.center)")
    }

    /// A resting hand, or one reaching to the inner (wrong) side, puts its cursor on no button,
    /// and the gameplay zone agrees (the wrist is in no zone).
    @Test func restingOrWrongSideCursorsAreOnNoButton() async throws {
        let (c, layout, h) = try Self.setup()
        let scene = LaserScene()
        let layer = try await Self.layer(scene, c, layout)
        let lane = layout.centerX(for: .player1)
        for wrist in [(lane + 0.16 * h, 0.44 * h), (lane - 0.45 * h, 0.75 * h)] {
            let shown = try #require(try Self.cursor(after: Self.pose(c, lane: lane, h: h, wrist: wrist),
                                                     sample: Self.sample(c, center: lane, h: h), scene: scene, layer: layer))
            for b in LaserVaultButton.allCases {
                let target = Self.button(scene, layout: layout, h: h, b)
                #expect(simd_distance(shown, target.center) > target.radius, "\(b) not shown pressed")
                #expect(hypot(wrist.0 - target.plane.0, wrist.1 - target.plane.1) > LaserLiveRoundGeometryV1.vaultRadiusShare * h)
            }
        }
        // No cursor outside a vault.
        layer.showsReachCursors = false
        #expect(layer.reachCursorPosition(.player1, .left) == nil)
    }

    /// Leaning toward the wall moves the mascot sideways at the same scale as the cursor, so the
    /// cursor stays where the player's wrist is and the bottom (full-reach) button gets easier.
    @Test func leaningTowardTheWallMovesMascotAndCursorTogether() async throws {
        let (c, layout, h) = try Self.setup()
        let scene = LaserScene()
        let layer = try await Self.layer(scene, c, layout)
        let lane = layout.centerX(for: .player1), shift = 0.12 * h
        let target = Self.button(scene, layout: layout, h: h, .bottom)
        let shown = try #require(try Self.cursor(after: Self.pose(c, lane: lane, h: h, wrist: target.plane, hipShift: shift),
                                                 sample: Self.sample(c, center: lane + shift, h: h), scene: scene, layer: layer))
        #expect(simd_distance(shown, target.center) < 0.01, "the cursor is the wrist, wherever the body is")
        let root = try #require(layer.robots[.player1]).container.position.x
        let expected = Float(shift) * RobotAvatarLayer.standingHeight / Float(h)
        #expect(abs(-root - expected) < 0.02, "the mascot moved \(-root) m toward its wall (expected \(expected))")
    }
}
