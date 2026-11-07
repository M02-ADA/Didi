//
//  RobotSkeleton.swift
//  Sedactive
//

#if DEBUG
import Foundation
import RealityKit
import simd

// The avatar (`mascot-p1-lemon.usdz` / `mascot-p2-tangerine.usdz`, Codex's
// two colour variants of the final mascot, unchanged; identical rig and
// geometry, so this one description and `modelHeight` hold for both): one skinned mesh on a 20-joint UsdSkel, 1.398 m tall, origin
// between the feet with the soles on it, +Y up, facing −Z, +X = the
// avatar's anatomical right. Under our camera at +Z looking down −Z the
// virtual camera sees its back, and its right side is on screen right.
// Joint names, paths and parents match the earlier robots; bind transforms
// differ (short legs, shoulders under a large head), so everything
// geometric (leg lengths, ankle stance, knee plane) is read from the loaded
// bind pose, never assumed. Arm head clearance: `MascotPoseEnvelope`.

/// The skeleton as RealityKit reports it for one instance: joint paths,
/// parents and bind-pose local transforms (`ModelEntity.jointTransforms`).
nonisolated struct RobotSkeleton: Sendable {
    static let modelHeight: Float = 1.398

    let paths: [String]
    let parent: [Int?]
    let bind: [Transform]
    private let index: [String: Int]

    init(paths: [String], bind: [Transform]) {
        self.paths = paths
        self.bind = bind
        var index: [String: Int] = [:]
        for (i, path) in paths.enumerated() { index[String(path.split(separator: "/").last ?? "")] = i }
        self.index = index
        parent = paths.map { path in
            let parts = path.split(separator: "/")
            guard parts.count > 1 else { return nil }
            return paths.firstIndex(of: parts.dropLast().joined(separator: "/"))
        }
    }

    func callAsFunction(_ name: String) -> Int? { index[name] }

    static let requiredJoints = ["Root", "Pelvis", "Spine", "Chest", "Neck", "Head",
                                 "Shoulder_L", "UpperArm_L", "Forearm_L", "Hand_L", "Thigh_L", "Shin_L", "Foot_L",
                                 "Shoulder_R", "UpperArm_R", "Forearm_R", "Hand_R", "Thigh_R", "Shin_R", "Foot_R"]

    /// Bind-pose model-space rotations and positions (parents come first in RealityKit's order).
    func world(_ locals: [Transform]) -> (rotation: [simd_quatf], position: [SIMD3<Float>]) {
        var rotation = [simd_quatf](repeating: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), count: locals.count)
        var position = [SIMD3<Float>](repeating: .zero, count: locals.count)
        for i in locals.indices {
            if let p = parent[i] {
                rotation[i] = rotation[p] * locals[i].rotation
                position[i] = position[p] + rotation[p].act(locals[i].translation)
            } else {
                rotation[i] = locals[i].rotation
                position[i] = locals[i].translation
            }
        }
        return (rotation, position)
    }
}

