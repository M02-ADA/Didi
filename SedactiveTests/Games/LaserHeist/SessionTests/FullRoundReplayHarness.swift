import Foundation
@testable import Sedactive

// Add a named scenario and its original issue/task ID here when LH-13/14/20/21 supplies a reproduced bug.
nonisolated enum FullRoundReplayCase: String, CaseIterable, Sendable {
    case allClear, duplicateFrames, missingLandmark, trackingLossRecovery, uncertainIdentityRecovery
    case healthFailure, vaultTimeout, earlyExit, providerFailure
}

nonisolated struct FullRoundReplayTrace: Equatable, Sendable {
    let summary: RoundSummary
    let events: [GameEvent]
    let results: [ReplayTargetResult]
    let maximumHistoryCount: Int
}

nonisolated struct FullRoundReplayScenario: Sendable {
    enum Action: Sendable {
        case register(LaserEncounter), packet(BodySnapshot), tick
        case openVault(UUID), touchVault(UUID, PlayerID, LaserVaultButton)
        case resume, exit, providerFailure
    }
    struct Step: Sendable {
        let sourceTime: Double
        let order: Int
        let action: Action
    }
    let fixture: ReplayFixture
    let configuration: LaserRoundConfiguration
    let steps: [Step]

    static func make(_ mode: FullRoundReplayCase, base: ReplayFixture) throws -> Self {
        let settings = try LaserSchedulingConfiguration(players: [.player1: .conservativeCandidate, .player2: .conservativeCandidate],
                                                       searchStep: 0.25, maximumSearchSteps: 2000)
        let config = try LaserRoundConfiguration(evidenceTiming: LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25,
                                                                                   deliveryAllowance: 0.1),
                                                clearanceMargin: 0.005, diamondPoints: nil, scheduling: settings)
        let plan = try LaserWaveDirector().schedule(script: LaserWaveBeat.fiveMinuteScript(),
            calibrations: base.configuration.calibrations, layout: base.configuration.playerPlaneLayout, configuration: config)
        try requireLaserValue(plan.deferred.isEmpty && plan.encounters.count == 50, "full-round plan must fit")
        var steps: [Step] = []
        var frame: UInt64 = 0
        func add(_ time: Double, _ action: Action) {
            steps.append(Step(sourceTime: time, order: steps.count, action: action))
        }
        func packet(encounter: LaserEncounter, sourceCapture: Double, fault: Bool, recovered: Bool = false) throws -> BodySnapshot {
            frame += 1
            var players: [PlayerID: PlayerBodySample] = [:]
            for target in encounter.targets {
                let id = target.playerID
                let calibration = base.configuration.calibrations[id]!
                let height = calibration.mapping.gameY(imageY: calibration.standingCrownImageY,
                                                       layout: base.configuration.playerPlaneLayout)
                let unavailable = fault && !recovered && id == .player2
                    && [.trackingLossRecovery, .uncertainIdentityRecovery].contains(mode)
                let validity: EvidenceValidity = mode == .trackingLossRecovery ? .outOfFrame : .identityUncertain
                func value(_ y: Double) throws -> EstimatedScalar {
                    try EstimatedScalar(value: unavailable ? nil : y, validity: unavailable ? validity : .valid)
                }
                let hit = mode == .healthFailure && !recovered
                let sole = target.requiredMove == .jump && !hit ? target.beam.upperY + config.clearanceMargin + height * 0.001 : 0
                var crown = try value(hit ? height : (target.requiredMove == .duck
                    ? target.beam.lowerY - config.clearanceMargin - height * 0.01 : height + sole))
                if fault && !recovered && id == .player2 && mode == .missingLandmark {
                    crown = try EstimatedScalar(value: nil, validity: .missingLandmarks)
                }
                let wrist = try value(target.requiredMove == .duck
                    ? target.beam.lowerY - config.clearanceMargin - height * 0.02 : height * 0.6 + sole)
                players[id] = PlayerBodySample(playerID: id, calibrationRevision: calibration.revision,
                    trackingStatus: unavailable ? (mode == .trackingLossRecovery ? .lost : .uncertain) : .reliable,
                    geometry: BodyGeometry(crownY: crown, leftWristY: wrist, rightWristY: wrist,
                                           leftSoleY: try value(sole), rightSoleY: try value(sole),
                                           centerX: try value(base.configuration.playerPlaneLayout.centerX(for: id))),
                    jumpState: JumpState(phase: unavailable ? .unknown : (target.requiredMove == .jump && !hit ? .airborne : .grounded),
                                         validity: unavailable ? validity : .valid))
            }
            return BodySnapshot(sessionGeneration: base.configuration.sessionGeneration, frameID: frame,
                                capturedAt: sourceCapture, cameraGeometryRevision: base.cameraGeometryRevision, players: players)
        }
        // Initial compatible observation establishes synthetic tracking before the first action window.
        add(0.02, .packet(try packet(encounter: plan.encounters[0], sourceCapture: 0.01, fault: false, recovered: true)))
        if mode == .earlyExit { add(2, .exit) }
        if mode == .providerFailure { add(2, .providerFailure) }
        var vaultOffset = 0.0, retryOffset = 0.0, pauseOffset = 0.0
        for (index, original) in plan.encounters.enumerated() {
            let offset = vaultOffset + retryOffset
            let targets = try original.targets.map {
                try LaserTarget(playerID: $0.playerID, calibrationRevision: $0.calibrationRevision, requiredMove: $0.requiredMove,
                    beam: $0.beam, warningTime: $0.warningTime + offset, crossingTime: $0.crossingTime + offset)
            }
            let encounter = try LaserEncounter(id: original.id, attemptID: original.attemptID, targets: targets)
            let crossing = targets[0].crossingTime
            add(targets[0].warningTime + pauseOffset, .register(encounter))
            let body = try packet(encounter: encounter, sourceCapture: crossing + pauseOffset, fault: index == 0)
            add(crossing + pauseOffset + 0.05, .packet(body))
            if mode == .duplicateFrames { add(crossing + pauseOffset + 0.075, .packet(body)) }
            if index == 0 && [.trackingLossRecovery, .uncertainIdentityRecovery].contains(mode) {
                let lossSource = crossing + pauseOffset + 0.05
                add(lossSource + 2, .packet(try packet(encounter: encounter, sourceCapture: lossSource + 1.95, fault: false, recovered: true)))
                add(lossSource + 5.4, .resume) // Reacquisition, settling and countdown: game clock stays paused.
                pauseOffset += 5.4
                retryOffset += 9
                let retryTargets = try targets.map {
                    try LaserTarget(playerID: $0.playerID, calibrationRevision: $0.calibrationRevision, requiredMove: $0.requiredMove,
                        beam: $0.beam, warningTime: $0.warningTime + 9, crossingTime: $0.crossingTime + 9)
                }
                let retry = try LaserEncounter(id: original.id,
                    attemptID: UUID(uuidString: "19000000-0000-4000-8000-000000000001")!, targets: retryTargets)
                add(retryTargets[0].warningTime + pauseOffset, .register(retry))
                let time = retryTargets[0].crossingTime
                add(time + pauseOffset + 0.05, .packet(try packet(encounter: retry, sourceCapture: time + pauseOffset, fault: false)))
                add(time + pauseOffset + 0.351, .tick)
            } else { add(crossing + pauseOffset + 0.351, .tick) }

            let minute = Int(original.targets[0].crossingTime / 60)
            let nextMinute = index + 1 == plan.encounters.count ? 5 : Int(plan.encounters[index + 1].targets[0].crossingTime / 60)
            if nextMinute != minute {
                let at = Double((minute + 1) * 60) + vaultOffset + retryOffset
                let id = UUID(uuidString: String(format: "19100000-0000-4000-8000-%012d", minute))!
                add(at + pauseOffset, .openVault(id))
                if mode == .vaultTimeout && minute == 0 {
                    add(at + pauseOffset + 5, .tick)
                    vaultOffset += 5
                } else {
                    for (playerIndex, player) in PlayerID.allCases.enumerated() {
                        for (buttonIndex, button) in LaserVaultButton.allCases.enumerated() {
                            add(at + pauseOffset + Double(playerIndex * 3 + buttonIndex + 1) * 0.2, .touchVault(id, player, button))
                        }
                    }
                    vaultOffset += 1.2
                }
            }
        }
        add(300 + vaultOffset + retryOffset + pauseOffset + config.diamondTimeDuration + 0.01, .tick)
        steps.sort { $0.sourceTime == $1.sourceTime ? $0.order < $1.order : $0.sourceTime < $1.sourceTime }
        let records = steps.compactMap { step -> ReplayRecord? in
            switch step.action {
            case .packet(let snapshot): ReplayRecord(deliveredAt: step.sourceTime, snapshot: snapshot)
            case .providerFailure: ReplayRecord(deliveredAt: step.sourceTime, status: .failed(.processingFailure))
            default: nil
            }
        }
        let fixture = ReplayFixture(schemaVersion: 2, configuration: base.configuration,
                                    cameraGeometryRevision: base.cameraGeometryRevision, records: records)
        try fixture.validate()
        return Self(fixture: fixture, configuration: config, steps: steps)
    }
}

