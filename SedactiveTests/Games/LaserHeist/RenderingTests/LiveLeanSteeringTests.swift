import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// iPad P0, 12 November 2026: a physical lean banked Lemon's board but never moved it, while every
/// earlier steering test passed. Those tests drove the avatars through the DEBUG snapshot bridge,
/// which never resets the presentation. A live round publishes a later source status (binding,
/// calibration, round start); the mailbox then reports a full reset, `resetPresentation` built a
/// fresh retargeter, and the fresh one had lost the board's steering gain: steering speed 0 forever,
/// while the bank (trunk angle) kept working.
/// These tests run the live path itself: `LaserScene.attachLiveAvatars` (Solo: Lemon only), the
/// production mailbox with a status change like a live round's, `LiveAvatarPresenter` render ticks,
/// and assertions on the RealityKit entities' world transforms. SYNTHETIC packets: no camera or
/// Vision, so nothing here proves real tracking on the iPad.
@MainActor
struct LiveLeanSteeringTests {
    private struct Live {
        let scene: LaserScene
        let mailbox: AvatarPoseMailbox
        var source: SyntheticAvatarSource
        let calibrations: [PlayerID: PlayerCalibration]
        let references: [PlayerID: AvatarReference]
        var frameID: UInt64
        var time: Double

        var avatars: RobotAvatarLayer { scene.robotAvatars! }
        func mascotX(_ p: PlayerID) -> Float { avatars.robots[p]!.container.position(relativeTo: nil).x }
        /// The board's world X after its own frame step (`HoverboardSystem` runs it in a live scene;
        /// a test scene has no running RealityKit systems).
        func boardX(_ p: PlayerID) -> Float {
            let board = avatars.hoverboards[p]!
            board.step(dt: 1 / 60)
            return board.model.position(relativeTo: nil).x
        }

        /// One camera frame (30 Hz) with each listed player leaning `shoulder` (share of standing
        /// height, + the player's own left), then two render ticks (60 Hz), as on the iPad.
        mutating func frame(_ leans: [PlayerID: Double]) throws {
            frameID += 1
            time += 1.0 / 30
            var players: [PlayerID: PlayerBodySample] = [:]
            var joints: [PlayerID: PresentationPoseSample] = [:]
            func v(_ x: Double) throws -> EstimatedScalar { try EstimatedScalar(value: x, validity: .valid) }
            for (player, share) in leans {
                let c = calibrations[player]!, r = references[player]!, h = r.standingHeight, lane = r.laneCenterX
                func p(_ x: Double, _ y: Double) -> PresentationPoint { PresentationPoint(x: lane + x, y: y, confidence: 0.9) }
                let shoulder = share * h, hipY = r.standingHipY
                let head = shoulder * (0.9 * h - hipY) / (0.82 * h - hipY) // a rigid trunk lean
                joints[player] = PresentationPoseSample(playerID: player, calibrationRevision: c.revision, joints: [
                    .leftShoulder: p(shoulder + 0.13 * h, 0.82 * h), .rightShoulder: p(shoulder - 0.13 * h, 0.82 * h),
                    .leftHip: p(0.07 * h, hipY), .rightHip: p(-0.07 * h, hipY),
                    .leftWrist: p(shoulder + 0.16 * h, 0.44 * h), .rightWrist: p(shoulder - 0.16 * h, 0.44 * h),
                    .nose: p(head, 0.9 * h)])
                players[player] = PlayerBodySample(playerID: player, calibrationRevision: c.revision, trackingStatus: .reliable,
                    geometry: BodyGeometry(crownY: try v(h), leftWristY: try v(0.44 * h), rightWristY: try v(0.44 * h),
                                           leftSoleY: try v(0), rightSoleY: try v(0), centerX: try v(lane)),
                    jumpState: JumpState(phase: .grounded, validity: .valid))
            }
            let snapshot = BodySnapshot(sessionGeneration: source.context.generation, frameID: frameID, capturedAt: time,
                                        cameraGeometryRevision: source.context.geometryRevision, players: players)
            let pose = PresentationPoseFrame(sessionGeneration: source.context.generation, frameID: frameID, capturedAt: time,
                                             players: joints)
            #expect(mailbox.offer(source.output(snapshot, joints: pose)) == nil)
            scene.refreshLiveAvatars(now: time + 0.004)
            scene.refreshLiveAvatars(now: time + 0.004 + 1.0 / 60)
        }

