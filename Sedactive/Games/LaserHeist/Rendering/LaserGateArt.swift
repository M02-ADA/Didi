//
//  LaserGateArt.swift
//  Sedactive
//

import RealityKit
import UIKit

/// The LaserHeist security-laser look: small procedural textures and shared
/// unlit materials for `LaserGate`, built once.
///
/// Art direction: a playful heist installation in the corridor's own language.
/// Navy/violet hardware is set into the walls; a coral energy beam has a
/// white-hot core, and light falls on the wall and floor. Shapes stay simple
/// and readable, with no realistic machinery, bloom or noise. Every texture
/// is a few kilobytes, drawn once, and shared by all gates.
@MainActor
enum LaserGateArt {
    // MARK: Palette (sRGB; unlit, not tone-mapped)

    /// The beam's white-hot centre.
    static let hot = RGB(0xFFF1EC)
    /// The beam's saturated rim, the corridor's warm hazard coral.
    static let coral = RGB(0xFF4458)
    /// Halo and light spill: a deeper coral, so the light around the beam stays darker than the beam itself.
    static let spill = RGB(0xFF3D55)
    /// Hardware, taken from the corridor walls and ribs.
    static let plate = RGB(0x2D2765), plateRim = RGB(0x5C52AC), recess = RGB(0x1D1944), barrel = RGB(0x463E92)
    /// A powered-down lens: the cool violet of the old disabled art.
    static let off = RGB(0x7380F0)