/// What the robot should do this frame, in model space (metres, radians).
nonisolated struct RobotPoseTargets: Equatable, Sendable {
    enum Side: CaseIterable, Sendable { case left, right }

    /// Pelvis lowered over the planted feet.
    var pelvisDrop: Float = 0
    /// Trunk tilt toward +X (screen right), radians; split across Spine and Chest.
    var lean: Float = 0
    /// Head roll, counter-clockwise on screen, relative to the chest.
    var headRoll: Float = 0
    /// Model-space directions for the upper arm and forearm; `nil` keeps the bind pose.
    var upperArm: [Side: SIMD3<Float>] = [:]
    var forearm: [Side: SIMD3<Float>] = [:]
    /// Each foot's height above the floor (knee raise or step arc), metres.
    var footLift: [Side: Float] = [:]
    /// Each foot's sideways offset from its bind position (+X = screen right),
    /// metres: where the foot planner keeps a planted foot while the pelvis
    /// moves, or carries a stepping foot.
    var footShift: [Side: Float] = [:]
    /// How much of each arm's aimed pose to show (0 = bind pose, 1 = aimed);
    /// missing means 1 when a direction is present. Fades instead of snapping.
    var armWeight: [Side: Float] = [:]

    static let rest = RobotPoseTargets()

    /// Moves `k` (0…1) of the way toward `target`: scalars linearly, limb
    /// directions along the shorter arc, arm weights linearly. Used to smooth
    /// camera-rate targets at render rate.
    func blended(toward target: RobotPoseTargets, k: Float) -> RobotPoseTargets {
        func mix(_ a: Float, _ b: Float) -> Float { a + (b - a) * k }
        func dir(_ a: SIMD3<Float>?, _ b: SIMD3<Float>?) -> SIMD3<Float>? {
            guard let b else { return a }
            guard let a else { return b }
            let v = simd_normalize(a) * (1 - k) + simd_normalize(b) * k
            return simd_length(v) > 1e-5 ? simd_normalize(v) : b
        }
        var out = target
        out.pelvisDrop = mix(pelvisDrop, target.pelvisDrop)
        out.lean = mix(lean, target.lean)
        out.headRoll = mix(headRoll, target.headRoll)
        for side in Side.allCases {
            out.upperArm[side] = dir(upperArm[side], target.upperArm[side])
            out.forearm[side] = dir(forearm[side], target.forearm[side])
            out.footLift[side] = mix(footLift[side] ?? 0, target.footLift[side] ?? 0)
            out.footShift[side] = mix(footShift[side] ?? 0, target.footShift[side] ?? 0)
            let from = armWeight[side] ?? (upperArm[side] == nil ? 0 : 1)
            let to = target.armWeight[side] ?? (target.upperArm[side] == nil ? 0 : 1)
            out.armWeight[side] = mix(from, to)
        }
        return out
    }

    /// Human elbows flex to about 150°: a forearm folded further (tracking
    /// noise) is turned back to that limit within its own bend plane.
    static func limitElbow(upper: SIMD3<Float>, fore: SIMD3<Float>, maximumDegrees: Float = 150) -> SIMD3<Float> {
        let a = simd_normalize(upper), f = simd_normalize(fore)
        let limit = maximumDegrees * .pi / 180
        guard simd_dot(a, f) < cos(limit) else { return fore }
        var perpendicular = f - simd_dot(f, a) * a
        if simd_length(perpendicular) < 1e-5 { perpendicular = simd_cross(a, [0, 0, 1]) }
        if simd_length(perpendicular) < 1e-5 { perpendicular = simd_cross(a, [1, 0, 0]) }
        return simd_normalize(a * cos(limit) + simd_normalize(perpendicular) * sin(limit))
    }
}

