//
//  LaserModels.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation

nonisolated enum LaserDataError: Error, Equatable, Sendable {
    case invalidValue(String)
}

nonisolated func requireLaserValue(_ condition: Bool, _ field: String) throws {
    guard condition else { throw LaserDataError.invalidValue(field) }
}

/// DUCK (high horizontal beam), JUMP (low horizontal beam), LEAN (vertical beam: move the board
/// sideways out of it, `LaserLeanBeam`).
nonisolated enum LaserMove: String, Sendable, Equatable, CaseIterable { case duck, jump, lean }

/// Which way a LEAN beam's way out goes, chosen in the level script and resolved against the
/// boards' actual positions when the beam is placed (`LaserLeanPlacement`).
nonisolated enum LaserLeanIntent: Equatable, Sendable {
    /// Toward the player's own wall (away from the partner).
    case outward
    /// Toward the partner (the corridor's centre).
    case inward
    /// Whichever side has more room.
    case moreRoom
    /// Both players move the same way (displayed direction, -1 left / +1 right). The player on that
    /// side leads; the follower's way out is the room its partner leaves.
    case shift(Int)
}

/// A LEAN target's vertical beam on the corridor axis (`LateralSteering` units: corridor metres,
/// + toward displayed right). `centerX` is fixed once, when the encounter is registered, from the
/// authoritative boards (`LaserGame.register`), and never moves afterwards.
nonisolated struct LaserLeanBeam: Equatable, Sendable {
    let intent: LaserLeanIntent
    /// The beam's centre; nil until placed.
    let centerX: Double?
    /// The direction (-1 / +1) the board must move to get out; nil until placed or when voided.
    let escape: Int?
    /// The judged half-width: exactly the drawn core (`VerticalLaser.coreWidth` / 2).
    let halfWidth: Double
    /// No safe way out could be guaranteed from where the boards were (a board boxed between a
    /// wall and its partner): the target is judged UNAVAILABLE (`noSafePlacement`), never CLEAR or HIT.
    let voided: Bool

    init(intent: LaserLeanIntent, centerX: Double? = nil, escape: Int? = nil,
         halfWidth: Double = LaserBoardGeometry.beamHalfWidth, voided: Bool = false) throws {
        try requireLaserValue(halfWidth.isFinite && halfWidth > 0 && (centerX?.isFinite ?? true)
                              && (escape.map { $0 == -1 || $0 == 1 } ?? true), "lean beam")
        if case .shift(let side) = intent { try requireLaserValue(side == -1 || side == 1, "shift side") }
        self.intent = intent; self.centerX = centerX; self.escape = escape
        self.halfWidth = halfWidth; self.voided = voided
    }

    var isPlaced: Bool { centerX != nil || voided }
    /// The same intent, not yet placed (a recovered or rebased attempt is placed afresh).
    var unplaced: Self { (try? Self(intent: intent, halfWidth: halfWidth)) ?? self }
}

/// Same unmirrored player-plane Double units as BodyGeometry, not image pixels or meters.
nonisolated struct LaserBeamBand: Equatable, Sendable {
    let lowerY: Double
    let upperY: Double

    init(lowerY: Double, upperY: Double) throws {
        try requireLaserValue(lowerY.isFinite && upperY.isFinite && lowerY >= 0 && lowerY < upperY, "beam band")
        self.lowerY = lowerY
        self.upperY = upperY
    }
}

