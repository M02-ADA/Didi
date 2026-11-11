import CoreVideo
import Foundation
import Testing
@testable import Sedactive

nonisolated enum LiveVisionFixtures {
  static func configuration(_ generation: UUID, capacity: Int = 2) -> BodyInputConfiguration {
    .init(sessionGeneration: generation, calibrations: [:],
      playerPlaneLayout: .init(leftCenterX: -1, rightCenterX: 1, gameUnitsPerImageHeight: 2),
      snapshotBufferCapacity: capacity)
  }
  static var standingPair: [PoseCandidate] {
    TrackingFixtures.pair.map { c in
      var j = c.joints
      let x = (j[.leftHip]!.x + j[.rightHip]!.x) / 2
      j[.nose] = .init(x: x, y: 0.8, confidence: 0.9)
      j[.leftAnkle] = .init(x: x - 0.04, y: 0.1, confidence: 0.9)
      j[.rightAnkle] = .init(x: x + 0.04, y: 0.1, confidence: 0.9)
      j[.leftWrist] = .init(x: x - 0.1, y: 0.45, confidence: 0.9)
      j[.rightWrist] = .init(x: x + 0.1, y: 0.45, confidence: 0.9)
      return .init(candidateID: c.candidateID, joints: j, maskTopImageY: nil, maskBottomImageY: nil,
        leftFootBottomImageY: nil, rightFootBottomImageY: nil, maskAssociation: .unavailable)
    }
  }
  static func mask(_ pose: CameraPoseResult, service: Double = 0.01) -> PersonMaskObservation {
    let regions: [PlayerID: PersonMaskRegion] = [
      .player1: .init(candidateID: 10, label: 2, minX: 0.6, maxX: 0.9, minY: 0.05, maxY: 0.9),
      .player2: .init(candidateID: 20, label: 1, minX: 0.1, maxX: 0.4, minY: 0.05, maxY: 0.9)]
    return .init(source: pose.source, quality: .torsoSupportedGeometryUnverified, regions: regions,
      outputBytes: 64, serviceSeconds: service)
  }
  /// Head-top 0.9 and soles 0.1 for both players, as the segmenter would attach them.
  static func withAnatomy(_ mask: PersonMaskObservation, pose: CameraPoseResult, revision: UInt64) -> PersonMaskObservation {
    var mask = mask
    for (id, region) in mask.regions {
      mask.anatomy[id] = .init(source: pose.source, controlRevision: revision, candidateID: region.candidateID,
        crown: .init(imageY: 0.9, status: .experimental), leftSole: .init(imageY: 0.1, status: .experimental),
        rightSole: .init(imageY: 0.1, status: .experimental))
    }
    return mask
  }
  static func association(_ pose: CameraPoseResult, revision: UInt64) -> PlayerTrackingSnapshot {
    let c = pose.source
    let context = PlayerTrackingContext(generation: c.context.generation, epoch: c.context.epoch,
      geometryRevision: c.context.geometryRevision, imageWidth: c.descriptor.width,
      imageHeight: c.descriptor.height, rotationAngle: c.rotationAngle, mirrored: c.mirrored)
    func slot(_ id: UInt64) -> PlayerTrackingSlotResult {
      .init(state: .tracking, reason: .matched, candidateID: id, cost: 0,
        requiresRebind: false, lastConfirmedAt: c.capturedAt)
    }
    return .init(source: .init(context: context, frameID: c.frameID, capturedAt: c.capturedAt,
      controlRevision: revision), evaluatedAt: c.capturedAt, controlRevision: revision,
      player1: slot(10), player2: slot(20), assignmentCount: 2, confirmedDescriptorCount: 4,
      provisionalDescriptorCount: 0)
  }
  static func sessionFixture() throws -> (TrackingIntegrationFixture, CalibrationSession, CalibrationAdmission) {
    var f = try TrackingIntegrationFixture(); try f.bind()
    var session = CalibrationSession()
    let request = try #require(f.gate.snapshot.requestID)
    _ = try session.request(id: UUID(), source: f.context, revision: f.gate.snapshot.revision,
      bindingRequest: request, at: 0.125)
    return (f, session, try #require(session.admission))
  }
}

nonisolated struct LiveVisionPipelineTests {
  @Test func maskAssociationUsesCurrentCandidateMappingNeverLabelOrder() throws {
    let f = try TrackingIntegrationFixture()
    let pose = try f.result(3, 0.25, LiveVisionFixtures.standingPair)
    let association = LiveVisionFixtures.association(pose, revision: 2)
    for labels: [UInt8] in [[1, 2], [2, 1]] {
      let regions = PersonSegmenter.associate(pose: pose, association: association, labels: labels,
        bounds: [[0, 3, 0, 7], [4, 7, 0, 7]], width: 8, height: 8) { x, _ in x < 4 ? 1 : 2 }
      #expect(regions[.player1]?.label == 2 && regions[.player2]?.label == 1)
      #expect(regions[.player1]?.candidateID == 10)
    }
  }
  @Test func sharedMaskOrWeakMissingTorsoCannotAssignPlayers() throws {
    let f = try TrackingIntegrationFixture()
    for missing in [false, true] {
      let candidates = missing ? [TrackingFixtures.candidate(10, x: 0.75, missing: [.leftHip]),
        TrackingFixtures.candidate(20, x: 0.25)] : LiveVisionFixtures.standingPair
      let pose = try f.result(3, 0.25, candidates)
      let a = LiveVisionFixtures.association(pose, revision: 2)
      let regions = PersonSegmenter.associate(pose: pose, association: a, labels: [1, 2],
        bounds: [[0, 7, 0, 7], [0, 7, 0, 7]], width: 8, height: 8) { _, _ in 1 }
      #expect(regions.isEmpty)
    }
  }
  @Test func mismatchedFrameEpochAndControlCannotJoinMasks() throws {
    var f = try TrackingIntegrationFixture(); try f.bind()
    try f.gate.configureBody(LiveVisionFixtures.configuration(f.context.generation))
    _ = try f.gate.requestCalibration(id: UUID())
    let pose = try f.result(3, 0.25, LiveVisionFixtures.standingPair)
    let stamp = try #require(f.gate.admit(pose.source)); try #require(try f.finish(pose, stamp: stamp))
    let receipt = try #require(f.gate.snapshot.latest)
    let old = try f.result(2, 0.125, LiveVisionFixtures.standingPair)
    #expect(!f.gate.beginMask(pose: old, admission: stamp, receipt: receipt))
    let wrong = try f.result(3, 0.25, LiveVisionFixtures.standingPair,
      context: .init(generation: f.context.generation, epoch: UUID(), geometryRevision: 1))
    #expect(!f.gate.beginMask(pose: wrong, admission: stamp, receipt: receipt))
    f.gate.revoke()
    f.gate.finishMask(LiveVisionFixtures.mask(pose), pose: pose, admission: stamp, receipt: receipt)
    #expect(f.gate.readBody().calibration.sampleCount == 0)
    #expect(f.gate.readBody().latest == nil)
  }
  @Test func admissionBeforeCalibrationCannotBorrowNewIntent() throws {
    var f = try TrackingIntegrationFixture(); try f.bind()
    try f.gate.configureBody(LiveVisionFixtures.configuration(f.context.generation))
    let pose = try f.result(3, 0.25, LiveVisionFixtures.standingPair)
    let old = try #require(f.gate.admit(pose.source))
    _ = try f.gate.requestCalibration(id: UUID())
    try #require(try f.finish(pose, stamp: old))
    #expect(!f.gate.beginMask(pose: pose, admission: old, receipt: try #require(f.gate.snapshot.latest)))
  }
  /// Without head-top/sole readings no sample joins a window: no candidate, nothing to accept,
  /// and the request ends with the reason instead of waiting forever.
  @Test func tenActualPairedSamplesWithoutAnatomyMakeNoCandidate() throws {
    let (f, initialSession, stamp) = try LiveVisionFixtures.sessionFixture()
    var session = initialSession
    for i in 0..<10 {
      let pose = try f.result(UInt64(i + 3), 0.25 + Double(i), LiveVisionFixtures.standingPair)
      let started = session.beginSample(stamp, source: pose.source, at: pose.source.capturedAt)
      try #require(started)
      session.observe(LiveVisionFixtures.mask(pose), pose: pose,
        association: LiveVisionFixtures.association(pose, revision: stamp.bindingRevision),
        stamp: stamp, at: pose.source.capturedAt + 0.01)
    }
    #expect(session.progress.phase == .collecting && session.candidate == nil && session.count == 0)
    for id in PlayerID.allCases {
      #expect(session.players[id]?.rejected[.bodyNotFullyVisible] == 10 && session.players[id]?.samples == 0)
    }
    var body = LiveBodyInputState()
    try body.configure(LiveVisionFixtures.configuration(f.context.generation), source: f.context)
    body.calibration = session
    #expect(throws: LiveVisionError.contextConflict) {
      try body.accept(candidateID: UUID(), expectedRevision: 0, at: 9.3)
    }
    #expect(body.configuration?.calibrations.isEmpty == true && body.acceptedRevision == 0)
    session.expire(at: 0.125 + StandingCollectionPolicyV1.requestLifetime)
    #expect(session.phase == .expired && session.reason.contains("bodyNotFullyVisible"))
    _ = f
  }
  @Test func cadenceCannotReuseFrameOrRepeatedHostInstant() throws {
    let (f, initial, stamp) = try LiveVisionFixtures.sessionFixture(); var session = initial
    let p = try f.result(3, 0.25, LiveVisionFixtures.standingPair)
    let initialStarted = session.beginSample(stamp, source: p.source, at: 0.25)
    #expect(initialStarted)
    let repeated = session.beginSample(stamp, source: p.source, at: 1.3)
    #expect(!repeated)
    let p2 = try f.result(4, 1.25, LiveVisionFixtures.standingPair)
    let early = session.beginSample(stamp, source: p2.source, at: 0.25)
    #expect(!early)
  }
  @Test func uncertaintyResetsCollectionAndWithdrawsCandidate() throws {
    let (f, initial, stamp) = try LiveVisionFixtures.sessionFixture(); var session = initial
    let p = try f.result(3, 0.25, LiveVisionFixtures.standingPair)
    let started = session.beginSample(stamp, source: p.source, at: 0.25)
    try #require(started)
    session.observe(LiveVisionFixtures.withAnatomy(LiveVisionFixtures.mask(p), pose: p, revision: stamp.bindingRevision),
      pose: p, association: LiveVisionFixtures.association(p, revision: stamp.bindingRevision), stamp: stamp, at: 0.26)
    #expect(session.count == 1)
    session.uncertain()
    #expect(session.count == 0 && session.phase == .waitingForReliablePair)
  }
  @Test func cancellationAndSupersessionRejectOldResults() throws {
    let (f, initial, stamp) = try LiveVisionFixtures.sessionFixture(); var session = initial
    let p = try f.result(3, 0.25, LiveVisionFixtures.standingPair)
    let started = session.beginSample(stamp, source: p.source, at: 0.25)
    try #require(started)
    session.invalidate("Cancel")
    let token = try session.request(id: UUID(), source: f.context, revision: stamp.bindingRevision,
      bindingRequest: stamp.bindingRequest, at: 0.26)
    session.observe(LiveVisionFixtures.mask(p), pose: p,
      association: LiveVisionFixtures.association(p, revision: stamp.bindingRevision), stamp: stamp, at: 0.27)
    #expect(session.count == 0 && session.admission?.request == token)
  }
  @Test func deadlineExpiresWithoutFabricatedFrame() throws {
    var f = try TrackingIntegrationFixture(); try f.bind()
    try f.gate.configureBody(LiveVisionFixtures.configuration(f.context.generation))
    _ = try f.gate.requestCalibration(id: UUID())
    f.gate.expireDue(at: 31)
    #expect(f.gate.readBody().calibration.phase == .expired)
    #expect(f.gate.readBody().calibration.request == nil)
  }
  @Test func overrunStopsFurtherSamplingEvenWhenResultIsStale() throws {
    var f = try TrackingIntegrationFixture(); try f.bind()
    try f.gate.configureBody(LiveVisionFixtures.configuration(f.context.generation))
    _ = try f.gate.requestCalibration(id: UUID())
    let p = try f.result(3, 0.25, LiveVisionFixtures.standingPair)
    let stamp = try #require(f.gate.admit(p.source)); try #require(try f.finish(p, stamp: stamp))
    let receipt = try #require(f.gate.snapshot.latest)
    try #require(f.gate.beginMask(pose: p, admission: stamp, receipt: receipt))
    f.clock.time = 1.0
    f.gate.finishMask(LiveVisionFixtures.mask(p, service: 0.75), pose: p, admission: stamp, receipt: receipt)
    #expect(f.gate.readBody().calibration.phase == .stoppedForReview)
    #expect(f.gate.readBody().calibration.candidate == nil)
    #expect(!f.gate.beginMask(pose: p, admission: stamp, receipt: receipt))
  }
  @Test func sourceLossClearsLiveEvidenceWithoutAnotherFrame() throws {
    var f = try TrackingIntegrationFixture(); try f.bind()
    try f.gate.configureBody(LiveVisionFixtures.configuration(f.context.generation))
    let p = try f.result(3, 0.25, LiveVisionFixtures.standingPair)
    let stamp = try #require(f.gate.admit(p.source)); try #require(try f.finish(p, stamp: stamp))
    let receipt = try #require(f.gate.snapshot.latest)
    f.gate.publishBody(p, admission: stamp, receipt: receipt)
    _ = try #require(f.gate.readBody().latest)
    f.gate.sourceLost(f.context)
    #expect(f.gate.readBody().latest == nil && f.gate.readBody().context?.isActive == false)
    f.gate.publishBody(p, admission: stamp, receipt: receipt)
    #expect(f.gate.readBody().latest == nil)
  }
  @Test func sourceRevocationCutoverRejectsOldUncalibratedSnapshotsOnResume() throws {
    var f = try TrackingIntegrationFixture(); try f.bind()
    try f.gate.configureBody(LiveVisionFixtures.configuration(f.context.generation))
    let p = try f.result(3, 0.25, LiveVisionFixtures.standingPair)
    let stamp = try #require(f.gate.admit(p.source)); try #require(try f.finish(p, stamp: stamp))
    let receipt = try #require(f.gate.snapshot.latest)
    f.gate.publishBody(p, admission: stamp, receipt: receipt)
    let old = try #require(f.gate.readBody().latest)
    f.gate.sourceLost(f.context); f.gate.resume(f.context)
    let context = try #require(f.gate.readBody().context)
    #expect(!context.accepts(old))
    #expect(f.gate.snapshot.requestID == nil && f.gate.snapshot.acknowledgment == nil)
  }
  @Test func arbitraryReferencesCannotBecomeAcceptedThroughCP1() throws {
    var f = try TrackingIntegrationFixture(); try f.bind()
    try f.gate.configureBody(LiveVisionFixtures.configuration(f.context.generation))
    let value = try #require(try LH00TestData.load().configuration.calibrations[.player1])
    #expect(throws: LiveVisionError.unsupportedAnatomy) {
      try f.gate.replaceBodyCalibrations([.player1: value], generation: f.context.generation)
    }
  }
  @Test func oneConsumerAndBoundedNewestDelivery() throws {
    var f = try TrackingIntegrationFixture(); try f.bind()
    try f.gate.configureBody(LiveVisionFixtures.configuration(f.context.generation, capacity: 1))
    let stream = try f.gate.bodyStream(generation: f.context.generation)
    defer { withExtendedLifetime(stream) {} }
    #expect(throws: BodyInputOperationError.consumerAlreadyClaimed) {
      try f.gate.bodyStream(generation: f.context.generation)
    }
    for i in 3...5 {
      let p = try f.result(UInt64(i), Double(i) * 0.125, LiveVisionFixtures.standingPair)
      let stamp = try #require(f.gate.admit(p.source)); try #require(try f.finish(p, stamp: stamp))
      let receipt = try #require(f.gate.snapshot.latest)
      f.gate.publishBody(p, admission: stamp, receipt: receipt)
    }
    #expect(f.gate.readBody().diagnostics.droppedSnapshotCount == 2)
    try f.gate.releaseBodyStream(generation: f.context.generation)
  }
  @Test func nativeMaskAccountingSurvivesInvalidationUntilOwnerExits() {
    let metrics = CameraCaptureMetrics()
    let source = CameraTestFrames.context()
    metrics.begin(source); metrics.maskOutputBytes(1024)
    metrics.begin(CameraTestFrames.context(2))
    #expect(metrics.snapshot.maskBytes == 1024 && metrics.snapshot.ownedPixelBytes == 1024)
    metrics.maskOutputBytes(0)
    #expect(metrics.snapshot.maskBytes == 0 && metrics.snapshot.peakMaskBytes == 1024)
  }
  @Test func cancelledConsumerCanBeReclaimedWithoutGateReentry() async throws {
    var f = try TrackingIntegrationFixture(); try f.bind()
    try f.gate.configureBody(LiveVisionFixtures.configuration(f.context.generation))
    let stream = try f.gate.bodyStream(generation: f.context.generation)
    let task = Task { for await _ in stream {} }
    task.cancel(); await task.value
    #expect(f.gate.readBody().diagnostics.lastTerminationReason == .cancelled)
    let next = try f.gate.bodyStream(generation: f.context.generation)
    try f.gate.releaseBodyStream(generation: f.context.generation)
    withExtendedLifetime(next) {}
  }
  @Test func diagnosticStallCannotChangeSourceActivityOrAuthorizeBinding() throws {
    var f = try TrackingIntegrationFixture(); try f.bind()
    let config = LiveVisionFixtures.configuration(f.context.generation)
    let diagnostic = BodyInputConfiguration(sessionGeneration: config.sessionGeneration,
      calibrations: [:], playerPlaneLayout: config.playerPlaneLayout,
      noProgressPolicy: .diagnostic(threshold: 0.25))
    try f.gate.configureBody(diagnostic)
    f.clock.time = 0.4
    #expect(f.gate.readBody().progress == .suspectedStall)
    #expect(f.gate.readBody().context?.isActive == true)
  }
  @Test func unsupportedAnatomyCannotProduceValidCollisionGeometry() throws {
    let candidate = LiveVisionFixtures.standingPair[0]
    let slot = PlayerTrackingSlotResult(state: .tracking, reason: .matched, candidateID: 10,
      cost: 0, requiresRebind: false, lastConfirmedAt: 0)
    let calibration = try #require(try LH00TestData.load().configuration.calibrations[.player1])
    let sample = BodyMeasurementExtractor.sample(id: .player1, candidate: candidate, slot: slot,
      calibration: calibration, layout: LiveVisionFixtures.configuration(UUID()).playerPlaneLayout)
    try sample.validate()
    #expect(sample.geometry.leftWristY.validity == .valid && sample.geometry.rightWristY.validity == .valid)
    #expect(sample.geometry.crownY.validity != .valid && sample.geometry.leftSoleY.validity != .valid
      && sample.geometry.rightSoleY.validity != .valid && sample.jumpState.phase == .unknown)
  }
}

