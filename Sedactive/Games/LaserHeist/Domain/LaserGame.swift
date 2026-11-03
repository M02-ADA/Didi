//
//  LaserGame.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
////gameplay progression


import Foundation

nonisolated enum LaserGameEventKind: Equatable, Sendable {
    case warning(encounterID: UUID, playerID: PlayerID)
    case targetJudged(encounterID: UUID, playerID: PlayerID, judgement: Judgement)
    case attemptWithdrawn(encounterID: UUID, attemptID: UUID)
    case teamEffectsCommitted(encounterID: UUID, healthDelta: Int, scoreDelta: Int)
    case phaseChanged(LaserRoundPhase)
    case roundEnded(LaserRoundOutcome)
}

nonisolated struct GameEvent: Equatable, Sendable {
    let id: UUID
    let sessionGeneration: UUID
    /// Explicit sequence breaks same-time ties and supports consumer deduplication.
    let sequence: UInt64
    let gameTime: Double
    let kind: LaserGameEventKind
}
