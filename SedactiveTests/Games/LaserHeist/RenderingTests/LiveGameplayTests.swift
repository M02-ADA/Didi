import Foundation
import Testing
@testable import Sedactive

/// The Debug live round: live body frames (here SYNTHETIC, in Vision's
/// convention) go through the live tracker into Jevon's `LaserGame`, which
/// selects the evidence nearest each crossing and judges it with
/// `LaserCollisionJudge`. No camera in tests; host time is simulated.
@MainActor
struct LiveGameplayTests {
    private let aspect = 16.0 / 9
    private let start = 1000.0  // host-clock seconds when the round starts
    /// One DUCK at 4 s, one JUMP at 10 s (game time).
    private let beats = [
        LaserWaveBeat(id: UUID(uuidString: "17000000-0000-4000-8000-000000000101")!, move: .duck, nominalCrossingTime: 4, segmentEnd: 300),
        LaserWaveBeat(id: UUID(uuidString: "17000000-0000-4000-8000-000000000102")!, move: .jump, nominalCrossingTime: 10, segmentEnd: 300),
    ]

    private func frame(_ id: UInt64, at captured: Double, _ bodies: [LiveSyntheticBody]) -> LiveBodyFrame {
        LiveBodyFrame(frameID: id, capturedAt: captured, visionCompletedAt: captured + 0.03, imageAspect: aspect,
                      cameraGeometryRevision: 1, people: bodies.map { $0.person(aspect: aspect) })
    }

    /// Calibrates the tracker from 1.5 s of standing before the round.
    private func calibrated(_ bodies: [LiveSyntheticBody], mode: LiveAvatarMode,
                            tuning: LiveJumpTuning = .tuned) throws -> (LiveAvatarTracker, UInt64) {
        var tracker = LiveAvatarTracker(sessionGeneration: UUID(), mode: mode)
        tracker.setJumpTuning(tuning)
        var calibrator = LiveCalibrator(players: mode.players, at: start - 3)
        for id in UInt64(1)...60 {
            let f = frame(id, at: start - 3 + Double(id) / 30, bodies)
            let processed = tracker.process(f, now: f.capturedAt + 0.05)
            let out = try #require(processed)
            if let stances = calibrator.add(out.assigned, frame: f) {
                try tracker.calibrate(stances, frame: f)
                return (tracker, id)
            }
        }
        Issue.record("calibration did not complete")
        return (tracker, 60)
    }

    /// Plays the round at 30 frames per second until `until` game seconds.
    /// `script` gives each player's body at a game time; `framesUntil` stops the
    /// camera early (stale evidence); `robots` optionally also poses robots.
    private func play(_ mode: LiveAvatarMode, _ scripts: [LiveSyntheticPlayer], until: Double = 12,
                      framesUntil: Double = .infinity, robots: RobotAvatarLayer? = nil,
                      tuning: LiveJumpTuning = .tuned) throws -> LiveGameSession {
        var (tracker, last) = try calibrated(scripts.map(\.body), mode: mode, tuning: tuning)
        var session = try LiveGameSession(mode: mode == .single ? .solo : .cooperative, calibrations: tracker.calibrations,
                                          layout: tracker.layout, sessionGeneration: tracker.sessionGeneration,
                                          cameraGeometryRevision: 1, startTime: start, beats: beats)
        let targets: [PlayerID: [LaserTarget]] = Dictionary(grouping: session.encounters.flatMap(\.targets), by: \.playerID)
        var id = last
        for n in 1...Int(until * 30) {
            let time = Double(n) / 30
            let now = start + time
            if time <= framesUntil {
                id += 1
                let bodies = zip(PlayerID.allCases, scripts).map { $1.body(at: time - 0.03, targets: targets[$0] ?? []) }
                let f = frame(id, at: now - 0.03, bodies)
                if let out = tracker.process(f, now: now) {
                    robots?.apply(out.snapshot, joints: out.joints)
                    session.receive(out.snapshot, now: now)
                }
            }
            session.advance(to: now)
        }
        return session
    }

    private func report(_ s: LiveGameSession, _ player: PlayerID, _ move: LaserMove) throws -> LiveCrossingReport {
        try #require(s.reports.first { $0.playerID == player && $0.move == move })
    }

    // MARK: - Live evidence reaches the checker

    @Test func duckingAndJumpingAtTheCrossingsClear() throws {
        let s = try play(.single, [LiveSyntheticPlayer(missEvery: nil)])
        let duck = try report(s, .player1, .duck), jump = try report(s, .player1, .jump)
        #expect(duck.judgement == .clear && jump.judgement == .clear)
        // The checker used live frames captured within one frame of each crossing.
        for r in [duck, jump] {
            #expect(r.frameID != nil && abs(r.captureOffset ?? 1) <= 1.0 / 30 + 1e-9)
            #expect((r.arrivalDelay ?? 1) <= s.configuration.evidenceTiming.deliveryAllowance)
        }
        #expect(try #require(duck.measured) < duck.threshold)
        #expect(try #require(jump.measured) > jump.threshold && jump.airborne == true)
        // The CLEAR/HIT feedback events the presenter shows were emitted.
        #expect(s.events.contains { if case .targetJudged(_, .player1, .clear) = $0.kind { true } else { false } })
    }

