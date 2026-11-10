//
//  NormalDiamondPresentation.swift
//  Sedactive
//

import Foundation
import RealityKit

/// One normal (passage) diamond in display terms, from Jevon's authoritative
/// `LaserDiamondState` (lifetime `.passage`). Placement and passage times are
/// the domain's; nothing here decides presence, collection or a miss.
struct NormalDiamond: Equatable, Identifiable {
    enum Outcome: Equatable { case pending, collected, missed, closed }

    let id: UUID
    /// The lane it floats in (its first eligible player).
    let lane: PlayerID
    /// Sideways from the lane centre, in game units (+ = screen right).
    let offsetX: Float
    /// Height above the calibrated floor, in game units.
    let heightAboveFloor: Float
    /// When the domain spawns it: the earliest it is shown.
    let spawnedAt: Double
    /// Its interaction passage, in game time.
    let entry: Double
    let exit: Double
    var outcome: Outcome

    /// When it stands at the players' interaction plane: the middle of its
    /// passage, so the window is centred on the players.
    var crossingTime: Double { (entry + exit) / 2 }
}

/// K06: normal diamonds coming down the corridor during the activity, each
/// placed like a laser gate (travel speed × game time to its crossing), so it
/// is at the players' plane in the middle of its domain passage window.
///
/// One entity per domain diamond, made once from the Reality Composer Pro
/// diamond (`LaserScene.makeDiamond`). Collected: the existing pop and
/// sparkles, once, then it goes. Missed: it keeps travelling past the players
/// with no feedback and is removed out of view. Closed (phase end): it fades.
/// Distinct from `DiamondTimePresentation`'s persistent targets. Keeps no clock:
/// everything follows the state's game time.
///
/// Visual acceptance is BLOCKED (see `Docs/LaserHeist-K06-Readiness-Handoff.md`):
/// the domain spawns normal diamonds only 0.5 s before interaction, so they
/// first appear about 5 m ahead instead of down the corridor, and the replay
/// plan's placements sit behind the mascots. PENDING Jevon (visual lead) and
/// Kevin + Theo + Edo (placement and reach). This view draws what the domain
/// says exists and never shows a diamond earlier than its spawn.
@MainActor
final class NormalDiamondPresentation {
    /// The domain's normal diamonds now, or `nil` with no source (shows nothing).
    var source: (() -> [NormalDiamond])?
    /// Collections shown so far (for the pickup sound, once per collection).
    private(set) var collections = 0

    private let scene: LaserScene
    private struct Shown {
        let diamond: Diamond
        let item: NormalDiamond
        var outcome: NormalDiamond.Outcome
        /// Game time after which a collected or closed diamond is removed.
        var until: Double?
    }
    private var shown: [UUID: Shown] = [:]

    /// How far down the corridor a diamond can first be seen (its far end).
    var horizonZ: Float { scene.layout.corridorFarZ + 2 }

    init(scene: LaserScene) {
        self.scene = scene
    }

    /// Diamond ids with an entity in the scene (tests and debugging).
    var shownIDs: Set<UUID> { Set(shown.keys) }

    /// World depth of a diamond at a game time (same rule as laser gates).
    func depth(of diamond: NormalDiamond, at time: Double) -> Float {
        scene.mapping.interactionPlaneZ - scene.layout.travelSpeed * Float(diamond.crossingTime - time)
    }

    func update(state: LaserGameState) {
        // Normal diamonds belong to the activity; a vault, Diamond Time or the
        // end leaves none behind.
        guard state.phase == .activity, let source else { return clear() }
        let time = state.gameTime
        let wanted = source()
        let ids = Set(wanted.map(\.id))
        for (id, entry) in shown where !ids.contains(id) {
            if entry.outcome != .collected { entry.diamond.remove() }
            retire(id, after: 0.25, at: time)
        }
        let nearCamera = scene.layout.cameraPosition.z - GameplayScenePresenter.cameraClearance
        for item in wanted {
            let z = depth(of: item, at: time)
            if var entry = shown[item.id] {
                if entry.outcome == .pending {
                    switch item.outcome {
                    case .collected:
                        entry.diamond.collect()
                        collections += 1
                        entry.until = time + Diamond.collectDuration + 0.15
                    case .closed:
                        entry.diamond.remove()
                        entry.until = time + 0.25
                    case .missed, .pending:
                        break
                    }
                    entry.outcome = item.outcome
                }
                entry.diamond.root.position.z = z
                shown[item.id] = entry
                // A passed diamond leaves before it reaches the camera.
                if z > nearCamera { remove(item.id) }
                continue
            }
            // First seen: only a pending diamond that has spawned and is in the corridor.
            guard item.outcome == .pending, time >= item.spawnedAt, z >= horizonZ, z <= nearCamera,
                  let diamond = scene.makeDiamond() else { continue }
            var position = scene.mapping.playerPosition(item.lane, heightAboveFloor: item.heightAboveFloor)
            position.x += item.offsetX * scene.mapping.metersPerGameUnit
            position.z = z
            diamond.root.position = position
            diamond.showIdle()
            shown[item.id] = Shown(diamond: diamond, item: item, outcome: .pending)
        }
        for (id, entry) in shown {
            if let until = entry.until, time >= until { remove(id) }
        }
    }

    /// Removes every normal diamond (phase change, stop, new generation).
    func clear() {
        for id in Array(shown.keys) { remove(id) }
    }

    private func retire(_ id: UUID, after delay: Double, at time: Double) {
        guard var entry = shown[id] else { return }
        if entry.until == nil { entry.until = time + delay }
        shown[id] = entry
    }

    private func remove(_ id: UUID) {
        shown[id]?.diamond.root.removeFromParent()
        shown[id] = nil
    }
}
