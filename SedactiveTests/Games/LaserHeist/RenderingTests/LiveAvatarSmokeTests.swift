#if DEBUG
import Foundation
import Testing
@testable import Sedactive

@MainActor struct LiveAvatarSmokeTests {
  private func fixture() -> (LiveAvatarSmokeModel, ControlledCameraDriver) {
    let driver = ControlledCameraDriver()
    let camera = CameraPipeline(permission:ControlledCameraPermission(.authorized),driver:driver)
    let provider = BodyInputService(camera:camera)
    let flow = LaserInputFlow(makeLiveSession: {
      GameSessionCoordinator(liveProvider:provider,inputConfiguration:LiveVisionFixtures.configuration(UUID()))
    })
    return (LiveAvatarSmokeModel(flow:flow,service:provider,bridge:VisionNumericPoseBridge(gate:camera.frames.tracking)),driver)
  }
  @Test func explicitModeCannotEnableAlongsideSyntheticOrDiagnostics() {
    #expect(LiveAvatarSmokeModel.requested(["app","--live-avatar-smoke"]))
    #expect(!LiveAvatarSmokeModel.requested(["app"]))
    for arg in ["--synthetic-gameplay-preview","--camera-diagnostics","--camera-diagnostics-run","-robotDemo"] {
      #expect(!LiveAvatarSmokeModel.requested(["app","--live-avatar-smoke",arg]))
    }
  }
  @Test func setupOnlyStartsDisarmedAndSequentialRetryRetiresAttachment() async throws {
    let (m,driver) = fixture()
    #expect(m.service.status == .stopped && m.sourceGeneration == nil)
    await m.start()
    let first = try #require(m.sourceGeneration), old = try #require(m.session)
    #expect(!old.isReplay && !old.hasLiveRoundPlan && old.phase == .awaitingSetup)
    #expect(old.state == nil && old.events.isEmpty && old.summary == nil && !old.canStartLiveRound)
    #expect(m.service.camera.frames.tracking.snapshot.requestID == nil)
    #expect(throws:BodyInputOperationError.consumerAlreadyClaimed) {
      try m.service.snapshotStream(generation:first)
    }
    let box = AvatarPoseMailbox(maxAge:LiveAvatarPresenter.maximumPoseAge)
    let pump = try m.attach(mailbox:box,generation:first)
    #expect(try pump.tick())
    #expect(!box.drain(now:CameraHostClock.now()).hasCurrent)
    await m.start() // repeated Start cannot start a second source
    #expect(await driver.starts == 1)
    await m.stop()
    #expect(m.service.status == .stopped && m.sourceGeneration == nil)
    #expect(m.service.camera.frames.usage.frames == 0)
    #expect(try pump.tick() == false)
    #expect(box.isRevoked)
    await m.start()
    let second = try #require(m.sourceGeneration)
    #expect(first != second && m.service.currentContext?.calibrationRevisions.isEmpty == true)
    #expect(m.service.camera.frames.tracking.snapshot.requestID == nil)
    #expect(throws:LiveVisionError.self) {
      try m.attach(mailbox:AvatarPoseMailbox(maxAge:0.25),generation:first)
    } // late asset completion for the retired generation cannot attach
    let fresh = try m.attach(mailbox:AvatarPoseMailbox(maxAge:0.25),generation:second)
    pump.stop() // old view teardown cannot retire the new lease
    #expect(try fresh.tick())
    await m.stop();fresh.stop()
    #expect(await driver.starts == 2)
    #expect(await driver.stops == 2)
  }
  @Test func genuineGateAssociationDrivesOnlyDirectionPoseAndRevokesWithoutGameplay() async throws {
    let (m,_) = fixture();await m.start()
    let generation = try #require(m.sourceGeneration), session = try #require(m.session)
    let source = try #require(m.service.camera.state.context)
    let gate = m.service.camera.frames.tracking
    let box = AvatarPoseMailbox(maxAge:LiveAvatarPresenter.maximumPoseAge)
    let pump = try m.attach(mailbox:box,generation:generation)
    m.arm()
    #expect(gate.snapshot.requestID != nil)
    let f = try TrackingIntegrationFixture();var engine = try MotionEngine(policy:B2bExperimentalPolicyV1.value)
    let base = CameraHostClock.now()-0.20
    for i in 1...2 {
      let p = try f.result(UInt64(i),base+Double(i-1)*0.125,LiveVisionFixtures.standingPair,context:source)
      let a = try #require(gate.admit(p.source)), staged = try engine.staged(p,admission:a)
      try #require(gate.finish(staged,admission:a,source:p.source,mutualCoreCount:4) { engine = staged })
      let receipt = try #require(gate.snapshot.latest)
      gate.publishBody(p,admission:a,receipt:receipt)
      gate.publishPresentation(p,admission:a,receipt:receipt)
    }
    #expect(gate.snapshot.acknowledgment != nil)
    #expect(try pump.tick())
    let frame = try #require(box.drain(now:CameraHostClock.now()).frame)
    #expect(frame.source.context.generation == generation && frame.source.context.epoch == source.epoch)
    #expect(frame.source.frameID == 2 && frame.source.capturedAt == base+0.125)
    for id in PlayerID.allCases {
      guard case .available(let pose) = frame.slot(id) else { Issue.record("bound slot missing");continue }
      #expect(pose.capability == .directionOnly)
      #expect(pose.joints[.leftWrist]?.confidence == 0.9)
    }
    #expect(session.state == nil && session.events.isEmpty && session.summary == nil)
    #expect(m.service.currentContext?.calibrationRevisions.isEmpty == true)
    m.cancelBinding()
    #expect(try pump.tick())
    #expect(!box.drain(now:CameraHostClock.now()).hasCurrent)
    #expect(gate.snapshot.acknowledgment == nil)
    gate.sourceLost(source)
    #expect(m.sourceGeneration == nil)
    #expect(throws:LiveVisionError.self) { try m.attach(mailbox:AvatarPoseMailbox(maxAge:0.25),generation:generation) }
    await m.stop();pump.stop()
    #expect(m.service.status == .stopped && m.service.camera.frames.usage.frames == 0)
  }
  @Test func singleCandidateCannotProduceSuccessfulPairOrAvailableAvatar() async throws {
    let (m,_) = fixture();await m.start()
    let generation = try #require(m.sourceGeneration), source = try #require(m.service.camera.state.context)
    let gate = m.service.camera.frames.tracking
    let box = AvatarPoseMailbox(maxAge:LiveAvatarPresenter.maximumPoseAge)
    let pump = try m.attach(mailbox:box,generation:generation)
    m.arm()
    let f = try TrackingIntegrationFixture();var engine = try MotionEngine(policy:B2bExperimentalPolicyV1.value)
    let base = CameraHostClock.now()-0.3
    for i in 1...3 {
      let p = try f.result(UInt64(i),base+Double(i-1)*0.125,[LiveVisionFixtures.standingPair[0]],context:source)
      let a = try #require(gate.admit(p.source)), staged = try engine.staged(p,admission:a)
      try #require(gate.finish(staged,admission:a,source:p.source,mutualCoreCount:4) { engine = staged })
      let receipt = try #require(gate.snapshot.latest)
      gate.publishPresentation(p,admission:a,receipt:receipt)
      #expect(try pump.tick())
      if let frame = box.drain(now:CameraHostClock.now()).frame {
        for id in PlayerID.allCases {
          guard case .unavailable = frame.slot(id) else { Issue.record("single candidate was presented as bound");continue }
        }
      }
      #expect(gate.snapshot.acknowledgment == nil)
    }
    #expect(m.session?.state == nil && m.session?.events.isEmpty == true)
    await m.stop();pump.stop()
  }

}
#endif