@MainActor enum FullRoundReplayHarness {
    static func run(_ scenario: FullRoundReplayScenario) async throws -> FullRoundReplayTrace {
        let source = try ReplayBodyInput(fixture: scenario.fixture)
        try await source.start(configuration: scenario.fixture.configuration)
        guard let context = source.currentContext else { throw LaserDataError.invalidValue("replay context") }
        let stream = try source.snapshotStream(generation: scenario.fixture.configuration.sessionGeneration)
        var iterator = stream.makeAsyncIterator()
        var clock = try GameClock(sourceTime: 0)
        var game = try LaserGame(configuration: scenario.configuration, context: context, historyCapacityPerPlayer: 120)
        var registered: [LaserEncounter] = [], results: [ReplayTargetResult] = [], events: [GameEvent] = []
        var consumed: Set<LaserTargetKey> = [], tracked = false, maximum = 0
        do {
            for step in scenario.steps {
                try clock.advance(to: step.sourceTime)
                if tracked && clock.isRunning {
                    for player in PlayerID.allCases {
                        try game.recordTrackedInterval(playerID: player, from: game.gameTime,
                                                       to: clock.gameTime, observedAt: clock.gameTime)
                    }
                }
                switch step.action {
                case .packet:
                    try source.advance(to: step.sourceTime)
                    guard let snapshot = await iterator.next(isolation: MainActor.shared) else {
                        throw LaserDataError.invalidValue("premature replay end")
                    }
                    let reliable = snapshot.players.values.allSatisfy { $0.trackingStatus == .reliable }
                    if let capture = clock.gameTime(forCaptureTime: snapshot.capturedAt) {
                        try game.receive(snapshot, capturedGameTime: capture, arrivedAt: clock.gameTime)
                        if !reliable { game.pause(); try clock.pause(at: step.sourceTime) }
                    }
                    tracked = reliable
                case .resume:
                    try requireLaserValue(tracked, "resume requires reliable recovery packet")
                    try clock.resume(at: step.sourceTime)
                    game.resume()
                default:
                    try game.advance(to: clock.gameTime)
                    if game.roundOutcome == nil {
                        switch step.action {
                        case .register(let encounter): try game.register(encounter); registered.append(encounter)
                        case .openVault(let id): try game.openVault(id: id, at: clock.gameTime)
                        case .touchVault(let id, let player, let button):
                            try game.touchVault(id: id, playerID: player, button: button, validity: .valid,
                                generation: context.sessionGeneration, calibrationRevision: context.calibrationRevisions[player]!, at: clock.gameTime)
                        case .exit: game.exit()
                        case .providerFailure:
                            try source.advance(to: step.sourceTime)
                            try requireLaserValue(source.status == .failed(.processingFailure), "provider failure signal")
                            game.exit(outcome: .technicalInterruption)
                        default: break
                        }
                    }
                }
                for encounter in registered {
                    for target in encounter.targets {
                        let key = LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: target.playerID)
                        guard !consumed.contains(key), let verdict = game.judgement(for: key) else { continue }
                        if case .pending = verdict { continue }
                        consumed.insert(key)
                        var frame: UInt64?
                        if case .selected(let evidence) = game.selection(for: key) { frame = evidence.snapshot.frameID }
                        results.append(ReplayTargetResult(encounterID: encounter.id, playerID: target.playerID,
                                                         judgement: verdict, selectedFrameID: frame))
                    }
                }
                maximum = max(maximum, game.historyCount)
                events.append(contentsOf: game.drainEvents())
                if let summary = game.summary {
                    // Simulate a worker completion/tick arriving after every kind of terminal outcome.
                    let future = max(step.sourceTime, scenario.steps.last?.sourceTime ?? step.sourceTime) + 1
                    try clock.advance(to: future)
                    if let late = scenario.fixture.records.compactMap(\.snapshot).last,
                       let captured = clock.gameTime(forCaptureTime: late.capturedAt) {
                        try game.receive(late, capturedGameTime: captured, arrivedAt: clock.gameTime)
                    }
                    try game.advance(to: clock.gameTime)
                    try requireLaserValue(game.summary == summary && game.teamScore == summary.teamScore
                        && game.teamHealth == summary.remainingTeamHealth && game.drainEvents().isEmpty,
                        "post-terminal data changed the frozen result")
                    await source.stop()
                    return FullRoundReplayTrace(summary: summary, events: events, results: results, maximumHistoryCount: maximum)
                }
            }
            throw LaserDataError.invalidValue("scenario did not terminate")
        } catch {
            await source.stop()
            throw error
        }
    }
}
