//
//  LaserApproachPreview.swift
//  Sedactive
//

#if DEBUG
import Foundation
import RealityKit
import SwiftUI

/// Developer-only motion for checking laser perspective and gate states (LH-11, LH-04).
///
/// Loops one laser from its spawn depth to just past the interaction plane and
/// walks through the gate's visual states. This is not game time and decides
/// nothing: the state timings are demo values, not warning leads or verdicts.
/// Jevon's `GameClock` and encounter state replace it once the frame-update
/// contract is agreed (TEAM_ALIGNMENT §C).
///
/// Launch with `-laserGateState <inactive|warning|active|hit|disabled>` to hold one
/// state, and `-laserPreviewDepth <z>` to hold the laser at one world depth.
@MainActor
final class LaserApproachPreview {
    var approachSeconds: Double = 4
    var holdSeconds: Double = 0.8
    var endZ: Float = 1.2
    private var elapsed: Double = 0
    private var subscription: EventSubscription?
    private let pinnedState = LaserApproachPreview.argument("-laserGateState").flatMap(LaserGate.VisualState.init(rawValue:))
    private let pinnedDepth = LaserApproachPreview.argument("-laserPreviewDepth").flatMap(Float.init)

    private static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    func start(on content: RealityViewCameraContent, scene: LaserScene) {
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.advance(by: event.deltaTime, scene: scene)
        }
    }

    private func advance(by deltaTime: TimeInterval, scene: LaserScene) {
        elapsed = (elapsed + deltaTime).truncatingRemainder(dividingBy: approachSeconds + holdSeconds)
        let progress = Float(min(elapsed / approachSeconds, 1))
        let spawnZ = scene.layout.laserSpawnZ
        let worldZ = pinnedDepth ?? spawnZ + (endZ - spawnZ) * progress
        scene.setLaserDepth(worldZ)
        scene.setLaserVisualState(pinnedState ?? demoState(progress: progress, worldZ: worldZ, scene: scene))
    }

    /// Demo order only: dim at spawn, warning, active, a hit flash just after
    /// the interaction plane, then disabled while holding past it.
    private func demoState(progress: Float, worldZ: Float, scene: LaserScene) -> LaserGate.VisualState {
        let planeZ = scene.mapping.interactionPlaneZ
        switch progress {
        case ..<0.08: return .inactive
        case ..<0.35: return .warning
        case ..<1 where worldZ < planeZ: return .active
        case ..<1 where worldZ < planeZ + 0.5: return .hit
        case ..<1: return .active
        default: return .disabled
        }
    }
}
#endif