nonisolated final class SprintPoseDetector: CameraPoseDetecting {
  func detect(in buffer: CVPixelBuffer) throws -> CameraPoseObservations {
    .init(totalCount: 2, joints: LiveVisionFixtures.standingPair.map(\.joints))
  }
}
nonisolated final class SprintFailingSegmenter: PersonMaskDetecting {
  let revoke: @Sendable () -> Void
  init(revoke: @escaping @Sendable () -> Void = {}) { self.revoke = revoke }
  func detect(in buffer: CVPixelBuffer, pose: CameraPoseResult,
    association: PlayerTrackingSnapshot) throws -> PersonMaskObservation {
    revoke()
    throw PersonMaskError.unsupportedOutput
  }
}
nonisolated struct LiveVisionWorkerTests {
  @Test(arguments: [false, true]) func optionalMaskFailureDoesNotBecomePrimaryFailure(revoke: Bool) async throws {
    let store = FrameStore(); let context = CameraTestFrames.context()
    _ = store.begin(context)
    let sink = CameraCopySink(metrics: store.metrics, poses: store.poses, tracking: store.tracking,
      makeDetector: { SprintPoseDetector() },
      makeSegmenter: { SprintFailingSegmenter(revoke: { if revoke { store.tracking.revoke() } }) })
    try store.tracking.configureBody(LiveVisionFixtures.configuration(context.generation))
    _ = try store.tracking.arm(request: store.tracking.makeBindingRequest())
    let buffer = try CameraTestFrames.buffer()
    let base = CameraHostClock.now() - 0.3
    for i in 1...3 {
      let t = i == 1 ? base : i == 2 ? base + 0.125 : CameraHostClock.now()
      let metadata = CameraFrameMetadata(context: context, frameID: try store.nextIdentity(context),
        capturedAt: t, descriptor: try CameraFrameDescriptor(width: 8, height: 8,
          bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), pixelFormat: kCVPixelFormatType_32BGRA,
          maximumBytes: 1024), rotationAngle: 180, mirrored: false)
      try store.copy(buffer, metadata: metadata)
      let lease = try CameraTestFrames.lease(store, context)
      try await sink.consume(lease.frame)
      store.complete(lease)
      if i == 2 { _ = try store.tracking.requestCalibration(id: UUID()) }
    }
    #expect(store.poses.snapshot.statistics.completed == 3 && store.poses.snapshot.statistics.failures == 0)
    if revoke {
      #expect(store.tracking.snapshot.requestID == nil && store.tracking.readBody().latest == nil)
      #expect(store.tracking.readBody().calibration.sampleCount == 0)
    } else {
      #expect(store.tracking.snapshot.latest?.player1.state == .tracking)
      // A failed optional mask skips the sample; it is not an identity failure.
      let calibration = store.tracking.readBody().calibration
      #expect(calibration.phase == .collecting && calibration.players.values.allSatisfy { $0.latestIssue == .notSeparated })
      #expect(store.tracking.snapshot.accepted == 3)
    }
    store.end(context); await sink.reset()
    #expect(store.metrics.snapshot.workspaceBytes == 0 && store.metrics.snapshot.maskBytes == 0)
  }
}

