#if DEBUG
import Foundation
import Testing
@testable import Sedactive

/// DEBUG Solo Test: one real player (P1) through the same tracker, calibration, round director
/// and game. Nothing is ever created for P2, and the co-op path is unchanged.
@MainActor struct SoloTestModeTests {
    typealias F = TrackingFixtures

    private static func soloTracker() throws -> PlayerTracker {
        var tracker = try PlayerTracker(policy: F.policy())
        try tracker.reset(context: F.context(), controlRevision: 1)
        try tracker.armBinding(controlRevision: 1, solo: true)
        return tracker
    }

    @Test func soloAcquiresExactlyOnePersonIntoP1AndLeavesP2Unbound() throws {
        var tracker = try Self.soloTracker()
        // Standing in the middle is fine in solo (co-op needs each player on their own side).
        let person = [F.candidate(10, x: 0.5)]
        var result = try tracker.process(F.input(1, 1, person))
        #expect(result.player1.state == .unbound && result.player1.reason == .acquiring)
        result = try tracker.process(F.input(2, 1.25, person))
        #expect(result.player1.state == .tracking && result.player1.candidateID == 10)
        #expect(result.player2.state == .unbound && result.player2.candidateID == nil && !result.player2.requiresRebind,
                "no teammate is fabricated")
        // P1 keeps being tracked frame to frame; P2 never receives anyone.
        for i in 3...6 {
            result = try tracker.process(F.input(UInt64(i), 1.25 + Double(i) * 0.1, [F.candidate(10, x: 0.5 + Double(i) * 0.005)]))
            #expect(result.player1.state == .tracking && result.player2.state == .unbound)
        }
    }

    /// iPad, 11 November 2026: walking to the iPad lost P1 for good, so the mascot froze for the
    /// rest of the round. In a Solo Test a lost P1 is re-linked by the solo linking rule (exactly
    /// one person, held for the dwell) in the same binding; two people never re-link anyone.
    @Test func aLostSoloPlayerIsRelinkedOnlyWhenAloneInView() throws {
        var tracker = try Self.soloTracker()
        var t = 1.0, frame: UInt64 = 0
        func step(_ people: [PoseCandidate]) throws -> PlayerTrackingSnapshot {
            frame += 1; t += 0.1
            return try tracker.process(F.input(frame, t, people))
        }
        for _ in 0..<4 { _ = try step([F.candidate(10, x: 0.5)]) }
        #expect(tracker.snapshot.player1.state == .tracking)
        // Out of view long enough to be lost (recovery window).
        for _ in 0..<30 { _ = try step([]) }
        #expect(tracker.snapshot.player1.state == .lost && tracker.snapshot.player1.requiresRebind)
        // Two people: still lost, no guessing.
        for _ in 0..<5 { _ = try step(F.pair) }
        #expect(tracker.snapshot.player1.state == .lost)
        // Back alone, somewhere else: one dwell later P1 is tracked again, rebind cleared.
        var r = try step([F.candidate(30, x: 0.3)])
        #expect(r.player1.state == .lost)
        for _ in 0..<3 { r = try step([F.candidate(30, x: 0.3)]) }
        #expect(r.player1.state == .tracking && r.player1.candidateID == 30 && !r.player1.requiresRebind)
        #expect(r.player2.state == .unbound, "no teammate is fabricated")
    }

    @Test func aLostCoopPlayerIsNeverRelinkedByTheTracker() throws {
        var tracker = try PlayerTracker(policy: F.policy())
        try tracker.reset(context: F.context(), controlRevision: 1)
        try tracker.armBinding(controlRevision: 1)
        var t = 1.0, frame: UInt64 = 0
        for _ in 0..<4 { frame += 1; t += 0.1; _ = try tracker.process(F.input(frame, t, F.pair)) }
        #expect(tracker.snapshot.player1.state == .tracking)
        for _ in 0..<30 { frame += 1; t += 0.1; _ = try tracker.process(F.input(frame, t, [])) }
        for _ in 0..<6 { frame += 1; t += 0.1; _ = try tracker.process(F.input(frame, t, [F.candidate(30, x: 0.3)])) }
        #expect(tracker.snapshot.player1.state == .lost, "co-op identity loss still needs a new setup")
    }

    @Test func soloRefusesTwoPeopleAndCoopStillRefusesOne() throws {
        var solo = try Self.soloTracker()
        for i in 1...4 {
            let r = try solo.process(F.input(UInt64(i), Double(i) * 0.25, F.pair))
            #expect(r.player1.state == .unbound && r.player1.reason == .acquisitionRefused, "two people: no guessing")
        }
        var coop = try F.tracker()
        for i in 1...4 {
            let r = try coop.process(F.input(UInt64(i), Double(i) * 0.25, [F.candidate(10, x: 0.75)]))
            #expect(r.player1.state == .unbound && r.player2.state == .unbound, "co-op still needs two")
        }
    }

    @Test func soloCalibrationMeasuresP1OnlyAndKeepsProvenance() throws {
        let (f, _, _) = try LiveVisionFixtures.sessionFixture()
        var session = CalibrationSession()
        let request = try #require(f.gate.snapshot.requestID)
        _ = try session.request(id: UUID(), source: f.context, revision: f.gate.snapshot.revision,
            bindingRequest: request, at: 0.125, roster: [.player1])
        let stamp = try #require(session.admission)
        for i in 0..<10 {
            let pose = try f.result(UInt64(i + 3), Double(i) * 0.25 + 0.25, LiveVisionFixtures.standingPair)
            let started = session.beginSample(stamp, source: pose.source, at: pose.source.capturedAt)
            try #require(started)
            var mask = LiveVisionFixtures.withAnatomy(LiveVisionFixtures.mask(pose), pose: pose, revision: stamp.bindingRevision)
            mask.anatomy.removeValue(forKey: .player2) // whatever P2's slot shows is never read
            session.observe(mask, pose: pose, association: LiveVisionFixtures.association(pose, revision: stamp.bindingRevision),
                            stamp: stamp, at: pose.source.capturedAt + 0.01)
        }
        let candidate = try #require(session.candidate)
        #expect(Set(candidate.players.keys) == [.player1] && candidate.acceptance == .stableEstimate)
        #expect(session.players[.player2] == nil, "P2 is not measured at all")
        var body = LiveBodyInputState()
        var configuration = LiveVisionFixtures.configuration(f.context.generation)
        configuration.soloPlayer = .player1
        try body.configure(configuration, source: f.context)
        body.calibration = session
        let context = try body.accept(candidateID: candidate.id, expectedRevision: 0, at: 3)
        #expect(Set(context.calibrationRevisions.keys) == [.player1], "no calibration for P2, ever")
        #expect(body.configuration?.calibrations[.player1]?.referenceQuality == .experimental)
    }

    @Test func coopCalibrationStillNeedsBothPlayers() throws {
        let (f, initial, stamp) = try LiveVisionFixtures.sessionFixture()
        var session = initial
        for i in 0..<10 {
            let pose = try f.result(UInt64(i + 3), Double(i) * 0.25 + 0.25, LiveVisionFixtures.standingPair)
            let started = session.beginSample(stamp, source: pose.source, at: pose.source.capturedAt)
            try #require(started)
            var mask = LiveVisionFixtures.withAnatomy(LiveVisionFixtures.mask(pose), pose: pose, revision: stamp.bindingRevision)
            mask.anatomy.removeValue(forKey: .player2)
            session.observe(mask, pose: pose, association: LiveVisionFixtures.association(pose, revision: stamp.bindingRevision),
                            stamp: stamp, at: pose.source.capturedAt + 0.01)
        }
        #expect(session.candidate == nil && session.players[.player1]?.samples == 10)
    }

    @Test func encountersAreCoopUnlessExplicitlySoloP1() throws {
        func target(_ player: PlayerID) throws -> LaserTarget {
            try LaserTarget(playerID: player, calibrationRevision: 1, requiredMove: .duck,
                            beam: .init(lowerY: 1, upperY: 1.1), warningTime: 1, crossingTime: 3)
        }
        #expect(throws: LaserDataError.self) { try LaserEncounter(id: UUID(), attemptID: UUID(), targets: [target(.player1)]) }
        #expect(throws: LaserDataError.self) {
            try LaserEncounter(id: UUID(), attemptID: UUID(), targets: [target(.player2)], roster: [.player2])
        }
        let solo = try LaserEncounter(id: UUID(), attemptID: UUID(), targets: [target(.player1)], roster: [.player1])
        #expect(solo.targets.map(\.playerID) == [.player1])
    }

    private static func soloRound(segment: Double = 15) throws
        -> (director: LaserLiveRoundDirector, game: LaserGame, context: BodyInputContext, revision: UInt64) {
        let script = try LaserReplayScript.load()
        let input = script.input.configuration
        let calibration = try #require(input.calibrations[.player1])
        let configuration = try LaserFullReplayPlan.roundConfiguration()
        let director = try LaserLiveRoundDirector(calibrations: [.player1: calibration], layout: input.playerPlaneLayout,
            configuration: configuration, seed: 3, segmentLength: segment, roster: [.player1])
        let context = BodyInputContext(sessionGeneration: input.sessionGeneration,
            cameraGeometryRevision: script.input.cameraGeometryRevision,
            calibrationRevisions: [.player1: calibration.revision], cutovers: [:], isActive: true, wristContact: nil)
        var game = try LaserGame(configuration: configuration, context: context, historyCapacityPerPlayer: 120)
        game.soloPracticePlayer = .player1
        return (director, game, context, calibration.revision)
    }

    /// The whole DEBUG Solo Test round on the same schedule and game: P1's lasers, a P1-only
    /// gate after every minute (three P1 presses open it), Diamond Time after the fifth, then
    /// the round completes with a summary for Results. No body evidence is given, so no laser
    /// is CLEAR and nothing is scored from movement.
    @Test func soloRoundPlaysEveryGateThroughDiamondTimeToResults() throws {
        var (director, game, context, revision) = try Self.soloRound()
        #expect(director.isSolo && director.baseEncounters.allSatisfy { $0.targets.map(\.playerID) == [.player1] })
        var registered = 0, gates: [Double] = [], diamonds: [LaserDiamondSpawn] = []
        var time = 0.0
        while time < 200, game.roundOutcome == nil {
            time += 0.05
            while let due = try director.nextDue(through: time, game: game) {
                try game.advance(to: max(game.gameTime, due.time))
                switch due.action {
                case .register(let encounter): try game.register(encounter); registered += 1
                case .normalDiamond(let spawn, let boundary):
                    try game.spawnNormalDiamonds([spawn], beforeVaultAt: boundary); diamonds.append(spawn)
                case .openVault(let id, let zones):
                    #expect(zones.count == 3 && zones.allSatisfy { $0.playerID == .player1 }, "P1's three buttons only")
                    try game.openVault(id: id, at: game.gameTime)
                    gates.append(game.gameTime)
                    // Two presses do not open it; the third (P1's last) does.
                    try game.touchVaultBatch(id: id, contacts: [.init(playerID: .player1, button: .top, calibrationRevision: revision),
                        .init(playerID: .player1, button: .middle, calibrationRevision: revision)],
                        generation: context.sessionGeneration, at: game.gameTime + 0.5)
                    #expect(game.roundPhase == .vault && game.vault?.opened == false)
                    try game.touchVaultBatch(id: id, contacts: [.init(playerID: .player1, button: .bottom, calibrationRevision: revision)],
                        generation: context.sessionGeneration, at: game.gameTime + 0.5)
                    #expect(game.vault?.opened == true && game.missionProgress == gates.count)
                }
            }
            if game.roundPhase == .diamondTime, !game.hasStartedDiamondTimeDiamonds {
                try game.startDiamondTimeDiamonds(try director.diamondTimeSpawns(at: game.gameTime,
                    deadline: game.gameTime + LaserRoundConfiguration.defaultDiamondTimeDuration))
            }
            try game.advance(to: max(time, game.gameTime))
        }
        #expect(gates.count == 5 && game.missionProgress == 5 && registered == director.baseEncounters.count)
        #expect(game.roundOutcome == .completed)
        let summary = try #require(game.summary, "Results has a summary")
        #expect(summary.vaultsOpened == 5 && summary.teamScore == 0)
        #expect(diamonds.allSatisfy { $0.eligiblePlayers == [.player1] })
        #expect(game.playerStats[.player1]?.cleared == 0, "no evidence: never CLEAR")
        #expect(game.playerStats[.player2] == nil)
    }

    /// Co-op is unchanged: P1's three presses never open a co-op vault on their own.
    @Test func coopVaultStillNeedsBothPlayers() throws {
        let script = try LaserReplayScript.load()
        let input = script.input.configuration
        let context = BodyInputContext(sessionGeneration: input.sessionGeneration,
            cameraGeometryRevision: script.input.cameraGeometryRevision,
            calibrationRevisions: [.player1: 1, .player2: 1], cutovers: [:], isActive: true, wristContact: nil)
        var game = try LaserGame(configuration: try LaserFullReplayPlan.roundConfiguration(), context: context,
                                 historyCapacityPerPlayer: 120)
        #expect(game.soloPracticePlayer == nil)
        let id = UUID()
        try game.openVault(id: id, at: 1)
        try game.touchVaultBatch(id: id, contacts: LaserVaultButton.allCases.map { .init(playerID: .player1, button: $0, calibrationRevision: 1) },
                                 generation: input.sessionGeneration, at: 1.5)
        #expect(game.vault?.opened == false && game.missionProgress == 0)
        try game.touchVaultBatch(id: id, contacts: LaserVaultButton.allCases.map { .init(playerID: .player2, button: $0, calibrationRevision: 1) },
                                 generation: input.sessionGeneration, at: 2)
        #expect(game.vault?.opened == true && game.missionProgress == 1)
    }

    /// "Skip to Next Gate" shortens the current minute only: unregistered lasers and diamonds
    /// are dropped (never judged or scored), registered ones are still judged, the gate comes
    /// due five game seconds later, and repeated taps, an open gate or a co-op round change nothing.
    @Test func skipToNextGateShortensTheMinuteWithoutScoring() throws {
        var (director, game, _, _) = try Self.soloRound(segment: 60)
        var time = 0.0, registered = 0
        func run(until end: Double) throws -> (id: UUID, at: Double)? {
            while time < end {
                time += 0.05
                while let due = try director.nextDue(through: time, game: game) {
                    try game.advance(to: max(game.gameTime, due.time))
                    switch due.action {
                    case .register(let e): try game.register(e); registered += 1
                    case .normalDiamond(let s, let b): try game.spawnNormalDiamonds([s], beforeVaultAt: b)
                    case .openVault(let id, _): try game.openVault(id: id, at: game.gameTime); return (id, game.gameTime)
                    }
                }
                try game.advance(to: time)
            }
            return nil
        }
        _ = try run(until: 2)
        let skipped = director.debugSkipToVault(game: game)
        let skip = try #require(skipped)
        #expect(skip.droppedLasers > 0 && abs(skip.vaultAt - (game.gameTime + LaserLiveRoundDirector.debugSkipLead)) < 1e-9)
        let again = director.debugSkipToVault(game: game)
        #expect(again == nil, "a second tap changes nothing")
        let gate = try run(until: 30)
        let opened = try #require(gate, "the gate opens soon after the skip, not at 60 s")
        #expect(opened.at >= skip.vaultAt - 1e-9 && opened.at < skip.vaultAt + 5)
        #expect(registered + skip.droppedLasers == director.baseEncounters.filter {
            Int($0.targets[0].crossingTime / 60) == 0 }.count, "every minute-1 laser is either played or dropped")
        #expect(game.teamScore == 0 && game.playerStats[.player1]?.cleared ?? 0 == 0, "nothing scored by skipping")
        let during = director.debugSkipToVault(game: game)
        #expect(during == nil, "no skip while the gate is open")
        // Co-op directors never skip.
        let script = try LaserReplayScript.load()
        let input = script.input.configuration
        let coop = try LaserLiveRoundDirector(calibrations: input.calibrations, layout: input.playerPlaneLayout,
            configuration: try LaserFullReplayPlan.roundConfiguration(), seed: 3)
        var coopDirector = coop
        let coopSkip = coopDirector.debugSkipToVault(game: game)
        #expect(coopSkip == nil)
    }

    @Test func aSoloLaserHitCostsHealthFromP1Alone() throws {
        let script = try LaserReplayScript.load()
        let input = script.input.configuration
        let configuration = try LaserFullReplayPlan.roundConfiguration()
        let context = BodyInputContext(sessionGeneration: input.sessionGeneration,
            cameraGeometryRevision: script.input.cameraGeometryRevision,
            calibrationRevisions: [.player1: 1], cutovers: [:], isActive: true, wristContact: nil)
        var game = try LaserGame(configuration: configuration, context: context, historyCapacityPerPlayer: 120)
        let target = try LaserTarget(playerID: .player1, calibrationRevision: 1, requiredMove: .duck,
            beam: .init(lowerY: 1.2, upperY: 1.3), warningTime: 0.5, crossingTime: 2)
        try game.register(try LaserEncounter(id: UUID(), attemptID: UUID(), targets: [target], roster: [.player1]))
        // P1 stands tall through the beam (real evidence values), P2's slot is unbound.
        func value(_ v: Double) throws -> EstimatedScalar { try .init(value: v, validity: .valid) }
        let missing = try EstimatedScalar(value: nil, validity: .notCalibrated)
        for (frame, t) in [(1, 1.8), (2, 1.9), (3, 2.0), (4, 2.1), (5, 2.2)] {
            let p1 = try PlayerBodySample(playerID: .player1, calibrationRevision: 1, trackingStatus: .reliable,
                geometry: .init(crownY: value(1.6), leftWristY: value(0.9), rightWristY: value(0.9),
                    leftSoleY: value(0), rightSoleY: value(0), centerX: value(-1)),
                jumpState: .init(phase: .grounded, validity: .valid))
            let p2 = try PlayerBodySample(playerID: .player2, calibrationRevision: nil, trackingStatus: .uncertain,
                geometry: .init(crownY: missing, leftWristY: missing, rightWristY: missing,
                    leftSoleY: missing, rightSoleY: missing, centerX: missing),
                jumpState: .init(phase: .unknown, validity: .notCalibrated))
            let snapshot = BodySnapshot(sessionGeneration: input.sessionGeneration, frameID: UInt64(frame), capturedAt: t,
                cameraGeometryRevision: script.input.cameraGeometryRevision, players: [.player1: p1, .player2: p2])
            try game.receive(snapshot, capturedGameTime: t, arrivedAt: t + 0.02)
        }
        try game.advance(to: 4)
        #expect(game.playerStats[.player1]?.hit == 1)
        #expect(game.teamHealth == configuration.initialTeamHealth - 1, "one target, one hit, one heart")
    }

    @Test func theFlowStartsSoloOnlyWithASoloFactoryAndKeepsItOnRetry() async throws {
        let plain = LaserInputFlow(makeLiveSession: { throw LiveVisionError.inactiveSource })
        #expect(!plain.canStartSolo)
        await plain.startLiveSetup(solo: true)
        #expect(plain.route == .selection && !plain.isSolo, "no solo factory, no solo setup")
        let flow = LaserInputFlow(makeLiveSession: { throw LiveVisionError.inactiveSource },
                                  makeSoloSession: { throw LiveVisionError.invalidRequest })
        #expect(flow.canStartSolo)
        await flow.startLiveSetup(solo: true)
        #expect(flow.isSolo && flow.route == .liveSetup)
        await flow.closeLiveSetup()
        await flow.startLiveSetup()
        #expect(!flow.isSolo, "co-op after solo starts a co-op setup")
        await flow.closeLiveSetup()
    }

    /// Found on the iPad (11 November 2026): the person mask demanded exactly two people, so every
    /// solo sample was refused as "not separated". It now expects one person per LINKED player.
    @Test func theSoloMaskExpectsOnePersonForTheOneLinkedPlayer() throws {
        let f = try TrackingIntegrationFixture()
        let pose = try f.result(3, 0.25, [LiveVisionFixtures.standingPair[0]])
        let both = LiveVisionFixtures.association(pose, revision: 2)
        let solo = PlayerTrackingSnapshot(source: both.source, evaluatedAt: both.evaluatedAt, controlRevision: 2,
            player1: both.player1, player2: .init(state: .unbound, reason: .disarmed, candidateID: nil, cost: nil,
                requiresRebind: false, lastConfirmedAt: nil),
            assignmentCount: 1, confirmedDescriptorCount: 1, provisionalDescriptorCount: 0)
        #expect(PersonSegmenter.linkedRoster(solo) == [.player1] && PersonSegmenter.linkedRoster(both) == PlayerID.allCases)
        let regions = PersonSegmenter.associate(pose: pose, association: solo, labels: [1],
            bounds: [[0, 7, 0, 7]], width: 8, height: 8) { _, _ in 1 }
        #expect(regions.keys.sorted { $0.rawValue < $1.rawValue } == [.player1] && regions[.player1]?.candidateID == 10)
        // A second person in the solo mask is refused (no guessing who is P1).
        #expect(PersonSegmenter.associate(pose: pose, association: solo, labels: [1, 2],
            bounds: [[0, 3, 0, 7], [4, 7, 0, 7]], width: 8, height: 8) { x, _ in x < 4 ? 1 : 2 }.isEmpty)
        // Co-op with one person in the mask is still refused.
        #expect(PersonSegmenter.associate(pose: pose, association: both, labels: [1],
            bounds: [[0, 7, 0, 7]], width: 8, height: 8) { _, _ in 1 }.isEmpty)
    }

    /// Device data (11 November 2026): a player ~30 % of the frame tall had no face and weak ankles.
    @Test func aSmallFigureWithoutFaceIsToldToStepCloser() throws {
        let (f, initial, stamp) = try LiveVisionFixtures.sessionFixture(); var session = initial
        let pair = LiveVisionFixtures.standingPair.map { c -> PoseCandidate in
            var j = c.joints; j.removeValue(forKey: .nose)
            return .init(candidateID: c.candidateID, joints: j, maskTopImageY: nil, maskBottomImageY: nil,
                leftFootBottomImageY: nil, rightFootBottomImageY: nil, maskAssociation: .unavailable)
        }
        let pose = try f.result(3, 0.25, pair)
        let started = session.beginSample(stamp, source: pose.source, at: 0.25)
        try #require(started)
        var mask = LiveVisionFixtures.mask(pose)
        mask = PersonMaskObservation(source: mask.source, quality: mask.quality, regions: mask.regions.mapValues {
            PersonMaskRegion(candidateID: $0.candidateID, label: $0.label, minX: $0.minX, maxX: $0.maxX, minY: 0.5, maxY: 0.8)
        }, outputBytes: mask.outputBytes, serviceSeconds: mask.serviceSeconds)
        session.observe(mask, pose: pose, association: LiveVisionFixtures.association(pose, revision: stamp.bindingRevision),
                        stamp: stamp, at: 0.26)
        #expect(session.players[.player1]?.latestIssue == .tooFar)
        #expect(LaserAutomaticSetupCopy.hint(.tooFar).contains("closer"))
    }

    @Test func soloSessionsUseTheP1RosterEverywhere() {
        var configuration = LiveVisionFixtures.configuration(UUID())
        #expect(configuration.roster == PlayerID.allCases)
        configuration.soloPlayer = .player1
        #expect(configuration.roster == [.player1])
        #expect(configuration.replacingCalibrations([:]).soloPlayer == .player1)
        configuration.soloPlayer = .player2
        #expect(throws: (any Error).self) { try configuration.validate() }
    }
}
#endif
