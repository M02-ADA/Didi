//
//  CorridorDepth.swift
//  Sedactive
//

import RealityKit
import UIKit

/// Atmospheric depth for the LaserHeist corridor: the far corridor dissolves
/// into dark navy, so the hall reads as long and the gates emerge from deep
/// inside it instead of popping in mid-corridor.
///
/// - The walls, floor and ceiling get thin overlays with a smooth distance
///   gradient: clear near the players, near-opaque at the far end. One quad
///   per surface, so the haze never bands.
/// - Streaming parts (ribs, wall art, seams, runway lights) and laser gates
///   fade by their live distance with the same curve (`haze(atDistance:)`),
///   so everything in the hall shares one depth.
/// - Runway lights along both floor edges stream with the corridor every
///   3 m: a constant, readable cue of forward motion.
///
/// Presentation only: nothing here moves a gate, changes a time or decides
/// anything (TEAM_ALIGNMENT §C).
@MainActor
final class CorridorDepth {
    /// Distances from the camera, in meters: haze starts here…
    nonisolated static let hazeStart: Float = 12
    /// …and is deepest here (the corridor's far end is ~73 m away).
    nonisolated static let hazeEnd: Float = 60
    /// How much of the far corridor the haze hides.
    nonisolated static let maximumHaze: Float = 0.9
    /// Deep navy, darker than the walls: the hall seems to continue into the dark.
    static let hazeColor = LaserGateArt.RGB(0x110E26)

    /// Haze at a distance from the camera: 0 (clear) … `maximumHaze`.
    nonisolated static func haze(atDistance distance: Float) -> Float {
        let t = min(max((distance - hazeStart) / (hazeEnd - hazeStart), 0), 1)
        return maximumHaze * t * t * (3 - 2 * t)
    }

    let root = Entity()
    private let cameraZ: Float

    init(layout: LaserWorldLayout) {
        cameraZ = layout.cameraPosition.z
        root.name = "corridorDepth"
        let width = layout.corridorWidth, floorY = layout.corridorFloorY
        let height = layout.corridorHeight - floorY, middleY = (layout.corridorHeight + floorY) / 2
        let near = layout.corridorNearZ, far = layout.corridorFarZ
        let length = near - far, centerZ = (near + far) / 2
        let inset: Float = 0.006
        // Each overlay is a +Z-facing quad turned onto its surface; the texture's far
        // end is chosen per orientation so the gradient always deepens down the hall.
        func overlay(_ name: String, size: SIMD2<Float>, at position: SIMD3<Float>, turn: simd_quatf, farAt: Edge) {
            let quad = ModelEntity(mesh: .generatePlane(width: size.x, height: size.y),
                                   materials: [Self.gradient(near: near, far: far, cameraZ: cameraZ, farAt: farAt)])
            quad.name = "corridorDepth.\(name)"
            quad.position = position
            quad.orientation = turn
            root.addChild(quad)
        }
        overlay("floor", size: [width, length], at: [0, floorY + inset, centerZ],
                turn: simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]), farAt: .top)
        overlay("ceiling", size: [width, length], at: [0, layout.corridorHeight - inset, centerZ],
                turn: simd_quatf(angle: .pi / 2, axis: [1, 0, 0]), farAt: .bottom)
        overlay("leftWall", size: [length, height], at: [-width / 2 + inset, middleY, centerZ],
                turn: simd_quatf(angle: .pi / 2, axis: [0, 1, 0]), farAt: .right)
        overlay("rightWall", size: [length, height], at: [width / 2 - inset, middleY, centerZ],
                turn: simd_quatf(angle: -.pi / 2, axis: [0, 1, 0]), farAt: .left)
        // The far end: the haze at its deepest, in front of the painted end wall.
        var endMaterial = UnlitMaterial(applyPostProcessToneMap: false)
        endMaterial.color = .init(tint: UIColor(red: CGFloat(Self.hazeColor.r), green: CGFloat(Self.hazeColor.g),
                                                blue: CGFloat(Self.hazeColor.b), alpha: 1))
        endMaterial.blending = .transparent(opacity: .init(scale: Self.maximumHaze + 0.08))
        let end = ModelEntity(mesh: .generatePlane(width: width, height: height), materials: [endMaterial])
        end.name = "corridorDepth.end"
        end.position = [0, middleY, far + 0.05]
        root.addChild(end)
    }

    /// Fades one streaming or travelling entity by its current world depth.
    func apply(to entity: Entity, worldZ: Float) {
        let opacity = 1 - Self.haze(atDistance: cameraZ - worldZ)
        if opacity >= 0.999 {
            entity.components.remove(OpacityComponent.self)
        } else {
            entity.components.set(OpacityComponent(opacity: opacity))
        }
    }

    /// Runway lights: two rows of small lavender dashes along the floor edges,
    /// every 3 m over `span` meters (a whole number of travel loops), to be
    /// added to the corridor's streaming group.
    static func runwayLights(layout: LaserWorldLayout, span: Float) -> [Entity] {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: UIColor(red: 0x8E / 255, green: 0x80 / 255, blue: 0xF0 / 255, alpha: 1))
        material.blending = .transparent(opacity: 0.85)
        let mesh = MeshResource.generatePlane(width: 0.07, depth: 0.55, cornerRadius: 0.03)
        var lights: [Entity] = []
        for z in stride(from: Float(0), to: -span, by: -3) {
            for side: Float in [-1, 1] {
                let dash = ModelEntity(mesh: mesh, materials: [material])
                dash.name = "corridorDepth.runway"
                dash.position = [side * (layout.corridorWidth / 2 - 0.42), layout.corridorFloorY + 0.012, z]
                lights.append(dash)
            }
        }
        return lights
    }

    // MARK: - Gradient textures

    enum Edge { case top, bottom, left, right }

    /// A transparent-to-navy gradient over a quad running from `near` to `far` (world Z).
    private static func gradient(near: Float, far: Float, cameraZ: Float, farAt: Edge) -> UnlitMaterial {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        let samples = 256
        var alphas = [Float](repeating: 0, count: samples)
        for i in 0..<samples {
            let t = (Float(i) + 0.5) / Float(samples)   // 0 at the near end, 1 at the far end
            alphas[i] = haze(atDistance: cameraZ - (near + (far - near) * t))
        }
        let horizontal = farAt == .left || farAt == .right
        let width = horizontal ? samples : 2, height = horizontal ? 2 : samples
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                // Image rows run top-down; the quad's top edge shows the image's top row.
                let index: Int = switch farAt {
                case .right: column
                case .left: samples - 1 - column
                case .top: samples - 1 - row
                case .bottom: row
                }
                let a = alphas[index]
                let p = (row * width + column) * 4
                pixels[p] = UInt8((hazeColor.r * a * 255).rounded())
                pixels[p + 1] = UInt8((hazeColor.g * a * 255).rounded())
                pixels[p + 2] = UInt8((hazeColor.b * a * 255).rounded())
                pixels[p + 3] = UInt8((a * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let texture = try? TextureResource(image: image, withName: "corridorDepth.\(farAt)", options: .init(semantic: .color))
        else { return material }
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: 1.0)
        return material
    }
}
