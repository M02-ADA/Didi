//
//  HoverboardReaction.swift
//  Sedactive
//

import Foundation
import RealityKit
import UIKit

/// A hoverboard's own reaction to its player's verdict (Kevin, 18 November 2026). Presentation
/// only: it reads a shown CLEAR or HIT and moves nothing judged. The board's X stays its ride
/// (`LateralSteering`), its deck top stays under the feet, and the lane never moves.
/// - CLEAR (`.clear`, that player's own verdict): "the board celebrates with me". A gold sunburst
///   pops in front of the board (the primary, camera-facing silhouette), the board squashes wide
///   and springs up tall with a little rock (secondary), its light bars blaze gold, and six gold
///   and cyan stars shoot up past the rider's legs (residual).
/// - HIT (`.hit`, with the mascot's own HIT reaction): "ouch, the board got shocked too". A jagged
///   coral shock ring bangs out on the first frame and flickers (primary), the board jolts flat
///   and shakes (secondary), its light bars flicker coral, and two cartoon bolts and a spray of
///   sparks crackle at its ends (residual).
/// UNAVAILABLE gets none. A new reaction restarts the board's one reaction (never stacks).
nonisolated enum HoverboardReaction: Equatable, Sendable {
    case clear, hit

    /// One short beat each.
    var duration: Double { self == .clear ? 0.55 : 0.45 }

    /// One frame of a reaction.
    struct Pose: Equatable, Sendable {
        /// The board's squash and stretch about its deck top (the feet stay put).
        var scaleX: Float = 1
        var scaleY: Float = 1
        /// Extra roll (radians); the deck drops by its rise under the feet, as for a bank.
        var roll: Float = 0
        /// The camera-facing burst: its size (× the board's width; nil: hidden), opacity and turn.
        var burst: Float?
        var burstOpacity: Float = 0
        var burstSpin: Float = 0
        /// Light-bar level: 0 authored, 1 lit, 2 blazing.
        var lights = 0
        /// The coloured light on the floor, 0…1.
        var glow: Float = 0
        /// HIT: whether the end bolts show, and the step that shapes them.
        var bolts = false
        var step = 0
    }

    /// The pose at `tau` seconds (pure, deterministic). Reduce Motion: no squash, rock, shake,
    /// burst growth or flicker; the burst and lights fade in and out, still.
    func pose(at tau: Double, reduceMotion: Bool) -> Pose {
        var p = Pose()
        guard tau >= 0, tau < duration else { return p }
        if reduceMotion {
            let fade = Float(sin(.pi * tau / duration))
            p.burst = 1
            p.burstOpacity = 0.75 * fade
            p.glow = 0.7 * fade
            p.lights = tau < duration * 0.6 ? 1 : 0
            return p
        }
        let step = Int(tau * 24)
        p.step = step
        if self == .clear {
            // Impact: squash wide at 60 ms; stretch up tall at 160 ms; settle by 360 ms.
            p.scaleX = Float(Self.keys(tau, [(0, 1), (0.06, 1.12), (0.16, 0.94), (0.26, 1.04), (0.36, 1)]))
            p.scaleY = Float(Self.keys(tau, [(0, 1), (0.06, 0.7), (0.16, 1.2), (0.26, 0.95), (0.36, 1)]))
            let rock = tau - 0.12
            if rock > 0 { p.roll = Float(0.045 * exp(-rock / 0.16) * sin(2 * .pi * 3.4 * rock)) }
            // The sunburst pops past full size, then spreads and fades.
            p.burst = Float(Self.keys(tau, [(0, 0.45), (0.07, 1.18), (0.14, 1.0), (0.45, 1.3)]))
            p.burstOpacity = Float(1 - Self.smooth(0.16, 0.45, tau))
            p.burstSpin = Float(0.35 * tau)
            p.lights = tau < 0.14 ? 2 : tau < 0.3 ? 1 : 0
            p.glow = Float(Self.keys(tau, [(0, 0), (0.05, 1), (duration, 0)]))
        } else {
            // Impact on frame one: jolted flat and wide, then a rough rebound and a fast shake.
            p.scaleX = Float(Self.keys(tau, [(0, 1.12), (0.05, 0.92), (0.1, 1.06), (0.16, 0.98), (0.24, 1)]))
            p.scaleY = Float(Self.keys(tau, [(0, 0.74), (0.05, 1.12), (0.1, 0.92), (0.16, 1.03), (0.24, 1)]))
            p.roll = Float(0.05 * exp(-tau / 0.12) * sin(2 * .pi * 17 * tau))
            // The shock ring bangs out at full size and flickers on twos as it spreads.
            let flicker: [Float] = [1, 0.55, 1, 0.7, 0.9, 0.45, 0.75, 0.35, 0.55]
            p.burst = tau < 0.36 ? Float(Self.keys(tau, [(0, 1.1), (0.05, 0.92), (0.36, 1.35)])) : nil
            p.burstOpacity = tau < 0.36 ? flicker[min(step, flicker.count - 1)] * Float(1 - Self.smooth(0.18, 0.36, tau)) : 0
            p.burstSpin = Float(Self.hash(step, 7) - 0.5) * 0.35
            let lights: [Int] = [2, 0, 2, 1, 2, 0, 1, 0]
            p.lights = step < lights.count ? lights[step] : 0
            p.glow = Float(Double(flicker[min(step, flicker.count - 1)]) * exp(-tau / 0.2))
            p.bolts = tau < 0.3 && (step < 2 || Self.hash(step, 41) > 0.35)
        }
        return p
    }

    /// One residual spark (in the board's root, metres): where it is, how big, how bright; nil
    /// when it is not out. CLEAR: six stars arc up past the rider's legs from both ends of the
    /// board; HIT: five sparks spray sideways off the ends.
    func spark(_ index: Int, at tau: Double, boardWidth: Float, reduceMotion: Bool) -> (position: SIMD2<Float>, size: Float, opacity: Float)? {
        guard !reduceMotion else { return nil }
        let count = self == .clear ? 6 : 5
        guard index < count else { return nil }
        let start = self == .clear ? 0.05 + 0.02 * Double(index) : 0.0
        let life = self == .clear ? 0.42 : 0.28
        let age = tau - start
        guard age >= 0, age < life else { return nil }
        let side: Float = index.isMultiple(of: 2) ? -1 : 1
        let h = { (k: Int) in Float(Self.hash(index, k)) }
        let t = Float(age)
        let x0 = side * boardWidth * (self == .clear ? 0.32 + 0.12 * h(1) : 0.48)
        let vx = side * (self == .clear ? 0.35 + 0.5 * h(2) : 1.6 + 1.2 * h(2))
        let vy = self == .clear ? 2.0 + 0.9 * h(3) : 0.6 + 1.2 * h(3)
        let gravity: Float = self == .clear ? 4.5 : 6
        let position = SIMD2(x0 + vx * t, 0.04 + vy * t - 0.5 * gravity * t * t)
        let u = Float(age / life)
        let size = (self == .clear ? 0.2 + 0.07 * h(4) : 0.12 + 0.04 * h(4)) * sin(.pi * min(1, u * 1.25 + 0.1))
        return (position, max(0, size), 1 - u * u)
    }

    // MARK: Curves

    /// Piecewise curve through (time, value) keys, each segment eased out.
    static func keys(_ t: Double, _ keys: [(Double, Double)]) -> Double {
        guard let first = keys.first, let last = keys.last else { return 0 }
        if t <= first.0 { return first.1 }
        if t >= last.0 { return last.1 }
        for (a, b) in zip(keys, keys.dropFirst()) where t <= b.0 {
            let x = (t - a.0) / (b.0 - a.0)
            return a.1 + (b.1 - a.1) * (1 - pow(1 - x, 3))
        }
        return last.1
    }
    static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }
    static func hash(_ a: Int, _ b: Int) -> Double {
        var h = UInt64(truncatingIfNeeded: a &* 73_856_093 ^ b &* 19_349_663) &+ 0x9E37_79B9_7F4A_7C15
        h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
        h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((h ^ (h >> 31)) % 10_000) / 10_000
    }
}

