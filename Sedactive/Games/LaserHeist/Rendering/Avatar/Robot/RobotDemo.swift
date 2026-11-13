//
//  RobotDemo.swift
//  Sedactive
//

#if DEBUG
import Foundation
import RealityKit
import SwiftUI

/// The required avatar demonstrations, each 4 seconds, in a loop.
enum RobotDemoScenario: Int, CaseIterable {
    case idle, p1JumpLand, p2DuckStand, bothJump, p1ArmRaise, asymmetricArms, duckWhileJump, trackingLoss
    // Feet: lean vs side step (foot planting and lateral stepping).
    case leanRight, leanLeft, stepRight, stepLeft, twoSteps, stepThenStop, duckPlanted, stepThenJump, lossDuringStep, p1StepP2Idle
    // Arms overhead against the mascot's head: alone, while ducking, while stepping.
    case armsOverhead
    // K03 head turn (nose between the ears), with arm and lean, both players at once.
    case headTurn
    case deepDuckCompare

    static let duration = 4.0

    var key: String {
        ["idle", "p1-jump", "p2-duck", "both-jump", "p1-arm", "arms", "duck-jump", "tracking-loss",
         "lean-right", "lean-left", "step-right", "step-left", "two-steps", "step-stop", "duck-planted", "step-jump",
         "loss-step", "p1-step-p2-idle", "arms-up", "head-turn", "deep-duck"][rawValue]
    }

    var title: String {
        ["Both idle", "P1 jumps and lands", "P2 ducks and stands", "Both jump independently",
         "P1 raises an arm, P2 idle", "Asymmetric arms", "P1 ducks while P2 jumps",
         "P2 tracking lost and recovered; P1 leans and sways",
         "P1 leans right, feet planted", "P1 leans left, feet planted", "P1 steps right, then back",
         "P1 steps left, then back", "P1 two steps right, two back", "P1 quick step right, stops, returns",
         "P1 ducks, feet planted", "P1 steps right, jumps, steps back", "P1 tracking lost mid-step",
         "P1 side-steps; P2 idle with body sway",
         "P1 both arms up, ducks, stands, lowers; P2 steps with right arm up",
         "P1 turns head right (right shoulder up) then left; P2 turns head left and leans with its arm out",
         "SYNTHETIC both: stand, moderate duck, deep duck, recover"][rawValue]
    }
}

/// SYNTHETIC, deterministic, time-varying human motion for both players,
/// emitted as valid CP1 `BodySnapshot`s plus presentation joints at 30 frames
/// per second. Not a recording and not live tracking: it drives `-robotDemo`
/// and the robot tests through the same retargeting the live lab uses.
struct RobotDemoSequence {
    static let frameRate = 30.0

    /// Human motion for one player at one instant (game units and degrees).
    struct Body: Equatable {
        var lift = 0.0
        var drop = 0.0
        var leftLegRaise = 0.0
        var rightLegRaise = 0.0
        /// Arm direction from straight down, outward positive.
        var leftArm = 6.0
        var rightArm = 6.0
        /// Torso tilt toward screen right, and head roll (counter-clockwise on screen).
        var lean = 0.0
        var headRoll = 0.0
        /// Head turn toward screen right (the player turning to their right), degrees.
        var headYaw = 0.0
        /// The player's right shoulder raised above the left (a shrug), share of standing height.
        var rightShoulderUp = 0.0
        /// Hip centre sideways on screen (screen right positive).
        var sway = 0.0
        /// Each ankle sideways on screen; `nil` moves it with the hips (a whole-body shift).
        var leftFoot: Double?
        var rightFoot: Double?
        var lost = false
    }

    /// One compact side step of `distance` (screen right positive) from `start`: the
    /// leading foot lifts and lands first, the hips follow, the trailing foot closes.
    struct SideStep {
        var lead = 0.0, trail = 0.0, hips = 0.0, leadLift = 0.0, trailLift = 0.0
    }

    static func sideStep(_ t: Double, at start: Double, distance: Double, quick: Bool = false) -> SideStep {
        func smooth(_ a: Double, _ b: Double) -> Double {
            let x = min(1, max(0, (t - a) / (b - a)))
            return x * x * (3 - 2 * x)
        }
        let swing = quick ? 0.22 : 0.3
        var s = SideStep()
        s.lead = distance * smooth(start, start + swing)
        s.hips = distance * smooth(start + 0.05, start + swing + 0.25)
        s.trail = distance * smooth(start + swing, start + 2 * swing)
        s.leadLift = 0.045 * bump(t, start, start + swing)
        s.trailLift = 0.035 * bump(t, start + swing, start + 2 * swing)
        return s
    }

