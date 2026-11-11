import Foundation
import Testing
@testable import Sedactive

/// Automatic onboarding: each step happens by itself only when the same producer conditions
/// its old button required hold. Real B2 gate receipts; calibration candidates and CP1 packets
/// are the existing controlled fixtures. The setup tick is stepped by hand for determinism.
@MainActor struct LaserAutomaticSetupTests {
    private static func rig() throws -> J07SessionRig {
        let calibrations = try LaserReplayScript.load().input.configuration.calibrations
        return try J07SessionRig(deferredPlan: true, liveRoundPlanner: { context, _ in
            try LaserLiveWristRoundPlan.completeRound(context: context, calibrations: calibrations,
                layout: .init(leftCenterX: -1, rightCenterX: 1, gameUnitsPerImageHeight: 2))
        }, automaticSetup: true)
    }

    /// Camera frames keep arriving while the screen waits (fresh pair evidence), with a tick each.
    @discardableResult
    private static func frames(_ rig: J07SessionRig, from start: Double, seconds: Double) async throws -> Double {
        var time = start
        while time < start + seconds {
            try await rig.send(time); rig.session.advanceSetupAutomatically(); time += 0.125
        }
        return time
    }

    /// Links, prompts, calibrates and accepts with no button; returns the next frame time.
    @discardableResult
    private static func linkAndCalibrate(_ rig: J07SessionRig) async throws -> Double {
        let session = rig.session, controls = rig.controls
        try await session.start()
        session.advanceSetupAutomatically()
        #expect(controls.armCalls == 1, "pair search armed by itself")
        #expect(session.presence.players.values.allSatisfy { $0 == .searching })
        try controls.bindPair() // the genuine pair acknowledgment
        session.advanceSetupAutomatically()
        #expect(session.setup?.hasConfirmedReliablePair == true, "linked by itself once the pair is reliable")
        session.advanceSetupAutomatically()
        #expect(session.presence.promptingUpright && controls.calibrationRequests == 0,
                "players are asked to stand upright BEFORE any sample is taken")
        var time = try await frames(rig, from: 0.25, seconds: LaserAutomaticSetupPolicy.uprightPrompt + 0.25)
        #expect(controls.calibrationRequests == 1 && session.presence.attempts == 1)
        controls.showCandidate(validated: false) // stable estimates for both players
        session.advanceSetupAutomatically()
        #expect(controls.confirmCalls == 1, "accepted by itself")
        rig.fixture = try WristGameplayFixture(generation: controls.fixture.context.generation,
                                               binding: try #require(controls.tracking.acknowledgment))
        controls.input.replaceContext(rig.fixture.context)
        session.advanceSetupAutomatically()
        #expect(session.presence.players.values.allSatisfy { $0 == .ready })
        time += 0.125
        return time
    }

    @Test func detectedPlayersReachGameplayWithoutAnyButton() async throws {
        let rig = try Self.rig(), session = rig.session
        var time = try await Self.linkAndCalibrate(rig)
        #expect(session.hasLiveRoundPlan && session.state == nil)
        let host = try session.attachLiveFrameHost(); session.advanceLive(frameHost: host)
        while session.phase != .countdown, time < 10 {
            try await rig.send(time); session.advanceSetupAutomatically(); time += 0.125
        }
        #expect(session.phase == .countdown, "countdown starts by itself once both are ready")
        #expect(session.state == nil, "no game time is spent during the countdown")
        while session.phase != .running, time < 16 {
            try await rig.send(time); session.advanceSetupAutomatically(); time += 0.125
        }
        #expect(session.phase == .running && (session.state?.gameTime ?? 1) < 0.2)
        await session.stop()
    }

    @Test func losingTrackingDuringTheCountdownCancelsItAndItRestartsByItself() async throws {
        let rig = try Self.rig(), session = rig.session
        var time = try await Self.linkAndCalibrate(rig)
        let host = try session.attachLiveFrameHost(); session.advanceLive(frameHost: host)
        while session.phase != .countdown, time < 10 { try await rig.send(time); session.advanceSetupAutomatically(); time += 0.125 }
        #expect(session.phase == .countdown)
        // P1's measurements become unusable (tracking uncertain) while frames keep arriving.
        try await rig.send(time, bad: "unbound"); session.advanceSetupAutomatically(); time += 0.125
        #expect(session.phase == .paused && session.state == nil, "countdown cancelled: no round, no clock")
        let copy = LaserAutomaticSetupCopy(.init(sessionPhase: session.phase, setupPhase: session.setup?.phase,
            presence: session.presence, hasRoundPlan: true, roundStarted: false))
        #expect(copy.title == "Get back in position" && copy.action == nil)
        while session.phase != .countdown, time < 20 { try await rig.send(time); session.advanceSetupAutomatically(); time += 0.125 }
        #expect(session.phase == .countdown, "fresh evidence restarts the countdown without a button")
        await session.stop()
    }

