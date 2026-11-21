//
//  VerticalLaserReplay.swift
//  Sedactive
//

#if DEBUG
import Foundation
import RealityKit
import SwiftUI

/// DEBUG rendering slice for ONE vertical laser, driven by deterministic MOCK game state shaped like
/// the PROPOSED vertical laser contract (16 November 2026): an authoritative board position per
/// player, one LEAN target for Lemon with its beam fixed at the warning, and a scripted verdict.
/// It exercises the rendering adapter (`VerticalLaserLayer`, `RobotAvatarLayer.authoritativeBoardX`)
/// end to end before Edo's lean evidence and Jevon's board state and judge exist. No GameClock,
/// encounter, judge or score: the times are a looping script on RealityKit frame time, and
/// `expectedVerdict` is the fixture's statement of the proposed rule, not the judge.
///
/// Launch with `-replay -verticalLaserReplay [clear|hit|unavailable] [solo] [reduced] [seconds]`:
/// - `clear` (default): Lemon's board moves out of the beam before the crossing → CLEAR.
/// - `hit`: the board stays in the beam → HIT.
/// - `unavailable`: the board moves clear, but the mock evidence is missing at the crossing →
///   UNAVAILABLE, never CLEAR.
/// - `solo` shows Lemon alone; co-op keeps Tangerine on its lane, 1.2 m apart at least.
/// - `seconds` holds one moment of the 9 s loop (screenshots).
@MainActor
final class VerticalLaserReplay {
    enum Mode: String, CaseIterable { case clear, hit, unavailable }

    struct Request {
        var mode: Mode = .clear
        var solo = false
        var reduced = false
        var heldAt: Double?
    }

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-verticalLaserReplay") }

    static var requested: Request {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-verticalLaserReplay") else { return Request() }
        let rest = arguments[(index + 1)...].prefix { !$0.hasPrefix("-") }
        return Request(mode: rest.compactMap(Mode.init(rawValue:)).first ?? .clear, solo: rest.contains("solo"),
                       reduced: rest.contains("reduced"), heldAt: rest.compactMap(Double.init).first)
    }

    // MARK: - The mock round (loop seconds)

    /// The warning (and placement), cue and crossing: the horizontal lasers' 3.0 s and 1.4 s leads.
    static let placedAt = 3.0, warningTime = 3.0, cueTime = 4.6, crossingTime = 6.0
    /// The verdict, as the horizontal judge reports one (evidence window 0.25 s + delivery 0.1 s).
    static let verdictTime = crossingTime + 0.35
    static let loopLength = 9.0
    /// The beam is aimed this far from the board's centre, toward the partner, so the way out is
    /// toward the player's own wall (proposed placement rule).
    static let aimOffset = 0.25
    /// The dodge: starts 0.6 s after the warning, takes 1 s, ends this far out from the lane.
    static let dodgeStart = 3.6, dodgeEnd = 4.6, dodgeTravel = 0.6
    /// The board glides back to its lane for the next loop.
    static let returnStart = 7.5, returnEnd = 8.8
    /// Proposed judged footprint: the board's half-width and the clearance margin (game units).
    static let boardHalfWidth = Double(PlayerHoverboard.halfWidth)
    static let clearanceMargin = 0.05

    let request: Request
    private let mapping: GameWorldMapping
    private let layer: VerticalLaserLayer
    private let robots: RobotAvatarLayer
    private let scene: LaserScene
    private let cueID = "vertical-laser-replay"
    private var subscription: EventSubscription?
    private var total = 0.0
    private var lastLabel = ""

    init(scene: LaserScene, robots: RobotAvatarLayer, request: Request) {
        self.scene = scene
        self.robots = robots
        self.request = request
        mapping = scene.mapping
        layer = VerticalLaserLayer(scene: scene)
        layer.reduceMotion = request.reduced
        robots.smoothing = 0.03
    }

