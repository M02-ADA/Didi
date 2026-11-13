import Foundation
import Testing
@testable import Sedactive

/// iPad, 12 November 2026 (P0): two players calibrated and started, then a jump sent the round
/// back to the setup screen. A running co-op round now rides out brief tracking gaps (a jump's
/// pose dropout) without pausing; missing evidence stays UNAVAILABLE and never becomes CLEAR.
/// A sustained loss still pauses as before. (Re-linking a LOST co-op identity is the tracker's
/// rule and is unchanged here.)
@MainActor struct CoopTrackingRecoveryTests {
    // MARK: - Readiness: running grace

    private let generation = UUID(uuidString: "33000000-0000-4000-8000-0000000000c1")!
    private var context: BodyInputContext {
        BodyInputContext(sessionGeneration: generation, cameraGeometryRevision: 1,
                         calibrationRevisions: [.player1: 1, .player2: 1], cutovers: [:], isActive: true)
    }
    private func packet(_ frame: UInt64, _ time: Double, p1Reliable: Bool = true) throws -> BodySnapshot {
        let base = try LH00TestData.load().records.first!.snapshot!
        let missing = try EstimatedScalar(value: nil, validity: .identityUncertain)
        let players = base.players.mapValues { sample -> PlayerBodySample in
            guard sample.playerID != .player1 || p1Reliable else {
                return PlayerBodySample(playerID: .player1, calibrationRevision: 1, trackingStatus: .uncertain,
                    geometry: BodyGeometry(crownY: missing, leftWristY: missing, rightWristY: missing,
                                           leftSoleY: missing, rightSoleY: missing, centerX: missing),
                    jumpState: JumpState(phase: .unknown, validity: .identityUncertain))
            }
            return PlayerBodySample(playerID: sample.playerID, calibrationRevision: 1, trackingStatus: .reliable,
                                    geometry: sample.geometry, jumpState: sample.jumpState)
        }
        return BodySnapshot(sessionGeneration: generation, frameID: frame, capturedAt: time,
                            cameraGeometryRevision: 1, players: players)
    }
    private func running(grace: Double) throws -> LaserLiveReadiness {
        var value = LaserLiveReadiness(policy: try LaserLiveTimingPolicy(settlingDuration: 0.125,
            maximumEvidenceAge: 0.5, countdownDuration: 0.25, trackingGrace: grace))
        try value.observe(packet(1, 1000), context: context, bindingConfirmed: true, at: 1000)
        try value.observe(packet(2, 1000.125), context: context, bindingConfirmed: true, at: 1000.125)
        try value.beginCountdown(at: 1000.125)
        try value.observe(packet(3, 1000.25), context: context, bindingConfirmed: true, at: 1000.25)
        try value.observe(packet(4, 1000.375), context: context, bindingConfirmed: true, at: 1000.375)
        #expect(value.phase == .running)
        return value
    }

    /// A jump's pose dropout (P1 uncertain, the pair briefly unconfirmed) under the grace keeps
    /// the round and its clock running; nothing from it is admitted; good evidence carries on.
    @Test func aBriefDropoutKeepsTheRoundRunning() throws {
        var value = try running(grace: 1)
        var frame: UInt64 = 5
        for time in stride(from: 1000.5, through: 1001.1, by: 0.1) {
            try value.observe(packet(frame, time, p1Reliable: false), context: context, bindingConfirmed: false, at: time)
            try value.invalidateBinding(at: time)
            frame += 1
            #expect(value.phase == .running, "at \(time)")
        }
        try value.observe(packet(frame, 1001.2), context: context, bindingConfirmed: true, at: 1001.2)
        #expect(value.phase == .running && abs(value.gameTime - 0.825) < 1e-9)
    }

    /// Longer than the grace, the existing pause applies (never a restart); with no grace
    /// (the default) the first bad frame pauses, as before.
    @Test func aSustainedLossPausesAsBeforeAndNoGraceKeepsTheOldRule() throws {
        var value = try running(grace: 1)
        var frame: UInt64 = 5
        for time in stride(from: 1000.5, through: 1001.5, by: 0.1) {
            try value.observe(packet(frame, time, p1Reliable: false), context: context, bindingConfirmed: true, at: time)
            frame += 1
        }
        #expect(value.phase == .paused && value.phase != .restartRequired)
        var strict = try running(grace: 0)
        try strict.observe(packet(5, 1000.5, p1Reliable: false), context: context, bindingConfirmed: true, at: 1000.5)
        #expect(strict.phase == .paused)
    }

