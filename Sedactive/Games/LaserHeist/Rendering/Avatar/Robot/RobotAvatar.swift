//
//  RobotAvatar.swift
//  Sedactive
//

#if DEBUG
import Foundation
import RealityKit
import UIKit
import simd

/// Human-to-robot retargeting for one player, from the live presentation
/// estimates (CP1-shaped `PlayerBodySample` plus player-plane joints) and
/// that player's calibration. Presentation only; nothing here is a hit shape.
///
/// Coordinates: player-plane joints are unmirrored (the person faces the
/// camera, so their right is the image's left). Model space for the robot is
/// +X = its anatomical right = screen right from behind. A player-plane
/// difference (dx, dy) becomes (−dx, dy) in model space: the one presentation
/// mirror, the same reflection the lane mapping applies to the live cutout.
/// Anatomical labels are never swapped: the player's right wrist aims the
/// robot's right forearm.
///
/// Sizes: every robot is shown at the same `RobotAvatarLayer.standingHeight`,
/// whoever drives it. Each player's own calibration still normalises their
/// motion: jump lift and sideways steps are scaled by
/// `standingHeight / player's standing height`, crouch depth is a share of
/// the player's own leg length, and arm and trunk directions are scale-free.
/// So a short and a tall player both make their robot jump, duck and reach
/// the same way for the same relative movement.
struct RobotRetargeter {
    /// The robot's hip-to-ankle height at rest (metres, model space).
    let robotLegRest: Float
    let calibration: PlayerCalibration
    let layout: PlayerPlaneLayout
    /// Robot metres per metre of this player's motion (shared robot height / player's standing height).
    let motionScale: Float
    var maximumSway: Float = 0.3
    var maximumLean: Float = 0.35
    var maximumHeadRoll: Float = 0.4
    /// Crouch below this share of standing leg length is camera noise.
    var crouchDeadband: Float = 0.03
    static let relaxTime = 0.25

    private(set) var targets = RobotPoseTargets.rest
    private(set) var lift: Float = 0
    private(set) var sway: Float = 0
    private(set) var isAvailable = false
    private var lastTime: Double?
    private var filters: [PresentationJoint: (x: OneEuroFilter, y: OneEuroFilter)] = [:]
    /// When each joint was last seen; a joint back after a gap restarts its filter.
    private var seen: [PresentationJoint: Double] = [:]
    /// When each arm last had evidence; an arm without it for `armHold` returns to the bind pose.
    private var armSeen: [RobotPoseTargets.Side: Double] = [:]
    static let jointGap = 0.3
    static let armHold = 0.5
    /// Longest projected length seen per segment (player-plane units), for foreshortening depth.
    private var longest: [String: Double] = [:]

    init(calibration: PlayerCalibration, layout: PlayerPlaneLayout, robotLegRest: Float,
         robotHeight: Float = RobotAvatarLayer.standingHeight) {
        self.calibration = calibration
        self.layout = layout
        self.robotLegRest = robotLegRest
        let standing = Float(calibration.mapping.gameY(imageY: calibration.standingCrownImageY, layout: layout))
        motionScale = standing > 0 ? robotHeight / standing : 1
    }

    private func gameY(_ imageY: Double) -> Double { calibration.mapping.gameY(imageY: imageY, layout: layout) }
    private var bodyHeight: Double { calibration.standingBodyImageHeight }

