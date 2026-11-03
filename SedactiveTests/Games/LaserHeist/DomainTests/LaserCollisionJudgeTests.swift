//
//  GameLogicTests.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation
import Testing
@testable import Sedactive

nonisolated struct LaserCollisionJudgeTests {
    private func fixture() throws -> LaserReplayScenario { try LaserReplayScenarios.make()[0] }

    private func context(_ scenario: LaserReplayScenario) -> BodyInputContext {
        BodyInputContext(sessionGeneration: scenario.input.configuration.sessionGeneration,
                         cameraGeometryRevision: 1, calibrationRevisions: [.player1: 1, .player2: 1],
                         cutovers: [:], isActive: true)
    }

    private func target(_ move: LaserMove, player: PlayerID = .player1) throws -> LaserTarget {
        try LaserTarget(playerID: player, calibrationRevision: 1, requiredMove: move,
                        beam: LaserBeamBand(lowerY: move == .duck ? 1 : 0.25,
                                            upperY: move == .duck ? 1.25 : 0.5),
                        warningTime: 7, crossingTime: 10)
    }

    private func sample(_ player: PlayerID = .player1, crown: Double = 0.5,
                        leftWrist: Double = 0.4, rightWrist: Double = 0.4,
                        leftSole: Double = 0.75, rightSole: Double = 0.75,
                        phase: JumpPhase = .airborne, missing: LaserEvidenceRequirement? = nil,
                        validity: EvidenceValidity = .missingLandmarks) throws -> PlayerBodySample {
        func scalar(_ requirement: LaserEvidenceRequirement, _ value: Double) throws -> EstimatedScalar {
            try EstimatedScalar(value: missing == requirement ? nil : value,
                                validity: missing == requirement ? validity : .valid)
        }
        return try PlayerBodySample(playerID: player, calibrationRevision: 1, trackingStatus: .reliable,
            geometry: BodyGeometry(crownY: scalar(.crown, crown), leftWristY: scalar(.leftWrist, leftWrist),
                                   rightWristY: scalar(.rightWrist, rightWrist), leftSoleY: scalar(.leftSole, leftSole),
                                   rightSoleY: scalar(.rightSole, rightSole), centerX: EstimatedScalar(value: 0, validity: .valid)),
            jumpState: JumpState(phase: missing == .jumpPhase ? .unknown : phase,
                                 validity: missing == .jumpPhase ? validity : .valid))
    }

    private func evidence(_ players: [PlayerBodySample], scenario: LaserReplayScenario) -> LaserEvidenceSelection {
        var slots = scenario.input.records.first?.snapshot?.players ?? [:]
        for player in players { slots[player.playerID] = player }
        let packet = BodySnapshot(sessionGeneration: scenario.input.configuration.sessionGeneration, frameID: 1,
                                  capturedAt: 110, cameraGeometryRevision: 1,
                                  players: slots)
        return .selected(LaserBodyEvidence(snapshot: packet, capturedGameTime: 10, arrivedGameTime: 10.1))
    }

    @Test(arguments: [LaserEvidenceRequirement.crown, .leftWrist, .rightWrist], [0.874, 0.875, 0.876])
    func highBoundaryIncludesMarginAndEqualityIsHit(_ point: LaserEvidenceRequirement, _ height: Double) throws {
        let scenario = try fixture()
        let selection = evidence([try sample(crown: point == .crown ? height : 0.5,
                                             leftWrist: point == .leftWrist ? height : 0.4,
                                             rightWrist: point == .rightWrist ? height : 0.4)], scenario: scenario)
        let actual = try LaserCollisionJudge().judge(target: target(.duck), selection: selection,
                                                     clearanceMargin: 0.125, context: context(scenario))
        #expect(actual == (height < 0.875 ? .clear : .hit(.insufficientClearance)))
    }

    @Test(arguments: [true, false], [0.624, 0.625, 0.626])
    func lowBoundaryRequiresBothSolesStrictlyAboveMargin(_ left: Bool, _ height: Double) throws {
        let scenario = try fixture()
        let selection = evidence([try sample(leftSole: left ? height : 0.75,
                                             rightSole: left ? 0.75 : height)], scenario: scenario)
        #expect(try LaserCollisionJudge().judge(target: target(.jump), selection: selection,
            clearanceMargin: 0.125, context: context(scenario)) == (height > 0.625 ? .clear : .hit(.insufficientClearance)))
    }

    @Test(arguments: [JumpPhase.grounded, .takingOff, .airborne, .landing])
    func validJumpPhaseMustBeAirborneEvenWhenSolesClear(_ phase: JumpPhase) throws {
        let scenario = try fixture()
        #expect(try LaserCollisionJudge().judge(target: target(.jump),
            selection: evidence([sample(phase: phase)], scenario: scenario), clearanceMargin: 0.125,
            context: context(scenario)) == (phase == .airborne ? .clear : .hit(.notAirborne)))
    }

    @Test(arguments: [LaserEvidenceRequirement.crown, .leftWrist, .rightWrist, .leftSole, .rightSole, .jumpPhase],
          EvidenceValidity.allCases.filter { $0 != .valid })
    func everyInvalidRequiredMeasurementStaysUnavailable(_ requirement: LaserEvidenceRequirement,
                                                         _ validity: EvidenceValidity) throws {
        let scenario = try fixture()
        let move: LaserMove = [.crown, .leftWrist, .rightWrist].contains(requirement) ? .duck : .jump
        let player = try sample(crown: 2, leftSole: 0, missing: requirement, validity: validity)
        #expect(try LaserCollisionJudge().judge(target: target(move), selection: evidence([player], scenario: scenario),
            clearanceMargin: 0.125, context: context(scenario)) == .unavailable(.invalidEvidence(requirement, validity)))
    }

    @Test func raisedWristIsHitAndMissingUnneededEvidenceIsIgnored() throws {
        let scenario = try fixture(), judge = LaserCollisionJudge()
        for raised in [try sample(leftWrist: 1), try sample(rightWrist: 1)] {
            #expect(try judge.judge(target: target(.duck), selection: evidence([raised], scenario: scenario),
                clearanceMargin: 0.125, context: context(scenario)) == .hit(.insufficientClearance))
        }
        #expect(try judge.judge(target: target(.duck),
            selection: evidence([sample(missing: .leftSole)], scenario: scenario), clearanceMargin: 0.125,
            context: context(scenario)) == .clear)
        #expect(try judge.judge(target: target(.jump),
            selection: evidence([sample(missing: .crown)], scenario: scenario), clearanceMargin: 0.125,
            context: context(scenario)) == .clear)
        #expect(try judge.judge(target: target(.jump),
            selection: evidence([sample(missing: .leftWrist)], scenario: scenario), clearanceMargin: 0.125,
            context: context(scenario)) == .clear)
        #expect(try judge.judge(target: target(.duck),
            selection: evidence([sample(missing: .jumpPhase)], scenario: scenario), clearanceMargin: 0.125,
            context: context(scenario)) == .clear)
    }

    @Test func playerMovesAndVerdictsAreIndependentWithoutAddingAMixedEncounter() throws {
        let scenario = try fixture(), judge = LaserCollisionJudge()
        // Target-local compatibility for the old split AC; mixed gameplay spawning stays disabled.
        let selection = evidence([try sample(crown: 1.1), try sample(.player2)], scenario: scenario)
        #expect(try judge.judge(target: target(.duck), selection: selection, clearanceMargin: 0.125,
            context: context(scenario)) == .hit(.insufficientClearance))
        #expect(try judge.judge(target: target(.jump, player: .player2), selection: selection, clearanceMargin: 0.125,
            context: context(scenario)) == .clear)
    }

    @Test func pendingWithdrawalAndUnavailableCannotBecomeClear() throws {
        let scenario = try fixture(), judge = LaserCollisionJudge(), value = try target(.duck)
        #expect(try judge.judge(target: value, selection: .pending, clearanceMargin: 0, context: context(scenario)) == .pending(.awaitingFinalization))
        #expect(try judge.judge(target: value, selection: .withdrawn, clearanceMargin: 0, context: context(scenario)) == nil)
        for reason in [LaserUnavailableReason.noSample, .stale, .late, .historyOverflow, .incompatibleContext] {
            #expect(try judge.judge(target: value, selection: .unavailable(reason), clearanceMargin: 0,
                context: context(scenario)) == .unavailable(reason))
        }
        for invalid in [-1.0, Double.nan, Double.infinity] {
            #expect(throws: LaserDataError.self) {
                try judge.judge(target: value, selection: .pending, clearanceMargin: invalid, context: context(scenario))
            }
        }
    }

    @Test(arguments: [true, false])
    func committedVerdictIsNotChangedByLaterOppositeOrDuplicateData(_ initiallyHit: Bool) throws {
        let scenario = try fixture()
        let encounter = try LaserEncounter(id: scenario.encounter.id, attemptID: scenario.encounter.attemptID,
                                          targets: [target(.duck), target(.duck, player: .player2)])
        let selection = evidence([try sample(crown: initiallyHit ? 2 : 0.5), try sample(.player2)], scenario: scenario)
        guard case .selected(let first) = selection else { Issue.record("Missing fixture evidence"); return }
        var game = try LaserGame(configuration: scenario.configuration, context: context(scenario), historyCapacityPerPlayer: 20)
        try game.register(encounter)
        let key = LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: .player1)
        try game.receive(first.snapshot, capturedGameTime: 10, arrivedAt: 10.1)
        try game.advance(to: 10.35)
        let expected: Judgement = initiallyHit ? .hit(.insufficientClearance) : .clear
        #expect(game.judgement(for: key) == expected)
        let later = BodySnapshot(sessionGeneration: first.snapshot.sessionGeneration, frameID: 2, capturedAt: 110.01,
                                 cameraGeometryRevision: 1,
                                 players: [.player1: try sample(crown: initiallyHit ? 0.5 : 2), .player2: try sample(.player2)])
        try game.receive(later, capturedGameTime: 10.01, arrivedAt: 10.4)
        try game.receive(first.snapshot, capturedGameTime: 10, arrivedAt: 10.5)
        try game.advance(to: 11)
        #expect(game.judgement(for: key) == expected)
        #expect(throws: LaserDataError.self) { try game.register(encounter) }
    }

    @Test func malformedUnknownPhaseAndWrongCalibrationAreUnavailable() throws {
        let scenario = try fixture(), judge = LaserCollisionJudge()
        #expect(try judge.judge(target: target(.jump),
            selection: evidence([sample(phase: .unknown)], scenario: scenario), clearanceMargin: 0.125,
            context: context(scenario)) == .unavailable(.incompatibleContext))
        let wrongRevision = try LaserTarget(playerID: .player1, calibrationRevision: 2, requiredMove: .duck,
            beam: LaserBeamBand(lowerY: 1, upperY: 1.25), warningTime: 7, crossingTime: 10)
        #expect(try judge.judge(target: wrongRevision, selection: evidence([sample()], scenario: scenario),
            clearanceMargin: 0.125, context: context(scenario)) == .unavailable(.incompatibleContext))
    }
}
