import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// K03 upper body from what E07 really delivers: 14 joints, no elbows or knees,
/// no `visual` crown/sole/centre, no airborne evidence. Retargeter level, at
/// the camera's 30 Hz, in direction-only aspect-corrected image units unless
/// a test says otherwise.
@MainActor
struct K03HeadTurnTests {
    private static let dt = 1.0 / 30

    /// A front-facing person in canonical image space (Y up), head turned
    /// toward the player's right by `turn` degrees (the nose moves toward the
    /// image's left, since the image is unmirrored), with `hipDrop` lowering
    /// the hips and shoulders.
    private static func person(turn: Double = 0, x: Double = 0.5, hipDrop: Double = 0,
                               ears: Bool = true, confidence: Double = 0.9,
                               rightShoulderUp: Double = 0, shoulderHalfWidth: Double = 0.09,
                               lean: Double = 0) -> RobotRetargeter.Observation {
        var o = RobotRetargeter.Observation()
        func put(_ joint: PresentationJoint, _ px: Double, _ py: Double) {
            o.joints[joint] = PresentationPoint(x: px, y: py, confidence: confidence)
        }
        let yaw = turn * .pi / 180, half = 0.035
        put(.nose, x - RobotRetargeter.noseDepthPerHalfEarSpan * half * sin(yaw), 0.86 - hipDrop)
        if ears {
            put(.leftEar, x + half * cos(yaw), 0.87 - hipDrop)
            put(.rightEar, x - half * cos(yaw), 0.87 - hipDrop)
        }
        put(.neck, x, 0.78 - hipDrop)
        put(.leftShoulder, x + shoulderHalfWidth, 0.77 - hipDrop)
        put(.rightShoulder, x - shoulderHalfWidth, 0.77 - hipDrop + rightShoulderUp)
        put(.leftWrist, x + 0.11, 0.5 - hipDrop); put(.rightWrist, x - 0.11, 0.5 - hipDrop)
        put(.leftHip, x + 0.06, 0.5 - hipDrop); put(.rightHip, x - 0.06, 0.5 - hipDrop)
        put(.leftAnkle, x + 0.06, 0.06); put(.rightAnkle, x - 0.06, 0.06)
        // A rigid trunk lean toward the player's right (the image's left) about the hip centre.
        if lean != 0 {
            let a = lean * .pi / 180, pivot = SIMD2(x, 0.5 - hipDrop)
            for joint in [PresentationJoint.nose, .leftEar, .rightEar, .neck, .leftShoulder, .rightShoulder,
                          .leftWrist, .rightWrist] {
                guard let q = o.joints[joint] else { continue }
                let d = SIMD2(q.x, q.y) - pivot
                let r = SIMD2(d.x * cos(a) - d.y * sin(a), d.x * sin(a) + d.y * cos(a)) + pivot
                o.joints[joint] = PresentationPoint(x: r.x, y: r.y, confidence: q.confidence)
            }
        }
        return o
    }

    private static func feed(_ r: inout RobotRetargeter, _ o: RobotRetargeter.Observation?, from t: Double, frames: Int) -> Double {
        var t = t
        for _ in 0..<frames { t += dt; r.update(o, time: t) }
        return t
    }

    private static func retargeter(_ reference: AvatarReference? = nil) -> RobotRetargeter {
        RobotRetargeter(reference: reference, robotLegRest: 0.5)
    }

    @Test("Facing the camera, the head looks straight ahead")
    func facingTheCameraIsStraight() {
        var r = Self.retargeter()
        _ = Self.feed(&r, Self.person(), from: 0, frames: 20)
        #expect(abs(r.targets.headYaw) < 1e-4)
    }

    @Test("Turning to the player's right turns the robot's head to its right (screen right)")
    func turnFollowsTheNoseBetweenTheEars() {
        var r = Self.retargeter()
        _ = Self.feed(&r, Self.person(turn: 25), from: 0, frames: 20)
        let right = r.targets.headYaw
        #expect(abs(right - 25 * .pi / 180) < 0.03, "\(right)")
        var l = Self.retargeter()
        _ = Self.feed(&l, Self.person(turn: -25), from: 0, frames: 20)
        #expect(abs(l.targets.headYaw + right) < 1e-3, "symmetric")
    }

