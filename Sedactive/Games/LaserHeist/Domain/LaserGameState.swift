//
//  LaserGameState.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//Team consequences

import Foundation

nonisolated enum LaserRoundPhase: Equatable, Sendable {
    case activity, vault, diamondTime
    case ended(LaserRoundOutcome)
}

nonisolated struct LaserEncounterState: Equatable, Sendable {
    let encounter: LaserEncounter
    let judgements: [PlayerID: Judgement]
    let effectsCommitted: Bool
}

/// Immutable projection. LaserGame will own mutations; UI/renderer hold no second score/clock.
nonisolated struct LaserGameState: Equatable, Sendable {
    let sessionGeneration: UUID
    let phase: LaserRoundPhase
    let gameTime: Double
    let activityProgress: Double
    let teamHealth: Int
    let teamScore: Int
    let encounters: [LaserEncounterState]
    var missionProgress: Int = 0
    var missionTarget: Int = 5
    var playerStats: [PlayerID: LaserPlayerTargetCounts] = [:]
    var vault: LaserVaultState? = nil
}

nonisolated enum LaserVaultButton: String, CaseIterable, Hashable, Sendable { case top, middle, bottom }

/// A verified domain command, not raw wrist evidence or a CP1 contract.
nonisolated struct LaserVaultContact: Hashable, Sendable {
    let playerID: PlayerID
    let button: LaserVaultButton
    let calibrationRevision: UInt64
}

nonisolated struct LaserVaultState: Equatable, Sendable {
    let id: UUID
    let deadline: Double
    var buttons: [PlayerID: Set<LaserVaultButton>]
    var opened: Bool = false
}

nonisolated enum LaserCoopDecision: Equatable, Sendable {
    case pending, unavailable, succeeded, failed

    static func evaluate(_ verdicts: [PlayerID: Judgement]) -> Self {
        guard verdicts.count == 2, Set(verdicts.keys) == Set(PlayerID.allCases),
              !verdicts.values.contains(where: { if case .pending = $0 { true } else { false } }) else { return .pending }
        if verdicts.values.contains(where: { if case .unavailable = $0 { true } else { false } }) { return .unavailable }
        return verdicts.values.allSatisfy { $0 == .clear } ? .succeeded : .failed
    }
}