/// The reaction's effects on one board: the camera-facing burst, sparks and bolts (unlit sprites
/// in front of the board, so the translucent mascot's depth pre-pass never hides them), the floor
/// light, and the board's own light bars and glow (material swaps on level changes only: a few
/// per reaction). Every entity is made once with the board and disabled at rest.
@MainActor
final class HoverboardReactionFX {
    /// How far in front of the board (toward the camera) the sprites float.
    static let spriteDepth: Float = 0.36

    private let burst: ModelEntity
    private let sparks: [ModelEntity]
    private let bolts: [ModelEntity]
    private let floorGlow: ModelEntity
    private let boardWidth: Float
    /// Every board surface, with its authored materials and its lit looks per (kind, level).
    private var surfaces: [(entity: ModelEntity, rest: [any RealityKit.Material], lit: [Key: [any RealityKit.Material]])] = []
    private struct Key: Hashable { let kind: HoverboardReaction; let level: Int }
    private var shownLights: Key?
    private var shown: [ObjectIdentifier: Float] = [:]
    private var kind: HoverboardReaction = .clear

    init(root: Entity, model: Entity, boardWidth: Float, floorY: Float) {
        self.boardWidth = boardWidth
        burst = Self.sprite("hoverboard.reaction.burst", Self.material(.clear, .burst))
        sparks = (0..<6).map { Self.sprite("hoverboard.reaction.spark\($0)", Self.material(.clear, .spark($0))) }
        bolts = (0..<2).map { Self.sprite("hoverboard.reaction.bolt\($0)", Self.material(.hit, .bolt)) }
        floorGlow = ModelEntity(mesh: Self.floorMesh, materials: [Self.material(.clear, .floor)])
        floorGlow.name = "hoverboard.reaction.floorGlow"
        floorGlow.position = [0, floorY + 0.025, 0]
        floorGlow.isEnabled = false
        for entity in [burst, floorGlow] + sparks + bolts { root.addChild(entity) }
        collectSurfaces(model)
    }

