//
//  EnvironmentPreview.swift
//  Sedactive
//

#if DEBUG
import Foundation
import RealityKit
import SwiftUI

/// Developer-only preview of the LH-03 environment: corridor travel, the
/// hoverboard, the vault door and diamonds, without Jevon's gameplay or Edo's
/// camera.
///
/// Runs on RealityKit frame time and decides nothing. Speeds, depths and holds
/// are temporary tuning values. In the game, travel distance, the door's depth
/// and state, and diamond positions and pickups come from game state
/// (TEAM_ALIGNMENT §C); the `LaserScene` calls below stay the same.
///
/// Launch with `-environmentPreview <mode>` (the laser preview is off meanwhile):
/// - `journey` (default): travel; a vault door arrives, unlocks, opens and
///   passes; diamonds approach, two are collected and one is missed; repeat.
/// - `door`: the door at a fixed depth, cycling closed, opening, open, resetting.
/// - `door-closed`, `door-open`: one door state, held.
/// - `diamonds`: three floating diamonds, collected or removed in turn.
///
/// `-environmentSpeed <m/s>` sets the sample travel speed.
@MainActor
final class EnvironmentPreview {
    enum Mode: String {
        case journey, door, diamonds
        case doorClosed = "door-closed"
        case doorOpen = "door-open"
    }