    @Test("The turn needs no standing reference: distance and lane don't change it")
    func turnIsScaleFree() {
        var near = Self.retargeter(), far = Self.retargeter()
        var nearPose = Self.person(turn: 20, x: 0.3), farPose = Self.person(turn: 20, x: 0.7)
        // Farther away: the same body at 60 % size about its own centre.
        for (joint, point) in farPose.joints {
            farPose.joints[joint] = PresentationPoint(x: 0.7 + (point.x - 0.7) * 0.6, y: 0.5 + (point.y - 0.5) * 0.6,
                                                      confidence: point.confidence)
        }
        nearPose.calibrated = false
        _ = Self.feed(&near, nearPose, from: 0, frames: 20)
        _ = Self.feed(&far, farPose, from: 0, frames: 20)
        #expect(abs(near.targets.headYaw - far.targets.headYaw) < 0.01)
    }

    @Test("A large turn is limited; a tiny one is damped")
    func turnIsClampedAndDeadbanded() {
        var r = Self.retargeter()
        _ = Self.feed(&r, Self.person(turn: 55), from: 0, frames: 20)
        #expect(abs(r.targets.headYaw - r.maximumHeadYaw) < 1e-4)
        var small = Self.retargeter()
        _ = Self.feed(&small, Self.person(turn: 1), from: 0, frames: 20)
        #expect(abs(small.targets.headYaw) < 0.6 * .pi / 180, "the soft zone damps jitter-sized turns")
    }

    @Test("An ear line that collapses (one ear hidden) is not trusted")
    func collapsedEarLineIsIgnored() {
        var r = Self.retargeter()
        _ = Self.feed(&r, Self.person(turn: 80), from: 0, frames: 20)
        #expect(r.targets.headYaw == 0)
    }

    @Test("Without ears the turn eases back to straight instead of holding an old look")
    func missingEarsReleaseTheTurn() {
        var r = Self.retargeter()
        var t = Self.feed(&r, Self.person(turn: 25), from: 0, frames: 20)
        let held = r.targets.headYaw
        t = Self.feed(&r, Self.person(turn: 25, ears: false), from: t, frames: 2)
        #expect(abs(r.targets.headYaw - held) < 1e-4, "a brief gap holds")
        _ = Self.feed(&r, Self.person(turn: 25, ears: false), from: t, frames: 30)
        #expect(abs(r.targets.headYaw) < 0.05 * held)
    }

    @Test("Low-confidence head joints never turn the head")
    func lowConfidenceIsIgnored() {
        var r = Self.retargeter()
        _ = Self.feed(&r, Self.person(turn: 25, confidence: 0.1), from: 0, frames: 20)
        #expect(r.targets.headYaw == 0)
    }

    @Test("Tracking loss fades the turn out with the rest of the pose")
    func lossFadesTheTurn() {
        var r = Self.retargeter()
        let t = Self.feed(&r, Self.person(turn: 25), from: 0, frames: 20)
        _ = Self.feed(&r, nil, from: t, frames: 45)
        #expect(!r.isAvailable && abs(r.targets.headYaw) < 0.01)
    }

