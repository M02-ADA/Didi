//
//  RobotSkeleton.swift
//  Sedactive
//

#if DEBUG
import Foundation
import RealityKit
import simd

// The Codex robot (`laserheist-robot.usdz`, unchanged): one skinned mesh on a
// 20-joint UsdSkel, 1.398 m tall, origin between the feet, +Y up, facing −Z,
// +X = the robot's anatomical right. Under our camera at +Z looking down −Z
// the virtual camera sees its back, and its right side is on screen right.

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
    /// Each foot's height above the floor (knee raise), metres.
    var footLift: [Side: Float] = [:]

    static let rest = RobotPoseTargets()
}

/// Turns targets into a full array of local joint transforms, starting from
/// the bind pose every time. Limbs are aimed in model space and converted
/// into parent space through the posed parent, so children follow; rest
/// translations and unit scales are never changed except the pelvis drop.
/// Legs use two-bone IK toward the planted (or lifted) ankle, knees bending
/// forward (−Z); feet are kept level.
nonisolated struct RobotPoseSolver: Sendable {
    let skeleton: RobotSkeleton
    private let thigh: Float
    private let shin: Float
    /// Computed once per instance, so a solve only allocates its output arrays.
    private let bindWorld: (rotation: [simd_quatf], position: [SIMD3<Float>])
    private let names: [String]
    private let childOf: [Int: Int]

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
    }

    var legLength: Float { thigh + shin }

    func solve(_ t: RobotPoseTargets) -> [Transform] {
        let s = skeleton
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
        func side(_ n: String) -> RobotPoseTargets.Side { n.hasSuffix("_L") ? .left : .right }

        for i in local.indices {
            let n = name(i)
            switch n {
            case "Pelvis":
                local[i].translation.y -= t.pelvisDrop
            case "Spine", "Chest":
                let tilt = t.lean / 2 * (n == "Spine" ? 1 : 2)
                if let c = childOf[i] { aim(i, toward: c, [sin(tilt), cos(tilt), 0]) }
            case "Head":
                let world = -t.lean + t.headRoll  // absolute roll on screen
                // The head is a leaf: set its model-space roll directly over the bind orientation.
                local[i].rotation = parentWorld(i).inverse * (simd_quatf(angle: world, axis: [0, 0, 1]) * bindWorld.rotation[i])
            case "UpperArm_L", "UpperArm_R":
                if let d = t.upperArm[side(n)], let c = childOf[i] { aim(i, toward: c, d) }
            case "Forearm_L", "Forearm_R":
                if let d = t.forearm[side(n)], let c = childOf[i] { aim(i, toward: c, d) }
            case "Thigh_L", "Thigh_R":
                guard let shinIndex = childOf[i], let footIndex = childOf[shinIndex] else { break }
                // Hip position with the pelvis already posed.
                let hip = (s.parent[i].map { position[$0] } ?? .zero) + parentWorld(i).act(local[i].translation)
                let bindAnkle = bindWorld.position[footIndex]
                let target = SIMD3<Float>(bindAnkle.x, bindAnkle.y + (t.footLift[side(n)] ?? 0), bindAnkle.z)
                var toAnkle = target - hip
                let reach = min(simd_length(toAnkle), legLength - 1e-4)
                toAnkle = simd_normalize(toAnkle) * reach
                let along = simd_normalize(toAnkle)
                let a = (thigh * thigh + reach * reach - shin * shin) / (2 * reach)
                let h = sqrt(max(0, thigh * thigh - a * a))
                var bend = SIMD3<Float>(0, 0, -1) - simd_dot([0, 0, -1], along) * along  // knees forward (−Z)
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
        return local
    }
}
#endif
