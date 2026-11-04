//
//  RoundSummary.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation

nonisolated enum LaserRoundOutcome: String, Equatable, Sendable {
    case completed, healthDepleted, vaultFailed, aborted, technicalInterruption
}

nonisolated struct LaserPlayerTargetCounts: Equatable, Sendable {
    let playerID: PlayerID
    let scheduled: Int
    let cleared: Int
    let hit: Int
    let unavailable: Int
}

nonisolated struct RoundSummary: Equatable, Sendable {
    let sessionGeneration: UUID
    let outcome: LaserRoundOutcome
    let gameDuration: Double
    let activityDuration: Double
    let remainingTeamHealth: Int
    let teamScore: Int
    let targets: [LaserPlayerTargetCounts]
    let diamondsCollected: Int
    let vaultsOpened: Int
    let withdrawnAttempts: Int
    let playerResults: [LaserPlayerRoundResult]
    let coopResults: [LaserCoopRoundResult]
    let missionProgress: Int
    let missionTarget: Int
    /// Explicit selection, never inferred from height, lane or anonymous slot identity.
    let primaryPlayerID: PlayerID?

    static let durationLimitation = "Active game time excludes pauses. It is not time spent moving."
    static let activityLimitation = "Activity progression excludes vault time and pauses; it is a game timer."
}

nonisolated struct LaserPlayerRoundResult: Equatable, Sendable {
    let playerID: PlayerID
    let successfulHighAvoidances: Int
    let successfulLowAvoidances: Int
    /// Nil: CP1 has jump phase but no completed-cycle events. Never infer cycles from CLEARs.
    let validatedJumpCycles: Int?
    /// Union of requested action windows intersected with supplied tracked coverage, pauses excluded.
    /// Nil means tracking coverage or action-cue timing was not supplied, not zero movement.
    let movementChallengeSeconds: Double?

    static let avoidanceLimitation = "Successful laser avoidances are game results, not movement repetitions."
    static let jumpCycleLimitation = "Unavailable until the body-input contract supplies validated complete jump-cycle events."
    static let challengeTimeLimitation = "Requested action-window time while tracked; not measured physical activity time."
}

nonisolated enum LaserCoopRoundOutcome: String, Equatable, Sendable { case opened, timedOut, interrupted }

nonisolated struct LaserCoopRoundResult: Equatable, Sendable {
    let gateID: UUID
    let outcome: LaserCoopRoundOutcome
    let gameTime: Double
}
