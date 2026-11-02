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
/// The game-unit scale and display mirroring are still TBD with Edo and Jevon
/// (TEAM_ALIGNMENT §C). Until they are agreed, one game unit is one meter and
/// nothing is mirrored.
struct GameWorldMapping {
    /// Rendering-side lane until players are identified by Edo's `PlayerID`.
    enum Lane: String, CaseIterable {
        case parent
        case child
    }

    var metersPerGameUnit: Float = 1
    var interactionPlaneZ: Float = 0
    var laneCenterX: [Lane: Float] = [.parent: -0.7, .child: 0.7]

    /// A point on the interaction plane in a player's lane.
    func playerPosition(_ lane: Lane, heightAboveFloor: Float = 0) -> SIMD3<Float> {
        [laneCenterX[lane, default: 0], heightAboveFloor * metersPerGameUnit, interactionPlaneZ]
    }

    /// The centre of a laser beam at a game-space height and a world depth.
    func laserPosition(heightAboveFloor: Float, worldZ: Float) -> SIMD3<Float> {
        [0, heightAboveFloor * metersPerGameUnit, worldZ]
    }
}