    /// Applies side steps to a body: screen-right steps lead with the right foot.
    static func stepping(_ b: inout Body, _ t: Double, _ steps: [(start: Double, distance: Double)], quick: Bool = false) {
        var left = b.leftFoot ?? 0, right = b.rightFoot ?? 0
        for step in steps {
            let s = sideStep(t, at: step.start, distance: step.distance, quick: quick)
            b.sway += s.hips
            if step.distance > 0 {
                right += s.lead; left += s.trail
                b.rightLegRaise += s.leadLift; b.leftLegRaise += s.trailLift
            } else {
                left += s.lead; right += s.trail
                b.leftLegRaise += s.leadLift; b.rightLegRaise += s.trailLift
            }
        }
        b.leftFoot = left
        b.rightFoot = right
    }

    let configuration: BodyInputConfiguration
    let cameraGeometryRevision: UInt64
    /// Loop only this scenario (`nil`: all of them in turn).
    var only: RobotDemoScenario?

    func scenario(at time: Double) -> (RobotDemoScenario, Double) {
        let local = time.truncatingRemainder(dividingBy: RobotDemoScenario.duration)
        if let only { return (only, local) }
        let index = Int(time / RobotDemoScenario.duration) % RobotDemoScenario.allCases.count
        return (RobotDemoScenario(rawValue: index)!, local)
    }

    // MARK: - Motion curves

    /// 0 → 1 → 0 between `start` and `end`, eased.
    static func bump(_ t: Double, _ start: Double, _ end: Double) -> Double {
        guard t > start, t < end else { return 0 }
        let s = sin(.pi * (t - start) / (end - start))
        return s * s
    }

    /// Eased rise over a…b, hold, eased fall over c…d.
    static func plateau(_ t: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
        func smooth(_ x: Double) -> Double { let x = min(1, max(0, x)); return x * x * (3 - 2 * x) }
        if t <= a || t >= d { return 0 }
        if t < b { return smooth((t - a) / (b - a)) }
        if t <= c { return 1 }
        return 1 - smooth((t - c) / (d - c))
    }

    /// A ballistic jump: a parabola of `height` over `airtime` seconds from `start`.
    static func jump(_ t: Double, _ start: Double, airtime: Double, height: Double) -> Double {
        let u = (t - start) / airtime
        guard u > 0, u < 1 else { return 0 }
        return 4 * height * u * (1 - u)
    }

