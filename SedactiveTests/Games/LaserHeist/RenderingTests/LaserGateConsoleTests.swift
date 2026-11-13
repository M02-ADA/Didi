import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// Owner Option A (12 November 2026): each player's vault buttons on a console mounted on their
/// corridor wall; the mascot steers to its dock, stops clear of it, and its own fist lands on the
/// button the player's real wrist is judged in. Geometry from the real mascot rig and mesh, the
/// real scene and camera; hand positions from the real retargeter and solver. SYNTHETIC poses.
@MainActor
struct LaserGateConsoleTests {
    private static func layer(_ players: Set<PlayerID>) async throws -> (LaserScene, RobotAvatarLayer) {
        _ = await PlayerHoverboard.sharedTemplate()
        let input = try LaserReplayScript.load().input
        let scene = LaserScene()
        let calibrations = input.configuration.calibrations.filter { players.contains($0.key) }
        let layer = RobotAvatarLayer(scene: scene, calibrations: calibrations, layout: input.configuration.playerPlaneLayout,
                                     templates: try await RobotAvatarLayer.sharedTemplates())
        scene.robotAvatars = layer
        return (scene, layer)
    }

    /// Bind-pose mesh vertices of the body without its arms (not skinned mostly to an arm joint).
    private static func bodyVertices(_ robot: RobotAvatarLayer.Robot) -> [SIMD3<Float>] {
        let names = robot.model.jointNames, s = RobotAvatarLayer.modelScale
        let arm = ["UpperArm", "Forearm", "Hand"]
        var out: [SIMD3<Float>] = []
        for model in robot.model.model?.mesh.contents.models ?? [] {
            for part in model.parts {
                let positions = Array(part.positions)
                let all = part.jointInfluences.map { Array($0.influences) } ?? []
                let n = max(1, all.count / max(1, positions.count))
                for (v, p) in positions.enumerated() {
                    if v * n + n <= all.count, let best = all[(v * n)..<(v * n + n)].max(by: { $0.weight < $1.weight }),
                       Int(best.jointIndex) < names.count, arm.contains(where: { names[Int(best.jointIndex)].contains($0) }) { continue }
                    out.append(p * s)
                }
            }
        }
        return out
    }