    mutating func update(sample: PlayerBodySample?, joints: PresentationPoseSample?, time: Double) {
        let dt = lastTime.map { max(0, time - $0) } ?? 0
        lastTime = time
        guard let sample, sample.playerID == calibration.playerID, sample.trackingStatus == .reliable,
              sample.calibrationRevision == calibration.revision, sample.jumpState.validity == .valid
        else { return relax(dt) }
        isAvailable = true
        let g = sample.geometry

        // JUMP: whole robot up by the lower sole while the (hysteresis) phase is off the ground.
        let soles = [g.leftSoleY, g.rightSoleY].compactMap { $0.validity == .valid ? $0.value : nil }
        lift = sample.jumpState.phase != .grounded ? Float(max(0, soles.min() ?? 0)) * motionScale : 0
        // LATERAL: hip centre, mirrored once about the lane (as `GameWorldMapping.cutoutPoint`).
        if g.centerX.validity == .valid, let x = g.centerX.value {
            let step = Float(layout.centerX(for: calibration.playerID) - x) * motionScale
            sway = min(maximumSway, max(-maximumSway, step))
        }

        // Filtered joints (1€: smooth when still, fast when moving).
        var p: [PresentationJoint: SIMD2<Double>] = [:]
        for (joint, point) in joints?.joints ?? [:] where point.confidence >= 0.3 {
            if let last = seen[joint], time - last > Self.jointGap { filters[joint] = nil }
            seen[joint] = time
            var f = filters[joint] ?? (x: OneEuroFilter(minimumCutoff: 2, beta: 4), y: OneEuroFilter(minimumCutoff: 2, beta: 4))
            p[joint] = SIMD2(Double(f.x.filter(Float(point.x), dt: dt)), Double(f.y.filter(Float(point.y), dt: dt)))
            filters[joint] = f
        }
        func model(_ a: SIMD2<Double>, _ b: SIMD2<Double>, segment: String) -> SIMD3<Float> {
            let d = b - a
            let length = simd_length(d)
            longest[segment] = max(length, (longest[segment] ?? length) * 0.999)
            // Shorter than its longest seen: the limb points toward the camera, i.e. forward (−Z).
            let depth = sqrt(max(0, (longest[segment] ?? length) * (longest[segment] ?? length) - length * length))
            return SIMD3(Float(-d.x), Float(d.y), Float(-depth))
        }

        // ARMS: shoulder→elbow and elbow→wrist directions per anatomical side.
        for (side, s, e, w) in [(RobotPoseTargets.Side.left, PresentationJoint.leftShoulder, PresentationJoint.leftElbow, PresentationJoint.leftWrist),
                                (.right, .rightShoulder, .rightElbow, .rightWrist)] {
            guard let shoulder = p[s], p[e] != nil || p[w] != nil else {
                // Low-confidence arm: hold briefly, then return to the bind pose (never invent a pose).
                if time - (armSeen[side] ?? time) > Self.armHold {
                    targets.upperArm[side] = nil
                    targets.forearm[side] = nil
                }
                continue
            }
            armSeen[side] = time
            if let elbow = p[e] {
                targets.upperArm[side] = model(shoulder, elbow, segment: "upper\(side)")
                if let wrist = p[w] { targets.forearm[side] = model(elbow, wrist, segment: "fore\(side)") }
            } else if let wrist = p[w] {
                let d = model(shoulder, wrist, segment: "arm\(side)")
                targets.upperArm[side] = d
                targets.forearm[side] = d
            }
        }

        // DUCK and knee raise: each leg's hip-to-ankle height as a share of standing, onto the robot's leg.
        if let lh = p[.leftHip], let rh = p[.rightHip] {
            let hipY = (lh.y + rh.y) / 2
            let hip0 = gameY(calibration.standingHipImageY)
            var reach: [RobotPoseTargets.Side: Float] = [:]
            for (side, ankle, sole, offset) in [(RobotPoseTargets.Side.left, PresentationJoint.leftAnkle, calibration.standingLeftSoleImageY, calibration.leftFootOffsetShare),
                                                (.right, .rightAnkle, calibration.standingRightSoleImageY, calibration.rightFootOffsetShare)] {
                guard let a = p[ankle] else { continue }
                let standing = hip0 - gameY(sole + offset * bodyHeight)
                guard standing > 0 else { continue }
                var share = Float((hipY - a.y) / standing)
                if share > 1 - crouchDeadband { share = 1 }
                reach[side] = robotLegRest * min(1, max(0.45, share))
            }
            if let longest = reach.values.max() {
                targets.pelvisDrop = robotLegRest - longest
                for side in RobotPoseTargets.Side.allCases { targets.footLift[side] = longest - (reach[side] ?? longest) }
            }
        }

        // LEAN: shoulders over hips. HEAD: the ear line.
        if let ls = p[.leftShoulder], let rs = p[.rightShoulder], let lh = p[.leftHip], let rh = p[.rightHip] {
            let d = (ls + rs) / 2 - (lh + rh) / 2
            targets.lean = min(maximumLean, max(-maximumLean, Float(atan2(-d.x, d.y))))
        }
        if let le = p[.leftEar], let re = p[.rightEar] {
            let roll = Float(atan2(re.y - le.y, -(re.x - le.x)))
            targets.headRoll = min(maximumHeadRoll, max(-maximumHeadRoll, roll + targets.lean))
        }
    }

    /// No usable evidence: never invent movement. Ease back to the bind pose
    /// and forget filter state, so recovery starts from fresh data.
    private mutating func relax(_ dt: Double) {
        isAvailable = false
        filters = [:]
        let keep = Float(exp(-dt / Self.relaxTime))
        lift *= keep
        sway *= keep
        targets.pelvisDrop *= keep
        targets.lean *= keep
        targets.headRoll *= keep
        targets.upperArm = [:]
        targets.forearm = [:]
        targets.footLift = [:]
    }
}

/// Both players' robots, standing on their `PlayerCutoutEntity`s in place of
/// the pictograms. Each instance is a clone of one loaded template with its
/// own `jointTransforms`, written once per player per new body frame.
@MainActor
final class RobotAvatarLayer {
    struct Robot {
        let container: Entity
        let model: ModelEntity
        let solver: RobotPoseSolver
        var retargeter: RobotRetargeter
    }

