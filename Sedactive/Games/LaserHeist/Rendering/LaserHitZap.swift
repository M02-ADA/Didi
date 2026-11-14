//
//  LaserHitZap.swift
//  Sedactive
//

import RealityKit
import UIKit

/// The electric VFX of one mascot's laser HIT (`LaserHitReaction`), attached to that mascot's
/// lane so they follow its body: a contact flash where the beam meets it, short jagged arcs
/// between points of its posed silhouette, a soft coral glow behind it, and a few residual
/// sparks that fall away. Everything is built once and only moved, shown and faded; the
/// intensities come from the reaction's frame, so the effects peak with the recoil and the
/// shudder and are gone, not left behind, when the reaction ends.
///
/// Palette: the beam's own hot white and coral (`LaserGateArt`), so the zap reads as the laser.
@MainActor
final class LaserHitZap {
    /// Points of the posed mascot, in its lane's space (metres).
    struct Body {
        var headTop: SIMD3<Float>
        var headCenter: SIMD3<Float>
        /// Half the head's drawn width (the mascot's head is its widest part).
        var headHalfWidth: Float
        var chest: SIMD3<Float>
        var pelvis: SIMD3<Float>
        var hands: (left: SIMD3<Float>, right: SIMD3<Float>)
        var knees: (left: SIMD3<Float>, right: SIMD3<Float>)
        var feet: (left: SIMD3<Float>, right: SIMD3<Float>)
    }

    let root = Entity()
    private let flash: ModelEntity
    private let glow: ModelEntity
    private let arcs: [ModelEntity]
    private let sparks: [ModelEntity]

    /// How far in front of the body (toward the camera) the effects stand, so the body never
    /// hides them; the glow stands behind it.
    static let front: Float = 0.34
    static let behind: Float = 0.3
    /// How often an arc changes shape (s): lively, never a strobe.
    static let arcStep = 0.05
    static let arcSlots = 3
    static let sparkCount = 7

    init() {
        let r = Resources.shared
        root.name = "laserHitZap"
        root.isEnabled = false
        flash = ModelEntity(mesh: r.quad, materials: [r.flashMaterial])
        flash.name = "laserHitZap.flash"
        glow = ModelEntity(mesh: r.quad, materials: [r.glowMaterial])
        glow.name = "laserHitZap.glow"
        arcs = (0..<Self.arcSlots).map { k in
            let arc = ModelEntity(mesh: r.arcMeshes[k % r.arcMeshes.count], materials: [r.arcGlowMaterial, r.arcCoreMaterial])
            arc.name = "laserHitZap.arc\(k)"
            return arc
        }
        sparks = (0..<Self.sparkCount).map { k in
            let spark = ModelEntity(mesh: r.quad, materials: [r.sparkMaterial])
            spark.name = "laserHitZap.spark\(k)"
            return spark
        }
        for part in [glow, flash] + arcs + sparks { root.addChild(part) }
    }

    /// Shows the effects at `tau` seconds into `reaction`. `contact`: where the beam meets the
    /// mascot (lane space).
    func show(_ reaction: LaserHitReaction, frame: LaserHitReaction.Frame, at tau: Double,
              body: Body, contact: SIMD3<Float>) {
        guard frame.arcs > 0.001 || frame.glow > 0.001 || frame.flash > 0.001 || frame.sparks else { hide(); return }
        root.isEnabled = true
        // In front of the struck part as posed (the head tips toward the camera in the recoil).
        let depth = reaction.region == .upper ? max(body.chest.z, body.headCenter.z) : body.pelvis.z
        // Contact flash: a hot pop at the beam, growing as it fades.
        set(flash, opacity: frame.flash * 0.95)
        if frame.flash > 0.001 {
            let size: Float = (reaction.reduceMotion ? 0.42 : 0.5) * (0.7 + 0.6 * (1 - frame.flash))
            flash.position = [contact.x, contact.y, depth + Self.front + 0.02]
            flash.scale = [size, size, 1]
        }
        // Glow behind the struck part of the body: it rims the silhouette, never covers the face.
        set(glow, opacity: frame.glow)
        if frame.glow > 0.001 {
            let center = reaction.region == .upper ? (body.headCenter + body.chest) / 2 : (body.pelvis + body.knees.left + body.knees.right) / 3
            let size: Float = reaction.region == .upper ? 1.35 : 1.15
            glow.position = [center.x, center.y, depth - Self.behind]
            glow.scale = [size, size, 1]
        }
        showArcs(reaction, intensity: frame.arcs, at: tau, body: body, depth: depth)
        showSparks(reaction, at: tau, from: [contact.x, contact.y, depth + Self.front + 0.04], visible: frame.sparks)
    }

