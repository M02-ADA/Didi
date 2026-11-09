import Foundation
import Testing
@testable import Sedactive

@MainActor
struct LiveGameLoopTests {
    @Test func countdownAndOriginalCaptureReachProductionJudgeAtEqualDeadline() async throws {
        let rig = try LiveGameRig()
        try await rig.run()
        #expect(rig.session.phase == .running && rig.session.state?.gameTime == 0)
        for time in [0.75, 0.875, 1.0] { try await rig.send(time, crown: 2) }
        #expect(rig.session.state?.teamScore == 0)
        // Crossing is game 0.5 / host 1.125; the capture arrives at the game 0.75 deadline.
        try await rig.send(1.125, arrivedAt: 1.375, notifyBeforeDelivery: true)
        #expect(rig.session.results.map(\.judgement) == [.clear, .clear])
        #expect(rig.session.state?.teamScore == 200 && rig.session.state?.teamHealth == 5)
        #expect(rig.controls.input.claimCount == 1 && rig.controls.input.observerCount == 1)
        await rig.session.stop()
    }

    @Test func manualPauseFreezesTotalsAndReplansFreshFullWarningAttempt() async throws {
        let rig = try LiveGameRig(planner: Self.recovery)
        try await rig.run()
        try await rig.send(0.75)
        let attempt = rig.session.encounters[0].attemptID
        rig.session.pauseLiveRound()
        let frozen = rig.session.state?.gameTime
        for time in [0.875, 1.0, 1.125, 1.25] { try await rig.send(time) }
        #expect(rig.session.phase == .paused && rig.session.state?.gameTime == frozen)
        #expect(rig.session.state?.teamScore == 0 && rig.session.state?.teamHealth == 5)
        rig.session.continueLiveRound()
        for time in [1.375, 1.5, 1.625, 1.75] { try await rig.send(time) }
        #expect(rig.session.phase == .running && rig.session.state?.gameTime == frozen)
        #expect(rig.session.encounters[0].attemptID != attempt)
        #expect(rig.session.encounters[0].targets[0].warningTime >= frozen!)
        #expect(rig.session.events.filter { if case .attemptWithdrawn = $0.kind { true } else { false } }.count == 1)
        for index in 15...20 { try await rig.send(Double(index) * 0.125) }
        #expect(rig.session.state?.teamScore == 200 && rig.session.state?.teamHealth == 5)
        #expect(rig.controls.input.claimCount == 1)
        await rig.session.stop()
    }

    @Test func missingRequiredMeasurementWithdrawsWithoutDamageAndMissingPlannerHoldsPause() async throws {
        let rig = try LiveGameRig()
        try await rig.run()
        try await rig.send(0.75)
        try await rig.send(0.875, crown: nil)
        #expect(rig.session.phase == .paused)
        let time = rig.session.state?.gameTime
        for value in [1.0, 1.125, 1.25, 1.375] { try await rig.send(value) }
        #expect(rig.session.phase == .paused && rig.session.recoveryNeedsPlan)
        #expect(rig.session.state?.gameTime == time)
        #expect(rig.session.state?.teamScore == 0 && rig.session.state?.teamHealth == 5)
        await rig.session.stop()
    }

    @Test func unsafeRecoveryCannotReuseOldAttemptOrShortenWarning() async throws {
        for shortWarning in [false, true] {
            let rig = try LiveGameRig(planner: { request in
                if !shortWarning { return request.withdrawn }
                return try request.withdrawn.map { old in
                    try LaserEncounter(id: old.id, attemptID: UUID(), targets: old.targets.map {
                        try LaserTarget(playerID: $0.playerID, calibrationRevision: $0.calibrationRevision,
                            requiredMove: $0.requiredMove, beam: $0.beam,
                            warningTime: request.gameTime, crossingTime: request.gameTime + 0.125)
                    })
                }
            })
            try await rig.run()
            try await rig.send(0.75, crown: nil)
            for time in [0.875, 1.0, 1.125] { try await rig.send(time) }
            #expect(rig.session.phase == .paused && rig.session.recoveryNeedsPlan)
            #expect(rig.session.state?.teamScore == 0 && rig.session.state?.teamHealth == 5)
            await rig.session.stop()
        }
    }

    @Test func noFrameBindingExpiryFreezesBeforeAnyBackloggedVerdict() async throws {
        let rig = try LiveGameRig()
        try await rig.run()
        try await rig.send(0.75)
        rig.controls.fixture.clock.time = 1.25
        rig.session.advanceLive()
        #expect(rig.session.phase == .paused)
        #expect(rig.session.state?.teamScore == 0 && rig.session.state?.teamHealth == 5)
        #expect(rig.session.results.isEmpty)
        let time = rig.session.state?.gameTime
        rig.controls.fixture.clock.time = 1.5
        rig.session.advanceLive()
        #expect(rig.session.state?.gameTime == time)
        await rig.session.stop()
    }

