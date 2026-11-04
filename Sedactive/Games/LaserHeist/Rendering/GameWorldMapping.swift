//
//  GameWorldMapping.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import simd

/// Places LaserHeist game space into the RealityKit world.
///
/// World convention (RealityKit units are meters):
/// - Origin is the centre of the floor on the player interaction plane.
/// - +X is screen right, +Y is up, and the floor is Y = 0, matching game
///   space's "Y up from the calibrated floor".
/// - -Z runs down the corridor, away from the camera. Lasers start at negative Z
///   and travel toward the interaction plane at `interactionPlaneZ`.
///
/// The game-unit scale is still TBD with Edo and Jevon (TEAM_ALIGNMENT §C);
/// until it is agreed, one game unit is one meter. Live cutouts follow the
/// accepted CP2 presentation rule: each image is mirrored once about its own
/// lane centre, so players see themselves as in a mirror while P1 stays left.
/// Game data itself is never mirrored.
struct GameWorldMapping {
    /// Rendering-side lane. P1 binds displayed-left (CP1), so it uses the
    /// left lane; see `lane(for:)`.
    enum Lane: String, CaseIterable {
        case parent
        case child
    }

    var metersPerGameUnit: Float = 1
    var interactionPlaneZ: Float = 0
    var laneCenterX: [Lane: Float] = [.parent: -0.7, .child: 0.7]

    /// P1 is displayed-left and P2 displayed-right, for the whole session.
    static func lane(for playerID: PlayerID) -> Lane {
        playerID == .player1 ? .parent : .child
    }

    /// A point on the interaction plane in a player's lane.
    func playerPosition(_ lane: Lane, heightAboveFloor: Float = 0) -> SIMD3<Float> {
        [laneCenterX[lane, default: 0], heightAboveFloor * metersPerGameUnit, interactionPlaneZ]
    }

    /// Where a live cutout's whole canvas sits, relative to its lane's
    /// `playerPosition` (CP2 proposal §10).
    ///
    /// `playerPlaneRect` covers only the content rectangle, so the canvas size
    /// and offset come from the content's pixel scale; padding never stretches
    /// or shifts the body. The result is mirrored about the lane centre
    /// `laneCenter` (in player-plane units): positions reflect `x → 2L − x` and
    /// the quad's texture runs right to left. Sizes are always positive.
    func cutoutQuad(
        canvasWidth: Int, canvasHeight: Int,
        contentRect: CutoutPixelRect, playerPlaneRect: CutoutPlayerPlaneRect, laneCenter: Double
    ) -> (center: SIMD2<Float>, size: SIMD2<Float>) {
        let unitsPerPixel = playerPlaneRect.height / Double(contentRect.height)
        let width = Double(canvasWidth) * unitsPerPixel
        let height = Double(canvasHeight) * unitsPerPixel
        let left = playerPlaneRect.x - Double(contentRect.x) * unitsPerPixel
        let bottom = playerPlaneRect.y - Double(canvasHeight - contentRect.y - contentRect.height) * unitsPerPixel
        let center = SIMD2(left + width / 2, bottom + height / 2)
        // Mirrored about the lane, then measured from it: (2L − x) − L = L − x.
        let local = SIMD2(laneCenter - center.x, center.y) * Double(metersPerGameUnit)
        return (SIMD2<Float>(local), SIMD2<Float>(Float(width), Float(height)) * metersPerGameUnit)
    }

    /// A player-plane point (body measurements, debug markers) relative to its
    /// lane's `playerPosition`, mirrored the same way as the cutout.
    func cutoutPoint(x: Double, y: Double, laneCenter: Double) -> SIMD2<Float> {
        SIMD2<Float>(SIMD2(laneCenter - x, y) * Double(metersPerGameUnit))
    }

    /// The centre of a laser beam at a game-space height and a world depth.
    func laserPosition(heightAboveFloor: Float, worldZ: Float) -> SIMD3<Float> {
        [0, heightAboveFloor * metersPerGameUnit, worldZ]
    }
}