        mutating func hold(_ leans: [PlayerID: Double], seconds: Double) throws -> [[PlayerID: Float]] {
            var xs: [[PlayerID: Float]] = []
            for _ in 0..<Int(seconds * 30) {
                try frame(leans)
                xs.append(Dictionary(uniqueKeysWithValues: leans.keys.map { ($0, mascotX($0)) }))
            }
            return xs
        }
    }

    /// The live attachment as a round makes it: the avatars first, then the producer's statuses,
    /// the later one (binding / calibration) replacing the first, which resets the presentation.
    private func live(_ players: Set<PlayerID>) async throws -> Live {
        _ = await PlayerHoverboard.sharedTemplate() // as the app: boards loaded before the round's avatars
        let input = try LaserReplayScript.load().input
        let scene = LaserScene()
        let mailbox = AvatarPoseMailbox(maxAge: LiveAvatarPresenter.maximumPoseAge)
        scene.attachLiveAvatars(mailbox: mailbox, templates: try await RobotAvatarLayer.sharedTemplates(), players: players)
        var source = SyntheticAvatarSource(configuration: input.configuration, cameraGeometryRevision: input.cameraGeometryRevision)
        mailbox.publish(source.status)
        source.statusRevision += 1
        source.controlRevision += 1
        mailbox.publish(source.status)
        let start = try RobotDemoSequence(configuration: input.configuration, cameraGeometryRevision: input.cameraGeometryRevision,
                                          only: .leanRight).frame(1).snapshot
        let calibrations = input.configuration.calibrations
        return Live(scene: scene, mailbox: mailbox, source: source, calibrations: calibrations,
                    references: calibrations.mapValues { AvatarReference(calibration: $0, layout: input.configuration.playerPlaneLayout) },
                    frameID: start.frameID, time: start.capturedAt)
    }

    /// Solo, through the live presenter: from Lemon's lane, a held RIGHT lean carries the mascot
    /// entity across X = 0 into the right half with its board; upright it stops and stays; LEFT
    /// reverses toward the left wall; no partner limit ever applies.
    @Test func soloLiveLeanRightCrossesTheCentreStopsAndReverses() async throws {
        var live = try await live([.player1])
        _ = try live.hold([.player1: 0], seconds: 0.5)
        let gain = live.avatars.robots[.player1]!.retargeter.leanSteerGain
        #expect(gain == RobotRetargeter.boardLeanSteerGain, "the live reset keeps the board's steering (gain \(gain))")
        let start = live.mascotX(.player1)
        // ~15° to the player's own right (screen right).
        let right = try live.hold([.player1: -0.08], seconds: 4)
        let crossed = right.firstIndex { $0[.player1]! > 0 }
        let afterRight = live.mascotX(.player1), boardRight = live.boardX(.player1)
        let reading = try #require(live.avatars.steeringReading(.player1))
        print(String(format: "LIVE SOLO lean right: mascot world x %+.3f → %+.3f m (board %+.3f), crossed 0 after %.2f s, screen x %.2f, %@",
                     start, afterRight, boardRight, Double(crossed ?? -1) / 30, reading.screenX ?? -1, reading.constraint.rawValue))
        #expect(crossed != nil, "Lemon crossed X = 0")
        #expect(afterRight > 0.8, "well into the right half: \(afterRight)")
        #expect(abs(boardRight - afterRight) < 0.02, "the hoverboard follows")
        #expect(reading.solo && reading.partnerDistance == nil)
        // Upright: it stops and stays (no recentring).
        let neutral = try live.hold([.player1: 0], seconds: 1.5)
        let stopped = live.mascotX(.player1)
        #expect(stopped > afterRight - 0.05 && stopped < afterRight + 0.4, "brakes near where it was: \(stopped)")
        let last = neutral.suffix(15).map { $0[.player1]! }
        #expect(last.max()! - last.min()! < 0.005, "holds still")
        // LEFT reverses, back across the centre toward the left wall.
        _ = try live.hold([.player1: 0.08], seconds: 6)
        let left = live.mascotX(.player1)
        let steering = try #require(live.avatars.steering)
        print(String(format: "LIVE SOLO lean left: %+.3f → %+.3f m (left limit %+.3f)", stopped, left, steering.bounds.lowerBound))
        #expect(left < -1.5)
        #expect(steering.riders.keys.sorted { $0.rawValue < $1.rawValue } == [.player1], "no P2 rider, no partner limit")
        #expect(steering.riders[.player1]?.constraint != .partner)
        live.scene.detachLiveAvatars()
    }