@MainActor struct LiveBodyInputServiceTests {
  @Test func providerUsesInjectedCameraWithoutAutoBindingAndStopsCleanly() async throws {
    let permission = ControlledCameraPermission(.authorized)
    let driver = ControlledCameraDriver()
    let camera = CameraPipeline(permission: permission, driver: driver)
    let service = BodyInputService(camera: camera)
    let config = LiveVisionFixtures.configuration(UUID())
    try await service.start(configuration: config)
    #expect(service.camera === camera && service.currentContext?.isActive == true)
    #expect(camera.frames.tracking.snapshot.requestID == nil && service.calibrationProgress.request == nil)
    try await service.start(configuration: config)
    #expect(await driver.starts == 1)
    let stream = try service.snapshotStream(generation: config.sessionGeneration)
    defer { withExtendedLifetime(stream) {} }
    #expect(throws: BodyInputOperationError.consumerAlreadyClaimed) {
      try service.snapshotStream(generation: config.sessionGeneration)
    }
    #expect(throws: LiveVisionError.inactiveSource) { try service.requestStandingCalibration(id: UUID()) }
    await service.stop()
    #expect(service.status == .stopped && service.latestSnapshot == nil && service.currentContext?.isActive == false)
    #expect(await driver.stops == 1)
  }
}
