//
//  LaserApproachPreview.swift
//  Sedactive
//

#if DEBUG
import Foundation
import RealityKit
import SwiftUI

/// Developer-only motion for checking laser perspective (LH-11).
///
/// Loops one laser from its spawn depth to just past the interaction plane.
/// This is not game time and decides nothing. Jevon's `GameClock` and
/// encounter state replace it once the frame-update contract is agreed
/// (TEAM_ALIGNMENT §C).
@MainActor
final class LaserApproachPreview {
    var approachSeconds: Double = 4
    var holdSeconds: Double = 0.8
    var endZ: Float = 1.2
    private var elapsed: Double = 0
    private var subscription: EventSubscription?

    func start(on content: RealityViewCameraContent, scene: LaserScene) {
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.advance(by: event.deltaTime, scene: scene)
        }
    }

    private func advance(by deltaTime: TimeInterval, scene: LaserScene) {
        elapsed = (elapsed + deltaTime).truncatingRemainder(dividingBy: approachSeconds + holdSeconds)
        let progress = Float(min(elapsed / approachSeconds, 1))
        let spawnZ = scene.layout.laserSpawnZ
        scene.setLaserDepth(spawnZ + (endZ - spawnZ) * progress)
    }
}
#endif
