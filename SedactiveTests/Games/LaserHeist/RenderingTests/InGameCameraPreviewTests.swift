#if DEBUG
import Foundation
import RealityKit
import Testing
@testable import Sedactive

@MainActor struct InGameCameraPreviewTests {
  private func fixture() -> (LiveAvatarSmokeModel, ControlledCameraDriver) {
    let driver = ControlledCameraDriver()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized), driver: driver)
    let provider = BodyInputService(camera: camera)
    let flow = LaserInputFlow(makeLiveSession: {
      GameSessionCoordinator(liveProvider: provider,
        inputConfiguration: LiveVisionFixtures.configuration(UUID()))
    })
    return (LiveAvatarSmokeModel(flow: flow, service: provider,
      bridge: VisionNumericPoseBridge(gate: camera.frames.tracking)), driver)
  }
  @Test func explicitDebugRouteRejectsMixedModes() {
    #expect(InGameCameraPreviewView.requested(["app", "--ingame-camera-preview"]))
    #expect(!InGameCameraPreviewView.requested(["app"]))
    for flag in ["--live-avatar-smoke", "--synthetic-gameplay-preview", "--camera-diagnostics",
      "--camera-diagnostics-run", "-robotDemo", "-replay"] {
      #expect(!InGameCameraPreviewView.requested(["--ingame-camera-preview", flag]))
    }
  }
  @Test(arguments: [0.249999, 0.25, 0.5, -0.001])
  func b1FreshnessNeverRestampsHistoricalFrame(_ age: Double) throws {
    let f = try TrackingIntegrationFixture()
    let pose = try f.result(7, 10, [LiveVisionFixtures.standingPair[0]])
    let mailbox = CameraPoseResults(); mailbox.begin(f.context)
    let ticket = try #require(mailbox.start(pose.source))
    try #require(mailbox.finish(pose, ticket: ticket, startedAt: 10.001, completedAt: 10.01))
    let read = InGameCameraPoseReadout(mailbox.snapshot, source: f.context, sourceActive: true, now: 10+age)
    #expect(read.current == (age >= 0 && age < 0.25))
    #expect(read.lastSource == pose.source && read.completed == 1)
    #expect(read.rawObservations == (read.current ? 1 : nil))
    #expect(read.current || read.jointCounts.isEmpty)
  }
  @Test func sourceLossAndEpochMismatchCannotAppearCurrent() throws {
    let f = try TrackingIntegrationFixture(), other = CameraTestFrames.context()
    let pose = try f.result(1, 10)
    let snap = CameraPoseSnapshot(latest: pose, statistics: CameraPoseStatistics())
    #expect(!InGameCameraPoseReadout(snap, source: other, sourceActive: true, now: 10.01).current)
    #expect(!InGameCameraPoseReadout(snap, source: f.context, sourceActive: false, now: 10.01).current)
    #expect(!InGameCameraPoseReadout(snap, source: nil, sourceActive: true, now: 10.01).current)
    #expect(!InGameCameraPoseReadout(snap, source: f.context, sourceActive: true, now: .nan).current)
  }
  @Test func b1ProgressDoesNotGrantPairCalibrationOrGameAuthority() async throws {
    let (m, driver) = fixture()
    await m.start()
    let source = try #require(m.service.camera.state.context)
    let f = try TrackingIntegrationFixture()
    let pose = try f.result(1, CameraHostClock.now()-0.02, [LiveVisionFixtures.standingPair[0]], context: source)
    let poses = m.service.camera.frames.poses
    let ticket = try #require(poses.start(pose.source))
    try #require(poses.finish(pose, ticket: ticket, startedAt: pose.source.capturedAt+0.001,
      completedAt: pose.source.capturedAt+0.005))
    let read = InGameCameraPoseReadout(poses.snapshot, source: source, sourceActive: true,
      now: pose.source.capturedAt+0.01)
    #expect(read.current && read.rawObservations == 1 && read.jointCounts == [pose.frame.candidates[0].joints.count])
    #expect(m.service.camera.frames.tracking.snapshot.requestID == nil)
    #expect(m.service.camera.frames.tracking.snapshot.acknowledgment == nil)
    #expect(m.service.camera.frames.tracking.snapshot.latest == nil)
    #expect(m.service.currentContext?.calibrationRevisions.isEmpty == true)
    #expect(m.session?.state == nil && m.session?.events.isEmpty == true && m.session?.summary == nil)
    #expect(throws: BodyInputOperationError.consumerAlreadyClaimed) {
      try m.service.snapshotStream(generation: source.generation)
    }
    await m.stop()
    #expect(poses.snapshot.latest == nil && m.service.status == .stopped)
    #expect(m.service.camera.frames.usage.frames == 0)
    let starts = await driver.starts, stops = await driver.stops
    #expect(starts == 1 && stops == 1)
  }
  @Test func realStageIsNeutralUntilGenuinePairAndStopsItsExactAttachment() async throws {
    let (m, driver) = fixture()
    let stage = InGameCameraStage()
    stage.install(environment: nil, templates: try await RobotAvatarLayer.sharedTemplates())
    stage.tick(model: m, now: CameraHostClock.now())
    #expect(stage.ready && stage.attachedGeneration == nil)
    #expect(stage.scene.robotAvatars?.robots.count == 2)
    #expect(stage.scene.robotAvatars?.robots.values.allSatisfy { !$0.retargeter.isAvailable } == true)
    #expect(await driver.starts == 0)
    await m.start()
    stage.tick(model: m, now: CameraHostClock.now())
    let first = try #require(stage.attachedGeneration), box = try #require(stage.mailbox)
    #expect(box.diagnostics.accepted == 0 && !box.isRevoked)
    #expect(m.service.camera.frames.tracking.snapshot.acknowledgment == nil)
    #expect(m.session?.hasLiveRoundPlan == false && m.session?.state == nil)
    stage.endCamera()
    #expect(box.isRevoked && stage.attachedGeneration == nil)
    stage.tick(model: m, now: CameraHostClock.now()) // cannot reattach old setup while Stop awaits
    #expect(stage.attachedGeneration == nil)
    await m.stop()
    await m.start()
    stage.tick(model: m, now: CameraHostClock.now())
    #expect(stage.attachedGeneration != nil && stage.attachedGeneration != first)
    #expect(m.service.camera.frames.tracking.snapshot.requestID == nil)
    stage.endCamera(); await m.stop(); stage.dispose()
    #expect(stage.scene.liveAvatars == nil && stage.scene.robotAvatars == nil)
    let starts = await driver.starts, stops = await driver.stops
    #expect(starts == 2 && stops == 2)
  }
  @Test func sourceLossAndBackgroundRetireLeaseWithoutNativeAutoAttachment() async throws {
    let (m, _) = fixture(); let stage = InGameCameraStage()
    stage.install(environment: nil, templates: try await RobotAvatarLayer.sharedTemplates())
    await m.start(); stage.tick(model: m, now: CameraHostClock.now())
    let source = try #require(m.service.camera.state.context), box = try #require(stage.mailbox)
    m.service.camera.frames.tracking.sourceLost(source)
    stage.tick(model: m, now: CameraHostClock.now())
    #expect(box.isRevoked && stage.attachedGeneration == nil)
    m.service.camera.frames.tracking.resume(source)
    stage.tick(model: m, now: CameraHostClock.now())
    #expect(stage.attachedGeneration == nil)
    #expect(m.service.camera.frames.tracking.snapshot.acknowledgment == nil)
    await m.flow.handleBackground(); stage.tick(model: m, now: CameraHostClock.now())
    #expect(m.service.status == .stopped && m.service.camera.frames.usage.frames == 0)
    stage.dispose()
  }
  @Test func disposedStageRejectsLateAssets() {
    let stage = InGameCameraStage(); stage.dispose()
    stage.install(environment: nil, templates: [:])
    #expect(!stage.ready && stage.scene.robotAvatars == nil)
  }
}
#endif
