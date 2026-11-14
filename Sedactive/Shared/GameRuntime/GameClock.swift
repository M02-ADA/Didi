//
//  GameClock.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation

nonisolated enum GameClockError: Error { case invalidSourceTime }

/// One active-time clock. Resume creates a fresh capture epoch; pause/older-epoch captures are rejected.
nonisolated struct GameClock: Sendable {
    private(set) var gameTime = 0.0
    private(set) var isRunning = true
    private var lastSourceTime: Double
    private var sourceAnchor: Double
    private var gameAnchor = 0.0

    init(sourceTime: Double) throws {
        guard sourceTime.isFinite && sourceTime >= 0 else { throw GameClockError.invalidSourceTime }
        lastSourceTime = sourceTime
        sourceAnchor = sourceTime
    }

    mutating func advance(to sourceTime: Double) throws {
        guard sourceTime.isFinite && sourceTime >= lastSourceTime else { throw GameClockError.invalidSourceTime }
        lastSourceTime = sourceTime
        if isRunning { gameTime = gameAnchor + sourceTime - sourceAnchor }
    }

    mutating func pause(at sourceTime: Double) throws { try advance(to: sourceTime); isRunning = false }

    mutating func resume(at sourceTime: Double) throws {
        try advance(to: sourceTime)
        guard !isRunning else { return }
        sourceAnchor = sourceTime
        gameAnchor = gameTime
        isRunning = true
    }

    func gameTime(forCaptureTime time: Double) -> Double? {
        guard isRunning, time.isFinite, time >= sourceAnchor, time <= lastSourceTime else { return nil }
        return gameAnchor + time - sourceAnchor
    }
}
