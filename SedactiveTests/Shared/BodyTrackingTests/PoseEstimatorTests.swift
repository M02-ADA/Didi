import CoreVideo
import Dispatch
import Foundation
import Synchronization
import Testing
import Vision

@testable import Sedactive

nonisolated enum RawPoseFixtures {
  static let joint = PoseJoint(x: 0.2, y: 0.8, confidence: 0.9)
  static func source(_ context: CameraSourceContext, id: UInt64 = 1) throws -> CameraFrameMetadata {
    CameraFrameMetadata(context: context, frameID: id, capturedAt: Double(id),
      descriptor: try CameraFrameDescriptor(width: 8, height: 8, bytesPerRow: 64,
        pixelFormat: kCVPixelFormatType_32BGRA, maximumBytes: 1024),
      rotationAngle: 180, mirrored: false)
  }
  static func result(_ source: CameraFrameMetadata, count: Int = 2) throws -> CameraPoseResult {
    try CameraPoseAdapter.convert(CameraPoseObservations(totalCount: count,
      joints: Array(repeating: [.nose: joint], count: min(count, PoseEstimator.maximumCandidates))),
      source: source)
  }
}

nonisolated struct PoseEstimatorTests {
  @Test(arguments: [0, 1, 2, 4, 12])
  func allPeopleAreRawCandidatesWithExplicitBound(_ count: Int) throws {
    let source = try RawPoseFixtures.source(CameraTestFrames.context())
    let result = try RawPoseFixtures.result(source, count: count)
    #expect(result.observationCount == count)
    #expect(result.frame.candidates.count == min(count, 8))
    #expect(result.frame.candidates.map(\.candidateID) == Array(0..<UInt64(min(count, 8))))
    #expect(result.frame.candidates.allSatisfy { $0.maskAssociation == .unavailable })
    #expect(result.frame.candidates.allSatisfy { $0.maskTopImageY == nil && $0.leftFootBottomImageY == nil })
    try result.frame.validate()
  }
  @Test func missingInvalidAndZeroConfidenceAreAbsentButLowConfidenceIsPreserved() throws {
    let points: [BodyJoint: PoseJoint] = [
      .nose: .init(x: .nan, y: 0.2, confidence: 1),
      .leftWrist: .init(x: 0, y: 1, confidence: 0.01),
      .rightWrist: .init(x: 0.5, y: 0.5, confidence: 0),
      .leftAnkle: .init(x: -0.1, y: 0.2, confidence: 1),
      .rightAnkle: .init(x: 0.5, y: 1.1, confidence: 1),
      .neck: .init(x: 0.5, y: 0.5, confidence: .infinity),
    ]
    let result = try CameraPoseAdapter.convert(.init(totalCount: 1, joints: [points]),
      source: RawPoseFixtures.source(CameraTestFrames.context()))
    let joints = try #require(result.frame.candidates.first?.joints)
    #expect(joints.count == 1)
    #expect(joints[.leftWrist] == points[.leftWrist])
    #expect(joints[.rightWrist] == nil && joints[.rightEye] == nil)
    #expect(result.invalidJointCount == 5)
  }
  @Test func anatomicalNamesCanonicalCornersAndReorderedCandidatesAreNotTrackedIdentities() throws {
    // 14 original joints plus both knees (kept for setup diagnostics, 11 November 2026).
    #expect(PoseEstimator.joints.count == 16)
    #expect(PoseEstimator.joints.first { $0.0 == .leftKnee }?.1 == .leftKnee)
    #expect(PoseEstimator.joints.first { $0.0 == .rightKnee }?.1 == .rightKnee)
    #expect(PoseEstimator.joints.first { $0.0 == .leftWrist }?.1 == .leftWrist)
    #expect(PoseEstimator.joints.first { $0.0 == .rightAnkle }?.1 == .rightAnkle)
    let left = PoseJoint(x: 0, y: 1, confidence: 1)
    let right = PoseJoint(x: 1, y: 0, confidence: 0.4)
    let a: [BodyJoint: PoseJoint] = [.leftWrist: left, .rightWrist: right]
    let b: [BodyJoint: PoseJoint] = [.nose: RawPoseFixtures.joint]
    let context = CameraTestFrames.context()
    let first = try CameraPoseAdapter.convert(.init(totalCount: 2, joints: [a, b]),
      source: RawPoseFixtures.source(context))
    let second = try CameraPoseAdapter.convert(.init(totalCount: 2, joints: [b, a]),
      source: RawPoseFixtures.source(context, id: 2))
    #expect(first.frame.candidates[0].joints[.leftWrist] == left)
    #expect(first.frame.candidates[0].joints[.rightWrist] == right)
    #expect(second.frame.candidates[1].joints == first.frame.candidates[0].joints)
    #expect(second.frame.candidates[0].candidateID == first.frame.candidates[0].candidateID)
    // Same numeric candidateID refers to a different observation in another source frame.
    #expect(second.frame.candidates[0].joints != first.frame.candidates[0].joints)
  }
  @Test func sourceIdentityTimeDimensionsAndInternalEpochAreNeverRewritten() throws {
    let context = CameraTestFrames.context(7)
    let source = try RawPoseFixtures.source(context, id: 94)
    let result = try RawPoseFixtures.result(source)
    #expect(result.source == source && result.matchesSource)
    #expect(result.source.context.epoch == context.epoch)
    #expect(result.source.rotationAngle == 180 && !result.source.mirrored)
    #expect(result.frame.frameID == 94 && result.frame.capturedAt == 94)
    #expect(result.frame.cameraGeometryRevision == 7 && result.frame.imageWidth == 8)
  }
  @Test func mirroredOrUnappliedPortraitSourceIsRejected() throws {
    let source = try RawPoseFixtures.source(CameraTestFrames.context())
    for (rotation, mirrored) in [(90.0, false), (0.0, true)] {
      let bad = CameraFrameMetadata(context: source.context, frameID: 1, capturedAt: 1,
        descriptor: source.descriptor, rotationAngle: rotation, mirrored: mirrored)
      #expect(throws: (any Error).self) { try RawPoseFixtures.result(bad) }
    }
  }
  @Test func duplicateOlderAndMismatchedSourceCannotReplaceNewerResult() throws {
    let results = CameraPoseResults()
    let context = CameraTestFrames.context()
    results.begin(context)
    let first = try RawPoseFixtures.result(RawPoseFixtures.source(context))
    let second = try RawPoseFixtures.result(RawPoseFixtures.source(context, id: 2))
    let old = try #require(results.start(first.source))
    let new = try #require(results.start(second.source))
    #expect(results.finish(second, ticket: new, startedAt: 3, completedAt: 4))
    #expect(!results.finish(first, ticket: old, startedAt: 3, completedAt: 5))
    #expect(results.start(second.source) == nil)
    #expect(results.snapshot.latest?.source == second.source)
    #expect(results.snapshot.statistics.rejected == 2)
    let third = try RawPoseFixtures.result(RawPoseFixtures.source(context, id: 3))
    let ticket = try #require(results.start(third.source))
    let spoofed = CameraPoseResult(source: third.source, frame: first.frame,
      observationCount: 2, invalidJointCount: 0)
    #expect(!results.finish(spoofed, ticket: ticket, startedAt: 4, completedAt: 5))
    #expect(results.snapshot.latest?.source == second.source)
  }
  @Test(arguments: [0, 1, 2, 3])
  func contextAndSameContextResumeRejectDelayedCompletion(_ component: Int) throws {
    let store = FrameStore()
    let old = CameraTestFrames.context()
    _ = store.begin(old)
    let result = try RawPoseFixtures.result(RawPoseFixtures.source(old))
    let ticket = try #require(store.poses.start(result.source))
    store.suspend(old)
    #expect(store.poses.snapshot.latest == nil)
    let next = CameraSourceContext(generation: component == 0 ? UUID() : old.generation,
      epoch: component == 1 ? UUID() : old.epoch,
      geometryRevision: component == 2 ? 2 : old.geometryRevision)
    if component == 3 { store.resume(old) } else { _ = store.begin(next) }
    #expect(!store.poses.finish(result, ticket: ticket, startedAt: 2, completedAt: 3))
    #expect(store.poses.snapshot.latest == nil)
    store.end(next)
  }
  @Test func noFrameStopAndFailuresInvalidateAndCountersStayBounded() throws {
    let store = FrameStore()
    let context = CameraTestFrames.context()
    _ = store.begin(context)
    let result = try RawPoseFixtures.result(RawPoseFixtures.source(context), count: 0)
    let ticket = try #require(store.poses.start(result.source))
    #expect(store.poses.finish(result, ticket: ticket, startedAt: 2, completedAt: 3))
    #expect(store.poses.snapshot.statistics.counts == [1, 0, 0, 0])
    store.end(context)
    #expect(store.poses.snapshot.latest == nil)
    #expect(!store.poses.finish(result, ticket: ticket, startedAt: 2, completedAt: 4))
    _ = store.begin(CameraTestFrames.context(2))
    store.poses.failed(ticket)
    #expect(store.poses.snapshot.latest == nil)
    #expect(store.poses.snapshot.statistics.failures == 0)
  }
}

