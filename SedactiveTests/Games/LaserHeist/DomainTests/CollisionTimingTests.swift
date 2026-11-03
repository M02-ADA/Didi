//
//  CollisionTimingTests.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation
import Testing
@testable import Sedactive

nonisolated struct CollisionTimingTests {
    private func context(_ scenario: LaserReplayScenario) -> BodyInputContext {
        BodyInputContext(sessionGeneration: scenario.input.configuration.sessionGeneration,
                         cameraGeometryRevision: 1,
                         calibrationRevisions: scenario.input.configuration.calibrations.mapValues(\.revision),
                         cutovers: [:], isActive: true)
    }

    private func key(_ scenario: LaserReplayScenario, _ player: PlayerID) -> LaserTargetKey {
        LaserTargetKey(encounterID: scenario.encounter.id, attemptID: scenario.encounter.attemptID, playerID: player)
    }

    /// Test-only geometry oracle: production LH-09 returns evidence, not an LH-10 verdict.
    private func oracle(_ result: LaserEvidenceSelection, target: LaserTarget, margin: Double) -> Judgement? {
        switch result {
        case .pending: return .pending(.awaitingFinalization)
        case .withdrawn: return nil
        case .unavailable(let reason): return .unavailable(reason)
        case .selected(let evidence):
            guard let sample = evidence.snapshot.players[target.playerID] else { return .unavailable(.noSample) }
            if target.requiredMove == .duck {
                let top = [sample.geometry.crownY.value, sample.geometry.leftWristY.value,
                           sample.geometry.rightWristY.value].compactMap { $0 }.max()!
                return top + margin < target.beam.lowerY ? .clear : .hit(.insufficientClearance)
            }
            let sole = min(sample.geometry.leftSoleY.value!, sample.geometry.rightSoleY.value!)
            guard sole - margin > target.beam.upperY else { return .hit(.insufficientClearance) }
            return sample.jumpState.phase == .airborne ? .clear : .hit(.notAirborne)
        }
    }

    @Test(arguments: Array(1...9))
    func officialReplayCases(_ number: Int) throws {
        let scenario = try LaserReplayScenarios.make()[number - 1]
        for expected in scenario.expected {
            var game = try LaserGame(timing: scenario.configuration.evidenceTiming, context: context(scenario), historyCapacityPerPlayer: 120)
            try game.register(scenario.encounter)
            var clock = try GameClock(sourceTime: scenario.captureEpoch)
            let end = min(expected.checkpoint, scenario.pauseAtGameTime ?? .infinity)
            for record in scenario.input.records where record.deliveredAt - scenario.captureEpoch <= end {
                let snapshot = try #require(record.snapshot)
                try clock.advance(to: record.deliveredAt)
                let captured = try #require(clock.gameTime(forCaptureTime: snapshot.capturedAt))
                try game.receive(snapshot, capturedGameTime: captured, arrivedAt: clock.gameTime)
            }
            let targetKey = key(scenario, expected.playerID)
            if let pause = scenario.pauseAtGameTime {
                try game.advance(to: pause)
                game.pause()
                try game.advance(to: expected.checkpoint)
                #expect(game.selection(for: targetKey) == .withdrawn)
                continue
            }
            try game.advance(to: expected.checkpoint - 0.000001)
            #expect(game.selection(for: targetKey) == .pending)
            try game.advance(to: expected.checkpoint)
            let result = try #require(game.selection(for: targetKey))
            let target = try #require(scenario.encounter.targets.first { $0.playerID == expected.playerID })
            #expect(oracle(result, target: target, margin: scenario.configuration.clearanceMargin) == expected.judgement)
            if case .selected(let evidence) = result { #expect(evidence.snapshot.frameID == expected.selectedFrameID) }
            // Future data must not revise a committed selection (R4 in particular).
            for record in scenario.input.records where record.deliveredAt - scenario.captureEpoch > expected.checkpoint {
                let packet = try #require(record.snapshot)
                try game.receive(packet, capturedGameTime: packet.capturedAt - scenario.captureEpoch,
                                 arrivedAt: record.deliveredAt - scenario.captureEpoch)
            }
            #expect(game.selection(for: targetKey) == result)
        }
    }

    @Test func captureClockExcludesPauseAndRejectsPreviousEpoch() throws {
        var clock = try GameClock(sourceTime: 100)
        try clock.advance(to: 110)
        #expect(clock.gameTime(forCaptureTime: 109) == 9)
        try clock.pause(at: 110)
        try clock.advance(to: 120)
        #expect(clock.gameTime == 10)
        #expect(clock.gameTime(forCaptureTime: 115) == nil)
        try clock.resume(at: 120)
        try clock.advance(to: 122)
        #expect(clock.gameTime == 12)
        #expect(clock.gameTime(forCaptureTime: 121) == 11)
        #expect(clock.gameTime(forCaptureTime: 109) == nil)
        #expect(clock.gameTime(forCaptureTime: 115) == nil)
        #expect(throws: GameClockError.self) { try clock.advance(to: 119) }
    }

    @Test func boundedHistoryOverLongReplay() throws {
        let scenario = try #require(LaserReplayScenarios.make().first)
        let packet = try #require(scenario.input.records[0].snapshot)
        var game = try LaserGame(timing: scenario.configuration.evidenceTiming, context: context(scenario), historyCapacityPerPlayer: 20)
        for frame in 1...10_000 {
            let time = Double(frame) / 10
            let snapshot = BodySnapshot(sessionGeneration: packet.sessionGeneration, frameID: UInt64(frame),
                                        capturedAt: 100 + time, cameraGeometryRevision: 1, players: packet.players)
            try game.receive(snapshot, capturedGameTime: time, arrivedAt: time)
            try game.advance(to: time)
            #expect(game.historyCount <= 40)
        }
        try game.advance(to: 1002)
        #expect(game.historyCount == 0)
        #expect(game.crossingCount == 0)
    }

    @Test func duplicatesTieBreakAndOverloadCannotFinalizeEarly() throws {
        let scenario = try #require(LaserReplayScenarios.make().first)
        let original = try #require(scenario.input.records[0].snapshot)
        let timing = try LaserEvidenceTiming(windowBefore: 0.5, windowAfter: 0.5, deliveryAllowance: 0.25)
        var game = try LaserGame(timing: timing, context: context(scenario), historyCapacityPerPlayer: 4)
        try game.register(scenario.encounter)
        let before = BodySnapshot(sessionGeneration: original.sessionGeneration, frameID: 1, capturedAt: 109.75,
                                  cameraGeometryRevision: 1, players: original.players)
        let after = BodySnapshot(sessionGeneration: original.sessionGeneration, frameID: 2, capturedAt: 110.25,
                                 cameraGeometryRevision: 1, players: original.players)
        try game.receive(after, capturedGameTime: 10.25, arrivedAt: 10.3)
        try game.receive(before, capturedGameTime: 9.75, arrivedAt: 10.4)
        try game.receive(before, capturedGameTime: 9.75, arrivedAt: 10.5)
        #expect(game.historyCount == 4)
        try game.advance(to: 10.75)
        if case .selected(let value) = game.selection(for: key(scenario, .player1)) {
            #expect(value.snapshot.frameID == 1)
        } else { Issue.record("Expected earlier sample on equal-distance tie") }

        var overloaded = try LaserGame(timing: timing, context: context(scenario), historyCapacityPerPlayer: 1)
        try overloaded.register(scenario.encounter)
        try overloaded.receive(before, capturedGameTime: 9.75, arrivedAt: 9.75)
        try overloaded.receive(after, capturedGameTime: 10.25, arrivedAt: 10.25)
        #expect(overloaded.selection(for: key(scenario, .player1)) == .pending)
        try overloaded.advance(to: 10.75)
        #expect(overloaded.selection(for: key(scenario, .player1)) == .unavailable(.historyOverflow))
    }

    @Test func exitAndPausePreventNewFinalizationEvenAfterResume() throws {
        let scenario = try #require(LaserReplayScenarios.make().first)
        for exit in [false, true] {
            var game = try LaserGame(timing: scenario.configuration.evidenceTiming, context: context(scenario), historyCapacityPerPlayer: 20)
            try game.register(scenario.encounter)
            if exit { game.exit() } else { game.pause() }
            try game.advance(to: 20)
            #expect(game.selection(for: key(scenario, .player1)) == .withdrawn)
            game.resume()
            try game.advance(to: 21)
            #expect(game.selection(for: key(scenario, .player1)) == .withdrawn)
            #expect(game.historyCount == 0)
        }
    }

    @Test func inclusiveBoundaryDeliveryAndCausalWindow() throws {
        let scenario = try #require(LaserReplayScenarios.make().first)
        let original = try #require(scenario.input.records[0].snapshot)
        let timing = try LaserEvidenceTiming(windowBefore: 0.5, windowAfter: 0.5, deliveryAllowance: 0.25)
        for capture in [9.5, 10.5] {
            var game = try LaserGame(timing: timing, context: context(scenario), historyCapacityPerPlayer: 10)
            try game.register(scenario.encounter)
            let packet = BodySnapshot(sessionGeneration: original.sessionGeneration, frameID: 1,
                                      capturedAt: 100 + capture, cameraGeometryRevision: 1, players: original.players)
            try game.receive(packet, capturedGameTime: capture, arrivedAt: 10.75)
            try game.advance(to: 10.75)
            if case .selected(let evidence) = game.selection(for: key(scenario, .player1)) {
                #expect(evidence.capturedGameTime == capture)
            } else { Issue.record("Inclusive capture/delivery boundary should select evidence") }
        }
        let causal = try LaserEvidenceTiming(windowBefore: 0.5, windowAfter: 0, deliveryAllowance: 0.25)
        var game = try LaserGame(timing: causal, context: context(scenario), historyCapacityPerPlayer: 10)
        try game.register(scenario.encounter)
        let futureCapture = BodySnapshot(sessionGeneration: original.sessionGeneration, frameID: 1, capturedAt: 110.125,
                                         cameraGeometryRevision: 1, players: original.players)
        try game.receive(futureCapture, capturedGameTime: 10.125, arrivedAt: 10.125)
        try game.advance(to: 10.25)
        #expect(game.selection(for: key(scenario, .player1)) == .unavailable(.noSample))
    }

    @Test func requiredWristsAndContextCutoverInvalidateEvidence() throws {
        let scenario = try #require(LaserReplayScenarios.make().first)
        let original = try #require(scenario.input.records[0].snapshot)
        var players = original.players
        let sample = try #require(players[.player1])
        let missing = try EstimatedScalar(value: nil, validity: .missingLandmarks)
        players[.player1] = PlayerBodySample(playerID: .player1, calibrationRevision: 1, trackingStatus: .reliable,
            geometry: BodyGeometry(crownY: sample.geometry.crownY, leftWristY: missing,
                                   rightWristY: sample.geometry.rightWristY, leftSoleY: sample.geometry.leftSoleY,
                                   rightSoleY: sample.geometry.rightSoleY, centerX: sample.geometry.centerX),
            jumpState: sample.jumpState)
        let packet = BodySnapshot(sessionGeneration: original.sessionGeneration, frameID: 1, capturedAt: 110,
                                  cameraGeometryRevision: 1, players: players)
        var game = try LaserGame(timing: scenario.configuration.evidenceTiming, context: context(scenario), historyCapacityPerPlayer: 10)
        try game.register(scenario.encounter)
        try game.receive(packet, capturedGameTime: 10, arrivedAt: 10.1)
        try game.advance(to: 10.35)
        #expect(game.selection(for: key(scenario, .player1)) == .unavailable(.invalidEvidence(.leftWrist, .missingLandmarks)))
        let previous = context(scenario)
        game.updateContext(BodyInputContext(sessionGeneration: previous.sessionGeneration,
            cameraGeometryRevision: previous.cameraGeometryRevision, calibrationRevisions: [.player1: 2, .player2: 2],
            cutovers: [.player1: BodyInputCutover(frameID: 2, capturedAt: 111)], isActive: true))
        #expect(game.historyCount == 0)
        #expect(game.selection(for: key(scenario, .player1)) == .withdrawn)
    }
}
