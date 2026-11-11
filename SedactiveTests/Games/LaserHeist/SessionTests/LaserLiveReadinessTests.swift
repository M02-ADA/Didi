import Foundation
import Testing
@testable import Sedactive

nonisolated struct LaserLiveReadinessTests {
    private let generation = UUID(uuidString: "33000000-0000-4000-8000-000000000001")!
    private var context: BodyInputContext {
        BodyInputContext(sessionGeneration: generation, cameraGeometryRevision: 1,
                         calibrationRevisions: [.player1: 1, .player2: 1], cutovers: [:], isActive: true)
    }
    private func packet(_ frame: UInt64, _ time: Double, valid: Bool = true) throws -> BodySnapshot {
        let base = try LH00TestData.load().records.first!.snapshot!
        let players = try base.players.mapValues { sample in
            let crown = valid ? sample.geometry.crownY : try EstimatedScalar(value: nil, validity: .notCalibrated)
            return PlayerBodySample(playerID: sample.playerID, calibrationRevision: 1, trackingStatus: .reliable,
                geometry: BodyGeometry(crownY: crown, leftWristY: sample.geometry.leftWristY,
                    rightWristY: sample.geometry.rightWristY, leftSoleY: sample.geometry.leftSoleY,
                    rightSoleY: sample.geometry.rightSoleY, centerX: sample.geometry.centerX),
                jumpState: sample.jumpState)
        }
        return BodySnapshot(sessionGeneration: generation, frameID: frame, capturedAt: time,
                            cameraGeometryRevision: 1, players: players)
    }
    private func runtime() throws -> LaserLiveReadiness {
        LaserLiveReadiness(policy: try LaserLiveTimingPolicy(settlingDuration: 0.125,
            maximumEvidenceAge: 0.5, countdownDuration: 0.25)) // Controlled fixture values only.
    }
    private func running() throws -> LaserLiveReadiness {
        var value = try runtime()
        try value.observe(packet(1, 1000), context: context, bindingConfirmed: true, at: 1000)
        try value.observe(packet(2, 1000.125), context: context, bindingConfirmed: true, at: 1000.125)
        try value.beginCountdown(at: 1000.125)
        try value.observe(packet(3, 1000.25), context: context, bindingConfirmed: true, at: 1000.25)
        try value.observe(packet(4, 1000.375), context: context, bindingConfirmed: true, at: 1000.375)
        return value
    }

    @Test func calibrationAndBindingNeverReplaceRequiredHumanMeasurements() throws {
        var value = try runtime()
        try value.observe(packet(1, 1), context: context, bindingConfirmed: false, at: 1)
        #expect(value.phase == .blocked(.binding))
        try value.observe(packet(2, 2, valid: false), context: context, bindingConfirmed: true, at: 2)
        #expect(value.phase == .blocked(.measurements))
        #expect(value.gameTime == 0)
        #expect(throws: LaserDataError.self) { try value.beginCountdown(at: 2) }
        let empty = BodyInputContext(sessionGeneration: generation, cameraGeometryRevision: 1,
                                    calibrationRevisions: [:], cutovers: [:], isActive: true)
        try value.observe(packet(3, 3), context: empty, bindingConfirmed: true, at: 3)
        #expect(value.phase == .blocked(.calibration))
    }

    @Test func absentApprovedTimingPolicyCannotBecomeReady() throws {
        var value = LaserLiveReadiness()
        try value.observe(packet(1, 1), context: context, bindingConfirmed: true, at: 1)
        #expect(value.phase == .blocked(.timingPolicy))
        #expect(throws: LaserDataError.self) { try value.beginCountdown(at: 1) }
    }

    @Test func heldOrDuplicatePoseCannotCompleteSettling() throws {
        var value = try runtime()
        let first = try packet(1, 1)
        try value.observe(first, context: context, bindingConfirmed: true, at: 1)
        try value.observe(first, context: context, bindingConfirmed: true, at: 1.125)
        #expect(value.phase == .settling)
        try value.observe(packet(2, 1.25), context: context, bindingConfirmed: true, at: 1.25)
        #expect(value.phase == .ready)
        try value.evaluate(at: 1.75) // Exact expiry boundary, without another camera frame.
        #expect(value.phase == .blocked(.staleEvidence))
    }

    @Test func hostOffsetAndCountdownDoNotConsumeActivityTime() throws {
        var value = try running()
        #expect(value.phase == .running && value.gameTime == 0)
        try value.evaluate(at: 1000.5)
        #expect(value.gameTime == 0.125)
        #expect(value.capturedGameTime(for: try packet(5, 1000.5)) == 0.125)
        #expect(value.capturedGameTime(for: try packet(3, 1000.25)) == nil)
    }

    #if DEBUG
    /// DEBUG Solo Test: once running, missing/stale evidence and a lost binding keep the clock
    /// running (the tester walks to the iPad); the default (co-op) still pauses. Before the
    /// round runs, and on a manual pause, the normal rules hold.
    @Test(arguments: [true, false])
    func soloKeepsRunningWithoutEvidenceOnlyWhenEnabled(solo: Bool) throws {
        var value = try running()
        value.continuesWithoutEvidence = solo
        try value.observe(packet(5, 1000.5, valid: false), context: context, bindingConfirmed: true, at: 1000.5)
        try value.observe(packet(6, 1000.6), context: context, bindingConfirmed: false, at: 1000.6)
        try value.evaluate(at: 1003)
        if solo {
            #expect(value.phase == .running && value.gameTime > 2.5, "clock keeps running with no evidence")
            // Tracking returns after a long gap: admitted again, never a pause.
            try value.observe(packet(7, 1003.1), context: context, bindingConfirmed: true, at: 1003.1)
            #expect(value.phase == .running)
            try value.evaluate(at: 1003.25)
            #expect(value.capturedGameTime(for: try packet(8, 1003.2)) != nil, "its frames are evidence again")
            try value.setManualPause(true, at: 1003.3)
            #expect(value.phase == .paused, "the pause button still pauses")
        } else {
            #expect(value.phase == .paused)
        }
    }
    #endif

    @Test func noFrameExpiryPausesAndManualBlockerSurvivesTrackingRecovery() throws {
        var value = try running()
        try value.evaluate(at: 1000.875)
        #expect(value.phase == .paused && value.blocker == .staleEvidence)
        let pausedTime = value.gameTime
        try value.setManualPause(true, at: 1001)
        try value.observe(packet(10, 1001.125), context: context, bindingConfirmed: true, at: 1001.125)
        #expect(value.phase == .paused && value.blocker == .manualPause)
        #expect(value.gameTime == pausedTime)
        try value.setManualPause(false, at: 1001.25)
        try value.observe(packet(11, 1001.375), context: context, bindingConfirmed: true, at: 1001.375)
        try value.observe(packet(12, 1001.5), context: context, bindingConfirmed: true, at: 1001.5)
        #expect(value.phase == .ready)
        try value.beginCountdown(at: 1001.5)
        try value.observe(packet(13, 1001.625), context: context, bindingConfirmed: true, at: 1001.625)
        try value.observe(packet(14, 1001.75), context: context, bindingConfirmed: true, at: 1001.75)
        #expect(value.phase == .running && value.gameTime == pausedTime)
        #expect(value.capturedGameTime(for: try packet(10, 1001.125)) == nil)
    }

    @Test func pauseCutoverRejectsLatePrePauseEvidence() throws {
        var value = try running()
        try value.setManualPause(true, at: 1000.5)
        try value.setManualPause(false, at: 1000.5)
        try value.observe(packet(5, 1000.4), context: context, bindingConfirmed: true, at: 1000.6)
        #expect(value.phase == .paused)
        try value.observe(packet(6, 1000.625), context: context, bindingConfirmed: true, at: 1000.625)
        #expect(value.phase == .settling)
    }

    @Test func acceptedContextChangeRequiresNewRoundEvenIfOldRevisionsReturn() throws {
        var value = try running()
        let removed = BodyInputContext(sessionGeneration: generation, cameraGeometryRevision: 1,
                                      calibrationRevisions: [.player1: 1], cutovers: [:], isActive: true)
        try value.updateContext(removed, at: 1000.5)
        #expect(value.phase == .restartRequired)
        try value.observe(packet(8, 1000.625), context: context, bindingConfirmed: true, at: 1000.625)
        #expect(value.phase == .restartRequired)
        #expect(value.capturedGameTime(for: try packet(8, 1000.625)) == nil)
    }

    @Test func bindingStatusCanPauseWithoutAFrameOrContextChange() throws {
        var value = try running()
        try value.invalidateBinding(at: 1000.5)
        let time = value.gameTime
        #expect(value.phase == .paused && value.blocker == .binding)
        try value.evaluate(at: 2000)
        #expect(value.phase == .paused && value.gameTime == time)
    }

    @Test func lateUnavailablePacketCannotReplaceNewerReliableReadiness() throws {
        var value = try running()
        try value.observe(packet(3, 1000.25, valid: false), context: context,
                          bindingConfirmed: true, at: 1000.5)
        #expect(value.phase == .running && value.blocker == nil)
        #expect(value.gameTime == 0.125)
    }
}
