//
//  LaserHitZap.swift
//  Sedactive
//

import RealityKit
import UIKit

/// The electric VFX of one mascot's laser HIT (`LaserHitReaction`), attached to that mascot's
/// lane so they follow its body. A few art-directed pieces, each with one job:
/// - **Burst** (0–130 ms): a crisp comic star where the beam meets the body: the impact.
/// - **Shock ring** (20–300 ms): one thin ring thrown out from the burst: the force.
/// - **Current** (0–460 ms): tapered, soft-edged lightning that starts AT the strike and runs
///   across the struck part of the body to its edges, re-forking as it crackles: the shock.
/// - **Streak sparks** (40–460 ms): a few hot sparks thrown off the strike, stretched along
///   their flight: the residue.
/// - A soft coral glow behind the struck part. The mascot's own surface flash and charge are
///   applied to its material by `RobotAvatarLayer` from `bodyTint`.
/// Everything is built once and only moved, shown and faded; intensities come from the
/// reaction's frame, so the effects peak with the recoil and are gone when the reaction ends.
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
    private let ring: ModelEntity
    private let glow: ModelEntity
    private let arcs: [ModelEntity]
    private let sparks: [ModelEntity]

    /// How far in front of the body (toward the camera) the effects stand, so the body never
    /// hides them; the glow stands behind it.
    static let front: Float = 0.34
    static let behind: Float = 0.3
    /// How often the current changes shape (s): lively, never a strobe.
    static let arcStep = 0.05
    static let arcSlots = 3
    static let sparkCount = 8
    /// The current's drawn thickness scale (metres per mesh unit across the stroke).
    static let arcThickness: Float = 0.6
    /// The shock ring's life (s from the impact).
    static let ringStart = 0.02
    static let ringLife = 0.24
    /// The longest stroke of current (m): it stays on the struck part instead of caging the body.
    static let arcReach: Float = 0.55

    init() {
        let r = Resources.shared
        root.name = "laserHitZap"
        root.isEnabled = false
        flash = ModelEntity(mesh: r.quad, materials: [r.burstMaterial])
        flash.name = "laserHitZap.flash"
        ring = ModelEntity(mesh: r.quad, materials: [r.ringMaterial])
        ring.name = "laserHitZap.ring"
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
        for part in [glow] + arcs + [ring, flash] + sparks { root.addChild(part) }
    }

    /// The emission the struck mascot's own surface shows: hot white for the impact frame,
    /// coral for the charge. Emission adds to the lit body, so its colours stay underneath.
    static func bodyTint(flash: Float, charge: Float) -> (color: UIColor, intensity: Float) {
        let flash = max(0, min(1, flash)), charge = max(0, min(1, charge))
        let color = LaserGateArt.coral.mix(LaserGateArt.hot, min(1, 0.2 + flash))
        return (color.uiColor, 1.6 * flash + 0.75 * charge * (1 - flash))
    }

    /// Shows the effects at `tau` seconds into `reaction`. `contact`: where the beam meets the
    /// mascot (lane space).
    func show(_ reaction: LaserHitReaction, frame: LaserHitReaction.Frame, at tau: Double,
              body: Body, contact: SIMD3<Float>) {
        let ringShows = !reaction.reduceMotion && tau >= Self.ringStart && tau < Self.ringStart + Self.ringLife
        guard frame.arcs > 0.001 || frame.glow > 0.001 || frame.flash > 0.001 || frame.sparks || ringShows else { hide(); return }
        root.isEnabled = true
        // In front of the struck part as posed (the head tips toward the camera in the recoil).
        let depth = reaction.region == .upper ? max(body.chest.z, body.headCenter.z) : body.pelvis.z
        let strike = SIMD3<Float>(contact.x, contact.y, depth + Self.front)
        showBurst(reaction, intensity: frame.flash, at: tau, strike: strike)
        showRing(reaction, at: tau, strike: strike, visible: ringShows)
        // Glow behind the struck part of the body: it rims the silhouette, never covers the face.
        set(glow, opacity: frame.glow)
        if frame.glow > 0.001 {
            let center = reaction.region == .upper ? (body.headCenter + body.chest) / 2 : (body.pelvis + body.knees.left + body.knees.right) / 3
            let size: Float = reaction.region == .upper ? 1.45 : 1.2
            glow.position = [center.x, center.y, depth - Self.behind]
            glow.scale = [size, size, 1]
        }
        showArcs(reaction, intensity: frame.arcs, at: tau, body: body, strike: strike)
        showSparks(reaction, at: tau, from: strike + [0, 0, 0.04], visible: frame.sparks)
    }

    func hide() {
        guard root.isEnabled else { return }
        root.isEnabled = false
    }

    // MARK: - Burst and ring

    /// The comic impact star: snaps from half size to full in ~2 frames (the first frame
    /// already shows it), holds hot through the hit-stop, then swells a little as it burns off.
    /// Tilted per hit so repeated hits never stamp the same star.
    private func showBurst(_ reaction: LaserHitReaction, intensity: Float, at tau: Double, strike: SIMD3<Float>) {
        set(flash, opacity: intensity)
        guard intensity > 0.001 else { return }
        let base: Float = (reaction.reduceMotion ? 0.46 : 0.62) * (reaction.region == .upper ? 1 : 0.82)
        let snap = reaction.reduceMotion ? 1 : Float(LaserHitReaction.smooth(0, 0.035, tau))
        let swell = Float(LaserHitReaction.smooth(0.04, 0.13, tau))
        let size = base * (0.55 + 0.45 * snap + 0.22 * swell)
        let tilt = (LaserHitReaction.noise(reaction.seed, 41) - 0.5) * 0.6
        let spin: Float = reaction.reduceMotion ? 0 : Float(tau) * 1.2
        flash.position = strike + [0, 0, 0.03]
        flash.orientation = simd_quatf(angle: tilt + spin, axis: [0, 0, 1])
        flash.scale = [size, size, 1]
    }

    /// One thin ring thrown out from the strike, fast then slowing (ease-out), thinning as it
    /// fades. Motion, so not shown with Reduce Motion.
    private func showRing(_ reaction: LaserHitReaction, at tau: Double, strike: SIMD3<Float>, visible: Bool) {
        guard visible else { set(ring, opacity: 0); return }
        let p = Float((tau - Self.ringStart) / Self.ringLife)
        let eased = 1 - pow(1 - p, 3)
        // Simulator review: a 1.35 m ring framed the whole mascot like a portal; this one stays
        // a shock around the struck part, smaller still at the legs.
        let size = (0.28 + 0.62 * eased) * (reaction.region == .upper ? 1 : 0.8)
        ring.position = strike + [0, 0, 0.015]
        ring.scale = [size, size, 1]
        set(ring, opacity: 0.75 * pow(1 - p, 2))
    }

    // MARK: - Current

    /// Up to three strokes of current, each from the strike to an edge point of the struck part
    /// (pushed just past the silhouette, so the tips crackle off the body). Each draws on from
    /// the strike in the first ~50 ms (current travelling), then re-forks every `arcStep` in a
    /// deterministic pattern and holds its target for two steps, so nothing strobes. Fewer
    /// strokes show as the energy decays. (Simulator review, 14 November 2026: free-floating
    /// zigzags around the body read as stickers; strokes from the strike read as the shock.)
    private func showArcs(_ reaction: LaserHitReaction, intensity: Float, at tau: Double, body: Body, strike: SIMD3<Float>) {
        let anchors = Self.anchors(body, region: reaction.region)
        let step = Int(tau / Self.arcStep)
        let meshes = Resources.shared.arcMeshes
        let center = reaction.region == .upper ? body.headCenter : (body.pelvis + body.knees.left + body.knees.right) / 3
        let grow = Float(LaserHitReaction.smooth(0, 0.05, tau))
        var used = Set<Int>()
        for (k, arc) in arcs.enumerated() {
            let threshold: Float = [0.08, 0.3, 0.55, 2][min(k, 3)]
            guard intensity > threshold else { set(arc, opacity: 0); continue }
            let hold = (step + k) / 2
            // Distinct targets, so two strokes never overlap.
            var index = Int(LaserHitReaction.noise(reaction.seed, k, hold) * Float(anchors.count)) % anchors.count
            while used.contains(index) { index = (index + 1) % anchors.count }
            used.insert(index)
            var end = anchors[index]
            var outward = SIMD2<Float>(end.x - center.x, end.y - center.y)
            outward = simd_length(outward) > 1e-4 ? simd_normalize(outward) : [0, 1]
            end.x += outward.x * 0.07
            end.y += outward.y * 0.07
            // From just beside the strike (each stroke leaves it at its own point).
            let jitter = SIMD2<Float>(LaserHitReaction.noise(reaction.seed, k + 11, hold) - 0.5,
                                      LaserHitReaction.noise(reaction.seed, k + 13, hold) - 0.5) * 0.06
            let start = SIMD2<Float>(strike.x + jitter.x, strike.y + jitter.y)
            var delta = SIMD2<Float>(end.x, end.y) - start
            if simd_length(delta) < 0.18 { delta = outward * 0.22 }
            if simd_length(delta) > Self.arcReach { delta = simd_normalize(delta) * Self.arcReach }
            let variant = Int(LaserHitReaction.noise(reaction.seed, k + 17, step) * Float(meshes.count)) % meshes.count
            if arc.model?.mesh !== meshes[variant] { arc.model?.mesh = meshes[variant] }
            let flip: Float = LaserHitReaction.noise(reaction.seed, k + 31, step) < 0.5 ? -1 : 1
            arc.position = [start.x, start.y, strike.z + 0.008 * Float(k)]
            arc.orientation = simd_quatf(angle: atan2(delta.y, delta.x), axis: [0, 0, 1])
            arc.scale = [simd_length(delta) * max(0.05, grow), Self.arcThickness * flip, 1]
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

    /// A few hot sparks thrown up and out from the strike, falling under gravity, each stretched
    /// along its own velocity (a streak reads as speed; a dot reads as a speck) and shortening
    /// as it slows and fades. Positions are a function of time only (no simulation state).
    private func showSparks(_ reaction: LaserHitReaction, at tau: Double, from origin: SIMD3<Float>, visible: Bool) {
        let age = Float(tau - LaserHitReaction.sparkStart)
        let life = Float(LaserHitReaction.sparkLife)
        for (k, spark) in sparks.enumerated() {
            let lifetime = life * (0.55 + 0.45 * LaserHitReaction.noise(reaction.seed, k, 7))
            guard visible, !reaction.reduceMotion, age >= 0, age < lifetime else { set(spark, opacity: 0); continue }
            let angle = Float.pi * (0.08 + 0.84 * (Float(k) + LaserHitReaction.noise(reaction.seed, k, 3)) / Float(sparks.count))
            let speed: Float = 1.2 + 1.0 * LaserHitReaction.noise(reaction.seed, k, 5)
            let gravity: Float = 6
            let p = origin + SIMD3<Float>(cos(angle) * speed * age, sin(angle) * speed * age - gravity * age * age / 2, 0)
            let velocity = SIMD2<Float>(cos(angle) * speed, sin(angle) * speed - gravity * age)
            let fade = 1 - age / lifetime
            let width: Float = 0.032 * (0.4 + 0.6 * fade)
            let length = width + 0.05 * simd_length(velocity) * fade
            spark.position = p
            spark.orientation = simd_quatf(angle: atan2(velocity.y, velocity.x), axis: [0, 0, 1])
            spark.scale = [length, width, 1]
            set(spark, opacity: min(1, fade * 1.3))
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
        let burstMaterial: UnlitMaterial
        let ringMaterial: UnlitMaterial
        let glowMaterial: UnlitMaterial
        let sparkMaterial: UnlitMaterial
        let arcGlowMaterial: UnlitMaterial
        let arcCoreMaterial: UnlitMaterial

        private init() {
            quad = .generatePlane(width: 1, height: 1)
            arcMeshes = (0..<6).compactMap { Self.arcMesh(variant: $0) }
            let hot = LaserGateArt.hot, coral = LaserGateArt.coral, spill = LaserGateArt.spill
            burstMaterial = Self.material(Self.shaded(256) { x, y in Self.burst(x, y, hot: hot, coral: coral, spill: spill) })
            ringMaterial = Self.material(Self.shaded(192) { x, y in
                let r = (x * x + y * y).squareRoot()
                let a = exp(-pow((r - 0.88) / 0.04, 2))
                return (hot.mix(coral, Self.smooth(0.82, 0.95, r)), a)
            })
            glowMaterial = Self.material(Self.shaded(128) { x, y in
                let r = min(1, (x * x + y * y).squareRoot())
                return (coral.mix(hot, 0.25).mix(spill, min(1, r * 1.4)), 0.55 * pow(1 - r, 2.4))
            })
            sparkMaterial = Self.material(Self.shaded(64) { x, y in
                let r = min(1, (x * x + y * y).squareRoot())
                return (hot.mix(coral, min(1, r * 1.3)), pow(1 - r, 1.3))
            })
            // Across the stroke (v): a soft coral glow, and a hot core with soft coral edges.
            arcGlowMaterial = Self.material(Self.shaded(64, width: 4) { _, v in (coral, 0.7 * exp(-pow(v / 0.48, 2) * 2.6)) })
            arcCoreMaterial = Self.material(Self.shaded(64, width: 4) { _, v in
                let d = abs(v)
                return (hot.mix(coral, Self.smooth(0.35, 0.95, d)), 1 - Self.smooth(0.55, 1, d))
            })
        }

        /// The impact star: ten straight-edged spikes, alternately long and short, a hot core
        /// melting into a coral rim, and a faint coral halo around it. Crisp, comic, flat.
        static func burst(_ x: Float, _ y: Float, hot: LaserGateArt.RGB, coral: LaserGateArt.RGB,
                          spill: LaserGateArt.RGB) -> (LaserGateArt.RGB, Float) {
            let r = (x * x + y * y).squareRoot()
            let spikes: Float = 10
            let turn = (atan2(y, x) / (2 * .pi) + 1) * spikes
            let index = Int(turn) % Int(spikes)
            let s = 1 - abs((turn - turn.rounded(.down)) * 2 - 1) // 0 between spikes, 1 at a tip
            let reach: Float = index % 2 == 0 ? 0.96 : 0.66
            let edge = 0.3 + (reach - 0.3) * pow(s, 1.5)
            let star = smooth(edge + 0.012, edge - 0.012, r)
            let halo = 0.3 * pow(max(0, 1 - r), 2.2)
            let color = star > 0.01 ? hot.mix(coral, smooth(0.42 * edge, 0.85 * edge, r)) : spill
            return (color, max(star, halo))
        }

        /// A jagged stroke from (0, 0) to (1, 0) with a short fork, in two parts (material 0: a
        /// wide soft coral glow, material 1: a thin hot core). Thickest at the strike, tapering
        /// toward the tip; kinks irregular in size and spacing, so no two strokes match.
        static func arcMesh(variant: Int) -> MeshResource? {
            let seed = UInt32(variant + 1)
            let segments = 8
            var points: [SIMD2<Float>] = [[0, 0]]
            for i in 1..<segments {
                let size = 0.035 + 0.075 * LaserHitReaction.noise(seed, i)
                let sign: Float = LaserHitReaction.noise(seed, i, 21) < 0.8 ? (i % 2 == 0 ? -1 : 1) : (i % 2 == 0 ? 1 : -1)
                let x = (Float(i) + (LaserHitReaction.noise(seed, i, 9) - 0.5) * 0.6) / Float(segments)
                points.append([x, sign * size])
            }
            points.append([1, 0])
            let taper = points.map { 1 - 0.7 * $0.x }
            // The fork leaves a middle kink at ~35° and runs a third of the stroke's length.
            let from = 3 + Int(LaserHitReaction.noise(seed, 5, 2) * 2)
            let side: Float = LaserHitReaction.noise(seed, 6, 2) < 0.5 ? -1 : 1
            let heading = SIMD2<Float>(cos(side * 0.62), sin(side * 0.62))
            var fork: [SIMD2<Float>] = [points[from]]
            for j in 1...3 {
                let jag = (j % 2 == 0 ? -1 : 1) * (0.02 + 0.03 * LaserHitReaction.noise(seed, j, 33))
                fork.append(points[from] + heading * (0.33 * Float(j) / 3) + SIMD2<Float>(-heading.y, heading.x) * jag)
            }
            let forkTaper = (0...3).map { taper[from] * 0.7 * (1 - 0.8 * Float($0) / 3) }
            func ribbon(_ halfWidth: Float, material: UInt32, z: Float) -> MeshDescriptor {
                var positions: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], indices: [UInt32] = []
                for (line, widths) in [(points, taper), (fork, forkTaper)] {
                    for i in 0..<(line.count - 1) {
                        let a = line[i], b = line[i + 1]
                        let d = simd_normalize(b - a), n = SIMD2<Float>(-d.y, d.x)
                        let wa = halfWidth * widths[i], wb = halfWidth * widths[i + 1]
                        let base = UInt32(positions.count)
                        // Each segment a quad, overlapping its neighbours a little at the kinks.
                        let a0 = a - d * wa * 0.6, b0 = b + d * wb * 0.6
                        positions += [[a0.x - n.x * wa, a0.y - n.y * wa, z], [a0.x + n.x * wa, a0.y + n.y * wa, z],
                                      [b0.x - n.x * wb, b0.y - n.y * wb, z], [b0.x + n.x * wb, b0.y + n.y * wb, z]]
                        uvs += [[0, 0], [0, 1], [1, 0], [1, 1]]
                        indices += [base, base + 2, base + 1, base + 1, base + 2, base + 3]
                    }
                }
                var descriptor = MeshDescriptor(name: "laserHitZap.arc")
                descriptor.positions = MeshBuffers.Positions(positions)
                descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
                descriptor.primitives = .triangles(indices)
                descriptor.materials = .allFaces(material)
                return descriptor
            }
            return try? MeshResource.generate(from: [ribbon(0.075, material: 0, z: 0), ribbon(0.022, material: 1, z: 0.004)])
        }

        static func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
            let t = min(1, max(0, (x - e0) / (e1 - e0)))
            return t * t * (3 - 2 * t)
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

        /// A small premultiplied texture from `shade(x, y)`: x across the image and y up it,
        /// each from −1 to 1 (so a quad's centre is (0, 0)).
        private static func shaded(_ height: Int, width: Int? = nil,
                                   _ shade: (Float, Float) -> (LaserGateArt.RGB, Float)) -> CGImage? {
            let w = width ?? height, h = height
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            for row in 0..<h {
                for column in 0..<w {
                    let x = (Float(column) + 0.5) / Float(w) * 2 - 1, y = 1 - (Float(row) + 0.5) / Float(h) * 2
                    let (c, raw) = shade(x, y)
                    let a = min(1, max(0, raw))
                    let i = (row * w + column) * 4
                    pixels[i] = UInt8(min(255, c.r * a * 255)); pixels[i + 1] = UInt8(min(255, c.g * a * 255))
                    pixels[i + 2] = UInt8(min(255, c.b * a * 255)); pixels[i + 3] = UInt8(min(255, a * 255))
                }
            }
            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }
}
