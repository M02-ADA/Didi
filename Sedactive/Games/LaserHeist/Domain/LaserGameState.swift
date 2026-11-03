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
}
