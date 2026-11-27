//
//  LaserWaveDirector.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation

/// One player's demand in a beat: a move, and for LEAN, which way its way out should go.
nonisolated struct LaserBeatDemand: Equatable, Sendable {
    let move: LaserMove
    let intent: LaserLeanIntent?

    static let duck = Self(move: .duck, intent: nil), jump = Self(move: .jump, intent: nil)
    static func lean(_ intent: LaserLeanIntent) -> Self { Self(move: .lean, intent: intent) }
}

nonisolated struct LaserWaveBeat: Equatable, Sendable {
    let id: UUID
    /// The beat's move (the first participating player's).
    let move: LaserMove
    let nominalCrossingTime: Double
    /// All target finalizations must precede this boundary, e.g. the next vault.
    let segmentEnd: Double
    /// Each participating player's demand. A horizontal laser is one continuous beam: every player
    /// gets the same DUCK or JUMP. A LEAN layer may ask only one player (a beam near that player).
    let demands: [PlayerID: LaserBeatDemand]
    /// The full-width horizontal laser of a COMBINED encounter: it crosses `layerGap` after its
    /// vertical LEAN layer (the beat before it), closer than ordinary spacing allows.
    let followsLayer: Bool
    /// The shorter recovery applies only after a DUCK and before this beat.
    let duckRecoverySpacing: Double?

    init(id: UUID, move: LaserMove, nominalCrossingTime: Double, segmentEnd: Double,
         demands: [PlayerID: LaserBeatDemand]? = nil, followsLayer: Bool = false, duckRecoverySpacing: Double? = nil) {
        let all = demands ?? Dictionary(uniqueKeysWithValues: PlayerID.allCases.map {
            ($0, LaserBeatDemand(move: move, intent: move == .lean ? .moreRoom : nil))
        })
        self.id = id
        self.move = PlayerID.allCases.compactMap { all[$0]?.move }.first ?? move
        self.nominalCrossingTime = nominalCrossingTime
        self.segmentEnd = segmentEnd
        self.demands = all
        self.followsLayer = followsLayer
        self.duckRecoverySpacing = duckRecoverySpacing
    }

    /// This player's demand, or nil when the beat does not ask them (a one-player LEAN layer).
    func demand(for player: PlayerID) -> LaserBeatDemand? { demands[player] }

    /// A combined encounter gives LEAN and DUCK separate crossings. The DUCK cue
    /// starts after the LEAN evidence window closes.
    static let layerGap = 1.75

    /// Five 60-second stages, each ending at a vault. D/J are DUCK/JUMP, LO/LI/LR are
    /// lean out/in/toward room, SR/SL are coordinated shifts. A prefix chooses one
    /// player for the vertical layer; `>D` adds a full-width DUCK 1.75 seconds later.
    static let fiveStages: [[(time: Double, code: String)]] = [
        // Get Moving: 9 lasers, no combinations.
        [(6, "LO"), (12, "LI"), (18, "J"), (24, "D"), (30, "LO"), (36, "D"), (42, "J"), (48, "LI"), (54, "D")],
        // Switch It Up: 3 JUMPs separated by DUCKs and vertical-to-DUCK pairs.
        [(5, "D"), (9.5, "J"), (14, "LO>D"), (20.25, "LI>D"), (26.5, "J"), (31, "LR>D"),
         (37.25, "D"), (41.75, "D"), (46.25, "J"), (50.75, "D")],
        // Double Trouble: faster DUCK recovery and one solo vertical layer per lane.
        [(5, "D"), (9.5, "J"), (14, "D"), (17.75, "LO>D"), (23.25, "1LO>D"), (29.5, "J"),
         (34, "LI>D"), (39.5, "2LR>D"), (45, "D"), (49.5, "J"), (54, "D")],
        // Security Alert: 9 DUCKs, with the same recovery before and after each JUMP.
        [(5, "D"), (9.5, "J"), (14, "LO>D"), (18.25, "D"), (20.75, "LI>D"), (25, "SR>D"),
         (31.25, "J"), (35.75, "1LR>D"), (40, "D"), (42.5, "2LR>D"), (48.75, "J"), (53.25, "D")],
        // Final Rush: 10 DUCKs and 2 JUMPs, ending 7.25 seconds before the Final Vault.
        [(5, "D"), (9.5, "J"), (14, "LO>D"), (18.25, "1LO>D"), (22.5, "D"), (25, "2LO>D"),
         (29.25, "SR>D"), (33.5, "D"), (36, "1LR>D"), (42.25, "J"), (46.75, "SL>D"), (51, "2LR>D")],
    ]

    /// The full-width horizontal lasers of the combined encounters (the `followsLayer` beats). Each
    /// is registered together with its vertical layer (`LaserLiveRoundDirector.registrationTime`), so
    /// the whole arrangement is on screen from the layer's reveal: the vertical beam ahead, the
    /// horizontal beam armed (unpowered) behind it, powering up for its own crossing.
    static let layeredHorizontalIDs: Set<UUID> = Set(fiveMinuteScript().filter(\.followsLayer).map(\.id))

    static func demand(_ code: String) -> LaserBeatDemand {
        switch code {
        case "D": .duck
        case "J": .jump
        case "LO": .lean(.outward)
        case "LI": .lean(.inward)
        case "LR": .lean(.moreRoom)
        case "SR": .lean(.shift(1))
        case "SL": .lean(.shift(-1))
        default: preconditionFailure("unknown beat code \(code)")
        }
    }

    /// The whole round (73 beats), no random generator or wall-clock identities.
    static func fiveMinuteScript() -> [Self] {
        var beats: [Self] = []
        func add(_ demands: [PlayerID: LaserBeatDemand], at time: Double, stage: Int,
                 followsLayer: Bool = false, duckRecoverySpacing: Double? = nil) {
            let id = UUID(uuidString: String(format: "15000000-0000-4000-8000-%012d", beats.count + 1))!
            beats.append(Self(id: id, move: demands.values.first!.move, nominalCrossingTime: Double(stage * 60) + time,
                              segmentEnd: Double((stage + 1) * 60), demands: demands, followsLayer: followsLayer, duckRecoverySpacing: duckRecoverySpacing))
        }
        for (stage, slots) in fiveStages.enumerated() {
            for slot in slots {
                let parts = slot.code.split(separator: ">").map(String.init)
                var lean = parts[0]
                var players = PlayerID.allCases
                if let only = lean.first.flatMap({ Int(String($0)) }) {
                    players = [only == 1 ? .player1 : .player2]
                    lean.removeFirst()
                }
                let usesShortRecovery = lean == "D" || parts.count == 2
                let spacing: Double? = if usesShortRecovery && stage >= 3 { 2.5 }
                    else if usesShortRecovery && stage == 2 { 3.75 }
                    else { nil }
                add(Dictionary(uniqueKeysWithValues: players.map { ($0, demand(lean)) }), at: slot.time, stage: stage,
                    duckRecoverySpacing: spacing)
                if parts.count > 1 {
                    let horizontal = demand(parts[1])
                    add(Dictionary(uniqueKeysWithValues: PlayerID.allCases.map { ($0, horizontal) }),
                        at: slot.time + layerGap, stage: stage, followsLayer: true,
                        duckRecoverySpacing: spacing.map { $0 + layerGap })
                }
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
            // The players this beat asks (a one-player LEAN layer asks one; none in a solo round
            // whose player it does not ask: the beat is skipped, nothing to judge).
            let asked = players.filter { beat.demand(for: $0) != nil }
            guard !asked.isEmpty else { continue }
            if asked.contains(where: { player in
                guard beat.demand(for: player)?.move == .jump else { return false }
                let consecutive = history.filter { $0.playerID == player }.reversed().prefix { $0.move == .jump }.count
                return consecutive >= settings.players[player]!.maximumConsecutiveJumps
            }) {
                deferred.append(LaserWaveDeferral(beatID: beat.id, reason: .consecutiveJumps))
                continue
            }
            let bands = try asked.map { player in
                try band(for: beat.demand(for: player)!.move, calibration: calibrations[player]!, layout: layout,
                         profile: settings.players[player]!, margin: configuration.clearanceMargin)
            }
            var candidate = beat.nominalCrossingTime
            var scheduled = false
            for _ in 0..<settings.maximumSearchSteps {
                var fits = true
                for player in asked {
                    let profile = settings.players[player]!
                    let time = candidate + profile.crossingOffset
                    let prior = history.filter { $0.playerID == player }
                    if time - profile.warningLead < 0 || time < (notBefore[player] ?? 0)
                        || configuration.evidenceTiming.finalizationTime(crossing: time) >= beat.segmentEnd { fits = false; break }
                    // A combined encounter's horizontal laser follows its layer (the beat before it, a
                    // LEAN in the script) exactly `layerGap` later; anything else keeps the spacing.
                    let spacing: Double
                    if beat.followsLayer,
                       abs(time - (prior.last?.crossingTime ?? -.infinity) - LaserWaveBeat.layerGap) < 1e-9 {
                        spacing = LaserWaveBeat.layerGap
                    } else if prior.last?.move == .duck, let shorter = beat.duckRecoverySpacing {
                        spacing = min(profile.minimumTargetSpacing, shorter)
                    } else {
                        spacing = profile.minimumTargetSpacing
                    }
                    if let last = prior.last, time - last.crossingTime < spacing - 1e-9 { fits = false; break }
                    if beat.demand(for: player)!.move == .jump {
                        let jumps = prior.filter { $0.move == .jump }
                        if let last = jumps.last, time - last.crossingTime < profile.minimumJumpSpacing { fits = false; break }
                        if jumps.filter({ $0.crossingTime >= time - profile.jumpWindow && $0.crossingTime <= time }).count
                            >= profile.maximumJumpsInWindow { fits = false; break }
                    }
                }
                if fits {
                    let targets = try asked.enumerated().map { index, player in
                        let profile = settings.players[player]!, crossing = candidate + profile.crossingOffset
                        let demand = beat.demand(for: player)!
                        // A shift needs a partner: alone, a LEAN goes toward more room.
                        var intent = demand.intent
                        if case .shift? = intent, players.count < 2 { intent = .moreRoom }
                        return try LaserTarget(playerID: player, calibrationRevision: calibrations[player]!.revision,
                            requiredMove: demand.move, beam: bands[index], warningTime: crossing - profile.warningLead,
                            crossingTime: crossing,
                            lean: demand.move == .lean ? LaserLeanBeam(intent: intent ?? .moreRoom) : nil)
                    }
                    encounters.append(try LaserEncounter(id: beat.id, attemptID: beat.id, targets: targets, roster: Set(asked)))
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
        case .lean:
            // A vertical beam spans the whole body; the band is not judged (`LaserLeanBeam` is).
            return try LaserBeamBand(lowerY: 0, upperY: height)
        case .jump:
            let lift = height * min(profile.requestedSoleLiftShare,
                                    profile.maximumSoleLiftShare * (1 - profile.clearanceReserveShare))
            let upper = lift - margin
            // Infeasible margin/thickness is an error; do not shrink margins to force a target to fit.
            return try LaserBeamBand(lowerY: upper - thickness, upperY: upper)
        }
    }
}
