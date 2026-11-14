import Foundation
import Testing
@testable import Sedactive

@MainActor struct J07WristGameplayIntegrationTests {
    @Test func actualSingleStreamSessionCollectsOnceThenRetryRejectsOldEvidence() async throws {
        let rig = try J07SessionRig(); try await rig.start()
        try await rig.spawn()
        #expect(rig.session.state?.teamScore == 0)
        try await rig.send(0.8125,points:[WristGameplayFixture.left:WristGameplayFixture.outside])
        let inside = try await rig.send(0.875,points:[WristGameplayFixture.left:WristGameplayFixture.inside])
        #expect(rig.session.diamondsCollected == 1 && rig.session.state?.teamScore == 25)
        #expect(rig.session.diamondStates[LaserDiamondTests.id(1)]?.outcome != nil)
        await rig.controls.input.sendAndWaitForContextRead(inside)
        #expect(rig.session.state?.teamScore == 25 && rig.controls.input.claimCount == 1)
        await rig.session.stop()
        #expect(rig.controls.input.stopCount == 1 && rig.controls.input.releaseCount == 1)
        rig.session.advanceLive()
        #expect(rig.session.summary?.teamScore == 25)

        // Same retained provider, fresh actual gate/source generation and a new coordinator.
        // Clear the test control's previous accepted-progress override before its new source.
        if let oldRequest = rig.controls.lastCalibration { rig.controls.cancelCalibration(oldRequest) }
        rig.controls.fixture = try TrackingIntegrationFixture()
        try rig.controls.fixture.gate.configureBody(LiveVisionFixtures.configuration(rig.controls.fixture.context.generation))
        rig.controls.acceptedRevision = 0
        let retry = try J07SessionRig(controls:rig.controls); try await retry.start()
        #expect(retry.fixture.context.sessionGeneration != inside.sessionGeneration)
        try await retry.spawn()
        await retry.controls.input.sendAndWaitForContextRead(inside)
        #expect(retry.session.diamondsCollected == 0 && retry.session.state?.teamScore == 0)
        try await retry.send(0.8125,points:[WristGameplayFixture.left:WristGameplayFixture.inside])
        #expect(retry.session.diamondsCollected == 0) // no old outside history survived Stop/Retry
        try await retry.send(0.875,points:[WristGameplayFixture.left:WristGameplayFixture.outside])
        try await retry.send(0.9375,points:[WristGameplayFixture.left:WristGameplayFixture.inside])
        #expect(retry.session.diamondsCollected == 1 && retry.session.state?.teamScore == 25)
        #expect(retry.controls.input.claimCount == 2)
        await retry.session.stop()
        #expect(retry.controls.input.releaseCount == 2 && retry.controls.input.stopCount == 2)
    }
    @Test func pausedWristCannotSupplyResumeEntry() async throws {
        let rig = try J07SessionRig(); try await rig.start(); try await rig.spawn()
        try await rig.send(0.8125,points:[WristGameplayFixture.left:WristGameplayFixture.outside])
        rig.session.pauseLiveRound()
        #expect(rig.session.phase == .paused && rig.session.state?.teamScore == 0)
        try await rig.send(0.875,points:[WristGameplayFixture.left:WristGameplayFixture.inside])
        #expect(rig.session.state?.teamScore == 0)
        rig.session.continueLiveRound()
        try await rig.send(1.0);try await rig.send(1.125)
        try await rig.send(1.25);try await rig.send(1.375)
        #expect(rig.session.phase == .running)
        try await rig.send(1.4375,points:[WristGameplayFixture.left:WristGameplayFixture.inside])
        #expect(rig.session.state?.teamScore == 0)
        try await rig.send(1.5,points:[WristGameplayFixture.left:WristGameplayFixture.outside])
        try await rig.send(1.5625,points:[WristGameplayFixture.left:WristGameplayFixture.inside])
        #expect(rig.session.state?.teamScore == 25)
        await rig.session.stop()
    }
    @Test func unconfiguredGeometryNeverEnablesLiveDiamondContact() async throws {
        let rig = try J07SessionRig(configured:false);try await rig.start()
        await #expect(throws:LaserDataError.self) { try await rig.spawn() }
        #expect(rig.session.diamondsCollected == 0 && rig.session.state?.teamScore == 0)
        await rig.session.stop()
    }
}

