//
//  Hoverboard.swift
//  Sedactive
//

import RealityKit

/// The hoverboard (Platform/Asset 11) that carries both players down the
/// corridor, from the `Hoverboard` group in the `LaserCorridor` scene.
///
/// It is decoration only: it never moves or scales the players, so their
/// crown, wrist and sole positions stay exactly where game data puts them
/// (TEAM_ALIGNMENT §C). It is visually stationary: it has no idle hover, so
/// the only vertical movement on screen is the players' own JUMP and DUCK.
///
/// The artwork is drawn in perspective, so it faces the camera rather than
/// lying on the floor, which would apply perspective twice. The upper half,
/// behind the players' feet, is pushed back along the camera rays: it looks
/// identical, but a low laser close to the crossing now draws in front of it
/// instead of disappearing behind it. Each half carries a darker copy of its
/// silhouette just below it, which reads as the board's thickness, and the
/// corridor floor lies well below with a soft shadow, so the board hovers.
@MainActor
final class Hoverboard {
    let root: Entity

    /// Returns `nil` when the scene lacks the board's named halves.
    /// - Parameters:
    ///   - camera: World position of the scene camera.
    ///   - backDepth: World z for the upper half; it must lie behind the
    ///     depth where a low beam first overlaps the board on screen.
    init?(entity: Entity, camera: SIMD3<Float>, backDepth: Float) {
        guard let front = entity.findEntity(named: "Front"), let back = entity.findEntity(named: "Back") else { return nil }
        root = entity
        Self.push(back, toWorldZ: backDepth, camera: camera)
        // The front half's layers are a few millimetres apart, and transparent
        // meshes sort by origin, so fix their order: edge, art, glow, then the
        // foot shadows on top. Otherwise a foot shadow can draw first and cut a hole.
        let group = ModelSortGroup()
        for (order, name) in ["Edge", "Art", "Underglow", "FootShadowParent", "FootShadowChild"].enumerated() {
            front.findEntity(named: name)?.components.set(ModelSortGroupComponent(group: group, order: Int32(order)))
        }
    }

    /// Centres the deck's contact shadows (`FootShadowParent`, `FootShadowChild`)
    /// under each player's feet, so the players read as standing on the board.
    /// The players never move with them.
    func setFootShadow(_ lane: GameWorldMapping.Lane, atWorldX x: Float) {
        let name = lane == .parent ? "FootShadowParent" : "FootShadowChild"
        guard let mark = root.findEntity(named: name) else { return }
        // The mesh is authored at its lane with the origin on the board's centre
        // line (for draw order), so shift it by how far its centre is from `x`.
        var position = mark.position(relativeTo: nil)
        position.x += x - mark.visualBounds(relativeTo: nil).center.x
        mark.setPosition(position, relativeTo: nil)
    }

    /// Moves a camera-facing part to `z` along the rays through the camera and
    /// scales it to match, so it projects to the same pixels.
    private static func push(_ part: Entity, toWorldZ z: Float, camera: SIMD3<Float>) {
        let position = part.position(relativeTo: nil)
        let scale = (camera.z - z) / (camera.z - position.z)
        part.setPosition(camera + scale * (position - camera), relativeTo: nil)
        part.scale *= scale
    }
}
