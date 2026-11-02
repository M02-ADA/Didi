//
//  PoseDebugOverlay.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

#if DEBUG
import RealityKit
import UIKit

/// Developer-only spatial aids for the LaserHeist world: world origin, the
/// player interaction plane, player feet and depth markers along the corridor.
/// Body markers (estimated crown/soles) join this view once Edo's data exists.
@MainActor
enum PoseDebugOverlay {
    static func make(for scene: LaserScene) -> Entity {
        let overlay = Entity()
        overlay.name = "debugOverlay"
        let layout = scene.layout
        let planeZ = scene.mapping.interactionPlaneZ

        overlay.addChild(axes(length: 0.5))
        overlay.addChild(label("origin", at: [0.05, 0.05, 0.02], color: .white))

        overlay.addChild(planeOutline(width: layout.corridorWidth - 0.2, height: layout.corridorHeight - 0.2, z: planeZ))
        overlay.addChild(label("interaction plane  z = \(format(planeZ))", at: [-layout.corridorWidth / 2 + 0.15, layout.corridorHeight - 0.3, planeZ], color: .yellow))
        overlay.addChild(label("environment: \(scene.environmentSource?.rawValue ?? "none")", at: [-layout.corridorWidth / 2 + 0.15, layout.corridorHeight - 0.45, planeZ], color: .yellow))

        for (lane, player) in scene.players {
            let feet = ModelEntity(mesh: .generateSphere(radius: 0.04), materials: [UnlitMaterial(color: .green)])
            feet.position = player.position
            overlay.addChild(feet)
            overlay.addChild(label("\(lane.rawValue)  x = \(format(player.position.x))", at: player.position + [-0.25, -0.12, 0.05], color: .green))
        }

        for z in stride(from: Float(-4), through: layout.laserSpawnZ, by: -4) {
            // Centred between the lanes so the player surfaces don't hide them.
            overlay.addChild(label("z = \(format(z))", at: [-0.3, 0.05, z], color: .cyan, size: 0.16))
        }
        return overlay
    }

    private static func axes(length: Float) -> Entity {
        let axes = Entity()
        let parts: [(SIMD3<Float>, SIMD3<Float>, UIColor)] = [
            ([length, 0.01, 0.01], [length / 2, 0, 0], .red),
            ([0.01, length, 0.01], [0, length / 2, 0], .green),
            ([0.01, 0.01, length], [0, 0, -length / 2], .blue),
        ]
        for (size, position, color) in parts {
            let axis = ModelEntity(mesh: .generateBox(size: size), materials: [UnlitMaterial(color: color)])
            axis.position = position
            axes.addChild(axis)
        }
        return axes
    }

    private static func planeOutline(width: Float, height: Float, z: Float) -> Entity {
        let outline = Entity()
        let thickness: Float = 0.012
        let material = UnlitMaterial(color: .yellow)
        let edges: [(SIMD3<Float>, SIMD3<Float>)] = [
            ([width, thickness, thickness], [0, 0.1, z]),
            ([width, thickness, thickness], [0, 0.1 + height, z]),
            ([thickness, height, thickness], [-width / 2, 0.1 + height / 2, z]),
            ([thickness, height, thickness], [width / 2, 0.1 + height / 2, z]),
        ]
        for (size, position) in edges {
            let edge = ModelEntity(mesh: .generateBox(size: size), materials: [material])
            edge.position = position
            outline.addChild(edge)
        }
        return outline
    }

    private static func label(_ text: String, at position: SIMD3<Float>, color: UIColor, size: CGFloat = 0.09) -> Entity {
        let mesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.001,
            font: .monospacedSystemFont(ofSize: size, weight: .semibold)
        )
        let entity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
        entity.position = position
        return entity
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.2f", value)
    }
}
#endif
