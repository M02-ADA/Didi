//
//  LaserApproachPreview.swift
//  Sedactive
//

#if DEBUG
import Foundation
import RealityKit
import SwiftUI

/// Developer-only laser encounters for checking perspective, gate states and
/// player feedback (LH-11, LH-04, LH-05).
///
/// Loops scripted sample encounters on RealityKit frame time. This is not game
/// time and decides nothing: the timings are labelled candidates and the moves
/// and verdicts are scripted. Jevon's `GameClock`, encounters and verdicts
/// replace this once the frame-update contract is agreed (TEAM_ALIGNMENT §C);
/// the `LaserScene` calls below stay the same.
///
/// Launch arguments:
/// - `-laserGateState <inactive|warning|active|hit|disabled>` holds one gate state.
/// - `-laserPreviewDepth <z>` holds the laser at one world depth.
/// - `-laserPreviewScenario <0-3>` repeats one sample encounter.
/// - `-laserPreviewTime <seconds>` freezes the encounter at a time relative to the crossing.
/// - `-laserPreviewSpeed <factor>` slows or speeds the loop, e.g. `0.25`.
///
/// The corridor streams past at the sample approach speed, so a laser stays
/// fixed relative to the walls until it reaches the players. It holds still
/// while a depth or time is pinned.
@MainActor
final class LaserApproachPreview {
    /// Sample timings in seconds relative to the crossing. The warning and cue
    /// leads are the rules draft's candidates (at least 3 s, and 1.4 s), and the
    /// verdict delay matches Jevon's LH-07 fixture values (0.25 s window plus
    /// 0.10 s allowance). None of them is an approved constant.
    struct SampleTimings {
        var spawn: Double = -4.2
        var warning: Double = -3.0
        var cue: Double = -1.4
        var verdict: Double = 0.35
        /// End of the hit flash; without a HIT the gate powers down at the verdict.
        var powerDown: Double = 0.65
        var end: Double = 2.0
    }

    /// One scripted encounter: the move both players make, one band in game
    /// units, and each player's verdict.
    struct SampleEncounter {
        let move: LaserFeedback.Move
        let band: ClosedRange<Float>
        let outcomes: [PlayerID: LaserFeedback.Outcome]
    }

    static let encounters = [
        SampleEncounter(move: .duck, band: 1.239...1.261, outcomes: [.player1: .clear, .player2: .clear]),
        SampleEncounter(move: .jump, band: 0.249...0.271, outcomes: [.player1: .hit, .player2: .clear]),
        SampleEncounter(move: .duck, band: 1.239...1.261, outcomes: [.player1: .clear, .player2: .unavailable]),
        SampleEncounter(move: .jump, band: 0.249...0.271, outcomes: [.player1: .hit, .player2: .hit]),
    ]

    var timings = SampleTimings()
    /// Where the laser comes to rest after passing the players, close enough
    /// that it stays clear of the outcome badges.
    var endZ: Float = 0.6
    private var elapsed: Double = 0
    private var encounterIndex: Int?
    private var lastTime: Double = .infinity
    private var verdictShown = false
    private var subscription: EventSubscription?
    private let pinnedState = LaserApproachPreview.argument("-laserGateState").flatMap(LaserGate.VisualState.init(rawValue:))
    private let pinnedDepth = LaserApproachPreview.argument("-laserPreviewDepth").flatMap(Float.init)
    private let pinnedEncounter = LaserApproachPreview.argument("-laserPreviewScenario").flatMap(Int.init)
    private let frozenTime = LaserApproachPreview.argument("-laserPreviewTime").flatMap(Double.init)
    private let speed = LaserApproachPreview.argument("-laserPreviewSpeed").flatMap(Double.init) ?? 1

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
        let length = timings.end - timings.spawn
        elapsed += deltaTime * speed
        let count = Self.encounters.count
        let index = ((pinnedEncounter ?? Int(elapsed / length)) % count + count) % count
        let time = frozenTime ?? timings.spawn + elapsed.truncatingRemainder(dividingBy: length)
        if index != encounterIndex || time < lastTime {
            begin(index, scene: scene)
        }
        lastTime = time
        let encounter = Self.encounters[index]
        if pinnedDepth == nil, frozenTime == nil {
            let approachSpeed = (scene.mapping.interactionPlaneZ - scene.layout.laserSpawnZ) / Float(-timings.spawn)
            scene.advanceTravel(by: approachSpeed * Float(deltaTime * speed))
        }

        scene.setLaserDepth(pinnedDepth ?? depth(at: time, scene: scene))
        scene.setLaserVisualState(pinnedState ?? state(at: time, hasHit: encounter.outcomes.values.contains(.hit)))
        scene.setLaserWarningProgress(Float((time - timings.warning) / (timings.cue - timings.warning)))
        // Preview of the move from the warning, action cue with countdown from the cue time.
        let cueShown = time >= timings.warning && time < 0
        scene.setMoveCue(cueShown ? encounter.move : nil, actionRemaining: time >= timings.cue ? Float(time / timings.cue) : nil)
        if time >= timings.verdict, !verdictShown {
            verdictShown = true
            for (player, outcome) in encounter.outcomes {
                scene.presentOutcome(outcome, for: player)
            }
        }
    }

    private func begin(_ index: Int, scene: LaserScene) {
        encounterIndex = index
        verdictShown = false
        let band = Self.encounters[index].band
        scene.setLaserBand(lowerEdge: band.lowerBound, upperEdge: band.upperBound)
        scene.clearLaserFeedback()
    }

    /// Constant speed so the beam reaches the interaction plane exactly at the
    /// crossing, then a cosmetic ease-out to rest just past the players.
    private func depth(at time: Double, scene: LaserScene) -> Float {
        let spawnZ = scene.layout.laserSpawnZ
        let planeZ = scene.mapping.interactionPlaneZ
        let approachSpeed = (planeZ - spawnZ) / Float(-timings.spawn)
        guard time >= 0 else { return planeZ + approachSpeed * Float(time) }
        // Starts at the approach speed and decelerates evenly to a stop at `endZ`.
        let stopDuration = 2 * (endZ - planeZ) / approachSpeed
        let progress = min(Float(time) / stopDuration, 1)
        return planeZ + (endZ - planeZ) * (1 - (1 - progress) * (1 - progress))
    }

    /// Sample order: dim at spawn, warning, active from the action cue, then
    /// power down at the verdict, after a short hit flash when anyone is hit.
    private func state(at time: Double, hasHit: Bool) -> LaserGate.VisualState {
        switch time {
        case ..<timings.warning: .inactive
        case ..<timings.cue: .warning
        case ..<timings.verdict: .active
        case ..<timings.powerDown where hasHit: .hit
        default: .disabled
        }
    }
}
#endif