    @Test func acceptedCalibrationChangeEndsExactlyOnceAndCannotResumeOldRound() async throws {
        let rig = try LiveGameRig()
        try await rig.run()
        try await rig.send(0.75)
        let original = try #require(rig.controls.input.currentContext)
        rig.controls.input.replaceContext(BodyInputContext(sessionGeneration: original.sessionGeneration,
            cameraGeometryRevision: original.cameraGeometryRevision, calibrationRevisions: [.player1: 1],
            cutovers: [:], isActive: true))
        #expect(rig.session.phase == .restartRequired)
        let summary = try #require(rig.session.summary)
        #expect(summary.outcome == .technicalInterruption && summary.teamScore == 0)
        await rig.session.stop()
        rig.session.continueLiveRound()
        rig.controls.fixture.clock.time = 10
        rig.session.advanceLive()
        #expect(rig.session.summary == summary)
        #expect(rig.session.events.filter { if case .roundEnded = $0.kind { true } else { false } }.count == 1)
    }

    @Test func healthFailureUsesLiveDomainAndJoinsInputCleanup() async throws {
        let rig = try LiveGameRig(encounterCount: 3)
        try await rig.run()
        for index in 6...28 {
            if rig.session.summary != nil { break }
            try await rig.send(Double(index) * 0.125, crown: 2)
        }
        #expect(rig.session.summary?.outcome == .healthDepleted)
        #expect(rig.session.summary?.remainingTeamHealth == 0)
        await rig.session.stop()
        #expect(rig.controls.input.stopCount == 1 && rig.controls.input.releaseCount == 1)
        #expect(rig.session.events.last?.kind == .roundEnded(.healthDepleted))
    }

    @Test func planAndPolicyDoNotBypassUnacceptedCalibration() async throws {
        let rig = try LiveGameRig()
        try await rig.session.start()
        #expect(throws: LaserDataError.self) { try rig.session.beginLiveCountdown() }
        #expect(rig.session.state == nil && rig.session.summary == nil)
        await rig.session.stop()
    }

    @Test func recoveryCannotBorrowTheAttemptOfAnAlreadyCommittedEncounter() async throws {
        let committedAttempt = UUID(uuidString: "34000000-0000-4000-8000-000000000001")!
        let rig = try LiveGameRig(encounterCount: 2, planner: { request in
            try request.withdrawn.map { old in
                try LaserEncounter(id: old.id, attemptID: committedAttempt, targets: old.targets.map {
                    let warning = request.gameTime + 0.125
                    return try LaserTarget(playerID: $0.playerID, calibrationRevision: $0.calibrationRevision,
                        requiredMove: $0.requiredMove, beam: $0.beam, warningTime: warning,
                        crossingTime: warning + $0.crossingTime - $0.warningTime)
                })
            }
        })
        try await rig.run()
        for index in 6...11 { try await rig.send(Double(index) * 0.125) }
        #expect(rig.session.state?.teamScore == 200)
        let oldPendingAttempt = rig.session.encounters[1].attemptID
        rig.session.pauseLiveRound()
        rig.session.continueLiveRound()
        try await rig.send(1.5); try await rig.send(1.625)
        #expect(rig.session.phase == .paused && rig.session.recoveryNeedsPlan)
        #expect(rig.session.encounters[1].attemptID == oldPendingAttempt)
        #expect(rig.session.state?.teamScore == 200 && rig.session.summary == nil)
        await rig.session.stop()
    }

    @Test func liveVaultTimeoutUsesGameClockAndPreservesLaserTotals() async throws {
        let rig = try LiveGameRig()
        try await rig.run()
        #expect(throws: LaserDataError.self) { try rig.session.beginLiveVault(id: UUID()) }
        for index in 6...11 { try await rig.send(Double(index) * 0.125) }
        let activity = rig.session.state?.activityProgress
        let vaultID = UUID()
        try rig.session.beginLiveVault(id: vaultID)
        #expect(rig.session.state?.phase == .vault && rig.session.state?.vault?.id == vaultID)
        for index in 12...51 {
            if rig.session.summary != nil { break }
            try await rig.send(Double(index) * 0.125)
        }
        let summary = try #require(rig.session.summary)
        #expect(summary.outcome == .vaultFailed && summary.remainingTeamHealth == 5 && summary.teamScore == 200)
        #expect(summary.activityDuration == activity && summary.vaultsOpened == 0)
        #expect(summary.coopResults.first?.gateID == vaultID && summary.coopResults.first?.outcome == .timedOut)
        #expect(rig.session.events.last?.kind == .roundEnded(.vaultFailed))
        await rig.session.stop()
        #expect(rig.controls.input.stopCount == 1)
    }

