import Foundation
import Testing
@testable import Sedactive

/// EVIDENCE (iPad, 13 November 2026: a DUCK with the hands behind the body sent the players back
/// to calibration). SYNTHETIC inputs through the REAL tracker (`PlayerTracker` with the live
/// `B2bExperimentalPolicyV1`), the real setup gate and the real session with the production round
/// plan. It establishes which mechanism does what; it says nothing about how long Vision actually
/// loses a squatting player's hips or wrists on the iPad (the `[LaserDropout]` log measures that).
@MainActor struct DuckOcclusionEvidenceTests {
    typealias F = TrackingFixtures

    // MARK: - Tracker: a squat whose hips Vision cannot see

    /// Two bound players at 30 Hz; then P1 squats with only the shoulders confident (hands behind
    /// the hips) for `hidden` seconds, then stands again. Wrists are not tracker evidence at all.
    private func squat(hidden: Double) throws -> (during: PlayerTrackingSnapshot, after: PlayerTrackingSnapshot) {
        var tracker = try F.tracker(policy: B2bExperimentalPolicyV1.value)
        var t = 1.0, frame: UInt64 = 0
        func step(_ people: [PoseCandidate]) throws -> PlayerTrackingSnapshot {
            frame += 1; t += 1.0 / 30
            return try tracker.process(F.input(frame, t, people))
        }
        for _ in 0..<10 { _ = try step(F.pair) }
        try #require(tracker.snapshot.player1.candidateID == 10 && tracker.snapshot.player2.candidateID == 20)
        let squatting = [F.candidate(10, x: 0.75, y: 0.4, missing: [.leftHip, .rightHip]), F.candidate(20, x: 0.25)]
        var during = tracker.snapshot
        for _ in 0..<Int((hidden * 30).rounded()) { during = try step(squatting) }
        var after = tracker.snapshot
        for _ in 0..<15 { after = try step(F.pair) }
        return (during, after)
    }