    @Test func eachConsoleIsMountedOnItsWallOnScreenAtTheMascotsReachHeights() async throws {
        let (scene, layer) = try await Self.layer(Set(PlayerID.allCases))
        let arm = try #require(layer.arm)
        print(String(format: "CONSOLE arm: shoulder (%.3f, %.3f) m, reach to the fist %.3f m", arm.shoulder.x, arm.shoulder.y, arm.length))
        for player in PlayerID.allCases {
            let c = try #require(layer.consoles[player])
            let side: Float = player == .player1 ? -1 : 1
            #expect(c.side == side)
            // Anchored: the main block reaches the corridor wall; the face is inside the camera's view.
            let main = c.blocks[0]
            #expect(abs(abs(main.center.x + side * main.size.x / 2) - scene.layout.corridorWidth / 2) < 1e-4, "\(player): on the wall")
            let screen = try #require(scene.screenFraction(of: [c.faceX, 0.6, 0], aspect: 4 / 3))
            #expect(player == .player1 ? (screen > 0.02 && screen < 0.2) : (screen > 0.8 && screen < 0.98), "\(player): face on screen at \(screen)")
            // HIGH just under the head, MIDDLE at the chest, LOW at the hips; one column, no gaps closed.
            let high = try #require(c.buttons[.top]), mid = try #require(c.buttons[.middle]), low = try #require(c.buttons[.bottom])
            #expect(high.center.y > 0.78 && high.center.y < 0.9 && mid.center.y > 0.55 && mid.center.y < 0.7 && low.center.y > 0.38 && low.center.y < 0.5)
            // One unified column: one face, one size, even spacing with clear gaps, all facing inward.
            for b in [high, mid, low] {
                #expect(b.center.x == c.faceX && b.radius == high.radius, "one face, one size")
                #expect(b.normal == SIMD3(-side, 0, 0), "faces into the corridor (no tilted pad)")
                // The column leans toward the camera: LOW in the players' plane, HIGH `lean` in front.
                let lean = (b.center.y - low.center.y) / (high.center.y - low.center.y) * LaserGateConsole.lean
                #expect(abs(b.center.z - scene.mapping.interactionPlaneZ - lean) < 1e-4)
                // Within the mascot's reach from its dock (to the cap's front).
                let shoulder = SIMD3(c.dockX + side * arm.shoulder.x, arm.shoulder.y, 0) // the console-side shoulder
                #expect(simd_distance(b.contact, shoulder) <= arm.length, "\(player): reachable, \(simd_distance(b.contact, shoulder)) of \(arm.length) m")
            }
            let gapHigh = high.center.y - mid.center.y, gapLow = mid.center.y - low.center.y
            #expect(abs(gapHigh - gapLow) < 0.005, "evenly spaced: \(gapHigh) / \(gapLow)")
            let ring = high.radius + LaserGateConsole.bezel
            #expect(gapLow - 2 * ring > 0.0, "bezels never touch")
            #expect(high.radius > 0.085, "large buttons: \(high.radius) m")
            _ = main
            print(String(format: "CONSOLE %@ dock %+.3f face %+.3f wall %+.3f · HIGH (%+.3f, %.3f) r %.3f · MIDDLE (%+.3f, %.3f) r %.3f · LOW (%+.3f, %.3f) r %.3f · screen %.3f",
                         player.rawValue, c.dockX, c.faceX, c.wallX, high.center.x, high.center.y, high.radius,
                         mid.center.x, mid.center.y, mid.radius, low.center.x, low.center.y, low.radius, screen))
        }
        layer.remove()
    }

    /// At its dock nothing of the mascot or its board is inside its console: the body (arms
    /// excluded: they reach) stays clear at every console height, the board rides below it.
    @Test func atTheDockTheBodyHeadAndBoardStayClearOfTheConsole() async throws {
        let (scene, layer) = try await Self.layer(Set(PlayerID.allCases))
        let robot = try #require(layer.robots[.player1]), steering = try #require(layer.steering)
        let body = Self.bodyVertices(robot)
        #expect(body.count > 1000)
        for player in PlayerID.allCases {
            let c = try #require(layer.consoles[player])
            #expect(player == .player1 ? steering.bounds.lowerBound == c.dockX : steering.bounds.upperBound == c.dockX, "the steering stops at the dock")
            var closest = Float.infinity
            let dock = abs(c.dockX)
            // Each cap's front against the body where the cap is (height and depth).
            for (key, b) in c.buttons {
                var worst = Float.infinity, at = SIMD3<Float>()
                for v in body where abs(v.y - b.center.y) <= b.radius && abs(v.z - b.center.z) <= b.radius {
                    let gap = abs(b.contact.x) - (dock + abs(v.x))
                    if gap < worst { worst = gap; at = v }
                }
                print(String(format: "CLEAR %@ %@ cap gap %.3f at body (%.3f, %.3f, %.3f)", player.rawValue, key.rawValue, worst, at.x, at.y, at.z))
                closest = min(closest, worst)
            }
            // The plate (housing face, leaning with the column) against the body where the housing is.
            let h = c.housing, unlean = simd_quatf(angle: -h.tilt, axis: [1, 0, 0])
            var plateGap = Float.infinity
            for v in body {
                let local = unlean.act(SIMD3(0, v.y, v.z) - SIMD3(0, h.center.y, h.center.z))
                guard abs(local.y) <= h.size.y / 2, abs(local.z) <= h.size.z / 2 else { continue }
                plateGap = min(plateGap, abs(c.faceX) - (dock + abs(v.x)))
            }
            print(String(format: "CLEAR %@ plate gap %.3f", player.rawValue, plateGap))
            closest = min(closest, plateGap)
            let lowY = c.blocks[0].center.y - c.blocks[0].size.y / 2
            #expect(lowY > 0.05, "\(player): board clear under the console (housing bottom \(lowY))")
            print(String(format: "CONSOLE %@ closest body-to-console gap at the dock %.3f m", player.rawValue, closest))
            #expect(closest > 0.02, "\(player): head and body clear by \(closest) m")
            let screenEdge = LateralSteering.visibleHalfWidth(depth: scene.layout.cameraPosition.z, verticalFieldOfViewDegrees: scene.layout.cameraVerticalFieldOfView,
                                                              aspect: RobotAvatarLayer.narrowestDisplayAspect)
            #expect(abs(c.dockX) + steering.halfWidth < screenEdge, "\(player): the docked board is on screen")
        }
        layer.remove()
    }

