//
//  LaserBoards.swift
//  Sedactive
//

import Foundation

/// The corridor the hoverboards ride, in corridor metres (`LateralSteering` units: + toward displayed
/// right, P1 left), and the LEAN rules' fixed numbers. Each value is the one the scene draws; a
/// rendering test (`LaserBoardGeometryConsistencyTests`) checks they agree, so the judged board is
/// the drawn board.
nonisolated enum LaserBoardGeometry {
    /// Lane centres where the boards start (`GameWorldMapping.laneCenterX`).
    static let laneX: [PlayerID: Double] = [.player1: -0.7, .player2: 0.7]
    /// Half the drawn board's width (its model's bounds, `RobotAvatarLayer.makeSteering`).
    static let boardHalfWidth = 0.584
    /// Gap kept between the two boards' edges (`LateralSteering.partnerGap`).
    static let partnerGap = Double(LateralSteering.partnerGap)
    static var minimumSeparation: Double { 2 * boardHalfWidth + partnerGap }
    /// Where a board's centre may go: between the two wall consoles' docks, the steering bounds the
    /// scene uses (the camera's view of the corridor at the players' plane, narrowed to the docks).
    static let bounds: ClosedRange<Double> = -1.746...1.746
    /// The consoles' docks, where the vault's dock assist takes a board (`LaserGateConsole.dockX`).
    static let docks: [PlayerID: Double] = [.player1: -1.746, .player2: 1.746]
    /// A vertical beam's judged half-width: exactly its drawn core (`VerticalLaser.coreWidth` / 2).
    static let beamHalfWidth = 0.025

    // MARK: Steering from the lean (the mascots' tuning, owner 12 November 2026, `RobotRetargeter`)

    /// A lean below this share of standing height is posture, not steering.
    static let steerDeadbandShare = 0.02
    /// Board speed (m/s) per share of lean beyond the deadband, up to `LateralSteering.maximumSpeed`.
    static let steerSpeedPerShare = 20.0
    /// The lean's filter time constant (s).
    static let steerFilterTime = 0.03
    /// The hip shift's soft zone (share of standing height) and its largest board offset (m).
    static let swayDeadbandShare = 0.015
    static let maximumSway = 0.4
    /// The mascot's height (m): a hip shift is drawn at the mascot's scale (`RobotRetargeter.motionScale`).
    static let mascotHeight = 1.6
    /// The hip shift's smoothing time constant (s), as the avatars render it (`LiveAvatarPresenter.renderSmoothing`).
    static let swaySmoothing = 0.03
    /// Without a new usable lean for this long (s), the board brakes and holds (`RobotRetargeter.lossHold`).
    static let leanHold = 0.15
    /// Fixed integration step (s), so a board's path does not depend on how often game time is advanced.
    static let substep = 1.0 / 120
    /// The vault's dock assist (`RobotAvatarLayer.dockCapture`, `dockAssistSpeed`), from this long
    /// before a gate (`VaultPresentation.dockLead`) and through it.
    static let dockCapture = 0.5
    static let dockAssistSpeed = 1.0
    static let dockLead = 4.0

    // MARK: LEAN placement and judgement

    /// The board travel a LEAN beam asks for (m): the beam is aimed off-centre on the board, on the
    /// side away from the way out, so this much travel that way clears it (more than twice as much
    /// the other way).
    static let standardDodge = 0.44
    /// The least travel a beam may ask for when the way out is short of room (m).
    static let minimumDodge = 0.25
    /// LEAN beams are placed and first shown this long before their crossing (s): one second before
    /// their warning, after the previous encounter (at least 4.5 s earlier) has been judged.
    static let revealLead = 4.0
    /// Longest gap in valid LEAN evidence between the action cue and the crossing (s): the jump
    /// estimator's own limit (`LiveJumpEstimator.maximumGap`). A longer gap is UNAVAILABLE.
    static let evidenceGap = 0.2
}

/// One board as game state shows it.
nonisolated struct LaserBoardReading: Equatable, Sendable {
    /// Board centre (corridor metres), velocity (m/s) and the game time of this reading.
    let x: Double
    let velocity: Double
    let time: Double
}

