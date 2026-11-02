//
//  PlayerCutoutEntity.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import RealityKit
import UIKit

/// A player's flat surface in the corridor.
///
/// The entity's origin sits at the player's feet, so changing `scale` keeps the
/// feet on the floor. Until LH-14 supplies the live cutout from Edo's
/// compositor, the surface shows a flat pictogram with transparent
/// surroundings, like the Hi-Fi.
final class PlayerCutoutEntity: Entity {
    private(set) var lane: GameWorldMapping.Lane = .parent

    init(lane: GameWorldMapping.Lane, size: SIMD2<Float>, color: UIColor) {
        super.init()
        self.lane = lane
        name = "player.\(lane.rawValue)"

        // No tone mapping, so placeholder colours match the Hi-Fi exactly.
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: color)
        if let texture = Self.pictogramTexture(aspect: size.x / size.y) {
            material.color = .init(tint: color, texture: .init(texture))
            material.blending = .transparent(opacity: 1.0)
            material.opacityThreshold = 0.5
        }
        let surface = ModelEntity(mesh: .generatePlane(width: size.x, height: size.y), materials: [material])
        surface.name = "player.\(lane.rawValue).surface"
        surface.position.y = size.y / 2
        addChild(surface)
    }

    required init() {
        super.init()
    }

    /// Placeholder figure: head, shoulders with arms, and two legs, drawn in
    /// white so the material's tint sets its colour.
    private static func pictogramTexture(aspect: Float) -> TextureResource? {
        let width: CGFloat = 256
        let height = width / CGFloat(aspect)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill()
            let head = width * 0.46
            UIBezierPath(ovalIn: CGRect(x: (width - head) / 2, y: 0, width: head, height: head)).fill()
            let shouldersTop = head + height * 0.03
            UIBezierPath(roundedRect: CGRect(x: 0, y: shouldersTop, width: width, height: height * 0.36), cornerRadius: width * 0.2).fill()
            let legsTop = shouldersTop + height * 0.3
            UIBezierPath(roundedRect: CGRect(x: width * 0.24, y: legsTop, width: width * 0.24, height: height - legsTop), cornerRadius: width * 0.1).fill()
            UIBezierPath(roundedRect: CGRect(x: width * 0.52, y: legsTop, width: width * 0.24, height: height - legsTop), cornerRadius: width * 0.1).fill()
            // Thin gaps separate the arms from the body, as in the Hi-Fi.
            context.cgContext.setBlendMode(.clear)
            for x in [width * 0.2, width * 0.765] {
                context.cgContext.fill(CGRect(x: x, y: shouldersTop + height * 0.11, width: width * 0.035, height: height))
            }
        }
        guard let cgImage = image.cgImage else { return nil }
        return try? TextureResource(image: cgImage, options: .init(semantic: .color))
    }
}
