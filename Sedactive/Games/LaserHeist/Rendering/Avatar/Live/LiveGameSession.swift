//
//  LiveGameSession.swift
//  Sedactive
//

#if DEBUG
import Foundation

// TEMPORARY Debug-only live round (needs Jevon's review: the production live
// session belongs in Session/). `GameSessionCoordinator` is replay-only, so
// live camera evidence never reached the laser checker. This adapter does for
// live frames exactly what the coordinator does for replay records, using
// Jevon's own types unchanged:
// - `LaserWaveDirector` schedules encounters from the players' calibrations
//   (each player's own beam band, the conservative candidate profile);
// - `GameClock` anchored to the camera's host clock converts each frame's
//   capture time to game time;
// - `LaserGame` receives every live `BodySnapshot` (the same one the robot
//   is posed from: same frame ID, capture time and player IDs), selects the
//   evidence nearest each crossing and judges it with `LaserCollisionJudge`.
// It adds no collision rule, threshold or clock of its own.

nonisolated enum LiveGameMode: String, Sendable {
    /// One real player as P1. P2's targets exist but have no player, so they
    /// are always UNAVAILABLE; encounters are technical (no damage, no score).
    /// A smoke test only, never reported as a cooperative result.
    case solo
    /// The real two-player game: both players calibrated, independent evidence.
    case cooperative
}

/// What the checker saw for one judged target, for diagnosing mismatches.
nonisolated struct LiveCrossingReport: Equatable, Sendable {
    let playerID: PlayerID
    let move: LaserMove
    let crossingTime: Double
    let beam: LaserBeamBand
    let margin: Double
    let judgement: Judgement
    /// The evidence the checker selected, if any.
    let frameID: UInt64?
    /// Selected frame's capture time minus the crossing time (negative: before it).
    let captureOffset: Double?
    /// Arrival delay of that frame after its capture.
    let arrivalDelay: Double?
    /// DUCK: highest of crown and wrists. JUMP: lower sole.
    let measured: Double?
    let airborne: Bool?

    /// The value the measurement had to beat: DUCK below it, JUMP above it.
    var threshold: Double { move == .duck ? beam.lowerY - margin : beam.upperY + margin }
}

