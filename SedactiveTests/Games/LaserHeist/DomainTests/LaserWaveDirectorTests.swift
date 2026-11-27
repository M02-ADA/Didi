//
//  LaserWaveDirectorTests.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation
import Testing
@testable import Sedactive

nonisolated struct LaserWaveDirectorTests {
    private func configuration(_ second: LaserPlayerDifficulty = .fiveStageCandidate) throws -> LaserRoundConfiguration {
        let timing = try LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25, deliveryAllowance: 0.1)
        return try LaserRoundConfiguration(evidenceTiming: timing, clearanceMargin: 0.005, diamondPoints: nil,
            scheduling: LaserSchedulingConfiguration(players: [.player1: .fiveStageCandidate, .player2: second],
                                                      searchStep: 0.25, maximumSearchSteps: 2000))
    }

    private func profile(lift: Double = 0.02, cap: Double = 0.04, drop: Double = 0.08,
                         count: Int = 3, spacing: Double = 8, consecutive: Int = 1,
                         warning: Double = 3, offset: Double = 0) -> LaserPlayerDifficulty {
        LaserPlayerDifficulty(requestedCrownDropShare: drop, requestedSoleLiftShare: lift, beamThicknessShare: 0.01,
            maximumCrownDropShare: 0.10, maximumSoleLiftShare: cap, clearanceReserveShare: 0.1,
            maximumJumpsInWindow: count, jumpWindow: 30, minimumJumpSpacing: spacing,
            maximumConsecutiveJumps: consecutive, minimumTargetSpacing: 4.5,
            warningLead: warning, cueLead: 1.4, crossingOffset: offset)
    }

    private func plan(_ script: [LaserWaveBeat] = LaserWaveBeat.fiveMinuteScript(),
                      second: LaserPlayerDifficulty = .fiveStageCandidate,
                      previous: [LaserScheduledDemand] = [], notBefore: [PlayerID: Double] = [:]) throws -> LaserWaveSchedule {
        let fixture = try #require(LaserReplayScenarios.make().first).input.configuration
        return try LaserWaveDirector().schedule(script: script, calibrations: fixture.calibrations,
            layout: fixture.playerPlaneLayout, configuration: configuration(second), previousDemands: previous,
            notBefore: notBefore)
    }

    @Test func fullRoundHasSeventyThreeTargetsAndStableIdentityAndTiming() throws {
        let first = try plan()
        #expect(first.deferred.isEmpty)
        #expect(first.encounters.count == 73)
        // The five-stage design opens with LEAN OUT, LEAN IN, JUMP, DUCK (16 November 2026).
        #expect(first.encounters.prefix(4).map { $0.targets[0].requiredMove } == [.lean, .lean, .jump, .duck])
        func count(_ player: PlayerID, _ move: LaserMove) -> Int {
            first.encounters.flatMap(\.targets).filter { $0.playerID == player && $0.requiredMove == move }.count
        }
        let p1: [Int] = [count(.player1, .duck), count(.player1, .jump), count(.player1, .lean)]
        let p2: [Int] = [count(.player2, .duck), count(.player2, .jump), count(.player2, .lean)]
        #expect(p1 == [37, 13, 19])
        #expect(p2 == [37, 13, 19])
        // Horizontal lasers are one continuous beam: never DUCK for one player and JUMP for the other.
        for encounter in first.encounters {
            #expect(Set(encounter.targets.map(\.requiredMove)).count == 1, "\(encounter.id): one move per encounter")
            if encounter.targets[0].requiredMove != .lean { #expect(encounter.targets.count == 2, "full width") }
        }
        // Every crossing lands exactly on the script's time: the recovery rules hold without a shift.
        #expect(first.encounters.map { $0.targets[0].crossingTime } == LaserWaveBeat.fiveMinuteScript().map(\.nominalCrossingTime))
        for _ in 0..<3 { #expect(try plan() == first) }
        #expect(first.encounters.map(\.id) == LaserWaveBeat.fiveMinuteScript().map(\.id))
        for (minute, count) in [9, 13, 15, 17, 19].enumerated() {
            #expect(first.encounters.filter { Int($0.targets[0].crossingTime / 60) == minute }.count == count)
        }
    }

    @Test func calibratedBandsAndEveryFullRoundRecoveryConstraintHold() throws {
        let schedule = try plan()
        let fixture = try #require(LaserReplayScenarios.make().first).input.configuration
        let config = try configuration()
        for player in PlayerID.allCases {
            let calibration = try #require(fixture.calibrations[player])
            let profile = try #require(config.scheduling?.players[player])
            let height = calibration.mapping.gameY(imageY: calibration.standingCrownImageY, layout: fixture.playerPlaneLayout)
            let targets = schedule.encounters.flatMap(\.targets).filter { $0.playerID == player }
            var jumps: [Double] = [], consecutive = 0
            for (index, target) in targets.enumerated() {
                #expect(target.calibrationRevision == calibration.revision)
                #expect(target.warningTime >= 0)
                #expect(abs(target.crossingTime - target.warningTime - profile.warningLead) < 1e-9)
                #expect(target.crossingTime - profile.cueLead >= target.warningTime)
                #expect(config.scheduling?.actionCueTime(for: target) == target.crossingTime - profile.cueLead)
                #expect(config.evidenceTiming.finalizationTime(crossing: target.crossingTime) < Double(Int(target.crossingTime / 60) + 1) * 60)
                if index > 0 {
                    // A combined encounter's full-width DUCK follows its LEAN layer `layerGap` later.
                    let beat = LaserWaveBeat.fiveMinuteScript().first { b in schedule.encounters.contains { $0.id == b.id && $0.targets.contains(target) } }
                    let gap = target.crossingTime - targets[index-1].crossingTime
                    if beat?.followsLayer == true, targets[index-1].requiredMove == .lean {
                        #expect(abs(gap - LaserWaveBeat.layerGap) < 1e-9 && target.requiredMove == .duck)
                    } else {
                        let duckRecovery = targets[index - 1].requiredMove == .duck ? beat?.duckRecoverySpacing : nil
                        #expect(gap >= min(profile.minimumTargetSpacing, duckRecovery ?? profile.minimumTargetSpacing))
                    }
                }
                if target.requiredMove == .jump {
                    #expect(target.beam.upperY + config.clearanceMargin < height * profile.maximumSoleLiftShare)
                    if let last = jumps.last { #expect(target.crossingTime - last >= profile.minimumJumpSpacing) }
                    jumps.append(target.crossingTime)
                    #expect(jumps.filter { $0 >= target.crossingTime - profile.jumpWindow }.count <= profile.maximumJumpsInWindow)
                    consecutive += 1
                    #expect(consecutive <= profile.maximumConsecutiveJumps)
                } else if target.requiredMove == .duck {
                    #expect(height - (target.beam.lowerY - config.clearanceMargin) < height * profile.maximumCrownDropShare)
                    consecutive = 0
                } else {
                    #expect(target.lean != nil && target.lean?.isPlaced == false, "a LEAN beam is placed only when registered")
                    consecutive = 0
                }
            }
        }
        let targets = try #require(schedule.encounters.first { $0.targets[0].requiredMove == .duck }).targets
        #expect(targets[1].beam.upperY < targets[0].beam.upperY) // Lower required clearance for the shorter baseline.
    }

    @Test func differentProfilesClampDifficultyAndKeepOwnCrossingTimes() throws {
        let schedule = try plan(second: profile(lift: 0.9, cap: 0.03, drop: 0.9, offset: 0.25))
        #expect(schedule.deferred.isEmpty)
        let fixture = try #require(LaserReplayScenarios.make().first).input.configuration
        let calibration = try #require(fixture.calibrations[.player2])
        let height = calibration.mapping.gameY(imageY: calibration.standingCrownImageY, layout: fixture.playerPlaneLayout)
        for encounter in schedule.encounters {
            // Each player's own demand from the script (a one-player LEAN layer asks one player).
            let beat = try #require(LaserWaveBeat.fiveMinuteScript().first { $0.id == encounter.id })
            for target in encounter.targets { #expect(target.requiredMove == beat.demand(for: target.playerID)?.move) }
            guard encounter.targets.count == 2 else { continue }
            let first = encounter.targets[0], second = encounter.targets[1]
            #expect(abs(second.crossingTime - first.crossingTime - 0.25) < 1e-9)
            if second.requiredMove == .jump { #expect(second.beam.upperY + 0.005 < height * 0.03) }
            else if second.requiredMove == .duck { #expect(height - (second.beam.lowerY - 0.005) < height * 0.10) }
        }
    }

    @Test func stricterFrequencyDefersInsteadOfViolatingLimits() throws {
        let p = profile(count: 1, spacing: 20)
        let schedule = try plan(second: p)
        // The scheduler had to adapt (defer, or move crossings later); the limits below always hold.
        #expect(!schedule.deferred.isEmpty || schedule.encounters.map { $0.targets.map(\.crossingTime) }
                != LaserWaveBeat.fiveMinuteScript().map { [$0.nominalCrossingTime] })
        let jumps = schedule.encounters.flatMap(\.targets).filter { $0.playerID == .player2 && $0.requiredMove == .jump }
        for (index, target) in jumps.enumerated() {
            if index > 0 { #expect(target.crossingTime - jumps[index-1].crossingTime >= p.minimumJumpSpacing) }
            #expect(jumps.prefix(index+1).filter { $0.crossingTime >= target.crossingTime - p.jumpWindow }.count <= 1)
        }
    }

    @Test func warningIntervalsCanOverlapButRequiredActionsStaySpaced() throws {
        let base = LaserWaveBeat.fiveMinuteScript()
        let beats = [LaserWaveBeat(id: base[0].id, move: .duck, nominalCrossingTime: 20, segmentEnd: 60),
                     LaserWaveBeat(id: base[1].id, move: .duck, nominalCrossingTime: 25, segmentEnd: 60)]
        let result = try plan(beats, second: profile(warning: 8))
        #expect(result.encounters.count == 2)
        #expect(result.encounters[1].targets[1].warningTime < result.encounters[0].targets[1].crossingTime)
        #expect(result.encounters[1].targets[1].crossingTime - result.encounters[0].targets[1].crossingTime >= 5)
    }

    @Test func previousRetriesRecoveryFloorAndConsecutiveJumpsCannotBeBypassed() throws {
        let base = LaserWaveBeat.fiveMinuteScript()
        let beat = LaserWaveBeat(id: base[0].id, move: .jump, nominalCrossingTime: 20, segmentEnd: 60)
        let prior = [LaserScheduledDemand(playerID: .player2, move: .jump, crossingTime: 18)]
        let consecutive = try plan([beat], previous: prior)
        #expect(consecutive.encounters.isEmpty)
        #expect(consecutive.deferred.first?.reason == .consecutiveJumps)
        let history = prior + [LaserScheduledDemand(playerID: .player2, move: .duck, crossingTime: 19)]
        let later = try plan([beat], previous: history, notBefore: [.player1: 30, .player2: 30])
        #expect(later.encounters.first?.targets.allSatisfy { $0.crossingTime >= 30 } == true)
    }

    @Test func invalidConfigurationOrGeometryFailsWithoutReducingMargins() throws {
        #expect(throws: LaserDataError.self) { try configuration(profile(count: 0)) }
        #expect(throws: LaserDataError.self) { try configuration(profile(warning: 1)) }
        let fixture = try #require(LaserReplayScenarios.make().first).input.configuration
        let config = try configuration()
        let hugeMargin = try LaserRoundConfiguration(evidenceTiming: config.evidenceTiming, clearanceMargin: 1,
                                                     diamondPoints: nil, scheduling: config.scheduling)
        #expect(throws: LaserDataError.self) {
            try LaserWaveDirector().schedule(script: LaserWaveBeat.fiveMinuteScript(), calibrations: fixture.calibrations,
                                             layout: fixture.playerPlaneLayout, configuration: hugeMargin)
        }
        #expect(throws: LaserDataError.self) { try plan(Array(repeating: LaserWaveBeat.fiveMinuteScript()[0], count: 2)) }
    }
}