    /// Shows `kind`'s colours from its first frame.
    func start(_ kind: HoverboardReaction) {
        self.kind = kind
        burst.model?.materials = [Self.material(kind, .burst)]
        floorGlow.model?.materials = [Self.material(kind, .floor)]
        for (i, spark) in sparks.enumerated() { spark.model?.materials = [Self.material(kind, .spark(i))] }
    }

    /// Lays out one frame. `deckX` is the board's ride offset, `deckY` its deck top.
    func apply(_ pose: HoverboardReaction.Pose, tau: Double, deckX: Float, deckY: Float, reduceMotion: Bool) {
        let z = Self.spriteDepth
        if let size = pose.burst, pose.burstOpacity > 0.01 {
            // An ellipse around the board, wider than tall, centred a little above the deck.
            let w = boardWidth * size * 1.25
            burst.transform = Transform(scale: [w, w * 0.42, 1], rotation: simd_quatf(angle: pose.burstSpin, axis: [0, 0, 1]),
                                        translation: [deckX, deckY + 0.06, z])
            show(burst, pose.burstOpacity)
        } else { hide(burst) }
        show(floorGlow, pose.glow)
        floorGlow.position.x = deckX
        for (i, spark) in sparks.enumerated() {
            if let s = kind.spark(i, at: tau, boardWidth: boardWidth, reduceMotion: reduceMotion), s.size > 0.005 {
                spark.transform = Transform(scale: [s.size, s.size, 1], rotation: simd_quatf(angle: Float(tau) * 6 * (i.isMultiple(of: 2) ? 1 : -1), axis: [0, 0, 1]),
                                            translation: [deckX + s.position.x, deckY + s.position.y, z + 0.02])
                show(spark, s.opacity)
            } else { hide(spark) }
        }
        for (i, bolt) in bolts.enumerated() {
            guard kind == .hit, pose.bolts else { hide(bolt); continue }
            let side: Float = i == 0 ? -1 : 1
            let wobble = Float(HoverboardReaction.hash(i, pose.step) - 0.5) * 0.6
            let flip: Float = HoverboardReaction.hash(i + 5, pose.step) > 0.5 ? -1 : 1
            let size = 0.38 + 0.08 * Float(HoverboardReaction.hash(i + 9, pose.step))
            bolt.transform = Transform(scale: [size * flip, size, 1], rotation: simd_quatf(angle: side * 0.5 + wobble, axis: [0, 0, 1]),
                                       translation: [deckX + side * boardWidth * 0.55, deckY + 0.1, z + 0.03])
            show(bolt, 1)
        }
        let key = pose.lights > 0 ? Key(kind: kind, level: pose.lights) : nil
        if key != shownLights { showLights(key) }
    }

    /// Everything back to rest (no reaction).
    func reset() {
        for entity in [burst, floorGlow] + sparks + bolts { hide(entity) }
        if shownLights != nil { showLights(nil) }
    }