nonisolated struct LiveGameSession: Sendable {
    let mode: LiveGameMode
    let configuration: LaserRoundConfiguration
    let encounters: [LaserEncounter]
    let sessionGeneration: UUID
    private(set) var game: LaserGame
    private var clock: GameClock
    private(set) var events: [GameEvent] = []
    private(set) var state: LaserGameState
    private(set) var latestSnapshot: BodySnapshot?
    private(set) var reports: [LiveCrossingReport] = []
    private var reported: Set<LaserTargetKey> = []
    private(set) var rejectedFrames = 0

    /// The replay slice's evidence timing and margin, and the conservative
    /// scheduling candidate for both players (as the director preview uses).
    static func configuration() throws -> LaserRoundConfiguration {
        let profile = LaserPlayerDifficulty.conservativeCandidate
        return try LaserRoundConfiguration(
            evidenceTiming: LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25, deliveryAllowance: 0.1),
            clearanceMargin: 0.005, diamondPoints: nil,
            scheduling: LaserSchedulingConfiguration(players: [.player1: profile, .player2: profile],
                                                      searchStep: 0.5, maximumSearchSteps: 40))
    }

    /// A short smoke sequence alternating DUCK and JUMP, one beat every 6 s,
    /// the first crossing `firstCrossing` seconds after the round starts.
    static func beats(count: Int = 10, firstCrossing: Double = 7) -> [LaserWaveBeat] {
        (0..<count).map { index in
            LaserWaveBeat(id: UUID(uuidString: String(format: "17000000-0000-4000-8000-%012d", index + 1))!,
                          move: index.isMultiple(of: 2) ? .duck : .jump,
                          nominalCrossingTime: firstCrossing + Double(index) * 6, segmentEnd: 300)
        }
    }

    /// - Parameters:
    ///   - calibrations: the live calibrations (solo: P1 only; cooperative: both).
    ///   - startTime: host-clock seconds when the round starts (game time 0).
    init(mode: LiveGameMode, calibrations: [PlayerID: PlayerCalibration], layout: PlayerPlaneLayout,
         sessionGeneration: UUID, cameraGeometryRevision: UInt64, startTime: Double,
         beats: [LaserWaveBeat] = Self.beats()) throws {
        guard let p1 = calibrations[.player1] else { throw LaserDataError.invalidValue("P1 calibration required") }
        var scheduling = calibrations
        switch mode {
        case .cooperative:
            guard calibrations[.player2] != nil else { throw LaserDataError.invalidValue("P2 calibration required") }
        case .solo:
            // The director needs both slots to place P2's lane beam. P2 has no player:
            // its slot copies P1's standing reference only to place that beam. No P2
            // body evidence exists, so every P2 target is judged UNAVAILABLE.
            scheduling[.player2] = Self.placeholder(for: .player2, from: p1)
        }
        let configuration = try Self.configuration()
        self.mode = mode
        self.configuration = configuration
        self.sessionGeneration = sessionGeneration
        encounters = try LaserWaveDirector().schedule(script: beats, calibrations: scheduling, layout: layout,
                                                      configuration: configuration).encounters
        let context = BodyInputContext(sessionGeneration: sessionGeneration, cameraGeometryRevision: cameraGeometryRevision,
                                       calibrationRevisions: scheduling.mapValues(\.revision), cutovers: [:], isActive: true)
        var game = try LaserGame(configuration: configuration, context: context, historyCapacityPerPlayer: 120)
        for encounter in encounters { try game.register(encounter) }
        self.game = game
        clock = try GameClock(sourceTime: startTime)
        state = LaserGameState(sessionGeneration: sessionGeneration, phase: .activity, gameTime: 0, activityProgress: 0,
                               teamHealth: game.teamHealth, teamScore: 0, encounters: [])
        refresh()
    }

    /// P2's scheduling slot in a solo test: P1's standing reference under P2's ID.
    static func placeholder(for player: PlayerID, from c: PlayerCalibration) -> PlayerCalibration {
        PlayerCalibration(playerID: player, sessionGeneration: c.sessionGeneration, revision: c.revision,
                          cameraGeometryRevision: c.cameraGeometryRevision, sourceFrameID: c.sourceFrameID,
                          capturedAt: c.capturedAt, standingCrownImageY: c.standingCrownImageY,
                          standingLeftSoleImageY: c.standingLeftSoleImageY, standingRightSoleImageY: c.standingRightSoleImageY,
                          standingHipImageY: c.standingHipImageY, standingBodyImageHeight: c.standingBodyImageHeight,
                          standingTorsoImageLength: c.standingTorsoImageLength, headOffsetFromNoseShare: c.headOffsetFromNoseShare,
                          leftFootOffsetShare: c.leftFootOffsetShare, rightFootOffsetShare: c.rightFootOffsetShare, mapping: c.mapping)
    }

    var gameTime: Double { game.gameTime }
    var isFinished: Bool {
        game.roundOutcome != nil || state.encounters.allSatisfy { $0.judgements.values.allSatisfy { !$0.isPendingVerdict } }
    }

    /// One live body frame for the checker, at host time `now`. A frame
    /// captured before the round started, or otherwise unmappable, is counted
    /// and dropped (never retimed).
    @discardableResult
    mutating func receive(_ snapshot: BodySnapshot, now: Double) -> Bool {
        do {
            try clock.advance(to: max(now, snapshot.capturedAt))
            guard let captured = clock.gameTime(forCaptureTime: snapshot.capturedAt) else { rejectedFrames += 1; return false }
            try game.receive(snapshot, capturedGameTime: captured, arrivedAt: clock.gameTime)
            latestSnapshot = snapshot
            return true
        } catch {
            rejectedFrames += 1
            return false
        }
    }

    /// Advances game time to host time `now`: finalizes due crossings and collects events.
    mutating func advance(to now: Double) {
        do {
            try clock.advance(to: now)
            try game.advance(to: clock.gameTime)
        } catch { return }
        events.append(contentsOf: game.drainEvents())
        refresh()
    }

    /// Stops the round (Stop button or leaving the lab).
    mutating func stop() {
        game.exit(outcome: .aborted)
        events.append(contentsOf: game.drainEvents())
        refresh()
    }

    private mutating func refresh() {
        var states: [LaserEncounterState] = []
        for encounter in encounters {
            var verdicts: [PlayerID: Judgement] = [:]
            for target in encounter.targets {
                let key = LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: target.playerID)
                let verdict = game.judgement(for: key)
                    ?? state.encounters.first { $0.encounter.id == encounter.id }?.judgements[target.playerID]
                    ?? .pending(.awaitingFinalization)
                verdicts[target.playerID] = verdict
                if !verdict.isPendingVerdict, reported.insert(key).inserted { report(target, key, verdict) }
            }
            let done = verdicts.values.allSatisfy { !$0.isPendingVerdict }
            states.append(LaserEncounterState(encounter: encounter, judgements: verdicts, effectsCommitted: done))
        }
        state = LaserGameState(sessionGeneration: sessionGeneration, phase: game.roundPhase, gameTime: game.gameTime,
                               activityProgress: game.activityProgress, teamHealth: game.teamHealth,
                               teamScore: game.teamScore, encounters: states)
    }

    private mutating func report(_ target: LaserTarget, _ key: LaserTargetKey, _ verdict: Judgement) {
        var frameID: UInt64?, offset: Double?, delay: Double?, measured: Double?, airborne: Bool?
        if case .selected(let evidence)? = game.selection(for: key), let sample = evidence.snapshot.players[target.playerID] {
            frameID = evidence.snapshot.frameID
            offset = evidence.capturedGameTime - target.crossingTime
            delay = evidence.arrivedGameTime - evidence.capturedGameTime
            let g = sample.geometry
            switch target.requiredMove {
            case .duck: measured = [g.crownY.value, g.leftWristY.value, g.rightWristY.value].compactMap { $0 }.max()
            case .jump: measured = [g.leftSoleY.value, g.rightSoleY.value].compactMap { $0 }.min()
            }
            airborne = sample.jumpState.phase == .airborne
        }
        reports.append(LiveCrossingReport(playerID: target.playerID, move: target.requiredMove, crossingTime: target.crossingTime,
                                          beam: target.beam, margin: configuration.clearanceMargin, judgement: verdict,
                                          frameID: frameID, captureOffset: offset, arrivalDelay: delay,
                                          measured: measured, airborne: airborne))
    }
}

extension Judgement {
    nonisolated var isPendingVerdict: Bool {
        if case .pending = self { true } else { false }
    }
}
#endif