    /// Lemon's mock authoritative board centre (corridor X) at loop time `t`.
    func boardX(at t: Double) -> Double {
        let lane = mapping.laneCorridorX(.player1)
        let out = -1.0 // toward Lemon's own (left) wall
        func ease(_ a: Double, _ b: Double) -> Double {
            let s = min(1, max(0, (t - a) / (b - a))); return s * s * (3 - 2 * s)
        }
        guard request.mode != .hit else { return lane }
        return lane + out * Self.dodgeTravel * (ease(Self.dodgeStart, Self.dodgeEnd) - ease(Self.returnStart, Self.returnEnd))
    }

    /// The beam, fixed where Lemon's board was at the warning.
    var beamX: Double { boardX(at: Self.placedAt) + Self.aimOffset }

    /// The proposed rule on the mock state at the crossing: the board's footprint clear of the beam's
    /// core by the margin is CLEAR, else HIT; missing evidence is UNAVAILABLE, whatever the position.
    func expectedVerdict() -> VerticalLaserCue.Outcome {
        let at = Self.verdictTime
        guard request.mode != .unavailable else { return .unavailable(at: at) }
        let gap = abs(boardX(at: Self.crossingTime) - beamX)
        let need = Self.boardHalfWidth + Double(VerticalLaser.coreWidth / 2) + Self.clearanceMargin
        return gap >= need ? .clear(at: at) : .hit(at: at)
    }

    func cue(at t: Double) -> VerticalLaserCue {
        VerticalLaserCue(id: cueID, player: .player1, beamX: beamX, halfWidth: Double(VerticalLaser.coreWidth / 2),
                         placedAt: Self.placedAt, warningTime: Self.warningTime, cueTime: Self.cueTime,
                         crossingTime: Self.crossingTime, outcome: t >= Self.verdictTime ? expectedVerdict() : .pending)
    }

    func start(on content: RealityViewCameraContent) {
        if let heldAt = request.heldAt {
            // Settle, then show the held moment (the verdict feedback fires if it has been reached).
            for step in 0...Int(min(heldAt, Self.loopLength) * 30) { show(Double(step) / 30, total: Double(step) / 30) }
            return
        }
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            guard let self else { return }
            total += event.deltaTime
            show(total.truncatingRemainder(dividingBy: Self.loopLength), total: total)
        }
    }

    private var loop = -1

    private func show(_ t: Double, total: Double) {
        let index = Int(total / Self.loopLength)
        if index != loop {
            // A fresh loop is a fresh encounter (a new cue identity keeps one feedback per verdict).
            loop = index
            layer.update([], at: t)
        }
        var boards: [PlayerID: Float] = [.player1: mapping.worldX(corridorX: boardX(at: t))]
        if !request.solo { boards[.player2] = mapping.worldX(corridorX: mapping.laneCorridorX(.player2)) }
        robots.authoritativeBoardX = boards
        robots.render(now: total)
        scene.setTravelDistance(scene.layout.travelSpeed * Float(total))
        let cue = cue(at: t)
        layer.update([cue], at: t)
        log(cue, at: t)
    }

    private func log(_ cue: VerticalLaserCue, at t: Double) {
        let phase = VerticalLaserTrack.phase(cue, at: t)
        let name = switch phase {
        case .inactive: "inactive"; case .warning: "warning"; case .active: "active"
        case .powerDown: "powerDown"; case .off: "off"
        }
        let label = "\(name) \(cue.outcome)"
        guard label != lastLabel else { return }
        lastLabel = label
        let drawn = robots.mascotWorldX(.player1) ?? .nan
        let width = robots.steering.map { 2 * $0.halfWidth } ?? .nan
        print(String(format: "[VerticalLaserReplay] %@ t %.2f · %@ · beam x %+.3f · board x %+.3f (drawn %+.3f, board width %.2f)",
                     request.mode.rawValue, t, label, cue.beamX, boardX(at: t), drawn, width))
    }
}
#endif