/// Turns targets into a full array of local joint transforms, starting from
/// the bind pose every time. Limbs are aimed in model space and converted
/// into parent space through the posed parent, so children follow; rest
/// translations and unit scales are never changed except the pelvis drop.
/// Legs use two-bone IK toward each foot's own target (bind ankle plus
/// `footShift` and `footLift`), knees bending in the bind pose's own knee
/// plane (forward, −Z, give or take the rig's authored splay); feet are kept level.
nonisolated struct RobotPoseSolver: Sendable {
    let skeleton: RobotSkeleton
    private let thigh: Float
    private let shin: Float
    /// Computed once per instance, so a solve only allocates its output arrays.
    private let bindWorld: (rotation: [simd_quatf], position: [SIMD3<Float>])
    private let names: [String]
    private let childOf: [Int: Int]
    /// Per leg: thigh joint, foot joint and the bind hip-to-ankle distance (the reach kept at rest).
    private let legs: [(side: RobotPoseTargets.Side, thigh: Int, foot: Int, reach: Float)]
    /// Per leg (by thigh joint): the direction the knee bends, taken from the
    /// rig's own bind pose (the knee's offset from the hip-to-ankle line), so
    /// the rest targets reproduce the authored bind exactly. A straight bind
    /// leg, or one not bent forward, falls back to forward (−Z).
    private let kneeBend: [Int: SIMD3<Float>]

    init(skeleton: RobotSkeleton) {
        self.skeleton = skeleton
        let bindWorld = skeleton.world(skeleton.bind)
        self.bindWorld = bindWorld
        names = skeleton.paths.map { String($0.split(separator: "/").last ?? "") }
        var children: [Int: Int] = [:]
        for (i, p) in skeleton.parent.enumerated() { if let p, children[p] == nil { children[p] = i } }
        childOf = children
        func length(_ a: String, _ b: String) -> Float {
            guard let i = skeleton(a), let j = skeleton(b) else { return 0.29 }
            return simd_distance(bindWorld.position[i], bindWorld.position[j])
        }
        thigh = length("Thigh_L", "Shin_L")
        shin = length("Shin_L", "Foot_L")
        let full = thigh + shin - 1e-4
        legs = [(RobotPoseTargets.Side.left, "Thigh_L", "Foot_L"), (.right, "Thigh_R", "Foot_R")].compactMap { side, a, b in
            guard let i = skeleton(a), let j = skeleton(b) else { return nil }
            return (side, i, j, min(full, simd_distance(bindWorld.position[i], bindWorld.position[j])))
        }
        var bend: [Int: SIMD3<Float>] = [:]
        for name in ["Thigh_L", "Thigh_R"] {
            guard let hip = skeleton(name), let knee = skeleton(name.replacingOccurrences(of: "Thigh", with: "Shin")),
                  let foot = skeleton(name.replacingOccurrences(of: "Thigh", with: "Foot")) else { continue }
            let axis = simd_normalize(bindWorld.position[foot] - bindWorld.position[hip])
            let offset = bindWorld.position[knee] - bindWorld.position[hip]
            let perpendicular = offset - simd_dot(offset, axis) * axis
            let forward = simd_length(perpendicular) > 0.005 && simd_dot(simd_normalize(perpendicular), [0, 0, -1]) > 0.3
            bend[hip] = forward ? simd_normalize(perpendicular) : [0, 0, -1]
        }
        kneeBend = bend
    }

    /// How much further the pelvis must drop so both feet can reach their
    /// targets (knees bend, as when standing over spread feet). Zero at rest and
    /// whenever the feet are under the hips; a foot too far sideways for any
    /// drop still falls short (`reachShortfall`).
    func reachDrop(_ t: RobotPoseTargets) -> Float {
        var drop: Float = 0
        for leg in legs {
            var hip = bindWorld.position[leg.thigh]
            hip.y -= t.pelvisDrop
            let ankle = bindWorld.position[leg.foot]
            let target = SIMD3<Float>(ankle.x + (t.footShift[leg.side] ?? 0), ankle.y + (t.footLift[leg.side] ?? 0), ankle.z)
            let horizontal = (target.x - hip.x) * (target.x - hip.x) + (target.z - hip.z) * (target.z - hip.z)
            guard horizontal < leg.reach * leg.reach else { continue }
            drop = max(drop, (hip.y - target.y) - sqrt(leg.reach * leg.reach - horizontal))
        }
        return drop > 1e-5 ? drop : 0
    }

    var legLength: Float { thigh + shin }

    func solve(_ t: RobotPoseTargets) -> [Transform] { solveDetailed(t).local }

    /// The solve plus, per leg, how far (metres) the requested ankle lies
    /// beyond the leg's reach (0 when reached): the foot then stops short.
    func solveDetailed(_ t: RobotPoseTargets) -> (local: [Transform], reachShortfall: [RobotPoseTargets.Side: Float]) {
        let s = skeleton
        var shortfall: [RobotPoseTargets.Side: Float] = [:]
        var local = s.bind
        var rotation = [simd_quatf](repeating: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), count: local.count)
        var position = [SIMD3<Float>](repeating: .zero, count: local.count)
        // Planned knee/ankle per leg, filled when the thigh is reached (after the pelvis is posed).
        var knee = [SIMD3<Float>?](repeating: nil, count: local.count)
        var ankle = [SIMD3<Float>?](repeating: nil, count: local.count)

        func parentWorld(_ i: Int) -> simd_quatf { s.parent[i].map { rotation[$0] } ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }

        /// Rotates joint `i` so its segment toward `child` points along `direction` (model space).
        func aim(_ i: Int, toward child: Int, _ direction: SIMD3<Float>) {
            guard simd_length(direction) > 1e-5, simd_length(local[child].translation) > 1e-6 else { return }
            let p = parentWorld(i)
            let base = p * s.bind[i].rotation
            let from = simd_normalize(base.act(local[child].translation))
            let to = simd_normalize(direction)
            let delta = simd_dot(from, to) < -0.9999
                ? simd_quatf(angle: .pi, axis: simd_normalize(simd_cross(from, abs(from.x) < 0.9 ? [1, 0, 0] : [0, 0, 1])))
                : simd_quatf(from: from, to: to)
            local[i].rotation = p.inverse * (delta * base)
        }

        func name(_ i: Int) -> String { names[i] }

        /// Keeps `weight` of the aimed local rotation, the rest of the bind rotation.
        func blendTowardBind(_ i: Int, weight: Float) {
            guard weight < 0.999 else { return }
            local[i].rotation = simd_slerp(s.bind[i].rotation, local[i].rotation, max(0, weight))
        }
        func side(_ n: String) -> RobotPoseTargets.Side { n.hasSuffix("_L") ? .left : .right }

        for i in local.indices {
            let n = name(i)
            switch n {
            case "Pelvis":
                local[i].translation.y -= t.pelvisDrop + reachDrop(t)
            case "Spine", "Chest":
                let tilt = t.lean / 2 * (n == "Spine" ? 1 : 2)
                if let c = childOf[i] { aim(i, toward: c, [sin(tilt), cos(tilt), 0]) }
            case "Head":
                let world = -t.lean + t.headRoll  // absolute roll on screen
                // The head is a leaf: set its model-space roll directly over the bind orientation.
                local[i].rotation = parentWorld(i).inverse * (simd_quatf(angle: world, axis: [0, 0, 1]) * bindWorld.rotation[i])
            case "UpperArm_L", "UpperArm_R":
                if let d = t.upperArm[side(n)], let c = childOf[i] {
                    aim(i, toward: c, d)
                    blendTowardBind(i, weight: t.armWeight[side(n)] ?? 1)
                }
            case "Forearm_L", "Forearm_R":
                if var d = t.forearm[side(n)], let c = childOf[i] {
                    if let upper = t.upperArm[side(n)] { d = RobotPoseTargets.limitElbow(upper: upper, fore: d) }
                    aim(i, toward: c, d)
                    blendTowardBind(i, weight: t.armWeight[side(n)] ?? 1)
                }
            case "Thigh_L", "Thigh_R":
                guard let shinIndex = childOf[i], let footIndex = childOf[shinIndex] else { break }
                // Hip position with the pelvis already posed.
                let hip = (s.parent[i].map { position[$0] } ?? .zero) + parentWorld(i).act(local[i].translation)
                let bindAnkle = bindWorld.position[footIndex]
                let target = SIMD3<Float>(bindAnkle.x + (t.footShift[side(n)] ?? 0), bindAnkle.y + (t.footLift[side(n)] ?? 0), bindAnkle.z)
                var toAnkle = target - hip
                let reach = min(simd_length(toAnkle), legLength - 1e-4)
                shortfall[side(n)] = max(0, simd_length(toAnkle) - legLength)
                toAnkle = simd_normalize(toAnkle) * reach
                let along = simd_normalize(toAnkle)
                let a = (thigh * thigh + reach * reach - shin * shin) / (2 * reach)
                let h = sqrt(max(0, thigh * thigh - a * a))
                // Knees bend the way the bind pose bends them (forward, −Z, for a straight bind leg).
                let hint = kneeBend[i] ?? [0, 0, -1]
                var bend = hint - simd_dot(hint, along) * along
                bend = simd_length(bend) > 1e-5 ? simd_normalize(bend) : [0, 0, -1]
                let k = hip + along * a + bend * h
                knee[i] = k
                ankle[shinIndex] = hip + toAnkle
                aim(i, toward: shinIndex, k - hip)
            case "Shin_L", "Shin_R":
                if let parent = s.parent[i], let k = knee[parent], let a = ankle[i], let c = childOf[i] {  // (arrays, no hashing)
                    aim(i, toward: c, a - k)
                }
            case "Foot_L", "Foot_R":
                // Level sole: the foot keeps its bind orientation in model space.
                local[i].rotation = parentWorld(i).inverse * bindWorld.rotation[i]
            default:
                break
            }
            if let p = s.parent[i] {
                rotation[i] = rotation[p] * local[i].rotation
                position[i] = position[p] + rotation[p].act(local[i].translation)
            } else {
                rotation[i] = local[i].rotation
                position[i] = local[i].translation
            }
        }
        return (local, shortfall)
    }
}
#endif