    func body(_ player: PlayerID, _ scenario: RobotDemoScenario, _ t: Double, standing: Double) -> Body {
        var b = Body()
        let p1 = player == .player1
        switch scenario {
        case .idle:
            break
        case .p1JumpLand:
            if p1 {
                b.lift = Self.jump(t, 0.6, airtime: 0.6, height: 0.28) + Self.jump(t, 2.3, airtime: 0.55, height: 0.22)
                b.rightLegRaise = 0.25 * b.lift
                b.leftArm = 6 + 140 * b.lift
                b.rightArm = 6 + 140 * b.lift
            }
        case .deepDuckCompare:
            b.drop = standing * (0.12 * Self.plateau(t, 0.4, 0.8, 2.7, 3.3)
                + 0.20 * Self.plateau(t, 1.2, 1.7, 2.4, 2.9))
        case .p2DuckStand:
            if !p1 {
                b.drop = 0.16 * standing * Self.plateau(t, 0.5, 1.2, 2.5, 3.3)
                b.leftArm = 6 + 25 * Self.plateau(t, 0.5, 1.2, 2.5, 3.3)
                b.rightArm = b.leftArm
            }
        case .bothJump:
            b.lift = p1 ? Self.jump(t, 0.4, airtime: 0.6, height: 0.25) + Self.jump(t, 2.6, airtime: 0.5, height: 0.16)
                        : Self.jump(t, 1.5, airtime: 0.65, height: 0.3)
            b.leftLegRaise = p1 ? 0.2 * b.lift : 0
        case .p1ArmRaise:
            if p1 { b.leftArm = 6 + 168 * Self.plateau(t, 0.4, 1.3, 2.4, 3.3) }
        case .asymmetricArms:
            if p1 {
                b.leftArm = 6 + 165 * Self.plateau(t, 0.3, 1.0, 3.0, 3.7)
                b.rightArm = 6 + 84 * Self.plateau(t, 1.0, 1.6, 2.6, 3.4)
            } else {
                let up = Self.plateau(t, 0.3, 0.8, 3.2, 3.7)
                b.rightArm = 6 + up * (114 + 34 * sin(2 * .pi * 1.6 * t))
            }
        case .duckWhileJump:
            if p1 {
                b.drop = 0.14 * standing * Self.plateau(t, 0.3, 0.9, 3.0, 3.6)
            } else {
                b.lift = Self.jump(t, 0.9, airtime: 0.6, height: 0.27) + Self.jump(t, 2.3, airtime: 0.6, height: 0.27)
                b.leftArm = 6 + 120 * b.lift
                b.rightArm = b.leftArm
            }
        case .trackingLoss:
            if p1 {
                b.lean = 8 * sin(2 * .pi * t / 4)
                b.headRoll = 6 * sin(2 * .pi * t / 2)
                b.sway = 0.16 * sin(2 * .pi * t / 4)
            } else {
                b.lost = t >= 1.0 && t < 2.6
                b.rightArm = t < 1.0 ? 6 + 100 * Self.plateau(t, 0.1, 0.6, 2, 3) : 6 + 60 * Self.plateau(t, 2.8, 3.2, 3.6, 3.95)
            }
        case .leanRight, .leanLeft:
            // Weight shift and trunk lean, ankles still: no step.
            if p1 {
                let sign = scenario == .leanRight ? 1.0 : -1.0
                let w = Self.plateau(t, 0.4, 1.1, 2.6, 3.3)
                b.sway = sign * 0.07 * w
                b.lean = sign * 9 * w
                b.leftFoot = 0
                b.rightFoot = 0
            }
        case .stepRight, .stepLeft:
            if p1 {
                let sign = scenario == .stepRight ? 1.0 : -1.0
                Self.stepping(&b, t, [(0.6, sign * 0.16), (2.6, -sign * 0.16)])
            }
        case .twoSteps:
            if p1 { Self.stepping(&b, t, [(0.3, 0.14), (1.0, 0.14), (2.2, -0.14), (2.9, -0.14)]) }
        case .stepThenStop:
            if p1 { Self.stepping(&b, t, [(0.5, 0.2), (3.2, -0.2)], quick: true) }
        case .duckPlanted:
            if p1 {
                b.drop = 0.15 * standing * Self.plateau(t, 0.5, 1.2, 2.6, 3.3)
                b.sway = 0.015 * sin(2 * .pi * t / 1.3)  // incidental balance sway
                b.leftFoot = 0
                b.rightFoot = 0
            }
        case .stepThenJump:
            if p1 {
                Self.stepping(&b, t, [(0.4, 0.15), (3.1, -0.15)])
                b.lift = Self.jump(t, 1.6, airtime: 0.6, height: 0.25)
            }
        case .lossDuringStep:
            if p1 {
                Self.stepping(&b, t, [(0.8, 0.16), (3.0, -0.16)])
                b.lost = t >= 0.95 && t < 1.8
            }
        case .p1StepP2Idle:
            if p1 {
                Self.stepping(&b, t, [(0.5, 0.15), (2.5, -0.15)])
            } else {
                b.sway = 0.012 * sin(2 * .pi * t / 1.7)  // incidental sway, ankles still
                b.leftFoot = 0
                b.rightFoot = 0
            }
        case .armsOverhead:
            if p1 {
                b.leftArm = 6 + 168 * Self.plateau(t, 0.2, 0.8, 3.2, 3.8)
                b.rightArm = b.leftArm
                b.drop = 0.15 * standing * Self.plateau(t, 1.2, 1.7, 2.3, 2.8)
            } else {
                b.rightArm = 6 + 165 * Self.plateau(t, 0.2, 0.7, 3.3, 3.8)
                Self.stepping(&b, t, [(1.0, 0.15), (2.6, -0.15)])
            }
        case .headTurn:
            if p1 {
                b.headYaw = 30 * Self.plateau(t, 0.2, 0.6, 1.3, 1.7) - 30 * Self.plateau(t, 2.0, 2.4, 3.1, 3.5)
                b.rightArm = 6 + 80 * Self.plateau(t, 0.2, 0.6, 1.3, 1.7)
                b.rightShoulderUp = 0.035 * Self.plateau(t, 0.2, 0.6, 1.3, 1.7)
            } else {
                b.headYaw = -30 * Self.plateau(t, 0.6, 1.0, 2.6, 3.0)
                b.lean = -12 * Self.plateau(t, 0.6, 1.0, 2.6, 3.0)
                b.leftArm = 6 + 70 * Self.plateau(t, 0.6, 1.0, 2.6, 3.0)
            }
        }
        return b
    }