/// The hoverboards as game state (vertical lasers, 16 November 2026): each player's LEAN evidence
/// steers their board through `LateralSteering` (walls, partner, no recentring), stepped in fixed
/// substeps on game time, so a replay reproduces every position. The LEAN judge reads it; the
/// renderer draws it. Untracked, a board brakes and holds; it never drifts on old evidence.
nonisolated struct LaserBoardField: Equatable, Sendable {
    struct Reference: Equatable, Sendable {
        /// The player's lane centre in the unmirrored player plane, and standing height (game units).
        let planeLaneX: Double
        let standingHeight: Double
    }
    private struct Input: Equatable, Sendable {
        var filteredLean: Double?
        var targetSpeed = 0.0
        var swayTarget = 0.0
        var sway = 0.0
        var lastLean: Double?
    }

    private(set) var steering: LateralSteering
    let references: [PlayerID: Reference]
    private var inputs: [PlayerID: Input] = [:]
    private(set) var time: Double
    /// Valid LEAN evidence capture times (game time), recent ones only.
    private var leanCaptures: [PlayerID: [Double]] = [:]
    /// Dock assist: on while a gate approaches or is open.
    var dockAssist = false

    init(references: [PlayerID: Reference], at time: Double = 0) throws {
        try requireLaserValue(!references.isEmpty && references.values.allSatisfy {
            $0.planeLaneX.isFinite && $0.standingHeight.isFinite && $0.standingHeight > 0
        }, "board references")
        let lanes = Dictionary(uniqueKeysWithValues: references.keys.map { ($0, Float(LaserBoardGeometry.laneX[$0]!)) })
        steering = LateralSteering(lanes: lanes,
            bounds: Float(LaserBoardGeometry.bounds.lowerBound)...Float(LaserBoardGeometry.bounds.upperBound),
            halfWidth: Float(LaserBoardGeometry.boardHalfWidth))
        self.references = references
        self.time = time
        for player in references.keys { inputs[player] = Input() }
    }

    /// From the round's accepted calibrations: each player's lane and standing height.
    static func make(calibrations: [PlayerID: PlayerCalibration], layout: PlayerPlaneLayout) throws -> Self {
        try Self(references: Dictionary(uniqueKeysWithValues: calibrations.map { player, calibration in
            (player, Reference(planeLaneX: layout.centerX(for: player),
                               standingHeight: calibration.mapping.gameY(imageY: calibration.standingCrownImageY, layout: layout)))
        }))
    }

    var players: [PlayerID] { PlayerID.allCases.filter { references[$0] != nil } }

    func x(_ player: PlayerID) -> Double? { steering.boardX(player).map(Double.init) }

    func reading(_ player: PlayerID) -> LaserBoardReading? {
        guard let x = x(player), let rider = steering.riders[player] else { return nil }
        return LaserBoardReading(x: x, velocity: Double(rider.velocity), time: time)
    }

    var readings: [PlayerID: LaserBoardReading] {
        Dictionary(uniqueKeysWithValues: players.compactMap { player in reading(player).map { (player, $0) } })
    }

    /// One player's sample arriving at game time `arrivedAt` (captured at `capturedAt`): its lean sets
    /// the board's steering speed (the mascots' rule, mirrored as displayed), its hip centre the board's
    /// hip shift. Only a reliably tracked sample of the board's own calibration steers.
    mutating func receive(_ sample: PlayerBodySample?, player: PlayerID, calibrationRevision: UInt64?,
                          capturedAt: Double, arrivedAt: Double) {
        guard let reference = references[player], var input = inputs[player] else { return }
        advance(to: max(time, arrivedAt))
        let h = reference.standingHeight
        if let sample, sample.trackingStatus == .reliable, sample.calibrationRevision == calibrationRevision,
           let lean = sample.geometry.trunkLeanX, lean.validity == .valid, let value = lean.value {
            // Displayed direction: each lane is drawn mirrored about its centre, so image +X is screen left.
            let share = -value / h
            let dt = input.lastLean.map { max(0, arrivedAt - $0) } ?? 0
            let k = input.filteredLean == nil ? 1 : 1 - exp(-dt / LaserBoardGeometry.steerFilterTime)
            let filtered = (input.filteredLean ?? share) + (share - (input.filteredLean ?? share)) * k
            input.filteredLean = filtered
            input.lastLean = arrivedAt
            let beyond = abs(filtered) - LaserBoardGeometry.steerDeadbandShare
            input.targetSpeed = beyond > 0
                ? min(Double(LateralSteering.maximumSpeed), beyond * LaserBoardGeometry.steerSpeedPerShare) * (filtered < 0 ? -1 : 1)
                : 0
            var captures = leanCaptures[player] ?? []
            if captures.last.map({ capturedAt > $0 }) ?? true { captures.append(capturedAt) }
            captures.removeAll { $0 < capturedAt - 8 }
            leanCaptures[player] = captures
        } else {
            // No usable lean in this sample: brake and hold, never steer on an older lean.
            input.filteredLean = nil
            input.targetSpeed = 0
            input.lastLean = nil
        }
        if let sample, sample.trackingStatus == .reliable, sample.calibrationRevision == calibrationRevision,
           sample.geometry.centerX.validity == .valid, let center = sample.geometry.centerX.value {
            let offset = reference.planeLaneX - center // mirrored about the lane, as displayed
            let zone = LaserBoardGeometry.swayDeadbandShare * h
            let scale = LaserBoardGeometry.mascotHeight / h
            let soft = Self.softZone(abs(offset), zone) * (offset < 0 ? -1 : 1) * scale
            input.swayTarget = min(LaserBoardGeometry.maximumSway, max(-LaserBoardGeometry.maximumSway, soft))
        }
        inputs[player] = input
    }

    /// The mascots' soft dead zone (`RobotRetargeter.softZone`): 0 at rest, smooth up to `zone`, then x.
    static func softZone(_ x: Double, _ zone: Double) -> Double {
        guard zone > 0, x < zone else { return x }
        guard x > 0 else { return 0 }
        return 2 * x * x / zone - x * x * x / (zone * zone)
    }

    /// Steps every board to game time `target` in fixed substeps (a no-op backwards).
    mutating func advance(to target: Double) {
        guard target > time else { return }
        while time < target - 1e-9 {
            let dt = min(LaserBoardGeometry.substep, target - time)
            step(dt)
            time += dt
        }
        time = target
    }

    /// Brakes and holds every board (a pause, a context change): no speed carries across the gap.
    mutating func halt() {
        for player in players {
            inputs[player]?.targetSpeed = 0
            inputs[player]?.filteredLean = nil
            inputs[player]?.lastLean = nil
            if let x = steering.boardX(player) { steering.place(player, boardX: x) }
        }
    }

    /// Whether this player's valid LEAN evidence covers `range` with no gap longer than `evidenceGap`.
    func leanEvidenceCovers(_ player: PlayerID, _ range: ClosedRange<Double>) -> Bool {
        let gap = LaserBoardGeometry.evidenceGap
        let captures = (leanCaptures[player] ?? []).filter { $0 >= range.lowerBound - gap && $0 <= range.upperBound }
        guard let first = captures.first, let last = captures.last,
              first <= range.lowerBound + gap, last >= range.upperBound - gap else { return false }
        return zip(captures, captures.dropFirst()).allSatisfy { $1 - $0 <= gap + 1e-9 }
    }

    private mutating func step(_ dt: Double) {
        var stepInputs: [PlayerID: LateralSteering.Input] = [:]
        let k = 1 - exp(-dt / LaserBoardGeometry.swaySmoothing)
        for player in players {
            guard var input = inputs[player] else { continue }
            // Held lean evidence steers only while fresh; then the board brakes and holds.
            if let last = input.lastLean, time - last > LaserBoardGeometry.leanHold {
                input.targetSpeed = 0; input.filteredLean = nil; input.lastLean = nil
            }
            input.sway += (input.swayTarget - input.sway) * k
            var speed = input.targetSpeed
            if dockAssist, let dock = LaserBoardGeometry.docks[player], let x = x(player) {
                let gap = dock - x, toward: Double = dock < 0 ? -1 : 1
                if abs(gap) < LaserBoardGeometry.dockCapture, abs(gap) > 0.001, speed * toward >= -0.05 {
                    let assist = min(LaserBoardGeometry.dockAssistSpeed, abs(gap) * 6)
                    speed = (gap > 0 ? 1 : -1) * max(assist, speed * (gap > 0 ? 1 : -1))
                }
            }
            inputs[player] = input
            stepInputs[player] = .init(targetSpeed: Float(speed), sway: Float(input.sway))
        }
        steering.step(dt: Float(dt), inputs: stepInputs)
    }
}