    @Test func liveVaultPauseContinuesSameDeadlineWithoutARecoveryLaserPlan() async throws {
        let rig = try LiveGameRig()
        try await rig.run()
        for index in 6...11 { try await rig.send(Double(index) * 0.125) }
        let id = UUID()
        try rig.session.beginLiveVault(id: id)
        try await rig.send(1.5)
        rig.session.pauseLiveRound()
        let paused = try #require(rig.session.state)
        let deadline = try #require(paused.vault?.deadline)
        for time in [1.625, 1.75, 1.875, 2.0] { try await rig.send(time) }
        #expect(rig.session.state?.gameTime == paused.gameTime)
        #expect(rig.session.state?.vault == paused.vault)
        rig.session.continueLiveRound()
        for time in [2.125, 2.25, 2.375, 2.5] { try await rig.send(time) }
        #expect(rig.session.phase == .running && !rig.session.recoveryNeedsPlan)
        #expect(rig.session.state?.vault?.id == id && rig.session.state?.vault?.deadline == deadline)
        #expect(rig.session.state?.gameTime == paused.gameTime && rig.session.state?.activityProgress == paused.activityProgress)
        for index in 21...59 {
            if rig.session.summary != nil { break }
            try await rig.send(Double(index) * 0.125)
        }
        #expect(rig.session.summary?.outcome == .vaultFailed)
        #expect(rig.session.summary?.gameDuration == deadline)
        #expect(rig.session.events.filter { $0.kind == .phaseChanged(.vault) }.count == 1)
        await rig.session.stop()
    }

    @Test func abortWhilePausedFreezesSummaryAndLateTicksCannotResumeIt() async throws {
        let rig = try LiveGameRig()
        try await rig.run()
        try await rig.send(0.75)
        rig.session.pauseLiveRound()
        let time = rig.session.state?.gameTime
        await rig.session.stop()
        let summary = try #require(rig.session.summary)
        let events = rig.session.events
        #expect(summary.outcome == .aborted && summary.gameDuration == time)
        #expect(summary.teamScore == 0 && summary.remainingTeamHealth == 5)
        rig.controls.fixture.clock.time = 100
        rig.session.advanceLive()
        rig.session.continueLiveRound()
        await rig.session.stop(reason: .technicalInterruption)
        #expect(rig.session.summary == summary && rig.session.events == events)
        #expect(rig.controls.input.stopCount == 1 && rig.controls.input.releaseCount == 1)
        #expect(events.last?.kind == .roundEnded(.aborted))
    }

    @Test func sourceLossDuringCountdownCannotCreateARoundOrResults() async throws {
        let rig = try LiveGameRig()
        try await rig.prepare()
        try rig.session.beginLiveCountdown()
        let context = try #require(rig.controls.input.currentContext)
        rig.controls.fixture.clock.time = 0.5
        rig.controls.input.replaceContext(BodyInputContext(sessionGeneration: context.sessionGeneration,
            cameraGeometryRevision: context.cameraGeometryRevision, calibrationRevisions: [:],
            cutovers: [:], isActive: false))
        #expect(rig.session.phase == .restartRequired && rig.session.state == nil)
        #expect(rig.session.summary == nil && rig.session.results.isEmpty && rig.session.events.isEmpty)
        await rig.session.stop()
        rig.controls.fixture.clock.time = 10
        rig.session.advanceLive()
        #expect(rig.session.state == nil && rig.session.summary == nil)
        #expect(rig.controls.input.stopCount == 1 && rig.controls.input.releaseCount == 1)
    }

    @Test func delayedUnavailableEvidenceDoesNotCancelANewerReliableAttempt() async throws {
        let rig = try LiveGameRig()
        try await rig.run()
        // Each source frame is delivered at most once; completion order differs from capture order.
        let delayed = try await rig.send(0.75, crown: nil, deliver: false)
        try await rig.send(0.875)
        let newest = rig.session.latestSnapshot
        rig.controls.fixture.clock.time = 1
        await rig.controls.input.sendAndWaitForContextRead(delayed)
        #expect(rig.session.phase == .running && rig.session.latestSnapshot == newest)
        for time in [1.125, 1.25, 1.375] { try await rig.send(time) }
        #expect(rig.session.state?.teamScore == 200 && rig.session.state?.teamHealth == 5)
        #expect(!rig.session.events.contains { if case .attemptWithdrawn = $0.kind { true } else { false } })
        await rig.session.stop()
    }

    private static func recovery(_ request: LaserLiveRecoveryRequest) throws -> [LaserEncounter]? {
        try request.withdrawn.map { old in
            try LaserEncounter(id: old.id, attemptID: UUID(), targets: old.targets.map {
                let warning = request.gameTime + 0.125
                return try LaserTarget(playerID: $0.playerID, calibrationRevision: $0.calibrationRevision,
                    requiredMove: $0.requiredMove, beam: $0.beam, warningTime: warning,
                    crossingTime: warning + ($0.crossingTime - $0.warningTime))
            })
        }
    }
}