    func hide() {
        guard root.isEnabled else { return }
        root.isEnabled = false
    }

    // MARK: - Arcs

    /// Up to three short arcs crackling OUT of the struck part's silhouette: each starts at an
    /// edge point (pushed just outside the body) and jags away from it, re-shaped every `arcStep`
    /// in a deterministic pattern; each holds its place for two steps so nothing strobes. Fewer
    /// arcs show as the energy decays. (Simulator review, 14 November 2026: arcs joining distant
    /// body points caged the whole mascot and hid it.)
    private func showArcs(_ reaction: LaserHitReaction, intensity: Float, at tau: Double, body: Body, depth: Float) {
        let anchors = Self.anchors(body, region: reaction.region)
        let step = Int(tau / Self.arcStep)
        let meshes = Resources.shared.arcMeshes
        let center = reaction.region == .upper ? body.headCenter : (body.pelvis + body.knees.left + body.knees.right) / 3
        for (k, arc) in arcs.enumerated() {
            let threshold: Float = [0.08, 0.3, 0.55, 2][min(k, 3)]
            guard intensity > threshold else { set(arc, opacity: 0); continue }
            let hold = (step + k) / 2
            var a = anchors[Int(LaserHitReaction.noise(reaction.seed, k, hold) * Float(anchors.count)) % anchors.count]
            var outward = SIMD2<Float>(a.x - center.x, a.y - center.y)
            outward = simd_length(outward) > 1e-4 ? simd_normalize(outward) : [0, 1]
            a.x += outward.x * 0.03
            a.y += outward.y * 0.03
            // Along the outline (either way round), tipped up to ±35° off it, so the arc hugs the
            // silhouette's edge instead of floating away from it.
            let along: Float = LaserHitReaction.noise(reaction.seed, k + 3, hold) < 0.5 ? -1 : 1
            let swing = (LaserHitReaction.noise(reaction.seed, k + 5, hold) - 0.5) * 2 * 35 * Float.pi / 180
            let angle = atan2(outward.y, outward.x) + along * Float.pi / 2 + swing
            let length: Float = 0.2 + 0.14 * LaserHitReaction.noise(reaction.seed, k + 9, step)
            let variant = Int(LaserHitReaction.noise(reaction.seed, k + 17, step) * Float(meshes.count)) % meshes.count
            if arc.model?.mesh !== meshes[variant] { arc.model?.mesh = meshes[variant] }
            let flip: Float = LaserHitReaction.noise(reaction.seed, k + 31, step) < 0.5 ? -1 : 1
            // In front of its own posed point: the recoil tips the big head toward the camera.
            arc.position = [a.x, a.y, a.z + Self.front + 0.01 * Float(k)]
            arc.orientation = simd_quatf(angle: angle, axis: [0, 0, 1])
            arc.scale = [length, length * flip, 1]
            set(arc, opacity: min(1, intensity * 1.15))
        }
    }

