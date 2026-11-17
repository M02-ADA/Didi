//
//  VerticalLaserPreview.swift
//  Sedactive
//

#if DEBUG
import Foundation
import RealityKit
import SwiftUI

/// DEBUG review of the vertical laser prototype (`VerticalLaser`) in the real corridor, with the
/// mascots standing on their lanes. No encounter, GameClock, judge or score: a scripted sample
/// timeline on RealityKit frame time, presentation review only.
///
/// Launch with `-replay -verticalLaserPreview [solo] [center|left|right|outer|sweep] [parked] [reduced] [seconds]`:
/// - **flow** (default): the obstacle emerges 60 m out and comes down the corridor at the travel
///   speed (5.2 m/s), the corridor streaming with it, crossing the players' plane 11.54 s in. Sample
///   leads as the horizontal lasers: warning 3 s and active 1.4 s before the crossing, power-down
///   0.35 s after it. Each loop is 13.14 s.
/// - **parked**: the obstacle stands 9 m from the camera (z −6) and runs inactive → warning →
///   active → power-down → off in place, so the activation and deactivation can be studied whole.
/// - Placement: `center` (x 0, between the mascots), `left` / `right` (on a mascot's lane, ±0.7 m),
///   `outer` (−2.0 m, near the wall); `sweep` (default) takes the next one each loop.
/// - `reduced` forces the Reduce Motion presentation; `solo` shows Lemon alone.
/// - `seconds` holds one moment of the loop (screenshots): the presentation is a pure function of
///   time, so any moment can be scrubbed to directly.
@MainActor
final class VerticalLaserPreview {
    enum Placement: String, CaseIterable {
        case center, left, right, outer
        var x: Float {
            switch self {
            case .center: 0
            case .left: -0.7
            case .right: 0.7
            case .outer: -2.0
            }
        }
    }

    struct Request {
        var solo = false
        var placement: Placement?
        var parked = false
        var reduced = false
        var heldAt: Double?
    }

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-verticalLaserPreview") }

    static var requested: Request {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-verticalLaserPreview") else { return Request() }
        let rest = arguments[(index + 1)...].prefix { !$0.hasPrefix("-") }
        return Request(solo: rest.contains("solo"), placement: rest.compactMap(Placement.init(rawValue:)).first,
                       parked: rest.contains("parked"), reduced: rest.contains("reduced"),
                       heldAt: rest.compactMap(Double.init).first)
    }

    /// Sample timings relative to the crossing (seconds): the horizontal lasers' candidates.
    static let warningLead = 3.0, activeLead = 1.4, powerDownAfter = 0.35, endAfter = 1.6
    /// Parked timeline (seconds from the loop's start).
    static let parkedZ: Float = -6
    static let parked = (warning: 1.2, active: 2.8, powerDown: 5.0, off: 5.3, end: 6.5)

    private let laser: VerticalLaser
    private let request: Request
    private let travelSpeed: Float
    private let planeZ: Float
    private let emergeZ: Float
    private var subscription: EventSubscription?
    private var elapsed = 0.0
    private var loopIndex = 0
    private var lastLabel = ""

    init(scene: LaserScene, request: Request) {
        self.request = request
        laser = VerticalLaser(layout: scene.layout, mapping: scene.mapping)
        laser.reduceMotion = request.reduced || UIAccessibility.isReduceMotionEnabled
        travelSpeed = scene.layout.travelSpeed
        planeZ = scene.mapping.interactionPlaneZ
        emergeZ = scene.layout.laserEmergeZ
        scene.root.addChild(laser.root)
    }

    /// Seconds from emerging to the crossing in flow mode (11.54 s).
    var crossingTime: Double { Double((planeZ - emergeZ) / travelSpeed) }
    var loopLength: Double { request.parked ? Self.parked.end : crossingTime + Self.endAfter }

    func start(on content: RealityViewCameraContent, scene: LaserScene) {
        if let heldAt = request.heldAt {
            show(at: min(heldAt, loopLength), loop: 0, scene: scene)
            return
        }
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            guard let self else { return }
            elapsed += event.deltaTime
            if elapsed >= loopLength {
                elapsed -= loopLength
                loopIndex += 1
            }
            show(at: elapsed, loop: loopIndex, scene: scene)
        }
    }

    /// The whole presentation at loop time `t`: placement, depth, corridor travel and phase.
    private func show(at t: Double, loop: Int, scene: LaserScene) {
        let placement = request.placement ?? Placement.allCases[loop % Placement.allCases.count]
        let phase: VerticalLaser.Phase
        let z: Float
        if request.parked {
            z = Self.parkedZ
            let p = Self.parked
            phase = switch t {
            case ..<p.warning: .inactive
            case ..<p.active: .warning(progress: Float((t - p.warning) / (p.active - p.warning)))
            case ..<p.powerDown: .active(elapsed: t - p.active)
            case ..<p.off: .powerDown(elapsed: t - p.powerDown)
            default: .off
            }
            scene.setTravelDistance(0)
        } else {
            let lead = crossingTime - t
            z = planeZ - travelSpeed * Float(lead)
            phase = switch -lead {
            case ..<(-Self.warningLead): .inactive
            case ..<(-Self.activeLead): .warning(progress: Float((Self.warningLead - lead) / (Self.warningLead - Self.activeLead)))
            case ..<Self.powerDownAfter: .active(elapsed: Self.activeLead - lead)
            default: .powerDown(elapsed: -lead - Self.powerDownAfter)
            }
            // The corridor streams with the obstacle, so it stands still relative to the walls.
            scene.setTravelDistance(travelSpeed * Float(t))
        }
        laser.setPlacement(x: placement.x, worldZ: z)
        laser.present(phase, ambientTime: t)
        let label = "\(Self.name(phase)) \(placement.rawValue)"
        if label != lastLabel {
            lastLabel = label
            print(String(format: "[VerticalLaserPreview] t %.2f · %@ · x %.2f · z %.1f · %.1f m from camera · opacity %.2f",
                         t, label, placement.x, z, scene.layout.cameraPosition.z - z, laser.opacity))
        }
    }

    private static func name(_ phase: VerticalLaser.Phase) -> String {
        switch phase {
        case .inactive: "inactive"
        case .warning: "warning"
        case .active: "active"
        case .powerDown: "powerDown"
        case .off: "off"
        }
    }
}
#endif