    /// Through the live session: P1's pose drops out for half a second mid-round (a jump), the
    /// round keeps running on the same clock, calibration and game; nothing is restarted.
    @Test func aCoopRoundKeepsRunningThroughAJumpDropout() async throws {
        let rig = try J07SessionRig(trackingGrace: 1)
        try await rig.start()
        // P1's pose drops out (uncertain, no measurements, no wrists): the fixture's "unbound" frame.
        let calibrations = try #require(rig.session.inputContext?.calibrationRevisions)
        for time in stride(from: 0.75, through: 1.25, by: 0.125) {
            try await rig.send(time, bad: "unbound")
            #expect(rig.session.phase == .running, "at \(time)")
        }
        try await rig.send(1.375)
        #expect(rig.session.phase == .running && abs((rig.session.state?.gameTime ?? 0) - 0.75) < 1e-9)
        #expect(rig.session.inputContext?.calibrationRevisions == calibrations && rig.session.summary == nil)
        // Sustained: the existing pause, never a restart.
        for time in stride(from: 1.5, through: 2.75, by: 0.125) { try await rig.send(time, bad: "unbound") }
        #expect(rig.session.phase == .paused)
        await rig.session.stop()
    }

    /// iPad, 12 November 2026: in co-op all twelve measurements must be valid in one frame; one
    /// flickering wrist or sole restarted settling and aborted the countdown, so "calibration"
    /// never seemed to finish. Before RUNNING a flicker is now skipped within the evidence age.
    @Test(arguments: [1.0, 0.0])
    func aFlickerNeitherResetsSettlingNorAbortsTheCountdown(grace: Double) throws {
        var value = LaserLiveReadiness(policy: try LaserLiveTimingPolicy(settlingDuration: 0.25,
            maximumEvidenceAge: 0.5, countdownDuration: 0.5, trackingGrace: grace))
        try value.observe(packet(1, 1000), context: context, bindingConfirmed: true, at: 1000)
        try value.observe(packet(2, 1000.125, p1Reliable: false), context: context, bindingConfirmed: true, at: 1000.125)
        try value.observe(packet(3, 1000.25), context: context, bindingConfirmed: true, at: 1000.25)
        if grace == 0 {
            #expect(value.phase == .settling, "strict rule: the flicker restarted settling")
            return
        }
        #expect(value.phase == .ready, "the flicker did not restart settling")
        try value.beginCountdown(at: 1000.25)
        try value.observe(packet(4, 1000.375, p1Reliable: false), context: context, bindingConfirmed: false, at: 1000.375)
        try value.invalidateBinding(at: 1000.375)
        try value.observe(packet(5, 1000.5), context: context, bindingConfirmed: true, at: 1000.5)
        #expect(value.phase == .countdown && value.skippedFrames == 2)
        try value.observe(packet(6, 1000.75), context: context, bindingConfirmed: true, at: 1000.75)
        #expect(value.phase == .running && value.gameTime == 0)
    }

    @Test func aSustainedLossBeforeTheRoundStillBlocks() throws {
        var value = LaserLiveReadiness(policy: try LaserLiveTimingPolicy(settlingDuration: 0.25,
            maximumEvidenceAge: 0.5, countdownDuration: 0.5, trackingGrace: 1))
        try value.observe(packet(1, 1000), context: context, bindingConfirmed: true, at: 1000)
        try value.observe(packet(2, 1000.25), context: context, bindingConfirmed: true, at: 1000.25)
        try value.beginCountdown(at: 1000.25)
        var frame: UInt64 = 3
        for time in stride(from: 1000.375, through: 1000.875, by: 0.125) {
            try value.observe(packet(frame, time, p1Reliable: false), context: context, bindingConfirmed: true, at: time)
            frame += 1
        }
        #expect(value.phase == .blocked(.measurements) || value.phase == .blocked(.staleEvidence))
        #expect(value.gameTime == 0, "no clock was started on missing evidence")
    }

