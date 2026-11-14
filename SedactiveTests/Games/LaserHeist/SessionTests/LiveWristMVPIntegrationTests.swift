import Foundation
import RealityKit
import Testing
@testable import Sedactive

@MainActor struct LiveWristMVPIntegrationTests {
    @Test func deferredAcceptedPlanUsesSameLivePathStreamDomainAndHud() async throws {
        let rig = try J07SessionRig(deferredPlan:true)
        try await rig.start(installDeferredPlan:false)
        #expect(!rig.session.hasLiveRoundPlan && !rig.session.hasWristDiamondPlan)
        let startCount = rig.controls.input.startCount, claims = rig.controls.input.claimCount
        try rig.session.installLiveWristRound(rig.makePlan())
        #expect(rig.session.hasLiveRoundPlan && rig.session.hasWristDiamondPlan)
        #expect(!rig.session.canStartLiveRound && rig.session.state == nil) // no inherited settling/frame-host permission
        try await rig.finishStart();try await rig.spawn()
        try await rig.send(0.8125,points:[WristGameplayFixture.left:WristGameplayFixture.outside])
        #expect(rig.session.state?.teamScore == 0)
        let inside = try await rig.send(0.875,points:[WristGameplayFixture.left:WristGameplayFixture.inside])
        #expect(rig.session.diamondsCollected == 1 && rig.session.state?.teamScore == 25)
        await rig.controls.input.sendAndWaitForContextRead(inside)
        #expect(rig.session.state?.teamScore == 25)
        #expect(rig.controls.input.startCount == startCount && rig.controls.input.claimCount == claims && claims == 1)
        let hud = GameplayHUDModel(state:rig.session.state,events:rig.session.events,
            configuration:try #require(rig.session.configuration),activityDuration:rig.session.activityDuration,
            diamondsCollected:rig.session.diamondsCollected,diamondsAreFixture:false)
        #expect(hud.score == 25)
        let mapped = LaserReplayPresentation.normalDiamonds(rig.session.diamondStates,layout:rig.fixture.input.playerPlaneLayout)
        #expect(mapped.count == 1 && mapped[0].outcome == .collected)
        await rig.session.stop()
        #expect(rig.controls.input.releaseCount == 1 && rig.controls.input.stopCount == 1)
        #expect(throws:LaserDataError.self) { try rig.session.installLiveWristRound(rig.makePlan()) }
    }
    @Test func setupWithoutAcceptanceRemainsNonScoring() async throws {
        let controls = try GateSetupControls()
        let session = GameSessionCoordinator(liveProvider:BodyInputService(camera:CameraPipeline(
            permission:ControlledCameraPermission(.authorized),driver:ControlledCameraDriver())),
            inputConfiguration:LiveVisionFixtures.configuration(UUID()))
        // Live provider never receives a synthetic dictionary or accepted context from this route.
        try await session.start()
        #expect(session.liveWristBlockers.contains(.calibration) && session.liveWristBlockers.contains(.geometry))
        #expect(!session.canStartLiveRound && session.state == nil && !session.hasWristDiamondPlan)
        #expect(throws:LaserDataError.self) { try session.installLiveWristRound(J07SessionRig(controls:controls).makePlan()) }
        await session.stop()
    }
    @Test(arguments:["epoch","control","calibration","inactive"])
    func staleOrUnacceptedPlanCannotAttach(_ change:String) async throws {
        let rig = try J07SessionRig(deferredPlan:true);try await rig.start(installDeferredPlan:false)
        let old = rig.fixture.context, a = try #require(old.wristContact)
        let wrist = WristContactContextV1(sourceEpoch:change == "epoch" ? UUID() : a.sourceEpoch,
            controlRevision:a.controlRevision+(change == "control" ? 1 : 0),bindingRequestID:a.bindingRequestID,
            bindingFrameID:a.bindingFrameID,bindingCapturedAt:a.bindingCapturedAt,acceptedContextRevision:a.acceptedContextRevision,freshness:a.freshness)
        let changed = BodyInputContext(sessionGeneration:old.sessionGeneration,cameraGeometryRevision:old.cameraGeometryRevision,
            calibrationRevisions:change == "calibration" ? [:] : old.calibrationRevisions,cutovers:old.cutovers,
            isActive:change != "inactive",wristContact:wrist)
        rig.controls.input.replaceContext(changed)
        #expect(throws:LaserDataError.self) { try rig.session.installLiveWristRound(rig.makePlan()) }
        #expect(!rig.session.hasLiveRoundPlan && !rig.session.hasWristDiamondPlan && rig.session.state == nil)
        await rig.session.stop()
    }
    @Test func planCannotBeReplacedOrSurviveAPreCountdownCutover() async throws {
        let rig = try J07SessionRig(deferredPlan:true);try await rig.start(installDeferredPlan:false)
        let plan = try rig.makePlan();try rig.session.installLiveWristRound(plan)
        #expect(throws:LaserDataError.self) { try rig.session.installLiveWristRound(plan) }
        let old = rig.fixture.context
        rig.controls.input.replaceContext(.init(sessionGeneration:old.sessionGeneration,cameraGeometryRevision:old.cameraGeometryRevision,
            calibrationRevisions:[:],cutovers:old.cutovers,isActive:true,wristContact:old.wristContact))
        #expect(rig.session.phase == .restartRequired && !rig.session.canStartLiveRound && rig.session.state == nil)
        await rig.session.stop()
    }
    @Test func oldConfirmedPairCannotGrantANewUnboundPlan() async throws {
        let rig = try J07SessionRig(deferredPlan:true);try await rig.start(installDeferredPlan:false)
        rig.controls.cancelBinding();rig.session.refreshLiveReadiness()
        #expect(throws:LaserDataError.self) { try rig.session.installLiveWristRound(rig.makePlan()) }
        #expect(rig.session.state == nil && !rig.session.hasWristDiamondPlan)
        await rig.session.stop()
    }
    @Test func currentLiveExtractorDoesNotPromoteStandingOffsetsToCollisionAnatomy() throws {
        let (_,body,_) = try WristEvidenceTests().fixture()
        let candidate = try #require(LiveVisionFixtures.standingPair.first), calibration = try #require(body.configuration?.calibrations[.player1])
        let slot = PlayerTrackingSlotResult(state:.tracking,reason:.matched,candidateID:candidate.candidateID,cost:0,
            requiresRebind:false,lastConfirmedAt:0.25)
        let sample = BodyMeasurementExtractor.sample(id:.player1,candidate:candidate,slot:slot,calibration:calibration,
            layout:try #require(body.configuration?.playerPlaneLayout))
        #expect(sample.geometry.leftWristY.validity == .valid && sample.geometry.rightWristY.validity == .valid)
        #expect(sample.geometry.crownY.value == nil && sample.geometry.leftSoleY.value == nil && sample.geometry.rightSoleY.value == nil)
        #expect(sample.jumpState.phase == .unknown && sample.jumpState.validity != .valid)
    }
}