    // MARK: - Frames

    /// Frame `index` (1-based) of the loop: a valid CP1 snapshot and the matching joints.
    func frame(_ index: UInt64) throws -> (snapshot: BodySnapshot, joints: PresentationPoseFrame, scenario: RobotDemoScenario) {
        let time = Double(index) / Self.frameRate
        let (scenario, t) = scenario(at: time)
        var samples: [PlayerID: PlayerBodySample] = [:]
        var joints: [PlayerID: PresentationPoseSample] = [:]
        for player in PlayerID.allCases {
            guard let calibration = configuration.calibrations[player] else { continue }
            let standing = calibration.mapping.gameY(imageY: calibration.standingCrownImageY, layout: configuration.playerPlaneLayout)
            let b = body(player, scenario, t, standing: standing)
            let previous = body(player, scenario, max(0, t - 1 / Self.frameRate), standing: standing)
            let (sample, points) = try make(player, calibration, b, previous, standing: standing)
            samples[player] = sample
            if let points { joints[player] = points }
        }
        let snapshot = BodySnapshot(sessionGeneration: configuration.sessionGeneration, frameID: index, capturedAt: time,
                                    cameraGeometryRevision: cameraGeometryRevision, players: samples)
        return (snapshot, PresentationPoseFrame(sessionGeneration: configuration.sessionGeneration, frameID: index,
                                                capturedAt: time, players: joints), scenario)
    }

    private func make(_ player: PlayerID, _ calibration: PlayerCalibration, _ b: Body, _ previous: Body,
                      standing c0: Double) throws -> (PlayerBodySample, PresentationPoseSample?) {
        if b.lost {
            let none = try EstimatedScalar(value: nil, validity: .outOfFrame)
            return (PlayerBodySample(playerID: player, calibrationRevision: calibration.revision, trackingStatus: .lost,
                                     geometry: BodyGeometry(crownY: none, leftWristY: none, rightWristY: none,
                                                            leftSoleY: none, rightSoleY: none, centerX: none),
                                     jumpState: JumpState(phase: .unknown, validity: .outOfFrame)), nil)
        }
        let layout = configuration.playerPlaneLayout
        let mapping = calibration.mapping
        let s0 = mapping.gameY(imageY: calibration.standingHipImageY + calibration.standingTorsoImageLength, layout: layout)
        let h0 = mapping.gameY(imageY: calibration.standingHipImageY, layout: layout)
        let deg = Double.pi / 180
        // Game-plane X is unmirrored: the display reflects it once, so a step to screen right is −X here.
        let hipX = layout.centerX(for: player) - b.sway
        let shoulderX = hipX - (s0 - h0) * tan(b.lean * deg)
        let crown = c0 + b.lift - b.drop
        let shoulderY = s0 + b.lift - b.drop
        let hipY = h0 + b.lift - b.drop * 0.55
        let arm = 0.35 * c0, half = 0.12 * c0
        // The player's left side is +X in the unmirrored plane.
        // A rigid trunk: leaning toward screen right (−X here) turns the shoulder
        // line with it, raising the player's left (+X) shoulder. A shrug adds to that.
        let tilt = half * sin(b.lean * deg)
        let leftShoulder = (x: shoulderX + half, y: shoulderY + tilt)
        let rightShoulder = (x: shoulderX - half, y: shoulderY - tilt + b.rightShoulderUp * c0)
        let leftWrist = (x: leftShoulder.x + arm * sin(b.leftArm * deg), y: leftShoulder.y - arm * cos(b.leftArm * deg))
        let rightWrist = (x: rightShoulder.x - arm * sin(b.rightArm * deg), y: rightShoulder.y - arm * cos(b.rightArm * deg))
        let leftSole = b.lift + b.leftLegRaise, rightSole = b.lift + b.rightLegRaise
        let earY = crown - 0.14 * c0, ear = 0.08 * c0, roll = (b.headRoll - b.lean) * deg, yaw = b.headYaw * deg
        // Ankles sit the calibrated foot height above the sole.
        let foot = calibration.leftFootOffsetShare * calibration.standingBodyImageHeight * layout.gameUnitsPerImageHeight
        let headX = shoulderX - (crown - shoulderY) * tan(b.lean * deg) * 0.5
        // Each ankle: its own sideways track, or with the hips.
        let leftAnkleX = layout.centerX(for: player) - (b.leftFoot ?? b.sway) + 0.06 * c0
        let rightAnkleX = layout.centerX(for: player) - (b.rightFoot ?? b.sway) - 0.06 * c0

        func v(_ value: Double) throws -> EstimatedScalar { try EstimatedScalar(value: value, validity: .valid) }
        let phase: JumpPhase
        if b.lift <= 0.002 { phase = .grounded }
        else if b.lift >= previous.lift { phase = b.lift < 0.06 ? .takingOff : .airborne }
        else { phase = b.lift < 0.06 ? .landing : .airborne }
        let sample = PlayerBodySample(
            playerID: player, calibrationRevision: calibration.revision, trackingStatus: .reliable,
            geometry: BodyGeometry(crownY: try v(crown), leftWristY: try v(leftWrist.y), rightWristY: try v(rightWrist.y),
                                   leftSoleY: try v(leftSole), rightSoleY: try v(rightSole), centerX: try v(hipX)),
            jumpState: JumpState(phase: phase, validity: .valid))

        func p(_ x: Double, _ y: Double) -> PresentationPoint { PresentationPoint(x: x, y: y, confidence: 0.9) }
        let points: [PresentationJoint: PresentationPoint] = [
            // A turn toward screen right (−X here) swings the nose that way and narrows the ears.
            .nose: p(headX - RobotRetargeter.noseDepthPerHalfEarSpan * ear * sin(yaw), crown - 0.12 * c0),
            .leftEar: p(headX + ear * cos(roll) * cos(yaw), earY - ear * sin(roll)),
            .rightEar: p(headX - ear * cos(roll) * cos(yaw), earY + ear * sin(roll)),
            .neck: p(shoulderX, shoulderY + 0.03 * c0),
            .leftShoulder: p(leftShoulder.x, leftShoulder.y), .rightShoulder: p(rightShoulder.x, rightShoulder.y),
            .leftElbow: p((leftShoulder.x + leftWrist.x) / 2, (leftShoulder.y + leftWrist.y) / 2),
            .rightElbow: p((rightShoulder.x + rightWrist.x) / 2, (rightShoulder.y + rightWrist.y) / 2),
            .leftWrist: p(leftWrist.x, leftWrist.y), .rightWrist: p(rightWrist.x, rightWrist.y),
            .leftHip: p(hipX + 0.08 * c0, hipY), .rightHip: p(hipX - 0.08 * c0, hipY),
            .leftKnee: p((hipX + leftAnkleX) / 2 + 0.04 * c0, (hipY + leftSole) / 2),
            .rightKnee: p((hipX + rightAnkleX) / 2 - 0.04 * c0, (hipY + rightSole) / 2),
            .leftAnkle: p(leftAnkleX, leftSole + foot), .rightAnkle: p(rightAnkleX, rightSole + foot),
        ]
        return (sample, PresentationPoseSample(playerID: player, calibrationRevision: calibration.revision, joints: points))
    }
}