/// Real B2 gate and explicit accepted/valid body fixtures. No camera/anatomy acceptance claim.
@MainActor private final class LiveGameRig {
    let controls: GateSetupControls
    let session: GameSessionCoordinator
    private var frame: UInt64 = 3
    init(encounterCount: Int = 1,
         planner: (@MainActor (LaserLiveRecoveryRequest) throws -> [LaserEncounter]?)? = nil) throws {
        let controls = try GateSetupControls()
        self.controls = controls
        let configuration = try LaserRoundConfiguration(
            evidenceTiming: LaserEvidenceTiming(windowBefore: 0.125, windowAfter: 0.125, deliveryAllowance: 0.125),
            clearanceMargin: 0.005, diamondPoints: nil, actionCueLead: 0.125)
        let encounters = try (0..<encounterCount).map { index in
            let id = UUID(uuidString: String(format: "34000000-0000-4000-8000-%012d", index + 1))!
            return try LaserEncounter(id: id, attemptID: id, targets: PlayerID.allCases.map {
                try LaserTarget(playerID: $0, calibrationRevision: 1, requiredMove: .duck,
                    beam: LaserBeamBand(lowerY: 1, upperY: 1.125), warningTime: Double(index) + 0.125,
                    crossingTime: Double(index) + 0.5)
            })
        }
        session = try GameSessionCoordinator(provider: controls.input,
            inputConfiguration: LiveVisionFixtures.configuration(controls.fixture.context.generation),
            configuration: configuration, encounters: encounters, setupControls: controls,
            liveTimingPolicy: LaserLiveTimingPolicy(settlingDuration: 0.125, maximumEvidenceAge: 0.5, countdownDuration: 0.25),
            hostNow: { controls.fixture.clock.time }, recoveryPlanner: planner)
    }
    func run() async throws {
        try await prepare()
        try session.beginLiveCountdown()
        #expect(session.phase == .countdown && session.state == nil)
        try await send(0.5); try await send(0.625)
    }
    func prepare() async throws {
        try await session.start()
        let setup = try #require(session.setup)
        try setup.beginBinding()
        try controls.bindPair()
        try setup.confirmPlayers()
        try setup.requestCalibration(id: UUID())
        controls.showCandidate(validated: true)
        try setup.confirmCandidate(id: try #require(controls.calibration.candidate?.id))
        try await send(0.25); try await send(0.375)
        #expect(session.canStartLiveRound)
    }
    @discardableResult
    func send(_ capture: Double, arrivedAt: Double? = nil, crown: Double? = 0.5,
              notifyBeforeDelivery: Bool = false, deliver: Bool = true) async throws -> BodySnapshot {
        let id = frame; frame += 1
        try #require(try controls.fixture.finish(controls.fixture.result(id, capture, LiveVisionFixtures.standingPair),
                                               age: (arrivedAt ?? capture) - capture))
        let tracking = controls.tracking
        if notifyBeforeDelivery {
            controls.input.replaceContext(try #require(controls.input.currentContext))
            #expect(session.state?.teamScore == 0 && session.state?.teamHealth == 5)
        }
        let players = try Dictionary(uniqueKeysWithValues: PlayerID.allCases.map { player in
            let reliable = tracking.latest?[player].state == .tracking
            let missing = try EstimatedScalar(value: nil, validity: .identityUncertain)
            let head = reliable ? try EstimatedScalar(value: crown, validity: crown == nil ? .notCalibrated : .valid) : missing
            let scalar = try EstimatedScalar(value: 0.5, validity: .valid)
            let feet = try EstimatedScalar(value: 0, validity: .valid)
            let center = try EstimatedScalar(value: player == .player1 ? -1 : 1, validity: .valid)
            return (player, PlayerBodySample(playerID: player, calibrationRevision: 1,
                trackingStatus: reliable ? .reliable : .uncertain,
                geometry: BodyGeometry(crownY: head, leftWristY: reliable ? scalar : missing,
                    rightWristY: reliable ? scalar : missing, leftSoleY: reliable ? feet : missing,
                    rightSoleY: reliable ? feet : missing, centerX: reliable ? center : missing),
                jumpState: JumpState(phase: reliable ? .grounded : .unknown, validity: reliable ? .valid : .identityUncertain)))
        })
        let packet = BodySnapshot(
            sessionGeneration: controls.fixture.context.generation, frameID: id, capturedAt: capture,
            cameraGeometryRevision: 1, players: players)
        if deliver { await controls.input.sendAndWaitForContextRead(packet) }
        return packet
    }
}