    private func show(_ entity: ModelEntity, _ opacity: Float) {
        guard opacity > 0.01 else { hide(entity); return }
        entity.isEnabled = true
        let id = ObjectIdentifier(entity)
        if let last = shown[id], abs(last - opacity) < 0.02 { return }
        shown[id] = opacity
        entity.components.set(OpacityComponent(opacity: opacity))
    }

    private func hide(_ entity: ModelEntity) {
        guard entity.isEnabled else { return }
        entity.isEnabled = false
        shown[ObjectIdentifier(entity)] = nil
    }

    // MARK: Board lights

    /// The board's PBR surfaces: light bars and accents (authored emissive) blaze; the shell
    /// glows faintly in the reaction's colour.
    private func collectSurfaces(_ entity: Entity) {
        if let model = entity as? ModelEntity, let materials = model.model?.materials,
           materials.contains(where: { $0 is PhysicallyBasedMaterial }) {
            var lit: [Key: [any RealityKit.Material]] = [:]
            for kind in [HoverboardReaction.clear, .hit] {
                for level in 1...2 {
                    lit[Key(kind: kind, level: level)] = materials.map { Self.lit($0, kind: kind, level: level) }
                }
            }
            surfaces.append((model, materials, lit))
        }
        for child in entity.children where !(child.name.hasPrefix("hoverboard.")) { collectSurfaces(child) }
    }

    private func showLights(_ key: Key?) {
        shownLights = key
        for surface in surfaces {
            surface.entity.model?.materials = key.flatMap { surface.lit[$0] } ?? surface.rest
        }
    }

    private static func lit(_ material: any RealityKit.Material, kind: HoverboardReaction, level: Int) -> any RealityKit.Material {
        guard var pbr = material as? PhysicallyBasedMaterial else { return material }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        pbr.emissiveColor.color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let isLight = r + g + b > 0.15 && pbr.emissiveIntensity > 0.01
        let color = kind == .clear
            ? (level == 2 ? UIColor(red: 1, green: 0.95, blue: 0.7, alpha: 1) : UIColor(red: 1, green: 0.8, blue: 0.32, alpha: 1))
            : (level == 2 ? UIColor(red: 1, green: 0.42, blue: 0.48, alpha: 1) : UIColor(red: 1, green: 0.3, blue: 0.36, alpha: 1))
        pbr.emissiveColor = .init(color: color)
        pbr.emissiveIntensity = isLight ? (level == 2 ? 4 : 2.2) : (level == 2 ? 0.22 : 0.1)
        return pbr
    }

    // MARK: Sprites

    private static let quad = MeshResource.generatePlane(width: 1, height: 1)
    private static let floorMesh = MeshResource.generatePlane(width: 1.9, depth: 0.8)

    private static func sprite(_ name: String, _ material: UnlitMaterial) -> ModelEntity {
        let entity = ModelEntity(mesh: quad, materials: [material])
        entity.name = name
        entity.isEnabled = false
        return entity
    }

    private enum Part: Hashable { case burst, floor, bolt, spark(Int) }
    private struct MaterialKey: Hashable { let kind: HoverboardReaction; let part: Part }
    private static var materials: [MaterialKey: UnlitMaterial] = [:]

    /// Procedural textures, drawn once per app run and shared by both boards.
    private static func material(_ kind: HoverboardReaction, _ part: Part) -> UnlitMaterial {
        let partKey: Part = if case .spark(let i) = part { .spark(i % 2) } else { part }
        let key = MaterialKey(kind: kind, part: partKey)
        if let made = materials[key] { return made }
        let made: UnlitMaterial
        switch partKey {
        case .burst: made = texture("hoverboard.burst.\(kind)", size: 256) { u, v in kind == .clear ? sunburst(u, v) : shock(u, v) }
        case .floor: made = texture("hoverboard.floor.\(kind)", size: 64) { u, v in
            let r = min(1, (u * u + v * v).squareRoot()), a = 0.5 * pow(1 - r * r, 2)
            return kind == .clear ? (1, 0.82, 0.3, a) : (1, 0.32, 0.4, a)
        }
        case .bolt: made = texture("hoverboard.bolt", size: 128) { u, v in bolt(u, v) }
        case .spark(let i):
            let color: (Float, Float, Float) = kind == .clear
                ? (i == 0 ? (1, 0.86, 0.3) : (0.5, 0.95, 1)) : (i == 0 ? (1, 0.45, 0.5) : (1, 0.95, 0.6))
            made = texture("hoverboard.spark.\(kind).\(i)", size: 64) { u, v in star(u, v, color) }
        }
        materials[key] = made
        return made
    }