nonisolated struct LaserTarget: Equatable, Sendable {
    let playerID: PlayerID
    let calibrationRevision: UInt64
    let requiredMove: LaserMove
    let beam: LaserBeamBand
    /// All gameplay times are seconds on GameClock, never capture or delivery time.
    let warningTime: Double
    let crossingTime: Double
    /// The vertical beam of a LEAN target (nil for DUCK and JUMP). Its `beam` band then spans the
    /// whole body and is not judged.
    let lean: LaserLeanBeam?

    init(playerID: PlayerID, calibrationRevision: UInt64, requiredMove: LaserMove,
         beam: LaserBeamBand, warningTime: Double, crossingTime: Double, lean: LaserLeanBeam? = nil) throws {
        try requireLaserValue(calibrationRevision > 0, "target calibration revision")
        try requireLaserValue(warningTime.isFinite && crossingTime.isFinite
                              && warningTime >= 0 && warningTime < crossingTime, "target timeline")
        try requireLaserValue((requiredMove == .lean) == (lean != nil), "a LEAN target, and only one, has a vertical beam")
        self.playerID = playerID
        self.calibrationRevision = calibrationRevision
        self.requiredMove = requiredMove
        self.beam = beam
        self.warningTime = warningTime
        self.crossingTime = crossingTime
        self.lean = lean
    }

    /// The same target `delta` seconds later; a LEAN beam is unplaced (placed afresh when registered).
    func shifted(by delta: Double) throws -> Self {
        try Self(playerID: playerID, calibrationRevision: calibrationRevision, requiredMove: requiredMove, beam: beam,
                 warningTime: warningTime + delta, crossingTime: crossingTime + delta, lean: lean?.unplaced)
    }

    /// This target with its LEAN beam placed.
    func placing(_ beam: LaserLeanBeam) throws -> Self {
        try Self(playerID: playerID, calibrationRevision: calibrationRevision, requiredMove: requiredMove,
                 beam: self.beam, warningTime: warningTime, crossingTime: crossingTime, lean: beam)
    }
}

nonisolated struct LaserEncounter: Equatable, Sendable {
    let id: UUID
    let attemptID: UUID
    /// Stable producer slot order; renderer and replay never depend on Dictionary iteration.
    let targets: [LaserTarget]

    /// - Parameter roster: the players this encounter judges: both (always, in Release), or P1
    ///   alone in a DEBUG Solo Test practice round; or ONE player for a vertical LEAN layer (a beam
    ///   near that player, `LaserWaveBeat.layerGap`). Never a fabricated teammate target.
    init(id: UUID, attemptID: UUID, targets: [LaserTarget], roster: Set<PlayerID> = Set(PlayerID.allCases)) throws {
        let leanLayer = !targets.isEmpty && targets.allSatisfy { $0.requiredMove == .lean } && roster.count == 1
        #if DEBUG
        try requireLaserValue(roster == Set(PlayerID.allCases) || roster == [.player1] || leanLayer, "co-op or solo P1 encounter")
        #else
        try requireLaserValue(roster == Set(PlayerID.allCases) || leanLayer, "encounter requires both players")
        #endif
        try requireLaserValue(targets.count == roster.count && Set(targets.map(\.playerID)) == roster,
                              "encounter requires both players exactly once")
        // ONE MOVE PER ENCOUNTER (corrected 16 November 2026): a horizontal laser is one continuous
        // beam across the corridor, so every player DUCKs, or every player JUMPs; never DUCK for one
        // and JUMP for the other. Vertical beams (LEAN) are their own encounter; a combined encounter
        // is a LEAN layer followed by a full-width DUCK (`LaserWaveBeat.layerGap`). A shift is both LEAN.
        try requireLaserValue(Set(targets.map(\.requiredMove)).count == 1, "one move per encounter")
        let shifts = targets.compactMap { target -> Int? in
            if case .shift(let side) = target.lean?.intent { side } else { nil }
        }
        try requireLaserValue(shifts.isEmpty || (shifts.count == targets.count && Set(shifts).count == 1),
                              "a shift moves every player the same way")
        self.id = id
        self.attemptID = attemptID
        self.targets = PlayerID.allCases.compactMap { id in targets.first { $0.playerID == id } }
    }
}

nonisolated enum LaserEvidenceRequirement: String, Equatable, Sendable {
    case crown, leftWrist, rightWrist, leftSole, rightSole, jumpPhase, trunkLean
}

nonisolated enum LaserUnavailableReason: Equatable, Sendable {
    case noSample, stale, late, incompatibleContext, historyOverflow
    /// A LEAN beam with no guaranteed way out from where the boards stood: neither the player's nor
    /// tracking's fault. No score, no damage, and not a tracking failure (no pause budget).
    case noSafePlacement
    case invalidEvidence(LaserEvidenceRequirement, EvidenceValidity)
}

nonisolated enum LaserHitReason: Equatable, Sendable { case insufficientClearance, notAirborne }
nonisolated enum LaserPendingReason: Equatable, Sendable { case awaitingFinalization }

nonisolated enum Judgement: Equatable, Sendable {
    case pending(LaserPendingReason)
    case clear
    case hit(LaserHitReason)
    case unavailable(LaserUnavailableReason)
}
