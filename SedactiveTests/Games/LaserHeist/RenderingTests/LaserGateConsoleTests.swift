import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// Owner (20 November 2026): each player's gate button on its side of the gate's door frame, on a compact
/// collar; the mascot leans to its dock, glides (presentation only) a short way sideways to the button's
/// station, and its own fist lands on the button the player's real wrist is judged in. Geometry from the real mascot rig and mesh, the
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

    @Test func eachButtonIsOnItsSideOfTheGateFrameInViewWithinASidewaysReach() async throws {
        let (scene, layer) = try await Self.layer(Set(PlayerID.allCases))
        let arm = try #require(layer.arm)
        print(String(format: "CONSOLE arm: shoulder (%.3f, %.3f) m, reach to the fist %.3f m", arm.shoulder.x, arm.shoulder.y, arm.length))
        let planeZ = scene.mapping.interactionPlaneZ
        for player in PlayerID.allCases {
            let c = try #require(layer.consoles[player])
            let side: Float = player == .player1 ? -1 : 1
            #expect(c.side == side)
            #expect(c.buttons.count == 1 && c.buttons.keys.first == .activate, "one button, no other targets")
            let b = c.button
            // On the gate's door frame (its stop `doorDepth` behind the players), on a compact collar,
            // facing the camera, level.
            #expect(abs(c.doorZ - (planeZ - LaserGateConsole.doorDepth)) < 1e-6)
            #expect(simd_distance(b.center, [side * LaserGateConsole.frameX, LaserGateConsole.buttonHeight,
                                             c.doorZ + LaserGateConsole.standoff + LaserGateConsole.plateDepth]) < 1e-6)
            #expect(b.normal == [0, 0, 1] && b.up == [0, 1, 0], "\(player): faces the camera, level")
            #expect(simd_distance(b.contact, b.center + b.normal * LaserGateConsole.capFront) < 1e-6, "\(player): touched on the cap's front")
            #expect(simd_distance(c.head.center, b.center) < 1e-6 && simd_distance(c.head.orientation.act([0, 0, 1]), b.normal) < 1e-5)
            #expect(b.radius == LaserGateConsole.radius && b.radius / 0.086 > 1.7, "large button: a \(2 * b.radius) m cap")
            // The access module: its panel wholly on the jamb's lavender band (the authored frame art,
            // 2.41–2.67 m; the door's panels slide behind it), flush on the door; its neck (the collar) from
            // the panel to the plate's back, under the plate's outline. Together exactly the standoff deep.
            let collar = c.blocks[1], panel = c.blocks[2]
            let inner = abs(panel.center.x) - panel.size.x / 2, outer = abs(panel.center.x) + panel.size.x / 2
            #expect(inner >= 2.41 && outer <= 2.67 && LaserGateConsole.jamb.contains(inner) && LaserGateConsole.jamb.contains(outer),
                    "\(player): panel on the jamb's band \(inner)…\(outer)")
            #expect(abs(panel.center.z - panel.size.z / 2 - c.doorZ) < 1e-5 && panel.size.z == LaserGateConsole.panelDepth, "\(player): flush on the door")
            #expect(abs(collar.center.z - collar.size.z / 2 - (c.doorZ + LaserGateConsole.panelDepth)) < 1e-5
                    && abs(collar.center.z + collar.size.z / 2 - (b.center.z - LaserGateConsole.plateDepth)) < 1e-5, "\(player): the neck spans panel to plate")
            #expect(abs(abs(b.center.x) - abs(collar.center.x)) + collar.size.x / 2 <= LaserGateConsole.plateHalf + 1e-5
                    && collar.size.y / 2 <= LaserGateConsole.plateHalf, "\(player): the neck under the plate")
            #expect(abs(collar.center.x) - collar.size.x / 2 >= inner - 1e-5 && abs(collar.center.x) + collar.size.x / 2 <= outer + 1e-5,
                    "\(player): the neck stands on the panel")
            // The whole plate in view on the narrowest (4:3) display and on the iPad (2420×1668).
            for aspect: Float in [4 / 3, 2420.0 / 1668.0] {
                for dx: Float in [-1, 1] {
                    for dy: Float in [-1, 1] {
                        let f = try #require(scene.screenFraction(of: b.center + SIMD3<Float>(dx, dy, 0) * LaserGateConsole.plateHalf, aspect: aspect))
                        #expect(f > 0.005 && f < 0.995, "\(player): plate corner on screen at \(f) (aspect \(aspect))")
                    }
                }
            }
            // The station: on the players' plane (the mascot's normal size), a short glide out from the
            // dock; its arm opened sideways, `armReach` of its length, ends on the cap's front.
            #expect(c.station.y == 0 && c.station.z == planeZ, "\(player): at the players' depth")
            let shoulder = SIMD3(c.station.x + side * arm.shoulder.x, arm.shoulder.y, c.station.z)
            let toFist = b.contact - shoulder
            #expect(abs(simd_length(toFist) - LaserGateConsole.armReach * arm.length) < 1e-4, "\(player): within the arm, nearly straight")
            #expect(toFist.x * side > 0.85 * simd_length(toFist), "\(player): mostly sideways (\(toFist))")
            let glide = (c.station.x - c.dockX) * side
            #expect(glide > 0 && glide < 0.3, "\(player): a short glide out from the dock (\(glide) m)")
            // The dock (where the lean stops) is unchanged: the wall stop.
            #expect(abs(abs(c.dockX) - (abs(c.faceX) - LaserGateConsole.faceShare * arm.length - arm.shoulder.x - LaserGateConsole.pressSurface)) < 1e-5)
            #expect(c.dockX == c.wallStopX)
            print(String(format: "BUTTON %@ centre (%+.3f, %.3f, %+.3f) r %.3f · door %+.3f · collar %.3f…%.3f · dock %+.3f · station %+.3f (glide %.3f) · arm %.0f%% sideways %.3f m",
                         player.rawValue, b.center.x, b.center.y, b.center.z, b.radius, c.doorZ, inner, outer, c.dockX, c.station.x, glide,
                         simd_length(toFist) / arm.length * 100, toFist.x * side))
        }
        layer.remove()
    }

    /// At its station nothing of the mascot or its board is inside the button, its collar or the door;
    /// the cap is mostly in view beside the mascot, the board on screen; and when the opened door later
    /// rides past the docked mascot, the button misses it.
    @Test func atTheStationTheBodyAndBoardStayClearOfTheButtonAndTheDoor() async throws {
        let (scene, layer) = try await Self.layer(Set(PlayerID.allCases))
        let robot = try #require(layer.robots[.player1]), steering = try #require(layer.steering)
        let body = Self.bodyVertices(robot)
        #expect(body.count > 1000)
        for player in PlayerID.allCases {
            let c = try #require(layer.consoles[player])
            #expect(player == .player1 ? steering.bounds.lowerBound == c.wallStopX : steering.bounds.upperBound == c.wallStopX,
                    "the steering stops at the wall stop")
            let b = c.button, s = c.station
            func at(_ v: SIMD3<Float>, _ x: Float) -> SIMD3<Float> { SIMD3(x + v.x, v.y, s.z + v.z) }
            // Distance from a point to the button (plate and collar boxes, the cap's cylinder).
            func gap(_ p: SIMD3<Float>, sweep: Bool = false) -> Float {
                var best = Float.infinity
                for box in c.blocks {
                    var d = simd_abs(p - box.center) - box.size / 2
                    if sweep { d.z = -1 } // the door riding past along the corridor: x and y only
                    let outside = simd_length(simd_max(d, .zero))
                    best = min(best, outside > 0 ? outside : max(d.x, d.y, d.z))
                }
                let r = hypot(p.x - b.center.x, p.y - b.center.y) - b.radius
                let dz = sweep ? -1 : max(p.z - b.contact.z, b.center.z - p.z)
                best = min(best, r > 0 && dz > 0 ? hypot(r, dz) : max(r, dz))
                return best
            }
            let buttonGap = body.map { gap(at($0, s.x)) }.min() ?? 0
            let doorGap = body.map { c.doorClearance(at($0, s.x)) }.min() ?? 0
            print(String(format: "CLEAR %@ at the station: button %.3f m, door %.3f m", player.rawValue, buttonGap, doorGap))
            #expect(buttonGap > 0.02 && doorGap > 0.02, "\(player): the body clears the button (\(buttonGap)) and the door (\(doorGap))")
            // The opened door rides past the mascot back at its dock (travel waits for the panels).
            let passGap = body.map { gap(at($0, c.dockX), sweep: true) }.min() ?? 0
            let boardTop: Float = 0.05
            print(String(format: "CLEAR %@ door passing the docked mascot: %.3f m · board top %.2f under the plate's bottom %.2f", player.rawValue,
                         passGap, boardTop, b.center.y - LaserGateConsole.plateHalf))
            #expect(passGap > 0.02 && b.center.y - LaserGateConsole.plateHalf > boardTop + 0.2, "\(player): the passing button misses the docked mascot")
            // The board at the station on screen (iPad and 4:3).
            for aspect: Float in [4 / 3, 2420.0 / 1668.0] {
                let edge = try #require(scene.screenFraction(of: [s.x + c.side * steering.halfWidth, -0.1, s.z], aspect: aspect))
                #expect(edge > 0 && edge < 1, "\(player): the board at the station on screen (\(edge), aspect \(aspect))")
            }
            // On screen (the iPad's frame): how much of the cap's width the body at the station hides.
            let aspect: Float = 2420.0 / 1668.0
            var capInner = player == .player1 ? -Float.infinity : Float.infinity, capOuter = player == .player1 ? Float.infinity : -Float.infinity
            for k in 0..<64 {
                let t = Float(k) / 64 * 2 * .pi
                if let f = scene.screenFraction(of: b.center + SIMD3(cos(t), sin(t), 0) * LaserGateConsole.radius, aspect: aspect) {
                    capInner = player == .player1 ? max(capInner, f) : min(capInner, f)
                    capOuter = player == .player1 ? min(capOuter, f) : max(capOuter, f)
                }
            }
            var bodyOuter = player == .player1 ? Float.infinity : -Float.infinity
            for v in body where abs(v.y - b.center.y) <= LaserGateConsole.radius {
                if let f = scene.screenFraction(of: at(v, s.x), aspect: aspect) { bodyOuter = player == .player1 ? min(bodyOuter, f) : max(bodyOuter, f) }
            }
            let covered = max(0, (player == .player1 ? capInner - bodyOuter : bodyOuter - capInner) / abs(capInner - capOuter))
            print(String(format: "SCREEN %@ the body at the station hides %.0f%% of the cap's width", player.rawValue, covered * 100))
            #expect(covered < 0.2, "\(player): the cap stays mostly in view beside the mascot (\(covered))")
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
    func afterLeaningToTheDockTheMascotGlidesToItsButtonAndItsFistLandsOnIt(_ player: PlayerID) async throws {
        let (scene, layer) = try await Self.layer([player])
        layer.consolesActive = true // a live gate shows the buttons
        layer.docksActive = true // and its dock assist and stop run
        let input = try LaserReplayScript.load().input
        let calibrations = input.configuration.calibrations
        let r = AvatarReference(calibration: calibrations[player]!, layout: input.configuration.playerPlaneLayout)
        let outward = LaserLiveRoundGeometryV1.outward(player), h = r.standingHeight
        let c = try #require(layer.consoles[player])
        let generation = UUID()
        var n = 0
        func send(_ j: [PresentationJoint: PresentationPoint], frames: Int) throws {
            for _ in 0..<frames { n += 1; try Self.frame(layer, generation, n, [player: j], calibrations, centers: [player: r.laneCenterX]) }
        }
        // Lean toward the own wall (the player's own outer side): the board travels and stops at the dock.
        try send(Self.pose(r, outward: outward, lean: outward * 0.09), frames: 120)
        try send(Self.pose(r, outward: outward), frames: 20) // upright again: it stays
        let docked = try #require(layer.steeringReading(player))
        print(String(format: "DOCK %@ board x %+.3f (dock %+.3f) · %@", player.rawValue, docked.targetX, c.dockX, docked.constraint.rawValue))
        #expect(abs(docked.targetX - c.dockX) < 0.01, "\(player): stopped at the dock")
        let shiftDocked = try #require(layer.vaultReachShift(player, capturedAt: Double(n) / 30))
        #expect(abs(shiftDocked) < 0.02, "the judge's zones need no extra reach at the dock: \(shiftDocked)")
        // Docked with the button live: the drawn mascot has glided to its station (the steering has not moved).
        let robot = try #require(layer.robots[player])
        let drawn = robot.container.position(relativeTo: nil)
        print(String(format: "GLIDE %@ drawn root (%+.3f, %+.3f) · station (%+.3f, %+.3f) · board stays %+.3f",
                     player.rawValue, drawn.x, drawn.z, c.station.x, c.station.z, layer.steering?.boardX(player) ?? .nan))
        #expect(abs(drawn.x - c.station.x) < 0.03 && abs(drawn.z - c.station.z) < 0.03, "\(player): drawn at the station")
        #expect(abs((layer.steering?.boardX(player) ?? 0) - c.dockX) < 0.01, "\(player): the steering stays at the dock")
        // A straight outer arm into the approved zone: the fist snaps onto the cap.
        for (button, share) in LaserLiveRoundGeometryV1.vaultShares {
            let zone = SIMD2(outward * share.out * h, share.y * h)
            let straight = Self.pose(r, outward: outward, toward: zone)
            let wristJoint: PresentationJoint = outward > 0 ? .leftWrist : .rightWrist
            let w = try #require(straight[wristJoint])
            #expect(hypot(w.x - r.laneCenterX - zone.x, w.y - zone.y) <= LaserLiveRoundGeometryV1.vaultRadiusShare * h + 1e-9,
                    "\(player) \(button): the straight-arm wrist is inside the judged zone")
            let b = try #require(c.buttons[button])
            // Arms down first (no snap), then the reach: within 0.1 s of the wrist entering the zone the
            // fist is locked onto the cap (the snap), and stays there.
            try send(Self.pose(r, outward: outward), frames: 15)
            let resting = try #require(Self.fistTips(robot, tip: RobotAvatarLayer.handTipLength ?? 0.076)
                .min { simd_distance($0, b.contact) < simd_distance($1, b.contact) })
            #expect(simd_distance(resting, b.contact) > 0.1, "\(player): arms down, no fist on the cap")
            try send(straight, frames: 3)
            let snapped = try #require(Self.fistTips(robot, tip: RobotAvatarLayer.handTipLength ?? 0.076)
                .min { simd_distance($0, b.contact) < simd_distance($1, b.contact) })
            print(String(format: "SNAP %@ fist %.3f m from the contact 0.1 s after entering", player.rawValue, simd_distance(snapped, b.contact)))
            #expect(simd_distance(snapped, b.contact) < 0.02, "\(player): snapped onto the cap within 0.1 s")
            try send(straight, frames: 17)
            let fist = try #require(Self.fistTips(robot, tip: RobotAvatarLayer.handTipLength ?? 0.076)
                .min { simd_distance($0, b.center) < simd_distance($1, b.center) })
            // On the cap's face (off its axis by less than its radius) and at its front: touching, not through.
            let along = simd_dot(fist - b.center, b.normal)
            let offAxis = simd_length(fist - b.center - b.normal * along)
            let gap = simd_dot(fist - b.contact, b.normal)
            print(String(format: "REACH %@ %@: fist (%+.3f, %.3f, %+.3f) button (%+.3f, %.3f, %+.3f) off its axis %.3f m (radius %.3f) · %.3f m from its front",
                         player.rawValue, button.rawValue, fist.x, fist.y, fist.z, b.center.x, b.center.y, b.center.z, offAxis, b.radius, gap))
            #expect(offAxis < b.radius, "\(player) \(button): the fist is on its button")
            #expect(gap > -0.01 && gap < 0.04, "\(player) \(button): the fist touches its front, never passes it (\(gap))")
        }
        // Lean alone (no reach): no fist on the button.
        try send(Self.pose(r, outward: outward, lean: outward * 0.09), frames: 20)
        let b = c.button
        #expect(Self.fistTips(robot, tip: 0.076).allSatisfy { f in
            let along = simd_dot(f - b.center, b.normal)
            return simd_dot(f - b.contact, b.normal) > 0.05 || simd_length(f - b.center - b.normal * along) > b.radius
        }, "a lean alone puts no fist on the button")
        // The gate opens (the button is no longer live): the mascot glides back onto its board's position.
        layer.consolesActive = false
        try send(Self.pose(r, outward: outward), frames: 45)
        let back = robot.container.position(relativeTo: nil)
        let lane = try #require(scene.players[player]?.position)
        print(String(format: "GLIDE BACK %@ drawn (%+.3f, %+.3f) · board %+.3f", player.rawValue, back.x, back.z, layer.steering?.boardX(player) ?? .nan))
        #expect(simd_length(layer.gateTravel[player] ?? .zero) < 0.02 && abs(back.z - lane.z) < 0.03, "\(player): back on its board's position")
        layer.remove()
        withExtendedLifetime(scene) {} // the lanes (the mascots' parents) live with the scene
    }

    /// Live play (authoritative game-state boards): while the gate's button is live, a mascot whose
    /// game-state board is at its wall stop (the gate's dock) is drawn there and glides to its button's
    /// station; when the gate opens it glides back to the game state's position. The game state
    /// itself is never moved.
    @Test func theGatesStopHoldsAnAuthoritativeMascotBackWhileTheConsolesShow() async throws {
        let (scene, layer) = try await Self.layer([.player1])
        let input = try LaserReplayScript.load().input
        let calibrations = input.configuration.calibrations
        let r = AvatarReference(calibration: calibrations[.player1]!, layout: input.configuration.playerPlaneLayout)
        let c = try #require(layer.consoles[.player1])
        let generation = UUID()
        var n = 0
        func send(_ frames: Int) throws {
            for _ in 0..<frames { n += 1; try Self.frame(layer, generation, n, [.player1: Self.pose(r, outward: 1)], calibrations,
                                                         centers: [.player1: r.laneCenterX]) }
        }
        layer.authoritativeBoardX = [.player1: c.wallStopX]
        try send(10)
        #expect(abs((layer.steering?.boardX(.player1) ?? 0) - c.wallStopX) < 0.005, "between gates: the game state's position")
        layer.consolesActive = true
        try send(60) // the glide to the station settles in about a second
        let held = try #require(layer.steering?.boardX(.player1))
        print(String(format: "GATE HOLD drawn %+.3f (game state %+.3f, gate dock %+.3f)", held, c.wallStopX, c.dockX))
        #expect(abs(held - c.dockX) < 0.005, "during the gate: steered at the gate's dock")
        #expect(simd_distance(try #require(layer.robots[.player1]).container.position(relativeTo: nil) * [1, 0, 1], c.station) < 0.03,
                "during the gate: drawn at the button's station")
        #expect(abs(try #require(layer.vaultReachShift(.player1, capturedAt: Double(n) / 30))) < 0.01, "the judged zone needs no extra reach")
        layer.consolesActive = false
        try send(60)
        #expect(abs((layer.steering?.boardX(.player1) ?? 0) - c.wallStopX) < 0.005, "after the gate: back to the game state's position")
        #expect(simd_length(layer.gateTravel[.player1] ?? .zero) < 0.02, "after the gate: glided back")
        layer.authoritativeBoardX = [:]
        layer.remove()
        withExtendedLifetime(scene) {}
    }

    /// GLIDE HYSTERESIS (pre-merge audit, 20 November 2026): a game-state board wobbling across the
    /// 8 cm set-off distance keeps its mascot at the station (no back-and-forth); it lets go only
    /// beyond `gateTravelReleaseTolerance`, and sets off again only within `gateTravelDockTolerance`.
    @Test func aBoardWobblingAtTheDockThresholdKeepsItsMascotAtTheStation() async throws {
        let (scene, layer) = try await Self.layer([.player1])
        let input = try LaserReplayScript.load().input
        let calibrations = input.configuration.calibrations
        let r = AvatarReference(calibration: calibrations[.player1]!, layout: input.configuration.playerPlaneLayout)
        let c = try #require(layer.consoles[.player1])
        let generation = UUID()
        var n = 0
        let robot = try #require(layer.robots[.player1])
        /// The largest distance, over the frames, between where the glide puts the mascot (its board's
        /// steered X plus the glide) and the station.
        func send(inward d: Float, _ frames: Int) throws -> Float {
            layer.authoritativeBoardX = [.player1: c.dockX - c.side * d]
            var worst: Float = 0
            for _ in 0..<frames {
                n += 1
                try Self.frame(layer, generation, n, [.player1: Self.pose(r, outward: 1)], calibrations, centers: [.player1: r.laneCenterX])
                let x = (layer.steering?.boardX(.player1) ?? .nan) + (layer.gateTravel[.player1]?.x ?? 0)
                worst = max(worst, abs(x - c.station.x))
            }
            return worst
        }
        layer.consolesActive = true
        _ = try send(inward: 0, 60)
        #expect(abs(robot.container.position(relativeTo: nil).x - c.station.x) < 0.03, "docked: at the station")
        var worst: Float = 0
        for i in 0..<16 { worst = max(worst, try send(inward: i % 2 == 0 ? 0.07 : 0.10, 6)) }
        print(String(format: "GLIDE HYSTERESIS worst distance from the station while wobbling 7–10 cm: %.3f m", worst))
        // Latched, only the board's own steps show (the largest is its first, 7 cm off the dock): 0.069 m.
        // Without the hysteresis the mascot slid back toward its board: 0.188 m (measured, 20 November 2026).
        #expect(worst < 0.09, "wobbling across 8 cm never sends the mascot back (\(worst))")
        // Clearly leaning away: released, back on its board.
        _ = try send(inward: Float(RobotAvatarLayer.gateTravelReleaseTolerance) + 0.04, 60)
        #expect(simd_length(layer.gateTravel[.player1] ?? .zero) < 0.01, "released beyond the release distance")
        // Between the two distances: stays released; within the set-off distance: glides again.
        _ = try send(inward: 0.10, 60)
        #expect(simd_length(layer.gateTravel[.player1] ?? .zero) < 0.01, "10 cm does not set it off again")
        _ = try send(inward: 0.05, 60)
        #expect(abs(robot.container.position(relativeTo: nil).x - c.station.x) < 0.03, "within 8 cm: at the station again")
        layer.consolesActive = false
        layer.authoritativeBoardX = [:]
        layer.remove()
        withExtendedLifetime(scene) {}
    }

    /// The final vault's walk-in starting while a gate's glide is still under way: the glide settles
    /// to zero during the walk (it used to freeze, offsetting the walking mascot).
    @Test func aGlideLeftWhenTheVaultWalkStartsSettlesToZero() async throws {
        let (scene, layer) = try await Self.layer([.player1])
        let input = try LaserReplayScript.load().input
        let calibrations = input.configuration.calibrations
        let r = AvatarReference(calibration: calibrations[.player1]!, layout: input.configuration.playerPlaneLayout)
        let c = try #require(layer.consoles[.player1])
        let generation = UUID()
        var n = 0
        func send(_ frames: Int) throws {
            for _ in 0..<frames { n += 1; try Self.frame(layer, generation, n, [.player1: Self.pose(r, outward: 1)], calibrations,
                                                         centers: [.player1: r.laneCenterX]) }
        }
        layer.authoritativeBoardX = [.player1: c.dockX]
        layer.consolesActive = true
        try send(60)
        let atStation = simd_length(layer.gateTravel[.player1] ?? .zero)
        #expect(atStation > 0.15, "glided to the station: \(atStation)")
        layer.consolesActive = false
        layer.setVaultWalking(true)
        try send(45)
        let left = simd_length(layer.gateTravel[.player1] ?? .zero)
        print(String(format: "WALK-IN glide %.3f m at the walk's start, %.4f m after 1.5 s", atStation, left))
        #expect(left < 0.01, "no glide offset leaks into the walk: \(left)")
        layer.setVaultWalking(false)
        layer.authoritativeBoardX = [:]
        layer.remove()
        withExtendedLifetime(scene) {}
    }

    /// A gate that times out: the buttons go dark and the mascots stop reaching for them (as when a
    /// gate opens); a pressed button stays pressed, red (the gate never opened).
    @Test func aTimedOutGateStopsTheReach() async throws {
        let (scene, layer) = try await Self.layer(Set(PlayerID.allCases))
        let configuration = try LaserRoundConfiguration(evidenceTiming: .init(windowBefore: 0.125, windowAfter: 0.125, deliveryAllowance: 0.125),
                                                        clearanceMargin: 0.005, diamondPoints: 25)
        let vault = VaultPresentation(scene: scene, configuration: configuration)
        vault.reducesMotion = { true }
        vault.liveConsoles = { layer.consoles[$0] }
        let id = UUID(), generation = UUID()
        func state(_ buttons: [PlayerID: Set<LaserVaultButton>], at t: Double, phase: LaserRoundPhase = .vault) -> LaserGameState {
            LaserGameState(sessionGeneration: generation, phase: phase, gameTime: t, activityProgress: 0, teamHealth: 5, teamScore: 0,
                           encounters: [], vault: LaserVaultState(id: id, deadline: 5, buttons: buttons))
        }
        vault.update(state: state([:], at: 0), travelDistance: 0)
        #expect(layer.consolesActive, "the gate's buttons are live: the mascots reach")
        vault.update(state: state([.player1: [.activate]], at: 1), travelDistance: 0)
        #expect(layer.consolesActive)
        vault.update(state: state([.player1: [.activate]], at: 5, phase: .ended(.vaultFailed)), travelDistance: 0)
        #expect(!layer.consolesActive, "timed out: no more reaching for a dead button")
        #expect(vault.consoleViews[.player1]?.state == .completed && vault.consoleViews[.player2]?.state == .unavailable)
        #expect(vault.consoleViews.values.allSatisfy { !$0.capIsGreen })
        layer.remove()
        withExtendedLifetime(scene) {}
    }

    /// A hand never goes inside the button or the door: a point behind the cap's face, the collar or the
    /// door's surface is brought onto that surface; points in front of it are untouched.
    @Test func aHandIsKeptOnTheButtonAndTheDoor() {
        let c = LaserGateConsole(player: .player1, arm: .init(shoulder: [0.154, 0.693], length: 0.369),
                                 visibleHalfWidth: 2.583, wallHalfWidth: 4.41, planeZ: 0)
        func local(_ p: SIMD3<Float>) -> SIMD3<Float> { c.head.orientation.inverse.act(p - c.head.center) }
        func world(_ l: SIMD3<Float>) -> SIMD3<Float> { c.head.center + c.head.orientation.act(l) }
        let capCentre = local(c.outsideConsole(world([0, 0, 0.0])))
        #expect(abs(capCentre.z - LaserGateConsole.capFront) < 1e-4 && abs(capCentre.x) < 1e-4, "onto the cap's face")
        #expect(abs(local(c.outsideConsole(world([0.18, 0, -0.1]))).z - LaserGateConsole.collarFront) < 1e-4, "onto the collar")
        // On the access panel (beside the plate, on the jamb): onto the panel's face, never inside it.
        let onPanel = local(c.outsideConsole(world([c.side * LaserGateConsole.collarShift, 0.36, -0.19])))
        #expect(abs(onPanel.z - (LaserGateConsole.panelDepth - LaserGateConsole.plateDepth - LaserGateConsole.standoff)) < 1e-4, "onto the panel")
        let onDoor = c.outsideConsole(world([0.5, -0.05, -0.25]))
        #expect(abs(local(onDoor).z + LaserGateConsole.plateDepth + LaserGateConsole.standoff) < 1e-4 && abs(c.doorClearance(onDoor)) < 1e-4,
                "onto the door's surface")
        let front = world([0.05, 0, 0.2]), beside = world([0.5, 0, 0.1])
        #expect(simd_distance(c.outsideConsole(front), front) < 1e-6 && simd_distance(c.outsideConsole(beside), beside) < 1e-6)
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
        #expect(shift > 0.7, "far beyond any arm: \(shift) game units")
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
            // Leaning on toward the wall during the gate: it stays at the dock (the gate's stop).
            try send(0.09, 60)
            #expect(abs((layer.steering?.boardX(.player1) ?? 0) - c.dockX) < 0.005, "the gate stops it at its dock")
            // Leaning away releases it.
            try send(-0.09, 20)
            #expect((layer.steering?.boardX(.player1) ?? 0) > c.dockX + 0.1, "leaning away leaves the dock")
            // Outside a gate it rides on to the wall stop, past the dock.
            layer.docksActive = false
            try send(0.09, 120)
            let free = try #require(layer.steering?.boardX(.player1))
            print(String(format: "WALL STOP outside a gate %+.3f (dock %+.3f, wall stop %+.3f)", free, c.dockX, c.wallStopX))
            #expect(abs(free - c.wallStopX) < 0.005, "outside a gate the board reaches the wall stop")
        }
        layer.remove()
        withExtendedLifetime(scene) {}
    }
}
