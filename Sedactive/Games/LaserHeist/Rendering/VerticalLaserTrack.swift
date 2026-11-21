//
//  VerticalLaserTrack.swift
//  Sedactive
//

import Foundation
import RealityKit
import UIKit

/// What the renderer needs to draw one player's vertical laser (a LEAN target), read from game
/// state. A rendering view of the PROPOSED vertical laser contract (16 November 2026): until
/// Jevon's `LaserTarget` carries a beam position, only DEBUG fixtures fill it. Display only:
/// nothing judged reads it, and it decides nothing.
struct VerticalLaserCue: Equatable {
    /// The player's verdict as game state reports it, with the game time it was reported.
    enum Outcome: Equatable {
        case pending
        case clear(at: Double), hit(at: Double), unavailable(at: Double)
        /// Withdrawn (a pause, a skip): powered down without any verdict feedback.
        case withdrawn(at: Double)

        var time: Double? {
            switch self {
            case .pending: nil
            case .clear(let at), .hit(let at), .unavailable(let at), .withdrawn(let at): at
            }
        }
    }

    /// Unique per target attempt (an attempt and a player).
    let id: String
    let player: PlayerID
    /// The beam's centre on the corridor axis (`GameWorldMapping.worldX(corridorX:)`), fixed from
    /// `placedAt` on.
    let beamX: Double
    /// The judged half-width (game units): exactly the drawn core (`VerticalLaser.coreWidth`).
    let halfWidth: Double
    /// When `beamX` became fixed. The obstacle is first drawn then, already where it will cross.
    let placedAt: Double
    let warningTime: Double
    let cueTime: Double
    let crossingTime: Double
    var outcome: Outcome = .pending
}

/// The pure mapping from a `VerticalLaserCue` and game time to what `VerticalLaser` draws. The
/// depth follows the crossing time like a horizontal gate (`GameplayScenePresenter.depth(of:at:)`),
/// so it reaches the players' plane exactly at `crossingTime`.
enum VerticalLaserTrack {
    /// The fade-in where the obstacle is first drawn (seconds from `placedAt`).
    static let appearDuration = 0.25

    struct Frame: Equatable {
        var phase: VerticalLaser.Phase
        var worldX: Float
        var worldZ: Float
        /// 0…1, the fade-in from `placedAt`.
        var appearance: Float
        /// False before `placedAt`, once powered down, and near the camera.
        var isVisible: Bool
    }

    static func frame(_ cue: VerticalLaserCue, at time: Double, mapping: GameWorldMapping,
                      layout: LaserWorldLayout) -> Frame {
        let z = mapping.interactionPlaneZ - layout.travelSpeed * Float(cue.crossingTime - time)
        let x = mapping.worldX(corridorX: cue.beamX)
        let appearance = Float(min(1, max(0, (time - cue.placedAt) / appearDuration)))
        let phase = phase(cue, at: time)
        let visible = time >= cue.placedAt && phase != .off && z < layout.cameraPosition.z - 0.5
        return Frame(phase: phase, worldX: x, worldZ: z, appearance: appearance, isVisible: visible)
    }

    /// Armed until its own verdict, like a horizontal gate: a CLEAR, UNAVAILABLE or withdrawal powers
    /// it down at once; a HIT keeps it armed through the strike (`LaserGate.longestTransition`) first.
    static func phase(_ cue: VerticalLaserCue, at time: Double) -> VerticalLaser.Phase {
        if let at = cue.outcome.time, time >= at {
            let start: Double
            if case .hit = cue.outcome { start = at + LaserGate.longestTransition } else { start = at }
            if time < start { return .active(elapsed: time - cue.cueTime) }
            let elapsed = time - start
            return elapsed < VerticalLaser.powerDownDuration ? .powerDown(elapsed: elapsed) : .off
        }
        if time < cue.warningTime { return .inactive }
        if time < cue.cueTime {
            let span = cue.cueTime - cue.warningTime
            return .warning(progress: span > 0 ? Float((time - cue.warningTime) / span) : 1)
        }
        return .active(elapsed: time - cue.cueTime)
    }
}

/// Draws every current vertical laser and its verdict feedback (the shared impact and badge,
/// `LaserScene.presentOutcome`), from cues read off game state each frame. Keeps no clock and
/// decides nothing. Not yet wired into `GameplayScenePresenter`: it waits for the contract.
@MainActor
final class VerticalLaserLayer {
    private let scene: LaserScene
    private var lasers: [String: VerticalLaser] = [:]
    private var reported: Set<String> = []
    /// Whether this layer shows each verdict's feedback itself (previews). The gameplay presenter
    /// shows it from its own `targetJudged` events instead, as for every gate.
    var reportsOutcomes = true
    /// Forces the Reduce Motion presentation (previews); otherwise the system setting.
    var reduceMotion = false
    /// Sound at the moment a verdict is shown (UNAVAILABLE and withdrawals stay silent).
    var onOutcome: ((PlayerID, LaserFeedback.Outcome) -> Void)?

    init(scene: LaserScene) { self.scene = scene }

    /// The impact's height on the mascot (metres above the floor): about its chest.
    static let impactHeightShare: Float = 0.55

    func update(_ cues: [VerticalLaserCue], at time: Double) {
        let current = Set(cues.map(\.id))
        for id in Array(lasers.keys) where !current.contains(id) {
            lasers[id]?.root.removeFromParent()
            lasers[id] = nil
            reported.remove(id)
        }
        for cue in cues {
            let frame = VerticalLaserTrack.frame(cue, at: time, mapping: scene.mapping, layout: scene.layout)
            let laser = lasers[cue.id] ?? make(cue)
            laser.root.isEnabled = frame.isVisible
            if frame.isVisible {
                laser.setPlacement(x: frame.worldX, worldZ: frame.worldZ, appearance: frame.appearance)
                laser.present(frame.phase, ambientTime: time)
            }
            report(cue, at: time)
        }
    }

    /// The laser drawn for a cue (tests and diagnostics).
    func laser(for id: String) -> VerticalLaser? { lasers[id] }

    private func make(_ cue: VerticalLaserCue) -> VerticalLaser {
        let laser = VerticalLaser(layout: scene.layout, mapping: scene.mapping)
        laser.reduceMotion = reduceMotion || UIAccessibility.isReduceMotionEnabled
        laser.root.name = "verticalLaser.\(cue.id)"
        scene.root.addChild(laser.root)
        lasers[cue.id] = laser
        return laser
    }

    /// One feedback per cue, when its verdict is reached: CLEAR and HIT as for a horizontal gate,
    /// UNAVAILABLE neutral. Never a CLEAR without a CLEAR verdict.
    private func report(_ cue: VerticalLaserCue, at time: Double) {
        guard reportsOutcomes, !reported.contains(cue.id), let at = cue.outcome.time, time >= at else { return }
        reported.insert(cue.id)
        let outcome: LaserFeedback.Outcome? = switch cue.outcome {
        case .clear: .clear
        case .hit: .hit
        case .unavailable: .unavailable
        case .pending, .withdrawn: nil
        }
        guard let outcome else { return }
        let height = RobotAvatarLayer.standingHeight * Self.impactHeightShare / scene.mapping.metersPerGameUnit
        scene.presentOutcome(outcome, for: cue.player, band: height...height)
        onOutcome?(cue.player, outcome)
    }
}