    struct RGB {
        let r, g, b: Float
        init(_ hex: UInt32) {
            r = Float((hex >> 16) & 0xFF) / 255
            g = Float((hex >> 8) & 0xFF) / 255
            b = Float(hex & 0xFF) / 255
        }
        func mix(_ other: RGB, _ t: Float) -> RGB { RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t) }
        private init(_ r: Float, _ g: Float, _ b: Float) { self.r = r; self.g = g; self.b = b }
        var uiColor: UIColor { UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1) }
    }

    // MARK: Materials

    /// The solid core: hot centre, coral rim, fully opaque so its edges are the band's edges.
    static let core = material("core", width: 4, height: 64, opaque: true) { _, v in
        let d = abs(v - 0.5) * 2
        return (hot.mix(coral, smoothstep(0.15, 0.9, d)), 1)
    }
    /// The beam's glow, from a band edge (v = 0) outward: bright coral against
    /// the core, falling off softly into deeper coral, so core and glow read as
    /// one beam rather than a stack of stripes. The falloff is steep, so the
    /// beam's visual weight sits on its core (on a DUCK beam, its judged lower
    /// edge) rather than drifting up into a tall haze.
    static let halo = material("halo", width: 4, height: 128) { _, v in
        (coral.mix(spill, min(1, v * 2.5)), 0.8 * pow(1 - v, 4.5))
    }
    /// A soft symmetric glow (around the riser where two halves step between heights).
    static let softGlow = material("softGlow", width: 32, height: 32) { u, v in
        let d = max(abs(u - 0.5), abs(v - 0.5)) * 2
        return (spill, 0.5 * pow(max(0, 1 - d), 2))
    }
    /// The beam's light on the corridor floor: a broad, faint pool (never a crisp
    /// line, which would read as a second, low laser), faded at both walls.
    static let floorLight = material("floorLight", width: 64, height: 64) { u, v in
        let across = exp(-pow((v - 0.5) / 0.3, 2)) * smoothstep(0, 0.2, v) * smoothstep(0, 0.2, 1 - v)
        let ends = smoothstep(0, 0.06, u) * smoothstep(0, 0.06, 1 - u)
        return (spill, 0.5 * across * ends)
    }
    /// A short white-hot streak that runs along the beam.
    static let packet = material("packet", width: 64, height: 16) { u, v in
        let along = pow(sin(.pi * u), 3)
        let across = 1 - smoothstep(0.35, 1, abs(v - 0.5) * 2)
        return (hot, along * across)
    }
    /// The hit flash over the core.
    static let flash: UnlitMaterial = {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .white)
        material.blending = .transparent(opacity: 1.0)
        return material
    }()
    /// The aperture lens, facing into the corridor: hot centre, coral ring, dark bezel.
    static let lens = material("lens", width: 64, height: 64) { u, v in
        let r = hypot(u - 0.5, v - 0.5) * 2
        let color = r < 0.62 ? hot.mix(coral, smoothstep(0.1, 0.62, r)) : recess
        return (color, 1 - smoothstep(0.92, 1, r))
    }
    /// A powered-down lens.
    static let offLens = material("offLens", width: 64, height: 64) { u, v in
        let r = hypot(u - 0.5, v - 0.5) * 2
        let color = r < 0.62 ? off.mix(recess, smoothstep(0.2, 0.62, r) * 0.6) : recess
        return (color, 1 - smoothstep(0.92, 1, r))
    }
    /// Camera-facing light at the aperture: readable at any distance, even when the lens is edge-on.
    static let flare = material("flare", width: 64, height: 64) { u, v in
        let r = hypot(u - 0.5, v - 0.5) * 2
        let color = hot.mix(coral, smoothstep(0, 0.35, r))
        return (color, max(0, 1 - smoothstep(0.08, 1, r)) * (r < 0.16 ? 1 : 0.75 * exp(-3 * (r - 0.16))))
    }
    static let offFlare = material("offFlare", width: 32, height: 32) { u, v in
        let r = hypot(u - 0.5, v - 0.5) * 2
        return (off, 0.55 * max(0, 1 - r) * max(0, 1 - r))
    }
    /// The emitter's light on its wall.
    static let splash = material("splash", width: 64, height: 64) { u, v in
        let r = hypot(u - 0.5, v - 0.5) * 2
        return (spill, 0.5 * exp(-pow(r / 0.45, 2)) * (1 - smoothstep(0.85, 1, r)))
    }
    /// The charge ring that gathers into the aperture during the warning.
    static let ring = material("ring", width: 64, height: 64) { u, v in
        let r = hypot(u - 0.5, v - 0.5) * 2
        return (coral.mix(hot, 0.3), max(0, 1 - abs(r - 0.82) / 0.1))
    }
    /// The wall plate: a rounded violet panel with a lavender rim, a recess around the aperture and two bolts.
    static let plateMaterial = material("plate", width: 96, height: 120) { u, v in
        let x = (u - 0.5) * 0.34, y = (v - 0.5) * 0.42
        let corner = 0.05 as Float
        let qx = max(abs(x) - (0.17 - corner), 0), qy = max(abs(y) - (0.21 - corner), 0)
        let outside = hypot(qx, qy) - corner
        if outside > 0 { return (plate, 0) }
        let edge = -outside
        var color = edge < 0.012 ? plateRim : plate
        if edge < 0.003 { color = plateRim.mix(plate, 0.4) }
        let toCentre = hypot(x, y)
        if toCentre < 0.085 { color = toCentre > 0.077 ? plateRim.mix(plate, 0.5) : recess }
        if hypot(x, abs(y) - 0.155) < 0.012 { color = plateRim }
        return (color, smoothstep(0, 0.002, edge))
    }
    static let barrelMaterial: UnlitMaterial = {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: barrel.uiColor)
        return material
    }()

    // MARK: Meshes

    /// A unit square in the XY plane, facing +Z; size it with `scale`.
    static let unitQuad = MeshResource.generatePlane(width: 1, height: 1)
    static let barrelMesh = MeshResource.generateBox(width: 1, height: 0.12, depth: 0.12, cornerRadius: 0.02)

    // MARK: Building

    private static func material(_ name: String, width: Int, height: Int, opaque: Bool = false,
                                 _ shade: (Float, Float) -> (RGB, Float)) -> UnlitMaterial {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        guard let texture = texture(name, width: width, height: height, shade) else {
            material.color = .init(tint: coral.uiColor)
            return material
        }
        material.color = .init(tint: .white, texture: .init(texture))
        if !opaque { material.blending = .transparent(opacity: 1.0) }
        return material
    }

    /// Draws a small texture from `shade(u, v)`, with v = 0 at the image's bottom row.
    private static func texture(_ name: String, width: Int, height: Int,
                                _ shade: (Float, Float) -> (RGB, Float)) -> TextureResource? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let v = 1 - (Float(row) + 0.5) / Float(height)
            for column in 0..<width {
                let u = (Float(column) + 0.5) / Float(width)
                let (color, rawAlpha) = shade(u, v)
                let alpha = min(max(rawAlpha, 0), 1)
                let i = (row * width + column) * 4
                pixels[i] = UInt8((color.r * alpha * 255).rounded())
                pixels[i + 1] = UInt8((color.g * alpha * 255).rounded())
                pixels[i + 2] = UInt8((color.b * alpha * 255).rounded())
                pixels[i + 3] = UInt8((alpha * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return try? TextureResource(image: image, withName: "laserGate.\(name)", options: .init(semantic: .color))
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
