import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// Live Avatar Lab logic with SYNTHETIC Vision-shaped joints (no camera in
/// tests). Joints follow Vision's convention: upright, unmirrored image,
/// normalized, origin bottom-left. A person facing the camera has their
/// anatomical LEFT on the image's RIGHT (+x).
@MainActor
struct LiveAvatarTests {
    private let aspect = 16.0 / 9
    private let degree = Float.pi / 180

    /// A synthetic standing person centred at image x `cx`, feet at `floor`, `h` image heights tall.
    private struct Body {
        var cx = 0.5, floor = 0.08, h = 0.8
        var lift = 0.0, crouch = 0.0, step = 0.0, lean = 0.0
        var leftArm = 0.0, rightArm = 0.0  // degrees from hanging, outward
        var leftFootLift = 0.0
        var missing: Set<LiveJoint> = []

        func person(aspect: Double) -> LivePerson {
            let x = cx + step, base = floor + lift, sx = h / aspect  // image-x per image-height
            let upper = { (y: Double) in base + y * h - crouch * h }
            let leanX = { (y: Double) in -self.lean * (y - 0.5) * sx }  // + lean: toward the player's right = image left
            let shoulderY = upper(0.78), hipY = base + 0.5 * h - crouch * h * 0.6
            func arm(_ left: Bool, _ deg: Double) -> (Double, Double) {
                let s = left ? 1.0 : -1.0, r = deg * .pi / 180
                return (x + leanX(0.78) + s * 0.1 * sx + s * 0.32 * sx * sin(r), shoulderY - 0.32 * h * cos(r))
            }
            let lw = arm(true, leftArm), rw = arm(false, rightArm)
            var j: [LiveJoint: LivePoint] = [
                .nose: .init(x: x + leanX(0.9), y: upper(0.9), confidence: 0.9),
                .neck: .init(x: x + leanX(0.8), y: upper(0.8), confidence: 0.9),
                .leftEar: .init(x: x + leanX(0.9) + 0.04 * sx, y: upper(0.89), confidence: 0.8),
                .rightEar: .init(x: x + leanX(0.9) - 0.04 * sx, y: upper(0.89), confidence: 0.8),
                .leftShoulder: .init(x: x + leanX(0.78) + 0.1 * sx, y: shoulderY, confidence: 0.9),
                .rightShoulder: .init(x: x + leanX(0.78) - 0.1 * sx, y: shoulderY, confidence: 0.9),
                .leftWrist: .init(x: lw.0, y: lw.1, confidence: 0.9), .rightWrist: .init(x: rw.0, y: rw.1, confidence: 0.9),
                .root: .init(x: x, y: hipY, confidence: 0.9),
                .leftHip: .init(x: x + 0.05 * sx, y: hipY, confidence: 0.9), .rightHip: .init(x: x - 0.05 * sx, y: hipY, confidence: 0.9),
                .leftKnee: .init(x: x + 0.05 * sx, y: base + 0.27 * h, confidence: 0.9),
                .rightKnee: .init(x: x - 0.05 * sx, y: base + 0.27 * h, confidence: 0.9),
                .leftAnkle: .init(x: x + 0.05 * sx, y: base + 0.04 * h + leftFootLift, confidence: 0.9),
                .rightAnkle: .init(x: x - 0.05 * sx, y: base + 0.04 * h, confidence: 0.9),
            ]
            for m in missing { j[m] = nil }
            return LivePerson(joints: j)
        }
    }

    private func frame(_ id: UInt64, _ bodies: [Body]) -> LiveBodyFrame {
        LiveBodyFrame(frameID: id, capturedAt: Double(id) / 30, visionCompletedAt: Double(id) / 30 + 0.03,
                      imageAspect: aspect, cameraGeometryRevision: 1, people: bodies.map { $0.person(aspect: aspect) })
    }

    /// A tracker calibrated from 1.5 s of steady stance, plus the frame counter.
    private func calibrated(_ bodies: [Body], mode: LiveAvatarMode) throws -> (LiveAvatarTracker, UInt64) {
        var tracker = LiveAvatarTracker(sessionGeneration: UUID(), mode: mode)
        var calibrator = LiveCalibrator(players: mode.players, at: 0)
        for id in UInt64(1)...60 {
            let f = frame(id, bodies)
            let processed = tracker.process(f, now: f.capturedAt + 0.05)
            let out = try #require(processed)
            if let stances = calibrator.add(out.assigned, frame: f) {
                try tracker.calibrate(stances, frame: f)
                return (tracker, id)
            }
        }
        Issue.record("calibration did not complete")
        return (tracker, 60)
    }

    /// The robot layer the Live Avatar Lab uses, as the readout for live tracking.
    private func layer(for tracker: LiveAvatarTracker) async throws -> RobotAvatarLayer {
        let template = try #require(await RobotAvatarLayer.loadTemplate())
        return RobotAvatarLayer(scene: LaserScene(), calibrations: tracker.calibrations, layout: tracker.layout, template: template)
    }