    @Test(arguments: [0.3, 0.6, 0.9, 1.2, 1.8]) func aSquatWithHiddenHips(hidden: Double) throws {
        let (during, after) = try squat(hidden: hidden)
        print(String(format: "[DuckEvidence] hips hidden %.1f s · during: P1 %@ rebind %@, P2 %@ rebind %@ · after standing: P1 %@ rebind %@, P2 %@ rebind %@",
                     hidden, "\(during.player1.state)", "\(during.player1.requiresRebind)", "\(during.player2.state)",
                     "\(during.player2.requiresRebind)", "\(after.player1.state)", "\(after.player1.requiresRebind)",
                     "\(after.player2.state)", "\(after.player2.requiresRebind)"))
        if hidden <= Self.longestSafeHide {
            #expect(!after.player1.requiresRebind && !after.player2.requiresRebind && after.player1.candidateID == 10,
                    "short enough: the same identities, no rebind")
        } else {
            // Recorded current contract (Edo): past the gap the hidden player's anchor is too old to
            // exclude, the OTHER, fully visible player is latched ambiguous and a rebind is required.
            #expect(after.player1.requiresRebind || after.player2.requiresRebind, "past the gap: rebind required")
        }
    }

    /// The longest hidden-hips squat (30 Hz frames) that keeps both identities: the 1 s observation
    /// gap less the hidden player's 0.125 s recovery dwell (measured by `theSafeSquatLimit`).
    static let longestSafeHide = 0.75

    @Test func theSafeSquatLimit() throws {
        var longest = 0.0
        for frames in stride(from: 3, through: 45, by: 1) {
            let hidden = Double(frames) / 30
            let (_, after) = try squat(hidden: hidden)
            guard !after.player1.requiresRebind, !after.player2.requiresRebind, after.player1.state == .tracking else { break }
            longest = hidden
        }
        print(String(format: "[DuckEvidence] longest hidden-hips squat that keeps both identities: %.3f s", longest))
        #expect(longest >= Self.longestSafeHide - 0.05 && longest < 1.0)
    }

    /// Hidden wrists alone (hips and shoulders visible) never touch identity.
    @Test func hiddenWristsAloneLeaveIdentityAlone() throws {
        var tracker = try F.tracker(policy: B2bExperimentalPolicyV1.value)
        var t = 1.0
        for frame in 1...90 {
            t += 1.0 / 30
            let r = try tracker.process(F.input(UInt64(frame), t, [F.candidate(10, x: 0.75, y: 0.4, length: 0.17), F.candidate(20, x: 0.25)]))
            if frame > 10 { #expect(r.player1.state == .tracking && !r.player1.requiresRebind && !r.player2.requiresRebind) }
        }
    }

    // MARK: - Session: hidden wrists while running (production plan and timing)

    private static func runningRig() async throws -> (J07SessionRig, Double) {
        let rig = try J07SessionRig(deferredPlan: true)
        try await rig.start(installDeferredPlan: false)
        let calibrations = try LaserReplayScript.load().input.configuration.calibrations
        try rig.session.installLiveWristRound(try LaserLiveWristRoundPlan.completeRound(context: rig.fixture.context,
            calibrations: calibrations, layout: rig.fixture.input.playerPlaneLayout))
        let session = rig.session
        let host = try session.attachLiveFrameHost(); session.advanceLive(frameHost: host)
        var time = 0.25
        while !session.canStartLiveRound, time < 4 { try await rig.send(time); time += 1.0 / 30 }
        try session.beginLiveCountdown()
        while session.phase != .running, time < 10 { try await rig.send(time); time += 1.0 / 30 }
        try #require(session.phase == .running)
        return (rig, time)
    }

    /// `player`'s wrists hidden (both, or the left only), everything else as calibrated.
    private static func hiddenWrists(_ rig: J07SessionRig, _ players: Set<PlayerID>, bothWrists: Bool = true) throws
        -> [PlayerID: PlayerBodySample] {
        var samples = rig.fixture.players
        for player in players {
            let s = try #require(samples[player]), g = s.geometry
            let gone = try EstimatedScalar(value: nil, validity: .missingLandmarks)
            samples[player] = PlayerBodySample(playerID: player, calibrationRevision: s.calibrationRevision,
                trackingStatus: s.trackingStatus, geometry: .init(crownY: g.crownY, leftWristY: gone,
                    rightWristY: bothWrists ? gone : g.rightWristY, leftSoleY: g.leftSoleY, rightSoleY: g.rightSoleY,
                    centerX: g.centerX), jumpState: s.jumpState)
        }
        return samples
    }

    @Test(arguments: [1, 3, 30]) func hiddenWristsWhileRunningNeverRestart(frames: Int) async throws {
        for (players, both) in [([PlayerID.player1], true), ([.player2], true), ([.player1], false), ([.player1, .player2], true)] {
            let (rig, start) = try await Self.runningRig()
            let session = rig.session
            var time = start
            for _ in 0..<15 { try await rig.send(time); time += 1.0 / 30 }
            let calibrations = session.inputContext?.calibrationRevisions
            let before = try #require(session.state)
            for _ in 0..<frames {
                try await rig.send(time, bodySamples: try Self.hiddenWrists(rig, Set(players), bothWrists: both)); time += 1.0 / 30
            }
            let paused = session.phase, setup = session.setup?.phase, blocker = session.liveReadiness?.blocker
            let lostAt = time
            while session.phase != .running, time < lostAt + 15 { try await rig.send(time); time += 1.0 / 30 }
            print(String(format: "[DuckEvidence] %@ %@ wrist%@ hidden %d frame%@ → session %@ · blocker %@ · setup %@ · running again after %.2f s",
                         players.map(\.rawValue).joined(separator: "+"), both ? "both" : "one", both ? "s" : "", frames,
                         frames == 1 ? "" : "s", "\(paused)", "\(String(describing: blocker))", "\(String(describing: setup))", time - lostAt))
            // Today Jevon's readiness pauses on a hidden wrist (blocker .measurements); with the proposed
            // readiness change it does not pause at all. Either way: never a restart, it runs on.
            #expect(paused == .running || (paused == .paused && blocker == .measurements), "paused only for the wrists, if at all")
            #expect(setup != .restartRequired && session.phase == .running, "never a restart: it resumes by itself")
            #expect(session.inputContext?.calibrationRevisions == calibrations, "calibrations kept")
            let after = try #require(session.state)
            #expect(after.teamHealth == before.teamHealth && after.missionProgress == before.missionProgress)
            await session.stop()
        }
    }

    /// The full chain: P1 squats with the hips unseen for 1.5 s DURING THE ROUND (real tracker in
    /// the setup gate), P2 fully visible. What happens to the setup, the session and the round.
    @Test func aLongSquatWithHiddenHipsDuringTheRound() async throws {
        let (rig, start) = try await Self.runningRig()
        let session = rig.session
        var time = start
        for _ in 0..<15 { try await rig.send(time); time += 1.0 / 30 }
        let calibrations = session.inputContext?.calibrationRevisions
        let standing = LiveVisionFixtures.standingPair
        let squatting = standing.map { c -> PoseCandidate in
            guard c.candidateID == 10 else { return c }
            var joints = c.joints
            joints.removeValue(forKey: .leftHip); joints.removeValue(forKey: .rightHip)
            return .init(candidateID: c.candidateID, joints: joints, maskTopImageY: nil, maskBottomImageY: nil,
                         leftFootBottomImageY: nil, rightFootBottomImageY: nil, maskAssociation: .unavailable)
        }
        var firstPause: Double?
        for _ in 0..<45 {
            try await rig.send(time, bodySamples: try Self.hiddenWrists(rig, [.player1]), people: squatting); time += 1.0 / 30
            if firstPause == nil, session.phase == .paused { firstPause = time - start }
        }
        let setupDuring = session.setup?.phase, identity = session.awaitsIdentityRecovery
        for _ in 0..<150 { try await rig.send(time); time += 1.0 / 30 } // 5 s standing again
        print(String(format: "[DuckEvidence] round: P1 squat, hips unseen 1.5 s · paused after %.2f s · setup %@ · awaits identity recovery %@ · 5 s after standing: session %@, setup %@ · calibrations kept %@",
                     firstPause ?? -1, "\(String(describing: setupDuring))", "\(identity)", "\(session.phase)",
                     "\(String(describing: session.setup?.phase))", "\(session.inputContext?.calibrationRevisions == calibrations)"))
        #expect(session.state != nil, "the round is kept, never discarded by the squat")
        await session.stop()
    }

    /// A DUCK judged while the ducking player's wrists are hidden: never a CLEAR without the
    /// evidence the judge requires (Jevon's DUCK rule needs both wrists below the beam).
    @Test func aDuckWithHiddenWristsIsNeverAFreeClear() async throws {
        let (rig, start) = try await Self.runningRig()
        let session = rig.session
        let configuration = try #require(session.configuration)
        var time = start
        func duckTarget() -> (UUID, LaserTarget)? {
            let now = session.state?.gameTime ?? 0
            return session.encounters.compactMap { e in
                e.targets.first { $0.playerID == .player1 && $0.requiredMove == .duck && $0.crossingTime > now + 0.5 }.map { (e.id, $0) }
            }.min { $0.1.crossingTime < $1.1.crossingTime }
        }
        var found: (UUID, LaserTarget)?
        for _ in 0..<1800 where found == nil { try await rig.send(time); time += 1.0 / 30; found = duckTarget() }
        let (id, target) = try #require(found, "a P1 DUCK is scheduled")
        var verdict: Judgement?
        for _ in 0..<900 where verdict == nil {
            let now = session.state?.gameTime ?? 0
            var samples = try Self.hiddenWrists(rig, [.player1])
            if abs(now - target.crossingTime) < 0.6, let s = samples[.player1] {
                let low = try EstimatedScalar(value: target.beam.lowerY - configuration.clearanceMargin - 0.05, validity: .valid)
                samples[.player1] = PlayerBodySample(playerID: .player1, calibrationRevision: s.calibrationRevision,
                    trackingStatus: s.trackingStatus, geometry: .init(crownY: low, leftWristY: s.geometry.leftWristY,
                        rightWristY: s.geometry.rightWristY, leftSoleY: s.geometry.leftSoleY, rightSoleY: s.geometry.rightSoleY,
                        centerX: s.geometry.centerX), jumpState: s.jumpState)
            }
            try await rig.send(time, bodySamples: samples); time += 1.0 / 30
            verdict = session.state?.encounters.first { $0.encounter.id == id }?.judgements[.player1].flatMap {
                if case .pending = $0 { nil } else { $0 }
            }
        }
        print("[DuckEvidence] P1 ducked under the beam with both wrists hidden → verdict \(String(describing: verdict)) · session \(session.phase)")
        #expect({ if case .clear? = verdict { false } else { true } }(), "never CLEAR without the wrists the DUCK judge requires")
        await session.stop()
    }
}
