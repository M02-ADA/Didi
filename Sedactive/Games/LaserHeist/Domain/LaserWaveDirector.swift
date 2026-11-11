//
//  LaserWaveDirector.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation

nonisolated struct LaserWaveBeat: Equatable, Sendable {
    let id: UUID
    let move: LaserMove
    let nominalCrossingTime: Double
    /// All target finalizations must precede this boundary, e.g. the next vault.
    let segmentEnd: Double

    /// Fixed 50-encounter LH-01 grid, no random generator or wall-clock identities.
    static func fiveMinuteScript() -> [Self] {
        let highs = [5, 6, 6, 7, 8], lows = [3, 3, 4, 4, 4]
        var beats: [Self] = []
        for minute in 0..<5 {
            let count = highs[minute] + lows[minute]
            // LH-01 starts the scored round with a high beam, then interleaves jump demands.
            let jumps = Set((0..<lows[minute]).map { $0 * count / lows[minute] + (minute == 0 ? 1 : 0) })
            for slot in 0..<count {
                let id = UUID(uuidString: String(format: "15000000-0000-4000-8000-%012d", beats.count + 1))!
                beats.append(Self(id: id, move: jumps.contains(slot) ? .jump : .duck,
                                  nominalCrossingTime: Double(minute * 60 + 3 + slot * 5),
                                  segmentEnd: Double((minute + 1) * 60)))
            }
        }
        return beats
    }
}

nonisolated struct LaserScheduledDemand: Equatable, Sendable {
    let playerID: PlayerID
    let move: LaserMove
    let crossingTime: Double
}

nonisolated enum LaserWaveDeferralReason: Equatable, Sendable {
    case consecutiveJumps, noComfortableSlot
}

nonisolated struct LaserWaveDeferral: Equatable, Sendable {
    let beatID: UUID
    let reason: LaserWaveDeferralReason
}

nonisolated struct LaserWaveSchedule: Equatable, Sendable {
    let encounters: [LaserEncounter]
    /// Explicit unscheduled beats: consumer must give a breather/replan, never silently override limits.
    let deferred: [LaserWaveDeferral]
}

