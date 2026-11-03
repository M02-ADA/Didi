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

nonisolated enum LaserMove: String, Sendable, Equatable { case duck, jump }

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

    init(playerID: PlayerID, calibrationRevision: UInt64, requiredMove: LaserMove,
         beam: LaserBeamBand, warningTime: Double, crossingTime: Double) throws {
        try requireLaserValue(calibrationRevision > 0, "target calibration revision")
        try requireLaserValue(warningTime.isFinite && crossingTime.isFinite
                              && warningTime >= 0 && warningTime < crossingTime, "target timeline")
        self.playerID = playerID
        self.calibrationRevision = calibrationRevision
        self.requiredMove = requiredMove
        self.beam = beam
        self.warningTime = warningTime
        self.crossingTime = crossingTime
    }
}

nonisolated struct LaserEncounter: Equatable, Sendable {
    let id: UUID
    let attemptID: UUID
    /// Stable producer slot order; renderer and replay never depend on Dictionary iteration.
    let targets: [LaserTarget]

    init(id: UUID, attemptID: UUID, targets: [LaserTarget]) throws {
        try requireLaserValue(targets.count == 2 && Set(targets.map(\.playerID)) == Set(PlayerID.allCases),
                              "encounter requires both players exactly once")
        try requireLaserValue(Set(targets.map(\.requiredMove)).count == 1, "horizontal lasers require the same move")
        self.id = id
        self.attemptID = attemptID
        self.targets = PlayerID.allCases.compactMap { id in targets.first { $0.playerID == id } }
    }
}

nonisolated enum LaserEvidenceRequirement: String, Equatable, Sendable {
    case crown, leftWrist, rightWrist, leftSole, rightSole, jumpPhase
}

nonisolated enum LaserUnavailableReason: Equatable, Sendable {
    case noSample, stale, late, incompatibleContext, historyOverflow
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
