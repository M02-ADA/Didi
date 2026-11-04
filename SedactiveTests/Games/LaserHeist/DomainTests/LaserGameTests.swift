//
//  CollisionTests.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation
import Testing
@testable import Sedactive

nonisolated struct LaserGameTests {
    private var outcomes: [Judgement] { [.clear, .hit(.insufficientClearance), .unavailable(.invalidEvidence(.crown, .missingLandmarks))] }

    private func setup(target: Int = 5) throws -> (LaserReplayScenario, LaserGame) {
        let scenario = try LaserReplayScenarios.make()[0]
        let context = BodyInputContext(sessionGeneration: scenario.input.configuration.sessionGeneration,
            cameraGeometryRevision: 1, calibrationRevisions: [.player1: 1, .player2: 1], cutovers: [:], isActive: true)
        let config = try LaserRoundConfiguration(evidenceTiming: scenario.configuration.evidenceTiming,
            clearanceMargin: scenario.configuration.clearanceMargin, diamondPoints: nil, missionGateTarget: target)
        return (scenario, try LaserGame(configuration: config, context: context, historyCapacityPerPlayer: 120))
    }

    private func packet(_ scenario: LaserReplayScenario, verdicts: [Judgement], frame: UInt64 = 1,
                        time: Double = 10) throws -> BodySnapshot {
        var players = try #require(scenario.input.records[0].snapshot).players
        for (index, id) in PlayerID.allCases.enumerated() {
            let old = try #require(players[id])
            let crown: EstimatedScalar
            switch verdicts[index] {
            case .clear: crown = old.geometry.crownY
            case .hit: crown = try EstimatedScalar(value: 2, validity: .valid)
            default: crown = try EstimatedScalar(value: nil, validity: .missingLandmarks)
            }
            players[id] = PlayerBodySample(playerID: id, calibrationRevision: 1, trackingStatus: .reliable,
                geometry: BodyGeometry(crownY: crown, leftWristY: old.geometry.leftWristY,
                    rightWristY: old.geometry.rightWristY, leftSoleY: old.geometry.leftSoleY,
                    rightSoleY: old.geometry.rightSoleY, centerX: old.geometry.centerX), jumpState: old.jumpState)
        }
        return BodySnapshot(sessionGeneration: scenario.input.configuration.sessionGeneration, frameID: frame,
                            capturedAt: 100 + time, cameraGeometryRevision: 1, players: players)
    }

    @Test(arguments: [0,1,2], [0,1,2])
    func nineVerdictCombinationsHaveExactlyTheRulesOutcome(_ p1: Int, _ p2: Int) throws {
        let (scenario, initial) = try setup()
        var game = initial
        let values = [outcomes[p1], outcomes[p2]]
        let technical = p1 == 2 || p2 == 2
        let hits = [p1,p2].filter { $0 == 1 }.count
        let clears = [p1,p2].filter { $0 == 0 }.count
        try game.register(scenario.encounter)
        let sample = try packet(scenario, verdicts: values)
        try game.receive(sample, capturedGameTime: 10, arrivedAt: 10.05)
        try game.advance(to: 10.35)
        #expect(game.teamHealth == 5 - (technical ? 0 : hits))
        #expect(game.teamScore == (technical ? 0 : clears * 100))
        #expect(game.missionProgress == 0) // Ordinary lasers never open a vault.
        for (index, id) in PlayerID.allCases.enumerated() {
            #expect(game.playerStats[id]?.cleared == (values[index] == .clear ? 1 : 0))
        }
        let first = game.drainEvents()
        try game.receive(sample, capturedGameTime: 10, arrivedAt: 10.5)
        try game.advance(to: 11)
        #expect(game.drainEvents().isEmpty)
        #expect(first.filter { if case .teamEffectsCommitted = $0.kind { true } else { false } }.count == 1)
        let expected: LaserCoopDecision = technical ? .unavailable : (clears == 2 ? .succeeded : .failed)
        #expect(LaserCoopDecision.evaluate([.player1: values[0], .player2: values[1]]) == expected)
    }

    private func completeVault(_ game: inout LaserGame, id: UUID, generation: UUID, at time: Double) throws {
        try game.openVault(id: id, at: time)
        for (index, player) in PlayerID.allCases.enumerated() {
            for (offset, button) in [LaserVaultButton.bottom, .top, .middle].enumerated() {
                try game.touchVault(id: id, playerID: player, button: button, validity: .valid,
                    generation: generation, calibrationRevision: 1, at: time + 0.1 * Double(index * 3 + offset + 1))
            }
        }
    }

    @Test func vaultRequiresBothPlayersAllButtonsAndOnlyOpensOnce() throws {
        let (scenario, initial) = try setup()
        var game = initial
        let id = scenario.encounter.id, generation = scenario.input.configuration.sessionGeneration
        try game.openVault(id: id, at: 0)
        for (i, button) in LaserVaultButton.allCases.enumerated() {
            #expect(try game.touchVault(id: id, playerID: .player1, button: button, validity: .valid,
                generation: generation, calibrationRevision: 1, at: Double(i+1) / 10))
        }
        #expect(game.missionProgress == 0)
        #expect(try !game.touchVault(id: id, playerID: .player1, button: .top, validity: .valid,
            generation: generation, calibrationRevision: 1, at: 0.4))
        #expect(try !game.touchVault(id: id, playerID: .player2, button: .top, validity: .stale,
            generation: generation, calibrationRevision: 1, at: 0.5))
        #expect(try !game.touchVault(id: id, playerID: .player2, button: .top, validity: .valid,
            generation: generation, calibrationRevision: 2, at: 0.5))
        for (i, button) in LaserVaultButton.allCases.reversed().enumerated() {
            try game.touchVault(id: id, playerID: .player2, button: button, validity: .valid,
                generation: generation, calibrationRevision: 1, at: Double(i+6) / 10)
        }
        #expect(game.missionProgress == 1)
        #expect(game.teamHealth == 5)
        #expect(game.teamScore == 0) // No unapproved vault bonus.
        #expect(try !game.touchVault(id: id, playerID: .player2, button: .top, validity: .valid,
            generation: generation, calibrationRevision: 1, at: 1))
        #expect(game.drainEvents().filter { if case .coopGateSucceeded = $0.kind { true } else { false } }.count == 1)
    }

    @Test func fiveVaultsLeadToFifteenSecondBonusThenExactlyOneRoundEnd() throws {
        let (scenario, initial) = try setup()
        var game = initial
        for index in 0..<5 {
            let id = UUID(uuidString: String(format: "16100000-0000-4000-8000-%012d", index))!
            try completeVault(&game, id: id, generation: scenario.input.configuration.sessionGeneration, at: Double(index * 2))
        }
        #expect(game.missionProgress == 5)
        #expect(game.roundPhase == .diamondTime)
        #expect(game.roundOutcome == nil)
        try game.advance(to: 23.5)
        #expect(game.roundOutcome == nil)
        try game.advance(to: 24)
        #expect(game.roundOutcome == .completed)
        try game.advance(to: 30)
        game.exit()
        let events = game.drainEvents()
        #expect(events.filter { if case .roundEnded = $0.kind { true } else { false } }.count == 1)
        #expect(events.filter { if case .coopGateSucceeded = $0.kind { true } else { false } }.count == 5)
        #expect(events.map(\.sequence) == Array(1...UInt64(events.count)))
    }

    @Test func exactVaultDeadlineFailsEvenWithFullHealthAndUnavailableCannotTouch() throws {
        let (scenario, initial) = try setup()
        var game = initial
        try game.openVault(id: scenario.encounter.id, at: 0)
        #expect(try !game.touchVault(id: scenario.encounter.id, playerID: .player1, button: .top, validity: .missingLandmarks,
            generation: scenario.input.configuration.sessionGeneration, calibrationRevision: 1, at: 1))
        try game.advance(to: 5)
        #expect(game.roundOutcome == .vaultFailed)
        #expect(game.missionProgress == 0)
        #expect(game.teamHealth == 5)
        try game.advance(to: 10)
        #expect(game.drainEvents().filter { if case .coopGateFailed = $0.kind { true } else { false } }.count == 1)
    }

    @Test func healthClampsAtZeroAndLaterTargetsCannotAwardOrDamage() throws {
        let (scenario, initial) = try setup()
        var game = initial
        for index in 0..<4 {
            let time = Double(10 + index * 10)
            let id = UUID(uuidString: String(format: "16200000-0000-4000-8000-%012d", index))!
            let targets = try scenario.encounter.targets.map {
                try LaserTarget(playerID: $0.playerID, calibrationRevision: 1, requiredMove: .duck,
                    beam: $0.beam, warningTime: time - 3, crossingTime: time)
            }
            try game.register(LaserEncounter(id: id, attemptID: id, targets: targets))
        }
        for index in 0..<4 {
            let time = Double(10 + index * 10)
            try game.receive(packet(scenario, verdicts: [outcomes[1],outcomes[1]], frame: UInt64(index+1), time: time),
                             capturedGameTime: time, arrivedAt: time + 0.05)
            try game.advance(to: time + 0.35)
        }
        #expect(game.teamHealth == 0)
        #expect(game.roundOutcome == .healthDepleted)
        #expect(game.summary?.outcome == .healthDepleted)
        #expect(game.summary?.remainingTeamHealth == game.teamHealth)
        #expect(game.summary?.teamScore == game.teamScore)
        #expect(game.summary?.gameDuration == game.gameTime)
        #expect(game.teamScore == 0)
        let events = game.drainEvents()
        #expect(events.compactMap { if case .teamDamaged(let amount, _) = $0.kind { amount } else { nil } } == [2,2,1])
        #expect(events.filter { if case .roundEnded = $0.kind { true } else { false } }.count == 1)
    }

    @Test func technicalAttemptCanRetryWithNewIdentityButCannotReplayOldEffects() throws {
        let (scenario, initial) = try setup()
        var game = initial
        try game.register(scenario.encounter)
        try game.receive(packet(scenario, verdicts: [outcomes[0],outcomes[2]]), capturedGameTime: 10, arrivedAt: 10.05)
        try game.advance(to: 10.35)
        #expect(game.teamScore == 0)
        #expect(game.teamHealth == 5)
        let targets = try scenario.encounter.targets.map {
            try LaserTarget(playerID: $0.playerID, calibrationRevision: 1, requiredMove: .duck, beam: $0.beam,
                            warningTime: 17, crossingTime: 20)
        }
        let retryID = UUID(uuidString: "16300000-0000-4000-8000-000000000001")!
        try game.register(LaserEncounter(id: scenario.encounter.id, attemptID: retryID, targets: targets))
        try game.receive(packet(scenario, verdicts: [outcomes[0],outcomes[0]], frame: 2, time: 20),
                         capturedGameTime: 20, arrivedAt: 20.05)
        try game.advance(to: 20.35)
        #expect(game.teamScore == 200)
        for player in PlayerID.allCases {
            game.remove(LaserTargetKey(encounterID: scenario.encounter.id, attemptID: retryID, playerID: player))
        }
        #expect(throws: LaserDataError.self) {
            try game.register(LaserEncounter(id: scenario.encounter.id, attemptID: retryID, targets: targets))
        }
    }

    @Test func vaultPauseRetainsButtonsAndFreezesActivityProgress() throws {
        let (scenario, initial) = try setup()
        var game = initial
        try game.openVault(id: scenario.encounter.id, at: 10)
        try game.touchVault(id: scenario.encounter.id, playerID: .player1, button: .top, validity: .valid,
            generation: scenario.input.configuration.sessionGeneration, calibrationRevision: 1, at: 11)
        #expect(game.activityProgress == 10)
        game.pause()
        try game.advance(to: 100)
        #expect(game.gameTime == 11)
        #expect(game.vault?.buttons[.player1] == [.top])
        game.resume()
        try game.advance(to: 12) // GameClock, not wall time: paused source time is excluded.
        #expect(game.activityProgress == 10)
        #expect(game.vault?.deadline == 15)
        #expect(game.roundOutcome == nil)
    }
}
