import Foundation
import Testing
@testable import Sedactive

/// EVIDENCE (13 November 2026, co-op "frozen after Ready" and "back to calibration"): the live
/// path with the PRODUCTION round plan and timing (`LaserLiveWristRoundPlan.completeRound`, PR #46
/// policy), through the real coordinator, readiness and setup-stage rule. SYNTHETIC CP1 packets:
/// both players standing, plus single frames in which one player's foot landmark is missing (as a
/// jump, a duck or a small child's ankle confidence can cause). It measures the session's response;
/// it says nothing about how often such frames happen on the iPad.
@MainActor struct LiveTrackingRobustnessEvidenceTests {
    static let step = 1.0 / 30

    private static func runningRig() async throws -> (J07SessionRig, Double) {
        let rig = try J07SessionRig(deferredPlan: true)
        try await rig.start(installDeferredPlan: false)
        let calibrations = try LaserReplayScript.load().input.configuration.calibrations
        try rig.session.installLiveWristRound(try LaserLiveWristRoundPlan.completeRound(context: rig.fixture.context,
            calibrations: calibrations, layout: rig.fixture.input.playerPlaneLayout))
        let session = rig.session
        let host = try session.attachLiveFrameHost(); session.advanceLive(frameHost: host)
        var time = 0.25
        while !session.canStartLiveRound, time < 4 { try await rig.send(time); time += step }
        try session.beginLiveCountdown()
        while session.phase != .running, time < 10 { try await rig.send(time); time += step }
        try #require(session.phase == .running, "Ready → countdown → running with steady evidence")
        return (rig, time)
    }

    /// P2 with one sole landmark missing in this frame (everything else as calibrated).
    private static func footDropout(_ rig: J07SessionRig) throws -> [PlayerID: PlayerBodySample] {
        var players = rig.fixture.players
        let s = try #require(players[.player2])
        let g = s.geometry
        players[.player2] = PlayerBodySample(playerID: s.playerID, calibrationRevision: s.calibrationRevision,
            trackingStatus: s.trackingStatus, geometry: .init(crownY: g.crownY, leftWristY: g.leftWristY,
                rightWristY: g.rightWristY, leftSoleY: try EstimatedScalar(value: nil, validity: .missingLandmarks),
                rightSoleY: g.rightSoleY, centerX: g.centerX), jumpState: s.jumpState)
        return players
    }

    @Test func oneDroppedFootFrameRightAfterTheStartPausesTheRoundBehindTheSetupStage() async throws {
        let (rig, start) = try await Self.runningRig()
        let session = rig.session
        var time = start
        for _ in 0..<15 { try await rig.send(time); time += Self.step } // half a second of play
        #expect(session.phase == .running)
        let before = try #require(session.state?.gameTime)
        try await rig.send(time, bodySamples: try Self.footDropout(rig)); time += Self.step
        let pausedPhase = session.phase
        let stage = ContentView.showsSetupStage(session)
        // Back to steady evidence: how long until the round runs again?
        let lostAt = time
        while session.phase != .running, time < lostAt + 15 { try await rig.send(time); time += Self.step }
        let recovered = time - lostAt
        let after = try #require(session.state?.gameTime)
        print(String(format: "[RobustnessEvidence] one dropped P2 foot frame at game %.3f → session %@, setup stage shown %@ · running again after %.2f s of steady evidence · game time advanced %.3f s meanwhile",
                     before, "\(pausedPhase)", "\(stage)", recovered, after - before))
        #expect(pausedPhase == .paused, "PR #46 policy: a single unusable running frame pauses the round")
        #expect(!stage, "the paused round stays over the game, never under the setup stage")
        #expect(session.phase == .running && session.state?.teamHealth != nil, "it recovers by itself, round kept")
        await session.stop()
    }

    /// A flicker about once a second (one frame in 30): how much of 30 s is actually played?
    @Test func aFlickerOnceASecondKeepsTheRoundMostlyPaused() async throws {
        let (rig, start) = try await Self.runningRig()
        let session = rig.session
        var time = start
        let gameStart = try #require(session.state?.gameTime)
        var pauses = 0, frames = 0, runningFrames = 0, previous = session.phase
        while time < start + 30 {
            frames += 1
            let flicker = frames % 30 == 0
            try await rig.send(time, bodySamples: flicker ? try Self.footDropout(rig) : nil); time += Self.step
            if session.phase == .running { runningFrames += 1 }
            if previous != .paused, session.phase == .paused { pauses += 1 }
            previous = session.phase
        }
        let played = try #require(session.state?.gameTime) - gameStart
        print(String(format: "[RobustnessEvidence] 30 s with one dropped foot frame per second: %d pauses · game time advanced %.2f s · running in %d of %d frames",
                     pauses, played, runningFrames, frames))
        #expect(pauses >= 5, "each flicker during play pauses")
        #expect(played < 15, "most of the time is spent paused, settling or counting down")
        await session.stop()
    }
}