    @Test func standingStillIsHitNeverClear() throws {
        let still = LiveSyntheticPlayer(body: LiveSyntheticBody(), missEvery: 1)  // misses every target
        let s = try play(.single, [still])
        #expect(try report(s, .player1, .duck).judgement == .hit(.insufficientClearance))
        let jump = try report(s, .player1, .jump).judgement
        #expect(jump == .hit(.insufficientClearance) || jump == .hit(.notAirborne))
    }

    @Test func staleEvidenceIsNeverAcceptedAsFresh() throws {
        // The camera stops at 2 s: nothing near either crossing.
        let s = try play(.single, [LiveSyntheticPlayer(missEvery: nil)], framesUntil: 2)
        for move in [LaserMove.duck, .jump] {
            let judgement = try report(s, .player1, move).judgement
            #expect(judgement == .unavailable(.stale) || judgement == .unavailable(.noSample), "\(move): \(judgement)")
        }
    }

    // MARK: - Solo and co-op

    @Test func soloNeverFabricatesP2() throws {
        let s = try play(.single, [LiveSyntheticPlayer(missEvery: nil)])
        for move in [LaserMove.duck, .jump] {
            if case .unavailable = try report(s, .player2, move).judgement {} else { Issue.record("P2 \(move) was not UNAVAILABLE") }
            #expect(try report(s, .player2, move).frameID == nil)
        }
        // Technical encounters: no damage, no score, whatever P1 did.
        #expect(s.state.teamHealth == 5 && s.state.teamScore == 0)
    }

    @Test func coopPlayersAreJudgedIndependently() throws {
        let p1 = LiveSyntheticPlayer(body: LiveSyntheticBody(cx: 0.68), missEvery: nil)
        let p2 = LiveSyntheticPlayer(body: LiveSyntheticBody(cx: 0.32, h: 0.6), missEvery: 1)  // P2 stands still
        let s = try play(.two, [p1, p2])
        #expect(try report(s, .player1, .duck).judgement == .clear && report(s, .player1, .jump).judgement == .clear)
        #expect(try report(s, .player2, .duck).judgement == .hit(.insufficientClearance))
        // Real team effects: P1's clears score, P2's hits cost health.
        #expect(s.state.teamScore == 200 && s.state.teamHealth == 3)
        // Each report's frame carries that player's own sample.
        #expect(s.reports.allSatisfy { r in r.frameID == nil || [PlayerID.player1, .player2].contains(r.playerID) })
    }

    // MARK: - Presentation never changes verdicts

    @Test func posingRobotsDoesNotChangeTheVerdicts() async throws {
        let script = [LiveSyntheticPlayer(missEvery: 2)]
        let plain = try play(.single, script)
        let template = try #require(await RobotAvatarLayer.loadTemplate())
        let (tracker, _) = try calibrated(script.map(\.body), mode: .single)
        let robots = RobotAvatarLayer(scene: LaserScene(), calibrations: tracker.calibrations, layout: tracker.layout, template: template)
        let posed = try play(.single, script, robots: robots)
        #expect(plain.reports.map(\.judgement) == posed.reports.map(\.judgement))
        #expect(plain.reports.map(\.frameID) == posed.reports.map(\.frameID))
    }

    // MARK: - Jump tuning changes evidence, never the checker

    /// A clear jump (13% of height), a deliberate miss and standing still are
    /// judged identically under both jump rules: same verdicts, same frames.
    @Test func judgementsAreUnchangedForClearMovesAndMisses() throws {
        for script in [LiveSyntheticPlayer(missEvery: nil), LiveSyntheticPlayer(missEvery: 1), LiveSyntheticPlayer(missEvery: 2)] {
            let original = try play(.single, [script], tuning: .original), tuned = try play(.single, [script], tuning: .tuned)
            #expect(original.reports.map(\.judgement) == tuned.reports.map(\.judgement))
            #expect(original.reports.map(\.frameID) == tuned.reports.map(\.frameID))
            #expect(original.state.teamHealth == tuned.state.teamHealth && original.state.teamScore == tuned.state.teamScore)
        }
    }

    /// A small hop (5% of height, feet ~6 cm up at the crossing) clears the
    /// checker's ~3.2 cm JUMP beam. The original live rule never called it
    /// airborne (HIT, not airborne); the tuned rule does, and the unchanged
    /// checker then judges it CLEAR from the same body measurement.
    @Test func aSmallHopClearsOnlyWithTheTunedJumpRule() throws {
        var hopper = LiveSyntheticPlayer(missEvery: nil)
        hopper.hop = 0.05
        let original = try report(try play(.single, [hopper], tuning: .original), .player1, .jump)
        let tuned = try report(try play(.single, [hopper], tuning: .tuned), .player1, .jump)
        #expect(original.judgement == .hit(.notAirborne) && original.airborne == false)
        #expect(tuned.judgement == .clear && tuned.airborne == true)
        #expect(try #require(tuned.measured) > tuned.threshold)
        #expect(original.threshold == tuned.threshold)  // the same beam and margin
    }

    @Test func liveRoundUsesTheDirectorsCalibratedBands() throws {
        let s = try play(.single, [LiveSyntheticPlayer(missEvery: nil)], until: 1)
        #expect(s.encounters.count == 2 && s.encounters.allSatisfy { $0.targets.count == 2 })
        let duck = try #require(s.encounters.first?.targets.first { $0.playerID == .player1 })
        // DUCK band: 8% below P1's calibrated standing crown (conservative candidate), plus the margin.
        #expect(abs(duck.beam.lowerY - (LiveAvatarTracker.referenceHeight * 0.92 + 0.005)) < 1e-6)
    }
}