    /// Edge points of the struck part: the head and shoulders for a high beam, the legs for a low one.
    private static func anchors(_ b: Body, region: LaserHitReaction.Region) -> [SIMD3<Float>] {
        let side = SIMD3<Float>(b.headHalfWidth * 0.95, 0, 0)
        let shoulder = SIMD3<Float>(b.headHalfWidth * 0.55, 0, 0)
        switch region {
        case .upper:
            return [b.headTop - side * 0.5, b.headTop + side * 0.5, b.headCenter - side, b.headCenter + side,
                    b.chest - shoulder, b.chest + shoulder, b.hands.left, b.hands.right]
        case .lower:
            let hip = SIMD3<Float>(b.headHalfWidth * 0.4, 0, 0)
            return [b.pelvis - hip, b.pelvis + hip, b.knees.left - hip * 0.5, b.knees.right + hip * 0.5,
                    b.feet.left - hip * 0.6, b.feet.right + hip * 0.6]
        }
    }

    // MARK: - Sparks

    /// A few hot sparks thrown up and out from the contact, falling under gravity and
    /// shrinking as they fade. Positions are a function of time only (no simulation state).
    private func showSparks(_ reaction: LaserHitReaction, at tau: Double, from origin: SIMD3<Float>, visible: Bool) {
        let age = Float(tau - LaserHitReaction.sparkStart)
        let life = Float(LaserHitReaction.sparkLife)
        for (k, spark) in sparks.enumerated() {
            let lifetime = life * (0.6 + 0.4 * LaserHitReaction.noise(reaction.seed, k, 7))
            guard visible, !reaction.reduceMotion, age >= 0, age < lifetime else { set(spark, opacity: 0); continue }
            let angle = Float.pi * (0.12 + 0.76 * (Float(k) + LaserHitReaction.noise(reaction.seed, k, 3)) / Float(sparks.count))
            let speed: Float = 1.1 + 1.2 * LaserHitReaction.noise(reaction.seed, k, 5)
            let gravity: Float = 5.5
            let p = origin + SIMD3<Float>(cos(angle) * speed * age, sin(angle) * speed * age - gravity * age * age / 2, 0)
            let fade = 1 - age / lifetime
            let size: Float = 0.055 * (0.35 + 0.65 * fade)
            spark.position = p
            spark.scale = [size, size, 1]
            set(spark, opacity: fade)
        }
    }

    private func set(_ entity: ModelEntity, opacity: Float) {
        let shown = opacity > 0.001
        if entity.isEnabled != shown { entity.isEnabled = shown }
        guard shown else { return }
        if entity.components[OpacityComponent.self]?.opacity != opacity {
            entity.components.set(OpacityComponent(opacity: opacity))
        }
    }

    // MARK: - Shared resources (built once)

    @MainActor
    final class Resources {
        static let shared = Resources()
        let quad: MeshResource
        let arcMeshes: [MeshResource]
        let flashMaterial: UnlitMaterial
        let glowMaterial: UnlitMaterial
        let sparkMaterial: UnlitMaterial
        let arcGlowMaterial: UnlitMaterial
        let arcCoreMaterial: UnlitMaterial

        private init() {
            quad = .generatePlane(width: 1, height: 1)
            arcMeshes = (0..<6).compactMap { Self.arcMesh(variant: $0) }
            let hot = LaserGateArt.hot, coral = LaserGateArt.coral
            flashMaterial = Self.material(Self.radial(inner: hot, outer: coral, falloff: 1.6))
            glowMaterial = Self.material(Self.radial(inner: coral.mix(hot, 0.25), outer: LaserGateArt.spill, falloff: 2.4, peak: 0.55))
            sparkMaterial = Self.material(Self.radial(inner: hot, outer: coral.mix(hot, 0.4), falloff: 1.2))
            arcGlowMaterial = Self.solid(coral, opacity: 0.55)
            arcCoreMaterial = Self.solid(hot, opacity: 1)
        }

