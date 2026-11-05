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

    static let duration = 4.0

    var key: String {
        ["idle", "p1-jump", "p2-duck", "both-jump", "p1-arm", "arms", "duck-jump", "tracking-loss"][rawValue]
    }

    var title: String {
        ["Both idle", "P1 jumps and lands", "P2 ducks and stands", "Both jump independently",
         "P1 raises an arm, P2 idle", "Asymmetric arms", "P1 ducks while P2 jumps",
         "P2 tracking lost and recovered; P1 leans and sways"][rawValue]
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
        /// Sideways step on screen.
        var sway = 0.0
        var lost = false
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
        let leftShoulder = (x: shoulderX + half, y: shoulderY), rightShoulder = (x: shoulderX - half, y: shoulderY)
        let leftWrist = (x: leftShoulder.x + arm * sin(b.leftArm * deg), y: leftShoulder.y - arm * cos(b.leftArm * deg))
        let rightWrist = (x: rightShoulder.x - arm * sin(b.rightArm * deg), y: rightShoulder.y - arm * cos(b.rightArm * deg))
        let leftSole = b.lift + b.leftLegRaise, rightSole = b.lift + b.rightLegRaise
        let earY = crown - 0.14 * c0, ear = 0.08 * c0, roll = (b.headRoll - b.lean) * deg
        // Ankles sit the calibrated foot height above the sole.
        let foot = calibration.leftFootOffsetShare * calibration.standingBodyImageHeight * layout.gameUnitsPerImageHeight
        let headX = shoulderX - (crown - shoulderY) * tan(b.lean * deg) * 0.5

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
            .nose: p(headX, crown - 0.12 * c0),
            .leftEar: p(headX + ear * cos(roll), earY - ear * sin(roll)),
            .rightEar: p(headX - ear * cos(roll), earY + ear * sin(roll)),
            .neck: p(shoulderX, shoulderY + 0.03 * c0),
            .leftShoulder: p(leftShoulder.x, leftShoulder.y), .rightShoulder: p(rightShoulder.x, rightShoulder.y),
            .leftElbow: p((leftShoulder.x + leftWrist.x) / 2, (leftShoulder.y + leftWrist.y) / 2),
            .rightElbow: p((rightShoulder.x + rightWrist.x) / 2, (rightShoulder.y + rightWrist.y) / 2),
            .leftWrist: p(leftWrist.x, leftWrist.y), .rightWrist: p(rightWrist.x, rightWrist.y),
            .leftHip: p(hipX + 0.08 * c0, hipY), .rightHip: p(hipX - 0.08 * c0, hipY),
            .leftKnee: p(hipX + 0.07 * c0, (hipY + leftSole) / 2), .rightKnee: p(hipX - 0.07 * c0, (hipY + rightSole) / 2),
            .leftAnkle: p(hipX + 0.06 * c0, leftSole + foot), .rightAnkle: p(hipX - 0.06 * c0, rightSole + foot),
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

    /// `apply` receives each synthetic frame (the robot layer).
    func start(on content: RealityViewCameraContent, sequence: RobotDemoSequence,
               apply: @escaping @MainActor (BodySnapshot, PresentationPoseFrame) -> Void) {
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            guard let self else { return }
            elapsed += event.deltaTime
            let latest = UInt64(elapsed * RobotDemoSequence.frameRate)
            guard latest > frame, let next = try? sequence.frame(latest) else { return }
            frame = latest
            apply(next.snapshot, next.joints)
            scenario = next.scenario
        }
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
    }
}
#endif