    @Test("The solver turns only the head: shoulders, arms, pelvis and feet stay put")
    func solverTurnsOnlyTheHead() async throws {
        let model = try #require(RobotAvatarLayer.skinnedModel(in: try await RobotAvatarLayer.loadTemplate(for: .player1)))
        let skeleton = RobotSkeleton(paths: model.jointNames, bind: model.jointTransforms)
        let solver = RobotPoseSolver(skeleton: skeleton)
        var turned = RobotPoseTargets.rest
        turned.headYaw = 0.5
        let rest = solver.solve(.rest), solved = solver.solve(turned)
        for (index, path) in skeleton.paths.enumerated() {
            if path.hasSuffix("/Head") {
                #expect(abs(simd_dot(rest[index].rotation.vector, solved[index].rotation.vector)) < 0.999)
            } else {
                #expect(simd_distance(rest[index].translation, solved[index].translation) < 1e-6
                        && abs(simd_dot(rest[index].rotation.vector, solved[index].rotation.vector)) > 0.99999, "\(path)")
            }
        }
    }

    // MARK: - Shrug (shoulder line beyond the lean)

    @Test("Level shoulders and a rigid lean show no shrug; the lean stays a lean")
    func levelAndRigidLeanHaveNoShrug() {
        var level = Self.retargeter()
        _ = Self.feed(&level, Self.person(), from: 0, frames: 20)
        #expect(abs(level.targets.shoulderShrug) < 1e-4)
        var leaning = Self.retargeter()
        _ = Self.feed(&leaning, Self.person(lean: 12), from: 0, frames: 20)
        #expect(abs(leaning.targets.lean) > 0.15, "\(leaning.targets.lean)")
        #expect(abs(leaning.targets.shoulderShrug) < 0.01, "\(leaning.targets.shoulderShrug)")
    }

    @Test("Raising the player's right shoulder lifts only the robot's right (screen-right) collarbone")
    func raisedShoulderShrugs() async throws {
        var r = Self.retargeter()
        _ = Self.feed(&r, Self.person(rightShoulderUp: 0.03), from: 0, frames: 20)
        #expect(r.targets.shoulderShrug > 0.1, "\(r.targets.shoulderShrug)")
        let model = try #require(RobotAvatarLayer.skinnedModel(in: try await RobotAvatarLayer.loadTemplate(for: .player1)))
        let skeleton = RobotSkeleton(paths: model.jointNames, bind: model.jointTransforms)
        let solver = RobotPoseSolver(skeleton: skeleton)
        let world = skeleton.world(solver.solve(r.targets)).position
        let rest = skeleton.world(solver.solve(.rest)).position
        let right = try #require(skeleton("UpperArm_R"))
        #expect(world[right].y > rest[right].y + 0.015, "the raised side's arm root lifts")
        // A one-sided shrug: the other shoulder, the trunk, the head and the pelvis stay where they were.
        for name in ["UpperArm_L", "Chest", "Neck", "Head", "Pelvis"] {
            let joint = try #require(skeleton(name))
            #expect(simd_distance(world[joint], rest[joint]) < 1e-5, "\(name) moved")
        }
    }

    @Test("A body turned side-on (stacked shoulders) shows no shrug")
    func sideOnShouldersAreIgnored() {
        var r = Self.retargeter()
        _ = Self.feed(&r, Self.person(rightShoulderUp: 0.03, shoulderHalfWidth: 0.02), from: 0, frames: 20)
        #expect(r.targets.shoulderShrug == 0)
    }

    @Test("A large shrug is limited, and it fades with tracking loss")
    func shrugIsClampedAndFades() {
        var r = Self.retargeter()
        let t = Self.feed(&r, Self.person(rightShoulderUp: 0.12), from: 0, frames: 20)
        #expect(abs(r.targets.shoulderShrug - r.maximumShoulderShrug) < 1e-4)
        _ = Self.feed(&r, nil, from: t, frames: 45)
        #expect(abs(r.targets.shoulderShrug) < 0.01)
    }

    // MARK: - Crouch: only with accepted calibration

    @Test("Direction-only hips that drop never crouch the robot or lift its root")
    func directionOnlyNeverCrouches() {
        var r = Self.retargeter()
        _ = Self.feed(&r, Self.person(hipDrop: 0.15), from: 0, frames: 30)
        #expect(r.targets.pelvisDrop == 0 && r.lift == 0)
        #expect(r.targets.footLift.values.allSatisfy { $0 == 0 })
    }

    @Test("A calibrated packet as the factory sends it today (no visual values) crouches from hips and ankles only")
    func calibratedCrouchWithoutVisual() {
        // Game units: standing hips 0.9, ankles 0.08 (accepted calibration).
        let reference = AvatarReference(playerID: .player1, calibrationRevision: 1, standingHeight: 1.6, standingHipY: 0.9,
                                        standingLeftAnkleY: 0.08, standingRightAnkleY: 0.08, laneCenterX: -0.65)
        func calibrated(hipY: Double) -> RobotRetargeter.Observation {
            var o = RobotRetargeter.Observation()
            func put(_ joint: PresentationJoint, _ x: Double, _ y: Double) {
                o.joints[joint] = PresentationPoint(x: x, y: y, confidence: 0.9)
            }
            put(.leftHip, -0.55, hipY); put(.rightHip, -0.75, hipY)
            put(.leftAnkle, -0.55, 0.08); put(.rightAnkle, -0.75, 0.08)
            o.calibrated = true   // no lowerSoleY, centerX, crownY or airborne: the factory sends visual: nil
            return o
        }
        var r = Self.retargeter(reference)
        var t = Self.feed(&r, calibrated(hipY: 0.9), from: 0, frames: 30)
        #expect(r.targets.pelvisDrop < 0.005)
        t = Self.feed(&r, calibrated(hipY: 0.75), from: t, frames: 30)   // hips 15 cm lower, ~18 % of the leg
        #expect(r.targets.pelvisDrop > 0.06 && r.lift == 0, "\(r.targets.pelvisDrop)")
        _ = Self.feed(&r, calibrated(hipY: 0.9), from: t, frames: 30)
        #expect(r.targets.pelvisDrop < 0.01, "recovers to standing")
    }
}

