import Foundation
import Testing
@testable import Sedactive

/// The in-round tracking warning (`LaserHeistUI/Recalibrate`): when it shows, what it offers, and
/// that it follows the session's own pause without flicker (13 November 2026).
nonisolated struct LaserTrackingWarningModelTests {
    typealias W = LaserTrackingWarning

    @Test func onlyATrackingPauseOfAStartedRoundShowsIt() {
        let lost = W.Input(roundStarted: true, sessionPhase: .paused, readinessBlocker: .measurements, attention: [.player2: .tracking])
        #expect(W.triggers(lost) && W(lost).stage == .waitingForPlayers && W(lost).detail.hasPrefix("P2: step back into your place."))
        #expect(!W.triggers(W.Input(roundStarted: false, sessionPhase: .paused, attention: [.player2: .tracking])), "not before the round")
        #expect(!W.triggers(W.Input(roundStarted: true, roundEnded: true, sessionPhase: .paused, attention: [.player2: .tracking])))
        #expect(!W.triggers(W.Input(roundStarted: true, sessionPhase: .paused, readinessBlocker: .manualPause, hasPacket: false)))
        #expect(!W.triggers(W.Input(roundStarted: true, sessionPhase: .paused, readinessBlocker: .presentation, hasPacket: false)))
        #expect(!W.triggers(W.Input(roundStarted: true, sessionPhase: .running, attention: [.player1: .tracking])))
        // A tracked player's hidden wrist (a duck with the hands behind): the setup hint, not the warning.
        #expect(!W.triggers(W.Input(roundStarted: true, sessionPhase: .paused, readinessBlocker: .measurements, attention: [.player1: .hands])))
        #expect(W.triggers(W.Input(roundStarted: true, sessionPhase: .paused, readinessBlocker: .binding)))
        #expect(W.triggers(W.Input(roundStarted: true, sessionPhase: .paused, hasPacket: false)), "no usable packet: nobody tracked")
    }

    @Test func aLostIdentityOffersRecalibrateAndAResumeNeverDoes() {
        let identity = W(W.Input(roundStarted: true, sessionPhase: .paused, setupPhase: .restartRequired, awaitsIdentityRecovery: true))
        #expect(identity.stage == .needsRecalibration && identity.primary == .recalibrate)
        let back = W(W.Input(roundStarted: true, sessionPhase: .paused, readinessBlocker: .staleEvidence))
        #expect(back.stage == .recovering && back.primary == nil)
        let tap = W(W.Input(roundStarted: true, sessionPhase: .paused, recoveryNeedsContinue: true))
        #expect(tap.primary == .continueRound)
        let solo = W(W.Input(roundStarted: true, sessionPhase: .paused, setupPhase: .restartRequired, solo: true))
        #expect(solo.stage != .needsRecalibration, "Solo re-links its one player")
    }

    @Test func theLatchHoldsForThePauseAndClearsWhenItEnds() {
        var latch = LaserTrackingWarningLatch()
        let gone = W.Input(roundStarted: true, sessionPhase: .paused, readinessBlocker: .measurements, attention: [.player2: .tracking])
        let feetOnly = W.Input(roundStarted: true, sessionPhase: .paused, readinessBlocker: .measurements, attention: [.player2: .feet])
        #expect(latch.update(feetOnly) == nil, "a landmark-only pause alone does not raise it")
        #expect(latch.update(gone)?.stage == .waitingForPlayers)
        #expect(latch.update(feetOnly)?.stage == .waitingForPlayers, "half back in view: no flicker to the setup stage")
        #expect(latch.update(W.Input(roundStarted: true, sessionPhase: .paused))?.stage == .recovering)
        #expect(latch.update(W.Input(roundStarted: true, sessionPhase: .countdown)) == nil, "the countdown ends it")
        #expect(latch.update(feetOnly) == nil, "a new pause starts unlatched")
    }
}

