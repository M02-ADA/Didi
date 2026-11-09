import Foundation
import Testing
@testable import Sedactive

@MainActor private final class RetryStopSignal {
  private var observed = false
  private var waiting: CheckedContinuation<Void, Never>?
  func observe(_ state: CameraPipelineState) {
    guard state.status == .stopped else { return }
    observed = true; waiting?.resume(); waiting = nil
  }
  func wait() async {
    if observed { return }
    await withCheckedContinuation { waiting = $0 }
  }
}

@MainActor struct LiveBodySessionRetryTests {
  @Test func sequentialSessionsRequireFreshGenerationAndBeginDisarmed() async throws {
    let driver = ControlledCameraDriver()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized), driver: driver)
    let provider = BodyInputService(camera: camera)
    var previous: UUID?
    var geometry: UInt64 = 0
    for _ in 0..<3 {
      let config = LiveVisionFixtures.configuration(UUID())
      try await provider.start(configuration: config)
      let source = try #require(camera.state.context)
      #expect(source.generation == config.sessionGeneration && source.generation != previous)
      #expect(source.geometryRevision > geometry)
      #expect(provider.currentContext?.calibrationRevisions.isEmpty == true)
      #expect(provider.currentContext?.cutovers.isEmpty == true)
      #expect(provider.latestSnapshot == nil && provider.acceptedContextRevision == 0)
      #expect(provider.calibrationProgress.request == nil)
      #expect(camera.frames.tracking.snapshot.requestID == nil)
      #expect(camera.frames.tracking.snapshot.acknowledgment == nil)
      try await provider.start(configuration: config) // idempotent current Start
      let stream = try provider.snapshotStream(generation: config.sessionGeneration)
      #expect(throws: BodyInputOperationError.consumerAlreadyClaimed) {
        try provider.snapshotStream(generation: config.sessionGeneration)
      }
      let receipt = try provider.makeBindingRequest()
      try provider.armBinding(receipt)
      await provider.stop()
      var iterator = stream.makeAsyncIterator()
      #expect(await iterator.next() == nil)
      #expect(provider.status == .stopped && provider.currentContext?.isActive == false)
      #expect(provider.latestSnapshot == nil && camera.state.context == nil)
      #expect(camera.frames.usage.frames == 0)
      #expect(throws: PlayerTrackingError.staleControl) { try camera.frames.tracking.arm(request: receipt) }
      await #expect(throws: CameraFailure.staleOperation) { try await provider.start(configuration: config) }
      #expect(provider.status == .stopped)
      previous = source.generation; geometry = source.geometryRevision
    }
    #expect(await driver.starts == 3)
    #expect(await driver.stops == 3)
  }

  @Test func priorBindingCalibrationSourceAndPresentationCannotCrossRetry() async throws {
    let driver = ControlledCameraDriver()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized), driver: driver)
    let provider = BodyInputService(camera: camera)
    let bridge = VisionNumericPoseBridge(gate: camera.frames.tracking)
    try await provider.start(configuration: LiveVisionFixtures.configuration(UUID()))
    let oldSource = try #require(camera.state.context)
    let oldEvents = try #require(await driver.events)
    let attachment = try bridge.attach()
    let request = try provider.makeBindingRequest(); try provider.armBinding(request)
    // The same transactional core used by CameraCopySink, with explicit deterministic frames.
    let f = try TrackingIntegrationFixture()
    var engine = try MotionEngine(policy: B2bExperimentalPolicyV1.value)
    let base = CameraHostClock.now() - 0.25
    var last: (CameraPoseResult, CameraTrackingAdmission, PlayerTrackingSnapshot)?
    for i in 1...2 {
      let pose = try f.result(UInt64(i), base + Double(i-1)*0.125,
        LiveVisionFixtures.standingPair, context: oldSource)
      let admission = try #require(camera.frames.tracking.admit(pose.source))
      let staged = try engine.staged(pose, admission: admission)
      try #require(camera.frames.tracking.finish(staged, admission: admission, source: pose.source,
        mutualCoreCount: 4) { engine = staged })
      let receipt = try #require(camera.frames.tracking.snapshot.latest)
      camera.frames.tracking.publishBody(pose, admission: admission, receipt: receipt)
      camera.frames.tracking.publishPresentation(pose, admission: admission, receipt: receipt)
      last = (pose, admission, receipt)
    }
    let oldAck = try #require(camera.frames.tracking.snapshot.acknowledgment)
    let oldCP1 = try #require(provider.latestSnapshot)
    let calibration = try provider.requestStandingCalibration(id: UUID())
    let evidence = try #require(last)
    await provider.stop()
    #expect(bridge.drain(attachment) == nil)
    try await provider.start(configuration: LiveVisionFixtures.configuration(UUID()))
    let current = try #require(camera.state.context)
    #expect(current.generation != oldSource.generation && current.epoch != oldSource.epoch)
    #expect(provider.currentContext?.accepts(oldCP1) == false)
    #expect(throws: PlayerTrackingError.staleControl) { try camera.armBinding(request: request) }
    provider.cancelStandingCalibration(calibration)
    #expect(provider.calibrationProgress.request == nil)
    #expect(throws: LiveVisionError.self) {
      try provider.confirmStandingCandidate(calibration.id, expectedContextRevision: 0)
    }
    oldEvents.emit(.failure(.processingFailure))
    camera.frames.tracking.sourceLost(oldSource)
    camera.frames.tracking.publishBody(evidence.0, admission: evidence.1, receipt: evidence.2)
    camera.frames.tracking.publishPresentation(evidence.0, admission: evidence.1, receipt: evidence.2)
    camera.frames.tracking.finishMask(LiveVisionFixtures.mask(evidence.0), pose: evidence.0,
      admission: evidence.1, receipt: evidence.2)
    #expect(camera.frames.tracking.snapshot.acknowledgment == nil)
    #expect(camera.frames.tracking.snapshot.acknowledgment?.requestID != oldAck.requestID)
    #expect(provider.latestSnapshot == nil && provider.currentContext?.calibrationRevisions.isEmpty == true)
    let fresh = try bridge.attach(); bridge.cancel(attachment)
    #expect(bridge.drain(fresh)?.status.active == false)
    #expect(provider.currentContext?.isActive == true)
    // A genuine fresh explicit request still acquires after the retained B2 generation guard.
    let nextRequest = try provider.makeBindingRequest(); try provider.armBinding(nextRequest)
    for i in 1...2 {
      let pose = try f.result(UInt64(i), base + Double(i-1)*0.125,
        LiveVisionFixtures.standingPair, context: current)
      let admission = try #require(camera.frames.tracking.admit(pose.source))
      let staged = try engine.staged(pose, admission: admission)
      try #require(camera.frames.tracking.finish(staged, admission: admission, source: pose.source,
        mutualCoreCount: 4) { engine = staged })
    }
    #expect(camera.frames.tracking.snapshot.acknowledgment?.requestID == nextRequest.requestID)
    let nextCalibration = try provider.requestStandingCalibration(id: calibration.id)
    #expect(nextCalibration != calibration)
    provider.cancelStandingCalibration(calibration)
    #expect(provider.calibrationProgress.request == nextCalibration)
    await provider.stop()
  }

  @Test func blockedWorkerRetainsSessionLeaseUntilCleanupAndDuplicateStopsShareDrain() async throws {
    let driver = ControlledCameraDriver(); let sink = ControlledCameraSink()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized), driver: driver, sink: sink)
    let provider = BodyInputService(camera: camera)
    let competitor = BodyInputService(camera: camera)
    var statuses: [BodyInputStatus] = []
    _ = try provider.statusUpdates { statuses.append($0.status) }
    try await provider.start(configuration: LiveVisionFixtures.configuration(UUID()))
    let context = try #require(camera.state.context)
    _ = try CameraTestFrames.offer(CameraTestFrames.buffer(), store: camera.frames, context: context)
    await sink.untilEntered()
    let stopped = RetryStopSignal(); _ = try camera.observe { stopped.observe($0) }
    let stop = Task { await provider.stop() }
    await stopped.wait()
    #expect(camera.frames.usage.frames == 1)
    #expect(provider.currentContext?.isActive == false)
    #expect(statuses.last == .stopped)
    await #expect(throws: BodyInputOperationError.notRunning) {
      try await provider.start(configuration: LiveVisionFixtures.configuration(UUID()))
    }
    await #expect(throws: CameraFailure.operationConflict) {
      try await competitor.start(configuration: LiveVisionFixtures.configuration(UUID()))
    }
    await #expect(throws: CameraFailure.operationConflict) { try await camera.start(generation: UUID()) }
    let duplicateStop = Task { await provider.stop() }
    await sink.release(); await stop.value; await duplicateStop.value
    #expect(camera.frames.usage.frames == 0 && camera.frames.metrics.snapshot.workspaceBytes == 0)
    #expect(await sink.resets == 1)
    try await provider.start(configuration: LiveVisionFixtures.configuration(UUID()))
    #expect(await driver.starts == 2)
    await provider.stop()
  }

  @Test func stopDuringPendingFullRebindDrainsItBeforeNewSession() async throws {
    let driver = ControlledCameraDriver(); let sink = ControlledCameraSink()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized), driver: driver, sink: sink)
    let provider = BodyInputService(camera: camera)
    try await provider.start(configuration: LiveVisionFixtures.configuration(UUID()))
    let stream = try provider.snapshotStream(generation: try #require(provider.currentContext?.sessionGeneration))
    let context = try #require(camera.state.context)
    _ = try CameraTestFrames.offer(CameraTestFrames.buffer(), store: camera.frames, context: context)
    await sink.untilEntered()
    let stopped = RetryStopSignal(); _ = try camera.observe { stopped.observe($0) }
    let request = try provider.makeBindingRequest()
    let rebind = Task { try await camera.requestFullRebind(request: request) }
    await stopped.wait()
    let stop = Task { await provider.stop() }
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == nil) // barrier: production stop has closed CP1
    // Stopping the session synchronously revokes the receipt before either cleanup can finish.
    // Awaiting a second stop must share that drain, not release its operation ownership early.
    let duplicate = Task { await provider.stop() }
    await sink.release()
    await stop.value; await duplicate.value
    await #expect(throws: CancellationError.self) { try await rebind.value }
    #expect(await driver.starts == 1)
    #expect(camera.state.context == nil && camera.frames.usage.frames == 0)
    #expect(camera.frames.tracking.snapshot.requestID == nil)
    try await provider.start(configuration: LiveVisionFixtures.configuration(UUID()))
    #expect(await driver.starts == 2)
    #expect(camera.frames.tracking.snapshot.acknowledgment == nil)
    await provider.stop()
  }

  @Test func stopDuringPermissionWaitJoinsOldStartupBeforeRetry() async throws {
    let permission = ControlledCameraPermission(.notDetermined, hold: true)
    let driver = ControlledCameraDriver()
    let camera = CameraPipeline(permission: permission, driver: driver)
    let provider = BodyInputService(camera: camera)
    let start = Task { try await provider.start(configuration: LiveVisionFixtures.configuration(UUID())) }
    await permission.untilRequested()
    let stopped = RetryStopSignal(); _ = try camera.observe { stopped.observe($0) }
    let stop = Task { await provider.stop() }; await stopped.wait()
    await #expect(throws: BodyInputOperationError.notRunning) {
      try await provider.start(configuration: LiveVisionFixtures.configuration(UUID()))
    }
    await permission.resolve(true)
    await stop.value
    await #expect(throws: CancellationError.self) { try await start.value }
    #expect(await driver.starts == 0 && camera.state.context == nil)
    let retry = Task { try await provider.start(configuration: LiveVisionFixtures.configuration(UUID())) }
    await permission.untilRequested(); await permission.resolve(true); try await retry.value
    #expect(await driver.starts == 1)
    #expect(camera.frames.tracking.snapshot.requestID == nil)
    await provider.stop()
  }

  @Test func inactiveFacadeCannotStopOrReadAnotherProvidersSession() async throws {
    let driver = ControlledCameraDriver()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized), driver: driver)
    let first = BodyInputService(camera: camera); let second = BodyInputService(camera: camera)
    try await first.start(configuration: LiveVisionFixtures.configuration(UUID()))
    await second.stop()
    #expect(second.status == .stopped && second.currentContext == nil)
    #expect(first.currentContext?.isActive == true)
    #expect(await driver.starts == 1)
    #expect(throws: BodyInputOperationError.notRunning) { try second.makeBindingRequest() }
    await first.stop()
    let stoppedContext = first.currentContext
    try await second.start(configuration: LiveVisionFixtures.configuration(UUID()))
    await first.stop()
    #expect(first.currentContext == stoppedContext && first.latestSnapshot == nil)
    #expect(second.currentContext?.isActive == true)
    #expect(throws: BodyInputOperationError.wrongGeneration) {
      try second.releaseSnapshotSubscription(generation: stoppedContext!.sessionGeneration)
    }
    await second.stop()
  }

  @Test func nativeLossCannotBeRetriedInPlaceButExplicitStoppedSessionCanRestart() async throws {
    let driver = ControlledCameraDriver()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized), driver: driver)
    let provider = BodyInputService(camera: camera)
    let config = LiveVisionFixtures.configuration(UUID())
    try await provider.start(configuration: config)
    let old = try #require(await driver.events)
    let request = try provider.makeBindingRequest(); try provider.armBinding(request)
    old.emit(.interrupted(1)) // actual source gate synchronously revokes before MainActor handling
    #expect(provider.currentContext?.isActive == false)
    #expect(camera.frames.tracking.snapshot.requestID == nil)
    await #expect(throws: BodyInputOperationError.notRunning) { try await provider.start(configuration: config) }
    await provider.stop()
    try await provider.start(configuration: LiveVisionFixtures.configuration(UUID()))
    old.emit(.interruptionEnded)
    #expect(camera.frames.tracking.snapshot.requestID == nil && camera.frames.tracking.snapshot.acknowledgment == nil)
    #expect(provider.currentContext?.isActive == true)
    await provider.stop()
  }

  @Test func concurrentStartsShareOnlyTheCurrentOwnersStartup() async throws {
    let driver = ControlledCameraDriver(hold: true)
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized), driver: driver)
    let provider = BodyInputService(camera: camera)
    let other = BodyInputService(camera: camera)
    let config = LiveVisionFixtures.configuration(UUID())
    let first = Task { try await provider.start(configuration: config) }
    await driver.untilStarted()
    let second = Task { try await provider.start(configuration: config) }
    await #expect(throws: CameraFailure.operationConflict) { try await other.start(configuration: config) }
    await #expect(throws: BodyInputOperationError.configurationChanged) {
      try await provider.start(configuration: LiveVisionFixtures.configuration(UUID()))
    }
    await driver.release(); try await first.value; try await second.value
    #expect(await driver.starts == 1)
    #expect(provider.currentContext?.isActive == true)
    await provider.stop()
  }

  @Test func failedStartReleasesOwnershipWithoutArming() async throws {
    let driver = ControlledCameraDriver()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.denied), driver: driver)
    let provider = BodyInputService(camera: camera)
    for _ in 0..<2 {
      await #expect(throws: CameraFailure.permissionDenied) {
        try await provider.start(configuration: LiveVisionFixtures.configuration(UUID()))
      }
      #expect(camera.status == .stopped && camera.state.context == nil)
      #expect(camera.frames.tracking.snapshot.requestID == nil)
    }
    #expect(await driver.starts == 0)
  }
}