/// Pure planning. Overlapping warning/approach intervals are allowed; demands still respect each slot.
nonisolated struct LaserWaveDirector: Sendable {
    func schedule(script: [LaserWaveBeat], calibrations: [PlayerID: PlayerCalibration], layout: PlayerPlaneLayout,
                  configuration: LaserRoundConfiguration, previousDemands: [LaserScheduledDemand] = [],
                  notBefore: [PlayerID: Double] = [:], players: [PlayerID] = PlayerID.allCases) throws -> LaserWaveSchedule {
        guard let settings = configuration.scheduling else { throw LaserDataError.invalidValue("missing scheduling configuration") }
        try layout.validate()
        // `players` is both (co-op) or P1 alone (DEBUG solo practice): each from its own calibration.
        try requireLaserValue(Set(calibrations.keys) == Set(players) && !players.isEmpty, "both calibrations required")
        for (id, calibration) in calibrations {
            try calibration.validate()
            try requireLaserValue(id == calibration.playerID, "calibration slot")
        }
        try requireLaserValue(Set(calibrations.values.map(\.sessionGeneration)).count == 1
                              && Set(calibrations.values.map(\.cameraGeometryRevision)).count == 1, "calibration context")
        try requireLaserValue(Set(script.map(\.id)).count == script.count, "duplicate beat IDs")
        try requireLaserValue(previousDemands.allSatisfy { $0.crossingTime.isFinite && $0.crossingTime >= 0 }
                              && notBefore.values.allSatisfy { $0.isFinite && $0 >= 0 }, "prior demand/recovery times")
        var history = previousDemands.sorted { $0.crossingTime < $1.crossingTime }
        // Per-player equal-time prior demands have no meaningful chronological action order.
        for player in PlayerID.allCases {
            let times = history.filter { $0.playerID == player }.map(\.crossingTime)
            try requireLaserValue(Set(times).count == times.count, "duplicate prior demand times")
        }
        var encounters: [LaserEncounter] = [], deferred: [LaserWaveDeferral] = []
        var lastNominal = -Double.infinity
        for beat in script {
            try requireLaserValue(beat.nominalCrossingTime.isFinite && beat.segmentEnd.isFinite
                                  && beat.nominalCrossingTime >= 0 && beat.nominalCrossingTime >= lastNominal
                                  && beat.nominalCrossingTime < beat.segmentEnd
                                  && beat.segmentEnd <= configuration.activityDuration, "beat timeline")
            lastNominal = beat.nominalCrossingTime
            if beat.move == .jump && players.contains(where: { player in
                let consecutive = history.filter { $0.playerID == player }.reversed().prefix { $0.move == .jump }.count
                return consecutive >= settings.players[player]!.maximumConsecutiveJumps
            }) {
                deferred.append(LaserWaveDeferral(beatID: beat.id, reason: .consecutiveJumps))
                continue
            }
            let bands = try players.map { player in
                try band(for: beat.move, calibration: calibrations[player]!, layout: layout,
                         profile: settings.players[player]!, margin: configuration.clearanceMargin)
            }
            var candidate = beat.nominalCrossingTime
            var scheduled = false
            for _ in 0..<settings.maximumSearchSteps {
                var fits = true
                for player in players {
                    let profile = settings.players[player]!
                    let time = candidate + profile.crossingOffset
                    let prior = history.filter { $0.playerID == player }
                    if time - profile.warningLead < 0 || time < (notBefore[player] ?? 0)
                        || configuration.evidenceTiming.finalizationTime(crossing: time) >= beat.segmentEnd { fits = false; break }
                    if let last = prior.last, time - last.crossingTime < profile.minimumTargetSpacing { fits = false; break }
                    if beat.move == .jump {
                        let jumps = prior.filter { $0.move == .jump }
                        if let last = jumps.last, time - last.crossingTime < profile.minimumJumpSpacing { fits = false; break }
                        if jumps.filter({ $0.crossingTime >= time - profile.jumpWindow && $0.crossingTime <= time }).count
                            >= profile.maximumJumpsInWindow { fits = false; break }
                    }
                }
                if fits {
                    let targets = try players.enumerated().map { index, player in
                        let profile = settings.players[player]!, crossing = candidate + profile.crossingOffset
                        return try LaserTarget(playerID: player, calibrationRevision: calibrations[player]!.revision,
                            requiredMove: beat.move, beam: bands[index], warningTime: crossing - profile.warningLead,
                            crossingTime: crossing)
                    }
                    encounters.append(try LaserEncounter(id: beat.id, attemptID: beat.id, targets: targets, roster: Set(players)))
                    for target in targets {
                        history.append(LaserScheduledDemand(playerID: target.playerID, move: target.requiredMove,
                                                            crossingTime: target.crossingTime))
                    }
                    scheduled = true
                    break
                }
                candidate += settings.searchStep
                if !candidate.isFinite || candidate >= beat.segmentEnd { break }
            }
            if !scheduled { deferred.append(LaserWaveDeferral(beatID: beat.id, reason: .noComfortableSlot)) }
        }
        return LaserWaveSchedule(encounters: encounters, deferred: deferred)
    }

    private func band(for move: LaserMove, calibration: PlayerCalibration, layout: PlayerPlaneLayout,
                      profile: LaserPlayerDifficulty, margin: Double) throws -> LaserBeamBand {
        let height = calibration.mapping.gameY(imageY: calibration.standingCrownImageY, layout: layout)
        try requireLaserValue(height.isFinite && height > 0, "standing crown above floor")
        let thickness = height * profile.beamThicknessShare
        switch move {
        case .duck:
            let drop = height * min(profile.requestedCrownDropShare,
                                    profile.maximumCrownDropShare * (1 - profile.clearanceReserveShare))
            let lower = height - drop + margin
            try requireLaserValue(lower - margin < height, "high target requires a feasible drop")
            return try LaserBeamBand(lowerY: lower, upperY: lower + thickness)
        case .jump:
            let lift = height * min(profile.requestedSoleLiftShare,
                                    profile.maximumSoleLiftShare * (1 - profile.clearanceReserveShare))
            let upper = lift - margin
            // Infeasible margin/thickness is an error; do not shrink margins to force a target to fit.
            return try LaserBeamBand(lowerY: upper - thickness, upperY: upper)
        }
    }
}
