//
//  SessionTests.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation
import Testing
@testable import Sedactive

nonisolated struct GameClockTests {
    @Test(arguments: [0.0, 1_000_000.0])
    func originalSourceOffsetDoesNotChangeActiveGameTime(_ origin: Double) throws {
        var clock = try GameClock(sourceTime: origin)
        try clock.advance(to: origin + 4)
        #expect(clock.gameTime == 4)
        #expect(clock.gameTime(forCaptureTime: origin + 3) == 3)
        #expect(clock.gameTime(forCaptureTime: origin + 5) == nil)
    }

    @Test func pauseExcludesInactiveTimeAndResumeRejectsOldCaptures() throws {
        var clock = try GameClock(sourceTime: 1000)
        try clock.pause(at: 1004)
        try clock.advance(to: 1050)
        #expect(clock.gameTime == 4)
        #expect(clock.gameTime(forCaptureTime: 1003) == nil)
        try clock.resume(at: 1100)
        try clock.advance(to: 1103)
        #expect(clock.gameTime == 7)
        #expect(clock.gameTime(forCaptureTime: 1099) == nil)
        #expect(clock.gameTime(forCaptureTime: 1101) == 5)
    }

    @Test func sourceRateComesFromSuppliedTimeRatherThanFrameCount() throws {
        var clock = try GameClock(sourceTime: 50)
        for time in [50.01, 50.02, 50.5, 54] { try clock.advance(to: time) }
        #expect(clock.gameTime == 4)
        #expect(throws: GameClockError.self) { try clock.advance(to: 53) }
        #expect(clock.gameTime == 4)
    }
}
