//
//  MascotDefeatFX.swift
//  Sedactive
//

import RealityKit
import UIKit

/// The team defeat's energy explosion and smoke (`MascotDefeat`), one set per mascot, attached to
/// its lane. Flat, camera-facing cartoon pieces (the zap's palette: hot white melting into coral),
/// each with one job, on the timeline's own clock:
/// - **Spread arc** (struck mascot, 0.36–0.50 s): a jagged bolt from its board to the teammate's,
///   a hot head running along it and a small flash where it lands: the failure spreads.
/// - **Gather** (0.56–0.70 s): a ring contracting into the board and a hot core swelling in it:
///   the energy pulls in before the boom (anticipation).
/// - **Boom** (0.70 s, the same instant for every board): a white-hot core for three frames (the
///   contrast beat), the zap's comic star snapping open over it, a thin shock ring, and a second
///   ring racing across the floor.
/// - **Debris** (0–0.85 s): hot spark streaks thrown out and falling, a few lavender board shards
///   tumbling to the floor (the board breaking up as it vanishes), round cartoon smoke clouds.
/// - **After**: thin smoke from the singed head and the spot where the board was, and the
///   mascot's own soft shadow on the floor (the board's went with it).
/// Everything is built once and only moved, shown and faded: no entity, mesh or texture is made
/// while it plays; nothing writes depth, so no quad ever cuts into the translucent mascots.
/// Reduce Motion: no arc, gather, core, star, rings, sparks or shards; the clouds fade in place,
/// the wisps rise gently.
@MainActor
final class MascotDefeatFX {
    let root = Entity()
    private let arc: ModelEntity
    private let arcHead: ModelEntity
    private let arcFlash: ModelEntity
    private let gatherRing: ModelEntity
    private let core: ModelEntity
    private let star: ModelEntity
    private let ring: ModelEntity
    private let floorRing: ModelEntity
    private let sparks: [ModelEntity]
    private let shards: [ModelEntity]
    private let puffs: [ModelEntity]
    private let wisps: [ModelEntity]
    private let shadow: ModelEntity
    private var all: [ModelEntity] { [arc, arcHead, arcFlash, gatherRing, core, star, ring, floorRing, shadow] + sparks + shards + puffs + wisps }

    static let sparkCount = 8, shardCount = 6, puffCount = 6
    /// Head wisps first, then wisps from where the board was.
    static let headWisps = 3, floorWisps = 2
    /// Toward the camera from the board's centre, so the board never hides the boom.
    static let front: Float = 0.3
    /// Where each cloud heads (degrees, counter-clockwise from screen right): out and up.
    static let puffAngles: [Float] = [-10, 25, 62, 118, 155, 190]
    /// Each spark's direction (degrees) and speed (m/s); each shard's.
    static let sparkFlights: [(Float, Float)] = [(12, 3.4), (38, 3.0), (64, 3.6), (88, 3.2), (112, 3.5), (140, 3.0), (166, 3.3), (-20, 2.6)]
    static let shardFlights: [(Float, Float)] = [(20, 2.2), (55, 2.0), (95, 1.7), (130, 2.1), (165, 2.3), (-5, 1.8)]
    static let gravity: Float = 7

    init() {
        let zap = LaserHitZap.Resources.shared, own = Resources.shared
        root.name = "mascotDefeatFX"
        root.isEnabled = false
        func quad(_ name: String, _ material: UnlitMaterial) -> ModelEntity {
            let entity = ModelEntity(mesh: zap.quad, materials: [material])
            entity.name = "mascotDefeatFX.\(name)"
            return entity
        }
        arc = ModelEntity(mesh: zap.arcMeshes[0], materials: [own.arcGlow, own.arcCore])
        arc.name = "mascotDefeatFX.spreadArc"
        arcHead = quad("spreadHead", own.spark)
        arcFlash = quad("spreadFlash", own.star)
        gatherRing = quad("gatherRing", own.ring)
        core = quad("core", own.core)
        star = quad("star", own.star)
        ring = quad("ring", own.ring)
        floorRing = quad("floorRing", own.ring)
        sparks = (0..<Self.sparkCount).map { quad("spark\($0)", own.spark) }
        shards = (0..<Self.shardCount).map { quad("shard\($0)", own.shard) }
        puffs = (0..<Self.puffCount).map { quad("puff\($0)", own.puff) }
        wisps = (0..<(Self.headWisps + Self.floorWisps)).map { quad("wisp\($0)", $0 < Self.headWisps ? own.singedWisp : own.boardWisp) }
        shadow = quad("floorShadow", own.shadow)
        for entity in all {
            entity.isEnabled = false
            root.addChild(entity)
        }
    }