/// Debug driver: plays `RobotDemoSequence` into the robot layer on the
/// render loop, one synthetic frame per 1/30 s of RealityKit time.
@MainActor
final class RobotDemoDriver {
    private(set) var scenario: RobotDemoScenario = .idle
    private var subscription: EventSubscription?
    private var elapsed = 0.0
    private var frame: UInt64 = 0

    static let launchArgument = "-robotDemo"

    /// The scenario requested with `-robotDemo [key]`: `nil` when the demo is
    /// off, `.some(nil)` to play all of them in turn.
    static func requested(in arguments: [String] = ProcessInfo.processInfo.arguments) -> RobotDemoScenario?? {
        guard let index = arguments.firstIndex(of: launchArgument) else { return nil }
        let key = index + 1 < arguments.count ? arguments[index + 1] : ""
        return .some(RobotDemoScenario.allCases.first { $0.key == key })
    }

    /// `apply` receives each synthetic frame (the robot layer); `render`, if
    /// given, runs every rendered frame with the same sequence time, so steps
    /// and smoothing animate at display rate like the live lab.
    func start(on content: RealityViewCameraContent, sequence: RobotDemoSequence,
               render: (@MainActor (Double) -> Void)? = nil,
               apply: @escaping @MainActor (BodySnapshot, PresentationPoseFrame) -> Void) {
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            guard let self else { return }
            elapsed += event.deltaTime
            let latest = UInt64(elapsed * RobotDemoSequence.frameRate)
            if latest > frame, let next = try? sequence.frame(latest) {
                frame = latest
                apply(next.snapshot, next.joints)
                scenario = next.scenario
            }
            render?(elapsed)
        }
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
    }
}
#endif
