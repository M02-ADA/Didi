import Foundation

/// Explicitly synthetic game actions, never a producer attachment or live input fallback.
nonisolated struct LaserFullReplayPlan: Sendable {
    enum Action: Sendable {
        case register(UUID)
        case openVault(UUID, [VaultTarget])
        case normalDiamond(LaserDiamondSpawn, boundary: Double)
        case membership([UUID: [LaserContactHand: LaserContactLocation]])
        case bonusOutside, bonusCollect
    }
    struct VaultTarget: Sendable {
        let id: UUID
        let player: PlayerID
        let button: LaserVaultButton
    }
    struct Step: Sendable {
        let time: Double
        let action: Action
    }
    let steps: [Step]
    let bonusStart: Double
    let normalDiamondCount: Int
    let plannerAfterNormal: LaserDiamondPlanner
    var duration: Double { bonusStart + 10 }

    /// Positions and times are test/demo inputs, not approved camera mapping or comfortable reach.
    /// The complete round's rules: evidence windows, clearance, diamond points and scheduling.
    /// Shared by the complete replay and the live round, so there is one schedule definition.
    static func roundConfiguration() throws -> LaserRoundConfiguration {
        let settings = try LaserSchedulingConfiguration(players: [.player1: .conservativeCandidate,
            .player2: .conservativeCandidate], searchStep: 0.25, maximumSearchSteps: 2000)
        return try LaserRoundConfiguration(
            evidenceTiming: LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25, deliveryAllowance: 0.1),
            clearanceMargin: 0.005, diamondPoints: LaserRoundConfiguration.approvedDiamondPoints, scheduling: settings)
    }

    /// - Parameter scenario: the DEBUG replay variants (all hits, an unpressed first vault);
    ///   `.standard` is the complete replay.
    static func make(base: ReplayFixture, seed: UInt64,
                     scenario: LaserReplayScript.Scenario = .standard) throws -> LaserReplayScript {
        let config = try roundConfiguration()
        let wave = try LaserWaveDirector().schedule(script: LaserWaveBeat.fiveMinuteScript(),
            calibrations: base.configuration.calibrations, layout: base.configuration.playerPlaneLayout, configuration: config)
        try requireLaserValue(wave.deferred.isEmpty && wave.encounters.count == 50, "full replay wave plan")
        let layout = base.configuration.playerPlaneLayout
        let placements = try PlayerID.allCases.flatMap { player in
            guard let calibration = base.configuration.calibrations[player] else {
                throw LaserDataError.invalidValue("missing replay calibration for diamond placement")
            }
            return try LaserLiveRoundGeometryV1.diamondPlacements(player: player, lane: layout.centerX(for: player),
                height: LaserLiveRoundGeometryV1.standingHeight(calibration, layout: layout))
        }
        var planner = try LaserDiamondPlanner(seed: seed, placements: placements, approachLead: 0.5, passageDuration: 1)
        var steps: [Step] = [], encounters: [LaserEncounter] = [], records: [ReplayRecord] = []
        var frame: UInt64 = 0, diamondCount = 0
        func packet(_ encounter: LaserEncounter, capturedAt: Double, standing: Bool = false) throws -> BodySnapshot {
            frame += 1
            var samples: [PlayerID: PlayerBodySample] = [:]
            for target in encounter.targets {
                let calibration = base.configuration.calibrations[target.playerID]!
                let height = calibration.mapping.gameY(imageY: calibration.standingCrownImageY,
                                                       layout: base.configuration.playerPlaneLayout)
                let sole = !standing && target.requiredMove == .jump ? target.beam.upperY + config.clearanceMargin + height * 0.001 : 0
                func scalar(_ value: Double) throws -> EstimatedScalar { try EstimatedScalar(value: value, validity: .valid) }
                let crown = !standing && target.requiredMove == .duck ? target.beam.lowerY - config.clearanceMargin - height * 0.01 : height + sole
                let wrist = !standing && target.requiredMove == .duck ? target.beam.lowerY - config.clearanceMargin - height * 0.02 : height * 0.6 + sole
                samples[target.playerID] = try PlayerBodySample(playerID: target.playerID,
                    calibrationRevision: target.calibrationRevision, trackingStatus: .reliable,
                    geometry: BodyGeometry(crownY: scalar(crown), leftWristY: scalar(wrist), rightWristY: scalar(wrist),
                        leftSoleY: scalar(sole), rightSoleY: scalar(sole),
                        centerX: scalar(base.configuration.playerPlaneLayout.centerX(for: target.playerID))),
                    jumpState: JumpState(phase: !standing && target.requiredMove == .jump ? .airborne : .grounded, validity: .valid))
            }
            return BodySnapshot(sessionGeneration: base.configuration.sessionGeneration, frameID: frame,
                capturedAt: capturedAt, cameraGeometryRevision: base.cameraGeometryRevision, players: samples)
        }
        records.append(ReplayRecord(deliveredAt: 0.02,
            snapshot: try packet(wave.encounters[0], capturedAt: 0.01, standing: true)))
        for minute in 0..<5 {
            let offset = Double(minute) * 1.2
            let start = Double(minute * 60) + offset, boundary = start + 60
            for original in wave.encounters where Int(original.targets[0].crossingTime / 60) == minute {
                let targets = try original.targets.map {
                    try LaserTarget(playerID: $0.playerID, calibrationRevision: $0.calibrationRevision,
                        requiredMove: $0.requiredMove, beam: $0.beam, warningTime: $0.warningTime + offset,
                        crossingTime: $0.crossingTime + offset)
                }
                let encounter = try LaserEncounter(id: original.id, attemptID: original.attemptID, targets: targets)
                encounters.append(encounter)
                steps.append(Step(time: targets[0].warningTime, action: .register(encounter.id)))
                records.append(ReplayRecord(deliveredAt: targets[0].crossingTime + 0.05,
                    snapshot: try packet(encounter, capturedAt: targets[0].crossingTime,
                                         standing: scenario == .healthDepleted)))
                // Return to neutral outside the judgment window; never hold a synthetic jump for the next five seconds.
                records.append(ReplayRecord(deliveredAt: targets[0].crossingTime + 0.65,
                    snapshot: try packet(encounter, capturedAt: targets[0].crossingTime + 0.6, standing: true)))
            }
            let diamonds = try planner.normalMinute(minute, from: start, until: boundary)
            diamondCount += diamonds.count
            for diamond in diamonds {
                let player = PlayerID.allCases.first { diamond.eligiblePlayers.contains($0) }!
                let hand = LaserContactHand(playerID: player, wrist: .left)
                steps.append(Step(time: diamond.spawnedAt, action: .normalDiamond(diamond, boundary: boundary)))
                steps.append(Step(time: diamond.entry + 0.05, action: .membership([diamond.id: [hand: .outside]])))
                steps.append(Step(time: diamond.entry + 0.15, action: .membership([diamond.id: [hand: .inside]])))
            }
            let vaultID = UUID(uuidString: String(format: "D1B00000-0000-4000-8000-%012d", minute + 1))!
            let buttons = PlayerID.allCases.enumerated().flatMap { playerIndex, player in
                LaserVaultButton.allCases.enumerated().map { buttonIndex, button in
                    VaultTarget(id: UUID(uuidString: String(format: "D1C00000-0000-4000-8000-%012d",
                        1 + minute * 6 + playerIndex * 3 + buttonIndex))!, player: player, button: button)
                }
            }
            steps.append(Step(time: boundary, action: .openVault(vaultID, buttons)))
            // Leave the first vault untouched so the real deadline ends the round.
            if scenario == .vaultTimeout { break }
            for (index, button) in buttons.enumerated() {
                let time = boundary + Double(index + 1) * 0.2
                let hand = LaserContactHand(playerID: button.player, wrist: .left)
                steps.append(Step(time: time - 0.05, action: .membership([button.id: [hand: .outside]])))
                steps.append(Step(time: time, action: .membership([button.id: [hand: .inside]])))
            }
        }
        let bonusStart = 306.0
        steps.append(Step(time: bonusStart + 1, action: .bonusOutside))
        steps.append(Step(time: bonusStart + 1.1, action: .bonusCollect))
        steps.append(Step(time: bonusStart + 2, action: .bonusOutside))
        steps.append(Step(time: bonusStart + 2.1, action: .bonusCollect))
        steps = steps.enumerated().sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }.map(\.element)
        records.sort { $0.deliveredAt < $1.deliveredAt }
        let fixture = ReplayFixture(schemaVersion: 2, configuration: base.configuration,
            cameraGeometryRevision: base.cameraGeometryRevision, records: records)
        try fixture.validate()
        return LaserReplayScript(input: fixture, encounters: encounters, configuration: config,
            fullRound: Self(steps: steps, bonusStart: bonusStart, normalDiamondCount: diamondCount,
                            plannerAfterNormal: planner))
    }
}