    @Test func inconsistentEstimatesAreRefusedRetriedAndThenLeftToThePlayers() async throws {
        let rig = try Self.rig(), session = rig.session, controls = rig.controls
        try await session.start()
        session.advanceSetupAutomatically(); try controls.bindPair()
        session.advanceSetupAutomatically(); session.advanceSetupAutomatically()
        var time = 0.25
        for attempt in 1...LaserAutomaticSetupPolicy.maximumAttempts {
            time = try await Self.frames(rig, from: time, seconds: LaserAutomaticSetupPolicy.uprightPrompt + 0.25)
            #expect(controls.calibrationRequests == attempt)
            // Head-top below the nose: refused, never confirmed.
            controls.showCandidate(validated: false, crownY: 0.7)
            session.advanceSetupAutomatically()
            guard case .blocked = session.setup?.phase else { Issue.record("attempt \(attempt) not blocked"); return }
            #expect(controls.confirmCalls == 0)
            // Retry after the delay (cancels this attempt) while attempts remain.
            time = try await Self.frames(rig, from: time, seconds: LaserAutomaticSetupPolicy.retryDelay + 0.25)
        }
        // Out of automatic attempts: it stops and says what to do; nothing was accepted.
        time = try await Self.frames(rig, from: time, seconds: 4)
        #expect(controls.calibrationRequests == LaserAutomaticSetupPolicy.maximumAttempts)
        #expect(!session.presence.willRetry && controls.confirmCalls == 0)
        #expect(session.inputContext?.calibrationRevisions.isEmpty == true && !session.hasLiveRoundPlan)
        let copy = LaserAutomaticSetupCopy(.init(sessionPhase: session.phase, setupPhase: session.setup?.phase,
                                                 presence: session.presence))
        #expect(copy.action == .tryAgain)
        // The players ask to try again: a fresh prompt, then a fresh request.
        session.retryCalibrationManually()
        time = try await Self.frames(rig, from: time, seconds: LaserAutomaticSetupPolicy.uprightPrompt + 0.25)
        #expect(controls.calibrationRequests == LaserAutomaticSetupPolicy.maximumAttempts + 1)
        await session.stop()
    }

    @Test func manualSessionsNeverAdvanceThemselves() async throws {
        let rig = try J07SessionRig(deferredPlan: true)
        try await rig.session.start()
        rig.session.advanceSetupAutomatically()
        #expect(rig.controls.armCalls == 0 && !rig.session.automaticSetup)
        await rig.session.stop()
    }

    @Test func playerFacingCopyHasNoTechnicalTerms() {
        let phases: [LaserSetupPhase] = [.inactive, .awaitingBinding, .binding, .confirmPlayers, .waitingForReliablePair,
            .awaitingCalibration, .calibrating, .reviewCandidate, .awaitingGameplayReadiness, .blocked("x"), .restartRequired]
        var texts: [String] = []
        for phase in phases {
            for people in 0...2 {
                var presence = LaserSetupPresence(); presence.peopleInView = people
                presence.players = [.player1: .calibrating(progress: 0.4, issue: .feetCutOff), .player2: .ready]
                let copy = LaserAutomaticSetupCopy(.init(sessionPhase: .awaitingSetup, setupPhase: phase, presence: presence))
                texts += [copy.title, copy.instruction]
            }
        }
        for issue in StandingSampleIssue.allCases {
            texts += [LaserAutomaticSetupCopy.hint(issue), LaserAutomaticSetupCopy.shortHint(issue)]
        }
        for status in [LaserSetupPlayerStatus.searching, .linked, .calibrating(progress: 0.6, issue: nil), .ready] {
            texts.append(LaserAutomaticSetupCopy.chip(.player1, status))
        }
        for text in texts {
            for word in ["B2", "E07", "E05", "J03", "crown", "sole", "calibration revision", "candidate", "anatomy"] {
                #expect(!text.localizedCaseInsensitiveContains(word), "\(word) in \"\(text)\"")
            }
        }
        #expect(LaserAutomaticSetupCopy.chip(.player2, .calibrating(progress: 0.6, issue: nil)) == "P2 · 60%")
    }
}