    static let resourceName = "laserheist-robot"
    /// Every robot's standing height on screen, in metres: one shared size for
    /// P1 and P2 (the size P1's robot had before sizes were equalised). Player
    /// height never changes it; see `RobotRetargeter.motionScale`.
    nonisolated static let standingHeight: Float = 1.6
    /// The uniform scale that gives the model that height.
    nonisolated static var modelScale: Float { standingHeight / RobotSkeleton.modelHeight }
    static let unavailableOpacity: Float = 0.5

    private(set) var robots: [PlayerID: Robot] = [:]
    private weak var scene: LaserScene?
    private let lights = Entity()
    private(set) var lastFrame: (generation: UUID, frameID: UInt64)?

    static func loadTemplate(bundle: Bundle = .main) async -> Entity? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "usdz") else { return nil }
        return try? await Entity(contentsOf: url)
    }

    /// The skinned model: the descendant with joints.
    static func skinnedModel(in entity: Entity) -> ModelEntity? {
        if let model = entity as? ModelEntity, !model.jointNames.isEmpty { return model }
        for child in entity.children { if let found = skinnedModel(in: child) { return found } }
        return nil
    }

    init(scene: LaserScene, calibrations: [PlayerID: PlayerCalibration], layout: PlayerPlaneLayout, template: Entity) {
        self.scene = scene
        for player in PlayerID.allCases {
            guard let entity = scene.players[player], let calibration = calibrations[player] else { continue }
            let robot = template.clone(recursive: true)
            guard let model = Self.skinnedModel(in: robot) else { continue }
            let skeleton = RobotSkeleton(paths: model.jointNames, bind: model.jointTransforms)
            let solver = RobotPoseSolver(skeleton: skeleton)
            let container = Entity()
            container.name = "player.\(player.rawValue).robot"
            // One shared size for every player; uniform scale only.
            container.scale = SIMD3(repeating: Self.modelScale)
            container.addChild(robot)
            entity.addChild(container)
            entity.findEntity(named: "player.\(player.rawValue).surface")?.isEnabled = false
            let bindWorld = skeleton.world(skeleton.bind).position
            let legRest = skeleton("Thigh_L").flatMap { t in skeleton("Foot_L").map { bindWorld[t].y - bindWorld[$0].y } } ?? 0.574
            robots[player] = Robot(container: container, model: model, solver: solver,
                                   retargeter: RobotRetargeter(calibration: calibration, layout: layout, robotLegRest: legRest))
            apply(player)
        }
        // The robot's materials are physically based: give it light.
        let key = DirectionalLight()
        key.light.intensity = 3000
        key.look(at: [0, 0.8, 0], from: [1.5, 3, 3], relativeTo: nil)
        let fill = DirectionalLight()
        fill.light.intensity = 1200
        fill.look(at: [0, 0.8, 0], from: [-2, 1.5, 2], relativeTo: nil)
        lights.name = "robot.lights"
        lights.addChild(key)
        lights.addChild(fill)
        scene.root.addChild(lights)
    }

    /// A new camera session restarts frame IDs; forget the last one shown.
    func resetFrameOrder() { lastFrame = nil }

    /// Shows one body frame; `joints` only when it belongs to the same frame.
    func apply(_ snapshot: BodySnapshot, joints: PresentationPoseFrame? = nil) {
        if let lastFrame, lastFrame.generation == snapshot.sessionGeneration, snapshot.frameID <= lastFrame.frameID { return }
        lastFrame = (snapshot.sessionGeneration, snapshot.frameID)
        let frameJoints = joints.flatMap { $0.matches(snapshot) ? $0 : nil }
        for player in Array(robots.keys) {
            guard var robot = robots[player] else { continue }
            let sample = frameJoints?.players[player].flatMap {
                $0.calibrationRevision == robot.retargeter.calibration.revision ? $0 : nil
            }
            robot.retargeter.update(sample: snapshot.players[player], joints: sample, time: snapshot.capturedAt)
            robots[player] = robot
            apply(player)
        }
    }

    private func apply(_ player: PlayerID) {
        guard let robot = robots[player] else { return }
        let r = robot.retargeter
        robot.container.position = [r.sway, r.lift, 0]
        robot.model.jointTransforms = robot.solver.solve(r.targets)
        let opacity = r.isAvailable ? 1 : Self.unavailableOpacity
        if robot.container.components[OpacityComponent.self]?.opacity != opacity {
            robot.container.components.set(OpacityComponent(opacity: opacity))
        }
    }

    func remove() {
        for (player, robot) in robots {
            robot.container.removeFromParent()
            scene?.players[player]?.findEntity(named: "player.\(player.rawValue).surface")?.isEnabled = true
        }
        robots = [:]
        lights.removeFromParent()
    }
}
#endif