/// The new head and shoulder values through the real K03 path (packets →
/// mailbox → layer), driven by the deterministic `head-turn` demo frames.
@MainActor
struct K03UpperBodyLifecycleTests {
    private struct Rig {
        let sequence: RobotDemoSequence
        let source: SyntheticAvatarSource
        let layer: RobotAvatarLayer
        let mailbox = AvatarPoseMailbox(maxAge: 0.25)

        init() async throws {
            let input = try LaserReplayScript.load().input
            sequence = RobotDemoSequence(configuration: input.configuration,
                                         cameraGeometryRevision: input.cameraGeometryRevision, only: .headTurn)
            source = SyntheticAvatarSource(configuration: input.configuration,
                                           cameraGeometryRevision: input.cameraGeometryRevision)
            layer = RobotAvatarLayer(scene: LaserScene(), players: Set(PlayerID.allCases),
                                     templates: try await RobotAvatarLayer.sharedTemplates())
            mailbox.publish(source.status)
        }

        /// Feeds demo frames, optionally marking P1 as needing a rebind.
        @discardableResult
        func feed(_ frames: ClosedRange<UInt64>, p1Rebind: Bool = false) throws -> Double {
            var now = 0.0
            for index in frames {
                let frame = try sequence.frame(index)
                var output = source.output(frame.snapshot, joints: frame.joints)
                if p1Rebind {
                    output = AvatarSourceOutput(source: output.source, contextRevision: output.contextRevision,
                                                player1: AvatarTrackedSlot(state: .tracking, candidateID: output.player1.candidateID,
                                                                           requiresRebind: true),
                                                player2: output.player2, candidates: output.candidates,
                                                calibration: output.calibration)
                }
                mailbox.offer(output)
                now = frame.snapshot.capturedAt + 0.005
                layer.apply(mailbox.drain(now: now), now: now)
            }
            return now
        }

        func targets(_ player: PlayerID) -> RobotPoseTargets { layer.robots[player]!.retargeter.targets }
    }

    @Test("Both players turn at once, each their own way; only P1's raised shoulder shrugs")
    func playersAreIndependent() async throws {
        let rig = try await Rig()
        try rig.feed(1...36)   // t = 1.2 s: P1 turned right with its right shoulder up; P2 turned left, leaning
        #expect(rig.targets(.player1).headYaw > 0.3 && rig.targets(.player2).headYaw < -0.3)
        #expect(rig.targets(.player1).shoulderShrug > 0.05)
        #expect(abs(rig.targets(.player2).shoulderShrug) < 0.02, "a rigid lean is a lean, not a shrug")
    }

    @Test("A rebind relaxes that player's turn and shrug to neutral; the partner keeps theirs")
    func rebindRelaxesOnlyThatPlayer() async throws {
        let rig = try await Rig()
        try rig.feed(1...36)
        try rig.feed(37...78, p1Rebind: true)   // 1.4 s: past the hold and the 0.3 s fade-out
        #expect(abs(rig.targets(.player1).headYaw) < 0.02 && abs(rig.targets(.player1).shoulderShrug) < 0.01)
        #expect(rig.targets(.player2).headYaw < -0.3)
    }

    @Test("Stopping the source resets both players at once: no held turn or shrug")
    func stopResetsAtOnce() async throws {
        let rig = try await Rig()
        let now = try rig.feed(1...36)
        rig.mailbox.publish(AvatarSourceStatus(revision: rig.source.statusRevision + 1, isActive: false, context: nil,
                                               controlRevision: rig.source.controlRevision, layout: nil, calibrations: [:]))
        rig.layer.apply(rig.mailbox.drain(now: now + 0.01), now: now + 0.01)
        for player in PlayerID.allCases {
            #expect(rig.targets(player).headYaw == 0 && rig.targets(player).shoulderShrug == 0)
        }
    }

    @Test("Expired packets fade the turn out instead of holding it")
    func expiryFadesOut() async throws {
        let rig = try await Rig()
        var now = try rig.feed(1...36)
        for _ in 0..<60 {
            now += 1.0 / 60
            rig.layer.apply(rig.mailbox.drain(now: now), now: now)
        }
        #expect(abs(rig.targets(.player1).headYaw) < 0.02 && abs(rig.targets(.player2).headYaw) < 0.02)
    }
}