/// Where a LEAN beam goes, decided once from the authoritative boards when its encounter is
/// registered. Fair by construction:
/// - the beam is always on the board (standing still is never a CLEAR);
/// - the way out is toward room the player can reach without their partner moving, except in a
///   shift, where the follower's room is exactly what the leader must vacate anyway;
/// - with too little room one way it asks for less travel (down to `minimumDodge`) or turns the
///   way out around; with no reachable room at all the target is voided (UNAVAILABLE, never
///   CLEAR or HIT).
nonisolated enum LaserLeanPlacement {
    struct Outcome: Equatable, Sendable {
        var beams: [PlayerID: LaserLeanBeam]
        /// Plain-language notes on any adjustment (flipped, shorter, swapped shift, voided).
        var notes: [String]
    }

    /// The clearance a board needs from the beam's centre to be CLEAR: board half-width, beam
    /// half-width and the judge's margin.
    static func clearance(halfWidth: Double, margin: Double) -> Double {
        LaserBoardGeometry.boardHalfWidth + halfWidth + margin
    }

    static func place(_ targets: [LaserTarget], boards: [PlayerID: Double], margin: Double) throws -> Outcome {
        let leans = targets.filter { $0.requiredMove == .lean }
        var out = Outcome(beams: [:], notes: [])
        guard !leans.isEmpty else { return out }
        let solo = boards.count == 1
        func room(_ player: PlayerID, _ e: Int, partnerMoves: Double = 0) -> Double {
            guard let x = boards[player] else { return 0 }
            let b = LaserBoardGeometry.bounds
            var r = e > 0 ? b.upperBound - x : x - b.lowerBound
            let partner: PlayerID = player == .player1 ? .player2 : .player1
            if let px = boards[partner] {
                let towardPartner = (partner == .player2) == (e > 0)
                if towardPartner { r = min(r, abs(px - x) - LaserBoardGeometry.minimumSeparation + partnerMoves) }
            }
            return max(0, r)
        }
        func outward(_ player: PlayerID) -> Int { player == .player1 ? -1 : 1 }
        var directions: [PlayerID: Int] = [:]
        var partnerAllowance: [PlayerID: Double] = [:]
        // Shift: the leader is the player on the shift's side; fall back to the other side, then to outward.
        if case .shift(let preferred)? = leans.first?.lean?.intent, !solo, leans.count == 2 {
            var placed = false
            for side in [preferred, -preferred] {
                let leader: PlayerID = side > 0 ? .player2 : .player1
                let follower: PlayerID = leader == .player1 ? .player2 : .player1
                if room(leader, side) >= LaserBoardGeometry.standardDodge {
                    directions[leader] = side; directions[follower] = side
                    partnerAllowance[follower] = LaserBoardGeometry.standardDodge
                    if side != preferred { out.notes.append("shift turned around (no room on the planned side)") }
                    placed = true
                    break
                }
            }
            if !placed {
                for target in leans { directions[target.playerID] = outward(target.playerID) }
                out.notes.append("shift became an outward pair (no room for a leader)")
            }
        } else {
            for target in leans {
                let p = target.playerID
                switch target.lean!.intent {
                case .outward: directions[p] = outward(p)
                case .inward: directions[p] = -outward(p)
                case .moreRoom, .shift: directions[p] = room(p, 1) >= room(p, -1) ? 1 : -1
                }
            }
            // Both inward together share the gap between them.
            if leans.count == 2, directions[.player1] == 1, directions[.player2] == -1,
               let a = boards[.player1], let b = boards[.player2],
               (b - a) - LaserBoardGeometry.minimumSeparation < 2 * LaserBoardGeometry.standardDodge {
                directions = [.player1: -1, .player2: 1]
                out.notes.append("inward pair became outward (not enough room between the boards)")
            }
            // Both the same way is a shift in effect: the trailing board's room includes what the
            // leading board must vacate anyway (as a planned shift's follower).
            if leans.count == 2, let d = directions[.player1], directions[.player2] == d, !solo {
                let follower: PlayerID = d > 0 ? .player1 : .player2
                partnerAllowance[follower] = LaserBoardGeometry.standardDodge
            }
        }
        for target in leans {
            let p = target.playerID, lean = target.lean!
            guard let x = boards[p], var e = directions[p] else {
                out.beams[p] = try LaserLeanBeam(intent: lean.intent, halfWidth: lean.halfWidth, voided: true)
                out.notes.append("\(p.rawValue) voided (no board)")
                continue
            }
            var need = LaserBoardGeometry.standardDodge
            let available = room(p, e, partnerMoves: partnerAllowance[p] ?? 0)
            if available < need {
                let other = room(p, -e)
                if available - 0.02 >= LaserBoardGeometry.minimumDodge {
                    need = available - 0.02
                    out.notes.append("\(p.rawValue) shorter dodge \(String(format: "%.2f", need)) m")
                } else if other >= LaserBoardGeometry.standardDodge {
                    e = -e
                    out.notes.append("\(p.rawValue) way out turned around")
                } else if other - 0.02 >= LaserBoardGeometry.minimumDodge {
                    e = -e; need = other - 0.02
                    out.notes.append("\(p.rawValue) way out turned around, shorter dodge \(String(format: "%.2f", need)) m")
                } else {
                    out.beams[p] = try LaserLeanBeam(intent: lean.intent, centerX: x, halfWidth: lean.halfWidth, voided: true)
                    out.notes.append("\(p.rawValue) voided (boxed in: no way out)")
                    continue
                }
            }
            // On the board, off-centre away from the way out: `need` that way clears it.
            let offset = clearance(halfWidth: lean.halfWidth, margin: margin) - need
            out.beams[p] = try LaserLeanBeam(intent: lean.intent, centerX: x - Double(e) * offset, escape: e,
                                             halfWidth: lean.halfWidth)
        }
        return out
    }

    /// CLEAR when the board's centre is at least the clearance from the beam's centre.
    static func isClear(boardX: Double, beam: LaserLeanBeam, margin: Double) -> Bool? {
        guard let center = beam.centerX, !beam.voided else { return nil }
        return abs(boardX - center) >= clearance(halfWidth: beam.halfWidth, margin: margin) - 1e-9
    }
}
