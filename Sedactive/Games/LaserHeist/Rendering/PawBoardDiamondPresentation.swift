import CoreGraphics
import Foundation
import Observation
import RealityKit

/// Draws the paw board's authoritative targets in the vault scene. The board
/// stays the sole source of screen positions and pickup outcomes.
@MainActor @Observable
final class PawBoardDiamondPresentation {
    struct Placement {
        let position: SIMD3<Float>
        let rotation: simd_quatf
        let radius: Float
        let cameraPosition: SIMD3<Float>
    }

    /// Inverse of the scene camera's vertical-FOV projection at a fixed depth.
    /// Board and viewport frames are measured in the same SwiftUI space.
    struct Projection {
        let board: CGRect
        let viewport: CGRect
        let cameraPosition: SIMD3<Float>
        let rotation: simd_quatf
        let verticalFieldOfView: Float

        private static let depth: Float = 1.65

        func placement(for position: LaserDiamondPosition) -> Placement? {
            guard board.width > 0, board.height > 0, viewport.width > 0, viewport.height > 0,
                  verticalFieldOfView > 0, verticalFieldOfView < 180 else { return nil }
            let unit = board.width / LaserDiamondTimeBoard.width
            let point = CGPoint(x: board.minX + position.x * unit, y: board.minY + position.y * unit)
            let metersPerPoint = 2 * Self.depth * tan(verticalFieldOfView * .pi / 360) / Float(viewport.height)
            let offset: SIMD3<Float> = [Float(point.x - viewport.midX) * metersPerPoint,
                                        Float(viewport.midY - point.y) * metersPerPoint, -Self.depth]
            let radius = Float(unit * LaserDiamondTimeBoard.diamondRadius) * metersPerPoint
            return Placement(position: cameraPosition + rotation.act(offset), rotation: rotation,
                             radius: radius, cameraPosition: cameraPosition)
        }
    }

    @ObservationIgnored var boardFrame: CGRect = .zero
    @ObservationIgnored var viewportFrame: CGRect = .zero
    private(set) var renderedIDs: Set<UUID> = []
    @ObservationIgnored private var shown: [UUID: Diamond] = [:]

    func update(states: [UUID: LaserDiamondState], time: Double, scene: LaserScene,
                onCollected: ((UUID, SIMD3<Float>) -> Void)? = nil,
                place: (LaserDiamondPosition) -> Placement?) {
        var rendered: Set<UUID> = []
        for state in states.values {
            guard case .diamondTime = state.lifetime else { continue }
            let spawn = state.spawn
            let age = time - spawn.spawnedAt
            guard age >= 0 else { continue }
            let pickedUp: Bool
            switch state.outcome {
            case nil:
                pickedUp = false
            case .collected(_, let collectedAt) where time >= collectedAt && time - collectedAt < Diamond.effectLifetime:
                pickedUp = true
            default:
                continue
            }

            guard let placement = place(spawn.position),
                  let diamond = shown[spawn.id] ?? scene.makeDiamond(passage: true) else { continue }
            if shown[spawn.id] == nil {
                diamond.root.name = "diamondTime.pawBoard.\(spawn.id)"
                diamond.showIdle()
                shown[spawn.id] = diamond
            }
            diamond.placeOnScreen(at: placement.position, rotation: placement.rotation, radius: placement.radius)
            diamond.updatePassagePose(age: age, glow: .collectible, cameraPosition: placement.cameraPosition)
            if pickedUp, diamond.phase == .idle {
                onCollected?(spawn.id, placement.position)
                diamond.collect()
            }
            rendered.insert(spawn.id)
        }
        for id in Set(shown.keys).subtracting(rendered) {
            shown.removeValue(forKey: id)?.retire()
        }
        if renderedIDs != rendered { renderedIDs = rendered }
    }

    func clear() {
        for diamond in shown.values { diamond.retire() }
        shown.removeAll()
        if !renderedIDs.isEmpty { renderedIDs = [] }
    }
}