/// The same warning from the REAL session: production round plan and timing, the real tracker in
/// the setup gate. SYNTHETIC pose and CP1 inputs; it proves the presentation follows the session,
/// not how Vision tracks real people.
@MainActor struct LaserTrackingWarningSessionTests {
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
        for _ in 0..<15 { try await rig.send(time); time += step }
        try #require(session.phase == .running)
        return (rig, time)
    }

    /// CP1 samples with `gone` untracked (left the view), the rest as calibrated.
    private static func samples(_ rig: J07SessionRig, gone: Set<PlayerID>, hiddenWrists: Set<PlayerID> = []) throws
        -> [PlayerID: PlayerBodySample] {
        var samples = rig.fixture.players
        let missing = try EstimatedScalar(value: nil, validity: .missingLandmarks)
        for player in gone {
            samples[player] = PlayerBodySample(playerID: player, calibrationRevision: samples[player]?.calibrationRevision,
                trackingStatus: .uncertain, geometry: .init(crownY: missing, leftWristY: missing, rightWristY: missing,
                    leftSoleY: missing, rightSoleY: missing, centerX: missing), jumpState: .init(phase: .unknown, validity: .missingLandmarks))
        }
        for player in hiddenWrists {
            let s = try #require(samples[player]), g = s.geometry
            samples[player] = PlayerBodySample(playerID: player, calibrationRevision: s.calibrationRevision, trackingStatus: s.trackingStatus,
                geometry: .init(crownY: g.crownY, leftWristY: missing, rightWristY: missing, leftSoleY: g.leftSoleY,
                                rightSoleY: g.rightSoleY, centerX: g.centerX), jumpState: s.jumpState)
        }
        return samples
    }

    /// The pose candidates in view (`LiveVisionFixtures.standingPair`: candidate 10 is P1, 20 is P2).
    private static func people(without gone: Set<PlayerID>) -> [PoseCandidate] {
        LiveVisionFixtures.standingPair.filter { c in
            !(gone.contains(.player1) && c.candidateID == 10) && !(gone.contains(.player2) && c.candidateID == 20)
        }
    }

    /// Frame-by-frame warning record through the same latch the screen uses.
    struct Record {
        var stages: [LaserTrackingWarning.Stage?] = []
        var latch = LaserTrackingWarningLatch()
        mutating func observe(_ session: GameSessionCoordinator) { stages.append(latch.update(.init(session: session))?.stage) }
        /// Whether, once shown, the warning stayed up until the pause ended (no flicker).
        var shownWithoutFlicker: Bool {
            guard let first = stages.firstIndex(where: { $0 != nil }) else { return false }
            let rest = stages[first...]
            guard let end = rest.firstIndex(where: { $0 == nil }) else { return true }
            return rest[end...].allSatisfy { $0 == nil }
        }
    }

    /// P1 out of view (the fixture's consistent untracked P1 packet; the real tracker sees P1, or
    /// both players, gone). P2 alone is the same path with the roles swapped.
    @Test(arguments: [Set([PlayerID.player1]), Set(PlayerID.allCases)])
    func playersLeavingBrieflyShowTheWarningThenResumeWithoutRecalibration(gone: Set<PlayerID>) async throws {
        let (rig, start) = try await Self.runningRig()
        let session = rig.session
        var time = start, record = Record()
        let before = try #require(session.state), calibrations = session.inputContext?.calibrationRevisions
        for _ in 0..<15 { // half a second out of view (within the tracker's identity gap)
            try await rig.send(time, bad: "unbound", people: Self.people(without: gone)); time += Self.step
            record.observe(session)
        }
        #expect(session.phase == .paused && record.stages.last == .waitingForPlayers, "paused, warning up (\(gone))")
        var sawRecovering = false
        while session.phase != .running, time < start + 20 {
            try await rig.send(time); time += Self.step
            record.observe(session)
            sawRecovering = sawRecovering || record.stages.last == .recovering
        }
        #expect(session.phase == .running && (record.stages.last ?? nil) == nil, "resumed, warning dismissed")
        #expect(sawRecovering && record.shownWithoutFlicker)
        #expect(!record.stages.contains(.needsRecalibration), "same players: never asked to recalibrate")
        #expect(session.inputContext?.calibrationRevisions == calibrations && session.setup?.phase != .restartRequired)
        let after = try #require(session.state)
        #expect(after.teamHealth == before.teamHealth && after.teamScore == before.teamScore
                && after.missionProgress == before.missionProgress, "progress kept")
        await session.stop()
    }

    /// A player out of view past the tracker's identity gap: the warning first, then it asks for
    /// Recalibrate (the existing setup restart); it never resumes on its own, never flickers.
    @Test func aPlayerGoneTooLongNeedsRecalibrationAfterTheWarning() async throws {
        let (rig, start) = try await Self.runningRig()
        let session = rig.session
        var time = start, record = Record()
        for _ in 0..<60 { // two seconds out of view
            try await rig.send(time, bad: "unbound", people: Self.people(without: [.player1]))
            time += Self.step
            record.observe(session)
        }
        for _ in 0..<150 { try await rig.send(time); time += Self.step; record.observe(session) } // back, 5 s
        let first = try #require(record.stages.firstIndex { $0 != nil })
        let recalibrate = try #require(record.stages.firstIndex { $0 == .needsRecalibration }, "\(record.stages.compactMap { $0 })")
        #expect(first < recalibrate && record.stages[first] == .waitingForPlayers, "the warning shows before Recalibrate is required")
        #expect(record.stages.last == .needsRecalibration && session.phase == .paused && record.shownWithoutFlicker)
        #expect(session.state != nil, "the round is held (not discarded) until the players choose Recalibrate")
        await session.stop()
    }

    /// A duck with the hands hidden: the session pauses (Jevon's readiness, unchanged) but this is
    /// not tracking loss: no warning, no recalibration, it resumes by itself.
    @Test func hiddenWristsDoNotShowTheWarning() async throws {
        let (rig, start) = try await Self.runningRig()
        let session = rig.session
        var time = start, record = Record()
        for _ in 0..<20 {
            try await rig.send(time, bodySamples: try Self.samples(rig, gone: [], hiddenWrists: [.player1])); time += Self.step
            record.observe(session)
        }
        #expect(record.stages.allSatisfy { $0 == nil }, "paused for the wrists (today's readiness) or running: no warning")
        while session.phase != .running, time < start + 20 { try await rig.send(time); time += Self.step; record.observe(session) }
        #expect(session.phase == .running && record.stages.allSatisfy { $0 == nil } && session.setup?.phase != .restartRequired)
        await session.stop()
    }

    // MARK: - Screen order during a started round (iPad, 13 November 2026: the calibration
    // stage showed BEFORE the warning in a squat)

    /// What the players see each frame: the camera setup stage, the full warning, or the game.
    enum Shown: Equatable { case game, setupStage, warning(LaserTrackingWarning.Stage) }

    /// A deep squat with the hands behind: first only landmarks are missing (hips, wrists, soles
    /// while tracking still reads reliable: the round pauses on measurements), then the tracker
    /// loses the hips for 1.5 s, then the player stands. The setup stage must never come first.
    @Test func aSquatNeverShowsTheSetupStageBeforeTheWarning() async throws {
        let (rig, start) = try await Self.runningRig()
        let session = rig.session
        var time = start, latch = LaserTrackingWarningLatch(), shown: [Shown] = []
        func observe() {
            let warning = latch.update(.init(session: session))
            // Top-most first, as RootView stacks them: the warning above the setup stage above the game.
            shown.append(warning.map { .warning($0.stage) } ?? (ContentView.showsSetupStage(session) ? .setupStage : .game))
        }
        let squatting = LiveVisionFixtures.standingPair.map { c -> PoseCandidate in
            guard c.candidateID == 10 else { return c }
            var joints = c.joints
            joints.removeValue(forKey: .leftHip); joints.removeValue(forKey: .rightHip)
            return .init(candidateID: c.candidateID, joints: joints, maskTopImageY: nil, maskBottomImageY: nil,
                         leftFootBottomImageY: nil, rightFootBottomImageY: nil, maskAssociation: .unavailable)
        }
        for _ in 0..<6 { // landmarks only (tracking still reliable)
            try await rig.send(time, bodySamples: try Self.samples(rig, gone: [], hiddenWrists: [.player1])); time += Self.step
            observe()
        }
        for _ in 0..<45 { // the tracker loses the hips
            try await rig.send(time, bodySamples: try Self.samples(rig, gone: [], hiddenWrists: [.player1]), people: squatting)
            time += Self.step
            observe()
        }
        for _ in 0..<150 { try await rig.send(time); time += Self.step; observe() } // standing, 5 s
        let firstWarning = shown.firstIndex { if case .warning = $0 { true } else { false } }
        let firstStage = shown.firstIndex(of: .setupStage)
        print("[WarningOrder] squat: first warning frame \(String(describing: firstWarning)) · first setup-stage frame \(String(describing: firstStage)) · last \(String(describing: shown.last)) · session \(session.phase)")
        #expect(firstStage == nil, "during a started round the calibration/setup stage is never the top screen (first at frame \(firstStage ?? -1))")
        #expect(!ContentView.showsSetupStage(session) || session.state == nil, "not even beneath the warning while the round is held")
        #expect(firstWarning != nil, "the warning shows")
        await session.stop()
    }

    /// Identity lost in a held round: the warning is the top screen with Recalibrate (the setup
    /// stage is not even beneath it); only after Recalibrate does the calibration stage show, for a
    /// NEW session with no round and no calibrations, under which the warning cannot show.
    @Test func identityLossShowsTheWarningFirstAndCalibrationOnlyAfterRecalibrate() async throws {
        let (rig, start) = try await Self.runningRig()
        let session = rig.session
        var time = start
        for _ in 0..<60 { try await rig.send(time, bad: "unbound", people: Self.people(without: [.player1])); time += Self.step }
        for _ in 0..<60 { try await rig.send(time); time += Self.step }
        let held = LaserTrackingWarningLatch().peek(.init(session: session))
        #expect(held?.stage == .needsRecalibration && held?.primary == .recalibrate, "the warning offers Recalibrate")
        #expect(!ContentView.showsSetupStage(session), "no calibration stage beneath the held round")
        await session.stop()

        // Recalibrate = the flow's existing restart (`flow.retryLiveSetup`): a new session.
        let driver = ControlledCameraDriver()
        let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized), driver: driver)
        let provider = BodyInputService(camera: camera)
        let flow = LaserInputFlow(makeLiveSession: {
            GameSessionCoordinator(liveProvider: provider, inputConfiguration: LiveVisionFixtures.configuration(UUID()))
        })
        await flow.startLiveSetup()
        let before = try #require(flow.session)
        await flow.retryLiveSetup()
        let fresh = try #require(flow.session)
        #expect(fresh !== before && fresh.state == nil && provider.currentContext?.calibrationRevisions.isEmpty == true,
                "a fresh binding and calibration: nothing inherited")
        #expect(ContentView.showsSetupStage(fresh), "the calibration stage shows for the new setup")
        #expect(LaserTrackingWarningLatch().peek(.init(session: fresh)) == nil, "and the warning never over it")
        await flow.closeLiveSetup()
    }

    /// A manual pause and a hidden-landmark pause stay over the game: the HUD pause menu or the
    /// compact notice, never the warning or the setup stage.
    @Test func otherPausesStayOverTheGameWithoutTheWarning() async throws {
        let (rig, start) = try await Self.runningRig()
        let session = rig.session
        var time = start
        try await rig.send(time, bodySamples: try Self.samples(rig, gone: [], hiddenWrists: [.player2])); time += Self.step
        let input = LaserTrackingWarning.Input(session: session)
        #expect(!ContentView.showsSetupStage(session) && LaserTrackingWarningLatch().peek(input) == nil)
        if session.phase == .paused { // today's readiness pauses on a hidden wrist; the notice names it
            #expect(LaserRoundPauseNotice(input)?.text.contains("P2: keep your hands in view.") == true, "\(String(describing: LaserRoundPauseNotice(input)))")
        }
        while session.phase != .running, time < start + 10 { try await rig.send(time); time += Self.step }
        session.pauseLiveRound()
        let manual = LaserTrackingWarning.Input(session: session)
        #expect(session.phase == .paused && !ContentView.showsSetupStage(session))
        #expect(LaserTrackingWarningLatch().peek(manual) == nil && LaserRoundPauseNotice(manual) == nil, "the HUD's pause menu")
        await session.stop()
    }
}
