import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// The 3D robot avatar: the Codex USDZ imported into the iOS app, its 20-joint
/// skeleton driven through `jointTransforms`, and human-to-robot retargeting.
/// Inputs are SYNTHETIC (constructed joints or the demo sequence).
@MainActor
struct RobotAvatarTests {
    private func template() async throws -> Entity {
        try await RobotAvatarLayer.loadTemplate(for: .player1)
    }

    private func templates() async throws -> [PlayerID: Entity] {
        try await RobotAvatarLayer.loadTemplates()
    }

    private func rig() async throws -> (ModelEntity, RobotSkeleton, RobotPoseSolver) {
        let model = try #require(RobotAvatarLayer.skinnedModel(in: try await template()))
        let skeleton = RobotSkeleton(paths: model.jointNames, bind: model.jointTransforms)
        return (model, skeleton, RobotPoseSolver(skeleton: skeleton))
    }

    private func world(_ s: RobotSkeleton, _ locals: [Transform], _ joint: String) throws -> SIMD3<Float> {
        s.world(locals).position[try #require(s(joint))]
    }

    // MARK: - Import

    @Test func usdzImportsWithAllTwentyControllableJoints() async throws {
        let (model, skeleton, _) = try await rig()
        #expect(model.jointNames.count == 20)
        for name in RobotSkeleton.requiredJoints { #expect(skeleton(name) != nil, "missing \(name)") }
        // Every joint can be written and read back independently.
        var transforms = model.jointTransforms
        for i in transforms.indices {
            var changed = transforms
            changed[i].rotation = simd_quatf(angle: 0.3, axis: [1, 0, 0]) * changed[i].rotation
            model.jointTransforms = changed
            #expect(abs(simd_dot(model.jointTransforms[i].rotation.vector, changed[i].rotation.vector)) > 0.9999)
        }
        model.jointTransforms = transforms
        transforms = model.jointTransforms
        // Bind pose: anatomical right on +X (screen right from behind), the
        // trunk stacked upward from the root at the deck, knees forward (−Z).
        let bind = skeleton.world(skeleton.bind).position
        #expect(bind[skeleton("Hand_R")!].x > 0 && bind[skeleton("Hand_L")!].x < 0)
        #expect(abs(bind[skeleton("Root")!].y) < 1e-4)
        #expect(bind[skeleton("Head")!].y > bind[skeleton("Chest")!].y && bind[skeleton("Chest")!].y > bind[skeleton("Pelvis")!].y)
        #expect(bind[skeleton("Shin_L")!].z <= 0 && bind[skeleton("Shin_R")!].z <= 0)
        // The mesh: `RobotSkeleton.modelHeight` tall, soles on the deck (y = 0).
        let bounds = try await template().visualBounds(relativeTo: nil)
        #expect(abs(bounds.extents.y - RobotSkeleton.modelHeight) < 0.005, "height \(bounds.extents.y)")
        #expect(abs(bounds.min.y) < 0.005, "sole \(bounds.min.y)")
    }

    @Test func twoInstancesPoseIndependently() async throws {
        let base = try await template()
        let a = try #require(RobotAvatarLayer.skinnedModel(in: base.clone(recursive: true)))
        let b = try #require(RobotAvatarLayer.skinnedModel(in: base.clone(recursive: true)))
        let solver = RobotPoseSolver(skeleton: RobotSkeleton(paths: a.jointNames, bind: a.jointTransforms))
        let bindB = b.jointTransforms
        var t = RobotPoseTargets()
        t.pelvisDrop = 0.15
        t.upperArm[.right] = [1, 0, 0]
        a.jointTransforms = solver.solve(t)
        #expect(zip(b.jointTransforms, bindB).allSatisfy { $0.translation == $1.translation && $0.rotation == $1.rotation })
    }

    // MARK: - Solver

    @Test func restTargetsReproduceTheBindPose() async throws {
        let (_, skeleton, solver) = try await rig()
        let posed = solver.solve(.rest)
        for (i, (p, b)) in zip(posed, skeleton.bind).enumerated() {
            let joint = skeleton.paths[i].split(separator: "/").last.map(String.init) ?? "?"
            #expect(simd_distance(p.translation, b.translation) < 1e-5, "\(joint) moved")
            #expect(abs(simd_dot(p.rotation.vector, b.rotation.vector)) > 0.9999, "\(joint) rotated")
        }
    }

    /// A right-arm target out to +X lifts the robot's RIGHT hand (screen right
    /// from behind) to shoulder height; the left arm does not move.
    @Test func armsAimTheirOwnSideOnly() async throws {
        let (_, s, solver) = try await rig()
        let rest = s.bind
        var t = RobotPoseTargets()
        t.upperArm[.right] = [1, 0, 0]
        t.forearm[.right] = [1, 0, 0]
        let posed = solver.solve(t)
        let hand = try world(s, posed, "Hand_R"), shoulder = try world(s, posed, "UpperArm_R")
        #expect(hand.x > (try world(s, rest, "Hand_R")).x + 0.1)
        #expect(abs(hand.y - shoulder.y) < 0.03)
        #expect(simd_distance(try world(s, posed, "Hand_L"), try world(s, rest, "Hand_L")) < 1e-5)
        // Segment lengths are kept (rigid bones, no stretching).
        let elbow = try world(s, posed, "Forearm_R")
        let restLength = simd_distance(try world(s, rest, "Forearm_R"), try world(s, rest, "Hand_R"))
        #expect(abs(simd_distance(elbow, hand) - restLength) < 1e-4)
    }

    @Test func crouchKeepsFeetPlantedAndBendsKneesForward() async throws {
        let (_, s, solver) = try await rig()
        var t = RobotPoseTargets()
        t.pelvisDrop = 0.2
        let posed = solver.solve(t)
        for side in ["L", "R"] {
            let foot = try world(s, posed, "Foot_\(side)"), restFoot = try world(s, s.bind, "Foot_\(side)")
            #expect(simd_distance(foot, restFoot) < 0.002, "foot \(side) slid")
            let knee = try world(s, posed, "Shin_\(side)")
            #expect(knee.z < (try world(s, s.bind, "Shin_\(side)")).z - 0.05)  // forward = −Z
        }
        #expect(abs((try world(s, posed, "Pelvis")).y - ((try world(s, s.bind, "Pelvis")).y - 0.2)) < 1e-4)
        // A raised foot (knee lift) leaves the other planted.
        t.footLift[.left] = 0.1
        let lifted = solver.solve(t)
        #expect(abs((try world(s, lifted, "Foot_L")).y - (try world(s, s.bind, "Foot_L")).y - 0.1) < 0.002)
        #expect(simd_distance(try world(s, lifted, "Foot_R"), try world(s, s.bind, "Foot_R")) < 0.002)
    }

    // MARK: - Human → robot retargeting

    private func calibration() throws -> (PlayerCalibration, PlayerPlaneLayout) {
        let input = try LaserReplayScript.load().input
        return (try #require(input.configuration.calibrations[.player1]), input.configuration.playerPlaneLayout)
    }

    private func sample(_ c: PlayerCalibration, phase: JumpPhase = .grounded, soles: (Double, Double) = (0, 0.01)) throws -> PlayerBodySample {
        func v(_ x: Double) throws -> EstimatedScalar { try EstimatedScalar(value: x, validity: .valid) }
        return PlayerBodySample(playerID: .player1, calibrationRevision: c.revision, trackingStatus: .reliable,
                                geometry: BodyGeometry(crownY: try v(1.6), leftWristY: try v(0.8), rightWristY: try v(0.8),
                                                       leftSoleY: try v(soles.0), rightSoleY: try v(soles.1), centerX: try v(-0.65)),
                                jumpState: JumpState(phase: phase, validity: .valid))
    }

    /// Player-plane joints (unmirrored: the player's right is −X) for a standing pose.
    private func joints(_ c: PlayerCalibration, rightWrist: (Double, Double)? = nil, hipDrop: Double = 0,
                        shoulderShift: Double = 0) -> PresentationPoseSample {
        let x = -0.65
        var j: [PresentationJoint: (Double, Double)] = [
            .leftShoulder: (x + 0.2 + shoulderShift, 1.3), .rightShoulder: (x - 0.2 + shoulderShift, 1.3),
            .leftElbow: (x + 0.22 + shoulderShift, 1.05), .rightElbow: (x - 0.22 + shoulderShift, 1.05),
            .leftWrist: (x + 0.24 + shoulderShift, 0.8), .rightWrist: (x - 0.24 + shoulderShift, 0.8),
            .leftHip: (x + 0.1, 0.9 - hipDrop), .rightHip: (x - 0.1, 0.9 - hipDrop),
            .leftAnkle: (x + 0.1, 0.032), .rightAnkle: (x - 0.1, 0.0405),
        ]
        if let rightWrist { j[.rightWrist] = rightWrist; j[.rightElbow] = ((j[.rightShoulder]!.0 + rightWrist.0) / 2, (1.3 + rightWrist.1) / 2) }
        return PresentationPoseSample(playerID: .player1, calibrationRevision: c.revision,
                                      joints: j.mapValues { PresentationPoint(x: $0.0, y: $0.1, confidence: 0.9) })
    }

    @Test func playersRightArmDrivesRobotsRightArm() throws {
        let (c, layout) = try calibration()
        var r = RobotRetargeter(calibration: c, layout: layout, robotLegRest: 0.574)
        // The player's right hand straight out to THEIR right: −X in the unmirrored plane.
        r.update(sample: try sample(c), joints: joints(c, rightWrist: (-0.65 - 0.2 - 0.55, 1.3)), time: 0)
        let right = try #require(r.targets.forearm[.right])
        #expect(right.x > 0.9 * simd_length(right))  // robot's right = +X = screen right from behind
        let left = try #require(r.targets.forearm[.left])
        #expect(left.y < 0)  // still hanging
    }

    /// Feeds the same input at 30 Hz for `frames` frames from `time`; returns the next time.
    @discardableResult
    private func feed(_ r: inout RobotRetargeter, _ sample: PlayerBodySample?, _ joints: PresentationPoseSample?,
                      from time: Double, frames: Int) -> Double {
        for n in 0..<frames { r.update(sample: sample, joints: joints, time: time + Double(n) / 30) }
        return time + Double(frames) / 30
    }

    @Test func crouchLeanAndJumpRetarget() throws {
        let (c, layout) = try calibration()
        var r = RobotRetargeter(calibration: c, layout: layout, robotLegRest: 0.574)
        // The first appearance fades in from rest (no snap), fully within 0.25 s.
        r.update(sample: try sample(c), joints: joints(c), time: 0)
        #expect(r.presence == 0)
        var t = feed(&r, try sample(c), joints(c), from: 1.0 / 30, frames: 9)
        #expect(r.presence > 0.95 && r.targets.pelvisDrop < 0.01 && r.lift < 0.005)
        // Hips 0.25 lower: within 100 ms (3 frames of the 1€ filter) the pelvis follows most of the way.
        t = feed(&r, try sample(c), joints(c, hipDrop: 0.25), from: t, frames: 3)
        let expected = Float(0.25 / 0.868) * 0.574  // above the soft noise zone the share passes unchanged (K04)
        #expect(r.targets.pelvisDrop > 0.85 * expected && r.targets.pelvisDrop <= expected + 1e-3)
        // Shoulders shifted toward the player's right (−X unmirrored): lean toward screen right (+).
        t = feed(&r, try sample(c), joints(c, shoulderShift: -0.15), from: t, frames: 3)
        #expect(r.targets.lean > 0.1)
        // K04: raised soles alone never lift the root; only valid airborne evidence
        // does (as the judge requires for a jump to clear).
        t = feed(&r, try sample(c, phase: .grounded, soles: (0.3, 0.32)), joints(c), from: t, frames: 4)
        #expect(r.lift < 0.001)
        // Validly airborne: the lift follows the lower sole, most of it within one
        // frame, all of it within four.
        let full = 0.3 * r.motionScale  // above the dead zone the lift passes unchanged (K04)
        t = feed(&r, try sample(c, phase: .airborne, soles: (0.3, 0.32)), joints(c), from: t, frames: 1)
        #expect(r.lift > 0.75 * full)
        t = feed(&r, try sample(c, phase: .airborne, soles: (0.3, 0.32)), joints(c), from: t, frames: 3)
        #expect(abs(r.lift - full) < 0.01)
        // Landing: back to (almost) 0 within four frames, never below the floor.
        var lifts: [Float] = []
        for n in 0..<4 { r.update(sample: try sample(c), joints: joints(c), time: t + Double(n) / 30); lifts.append(r.lift) }
        #expect(lifts.last! < 0.01 && lifts.allSatisfy { $0 >= 0 })
    }

    @Test func trackingLossRelaxesAndRecoveryUsesFreshData() throws {
        let (c, layout) = try calibration()
        var r = RobotRetargeter(calibration: c, layout: layout, robotLegRest: 0.574)
        var t = feed(&r, try sample(c), joints(c, rightWrist: (-1.4, 1.3), hipDrop: 0.2), from: 0, frames: 15)
        #expect(r.isAvailable && r.targets.pelvisDrop > 0.05)
        // One or two missed detections: the pose is held exactly, still shown as tracked.
        let held = r.targets
        t = feed(&r, nil, nil, from: t, frames: 2)
        #expect(r.isAvailable && r.targets == held)
        // Gone for 1.5 s: fades back to the bind pose (never invents movement).
        t = feed(&r, nil, nil, from: t, frames: 43)
        #expect(!r.isAvailable && r.targets.pelvisDrop < 0.005 && (r.targets.armWeight[.right] ?? 0) < 0.02)
        // Recovery fades in from rest toward FRESH data (arm hanging), never the old raised arm.
        r.update(sample: try sample(c), joints: joints(c), time: t)
        #expect(r.isAvailable && r.presence < 0.5)  // eases in over ~0.1 s
        feed(&r, try sample(c), joints(c), from: t + 1.0 / 30, frames: 10)
        #expect(r.presence > 0.95 && (r.targets.forearm[.right]?.y ?? 0) < 0)
    }

    @Test func aLowConfidenceArmHoldsBrieflyThenReturnsToBind() throws {
        let (c, layout) = try calibration()
        var r = RobotRetargeter(calibration: c, layout: layout, robotLegRest: 0.574)
        var t = feed(&r, try sample(c), joints(c, rightWrist: (-1.4, 1.3)), from: 0, frames: 15)
        #expect((r.targets.armWeight[.right] ?? 0) > 0.95)
        // Right elbow and wrist drop below confidence: the arm holds, then fades to bind.
        var weak = joints(c).joints
        weak[.rightElbow] = nil
        weak[.rightWrist] = nil
        let sparse = PresentationPoseSample(playerID: .player1, calibrationRevision: c.revision, joints: weak)
        t = feed(&r, try sample(c), sparse, from: t, frames: 6)  // 0.2 s
        #expect((r.targets.armWeight[.right] ?? 0) > 0.95)
        feed(&r, try sample(c), sparse, from: t, frames: 30)  // +1 s
        #expect((r.targets.armWeight[.right] ?? 1) < 0.1)
        #expect((r.targets.armWeight[.left] ?? 0) > 0.95)  // the other arm is unaffected
    }

    @Test func layerAcceptsRestartedFrameIDsAfterReset() async throws {
        let input = try LaserReplayScript.load().input
        let layer = RobotAvatarLayer(scene: LaserScene(), calibrations: input.configuration.calibrations,
                                     layout: input.configuration.playerPlaneLayout, templates: try await templates())
        let sequence = RobotDemoSequence(configuration: input.configuration, cameraGeometryRevision: 1, only: .p1JumpLand)
        let late = try sequence.frame(40)
        layer.apply(late.snapshot, joints: late.joints)
        #expect(layer.lastFrame?.frameID == 40)
        layer.resetFrameOrder()
        let early = try sequence.frame(3)
        layer.apply(early.snapshot, joints: early.joints)
        #expect(layer.lastFrame?.frameID == 3)
    }

    /// Per-frame cost: one full solve for each of two robots, 30 times a second.
    @Test func solvingIsCheapEnoughForTwoRobotsPerFrame() async throws {
        let (_, _, solver) = try await rig()
        var t = RobotPoseTargets()
        t.pelvisDrop = 0.12; t.lean = 0.2; t.headRoll = 0.1
        t.upperArm[.left] = [-1, 0.3, -0.2]; t.forearm[.left] = [-1, 0.6, 0]
        t.upperArm[.right] = [1, -0.4, 0]; t.forearm[.right] = [0.6, 0.8, -0.3]
        t.footLift[.right] = 0.05
        let clock = ContinuousClock()
        let elapsed = clock.measure { for _ in 0..<600 { _ = solver.solve(t) } }
        let perSolve = Double(elapsed.components.attoseconds) / 1e18 / 600 + Double(elapsed.components.seconds) / 600
        print(String(format: "ROBOT-SOLVE-COST %.1f µs per solve", perSolve * 1e6))
        #expect(perSolve < 0.0005)  // far under a 33 ms camera frame even on the Simulator
    }

    // MARK: - Equal size

    /// Two players of very different calibrated heights get the same robot.
    private func calibrations(p1Height: Double, p2Height: Double) throws -> ([PlayerID: PlayerCalibration], PlayerPlaneLayout) {
        let input = try LaserReplayScript.load().input
        let layout = input.configuration.playerPlaneLayout
        var result: [PlayerID: PlayerCalibration] = [:]
        for (player, height) in [(PlayerID.player1, p1Height), (.player2, p2Height)] {
            let base = try #require(input.configuration.calibrations[player])
            // Standing crown = floor + height in game units (layout.gameUnitsPerImageHeight per image height).
            let crown = base.mapping.floorImageY + height / layout.gameUnitsPerImageHeight
            let sole = min(base.standingLeftSoleImageY, base.standingRightSoleImageY)
            result[player] = PlayerCalibration(
                playerID: player, sessionGeneration: base.sessionGeneration, revision: base.revision,
                cameraGeometryRevision: base.cameraGeometryRevision, sourceFrameID: base.sourceFrameID, capturedAt: base.capturedAt,
                standingCrownImageY: crown, standingLeftSoleImageY: base.standingLeftSoleImageY,
                standingRightSoleImageY: base.standingRightSoleImageY, standingHipImageY: sole + (crown - sole) * 0.5,
                standingBodyImageHeight: crown - sole, standingTorsoImageLength: (crown - sole) * 0.3,
                headOffsetFromNoseShare: base.headOffsetFromNoseShare, leftFootOffsetShare: base.leftFootOffsetShare,
                rightFootOffsetShare: base.rightFootOffsetShare, mapping: base.mapping)
            try result[player]!.validate()
        }
        return (result, layout)
    }

    /// Projected screen height (normalized device units) of a world-space vertical span, through the scene camera.
    private func projectedHeight(_ scene: LaserScene, bottom: SIMD3<Float>, top: SIMD3<Float>) -> Float {
        let l = scene.layout
        let forward = simd_normalize(l.cameraTarget - l.cameraPosition)
        let right = simd_normalize(simd_cross(forward, [0, 1, 0]))
        let up = simd_cross(right, forward)
        let focal = 1 / tan(l.cameraVerticalFieldOfView * .pi / 360)
        func y(_ p: SIMD3<Float>) -> Float {
            let d = p - l.cameraPosition
            return simd_dot(d, up) / simd_dot(d, forward) * focal
        }
        return y(top) - y(bottom)
    }

    @Test func bothRobotsShareOneSizeWhateverThePlayersHeights() async throws {
        let (calibrations, layout) = try calibrations(p1Height: 1.7, p2Height: 1.2)
        let scene = LaserScene()
        let layer = RobotAvatarLayer(scene: scene, calibrations: calibrations, layout: layout, templates: try await templates())
        let p1 = try #require(layer.robots[.player1]), p2 = try #require(layer.robots[.player2])
        // Same uniform model scale for both, from one place.
        #expect(p1.container.scale == p2.container.scale)
        #expect(p1.container.scale == SIMD3(repeating: RobotAvatarLayer.modelScale))
        // Same world-space size, grounded on the board (feet at the players' floor, y = 0).
        let a = p1.container.visualBounds(relativeTo: nil), b = p2.container.visualBounds(relativeTo: nil)
        #expect(abs(a.extents.y - RobotAvatarLayer.standingHeight) < 0.01)
        #expect(abs(a.extents.y - b.extents.y) < 1e-4 && abs(a.extents.x - b.extents.x) < 1e-4)
        #expect(abs(a.min.y) < 0.01 && abs(b.min.y) < 0.01)
        // Same depth, mirrored lanes: P1 screen-left, P2 screen-right.
        #expect(abs(a.center.z - b.center.z) < 1e-4 && a.center.x < 0 && b.center.x > 0)
        // And the same height on screen through the gameplay camera.
        let h1 = projectedHeight(scene, bottom: [a.center.x, a.min.y, a.center.z], top: [a.center.x, a.max.y, a.center.z])
        let h2 = projectedHeight(scene, bottom: [b.center.x, b.min.y, b.center.z], top: [b.center.x, b.max.y, b.center.z])
        #expect(abs(h1 - h2) / h1 < 0.005)
    }

    /// Each player's motion is normalized by their own height: the same
    /// relative jump lifts both robots by the same amount.
    @Test func motionIsNormalizedPerPlayerNotSize() throws {
        let (calibrations, layout) = try calibrations(p1Height: 1.7, p2Height: 1.2)
        var tall = RobotRetargeter(calibration: calibrations[.player1]!, layout: layout, robotLegRest: 0.574)
        var short = RobotRetargeter(calibration: calibrations[.player2]!, layout: layout, robotLegRest: 0.574)
        func jump(_ c: PlayerCalibration, _ lift: Double) throws -> PlayerBodySample {
            func v(_ x: Double) throws -> EstimatedScalar { try EstimatedScalar(value: x, validity: .valid) }
            let height = c.mapping.gameY(imageY: c.standingCrownImageY, layout: layout)
            return PlayerBodySample(playerID: c.playerID, calibrationRevision: c.revision, trackingStatus: .reliable,
                                    geometry: BodyGeometry(crownY: try v(height + lift), leftWristY: try v(0.8), rightWristY: try v(0.8),
                                                           leftSoleY: try v(lift), rightSoleY: try v(lift), centerX: try v(layout.centerX(for: c.playerID))),
                                    jumpState: JumpState(phase: .airborne, validity: .valid))
        }
        // Both jump 15% of their own height.
        feed(&tall, try jump(calibrations[.player1]!, 0.15 * 1.7), nil, from: 0, frames: 20)
        feed(&short, try jump(calibrations[.player2]!, 0.15 * 1.2), nil, from: 0, frames: 20)
        // Above the soft noise zone (2% of height) the lift passes unchanged (K04).
        #expect(abs(tall.lift - 0.15 * RobotAvatarLayer.standingHeight) < 2e-3)
        #expect(abs(short.lift - tall.lift) < 1e-3)
    }

    // MARK: - Debug paths and cleanup

    @Test func onlyTheRobotDemoFlagSelectsTheDemo() {
        #expect(RobotDemoDriver.requested(in: ["app"]) == nil)
        #expect(RobotDemoDriver.requested(in: ["app", "-rigDemo"]) == nil)   // retired 2D flag
        #expect(RobotDemoDriver.requested(in: ["app", "-rearAvatar"]) == nil) // retired 2D flag
        #expect(RobotDemoDriver.requested(in: ["app", "-robotDemo"]) == .some(nil))
        #expect(RobotDemoDriver.requested(in: ["app", "-robotDemo", "p1-jump"]) == .some(.p1JumpLand))
    }

    @Test func noRetiredChibiResourcesShipInTheApp() throws {
        let bundle = Bundle.main
        for name in ["chibi-rig", "chibi-head", "chibi-torso", "chibi-arm-left", "chibi-arm-right",
                     "chibi-leg-left", "chibi-leg-right", "mascot-rear-idle", "chibi-master"] {
            #expect(bundle.url(forResource: name, withExtension: "png") == nil && bundle.url(forResource: name, withExtension: "json") == nil)
        }
        for player in PlayerID.allCases {
            #expect(bundle.url(forResource: RobotAvatarLayer.resourceName(for: player), withExtension: "usdz") != nil)
        }
        // The single orange `mascot.usdz` was replaced by its byte-identical P2 copy.
        #expect(bundle.url(forResource: "mascot", withExtension: "usdz") == nil)
    }

    // MARK: - Two players in the scene

    @Test func bothRobotsMoveIndependentlyFromOneSequence() async throws {
        let input = try LaserReplayScript.load().input
        let scene = LaserScene()
        let layer = RobotAvatarLayer(scene: scene, calibrations: input.configuration.calibrations,
                                     layout: input.configuration.playerPlaneLayout, templates: try await templates())
        #expect(layer.robots.count == 2)
        // P1 ducks while P2 jumps (synthetic sequence, scenario 7, around 1.2 s).
        let sequence = RobotDemoSequence(configuration: input.configuration, cameraGeometryRevision: input.cameraGeometryRevision,
                                            only: .duckWhileJump)
        for index in UInt64(1)...36 {
            let f = try sequence.frame(index)
            layer.apply(f.snapshot, joints: f.joints)
        }
        let p1 = try #require(layer.robots[.player1]), p2 = try #require(layer.robots[.player2])
        // The same share of the avatar's leg as 5 cm was of the first robot's 0.574 m leg.
        #expect(p1.retargeter.targets.pelvisDrop > 0.05 / 0.574 * p1.retargeter.robotLegRest && p1.retargeter.lift == 0)
        #expect(p2.retargeter.lift > 0.1)
        #expect(p1.container.position.y == 0 && p2.container.position.y > 0.1)
        // Robots stand on their own lanes, P1 left, P2 right; the pictograms are hidden.
        #expect(try #require(scene.players[.player1]).position.x < 0 && p1.container.parent === scene.players[.player1])
        #expect(scene.players[.player2]?.findEntity(named: "player.player2.surface")?.isEnabled == false)
        layer.remove()
        #expect(scene.players[.player2]?.findEntity(named: "player.player2.surface")?.isEnabled == true)
    }

    /// The avatars are lit only by key/fill plus their own dim neutral
    /// environment (not RealityView's default one, which washed the orange out).
    @Test func avatarsReceiveOnlyTheirOwnNeutralEnvironmentLight() async throws {
        let input = try LaserReplayScript.load().input
        let scene = LaserScene()
        let layer = RobotAvatarLayer(scene: scene, calibrations: input.configuration.calibrations,
                                     layout: input.configuration.playerPlaneLayout, templates: try await templates())
        let lights = try #require(scene.root.findEntity(named: "robot.lights"))
        #expect(lights.components[ImageBasedLightComponent.self] != nil)
        for robot in layer.robots.values {
            #expect(robot.container.components[ImageBasedLightReceiverComponent.self]?.imageBasedLight === lights)
        }
        let intensities = lights.children.compactMap { ($0 as? DirectionalLight)?.light.intensity }.sorted()
        #expect(intensities == [1200, 3000])  // unchanged key and fill
        layer.remove()
    }
}