    /// The DEBUG Test Move drives the same controller and entities without Vision: with Lemon
    /// untracked (no poses at all) it still moves the mascot entity; stopping holds it.
    @Test func debugTestMoveMovesLemonThroughTheSameEntityPath() async throws {
        var live = try await live([.player1])
        _ = try live.hold([.player1: 0], seconds: 0.3)
        let start = live.mascotX(.player1)
        RobotAvatarLayer.debugTestSteer = RobotAvatarLayer.debugTestSteerSpeed
        defer { RobotAvatarLayer.debugTestSteer = nil }
        for n in 1...120 { live.scene.refreshLiveAvatars(now: live.time + Double(n) / 60) } // 2 s, no poses
        let moved = live.mascotX(.player1)
        RobotAvatarLayer.debugTestSteer = nil
        for n in 121...180 { live.scene.refreshLiveAvatars(now: live.time + Double(n) / 60) }
        let held = live.mascotX(.player1)
        print(String(format: "TEST MOVE right: %+.3f → %+.3f m in 2 s, stopped at %+.3f m", start, moved, held))
        #expect(moved - start > 1.2)
        #expect(abs(held - moved) < 0.1 && held > start + 1.2, "stops and stays")
        live.scene.detachLiveAvatars()
    }

    /// Co-op through the live presenter: both lean toward each other, never overlap, P1 stays left.
    @Test func coopLiveLeansKeepSeparation() async throws {
        var live = try await live(Set(PlayerID.allCases))
        _ = try live.hold([.player1: 0, .player2: 0], seconds: 0.3)
        let frames = try live.hold([.player1: -0.1, .player2: 0.1], seconds: 3)
        let steering = try #require(live.avatars.steering)
        for f in frames {
            #expect(f[.player2]! - f[.player1]! >= steering.minimumSeparation - 0.02)
        }
        let a = live.mascotX(.player1), b = live.mascotX(.player2)
        print(String(format: "LIVE CO-OP inward: P1 %+.3f, P2 %+.3f, gap between boards %.3f m", a, b, b - a - 2 * steering.halfWidth))
        #expect(a > -0.7 + 0.05 && b < 0.7 - 0.05, "both moved inward")
        // P2 steers away, P1 follows past the centre.
        _ = try live.hold([.player1: -0.1, .player2: -0.12], seconds: 3)
        #expect(live.mascotX(.player1) > 0.1, "P1 crossed the centre: \(live.mascotX(.player1))")
        #expect(live.mascotX(.player2) - live.mascotX(.player1) >= steering.minimumSeparation - 0.02)
        live.scene.detachLiveAvatars()
    }

    /// Reaching for a wall button shifts the shoulder line, but the head stays over the hips: no
    /// steering. A real trunk lean (head going with the shoulders) steers.
    @Test func anArmReachDoesNotSteerButATrunkLeanDoes() throws {
        let input = try LaserReplayScript.load().input
        let c = try #require(input.configuration.calibrations[.player1])
        let reference = AvatarReference(calibration: c, layout: input.configuration.playerPlaneLayout)
        let h = reference.standingHeight, lane = reference.laneCenterX
        func p(_ x: Double, _ y: Double) -> PresentationPoint { PresentationPoint(x: lane + x, y: y, confidence: 0.9) }
        func observation(shoulders: Double, head: Double) -> RobotRetargeter.Observation {
            var o = RobotRetargeter.Observation()
            o.calibrated = true
            o.centerX = lane
            o.joints = [.leftShoulder: p(shoulders + 0.13 * h, 0.82 * h), .rightShoulder: p(shoulders - 0.13 * h, 0.82 * h),
                        .leftHip: p(0.07 * h, reference.standingHipY), .rightHip: p(-0.07 * h, reference.standingHipY),
                        .leftWrist: p(0.6 * h, 0.85 * h), .rightWrist: p(-0.16 * h, 0.44 * h), .nose: p(head, 0.9 * h)]
            return o
        }
        var reach = RobotRetargeter(reference: reference, robotLegRest: 0.5)
        reach.leanSteerGain = RobotRetargeter.boardLeanSteerGain
        for i in 0..<30 { reach.update(observation(shoulders: 0.06 * h, head: 0), time: Double(i) / 30) }
        #expect(reach.steerSpeed == 0, "the arm reach shifts the shoulders 0.06 h, the head stays: \(reach.steerSpeed)")
        var lean = RobotRetargeter(reference: reference, robotLegRest: 0.5)
        lean.leanSteerGain = RobotRetargeter.boardLeanSteerGain
        for i in 0..<30 { lean.update(observation(shoulders: 0.08 * h, head: 0.1 * h), time: Double(i) / 30) }
        #expect(lean.steerSpeed < -0.3, "a trunk lean steers: \(lean.steerSpeed)")
    }
}