        /// A jagged stroke from (0, 0) to (1, 0) in two parts (material 0: a wide coral glow,
        /// material 1: a thin hot core), with seven kinks whose sizes differ per variant.
        static func arcMesh(variant: Int) -> MeshResource? {
            let segments = 7
            var points: [SIMD2<Float>] = [[0, 0]]
            for i in 1..<segments {
                let size = 0.06 + 0.1 * LaserHitReaction.noise(UInt32(variant + 1), i)
                let x = (Float(i) + (LaserHitReaction.noise(UInt32(variant + 1), i, 9) - 0.5) * 0.5) / Float(segments)
                points.append([x, (i % 2 == 0 ? -1 : 1) * size])
            }
            points.append([1, 0])
            func ribbon(_ halfWidth: Float, material: UInt32, z: Float) -> MeshDescriptor {
                var positions: [SIMD3<Float>] = [], indices: [UInt32] = []
                for i in 0..<(points.count - 1) {
                    let a = points[i], b = points[i + 1]
                    let d = simd_normalize(b - a), n = SIMD2<Float>(-d.y, d.x) * halfWidth
                    let base = UInt32(positions.count)
                    // Each segment a quad, overlapping its neighbours a little at the kinks.
                    let a0 = a - d * halfWidth, b0 = b + d * halfWidth
                    positions += [[a0.x - n.x, a0.y - n.y, z], [a0.x + n.x, a0.y + n.y, z],
                                  [b0.x - n.x, b0.y - n.y, z], [b0.x + n.x, b0.y + n.y, z]]
                    indices += [base, base + 2, base + 1, base + 1, base + 2, base + 3]
                }
                var descriptor = MeshDescriptor(name: "laserHitZap.arc")
                descriptor.positions = MeshBuffers.Positions(positions)
                descriptor.primitives = .triangles(indices)
                descriptor.materials = .allFaces(material)
                return descriptor
            }
            return try? MeshResource.generate(from: [ribbon(0.055, material: 0, z: 0), ribbon(0.016, material: 1, z: 0.004)])
        }

        private static func solid(_ color: LaserGateArt.RGB, opacity: Float) -> UnlitMaterial {
            var material = UnlitMaterial(applyPostProcessToneMap: false)
            material.color = .init(tint: color.uiColor)
            material.blending = .transparent(opacity: .init(floatLiteral: opacity))
            material.faceCulling = .none
            return material
        }

        private static func material(_ image: CGImage?) -> UnlitMaterial {
            var material = UnlitMaterial(applyPostProcessToneMap: false)
            if let image, let texture = try? TextureResource(image: image, options: .init(semantic: .color)) {
                material.color = .init(tint: .white, texture: .init(texture))
            }
            material.blending = .transparent(opacity: 1.0)
            material.faceCulling = .none
            return material
        }

        /// A soft round sprite: `inner` at the centre, `outer` at the rim, alpha falling off.
        private static func radial(inner: LaserGateArt.RGB, outer: LaserGateArt.RGB, falloff: Float, peak: Float = 1) -> CGImage? {
            let n = 128
            var pixels = [UInt8](repeating: 0, count: n * n * 4)
            for y in 0..<n {
                for x in 0..<n {
                    let dx = (Float(x) + 0.5) / Float(n) * 2 - 1, dy = (Float(y) + 0.5) / Float(n) * 2 - 1
                    let r = min(1, (dx * dx + dy * dy).squareRoot())
                    let c = inner.mix(outer, min(1, r * 1.4))
                    let a = peak * pow(1 - r, falloff)
                    let i = (y * n + x) * 4
                    // Premultiplied RGBA.
                    pixels[i] = UInt8(min(255, c.r * a * 255)); pixels[i + 1] = UInt8(min(255, c.g * a * 255))
                    pixels[i + 2] = UInt8(min(255, c.b * a * 255)); pixels[i + 3] = UInt8(min(255, a * 255))
                }
            }
            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }
}
