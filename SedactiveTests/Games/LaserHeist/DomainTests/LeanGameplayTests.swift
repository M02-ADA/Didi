import Foundation
import Testing
@testable import Sedactive

/// Vertical lasers as gameplay (16 November 2026): LEAN evidence, the boards as game state, beam
/// placement, LEAN verdicts and the five-stage script. Synthetic, deterministic data only.
nonisolated struct LeanGameplayTests {
    // MARK: Fixture

    private struct Rig {
        let input: BodyInputConfiguration
        let geometryRevision: UInt64
        let context: BodyInputContext
        let configuration: LaserRoundConfiguration
        var game: LaserGame
        var frame: UInt64 = 0

        init() throws {
            let script = try LaserReplayScript.load()
            input = script.input.configuration
            geometryRevision = script.input.cameraGeometryRevision
            context = BodyInputContext(sessionGeneration: input.sessionGeneration, cameraGeometryRevision: geometryRevision,
                calibrationRevisions: input.calibrations.mapValues(\.revision), cutovers: [:], isActive: true, wristContact: nil)
            configuration = try LaserFullReplayPlan.roundConfiguration()
            game = try LaserGame(configuration: configuration, context: context, historyCapacityPerPlayer: 240)
            game.configureBoards(try LaserBoardField.make(calibrations: input.calibrations, layout: input.playerPlaneLayout))
        }

        func height(_ player: PlayerID) -> Double {
            LaserLiveRoundGeometryV1.standingHeight(input.calibrations[player]!, layout: input.playerPlaneLayout)
        }

        /// The trunk lean (image units) that steers `player`'s board toward displayed `direction` at
        /// a held 8 % lean (1.2 m/s).
        func lean(_ player: PlayerID, toward direction: Int) -> Double { -Double(direction) * 0.08 * height(player) }

        func sample(_ player: PlayerID, lean: Double?, tracked: Bool = true) throws -> PlayerBodySample {
            let h = height(player)
            func v(_ x: Double) throws -> EstimatedScalar { try EstimatedScalar(value: x, validity: .valid) }
            let missing = try EstimatedScalar(value: nil, validity: tracked ? .missingLandmarks : .identityUncertain)
            guard tracked else {
                return PlayerBodySample(playerID: player, calibrationRevision: input.calibrations[player]!.revision,
                    trackingStatus: .lost, geometry: BodyGeometry(crownY: missing, leftWristY: missing, rightWristY: missing,
                        leftSoleY: missing, rightSoleY: missing, centerX: missing, trunkLeanX: missing),
                    jumpState: JumpState(phase: .unknown, validity: .identityUncertain))
            }
            return PlayerBodySample(playerID: player, calibrationRevision: input.calibrations[player]!.revision,
                trackingStatus: .reliable,
                geometry: BodyGeometry(crownY: try v(h), leftWristY: try v(0.6 * h), rightWristY: try v(0.6 * h),
                    leftSoleY: try v(0), rightSoleY: try v(0), centerX: try v(input.playerPlaneLayout.centerX(for: player)),
                    trunkLeanX: try lean.map(v) ?? missing),
                jumpState: JumpState(phase: .grounded, validity: .valid))
        }

        /// Delivers one frame captured at `time` (arriving 0.05 s later) with each player's lean.
        mutating func frame(at time: Double, leans: [PlayerID: Double?], tracked: Set<PlayerID> = Set(PlayerID.allCases)) throws {
            frame += 1
            var players: [PlayerID: PlayerBodySample] = [:]
            for player in PlayerID.allCases {
                players[player] = try sample(player, lean: leans[player] ?? 0, tracked: tracked.contains(player))
            }
            let snapshot = BodySnapshot(sessionGeneration: input.sessionGeneration, frameID: frame, capturedAt: time,
                                        cameraGeometryRevision: geometryRevision, players: players)
            try game.receive(snapshot, capturedGameTime: time, arrivedAt: time + 0.05)
        }

        func leanEncounter(_ intents: [PlayerID: LaserLeanIntent], crossing: Double, id: Int = 1) throws -> LaserEncounter {
            let uuid = UUID(uuidString: String(format: "1EA00000-0000-4000-8000-%012d", id))!
            return try LaserEncounter(id: uuid, attemptID: uuid, targets: PlayerID.allCases.map { player in
                try LaserTarget(playerID: player, calibrationRevision: input.calibrations[player]!.revision, requiredMove: .lean,
                    beam: LaserBeamBand(lowerY: 0, upperY: height(player)), warningTime: crossing - 3, crossingTime: crossing,
                    lean: LaserLeanBeam(intent: intents[player] ?? .outward))
            })
        }

        func verdict(_ encounter: LaserEncounter, _ player: PlayerID) -> Judgement? {
            game.judgement(for: LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: player))
        }
    }

    /// Plays one LEAN encounter crossing at 6 s: frames every 0.1 s from 0 to 7; `leanFor` decides
    /// each player's lean at each capture time (nil: no usable lean).
    private func play(_ intents: [PlayerID: LaserLeanIntent] = [:],
                      leanFor: (Rig, LaserEncounter, PlayerID, Double) -> Double?,
                      tracked: (PlayerID, Double) -> Bool = { _, _ in true }) throws -> (Rig, LaserEncounter) {
        var rig = try Rig()
        var placed: LaserEncounter?
        for step in 0...70 {
            let t = Double(step) / 10
            if placed == nil, t >= 6 - LaserBoardGeometry.revealLead {
                try rig.game.advance(to: t)
                placed = try rig.game.register(rig.leanEncounter(intents, crossing: 6))
            }
            var leans: [PlayerID: Double?] = [:]
            for player in PlayerID.allCases { leans[player] = placed.map { leanFor(rig, $0, player, t) } ?? 0 }
            try rig.frame(at: t, leans: leans, tracked: Set(PlayerID.allCases.filter { tracked($0, t) }))
        }
        try rig.game.advance(to: 7.5)
        return (rig, placed!)
    }

    /// A player who leans toward their beam's way out from 0.4 s after the warning until clear.
    private func dodger(_ rig: Rig, _ encounter: LaserEncounter, _ player: PlayerID, _ t: Double) -> Double? {
        guard let beam = encounter.targets.first(where: { $0.playerID == player })?.lean, let e = beam.escape,
              let center = beam.centerX, let x = rig.game.boardReadings[player]?.x else { return 0 }
        let clear = LaserLeanPlacement.isClear(boardX: x, beam: beam, margin: rig.configuration.clearanceMargin) == true
        let margin = abs(x - center) - LaserLeanPlacement.clearance(halfWidth: beam.halfWidth, margin: rig.configuration.clearanceMargin)
        return t >= 3.4 && (!clear || margin < 0.1) ? rig.lean(player, toward: e) : 0
    }

    // MARK: LEAN evidence (Edo's body tracking)

    @Test func trunkLeanIsHeadConfirmedUnmirroredAndKeepsTheExistingConfidence() throws {
        let rig = try Rig()
        let calibration = rig.input.calibrations[.player1]!
        func candidate(shoulderX: Double, noseX: Double, shoulderConfidence: Double = 0.9, nose: Bool = true) -> PoseCandidate {
            var joints: [BodyJoint: PoseJoint] = [
                .leftHip: PoseJoint(x: 0.47, y: 0.45, confidence: 0.9), .rightHip: PoseJoint(x: 0.53, y: 0.45, confidence: 0.9),
                .leftShoulder: PoseJoint(x: shoulderX - 0.05, y: 0.65, confidence: shoulderConfidence),
                .rightShoulder: PoseJoint(x: shoulderX + 0.05, y: 0.65, confidence: 0.9)]
            if nose { joints[.nose] = PoseJoint(x: noseX, y: 0.75, confidence: 0.9) }
            return PoseCandidate(candidateID: 1, joints: joints, maskTopImageY: nil, maskBottomImageY: nil,
                                 leftFootBottomImageY: nil, rightFootBottomImageY: nil, maskAssociation: .matched)
        }
        func lean(_ c: PoseCandidate) -> EstimatedScalar {
            BodyMeasurementExtractor.trunkLean(candidate: c, calibration: calibration, id: .player1, layout: rig.input.playerPlaneLayout)
        }
        // A whole-trunk lean toward image +X: the shoulders and, further, the head go that way.
        let toward = lean(candidate(shoulderX: 0.54, noseX: 0.56))
        #expect(toward.validity == .valid && (toward.value ?? 0) > 0)
        let away = lean(candidate(shoulderX: 0.46, noseX: 0.44))
        #expect(abs((away.value ?? 0) + (toward.value ?? 0)) < 1e-9, "mirror-symmetric")
        // An arm reach shifts the shoulder line while the head stays: no lean. A head tilt the other way: none.
        #expect(lean(candidate(shoulderX: 0.53, noseX: 0.5)).value == 0)
        #expect(lean(candidate(shoulderX: 0.53, noseX: 0.48)).value == 0)
        // The existing 0.5 landmark confidence, no new threshold; nothing invented when a landmark is missing.
        #expect(lean(candidate(shoulderX: 0.54, noseX: 0.56, shoulderConfidence: 0.4)).validity == .lowConfidence)
        #expect(lean(candidate(shoulderX: 0.54, noseX: 0.56, nose: false)).validity == .missingLandmarks)
    }

    @Test func aLeanTowardImagePlusXSteersTheBoardToTheDisplayedLeft() throws {
        var rig = try Rig()
        let start = try #require(rig.game.boardReadings[.player1]?.x)
        for step in 0...10 { try rig.frame(at: Double(step) / 10, leans: [.player1: 0.08 * rig.height(.player1)]) }
        let moved = try #require(rig.game.boardReadings[.player1]?.x) - start
        // Each lane is drawn mirrored about its centre, so image +X is screen left: the board goes left.
        #expect(moved < -0.5, "moved \(moved)")
    }

    // MARK: Boards as game state

    @Test func boardsStopAtTheWallsKeepApartAndNeverDriftOnOldEvidence() throws {
        var rig = try Rig()
        // P1 leans hard left into the wall; P2 leans left into P1.
        for step in 0...40 {
            try rig.frame(at: Double(step) / 10, leans: [.player1: rig.lean(.player1, toward: -1) * 3,
                                                         .player2: rig.lean(.player2, toward: -1) * 3])
            let a = try #require(rig.game.boardReadings[.player1]?.x), b = try #require(rig.game.boardReadings[.player2]?.x)
            #expect(a >= LaserBoardGeometry.bounds.lowerBound - 1e-6)
            #expect(b - a >= LaserBoardGeometry.minimumSeparation - 1e-4, "never through each other")
            #expect(abs(rig.game.boardReadings[.player2]?.velocity ?? 0) <= Double(LateralSteering.maximumSpeed) + 1e-6)
        }
        // P2 leans right, then tracking stops: it brakes and holds within the loss hold, no drift.
        for step in 41...50 { try rig.frame(at: Double(step) / 10, leans: [.player2: rig.lean(.player2, toward: 1)]) }
        try rig.game.advance(to: 5.6)
        let held = try #require(rig.game.boardReadings[.player2]?.x)
        try rig.game.advance(to: 9)
        #expect(abs(try #require(rig.game.boardReadings[.player2]?.x) - held) < 1e-9, "no movement on old evidence")
    }

    @Test func boardPathsDoNotDependOnHowOftenGameTimeAdvances() throws {
        var coarse = try Rig(), fine = try Rig()
        for step in 0...30 {
            let t = Double(step) / 10
            let lean: [PlayerID: Double?] = [.player1: step < 12 ? coarse.lean(.player1, toward: 1) : 0]
            try coarse.frame(at: t, leans: lean)
            for k in 1...7 { try fine.game.advance(to: max(fine.game.gameTime, t + 0.05 - 0.1 + Double(k) * 0.0137)) }
            try fine.frame(at: t, leans: lean)
        }
        let a = try #require(coarse.game.boardReadings[.player1]?.x), b = try #require(fine.game.boardReadings[.player1]?.x)
        #expect(abs(a - b) < 0.01, "\(a) vs \(b)")
    }

    // MARK: Placement

    @Test("A beam is always on its board, its way out always has reachable room, or it is voided",
          arguments: [LaserLeanIntent.outward, .inward, .moreRoom, .shift(1), .shift(-1)])
    func placementIsFairFromAnyPlausiblePosition(intent: LaserLeanIntent) throws {
        let b = LaserBoardGeometry.bounds, sep = LaserBoardGeometry.minimumSeparation, margin = 0.005
        let rig = try Rig()
        var placed = 0, voided = 0
        var p1 = b.lowerBound
        while p1 <= b.upperBound - sep {
            var p2 = p1 + sep
            while p2 <= b.upperBound {
                let encounter = try rig.leanEncounter([.player1: intent, .player2: intent], crossing: 10)
                let outcome = try LaserLeanPlacement.place(encounter.targets, boards: [.player1: p1, .player2: p2], margin: margin)
                for player in PlayerID.allCases {
                    let beam = try #require(outcome.beams[player])
                    guard !beam.voided else { voided += 1; continue }
                    placed += 1
                    let x = player == .player1 ? p1 : p2, other = player == .player1 ? p2 : p1
                    let center = try #require(beam.centerX), e = Double(try #require(beam.escape))
                    let clearance = LaserLeanPlacement.clearance(halfWidth: beam.halfWidth, margin: margin)
                    // Standing still is never a CLEAR.
                    #expect(LaserLeanPlacement.isClear(boardX: x, beam: beam, margin: margin) == false)
                    let need = clearance - abs(x - center)
                    #expect(need >= LaserBoardGeometry.minimumDodge - 1e-9 && need <= LaserBoardGeometry.standardDodge + 1e-9)
                    // Moving `need` the way out clears it, inside the walls.
                    let target = x + e * need
                    #expect(LaserLeanPlacement.isClear(boardX: target, beam: beam, margin: margin) == true)
                    #expect(b.contains(target))
                    // Toward the partner only into room it has (a shift's follower: what the leader vacates).
                    let towardPartner = (player == .player1) == (e > 0)
                    if towardPartner {
                        var room = abs(other - x) - sep
                        // Following a partner who must move the same way (a shift, or both the same way).
                        let partnerBeam = outcome.beams[player == .player1 ? .player2 : .player1]
                        if partnerBeam?.escape == beam.escape { room += LaserBoardGeometry.standardDodge }
                        #expect(need <= room + 1e-9, "\(player) at \(x) partner \(other)")
                    }
                }
                p2 += 0.1
            }
            p1 += 0.1
        }
        // Voids happen only where a board is boxed in; they stay rare over every plausible position.
        #expect(Double(voided) / Double(placed + voided) < 0.05, "voided \(voided) of \(placed + voided)")
    }

    @Test func aBoxedInBoardIsVoidedNotFakedAndAShiftTurnsAroundWhenItsLeaderHasNoRoom() throws {
        let rig = try Rig()
        let b = LaserBoardGeometry.bounds, sep = LaserBoardGeometry.minimumSeparation
        // P1 against the left wall, P2 touching it: P1 has nowhere to go.
        let boxed = try LaserLeanPlacement.place(rig.leanEncounter([:], crossing: 10).targets,
            boards: [.player1: b.lowerBound, .player2: b.lowerBound + sep], margin: 0.005)
        #expect(boxed.beams[.player1]?.voided == true && boxed.beams[.player2]?.voided == false)
        // A right shift whose leader (P2) is at the right wall turns into a left shift led by P1.
        let shift = try LaserLeanPlacement.place(rig.leanEncounter([.player1: .shift(1), .player2: .shift(1)], crossing: 10).targets,
            boards: [.player1: b.upperBound - sep - 0.3, .player2: b.upperBound], margin: 0.005)
        #expect(shift.beams[.player1]?.escape == -1 && shift.beams[.player2]?.escape == -1)
    }

    // MARK: LEAN verdicts

    @Test func dodgingTheBeamIsClearAndStandingInItIsHit() throws {
        let (clearRig, clearEncounter) = try play(leanFor: dodger)
        let (hitRig, hitEncounter) = try play(leanFor: { _, _, _, _ in 0 })
        for player in PlayerID.allCases {
            #expect(clearRig.verdict(clearEncounter, player) == .clear, "\(player)")
            #expect(hitRig.verdict(hitEncounter, player) == .hit(.insufficientClearance), "\(player)")
        }
        #expect(clearRig.game.teamScore == 2 * clearRig.configuration.clearTargetPoints)
        #expect(hitRig.game.teamHealth == hitRig.configuration.initialTeamHealth - 2)
        // The beam was placed once, on the board, and the board moved out of it the way it shows.
        for target in clearEncounter.targets {
            let beam = try #require(target.lean)
            #expect(beam.centerX != nil && beam.escape == (target.playerID == .player1 ? -1 : 1), "outward")
        }
    }

    @Test func aGapInTheLeanEvidenceIsUnavailableNeverClearOrHit() throws {
        // The dodge happens, but P1's lean is unseen for 0.4 s just before the crossing.
        let (rig, encounter) = try play(leanFor: { rig, encounter, player, t in
            player == .player1 && t >= 5.2 && t < 5.6 ? nil : self.dodger(rig, encounter, player, t)
        })
        #expect(rig.verdict(encounter, .player1) == .unavailable(.invalidEvidence(.trunkLean, .stale)))
        #expect(rig.verdict(encounter, .player2) == .clear)
        // UNAVAILABLE is technical: no score and no damage for the encounter.
        #expect(rig.game.teamScore == 0 && rig.game.teamHealth == rig.configuration.initialTeamHealth)
        // Untracked at the crossing: UNAVAILABLE too, never the board's last position.
        let (lost, lostEncounter) = try play(leanFor: dodger, tracked: { player, t in !(player == .player2 && t >= 5.5) })
        if case .unavailable = lost.verdict(lostEncounter, .player2) {} else {
            Issue.record("expected UNAVAILABLE, got \(String(describing: lost.verdict(lostEncounter, .player2)))")
        }
    }

    @Test func aVoidedBeamIsUnscoredAndNeverCountsTowardATrackingPause() throws {
        var rig = try Rig()
        // Push P1 against the wall with P2 right next to it, then place a LEAN pair.
        for step in 0...40 {
            try rig.frame(at: Double(step) / 10, leans: [.player1: rig.lean(.player1, toward: -1) * 3,
                                                         .player2: rig.lean(.player2, toward: -1) * 3])
        }
        let encounter = try rig.game.register(rig.leanEncounter([:], crossing: 9))
        #expect(encounter.targets.first { $0.playerID == .player1 }?.lean?.voided == true)
        for step in 41...100 { try rig.frame(at: Double(step) / 10, leans: [:]) }
        try rig.game.advance(to: 10.5)
        let key = LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: .player1)
        #expect(rig.game.judgement(for: key) == .unavailable(.noSafePlacement))
        var policy = LaserUnavailableRetryPolicy()
        let pauses = policy.review([(key, .unavailable(.noSafePlacement))], isPresent: { _ in true })
        #expect(!pauses)
        #expect(policy.total[.player1, default: 0] == 0 && policy.consecutive[.player1, default: 0] == 0)
    }

    // MARK: The five-stage script

    @Test func theFiveStagesKeepTheirShapeRecoveryAndClimax() throws {
        let beats = LaserWaveBeat.fiveMinuteScript()
        #expect(beats.count == 50)
        // The layer gap comes from the round's own timing: the DUCK's action cue opens only after the
        // LEAN's evidence window closes, on the scheduler's step.
        let configuration = try LaserFullReplayPlan.roundConfiguration()
        let profile = try #require(configuration.scheduling?.players[.player1])
        let step = try #require(configuration.scheduling?.searchStep)
        #expect(LaserWaveBeat.layerGap == ((profile.cueLead + configuration.evidenceTiming.windowAfter) / step).rounded(.up) * step)
        let layerLeads = Set(zip(beats, beats.dropFirst()).filter { $0.1.followsLayer }.map(\.0.id))
        var combined: [Int] = [], shifts: [Int] = []
        for stage in 0..<5 {
            let mine = beats.filter { Int($0.nominalCrossingTime / 60) == stage }
            #expect(mine.count == [9, 10, 10, 11, 10][stage])
            combined.append(mine.filter(\.followsLayer).count)
            shifts.append(mine.filter { b in PlayerID.allCases.contains { if case .shift? = b.demand(for: $0)?.intent { true } else { false } } }.count)
            let start = Double(stage * 60)
            // A breather after the countdown or gate, and room before the next gate (more before the Final Vault).
            #expect(mine[0].nominalCrossingTime - 3 - start >= (stage == 0 ? 3 : 2) - 1e-9)
            #expect(start + 60 - mine.last!.nominalCrossingTime >= (stage == 4 ? 7 : 6) - 1e-9)
            // A stage never repeats the same layer (who it is near, and which way).
            let layers = mine.filter { layerLeads.contains($0.id) }.map { b in
                PlayerID.allCases.map { "\(b.demand(for: $0).map { "\($0.intent!)" } ?? "-")" }.joined(separator: "|")
            }
            #expect(Set(layers).count == layers.count, "stage \(stage + 1) repeats a layer: \(layers)")
        }
        #expect(combined == [0, 1, 2, 3, 4] && shifts == [0, 0, 0, 1, 1])
        for (index, beat) in beats.enumerated() {
            let moves = Set(beat.demands.values.map(\.move))
            #expect(moves.count == 1, "\(beat.nominalCrossingTime): one move per encounter")
            if moves != [.lean] {
                // A horizontal laser is one continuous beam: both players, the same move.
                #expect(beat.demands.count == 2, "\(beat.nominalCrossingTime): full width")
            }
            if beat.followsLayer {
                // A combined encounter: a LEAN layer, then the full-width DUCK `layerGap` later.
                let layer = beats[index - 1]
                #expect(moves == [.duck] && Set(layer.demands.values.map(\.move)) == [.lean])
                #expect(abs(beat.nominalCrossingTime - layer.nominalCrossingTime - LaserWaveBeat.layerGap) < 1e-9)
            }
        }
        // Stage 1 opens LEAN OUT, LEAN IN, JUMP, DUCK, one movement at a time.
        #expect(beats.prefix(4).map { $0.demand(for: .player1) } == [.lean(.outward), .lean(.inward), .jump, .duck])
        for player in PlayerID.allCases {
            let moves = beats.compactMap { b in b.demand(for: player).map { (b.nominalCrossingTime, $0.move, b) } }
            for (a, b) in zip(moves, moves.dropFirst()) {
                let gap = b.0 - a.0
                if b.2.followsLayer, a.1 == .lean, abs(gap - LaserWaveBeat.layerGap) < 1e-9 { continue }
                let intoCombined = layerLeads.contains(b.2.id) || b.2.followsLayer
                var minimum = 5.0
                if a.1 != .jump, b.1 != .jump, b.0 >= 180 { minimum = 4.5 } // stages 4-5: DUCK and LEAN 4.5 s apart
                if a.1 == .jump || b.1 == .jump { minimum = a.1 == .jump && b.1 == .duck ? 5 : 5.5 }
                if a.1 == .jump && b.1 == .jump { minimum = 8 }
                if intoCombined { minimum = max(minimum, b.0 >= 180 ? 5 : 5.5) } // familiar by stages 4-5
                if b.0 < 60 { minimum = 6 } // stage 1 is relaxed
                #expect(gap >= minimum - 1e-9, "\(player) \(a.1)@\(a.0) → \(b.1)@\(b.0)")
            }
            // JUMP limits: never consecutive, at least 8 s apart, at most 3 in 30 s.
            let jumps = moves.filter { $0.1 == .jump }.map(\.0)
            for (a, b) in zip(jumps, jumps.dropFirst()) { #expect(b - a >= 8) }
            for a in jumps { #expect(jumps.filter { $0 >= a && $0 < a + 30 }.count <= 3) }
        }
    }

    @Test func aSoloRoundTurnsShiftsIntoItsOwnLeans() throws {
        let rig = try Rig()
        let schedule = try LaserWaveDirector().schedule(script: LaserWaveBeat.fiveMinuteScript(),
            calibrations: [.player1: rig.input.calibrations[.player1]!], layout: rig.input.playerPlaneLayout,
            configuration: rig.configuration, players: [.player1])
        // A vertical beam near P2 only has nothing for a solo P1 to judge: that layer is skipped.
        let p2Only = LaserWaveBeat.fiveMinuteScript().filter { $0.demand(for: .player1) == nil }.count
        #expect(p2Only == 2)
        #expect(schedule.deferred.isEmpty && schedule.encounters.count == 50 - p2Only)
        for target in schedule.encounters.flatMap(\.targets) {
            if case .shift? = target.lean?.intent { Issue.record("solo shift at \(target.crossingTime)") }
        }
    }
}