    /// What one robot shows: lift and sway (metres), lean (radians, + toward screen right),
    /// pelvis drop (model metres) and each arm's elevation from hanging (degrees).
    private struct Shown {
        let robot: RobotAvatarLayer.Robot
        var r: RobotRetargeter { robot.retargeter }
        var lift: Float { r.lift }
        var sway: Float { r.sway }
        var lean: Float { r.targets.lean }
        var pelvisDrop: Float { r.targets.pelvisDrop }
        var isAvailable: Bool { r.isAvailable }
        var opacity: Float? { robot.container.components[OpacityComponent.self]?.opacity }
        func raise(_ side: RobotPoseTargets.Side) -> Float {
            guard let d = r.targets.upperArm[side] else { return 0 }
            let outward = side == .left ? -d.x : d.x  // the robot's left is −X, screen left from behind
            return atan2(outward, -d.y) * 180 / .pi
        }
    }

    /// Feeds frames and returns P1's (and P2's) final rig poses.
    private func run(_ tracker: inout LiveAvatarTracker, _ layer: RobotAvatarLayer, from: UInt64, count: UInt64,
                     _ bodies: [Body]) -> [PlayerID: Shown] {
        for id in from..<(from + count) {
            let f = frame(id, bodies)
            if let out = tracker.process(f, now: f.capturedAt + 0.05) { layer.apply(out.snapshot, joints: out.joints) }
        }
        return layer.robots.mapValues(Shown.init)
    }

    // MARK: - Calibration

    @Test func steadyStandingCalibratesAndScalesToTheReferenceHeight() throws {
        let (tracker, _) = try calibrated([Body()], mode: .single)
        let c = try #require(tracker.calibrations[.player1])
        try c.validate()
        #expect(c.standingCrownImageY > c.standingHipImageY && c.mapping.imageAspectRatio == aspect)
        #expect(abs(c.standingBodyImageHeight * tracker.layout.gameUnitsPerImageHeight - LiveAvatarTracker.referenceHeight) < 1e-9)
        #expect(tracker.calibrations[.player2] == nil)
    }

    @Test func calibrationRejectsMovementAndMissingFeet() throws {
        var tracker = LiveAvatarTracker(sessionGeneration: UUID(), mode: .single)
        var calibrator = LiveCalibrator(players: [.player1], at: 0)
        var noFeet = Body()
        noFeet.missing = [.leftAnkle, .rightAnkle]
        for id in UInt64(1)...40 {
            let f = frame(id, [noFeet])
            let processed = tracker.process(f, now: f.capturedAt)
            #expect(calibrator.add(try #require(processed).assigned, frame: f) == nil)
        }
        #expect(calibrator.issue[.player1] == .feetNotVisible)
        for id in UInt64(41)...80 {
            var moving = Body()
            moving.lift = id.isMultiple(of: 2) ? 0.06 : 0
            let f = frame(id, [moving])
            let processed = tracker.process(f, now: f.capturedAt)
            #expect(calibrator.add(try #require(processed).assigned, frame: f) == nil)
        }
        #expect(calibrator.issue[.player1] == .moving)
        let late = LiveBodyFrame(frameID: 999, capturedAt: 11, visionCompletedAt: 11, imageAspect: aspect, cameraGeometryRevision: 1, people: [])
        _ = calibrator.add([:], frame: late)
        #expect(calibrator.timedOut)
    }

    @Test func recalibrationIssuesANewRevisionAndOldDataIsRejected() async throws {
        var (tracker, last) = try calibrated([Body()], mode: .single)
        let first = try #require(tracker.calibrations[.player1])
        let old = try await layer(for: tracker)
        let f = frame(last + 1, [Body()])
        let stances = [PlayerID.player1: LiveStance(noseY: 0.8, neckY: 0.73, shoulderY: 0.71, leftAnkleY: 0.11, rightAnkleY: 0.11, centerX: 0.5, centerY: 0.48)]
        try tracker.calibrate(stances, frame: f)
        let second = try #require(tracker.calibrations[.player1])
        #expect(second.revision > first.revision)
        // A rig built on the old calibration treats new-revision samples as unavailable.
        let processed = tracker.process(frame(last + 2, [Body()]), now: Double(last + 2) / 30)
        let out = try #require(processed)
        var stale = try #require(old.robots[.player1]).retargeter
        stale.update(sample: out.snapshot.players[.player1], joints: out.joints.players[.player1], time: 1)
        #expect(!stale.isAvailable)
    }

    // MARK: - Anatomical left/right and mirroring

