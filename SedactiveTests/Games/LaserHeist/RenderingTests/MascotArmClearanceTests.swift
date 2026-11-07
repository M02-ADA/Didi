import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// The mascot's arms against its oversized head, on each colour variant's real skinned
/// mesh: vertices are skinned on the CPU from the imported joint weights and
/// inverse bind matrices, posed by the game's own `RobotPoseSolver`.
/// Targets are SYNTHETIC model-space directions (what the retargeter emits).
@MainActor
struct MascotArmClearanceTests {
    /// The mesh as skinnable vertices, plus the head's triangles (Head-only weights).
    struct Mesh {
        var positions: [SIMD3<Float>] = []
        var influences: [[(joint: Int, weight: Float)]] = []
        var inverseBind: [Int: simd_float4x4] = [:]
        var headTriangles: [(Int, Int, Int)] = []
        var head: [Int] = []
        var arm: [Int] = []
    }

    private func load(_ player: PlayerID) async throws -> (RobotSkeleton, RobotPoseSolver, Mesh) {
        let template = try await RobotAvatarLayer.loadTemplate(for: player)
        let model = try #require(RobotAvatarLayer.skinnedModel(in: template))
        let skeleton = RobotSkeleton(paths: model.jointNames, bind: model.jointTransforms)
        let contents = try #require(model.model?.mesh.contents)
        var mesh = Mesh()
        var jointMap: [String: [Int]] = [:]  // mesh skeleton id → our joint index per mesh joint
        for meshSkeleton in contents.skeletons {
            let map = meshSkeleton.joints.map { skeleton(String($0.name.split(separator: "/").last ?? "")) ?? -1 }
            jointMap[meshSkeleton.id] = map
            for (k, j) in map.enumerated() where j >= 0 { mesh.inverseBind[j] = meshSkeleton.joints[k].inverseBindPoseMatrix }
        }
        let headIndex = try #require(skeleton("Head"))
        let armJoints = Set(["UpperArm_L", "Forearm_L", "Hand_L", "UpperArm_R", "Forearm_R", "Hand_R"].compactMap { skeleton($0) })
        for meshModel in contents.models {
            for part in meshModel.parts {
                guard let skin = part.jointInfluences, let map = jointMap[part.skeletonID ?? ""] else { continue }
                let base = mesh.positions.count
                let positions = part.positions.elements
                let all = skin.influences.elements
                let per = all.count / max(1, positions.count)
                for v in positions.indices {
                    mesh.positions.append(positions[v])
                    var w: [(joint: Int, weight: Float)] = []
                    var total: Float = 0, headWeight: Float = 0, armWeight: Float = 0
                    for k in 0..<per {
                        let influence = all[v * per + k]
                        guard influence.weight > 0 else { continue }
                        let joint = map[influence.jointIndex]
                        w.append((joint, influence.weight))
                        total += influence.weight
                        if joint == headIndex { headWeight += influence.weight }
                        if armJoints.contains(joint) { armWeight += influence.weight }
                    }
                    mesh.influences.append(w)
                    if headWeight > 0.99 * total { mesh.head.append(base + v) }
                    if armWeight > 0.5 * total { mesh.arm.append(base + v) }
                }
                let headSet = Set(mesh.head)
                if let indices = part.triangleIndices?.elements {
                    for t in stride(from: 0, to: indices.count - 2, by: 3) {
                        let a = base + Int(indices[t]), b = base + Int(indices[t + 1]), c = base + Int(indices[t + 2])
                        if headSet.contains(a) && headSet.contains(b) && headSet.contains(c) { mesh.headTriangles.append((a, b, c)) }
                    }
                }
            }
        }
        return (skeleton, RobotPoseSolver(skeleton: skeleton), mesh)
    }

    /// Skinned positions (model space) of `indices` under the joint `locals`.
    private func skin(_ s: RobotSkeleton, _ mesh: Mesh, _ locals: [Transform], _ indices: [Int]) -> [Int: SIMD3<Float>] {
        let world = s.world(locals)
        var matrices: [Int: simd_float4x4] = [:]
        for (j, inverse) in mesh.inverseBind {
            let m = Transform(scale: .one, rotation: world.rotation[j], translation: world.position[j]).matrix
            matrices[j] = m * inverse
        }
        var out: [Int: SIMD3<Float>] = [:]
        for i in indices {
            let p = SIMD4<Float>(mesh.positions[i], 1)
            var sum = SIMD4<Float>.zero
            var total: Float = 0
            for (j, w) in mesh.influences[i] where j >= 0 { sum += w * (matrices[j] ?? matrix_identity_float4x4) * p; total += w }
            out[i] = total > 0 ? SIMD3(sum.x, sum.y, sum.z) / total : mesh.positions[i]
        }
        return out
    }