    // MARK: Hand and judge, after steering to the dock

    private static func frame(_ layer: RobotAvatarLayer, _ generation: UUID, _ n: Int, _ joints: [PlayerID: [PresentationJoint: PresentationPoint]],
                              _ calibrations: [PlayerID: PlayerCalibration], centers: [PlayerID: Double]) throws {
        let t = Double(n) / 30
        func v(_ x: Double) throws -> EstimatedScalar { try EstimatedScalar(value: x, validity: .valid) }
        var players: [PlayerID: PlayerBodySample] = [:], poses: [PlayerID: PresentationPoseSample] = [:]
        for (player, j) in joints {
            let c = calibrations[player]!
            players[player] = PlayerBodySample(playerID: player, calibrationRevision: c.revision, trackingStatus: .reliable,
                geometry: BodyGeometry(crownY: try v(1.7), leftWristY: try v(1), rightWristY: try v(1), leftSoleY: try v(0),
                                       rightSoleY: try v(0), centerX: try v(centers[player]!)),
                jumpState: JumpState(phase: .grounded, validity: .valid))
            poses[player] = PresentationPoseSample(playerID: player, calibrationRevision: c.revision, joints: j)
        }
        layer.apply(BodySnapshot(sessionGeneration: generation, frameID: UInt64(n), capturedAt: t, cameraGeometryRevision: 1, players: players),
                    joints: PresentationPoseFrame(sessionGeneration: generation, frameID: UInt64(n), capturedAt: t, players: poses))
    }

    /// A real human arm (`LaserLiveRoundGeometryV1.humanWristReachShare`, shoulder→wrist 0.332 h),
    /// split upper 0.186 h / fore 0.146 h, so its segments keep their lengths.
    private static let upper = 0.186, fore = 0.146 // a real arm: shoulder→wrist 0.332 h