    /// CLEAR's sunburst: a bold gold ring with a cream-hot core and twelve tapered rays outside it.
    private static func sunburst(_ u: Float, _ v: Float) -> (Float, Float, Float, Float) {
        let r = (u * u + v * v).squareRoot(), a = atan2(v, u)
        let ring = max(0, 1 - abs(r - 0.6) / 0.11), core = max(0, 1 - abs(r - 0.6) / 0.045)
        let k = (a + .pi) / (2 * .pi) * 12, frac = k - floor(k)
        let long = Int(floor(k)).isMultiple(of: 2)
        let rayWidth = 0.5 * (1 - (r - 0.72) / ((long ? 0.98 : 0.88) - 0.72))
        let ray: Float = r > 0.72 && r < (long ? 0.98 : 0.88) && abs(frac - 0.5) < 0.18 * max(0, rayWidth) * 2 ? 1 : 0
        let alpha = min(1, max(ring * 1.6, ray * 0.95))
        let hot = max(core, ray * 0.6)
        return (1, 0.78 + 0.2 * hot, 0.22 + 0.7 * hot, alpha)
    }

    /// HIT's shock: a thick jagged coral ring (14 spikes) with a hot pale core.
    private static func shock(_ u: Float, _ v: Float) -> (Float, Float, Float, Float) {
        let r = (u * u + v * v).squareRoot(), a = atan2(v, u)
        let k = (a + .pi) / (2 * .pi) * 14, tri = abs(2 * (k - floor(k)) - 1)
        let center = 0.6 + 0.2 * tri
        let band = max(0, 1 - abs(r - center) / 0.13), core = max(0, 1 - abs(r - center) / 0.05)
        return (1, 0.32 + 0.6 * core, 0.42 + 0.35 * core, min(1, band * 1.6))
    }

    /// A cartoon bolt: pale yellow core, electric cyan rim.
    private static func bolt(_ u: Float, _ v: Float) -> (Float, Float, Float, Float) {
        // The zig-zag spine x(y) and its distance.
        let y = -v
        let spine: Float = y > 0.15 ? 0.25 - (y - 0.15) * 0.6 : y > -0.15 ? -0.15 + (y + 0.15) * 1.33 : 0.2 + (y + 0.15) * 0.8
        let d = abs(u - spine) * (abs(y) < 0.9 ? 1 : 10)
        let core = max(0, 1 - d / 0.07), rim = max(0, 1 - d / 0.15)
        return (0.5 + 0.5 * core, 0.95, 1 - 0.4 * core, min(1, rim * 1.4))
    }

    /// A four-point star with a soft glow and a white-hot centre, tinted.
    private static func star(_ u: Float, _ v: Float, _ c: (Float, Float, Float)) -> (Float, Float, Float, Float) {
        let au = abs(u), av = abs(v)
        let spike = max(0, 1 - (au * 6 + av)) + max(0, 1 - (av * 6 + au))
        let glow = max(0, 1 - (au * au + av * av).squareRoot()) * 0.45
        let a = min(1, spike * 1.4 + glow)
        let hot = min(1, spike)
        return (c.0 + (1 - c.0) * hot, c.1 + (1 - c.1) * hot, c.2 + (1 - c.2) * hot, a)
    }

    private static func texture(_ name: String, size: Int, _ pixel: (Float, Float) -> (Float, Float, Float, Float)) -> UnlitMaterial {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for row in 0..<size {
            for column in 0..<size {
                let u = (Float(column) + 0.5) / Float(size) * 2 - 1, v = (Float(row) + 0.5) / Float(size) * 2 - 1
                let (r, g, b, a) = pixel(u, v)
                let alpha = max(0, min(1, a)), i = (row * size + column) * 4
                bytes[i] = UInt8((max(0, min(1, r)) * alpha * 255).rounded())
                bytes[i + 1] = UInt8((max(0, min(1, g)) * alpha * 255).rounded())
                bytes[i + 2] = UInt8((max(0, min(1, b)) * alpha * 255).rounded())
                bytes[i + 3] = UInt8((alpha * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let texture = try? TextureResource(image: image, withName: name, options: .init(semantic: .color))
        else {
            material.color = .init(tint: .clear)
            material.blending = .transparent(opacity: 0.0)
            return material
        }
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: 1.0)
        return material
    }
}