    struct Clearance { var inside = 0; var nearest: Float = .infinity }

    /// Arm vertices inside the closed head shell (ray parity along +X), and the closest arm-to-head vertex distance.
    /// `firstOnly`: stop at the first arm vertex inside the head (and skip the distance).
    private func clearance(_ s: RobotSkeleton, _ mesh: Mesh, _ locals: [Transform], firstOnly: Bool = false) -> Clearance {
        let headIndices = Array(Set(mesh.headTriangles.flatMap { [$0.0, $0.1, $0.2] }))
        let head = skin(s, mesh, locals, headIndices), arm = skin(s, mesh, locals, mesh.arm)
        let lo = head.values.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }
        let hi = head.values.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
        var result = Clearance()
        let headPoints = Array(head.values)
        // Posed triangles with their bounds, so axis-aligned rays skip most of them cheaply.
        let triangles = mesh.headTriangles.map { t -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) in
            let a = head[t.0]!, b = head[t.1]!, c = head[t.2]!
            return (a, b, c, simd_min(a, simd_min(b, c)), simd_max(a, simd_max(b, c)))
        }
        for (_, p) in arm {
            guard all(p .> lo - 0.03) && all(p .< hi + 0.03) else { continue }
            if !firstOnly { for q in headPoints { result.nearest = min(result.nearest, simd_distance_squared(p, q)) } }
            guard all(p .> lo) && all(p .< hi) else { continue }
            // Parity of crossings along ±Z and ±X (the shell may be open at the neck): inside when 3 of 4 agree.
            var odd = 0
            for direction in [SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, -1), SIMD3<Float>(1, 0, 0), SIMD3<Float>(-1, 0, 0)] {
                let alongZ = direction.z != 0
                var hits = 0
                for (a, b, c, low, high) in triangles {
                    if alongZ {
                        guard p.x >= low.x, p.x <= high.x, p.y >= low.y, p.y <= high.y else { continue }
                    } else {
                        guard p.z >= low.z, p.z <= high.z, p.y >= low.y, p.y <= high.y else { continue }
                    }
                    if Self.ray(p, direction, a, b, c) { hits += 1 }
                }
                if hits % 2 == 1 { odd += 1 }
            }
            if odd >= 3 { result.inside += 1; if firstOnly { break } }
        }
        result.nearest = result.nearest.squareRoot()
        return result
    }

    /// Möller–Trumbore ray/triangle test (t > 0).
    private static func ray(_ o: SIMD3<Float>, _ d: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Bool {
        let e1 = b - a, e2 = c - a, p = simd_cross(d, e2), det = simd_dot(e1, p)
        guard abs(det) > 1e-9 else { return false }
        let inv = 1 / det, s = o - a, u = simd_dot(s, p) * inv
        guard u >= 0 && u <= 1 else { return false }
        let q = simd_cross(s, e1), v = simd_dot(d, q) * inv
        guard v >= 0 && u + v <= 1 else { return false }
        return simd_dot(e2, q) * inv > 1e-6
    }

    /// Raised-arm poses the live retargeter can produce (model space, +X = anatomical right).
    static let poses: [(String, RobotPoseTargets)] = {
        func up(_ sides: [RobotPoseTargets.Side], _ d: SIMD3<Float> = [0, 1, 0]) -> RobotPoseTargets {
            var t = RobotPoseTargets()
            for side in sides { t.upperArm[side] = d; t.forearm[side] = d }
            return t
        }
        var crouch = up([.left, .right]); crouch.pelvisDrop = 0.12
        var leanR = up([.left, .right]); leanR.lean = 0.3
        var leanL = up([.left, .right]); leanL.lean = -0.3; leanL.headRoll = 0.2
        var step = up([.right]); step.footShift[.right] = 0.06; step.footLift[.right] = 0.03
        var bentElbow = RobotPoseTargets()
        bentElbow.upperArm[.right] = simd_normalize([1, 0.4, 0]); bentElbow.forearm[.right] = [0, 1, 0]
        var across = RobotPoseTargets()
        across.upperArm[.right] = simd_normalize([-0.3, 1, -0.1]); across.forearm[.right] = simd_normalize([-0.5, 1, -0.1])
        return [("left arm up", up([.left])), ("right arm up", up([.right])), ("both arms up", up([.left, .right])),
                ("both up, forward", up([.left, .right], simd_normalize([0, 1, -0.3]))),
                ("both up in deep crouch", crouch), ("both up, lean right", leanR), ("both up, lean left + head", leanL),
                ("right up while stepping", step), ("bent elbow, forearm up", bentElbow), ("reach across, up", across)]
    }()

    @Test(arguments: PlayerID.allCases)
    func skinningReproducesTheBindMesh(player: PlayerID) async throws {
        let (s, _, mesh) = try await load(player)
        #expect(mesh.head.count > 100 && mesh.arm.count > 100 && mesh.headTriangles.count > 100,
                "head \(mesh.head.count) arm \(mesh.arm.count) tris \(mesh.headTriangles.count)")
        let posed = skin(s, mesh, s.bind, Array(mesh.positions.indices))
        let error = posed.map { simd_distance($0.value, mesh.positions[$0.key]) }.max() ?? .infinity
        #expect(error < 1e-4, "bind skinning error \(error)")
        let template = try await RobotAvatarLayer.loadTemplate(for: player)
        let model = try #require(RobotAvatarLayer.skinnedModel(in: template))
        let triangles = model.model?.mesh.contents.models.reduce(0) { $0 + $1.parts.reduce(0) { $0 + ($1.triangleIndices?.count ?? 0) / 3 } } ?? 0
        let materials = model.model?.materials.compactMap { $0 as? PhysicallyBasedMaterial } ?? []
        print("MASCOTMESH \(player.rawValue) vertices \(mesh.positions.count) triangles \(triangles) materials \(model.model?.materials.count ?? 0)",
              materials.map { String(format: "%@ rough %.2f metal %.2f spec %.3f", $0.name ?? "?", $0.roughness.scale, $0.metallic.scale, $0.specular.scale) })
        // Matte: no metal, high roughness on every surface.
        #expect(!materials.isEmpty && materials.allSatisfy { $0.metallic.scale < 0.01 && $0.roughness.scale > 0.85 })
        let ys = posed.values.map(\.y)
        #expect(abs((ys.max()! - ys.min()!) - RobotSkeleton.modelHeight) < 0.005 && abs(ys.min()!) < 0.005)
    }

    /// Without the envelope a raised arm goes through the head; with it, no
    /// arm vertex enters the head in any tested pose.
    @Test(arguments: PlayerID.allCases)
    func raisedArmsClearTheHeadOnlyWithTheEnvelope(player: PlayerID) async throws {
        let (s, solver, mesh) = try await load(player)
        var without = 0
        for (name, raw) in Self.poses {
            var t = raw
            MascotPoseEnvelope.apply(to: &t)
            let bare = clearance(s, mesh, solver.solve(raw), firstOnly: true), fitted = clearance(s, mesh, solver.solve(t))
            without += bare.inside
            print(String(format: "ARMCLEAR \(player.rawValue) %@ | raw: %@ | envelope: %d inside, nearest %.1f mm",
                         name, bare.inside > 0 ? "arm inside head" : "clear", fitted.inside, fitted.nearest * 1000))
            #expect(fitted.inside == 0, "\(name): \(fitted.inside) arm vertices inside the head")
        }
        #expect(without > 0, "the raw targets never reached the head: the envelope would be unnecessary")
        #expect(RobotAvatarLayer.headClearance)
    }

    /// Raising and lowering an arm moves the shown direction smoothly: no step
    /// between neighbouring inputs, downward targets untouched, sides independent.
    @Test func envelopeIsContinuousAndSideSpecific() {
        var previous: SIMD3<Float>?
        var worst: Float = 0
        for i in 0...180 {
            // Right arm swung from straight down, out to the side, to straight up.
            let a = Float(i) * .pi / 180
            var t = RobotPoseTargets()
            t.upperArm[.right] = [sin(a), -cos(a), 0]
            MascotPoseEnvelope.apply(to: &t)
            let d = t.upperArm[.right]!
            if let previous { worst = max(worst, acos(min(1, simd_dot(previous, d)))) }
            previous = d
            #expect(t.upperArm[.left] == nil)
            if i < 90 { #expect(d == simd_float3(sin(a), -cos(a), 0)) }  // at or below horizontal: untouched
            #expect(d.x >= -1e-6)  // never turned toward the head side
        }
        #expect(worst < 3 * .pi / 180, "largest jump \(worst * 180 / .pi)° per 1° of input")
        // The left arm mirrors the right.
        var l = RobotPoseTargets(), r = RobotPoseTargets()
        l.upperArm[.left] = [-0.2, 1, -0.1]; r.upperArm[.right] = [0.2, 1, -0.1]
        MascotPoseEnvelope.apply(to: &l); MascotPoseEnvelope.apply(to: &r)
        #expect(simd_distance(l.upperArm[.left]! * SIMD3(-1, 1, 1), r.upperArm[.right]!) < 1e-6)
    }
}