    /// iPad, 12 November 2026: losing a co-op player's identity mid-round (out of view past the
    /// tracker's recovery window) ended the round as "Round interrupted". It now PAUSES and keeps
    /// the round (clock, hearts, score, encounters, calibrations); the players see "Player tracking
    /// lost" with an explicit Restart. No automatic restart, no identity guessed.
    @Test func aCoopIdentityLostMidRoundPausesAndKeepsTheRound() async throws {
        let rig = try J07SessionRig(trackingGrace: 1)
        try await rig.start()
        let session = rig.session
        let before = try #require(session.state)
        let calibrations = try #require(session.inputContext?.calibrationRevisions)
        var time = 0.75
        for _ in 0..<32 { try await rig.send(time, bad: "unbound", people: []); time += 0.125 }
        #expect(session.phase == .paused && session.summary == nil, "paused, not interrupted or finished")
        #expect(session.awaitsIdentityRecovery)
        let after = try #require(session.state)
        #expect(after.teamHealth == before.teamHealth && after.teamScore == before.teamScore
                && after.missionProgress == before.missionProgress && after.phase == before.phase)
        #expect(after.gameTime <= before.gameTime + 1.1, "the clock stopped with the pause (grace at most)")
        #expect(session.inputContext?.calibrationRevisions == calibrations, "calibrations kept")
        let copy = LaserAutomaticSetupCopy(.init(sessionPhase: session.phase, setupPhase: session.setup?.phase,
                                                 hasRoundPlan: true, roundStarted: true))
        // Over the held round: the tracking warning with Recalibrate, never the setup stage first
        // (Kevin, 13 November 2026).
        #expect(!ContentView.showsSetupStage(session))
        #expect(LaserTrackingWarningLatch().peek(.init(session: session))?.primary == .recalibrate)
        #expect(copy.title == "Tracking paused" && copy.action == .restartSetup)
        await session.stop()
    }

    @Test func liveTimingPausesDuringPlayButPreservesTheInitialCountdownOnBriefFlickers() {
        let timing = LaserLiveWristRoundPlan.liveTiming
        #expect(timing.trackingGrace == 0)
        #expect(timing.preservesCountdownOnTrackingFlicker)
    }
}

/// Bystanders against Edo's PlayerTracker as it is (identity contract unchanged), 12 November
/// 2026. What the round survives, and the case that still needs a tracker re-link (dependency).
nonisolated struct BystanderTrackingTests {
    typealias F = TrackingFixtures

    private func bound() throws -> (PlayerTracker, (inout PlayerTracker, [PoseCandidate]) throws -> PlayerTrackingSnapshot) {
        var tracker = try F.tracker()
        var t = 1.0, frame: UInt64 = 0
        let step: (inout PlayerTracker, [PoseCandidate]) throws -> PlayerTrackingSnapshot = { tracker, people in
            frame += 1; t += 0.1
            return try tracker.process(F.input(frame, t, people))
        }
        for _ in 0..<4 { _ = try step(&tracker, F.pair) }
        #expect(tracker.snapshot.player1.candidateID == 10 && tracker.snapshot.player2.candidateID == 20)
        return (tracker, step)
    }

    /// A smaller person walking past behind both players: nobody is re-assigned or needs rebind.
    @Test func aBystanderWalkingPastBehindChangesNoIdentity() throws {
        var (tracker, step) = try bound()
        for i in 0...12 {
            let walker = F.candidate(99, x: 0.1 + Double(i) * 0.065, y: 0.55, length: 0.12)
            let r = try step(&tracker, F.pair + [walker])
            #expect(r.player1.candidateID == 10 && r.player2.candidateID == 20, "frame \(i)")
            #expect(!r.player1.requiresRebind && !r.player2.requiresRebind)
        }
        let after = try step(&tracker, F.pair)
        #expect(after.player1.state == .tracking && after.player2.state == .tracking)
    }

    /// A brief occlusion of one player (half a second): uncertain, never rebind, and the same
    /// person is tracked again when visible. The other player is unaffected.
    @Test func aBriefOcclusionRecoversTheSameIdentity() throws {
        var (tracker, step) = try bound()
        for _ in 0..<5 {
            let r = try step(&tracker, [F.candidate(10, x: 0.75)])
            #expect(r.player1.state == .tracking && !r.player1.requiresRebind)
            #expect(r.player2.state != .tracking && !r.player2.requiresRebind)
        }
        var r = try step(&tracker, F.pair)
        for _ in 0..<2 { r = try step(&tracker, F.pair) }
        #expect(r.player1.candidateID == 10 && r.player2.state == .tracking && r.player2.candidateID == 20)
        #expect(!r.player1.requiresRebind && !r.player2.requiresRebind)
    }

    /// DEPENDENCY (Edo): one player hidden longer than the tracker's 1 s observation gap latches
    /// the identities as ambiguous (the hidden player's evidence is too old to exclude them), and
    /// the latch holds until a new binding, which ends a co-op round ("Round interrupted").
    /// Recording the current contract; a recovery needs a tracker-side pair re-link.
    @Test func aLongOcclusionStillNeedsATrackerRelink() throws {
        var (tracker, step) = try bound()
        var r = try step(&tracker, [F.candidate(10, x: 0.75)])
        for _ in 0..<15 { r = try step(&tracker, [F.candidate(10, x: 0.75)]) }
        for _ in 0..<5 { r = try step(&tracker, F.pair) }
        #expect(r.player1.requiresRebind || r.player2.requiresRebind, "current contract: rebind after a long occlusion")
    }
}
