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
}