/// Only synthetic accepted measurements. Setup still exercises the real B2 gate and J03
/// binding/confirmation/countdown/attachment path, with the EXISTING controlled CP1 provider.
@MainActor final class J07SessionRig {
    let controls: GateSetupControls
    let session: GameSessionCoordinator
    var fixture: WristGameplayFixture
    private var frame: UInt64 = 3
    private let deferredPlan: Bool
    private let roundConfiguration: LaserRoundConfiguration
    private let plannedEncounters: [LaserEncounter]
    private var host: LaserLiveFrameAttachment?
    init(controls existing:GateSetupControls? = nil, configured:Bool = true, deferredPlan:Bool = false,
         liveRoundPlanner:(@MainActor (BodyInputContext,[PlayerID:PlayerCalibration]) throws -> LaserLiveWristRoundPlan)? = nil,
         automaticSetup:Bool = false, trackingGrace:Double = 0) throws {
        self.deferredPlan = deferredPlan
        let controls = try existing ?? GateSetupControls();self.controls = controls
        fixture = try WristGameplayFixture(generation:controls.fixture.context.generation)
        let configuration = try LaserRoundConfiguration(evidenceTiming:.init(windowBefore:0.125,
            windowAfter:0.125,deliveryAllowance:0.125),clearanceMargin:0.005,diamondPoints:25)
        let encounter = try LaserEncounter(id:UUID(),attemptID:UUID(),targets:PlayerID.allCases.map {
            try LaserTarget(playerID:$0,calibrationRevision:1,requiredMove:.duck,
                beam:.init(lowerY:1,upperY:1.125),warningTime:0.125,crossingTime:10)
        })
        roundConfiguration = configuration; plannedEncounters = [encounter]
        session = try GameSessionCoordinator(provider:controls.input,inputConfiguration:fixture.input,
            configuration:deferredPlan ? nil : configuration,encounters:deferredPlan ? [] : [encounter],setupControls:controls,
            liveTimingPolicy:deferredPlan ? nil : .init(settlingDuration:0.125,maximumEvidenceAge:0.5,countdownDuration:0.25,
                                                        trackingGrace:trackingGrace),
            wristDiamondConfiguration:configured && !deferredPlan ? fixture.plan() : nil,
            hostNow:{ controls.fixture.clock.time },recoveryPlanner:{ request in
                try request.withdrawn.map { old in
                    try LaserEncounter(id:old.id,attemptID:UUID(),targets:old.targets.map {
                        try LaserTarget(playerID:$0.playerID,calibrationRevision:$0.calibrationRevision,
                            requiredMove:$0.requiredMove,beam:$0.beam,warningTime:request.gameTime+0.125,
                            crossingTime:request.gameTime+10)
                    })
                }
            },liveRoundPlanner:liveRoundPlanner,automaticSetup:automaticSetup,automaticSetupTimer:false)
    }
    func start(installDeferredPlan:Bool = true) async throws {
        try await session.start()
        if session.hasLiveRoundPlan {
            let h = try session.attachLiveFrameHost();host = h;session.advanceLive(frameHost:h)
        }
        let setup = try #require(session.setup)
        try setup.beginBinding();try controls.bindPair();try setup.confirmPlayers()
        try setup.requestCalibration(id:UUID());controls.showCandidate(validated:true)
        try setup.confirmCandidate(id:try #require(controls.calibration.candidate?.id))
        let acknowledgment = try #require(controls.tracking.acknowledgment)
        fixture = try WristGameplayFixture(generation:controls.fixture.context.generation, binding:acknowledgment)
        controls.input.replaceContext(fixture.context)
        if deferredPlan {
            if !installDeferredPlan { return }
            try session.installLiveWristRound(makePlan())
        }
        try await finishStart()
    }
    func makePlan(context:BodyInputContext? = nil) throws -> LaserLiveWristRoundPlan {
        try .init(expectedContext:context ?? fixture.context,configuration:roundConfiguration,
            encounters:plannedEncounters,timing:.init(settlingDuration:0.125,maximumEvidenceAge:0.5,countdownDuration:0.25),
            diamonds:fixture.plan())
    }
    func finishStart() async throws {
        if host == nil {
            let h = try session.attachLiveFrameHost();host = h;session.advanceLive(frameHost:h)
        }
        try await send(0.25);try await send(0.375)
        #expect(session.canStartLiveRound)
        try session.beginLiveCountdown()
        try await send(0.5);try await send(0.625)
        #expect(session.phase == .running && session.state?.gameTime == 0)
    }
    func spawn() async throws {
        try session.spawnLiveDiamonds([LaserDiamondTests.spawn(1,at:0,entry:0.125,exit:2)],beforeVaultAt:3)
        try await send(0.75) // activation tick records the original host watermark
    }
    @discardableResult func send(_ time:Double,points:[LaserContactHand:WristPlanePoint] = [:],
                                 bad:String? = nil, bodySamples: [PlayerID: PlayerBodySample]? = nil,
                                 people: [PoseCandidate] = LiveVisionFixtures.standingPair) async throws -> BodySnapshot {
        let id = frame;frame += 1
        if people == LiveVisionFixtures.standingPair {
            try #require(try controls.fixture.finish(controls.fixture.result(id,time,people)))
        } else { _ = try? controls.fixture.finish(controls.fixture.result(id,time,people)) } // nobody in view
        let s = try fixture.packet(id,time,points:points,bad:bad,bodySamples:bodySamples)
        await controls.input.sendAndWaitForContextRead(s)
        return s
    }
}