    /// The mode requested at launch, or `nil` when the preview is off.
    static var requestedMode: Mode? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-environmentPreview") else { return nil }
        return index + 1 < arguments.count ? Mode(rawValue: arguments[index + 1]) ?? .journey : .journey
    }

    /// Temporary tuning values, not approved constants. The default speed
    /// matches the laser preview's sample approach (22 m in 4.2 s).
    struct Tuning {
        var cruiseSpeed: Float = 5.2
        var doorSpawnZ: Float = -60
        var doorStopZ: Float = -7.5
        var brakingDistance: Float = 9
        var accelerationTime: Double = 1.6
        var lockedHold: Double = 1.2
        var openHold: Double = 1.2
        var diamondSpawnZ: Float = -36
    }

    private enum Stage {
        case cruising, doorArriving, doorLocked, doorOpening, departing, diamonds, finishing
    }

    /// A sample diamond: where it floats relative to the players, and whether
    /// the script collects it at the interaction plane or lets it pass.
    private struct SampleDiamond {
        let position: SIMD2<Float>
        let lead: Float
        let collected: Bool
    }

    private static let sampleDiamonds = [
        SampleDiamond(position: [-1.55, 1.15], lead: 0, collected: true),
        SampleDiamond(position: [1.45, 0.9], lead: 4, collected: true),
        SampleDiamond(position: [0, 1.55], lead: 8, collected: false),
    ]

    var tuning = Tuning()
    private var mode: Mode = .journey
    private var stage: Stage = .cruising
    private var stageTime: Double = 0
    private var doorZ: Float = 0
    private var diamonds: [(diamond: Diamond, sample: SampleDiamond, done: Bool)] = []
    private var subscription: EventSubscription?

    func start(on content: RealityViewCameraContent, scene: LaserScene, mode: Mode) {
        self.mode = mode
        if let speed = Self.argument("-environmentSpeed").flatMap(Float.init) {
            tuning.cruiseSpeed = speed
        }
        scene.isLaserVisible = false
        scene.clearLaserFeedback()
        switch mode {
        case .doorClosed, .doorOpen:
            scene.setVaultDoorDepth(tuning.doorStopZ)
            scene.setVaultDoorState(mode == .doorOpen ? .open : .locked, animated: false)
            return
        case .door:
            scene.setVaultDoorDepth(tuning.doorStopZ)
        case .diamonds:
            // Just in front of the players, where wrists collect them.
            placeDiamonds(on: scene, atZ: 0.25)
        case .journey:
            break
        }
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.advance(by: event.deltaTime, scene: scene)
        }
    }

    private static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private func advance(by deltaTime: TimeInterval, scene: LaserScene) {
        stageTime += deltaTime
        switch mode {
        case .journey: journey(deltaTime, scene: scene)
        case .door: doorCycle(scene: scene)
        case .diamonds: diamondCycle(scene: scene)
        case .doorClosed, .doorOpen: break
        }
    }

    private func enter(_ next: Stage) {
        stage = next
        stageTime = 0
    }

    // MARK: - Journey

    private func journey(_ deltaTime: TimeInterval, scene: LaserScene) {
        let cruise = tuning.cruiseSpeed
        var speed = cruise
        switch stage {
        case .cruising:
            if stageTime > 2.5 {
                doorZ = tuning.doorSpawnZ
                scene.setVaultDoorDepth(doorZ)
                enter(.doorArriving)
            }
        case .doorArriving:
            // Even braking to a stop exactly at the door's halt depth.
            let remaining = tuning.doorStopZ - doorZ
            let braking = cruise * cruise / (2 * tuning.brakingDistance)
            speed = min(cruise, (2 * braking * max(remaining, 0)).squareRoot())
            if remaining < 0.01 {
                speed = 0
                doorZ = tuning.doorStopZ
                enter(.doorLocked)
            }
        case .doorLocked:
            speed = 0
            if stageTime > tuning.lockedHold {
                scene.setVaultDoorState(.open, animated: true)
                enter(.doorOpening)
            }
        case .doorOpening:
            speed = 0
            if stageTime > VaultDoor.lightDuration + VaultDoor.openDuration + tuning.openHold {
                enter(.departing)
            }
        case .departing:
            let ramp = Float(min(stageTime / tuning.accelerationTime, 1))
            speed = cruise * ramp * ramp
            if doorZ > scene.layout.cameraPosition.z + 1 {
                scene.setVaultDoorDepth(nil)
                scene.resetVaultDoor()
                placeDiamonds(on: scene, atZ: tuning.diamondSpawnZ)
                enter(.diamonds)
            }
        case .diamonds:
            updateDiamonds()
            if diamonds.allSatisfy(\.done), stageTime > 1 {
                enter(.finishing)
            }
        case .finishing:
            if stageTime > 1.5 {
                clearDiamonds()
                enter(.cruising)
            }
        }
        let distance = speed * Float(deltaTime)
        scene.advanceTravel(by: distance)
        if scene.vaultDoorDepth != nil {
            doorZ += stage == .doorArriving || stage == .departing ? distance : 0
            scene.setVaultDoorDepth(doorZ)
        }
        for entry in diamonds {
            entry.diamond.root.position.z += distance
        }
    }

    /// Collects or misses each sample diamond as it reaches the players.
    private func updateDiamonds() {
        for index in diamonds.indices where !diamonds[index].done {
            let entry = diamonds[index]
            let z = entry.diamond.root.position.z
            if entry.sample.collected, z >= 0 {
                entry.diamond.collect()
                diamonds[index].done = true
            } else if !entry.sample.collected, z >= 0.9 {
                entry.diamond.remove()
                diamonds[index].done = true
            }
        }
    }

    // MARK: - Door and diamond cycles

    private func doorCycle(scene: LaserScene) {
        let opening = VaultDoor.lightDuration + VaultDoor.openDuration
        switch stageTime {
        case ..<1.5:
            break
        case ..<(1.5 + opening + 1.5):
            scene.setVaultDoorState(.open, animated: true)
        case ..<(1.5 + opening + 1.5 + VaultDoor.closeDuration + 0.6):
            scene.setVaultDoorState(.locked, animated: true)
        default:
            stageTime = 0
        }
    }

    private func diamondCycle(scene: LaserScene) {
        let steps: [(Double, (Diamond) -> Void)] = [(2.0, { $0.collect() }), (3.2, { $0.collect() }), (4.4, { $0.remove() })]
        for (index, (time, action)) in steps.enumerated() where stageTime >= time && !diamonds[index].done {
            action(diamonds[index].diamond)
            diamonds[index].done = true
        }
        if stageTime > 5.6 {
            for index in diamonds.indices {
                diamonds[index].diamond.showIdle()
                diamonds[index].done = false
            }
            stageTime = 0
        }
    }

    private func placeDiamonds(on scene: LaserScene, atZ z: Float) {
        clearDiamonds()
        for sample in Self.sampleDiamonds {
            guard let diamond = scene.makeDiamond() else { return }
            let depth = mode == .diamonds ? z : z - sample.lead
            diamond.root.position = [sample.position.x, sample.position.y, depth]
            diamond.showIdle()
            diamonds.append((diamond, sample, false))
        }
    }

    private func clearDiamonds() {
        for entry in diamonds {
            entry.diamond.root.removeFromParent()
        }
        diamonds = []
    }
}
#endif