    /// A standing player (unmirrored plane), leaning `lean` (share of height; + their own left), the
    /// OUTER arm straight toward `toward` (a zone centre; nil: both arms hanging) or, with `bent`,
    /// its wrist exactly at `toward` with the elbow bent.
    private static func pose(_ r: AvatarReference, outward: Double, lean: Double = 0, toward: SIMD2<Double>? = nil,
                             bent: Bool = false) -> [PresentationJoint: PresentationPoint] {
        let h = r.standingHeight, L = r.laneCenterX, hipY = r.standingHipY
        func p(_ v: SIMD2<Double>) -> PresentationPoint { PresentationPoint(x: L + v.x, y: v.y, confidence: 0.9) }
        let s = lean * h, head = s * (0.9 * h - hipY) / (0.82 * h - hipY)
        let outerShoulder = SIMD2(s + outward * 0.13 * h, 0.82 * h), innerShoulder = SIMD2(s - outward * 0.13 * h, 0.82 * h)
        let down = SIMD2(0.0, -1.0), out = SIMD2(outward, 0.0)
        func hanging(_ sh: SIMD2<Double>, _ side: Double) -> (SIMD2<Double>, SIMD2<Double>) {
            let dir = simd_normalize(down + 0.08 * SIMD2(side, 0))
            return (sh + dir * upper * h, sh + dir * (upper + fore) * h)
        }
        var outerArm = hanging(outerShoulder, outward)
        if let toward {
            let v = toward - outerShoulder, d = simd_length(v), dir = v / d
            if bent, d < (upper + fore) * h {
                // Two-link arm with the wrist on the target, elbow bent down-and-out.
                let a = upper * h, b = fore * h
                let cosA = (a * a + d * d - b * b) / (2 * a * d), angle = acos(max(-1, min(1, cosA)))
                let turn = -outward * angle // bend toward the floor
                let elbowDir = SIMD2(dir.x * cos(turn) - dir.y * sin(turn), dir.x * sin(turn) + dir.y * cos(turn))
                outerArm = (outerShoulder + elbowDir * a, toward)
            } else {
                outerArm = (outerShoulder + dir * upper * h, outerShoulder + dir * (upper + fore) * h)
            }
        }
        _ = out
        let innerArm = hanging(innerShoulder, -outward)
        let (oe, ow, ie, iw): (PresentationJoint, PresentationJoint, PresentationJoint, PresentationJoint) = outward > 0
            ? (.leftElbow, .leftWrist, .rightElbow, .rightWrist) : (.rightElbow, .rightWrist, .leftElbow, .leftWrist)
        return [
            .leftShoulder: p(SIMD2(s + 0.13 * h, 0.82 * h)), .rightShoulder: p(SIMD2(s - 0.13 * h, 0.82 * h)),
            .leftHip: p(SIMD2(0.07 * h, hipY)), .rightHip: p(SIMD2(-0.07 * h, hipY)), .nose: p(SIMD2(head, 0.9 * h)),
            oe: p(outerArm.0), ow: p(outerArm.1), ie: p(innerArm.0), iw: p(innerArm.1)]
    }

    /// The fist's tip in world space: the hand joint plus the measured fist length along the forearm.
    private static func fistTips(_ robot: RobotAvatarLayer.Robot, tip: Float) -> [SIMD3<Float>] {
        let sk = robot.solver.skeleton
        let world = sk.world(robot.model.jointTransforms).position
        return [("Hand_L", "Forearm_L"), ("Hand_R", "Forearm_R")].compactMap { hand, fore in
            guard let h = sk(hand), let f = sk(fore) else { return nil }
            let a = robot.model.convert(position: world[f], to: nil), b = robot.model.convert(position: world[h], to: nil)
            return b + simd_normalize(b - a) * tip
        }
    }