    /// Shows the effects for one frame (lane space): `board` the board's centre on its deck,
    /// `floorY` the corridor floor, `root` the mascot's root (its soles), `headTop` the top of its
    /// head as drawn, `spreadTo` the teammate's board while the failure spreads to it.
    func show(_ defeat: MascotDefeat, frame: MascotDefeat.Frame, board: SIMD3<Float>, floorY: Float,
              root mascot: SIMD3<Float>, headTop: SIMD3<Float>, spreadTo: SIMD3<Float>?) {
        let calm = defeat.reduceMotion
        guard frame.spreadAge != nil || frame.gather > 0 || frame.popAge != nil || frame.floorShadow > 0 else { hide(); return }
        root.isEnabled = true
        let center = board + [0, 0.05, Self.front]
        // Raised over the board rims, so the bolt reads against the dark floor, not the red boards.
        showSpread(frame.spreadAge, from: center + [0, 0.12, 0], to: spreadTo.map { $0 + [0, 0.17, Self.front] }, calm: calm)

        // Gather: a ring pulls in, a hot core swells in the board.
        let p = frame.popAge ?? -1
        let gathering = !calm && p < 0 && frame.gather > 0
        set(gatherRing, opacity: gathering ? 0.85 * frame.gather : 0)
        if gathering {
            let size = 1.5 - 1.15 * frame.gather
            place(gatherRing, at: center + [0, 0, 0.01], size: [size, size * 0.8])
        }
        // The core: swelling with the gather, white-hot for three frames at the boom, then gone.
        var coreLevel: Float = 0, coreSize: Float = 0
        if !calm, p < 0, frame.gather > 0 { coreLevel = 0.75 * frame.gather * frame.gather; coreSize = 0.18 + 0.3 * frame.gather }
        if !calm, p >= 0, p < 0.16 {
            coreLevel = 1 - MascotDefeat.smoothF(0.05, 0.16, p)
            coreSize = 0.95 + 0.4 * MascotDefeat.smoothF(0, 0.16, p)
        }
        set(core, opacity: coreLevel)
        if coreLevel > 0.001 { place(core, at: center + [0, 0, 0.03], size: [coreSize, coreSize]) }

        // The star: snaps open over the core, holds, burns off, turning a little.
        let starOn = !calm && p >= 0 && p < 0.22
        set(star, opacity: starOn ? 1 - MascotDefeat.smoothF(0.09, 0.22, p) : 0)
        if starOn {
            let open = Float(1 - pow(1 - min(1, p / 0.04), 3))
            let size = 0.35 + 0.85 * open + 0.15 * Float(max(0, p - 0.04) / 0.18)
            place(star, at: center + [0, 0, 0.04], size: [size, size], turn: 0.2 * defeat.side + Float(p) * 1.5)
        }
        // The shock ring, and its echo racing across the floor.
        let k = (p - 0.01) / 0.28
        let ringOn = !calm && k >= 0 && k < 1
        set(ring, opacity: ringOn ? Float(0.95 * (1 - k) * (1 - k)) : 0)
        if ringOn {
            let size = 0.5 + 1.2 * Float(1 - pow(1 - k, 3))
            place(ring, at: center + [0, 0, 0.02], size: [size, size * 0.85])
        }
        let g = (p - 0.03) / 0.4
        let floorOn = !calm && g >= 0 && g < 1
        set(floorRing, opacity: floorOn ? Float(0.8 * (1 - g) * (1 - g)) : 0)
        if floorOn {
            let size = 0.5 + 2.2 * Float(1 - pow(1 - g, 2.5))
            floorRing.transform = Transform(scale: [size, size, 1], rotation: simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]),
                                            translation: [board.x, floorY + 0.012, 0.05])
        }
        showDebris(p, from: center, floorY: floorY, side: defeat.side, calm: calm)

        // Clouds: burst out, swell, fade.
        for (i, puff) in puffs.enumerated() {
            let age = p - 0.03 - Double(i) * 0.012
            guard age >= 0, age < 0.9 else { set(puff, opacity: 0); continue }
            let angle = Self.puffAngles[i] * .pi / 180
            let direction = SIMD3<Float>(cos(angle) * defeat.side, sin(angle) * 0.8, 0)
            var opacity: Float, size: Float, offset: SIMD3<Float>
            if calm {
                opacity = 0.7 * MascotDefeat.smoothF(0, 0.15, age) * (1 - MascotDefeat.smoothF(0.4, 0.9, age))
                size = 0.28
                offset = direction * 0.25
            } else {
                let out = Float(1 - pow(1 - min(1, age / 0.45), 3))
                // Gone before the landing, so the clouds never hide the defeated pose.
                opacity = 0.85 * MascotDefeat.smoothF(0, 0.04, age) * (1 - MascotDefeat.smoothF(0.2, 0.52, age))
                size = 0.16 + 0.22 * Float(1 - pow(1 - min(1, age / 0.3), 2)) + 0.08 * Float(age)
                offset = direction * (0.14 + 0.4 * out) + [0, 0.12 * Float(age), 0]
            }
            set(puff, opacity: opacity)
            if opacity > 0.001 { place(puff, at: center + offset + [0, 0, 0.004 * Float(i)], size: [size, size], turn: Float(i) * 1.1) }
        }

        // Wisps: rising from the singed head and the spot on the floor where the board was.
        let time = max(0, p)
        for (i, wisp) in wisps.enumerated() {
            let head = i < Self.headWisps
            let period = head ? 1.0 : 1.3
            let a = Float(((time / period) + Double(i) * 0.37).truncatingRemainder(dividingBy: 1))
            let level = head ? frame.smoke : frame.floorShadow * MascotDefeat.smoothF(0.25, 0.6, p)
            let opacity = level * (head ? 0.6 : 0.4) * sin(.pi * a)
            set(wisp, opacity: opacity)
            guard opacity > 0.001 else { continue }
            let source: SIMD3<Float> = head
                ? headTop + [[-0.06, 0.05, 0][i], -0.02, 0.06]
                : [board.x + (i == Self.headWisps ? -0.34 : 0.32) * defeat.side, floorY + 0.03, 0.2]
            let rise: Float = (head ? 0.4 : 0.34) * (calm ? 0.7 : 1)
            let sway = 0.04 * sin(2 * .pi * (a * 1.2 + Float(i)))
            let size = (head ? 0.06 : 0.08) + 0.12 * a
            place(wisp, at: source + [sway, rise * a, 0.003 * Float(i)], size: [size, size], turn: Float(i))
        }

        // The mascot's own soft shadow on the floor, darker as it comes down.
        let height = max(0, mascot.y - floorY)
        let shade = frame.floorShadow * 0.6 * (1 - min(1, height / 0.7))
        set(shadow, opacity: shade)
        if shade > 0.001 {
            shadow.transform = Transform(scale: [0.78, 0.5, 1], rotation: simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]),
                                         translation: [mascot.x, floorY + 0.006, 0.02])
        }
    }

    /// The failure spreading to the teammate's board: a thick flickering bolt that runs across in
    /// 90 ms and holds a moment, a hot head along it, a flash where it lands.
    private func showSpread(_ age: Double?, from: SIMD3<Float>, to: SIMD3<Float>?, calm: Bool) {
        guard !calm, let age, let to, age < 0.16 else {
            for entity in [arc, arcHead, arcFlash] { set(entity, opacity: 0) }
            return
        }
        let span = to - from
        let length = simd_length(span)
        let travel = Float(min(1, age / 0.09))
        let opacity = Float(1 - MascotDefeat.smooth(0.12, 0.16, age))
        set(arc, opacity: opacity * (0.8 + 0.2 * sin(Float(age) * 90)))
        if opacity > 0.001, var model = arc.model {
            let meshes = LaserHitZap.Resources.shared.arcMeshes
            model.mesh = meshes[Int(age / 0.035) % meshes.count]
            arc.model = model
            arc.transform = Transform(scale: [length * travel, 1.5, 1], rotation: simd_quatf(angle: atan2(span.y, span.x), axis: [0, 0, 1]),
                                      translation: from + [0, 0, 0.05])
        }
        let headOn = age < 0.09
        set(arcHead, opacity: headOn ? 1 : 0)
        if headOn { place(arcHead, at: from + span * travel + [0, 0, 0.06], size: [0.34, 0.34]) }
        let landed = age - 0.085
        let flashOn = landed >= 0 && landed < 0.09
        set(arcFlash, opacity: flashOn ? Float(1 - landed / 0.09) : 0)
        if flashOn { place(arcFlash, at: to + [0, 0, 0.06], size: [0.5, 0.5], turn: 0.5) }
    }

    /// Hot spark streaks thrown out and falling; board shards tumbling onto the floor.
    private func showDebris(_ p: Double, from center: SIMD3<Float>, floorY: Float, side: Float, calm: Bool) {
        let t = Float(p)
        for (i, spark) in sparks.enumerated() {
            let life: Float = 0.38 + 0.03 * Float(i % 4)
            guard !calm, p >= 0, t < life else { set(spark, opacity: 0); continue }
            let (degrees, speed) = Self.sparkFlights[i]
            let angle = degrees * .pi / 180
            let v0 = SIMD2<Float>(cos(angle) * side, sin(angle)) * speed
            let velocity = SIMD2(v0.x, v0.y - Self.gravity * t)
            var position = center + [v0.x * t, v0.y * t - Self.gravity * t * t / 2, 0.06]
            position.y = max(position.y, floorY + 0.02)
            set(spark, opacity: 1 - MascotDefeat.smoothF(Double(life * 0.6), Double(life), p))
            let length = 0.08 + 0.035 * simd_length(velocity)
            spark.transform = Transform(scale: [length, 0.045, 1], rotation: simd_quatf(angle: atan2(velocity.y, velocity.x), axis: [0, 0, 1]),
                                        translation: position)
        }
        for (i, shard) in shards.enumerated() {
            guard !calm, p >= 0.01, t < 0.85 else { set(shard, opacity: 0); continue }
            let (degrees, speed) = Self.shardFlights[i]
            let angle = degrees * .pi / 180
            let v0 = SIMD2<Float>(cos(angle) * side, sin(angle)) * speed
            let z = 0.05 + 0.005 * Float(i)
            var position = center + [v0.x * t, v0.y * t - Self.gravity * t * t / 2, z]
            // Landed shards lie where they hit the floor (no bounce: compact, never busy).
            let rest = floorY + 0.03
            let grounded = position.y <= rest
            if grounded {
                let hit = (v0.y + (v0.y * v0.y + 2 * Self.gravity * (center.y - rest)).squareRoot()) / Self.gravity
                position = [center.x + v0.x * hit, rest, center.z + z]
            }
            let spin = Float(i % 2 == 0 ? 1 : -1) * (10 + Float(i) * 1.2)
            let size = 0.07 + 0.012 * Float(i % 3)
            set(shard, opacity: 1 - MascotDefeat.smoothF(0.55, 0.85, p))
            place(shard, at: position, size: [size, size], turn: grounded ? Float(i) : spin * t)
        }
    }

    func hide() {
        guard root.isEnabled else { return }
        root.isEnabled = false
        for entity in all { entity.isEnabled = false }
    }

    private func place(_ entity: ModelEntity, at position: SIMD3<Float>, size: SIMD2<Float>, turn: Float = 0) {
        entity.transform = Transform(scale: [size.x, size.y, 1], rotation: simd_quatf(angle: turn, axis: [0, 0, 1]), translation: position)
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
        /// A cartoon cloud: five overlapping circles, one crisp outline, shaded toward the lower
        /// right with a slightly darker rim (never a soft square).
        let puff: UnlitMaterial
        /// Thin rising smoke: soft round wisps, darker off the singed head.
        let singedWisp: UnlitMaterial
        let boardWisp: UnlitMaterial
        /// The boom's white-hot core: solid white melting through warm white into a coral rim.
        let core: UnlitMaterial
        /// A broken piece of the board: a lavender triangle with a light edge.
        let shard: UnlitMaterial
        /// The mascot's soft shadow on the floor.
        let shadow: UnlitMaterial
        /// The zap's star, ring, spark and arc, never writing depth: a large quad that writes depth
        /// hides the translucent mascot behind its transparent corners.
        let star: UnlitMaterial
        let ring: UnlitMaterial
        let spark: UnlitMaterial
        let arcGlow: UnlitMaterial
        let arcCore: UnlitMaterial

        private init() {
            typealias R = LaserHitZap.Resources
            puff = Self.cloud(light: LaserGateArt.RGB(0xD9D4E6), shade: LaserGateArt.RGB(0x948CAE))
            singedWisp = Self.wisp(LaserGateArt.RGB(0x6E6879))
            boardWisp = Self.wisp(LaserGateArt.RGB(0xA8A2B8))
            let white = LaserGateArt.RGB(0xFFFFFF), warm = LaserGateArt.RGB(0xFFF1D8)
            core = Self.flat(R.shaded(128) { x, y in
                let r = min(1, (x * x + y * y).squareRoot())
                return (white.mix(warm, R.smooth(0.25, 0.6, r)).mix(LaserGateArt.coral, R.smooth(0.6, 0.95, r)),
                        1 - R.smooth(0.7, 1, r))
            })
            let fill = LaserGateArt.RGB(0x7E6CC8), edge = LaserGateArt.RGB(0xC6BEEA)
            shard = Self.flat(R.shaded(64) { x, y in
                // A triangle by its three edges' signed distances (inside > 0).
                let corners: [SIMD2<Float>] = [[0, 0.85], [-0.8, -0.6], [0.75, -0.5]]
                var d: Float = 1
                for k in 0..<3 {
                    let a = corners[k], b = corners[(k + 1) % 3]
                    let n = simd_normalize(SIMD2(b.y - a.y, a.x - b.x))
                    d = min(d, -simd_dot(SIMD2(x, y) - a, n))
                }
                return (fill.mix(edge, R.smooth(0.12, 0, d)), R.smooth(-0.03, 0.03, d))
            })
            let dark = LaserGateArt.RGB(0x140F33)
            shadow = Self.flat(R.shaded(64) { x, y in
                let r = min(1, (x * x + y * y).squareRoot())
                return (dark, 0.85 * pow(1 - r * r, 1.4))
            })
            let zap = R.shared
            star = Self.noDepth(zap.burstMaterial)
            ring = Self.noDepth(zap.ringMaterial)
            spark = Self.noDepth(zap.sparkMaterial)
            arcGlow = Self.noDepth(zap.arcGlowMaterial)
            arcCore = Self.noDepth(zap.arcCoreMaterial)
        }

        private static func noDepth(_ material: UnlitMaterial) -> UnlitMaterial {
            var copy = material
            copy.writesDepth = false
            return copy
        }

        private static func flat(_ image: CGImage?) -> UnlitMaterial { noDepth(LaserHitZap.Resources.material(image)) }

        private static func wisp(_ color: LaserGateArt.RGB) -> UnlitMaterial {
            flat(LaserHitZap.Resources.shaded(64) { x, y in
                let r = min(1, (x * x + y * y).squareRoot())
                return (color, 0.85 * pow(1 - r * r, 1.6))
            })
        }

        private static func cloud(light: LaserGateArt.RGB, shade: LaserGateArt.RGB) -> UnlitMaterial {
            let circles: [SIMD3<Float>] = [[0, -0.18, 0.52], [-0.42, 0.02, 0.4], [0.4, 0, 0.42], [-0.12, 0.36, 0.4], [0.24, 0.32, 0.36]]
            return flat(LaserHitZap.Resources.shaded(128) { x, y in
                let d = circles.map { simd_length(SIMD2<Float>(x - $0.x, y - $0.y)) - $0.z }.min()!
                let alpha = LaserHitZap.Resources.smooth(0.025, -0.025, d)
                let shading = 0.8 * LaserHitZap.Resources.smooth(-0.6, 0.7, 0.5 * x - y)
                let rim = 0.35 * LaserHitZap.Resources.smooth(-0.1, 0, d)
                return (light.mix(shade, min(1, shading + rim)), alpha)
            })
        }
    }
}