// Tests alone inject this synchronous detector. Production constructs the real Vision adapter.
// Blocking here models a non-cooperative synchronous inference; the async test never blocks its executor.
nonisolated final class RawPoseGate: Sendable {
  let entered: AsyncStream<Void>
  private let signal: AsyncStream<Void>.Continuation
  private let releaseSignal = DispatchSemaphore(value: 0)
  let destroyed = Mutex(false)
  init() {
    let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    entered = pair.stream
    signal = pair.continuation
  }
  func waitInInference() {
    signal.yield(())
    releaseSignal.wait()
  }
  func release() { releaseSignal.signal() }
}
nonisolated final class ControlledPoseDetector: CameraPoseDetecting {
  let gate: RawPoseGate?
  let shouldFail: Bool
  init(gate: RawPoseGate? = nil, shouldFail: Bool = false) {
    self.gate = gate
    self.shouldFail = shouldFail
  }
  deinit { gate?.destroyed.withLock { $0 = true } }
  func detect(in buffer: CVPixelBuffer) throws -> CameraPoseObservations {
    #expect(CVPixelBufferGetWidth(buffer) == 8)
    #expect(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    #expect(CVPixelBufferGetBaseAddress(buffer)?.load(as: UInt8.self) == 42)
    gate?.waitInInference()
    if shouldFail { throw CameraPoseError.invalidResult }
    return .init(totalCount: 2, joints: [[.nose: RawPoseFixtures.joint], [:]])
  }
}
nonisolated struct RawPoseWorkerTests {
  @Test func slowInferenceKeepsOneConsumerAndPendingLatestAndReleasesAfterCancelledStop()
    async throws
  {
    let store = FrameStore()
    let context = CameraTestFrames.context()
    _ = store.begin(context)
    let gate = RawPoseGate()
    defer { gate.release() }
    let sink = CameraCopySink(metrics: store.metrics, poses: store.poses,
      makeDetector: { ControlledPoseDetector(gate: gate) })
    let buffer = try CameraTestFrames.buffer()
    try CameraTestFrames.fill(buffer, 42)
    _ = try CameraTestFrames.offer(buffer, store: store, context: context)
    var lease: CameraProcessingLease? = try CameraTestFrames.lease(store, context)
    var job: Task<Void, Error>? = Task { [frame = lease!.frame] in try await sink.consume(frame) }
    var entered = gate.entered.makeAsyncIterator()
    _ = await entered.next()
    #expect(throws: CameraFrameError.processingBusy) { try store.acquire(context) }
    for _ in 0..<20 { _ = try CameraTestFrames.offer(buffer, store: store, context: context) }
    #expect(store.usage.frames == 2)
    #expect(store.usage.peakFrames <= 3)
    #expect(store.diagnostics.superseded == 19)
    #expect(store.metrics.snapshot.workspaceBytes <= 4 * 1024 * 1024)
    store.end(context)
    job?.cancel()
    #expect(store.usage.frames == 1)  // Inference's owner cannot be force-reclaimed by Stop.
    gate.release()
    try await job?.value
    store.complete(lease!)
    lease = nil
    job = nil
    await sink.reset()
    #expect(store.poses.snapshot.latest == nil)
    #expect(store.poses.snapshot.statistics.rejected == 1)
    #expect(store.usage.bytes == 0 && store.metrics.snapshot.workspaceBytes == 0)
    #expect(gate.destroyed.withLock { $0 })
  }
  @Test func reconstructedBytesProduceExactSourceValuesAndPreviewIsIndependent() async throws {
    let store = FrameStore()
    let context = CameraTestFrames.context()
    _ = store.begin(context)
    #if DEBUG
      store.preview.setEnabled(true)  // No preview worker; cannot hold the primary raw frame.
    #endif
    let sink = CameraCopySink(metrics: store.metrics, poses: store.poses,
      makeDetector: { ControlledPoseDetector() })
    do {
      let buffer = try CameraTestFrames.buffer()
      try CameraTestFrames.fill(buffer, 42)
      let source = try CameraTestFrames.offer(buffer, store: store, context: context)
      let lease = try CameraTestFrames.lease(store, context)
      try await sink.consume(lease.frame)
      #expect(store.poses.snapshot.latest?.source == source)
      #expect(store.poses.snapshot.latest?.frame.candidates.count == 2)
      #expect(store.poses.snapshot.statistics.completed == 1)
      store.complete(lease)
      store.end(context)
    }
    await sink.reset()
    #expect(store.usage.bytes == 0)
    #if DEBUG
      #expect(store.preview.budget.usage.bytes == 0)
    #endif
  }
  @Test func inferenceFailureIsReportedWithoutFakeFallback() async throws {
    let store = FrameStore()
    let context = CameraTestFrames.context()
    _ = store.begin(context)
    let sink = CameraCopySink(poses: store.poses,
      makeDetector: { ControlledPoseDetector(shouldFail: true) })
    do {
      let buffer = try CameraTestFrames.buffer()
      try CameraTestFrames.fill(buffer, 42)
      _ = try CameraTestFrames.offer(buffer, store: store, context: context)
      let lease = try CameraTestFrames.lease(store, context)
      await #expect(throws: CameraPoseError.invalidResult) { try await sink.consume(lease.frame) }
      #expect(store.poses.snapshot.statistics.failures == 1)
      #expect(store.poses.snapshot.latest == nil)
      store.complete(lease)
      store.end(context)
    }
    await sink.reset()
    #expect(store.usage.bytes == 0)
  }
}
