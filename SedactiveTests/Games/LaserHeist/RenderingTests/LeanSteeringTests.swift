import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// Approved movement contract (owner, 12 November 2026): a held lean is a lateral SPEED that moves
/// the whole mascot and its board across the corridor; upright it brakes and stays; the other way
/// it reverses. Only the corridor (walls, or the camera's view of the players' plane where that is
/// narrower) and, in co-op, the partner's board limit it: no lane, no corridor half.
/// Root cause of "the mascot barely moves" (iPad, 12 November 2026): the travel was clamped per
/// lane to 0.45 m toward the own wall and 0.06 m toward the partner (`PlayerHoverboard`'s glide
/// limits, applied in `RobotRetargeter`), so Lemon could not cross toward the right at all, even
/// in Solo, and the hip sway (and with it the travel) was also scaled by tracking presence.
/// SYNTHETIC player-plane joints throughout.
@MainActor
struct LeanSteeringTests {
    // MARK: Fixtures

    private static func calibration(_ player: PlayerID) throws -> (PlayerCalibration, PlayerPlaneLayout) {
        let input = try LaserReplayScript.load().input
        return (try #require(input.configuration.calibrations[player]), input.configuration.playerPlaneLayout)
    }

    /// A calibrated observation in the unmirrored plane: hips at `hip`, shoulders at `shoulder`
    /// (lane-relative, game units; + is the player's own left, which shows to screen LEFT).
    private static func observation(_ reference: AvatarReference, hip: Double = 0, shoulder: Double,
                                    hipDrop: Double = 0) -> RobotRetargeter.Observation {
        let h = reference.standingHeight, lane = reference.laneCenterX
        var o = RobotRetargeter.Observation()
        o.calibrated = true
        o.centerX = lane + hip
        func p(_ x: Double, _ y: Double) -> PresentationPoint { PresentationPoint(x: lane + x, y: y, confidence: 0.9) }
        let hipY = reference.standingHipY - hipDrop
        o.joints = [.leftShoulder: p(shoulder + 0.13 * h, 0.82 * h - hipDrop), .rightShoulder: p(shoulder - 0.13 * h, 0.82 * h - hipDrop),
                    .leftHip: p(hip + 0.07 * h, hipY), .rightHip: p(hip - 0.07 * h, hipY),
                    .leftWrist: p(shoulder + 0.16 * h, 0.44 * h - hipDrop), .rightWrist: p(shoulder - 0.16 * h, 0.44 * h - hipDrop),
                    // A rigid trunk lean: the head moves past the hips further than the shoulders.
                    .nose: p(hip + (shoulder - hip) * (0.9 * h - reference.standingHipY) / (0.82 * h - reference.standingHipY),
                             0.9 * h - hipDrop)]
        return o
    }

    /// The scene's own steering bounds (corridor 6.3 m, camera 64° at 3.1 m, 4:3 iPad, 1.16 m board).
    private static func sceneSteering(_ lanes: [PlayerID: Float]) -> LateralSteering {
        let layout = LaserWorldLayout()
        let half = PlayerHoverboard.halfWidth
        let visible = LateralSteering.visibleHalfWidth(depth: layout.cameraPosition.z, verticalFieldOfViewDegrees: layout.cameraVerticalFieldOfView,
                                                       aspect: RobotAvatarLayer.narrowestDisplayAspect)
        return LateralSteering(lanes: lanes, bounds: LateralSteering.bounds(corridorWidth: layout.corridorWidth, visibleHalfWidth: visible,
                                                                            halfWidth: half), halfWidth: half)
    }

    private static let coopLanes: [PlayerID: Float] = [.player1: -0.7, .player2: 0.7]
    private static let dt: Float = 1 / 60

    /// Runs the steering for `seconds` at 60 Hz with fixed lean speeds; returns each frame's board X.
    @discardableResult
    private static func run(_ s: inout LateralSteering, _ speeds: [PlayerID: Float], seconds: Float) -> [[PlayerID: Float]] {
        var frames: [[PlayerID: Float]] = []
        for _ in 0..<Int(seconds * 60) {
            s.step(dt: dt, inputs: speeds.mapValues { .init(targetSpeed: $0) })
            var f: [PlayerID: Float] = [:]
            for p in s.riders.keys { f[p] = s.boardX(p) }
            frames.append(f)
        }
        return frames
    }

    // MARK: Lean → steering speed (RobotRetargeter)

    @Test(arguments: PlayerID.allCases)
    func aHeldLeanIsASteeringSpeedTowardItsSideAndUprightIsNone(_ player: PlayerID) throws {
        let (c, layout) = try Self.calibration(player)
        let reference = AvatarReference(calibration: c, layout: layout)
        var r = RobotRetargeter(reference: reference, robotLegRest: 0.5)
        r.leanSteerGain = RobotRetargeter.boardLeanSteerGain
        let h = reference.standingHeight
        var t = 0.0
        func hold(_ o: RobotRetargeter.Observation, _ seconds: Double) {
            for _ in 0..<Int(seconds * 30) { t += 1.0 / 30; r.update(o, time: t) }
        }
        // ~15° of trunk lean to the player's own left: screen LEFT (mirror), ~0.9 m/s.
        hold(Self.observation(reference, shoulder: 0.08 * h), 0.5)
        #expect(r.steerSpeed < -0.6 && r.steerSpeed > -1.2, "\(player): \(r.steerSpeed) m/s")
        #expect(r.targets.lean != 0, "the trunk still tilts (the board still banks)")
        hold(Self.observation(reference, shoulder: -0.08 * h), 0.5)
        #expect(r.steerSpeed > 0.4, "the other way reverses")
        hold(Self.observation(reference, shoulder: 0), 0.5)
        #expect(r.steerSpeed == 0, "upright: no speed")
        #expect(abs(r.sway) < 0.01, "the lean is never a recentring sway")
        // Untracked: no speed (brake and hold, never drift on stale input).
        hold(Self.observation(reference, shoulder: 0.08 * h), 0.5)
        for _ in 0..<15 { t += 1.0 / 30; r.update(nil, time: t) }
        #expect(r.steerSpeed == 0)
        // Without a board (feet on the floor) a lean never steers.
        var floor = RobotRetargeter(reference: reference, robotLegRest: 0.5)
        for i in 0..<45 { floor.update(Self.observation(reference, shoulder: 0.08 * h), time: Double(i) / 30) }
        #expect(floor.steerSpeed == 0)
    }

    /// A posture lean inside the deadband (about 4°) never drifts the board.
    @Test func aSmallPostureLeanDoesNotSteer() throws {
        let (c, layout) = try Self.calibration(.player1)
        let reference = AvatarReference(calibration: c, layout: layout)
        var r = RobotRetargeter(reference: reference, robotLegRest: 0.5)
        r.leanSteerGain = RobotRetargeter.boardLeanSteerGain
        let o = Self.observation(reference, shoulder: 0.02 * reference.standingHeight)
        for i in 0..<150 { r.update(o, time: Double(i) / 30) }
        #expect(r.steerSpeed == 0)
    }

    /// Jump and duck coexist with steering: the speed is unaffected by a jump's lift or a duck's drop.
    @Test func jumpAndDuckKeepSteering() throws {
        let (c, layout) = try Self.calibration(.player1)
        let reference = AvatarReference(calibration: c, layout: layout)
        var r = RobotRetargeter(reference: reference, robotLegRest: 0.5)
        r.leanSteerGain = RobotRetargeter.boardLeanSteerGain
        let h = reference.standingHeight
        var o = Self.observation(reference, shoulder: -0.08 * h)
        for i in 0..<15 { r.update(o, time: Double(i) / 30) }
        let speed = r.steerSpeed
        o.lowerSoleY = 0.25 * h
        o.airborne = true
        for i in 15..<30 { r.update(o, time: Double(i) / 30) }
        #expect(r.lift > 0.05, "jumping: \(r.lift)")
        #expect(abs(r.steerSpeed - speed) < 0.05, "still steering while airborne")
        var duck = Self.observation(reference, shoulder: -0.08 * h, hipDrop: 0.15 * h)
        duck.crownY = 0.8 * h // the crown went down: a duck
        for i in 30..<60 { r.update(duck, time: Double(i) / 30) }
        #expect(r.targets.pelvisDrop > 0.02, "ducking: \(r.targets.pelvisDrop)")
        #expect(abs(r.steerSpeed - speed) < 0.05, "still steering while ducking")
    }

    // MARK: Solo (LateralSteering)

    @Test func soloLeanLeftAndRightTravelHoldAndReverse() {
        var s = Self.sceneSteering([.player1: -0.7])
        // 1. LEFT: sustained leftward travel.
        let left = Self.run(&s, [.player1: -0.6], seconds: 0.5)
        #expect(zip(left.dropFirst(), left).allSatisfy { $0[.player1]! < $1[.player1]! }, "moves left every frame")
        #expect(s.boardX(.player1)! < -0.85)
        // 3. Neutral: brakes, then stays (no recentring).
        Self.run(&s, [.player1: 0], seconds: 0.3)
        let stopped = s.boardX(.player1)!
        Self.run(&s, [.player1: 0], seconds: 2)
        #expect(s.boardX(.player1) == stopped && s.riders[.player1]?.velocity == 0, "holds at \(stopped)")
        #expect(stopped < -0.85, "not pulled back toward the lane")
        // 2 + 4. RIGHT reverses, and keeps going right.
        let right = Self.run(&s, [.player1: 0.6], seconds: 1)
        #expect(right.last![.player1]! > right.first![.player1]! + 0.3)
        #expect(zip(right.dropFirst(10), right.dropFirst(9)).allSatisfy { $0[.player1]! > $1[.player1]! })
    }

    @Test func soloLemonCrossesTheWholeCorridorWithoutClipping() {
        var s = Self.sceneSteering([.player1: -0.7])
        // 5. Crosses the corridor midpoint, 6. reaches the right wall limit and stops there.
        let frames = Self.run(&s, [.player1: 1.0], seconds: 5)
        let crossedAt = frames.firstIndex { $0[.player1]! > 0 }
        #expect(crossedAt != nil, "crosses the midpoint")
        #expect(s.boardX(.player1) == s.bounds.upperBound && s.riders[.player1]?.constraint == .rightLimit)
        #expect(frames.allSatisfy { $0[.player1]! <= s.bounds.upperBound })
        Self.run(&s, [.player1: -1.0], seconds: 6)
        #expect(s.boardX(.player1) == s.bounds.lowerBound && s.riders[.player1]?.constraint == .leftLimit)
        // The board's edges stay inside the corridor walls (and the camera's view).
        let layout = LaserWorldLayout()
        #expect(s.bounds.lowerBound - s.halfWidth > -layout.corridorWidth / 2)
        #expect(s.bounds.upperBound + s.halfWidth < layout.corridorWidth / 2)
        let width = s.bounds.upperBound - s.bounds.lowerBound
        print(String(format: "SOLO bounds %+.3f…%+.3f m (board centre), travel span %.2f m, midpoint crossed after %.2f s",
                     s.bounds.lowerBound, s.bounds.upperBound, width, Float(crossedAt ?? 0) / 60))
        #expect(width > 3.5, "nearly the whole visible corridor")
    }

    /// A comfortable lean (~12°, ~0.7 m/s) brings Lemon's hand to the left-wall button column
    /// (board 0.45 m out from the lane) within a second (responsive tuning; was 1.1 s).
    @Test func aComfortableLeanReachesTheButtonRegionInOneToTwoSeconds() throws {
        let (c, layout) = try Self.calibration(.player1)
        let reference = AvatarReference(calibration: c, layout: layout)
        var r = RobotRetargeter(reference: reference, robotLegRest: 0.5)
        r.leanSteerGain = RobotRetargeter.boardLeanSteerGain
        let h = reference.standingHeight
        let lean = Self.observation(reference, shoulder: 0.065 * h) // ≈ 12° trunk lean
        var s = Self.sceneSteering([.player1: -0.7])
        var seconds: Float = 0
        while s.boardX(.player1)! > -0.7 - 0.45, seconds < 4 {
            seconds += Self.dt
            r.update(lean, time: Double(seconds))
            s.step(dt: Self.dt, inputs: [.player1: .init(targetSpeed: r.steerSpeed)])
        }
        print(String(format: "REACH button region (0.45 m) in %.2f s at %.2f m/s", seconds, r.steerSpeed))
        #expect(seconds >= 0.4 && seconds <= 1.0, "\(seconds) s")
    }

    // MARK: Co-op (LateralSteering)

    @Test func coopEachCrossesTheCentrelineWhenThePartnerIsFarAway() {
        // 7. P2 far right, then P1 can go well past the centre (70% of the corridor's span).
        var s = Self.sceneSteering(Self.coopLanes)
        Self.run(&s, [.player2: 1.5], seconds: 2)
        Self.run(&s, [.player1: 1.5], seconds: 3)
        let span = s.bounds.upperBound - s.bounds.lowerBound
        let p1 = s.boardX(.player1)!
        #expect(p1 > 0.2, "P1 crossed the centreline: \(p1)")
        #expect((p1 - s.bounds.lowerBound) / span > 0.65, "about 70% across")
        #expect(abs(s.boardX(.player2)! - p1 - s.minimumSeparation) < 1e-4, "stops at the partner")
        // 8. P1 far left, then P2 can go left of centre.
        var t = Self.sceneSteering(Self.coopLanes)
        Self.run(&t, [.player1: -1.5], seconds: 2)
        Self.run(&t, [.player2: -1.5], seconds: 3)
        #expect(t.boardX(.player2)! < -0.2, "P2 crossed the centreline: \(t.boardX(.player2)!)")
        print(String(format: "COOP P1 reached %+.3f m (P2 %+.3f); P2 reached %+.3f m (P1 %+.3f); min separation %.2f m",
                     p1, s.boardX(.player2)!, t.boardX(.player2)!, t.boardX(.player1)!, s.minimumSeparation))
    }

    @Test func coopBothLeaningInwardStopApartWithoutJitter() {
        var s = Self.sceneSteering(Self.coopLanes)
        // 9 + 10. Simultaneous inward movement: they stop at the minimum separation, never overlap.
        let frames = Self.run(&s, [.player1: 1.2, .player2: -0.6], seconds: 3)
        for f in frames {
            #expect(f[.player2]! - f[.player1]! >= s.minimumSeparation - 1e-4, "never overlap")
            #expect(f[.player1]! < f[.player2]!, "13. P1 stays left of P2")
        }
        // Deterministic resolution: the faster one covered more of the closing distance.
        let p1Moved = s.boardX(.player1)! + 0.7, p2Moved = 0.7 - s.boardX(.player2)!
        #expect(p1Moved > p2Moved, "P1 \(p1Moved) m, P2 \(p2Moved) m")
        // 12. No jitter or teleporting: every frame moves at most the speed cap, and once in
        // contact, both stay exactly still while both keep leaning inward.
        for (a, b) in zip(frames.dropFirst(), frames) {
            for p in PlayerID.allCases { #expect(abs(a[p]! - b[p]!) <= LateralSteering.maximumSpeed * Self.dt + 1e-5) }
        }
        let settled = frames.suffix(60)
        #expect(Set(settled.map { $0[.player1]! }).count == 1 && Set(settled.map { $0[.player2]! }).count == 1, "still at contact")
        #expect(s.riders[.player1]?.constraint == .partner && s.riders[.player2]?.constraint == .partner)
        // The same inputs give the same result.
        var again = Self.sceneSteering(Self.coopLanes)
        Self.run(&again, [.player1: 1.2, .player2: -0.6], seconds: 3)
        #expect(again == s)
    }

    @Test func coopMovingAwayReleasesSpaceForThePartner() {
        var s = Self.sceneSteering(Self.coopLanes)
        Self.run(&s, [.player1: 1.0], seconds: 2) // 11. P1 pinned against P2
        let pinned = s.boardX(.player1)!
        #expect(s.riders[.player1]?.constraint == .partner)
        Self.run(&s, [.player1: 1.0, .player2: 1.0], seconds: 1.5)
        #expect(s.boardX(.player1)! > pinned + 0.5, "P1 follows P2 to the right")
        #expect(s.boardX(.player2)! - s.boardX(.player1)! >= s.minimumSeparation - 1e-4)
        // P2 is pinned at the right wall: P1 pushing still cannot overlap it.
        Self.run(&s, [.player1: 1.5, .player2: 1.5], seconds: 4)
        #expect(s.boardX(.player2) == s.bounds.upperBound)
        #expect(abs(s.boardX(.player2)! - s.boardX(.player1)! - s.minimumSeparation) < 1e-4)
    }

    // MARK: Gameplay integration (RobotAvatarLayer in the scene)

    private static func snapshotFrame(_ layer: RobotAvatarLayer, _ generation: UUID, frame: Int,
                                      observations: [PlayerID: (PlayerCalibration, RobotRetargeter.Observation)]) throws {
        let t = Double(frame) / 30
        var players: [PlayerID: PlayerBodySample] = [:]
        var joints: [PlayerID: PresentationPoseSample] = [:]
        func v(_ x: Double) throws -> EstimatedScalar { try EstimatedScalar(value: x, validity: .valid) }
        for (player, (c, o)) in observations {
            let h = o.joints[.nose].map { $0.y / 0.9 } ?? 1.7
            players[player] = PlayerBodySample(playerID: player, calibrationRevision: c.revision, trackingStatus: .reliable,
                geometry: BodyGeometry(crownY: try v(h), leftWristY: try v(0.44 * h), rightWristY: try v(0.44 * h),
                                       leftSoleY: try v(0), rightSoleY: try v(0), centerX: try v(o.centerX ?? 0)),
                jumpState: JumpState(phase: .grounded, validity: .valid))
            joints[player] = PresentationPoseSample(playerID: player, calibrationRevision: c.revision, joints: o.joints)
        }
        layer.apply(BodySnapshot(sessionGeneration: generation, frameID: UInt64(frame), capturedAt: t,
                                 cameraGeometryRevision: 1, players: players),
                    joints: PresentationPoseFrame(sessionGeneration: generation, frameID: UInt64(frame), capturedAt: t, players: joints))
    }

    /// 14. The applied RealityKit transforms move: the mascot entity and its board translate together
    /// in world space, a long way, read back from the entities themselves (not the controller).
    /// 18. Laser drawing follows the mascot (a Solo round's beam spans the corridor); a lean alone
    /// shows no wrist on any button.
    @Test func soloTheMascotEntityAndBoardTranslateAcrossTheCorridor() async throws {
        _ = await PlayerHoverboard.sharedTemplate() // boards come from the loaded asset
        let (c, layout) = try Self.calibration(.player1)
        let scene = LaserScene()
        let layer = RobotAvatarLayer(scene: scene, calibrations: [.player1: c], layout: layout,
                                     templates: try await RobotAvatarLayer.loadTemplates())
        scene.robotAvatars = layer
        let reference = AvatarReference(calibration: c, layout: layout)
        let h = reference.standingHeight
        let robot = try #require(layer.robots[.player1]), board = try #require(layer.hoverboards[.player1])
        let lane = try #require(scene.players[.player1])
        func worldX() -> (mascot: Float, board: Float) {
            (robot.container.position(relativeTo: nil).x, board.model.position(relativeTo: nil).x)
        }
        let before = worldX()
        let generation = UUID()
        layer.showsReachCursors = true
        // Lean to screen RIGHT (the player's own right: shoulders toward −x unmirrored) for 3 s.
        for frame in 1...90 {
            try Self.snapshotFrame(layer, generation, frame: frame,
                                   observations: [.player1: (c, Self.observation(reference, shoulder: -0.1 * h))])
        }
        board.step(dt: 1 / 60)
        let after = worldX()
        let reading = try #require(layer.steeringReading(.player1))
        print(String(format: "SOLO applied world x: mascot %+.3f → %+.3f m, board %+.3f → %+.3f m (lane %+.3f); reading target %+.3f applied %+.3f %@",
                     before.mascot, after.mascot, before.board, after.board, lane.position.x,
                     reading.targetX, reading.appliedX, reading.constraint.rawValue))
        #expect(after.mascot - before.mascot > 1.5, "the entity crossed the corridor")
        #expect(after.mascot > 0.5, "Lemon is right of the midpoint")
        #expect(abs(after.board - after.mascot) < 0.02, "the board carries the mascot")
        #expect(abs(reading.appliedX - after.mascot) < 1e-4, "telemetry reads the entity")
        #expect(scene.laneSpan(for: .player1) == scene.fullLaserSpan, "Solo: its beam crosses the whole corridor")
        // A lean alone presses nothing: far from its console dock, the judged zones are out of reach.
        #expect((layer.vaultReachShift(.player1, capturedAt: 3.0) ?? 0) > 2, "zones moved beyond any arm")
        _ = h
        layer.remove()
    }

    /// Co-op in the scene: both steer independently, the lasers' split follows the mascots, they
    /// never overlap, P1 stays left. 20. A new round's layer (Play Again) starts fresh at the lanes.
    @Test func coopInTheSceneAndPlayAgainStartsFresh() async throws {
        _ = await PlayerHoverboard.sharedTemplate() // boards come from the loaded asset
        let input = try LaserReplayScript.load().input
        let calibrations = input.configuration.calibrations, layout = input.configuration.playerPlaneLayout
        let scene = LaserScene()
        let templates = try await RobotAvatarLayer.loadTemplates()
        var layer = RobotAvatarLayer(scene: scene, calibrations: calibrations, layout: layout, templates: templates)
        scene.robotAvatars = layer
        let refs = calibrations.mapValues { AvatarReference(calibration: $0, layout: layout) }
        let r1 = try #require(refs[.player1]), r2 = try #require(refs[.player2])
        let c1 = try #require(calibrations[.player1]), c2 = try #require(calibrations[.player2])
        let generation = UUID()
        // Both lean toward each other (P1 screen right, P2 screen left) for 3 s.
        for frame in 1...90 {
            try Self.snapshotFrame(layer, generation, frame: frame, observations: [
                .player1: (c1, Self.observation(r1, shoulder: -0.1 * r1.standingHeight)),
                .player2: (c2, Self.observation(r2, shoulder: 0.1 * r2.standingHeight)),
            ])
            let a = try #require(layer.mascotWorldX(.player1)), b = try #require(layer.mascotWorldX(.player2))
            let steering = try #require(layer.steering)
            #expect(b - a >= steering.minimumSeparation - 0.01, "frame \(frame): \(a) / \(b)")
            #expect(a < b)
        }
        let a = try #require(layer.mascotWorldX(.player1)), b = try #require(layer.mascotWorldX(.player2))
        #expect(a > -0.7 + 0.05 && b < 0.7 - 0.05, "both moved inward")
        let split = scene.laneSpan(for: .player1).upperBound
        #expect(abs(split - (a + b) / 2) < 1e-4 && scene.laneSpan(for: .player2).lowerBound == split, "beams meet between the mascots")
        let reading = try #require(layer.steeringReading(.player1))
        #expect(reading.constraint == .partner && (reading.partnerDistance ?? 1) < LateralSteering.partnerGap + 0.01)
        layer.remove()
        // Play Again: the next round's avatars stand at their lanes again with no velocity.
        layer = RobotAvatarLayer(scene: scene, calibrations: calibrations, layout: layout, templates: templates)
        scene.robotAvatars = layer
        let fresh = try #require(layer.steering)
        #expect(fresh.riders.values.allSatisfy { $0.travel == 0 && $0.velocity == 0 })
        #expect(abs((layer.mascotWorldX(.player1) ?? 0) - (scene.players[.player1]?.position.x ?? 1)) < 0.05)
        layer.remove()
    }

    // 17. Both wall-button targets: `LaserGateConsoleTests` (the mascot's fist on each button from
    // its dock, after steering there).
}
