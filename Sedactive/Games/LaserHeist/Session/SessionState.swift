//
//  SessionState.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation

nonisolated enum SessionState: Equatable, Sendable {
    case idle, starting, awaitingSetup, running, finished, failed(String)
}

nonisolated struct ReplayTargetResult: Equatable, Sendable {
    let encounterID: UUID
    let playerID: PlayerID
    let judgement: Judgement
    let selectedFrameID: UInt64?
}