    /// Raising the RIGHT arm raises the avatar's RIGHT arm (screen right in the
    /// rear view), and the LEFT arm the LEFT; the other stays down.
    @Test func eachArmDrivesTheSameAnatomicalArm() async throws {
        var (tracker, last) = try calibrated([Body()], mode: .single)
        let layer = try await layer(for: tracker)
        var right = Body()
        right.rightArm = 90
        var p = run(&tracker, layer, from: last + 1, count: 15, [right])[.player1]!
        #expect(p.raise(.right) > 60 && p.raise(.left) < 10)  // the robot's right arm: up and out to screen right
        var left = Body()
        left.leftArm = 170
        p = run(&tracker, layer, from: last + 16, count: 15, [left])[.player1]!
        #expect(p.raise(.left) > 120 && p.raise(.right) < 10)  // the robot's left arm: up and out to screen left
        var both = Body()
        both.leftArm = 90; both.rightArm = 90
        p = run(&tracker, layer, from: last + 31, count: 15, [both])[.player1]!
        #expect(p.raise(.left) > 60 && p.raise(.right) > 60 && abs(p.raise(.left) - p.raise(.right)) < 5)
    }

    /// Stepping or leaning to the player's own right moves the avatar to screen right, once mirrored.
    @Test func stepsAndLeansFollowThePlayersOwnRight() async throws {
        var (tracker, last) = try calibrated([Body()], mode: .single)
        let layer = try await layer(for: tracker)
        var step = Body()
        step.step = -0.05  // the player's right is the unmirrored image's left
        var p = run(&tracker, layer, from: last + 1, count: 20, [step])[.player1]!
        #expect(p.sway > 0.05)
        var lean = Body()
        lean.lean = 0.3
        p = run(&tracker, layer, from: last + 21, count: 20, [lean])[.player1]!
        #expect(p.lean > 3 * degree)  // the trunk tips toward screen right
    }

    // MARK: - Jump and duck

    @Test func jumpNeedsRealLiftAndLandsAtIdle() async throws {
        var (tracker, last) = try calibrated([Body()], mode: .single)
        let layer = try await layer(for: tracker)
        // Noise and tiptoes (3% of height) never read as a jump.
        var small = Body()
        small.lift = 0.024
        var p = run(&tracker, layer, from: last + 1, count: 5, [small])[.player1]!
        #expect(p.lift == 0 && !tracker.airborne(.player1))
        // A real jump: 15% of standing height → the rig rises by that much (P1 stands 1.6 m).
        var jump = Body()
        jump.lift = 0.12
        p = run(&tracker, layer, from: last + 6, count: 3, [jump])[.player1]!
        #expect(tracker.airborne(.player1) && abs(p.lift - Float(0.12 / 0.8 * 1.6)) < 0.01)
        // Landing: back on the floor, back at idle.
        p = run(&tracker, layer, from: last + 9, count: 3, [Body()])[.player1]!
        #expect(!tracker.airborne(.player1) && p.lift == 0 && p.pelvisDrop < 0.005)
    }

    @Test func crouchDepthIsContinuousAndStandingRestores() async throws {
        var (tracker, last) = try calibrated([Body()], mode: .single)
        let layer = try await layer(for: tracker)
        var depths: [Float] = []
        for (n, crouch) in [0.01, 0.05, 0.08, 0.11].enumerated() {
            var b = Body()
            b.crouch = crouch
            let p = run(&tracker, layer, from: last + 1 + UInt64(n) * 5, count: 5, [b])[.player1]!
            depths.append(p.pelvisDrop)
            #expect(p.lift == 0 && p.isAvailable)
        }
        #expect(depths[0] == 0)  // within the noise deadband
        #expect(depths[1] > 0 && depths[2] > depths[1] && depths[3] > depths[2])
        let p = run(&tracker, layer, from: last + 30, count: 5, [Body()])[.player1]!
        #expect(p.pelvisDrop < 0.005)
    }

    // MARK: - Frames, loss and identity

    @Test func staleDuplicateAndOutOfOrderFramesAreDropped() throws {
        var (tracker, last) = try calibrated([Body()], mode: .single)
        let f = frame(last + 1, [Body()])
        let fresh = tracker.process(f, now: f.capturedAt + 0.05)
        let duplicate = tracker.process(f, now: f.capturedAt + 0.05)
        let older = tracker.process(frame(last, [Body()]), now: f.capturedAt)
        let stale = frame(last + 2, [Body()])
        let late = tracker.process(stale, now: stale.capturedAt + 0.4)
        #expect(fresh != nil && duplicate == nil && older == nil && late == nil)
        #expect(tracker.orderDrops == 2 && tracker.staleDrops == 1)
    }

