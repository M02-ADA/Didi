//
//  CorridorWidening.swift
//  Sedactive
//

import RealityKit

/// Widens the authored corridor (`LaserCorridor`, authored 6.3 m wide) to the layout's
/// `environmentWidth` at load time, without stretching its art (Kevin, 14 November 2026).
///
/// - Pieces on one side (walls, rib posts, wall art) move out with their wall.
/// - Pieces across the corridor (floor, ceiling, beams, floor seams, end wall) widen. Their
///   textures are flat colours (the end wall's is a soft gradient), so nothing visibly stretches.
/// - The laser mounts move out with the walls, so beams reach the wider walls.
/// - The lane anchors, the vault stop, the laser spawn point, the hoverboard and the editor
///   previews are not touched: the players' plane and lanes stay where gameplay maps them.
///
/// Presentation only: nothing here is read by gameplay, judgment or steering.
@MainActor
enum CorridorWidening {
    /// Child entities of the authored scene that keep their authored place and size.
    static let untouched: Set<String> = ["Hoverboard", "EditorPreviews", "PlayerAnchor_Parent", "PlayerAnchor_Child",
                                         "VaultDoorStop", "LaserSpawnPoint", "TravelLoop"]

    /// Widens `authored` from `authoredWidth` to `width` (a no-op when they match).
    static func widen(_ authored: Entity, from authoredWidth: Float, to width: Float) {
        let shift = (width - authoredWidth) / 2
        guard shift > 0.001 else { return }
        let scale = width / authoredWidth
        if let corridor = authored.findEntity(named: "Corridor") {
            // Classify against the authored places first, then move (moving changes bounds).
            var moves: [(Entity, Move)] = []
            collect(corridor, in: authored, into: &moves)
            for (entity, move) in moves {
                switch move {
                case .shift(let side): entity.position.x += side * shift
                case .widen:
                    entity.position.x *= scale
                    entity.scale.x *= scale
                }
            }
        }
        for (name, side) in [("LaserMount_Left", Float(-1)), ("LaserMount_Right", 1)] {
            authored.findEntity(named: name)?.position.x += side * shift
        }
    }

    /// Stretches a wall-side strip (a vault door's surround) so its outer edge reaches the wall at
    /// `wallHalfWidth`; its inner edge, against the door's frame, stays.
    static func stretch(_ strip: Entity, toWallAt wallHalfWidth: Float, in root: Entity) {
        let bounds = strip.visualBounds(relativeTo: root)
        let side: Float = bounds.center.x < 0 ? -1 : 1
        let inner = side < 0 ? bounds.max.x : bounds.min.x, outer = side < 0 ? bounds.min.x : bounds.max.x
        let width = abs(outer - inner), target = wallHalfWidth - abs(inner)
        guard width > 0.001, target > width + 0.001, strip.parent === root else { return }
        let scale = target / width
        // x' = position + scale · (x − position) about the strip's own origin; keep `inner` fixed.
        strip.scale.x *= scale
        strip.position.x = inner - scale * (inner - strip.position.x)
    }

    private enum Move { case shift(Float), widen }

    /// Each model under `entity` (outside `untouched`), classified by where it lies across the
    /// corridor: wholly on one side, or across its middle.
    private static func collect(_ entity: Entity, in root: Entity, into moves: inout [(Entity, Move)]) {
        for child in entity.children where !untouched.contains(child.name) {
            if child.components.has(ModelComponent.self) {
                let bounds = child.visualBounds(relativeTo: root)
                if bounds.min.x < -0.05, bounds.max.x > 0.05 { moves.append((child, .widen)) }
                else { moves.append((child, .shift(bounds.center.x < 0 ? -1 : 1))) }
            } else {
                collect(child, in: root, into: &moves)
            }
        }
    }
}