    @Test(arguments: PlayerID.allCases)
    func afterLeaningToTheDockTheMascotsFistLandsOnTheButtonTheWristIsJudgedIn(_ player: PlayerID) async throws {
        let (scene, layer) = try await Self.layer([player])
        layer.consolesActive = true // a live gate shows the consoles (and the dock assist runs)
        let input = try LaserReplayScript.load().input
        let calibrations = input.configuration.calibrations
        let r = AvatarReference(calibration: calibrations[player]!, layout: input.configuration.playerPlaneLayout)
        let outward = LaserLiveRoundGeometryV1.outward(player), h = r.standingHeight
        let c = try #require(layer.consoles[player]), arm = try #require(layer.arm)
        let generation = UUID()
        var n = 0
        func send(_ j: [PresentationJoint: PresentationPoint], frames: Int) throws {
            for _ in 0..<frames { n += 1; try Self.frame(layer, generation, n, [player: j], calibrations, centers: [player: r.laneCenterX]) }
        }
        // 1–4: lean toward the own wall (the player's own outer side), the board travels and stops at the dock.
        try send(Self.pose(r, outward: outward, lean: outward * 0.09), frames: 120)
        _ = h
        try send(Self.pose(r, outward: outward), frames: 20) // upright again: it stays
        let docked = try #require(layer.steeringReading(player))
        print(String(format: "DOCK %@ board x %+.3f (dock %+.3f) · %@", player.rawValue, docked.targetX, c.dockX, docked.constraint.rawValue))
        #expect(abs(docked.targetX - c.dockX) < 0.01, "\(player): stopped at the dock")
        let shiftDocked = try #require(layer.vaultReachShift(player, capturedAt: Double(n) / 30))
        #expect(abs(shiftDocked) < 0.02, "the judge's zones need no extra reach at the dock: \(shiftDocked)")
        // 6–8: a straight outer arm into each approved zone: the fist lands on that button.
        let robot = try #require(layer.robots[player])
        _ = arm
        for (button, share) in LaserLiveRoundGeometryV1.vaultShares {
            let zone = SIMD2(outward * share.out * h, share.y * h)
            // The natural press: a straight arm toward the button, wrist inside its zone.
            let lean = 0.0
            let straight = Self.pose(r, outward: outward, lean: lean, toward: zone)
            let wristJoint: PresentationJoint = outward > 0 ? .leftWrist : .rightWrist
            let w = try #require(straight[wristJoint])
            #expect(hypot(w.x - r.laneCenterX - zone.x, w.y - zone.y) <= LaserLiveRoundGeometryV1.vaultRadiusShare * h + 1e-9,
                    "\(player) \(button): the straight-arm wrist is inside the judged zone")
            try send(straight, frames: 20)
            let b = try #require(c.buttons[button])
            let fists = Self.fistTips(robot, tip: RobotAvatarLayer.handTipLength ?? 0.076)
            let fist = try #require(fists.min { simd_distance($0, b.center) < simd_distance($1, b.center) })
            // On the cap's face (yz) and at its front surface (x): touching, not through.
            let capFront = abs(c.faceX) - LaserGateConsole.pressSurface
            let offAxis = simd_length(SIMD2(fist.y - b.center.y, fist.z - b.center.z))
            let gap = capFront - abs(fist.x)
            print(String(format: "REACH %@ %@: fist (%+.3f, %.3f, %+.3f) button (%+.3f, %.3f) off its axis %.3f m (radius %.3f) · %.3f m from its front",
                         player.rawValue, button.rawValue, fist.x, fist.y, fist.z, b.center.x, b.center.y, offAxis, b.radius, gap))
            #expect(offAxis < b.radius, "\(player) \(button): the fist is on its button")
            #expect(gap > -0.01 && gap < 0.04, "\(player) \(button): the fist touches its front, never passes it (\(gap))")
            // The other buttons are not under the fist.
            for (other, ob) in c.buttons where other != button {
                #expect(simd_length(SIMD2(fist.y - ob.center.y, fist.z - ob.center.z)) > ob.radius, "\(player) \(button): not on \(other)")
            }
            // A bent arm with the wrist on the zone's centre: still a press; the fist is over the
            // button, short of its face by the bend (reported).
            try send(Self.pose(r, outward: outward, lean: lean, toward: zone, bent: true), frames: 20)
            if let bentFist = Self.fistTips(robot, tip: RobotAvatarLayer.handTipLength ?? 0.076)
                .min(by: { simd_distance($0, b.center) < simd_distance($1, b.center) }) {
                print(String(format: "REACH %@ %@ bent: fist (%+.3f, %.3f, %+.3f) · %.3f m short of its front · %.3f m off the button's axis",
                             player.rawValue, button.rawValue, bentFist.x, bentFist.y, bentFist.z,
                             abs(c.faceX) - LaserGateConsole.pressSurface - abs(bentFist.x),
                             simd_length(SIMD2(bentFist.y - b.center.y, bentFist.z - b.center.z))))
            }
        }
        // Lean alone (no reach) at the dock: no fist on any button.
        try send(Self.pose(r, outward: outward, lean: outward * 0.09), frames: 20)
        let fists = Self.fistTips(robot, tip: 0.076)
        for b in c.buttons.values {
            #expect(fists.allSatisfy { abs(c.faceX) - LaserGateConsole.pressSurface - abs($0.x) > 0.05 || simd_length(SIMD2($0.y - b.center.y, $0.z - b.center.z)) > b.radius },
                    "a lean alone puts no fist on a button")
        }
        layer.remove()
        withExtendedLifetime(scene) {} // the lanes (the mascots' parents) live with the scene
    }

    /// Away from the dock the judge wants the wrist that much further out: a wrist in the
    /// approved zone presses nothing while the mascot's hand is in mid-air.
    @Test func awayFromTheDockTheJudgedZoneMovesOutByTheMascotsDistance() async throws {
        let (scene, layer) = try await Self.layer([.player1])
        let input = try LaserReplayScript.load().input
        let calibrations = input.configuration.calibrations
        let r = AvatarReference(calibration: calibrations[.player1]!, layout: input.configuration.playerPlaneLayout)
        let c = try #require(layer.consoles[.player1])
        for n in 1...10 { try Self.frame(layer, UUID(), n, [.player1: Self.pose(r, outward: 1)], calibrations, centers: [.player1: r.laneCenterX]) }
        let shift = try #require(layer.vaultReachShift(.player1, capturedAt: 10.0 / 30))
        let k = try #require(layer.robots[.player1]).retargeter.motionScale
        let lane = try #require(layer.steering?.riders[.player1]).laneX
        #expect(abs(shift - Double((lane - c.dockX) / k)) < 0.02, "at the lane: \(shift)")
        #expect(shift > 0.9, "far beyond any arm: \(shift) game units")
        layer.remove()
        withExtendedLifetime(scene) {}
    }

    /// Dock assist (iPad P0): with the gate's consoles shown, a mascot that stopped short of its dock
    /// (within `dockCapture`) glides onto it; leaning away releases it; without consoles nothing moves.
    @Test func aMascotStoppedShortGlidesOntoItsDockWhileTheConsolesShow() async throws {
        let (scene, layer) = try await Self.layer([.player1])
        let input = try LaserReplayScript.load().input
        let calibrations = input.configuration.calibrations
        let r = AvatarReference(calibration: calibrations[.player1]!, layout: input.configuration.playerPlaneLayout)
        let c = try #require(layer.consoles[.player1])
        let generation = UUID()
        var n = 0
        func send(_ lean: Double, _ frames: Int) throws {
            for _ in 0..<frames { n += 1; try Self.frame(layer, generation, n, [.player1: Self.pose(r, outward: 1, lean: lean)], calibrations,
                                                         centers: [.player1: r.laneCenterX]) }
        }
        // Lean toward the wall until about 0.35 m from the dock, then upright: it brakes short of it.
        for _ in 0..<120 where (layer.steering?.boardX(.player1) ?? 0) > c.dockX + 0.35 { try send(0.07, 1) }
        try send(0, 30)
        let short = try #require(layer.steering?.boardX(.player1))
        #expect(short > c.dockX + 0.05, "stopped short: \(short) vs dock \(c.dockX)")
        try send(0, 30)
        #expect(layer.steering?.boardX(.player1) == short, "no gate near: it stays where it stopped")
        layer.docksActive = true // a gate is near (or open): the dock assist runs
        #expect(short - c.dockX < RobotAvatarLayer.dockCapture, "within the capture distance")
        do {
            try send(0, 30)
            let docked = try #require(layer.steering?.boardX(.player1))
            print(String(format: "DOCK ASSIST from %+.3f to %+.3f (dock %+.3f)", short, docked, c.dockX))
            #expect(abs(docked - c.dockX) < 0.005, "glided onto the dock")
            #expect(abs(try #require(layer.vaultReachShift(.player1, capturedAt: Double(n) / 30))) < 0.01)
            // Leaning away releases it.
            try send(-0.09, 20)
            #expect((layer.steering?.boardX(.player1) ?? 0) > c.dockX + 0.1, "leaning away leaves the dock")
        }
        layer.remove()
        withExtendedLifetime(scene) {}
    }
}