    /// Edo's FrameStore restarts frame IDs at 1 with each camera session
    /// (e.g. back from the background); the restarted IDs must not be dropped.
    @Test func aNewCameraSessionAcceptsRestartedFrameIDs() throws {
        var (tracker, last) = try calibrated([Body()], mode: .single)
        for id in last + 1...last + 5 {
            let f = frame(id, [Body()])
            _ = tracker.process(f, now: f.capturedAt + 0.05)
        }
        tracker.beginCameraSession()
        var raised = Body()
        raised.rightArm = 90
        let restarted = LiveBodyFrame(frameID: 1, capturedAt: 100, visionCompletedAt: 100.03, imageAspect: aspect,
                                      cameraGeometryRevision: 1, people: [raised.person(aspect: aspect)])
        let out = tracker.process(restarted, now: 100.05)
        #expect(out != nil && tracker.calibrations[.player1] != nil)  // calibration survives the restart
        #expect(tracker.orderDrops == 0)
    }

    @Test func labExplainsCameraAndTrackingFailures() throws {
        #expect(LiveAvatarLabModel.describe(CameraFailure.permissionDenied).contains("Settings"))
        #expect(LiveAvatarLabModel.unavailableReason(nil) == "no sample")
        let (tracker, _) = try calibrated([Body()], mode: .single)
        var copy = tracker
        var noFeet = Body()
        noFeet.missing = [.leftAnkle, .rightAnkle]
        let feetMissing = copy.process(frame(500, [noFeet]), now: Double(500) / 30)
        let out = try #require(feetMissing)
        #expect(LiveAvatarLabModel.unavailableReason(out.snapshot.players[.player1]) == "feet not visible")
        let nobody = copy.process(frame(501, []), now: Double(501) / 30)
        let gone = try #require(nobody)
        #expect(LiveAvatarLabModel.unavailableReason(gone.snapshot.players[.player1]) == "not detected")
    }

    @Test func trackingLossNeverInventsMovementAndRecovers() async throws {
        var (tracker, last) = try calibrated([Body()], mode: .single)
        let layer = try await layer(for: tracker)
        var raised = Body()
        raised.rightArm = 90
        _ = run(&tracker, layer, from: last + 1, count: 10, [raised])
        var p = run(&tracker, layer, from: last + 11, count: 30, [])[.player1]!  // 1 s with nobody in view
        #expect(!p.isAvailable && p.lift < 0.001 && p.pelvisDrop < 0.005 && p.raise(.right) == 0)  // back to the bind pose
        #expect(p.opacity == RobotAvatarLayer.unavailableOpacity)  // dimmed while unavailable
        p = run(&tracker, layer, from: last + 41, count: 3, [Body()])[.player1]!
        #expect(p.isAvailable && p.raise(.right) < 10 && p.opacity == 1)
    }

    @Test func twoPlayersKeepTheirSlotsWhenTheyCross() throws {
        // P1 is screen-left = image-right.
        var (tracker, last) = try calibrated([Body(cx: 0.7, h: 0.8), Body(cx: 0.3, h: 0.6)], mode: .two)
        #expect(tracker.calibrations.count == 2)
        let p2Height = try #require(tracker.calibrations[.player2]).standingBodyImageHeight * tracker.layout.gameUnitsPerImageHeight
        #expect(abs(p2Height - 1.2) < 0.02)  // relative heights preserved
        // They walk past each other: tall moves left, short moves right, 0.02 per frame.
        for n in 0..<20 {
            let id = last + 1 + UInt64(n)
            let a = Body(cx: 0.7 - 0.02 * Double(n), h: 0.8), b = Body(cx: 0.3 + 0.02 * Double(n), h: 0.6)
            let processed = tracker.process(frame(id, n.isMultiple(of: 3) ? [b, a] : [a, b]), now: Double(id) / 30)
            let out = try #require(processed)
            let tall = out.assigned[.player1]?.point(.nose)?.y, short = out.assigned[.player2]?.point(.nose)?.y
            #expect(tall != nil && short != nil && tall! > short!)
        }
    }

    @Test func playersMoveIndependently() async throws {
        var (tracker, last) = try calibrated([Body(cx: 0.7), Body(cx: 0.3)], mode: .two)
        let layer = try await layer(for: tracker)
        var jumper = Body(cx: 0.7), croucher = Body(cx: 0.3)
        jumper.lift = 0.12; croucher.crouch = 0.09
        let poses = run(&tracker, layer, from: last + 1, count: 6, [jumper, croucher])
        let p1 = try #require(poses[.player1]), p2 = try #require(poses[.player2])
        #expect(p1.lift > 0.2 && p1.pelvisDrop < 0.01)
        #expect(p2.lift == 0 && p2.pelvisDrop > 0.03)
    }

    @Test func singlePlayerModeNeedsOnlyOnePerson() async throws {
        let (tracker, _) = try calibrated([Body()], mode: .single)
        let layer = try await layer(for: tracker)
        #expect(layer.robots.keys.sorted { $0.rawValue < $1.rawValue } == [.player1])
    }
}
