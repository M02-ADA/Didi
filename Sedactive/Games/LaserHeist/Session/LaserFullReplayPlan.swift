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
    var duration: Double { bonusStart + LaserRoundConfiguration.defaultDiamondTimeDuration }

    /// Positions and times are test/demo inputs, not approved camera mapping or comfortable reach.
    /// The complete round's rules: evidence windows, clearance, diamond points and scheduling.
    /// Shared by the complete replay and the live round, so there is one schedule definition.
    static func roundConfiguration() throws -> LaserRoundConfiguration {
        let settings = try LaserSchedulingConfiguration(players: [.player1: .fiveStageCandidate,
            .player2: .fiveStageCandidate], searchStep: 0.25, maximumSearchSteps: 2000)
        return try LaserRoundConfiguration(
            evidenceTiming: LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25, deliveryAllowance: 0.1),
            clearanceMargin: 0.005, diamondPoints: LaserRoundConfiguration.approvedDiamondPoints, scheduling: settings)
    }

    /// The encounters with their LEAN beams as the plan's synthetic players expect the game to
    /// place them (tests compare the game's own placements with these).
    var predictedEncounters: [LaserEncounter] = []

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
        let passagePlacements = try PlayerID.allCases.flatMap { player in
            guard let calibration = base.configuration.calibrations[player] else {
                throw LaserDataError.invalidValue("missing replay calibration for diamond placement")
            }
            return try LaserLiveRoundGeometryV1.passagePlacements(player: player, lane: layout.centerX(for: player),
                height: LaserLiveRoundGeometryV1.standingHeight(calibration, layout: layout))
        }
        var planner = try LaserDiamondPlanner(seed: seed, placements: placements, approachLead: 0.5, passageDuration: 1,
                                             passagePlacements: passagePlacements)
        var steps: [Step] = [], encounters: [LaserEncounter] = []
        var diamondCount = 0
        let standing = scenario == .healthDepleted
        // Each minute's encounters at their replay times (a 1.2 s gate per minute), unplaced.
        var timeline: [(encounter: LaserEncounter, registerAt: Double)] = []
        var vaultWindows: [ClosedRange<Double>] = []
        for minute in 0..<5 {
            let offset = Double(minute) * 1.2
            let start = Double(minute * 60) + offset, boundary = start + 60
            for original in wave.encounters where Int(original.targets[0].crossingTime / 60) == minute {
                let encounter = try LaserEncounter(id: original.id, attemptID: original.attemptID,
                                                   targets: original.targets.map { try $0.shifted(by: offset) },
                                                   roster: Set(original.targets.map(\.playerID)))
                timeline.append((encounter, LaserLiveRoundDirector.registrationTime(encounter)))
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
            vaultWindows.append(boundary...(boundary + Double(buttons.count) * 0.2))
        }
        // The synthetic players: upright on their lanes; at each horizontal crossing the move asked
        // for; for each LEAN beam a lean toward its way out from 0.4 s after the warning until the
        // board has travelled past it (with the SAME boards and placement rules the game runs, so
        // the replay's boards are the game's), observed every 0.1 s from the reveal to the crossing.
        let roster = PlayerID.allCases
        let heights = base.configuration.calibrations.mapValues {
            LaserLiveRoundGeometryV1.standingHeight($0, layout: layout)
        }
        var field = try LaserBoardField.make(calibrations: base.configuration.calibrations, layout: layout)
        let delivery = 0.05, packetStep = 0.1
        var captures: Set<Double> = [0.01]
        func key(_ t: Double) -> Double { (t * 1_000_000).rounded() / 1_000_000 }
        for (encounter, registerAt) in timeline {
            let crossing = encounter.targets[0].crossingTime
            captures.insert(key(crossing)); captures.insert(key(crossing + 0.6))
            if encounter.targets.contains(where: { $0.requiredMove == .lean }) {
                var t = registerAt
                while t <= crossing + 0.3 + 1e-9 { captures.insert(key(t)); t += packetStep }
            }
        }
        // Body packets: each player's horizontal move exactly at its crossing, upright otherwise.
        var frame: UInt64 = 0
        var horizontal: [Double: [PlayerID: LaserTarget]] = [:]
        for encounter in timeline.map(\.encounter) {
            for target in encounter.targets where target.requiredMove != .lean {
                horizontal[key(target.crossingTime), default: [:]][target.playerID] = target
            }
        }
        func packet(at t: Double, lean: [PlayerID: Double]) throws -> BodySnapshot {
            frame += 1
            var samples: [PlayerID: PlayerBodySample] = [:]
            for player in roster {
                let calibration = base.configuration.calibrations[player]!
                let height = heights[player]!
                let target = standing ? nil : horizontal[key(t)]?[player]
                func scalar(_ value: Double) throws -> EstimatedScalar { try EstimatedScalar(value: value, validity: .valid) }
                let sole = target?.requiredMove == .jump ? target!.beam.upperY + config.clearanceMargin + height * 0.001 : 0
                let crown = target?.requiredMove == .duck ? target!.beam.lowerY - config.clearanceMargin - height * 0.01 : height + sole
                let wrist = target?.requiredMove == .duck ? target!.beam.lowerY - config.clearanceMargin - height * 0.02 : height * 0.6 + sole
                samples[player] = try PlayerBodySample(playerID: player, calibrationRevision: calibration.revision,
                    trackingStatus: .reliable,
                    geometry: BodyGeometry(crownY: scalar(crown), leftWristY: scalar(wrist), rightWristY: scalar(wrist),
                        leftSoleY: scalar(sole), rightSoleY: scalar(sole), centerX: scalar(layout.centerX(for: player)),
                        trunkLeanX: scalar(lean[player] ?? 0)),
                    jumpState: JumpState(phase: target?.requiredMove == .jump ? .airborne : .grounded, validity: .valid))
            }
            return BodySnapshot(sessionGeneration: base.configuration.sessionGeneration, frameID: frame,
                capturedAt: t, cameraGeometryRevision: base.cameraGeometryRevision, players: samples)
        }
        // Lean per player per capture time, decided in time order against the simulated boards.
        var leans: [Double: [PlayerID: Double]] = [:]
        var pending = timeline.sorted { $0.registerAt < $1.registerAt }
        var placedByID: [UUID: LaserEncounter] = [:]
        var dodges: [(player: PlayerID, escape: Int, start: Double, until: Double, from: Double?, travel: Double)] = []
        var simTime = 0.0
        // The game's vault dock assist runs while a vault is open: integrate in pieces split at
        // each vault's open and last press, with the assist on exactly inside.
        func simulate(to time: Double) {
            guard time > simTime else { return }
            let edges = vaultWindows.flatMap { [$0.lowerBound, $0.upperBound] }.filter { $0 > simTime && $0 < time }.sorted()
            for end in edges + [time] {
                let mid = (simTime + end) / 2
                field.dockAssist = vaultWindows.contains { $0.contains(mid) }
                field.advance(to: end)
                simTime = end
            }
        }
        for t in captures.sorted() {
            // Placements due before this packet arrives, in order (the game places at registration).
            let arrival = t + (t == 0.01 ? 0.01 : delivery)
            while let next = pending.first, next.registerAt <= arrival {
                pending.removeFirst()
                simulate(to: next.registerAt)
                var positions: [PlayerID: Double] = [:]
                for player in roster { positions[player] = field.x(player) }
                let outcome = try LaserLeanPlacement.place(next.encounter.targets, boards: positions,
                                                           margin: config.clearanceMargin)
                let placed = try LaserEncounter(id: next.encounter.id, attemptID: next.encounter.attemptID,
                    targets: next.encounter.targets.map { target in
                        guard let beam = outcome.beams[target.playerID] else { return target }
                        return try target.placing(beam)
                    }, roster: Set(next.encounter.targets.map(\.playerID)))
                placedByID[placed.id] = placed
                for target in placed.targets {
                    guard let beam = target.lean, let escape = beam.escape, let center = beam.centerX,
                          let x = positions[target.playerID], !standing else { continue }
                    // Travel until clear of the beam, plus room for braking and rounding.
                    let travel = LaserLeanPlacement.clearance(halfWidth: beam.halfWidth, margin: config.clearanceMargin)
                        - abs(x - center) + 0.12
                    dodges.append((target.playerID, escape, target.warningTime + 0.4, target.crossingTime - 0.25, nil, travel))
                }
            }
            simulate(to: arrival)
            var lean: [PlayerID: Double] = [:]
            for index in dodges.indices where dodges[index].start <= t && t <= dodges[index].until {
                let player = dodges[index].player
                let x = field.x(player) ?? 0
                if dodges[index].from == nil { dodges[index].from = x }
                let moved = (x - dodges[index].from!) * Double(dodges[index].escape)
                if moved < dodges[index].travel {
                    // Lean toward the way out: displayed direction `escape`, so image X the other way.
                    lean[player] = -Double(dodges[index].escape) * 0.08 * heights[player]!
                }
            }
            leans[t] = lean
            let snapshot = try packet(at: t, lean: lean)
            field.receive(snapshot.players[.player1], player: .player1,
                          calibrationRevision: base.configuration.calibrations[.player1]?.revision,
                          capturedAt: t, arrivedAt: arrival)
            field.receive(snapshot.players[.player2], player: .player2,
                          calibrationRevision: base.configuration.calibrations[.player2]?.revision,
                          capturedAt: t, arrivedAt: arrival)
        }
        // The game places each LEAN beam itself from its own boards; the plan's prediction (the
        // same rules on the same packets) is kept for tests.
        for (encounter, registerAt) in timeline {
            encounters.append(encounter)
            steps.append(Step(time: registerAt, action: .register(encounter.id)))
        }
        let predicted = timeline.map { placedByID[$0.encounter.id] ?? $0.encounter }
        frame = 0
        var records: [ReplayRecord] = []
        for t in captures.sorted() {
            records.append(ReplayRecord(deliveredAt: t + (t == 0.01 ? 0.01 : delivery), snapshot: try packet(at: t, lean: leans[t] ?? [:])))
        }
        let bonusStart = 306.0
        steps.append(Step(time: bonusStart + 1, action: .bonusOutside))
        steps.append(Step(time: bonusStart + 1.1, action: .bonusCollect))
        steps.append(Step(time: bonusStart + 2, action: .bonusOutside))
        steps.append(Step(time: bonusStart + 2.1, action: .bonusCollect))
        steps = steps.enumerated().sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }.map(\.element)
        let fixture = ReplayFixture(schemaVersion: 2, configuration: base.configuration,
            cameraGeometryRevision: base.cameraGeometryRevision, records: records)
        try fixture.validate()
        return LaserReplayScript(input: fixture, encounters: encounters, configuration: config,
            fullRound: Self(steps: steps, bonusStart: bonusStart, normalDiamondCount: diamondCount,
                            plannerAfterNormal: planner, predictedEncounters: predicted))
    }
}
