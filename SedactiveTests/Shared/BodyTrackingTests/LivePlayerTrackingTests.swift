import Dispatch
import CoreVideo
import Foundation
import Synchronization
import Testing
import UIKit
@testable import Sedactive

nonisolated final class TrackingIntegrationClock: Sendable {
  private let value = Mutex(0.0)
  var time: Double {
    get { value.withLock { $0 } }
    set { value.withLock { $0 = newValue } }
  }
}
nonisolated struct TrackingIntegrationFixture {
  let clock: TrackingIntegrationClock
  let gate: CameraTrackingGate
  var engine: MotionEngine
  let context: CameraSourceContext
  init() throws {
    let clock = TrackingIntegrationClock()
    self.clock = clock
    gate = CameraTrackingGate(automaticDeadlines: false, now: { clock.time })
    engine = try MotionEngine(policy: B2bExperimentalPolicyV1.value)
    context = CameraSourceContext(generation: UUID(), epoch: UUID(), geometryRevision: 1)
    gate.begin(context, wake: AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1)).continuation)
  }
  func result(_ id: UInt64, _ time: Double, _ candidates: [PoseCandidate] = TrackingFixtures.pair,
    context replacement: CameraSourceContext? = nil, rotation: Double = 180,
    count: Int? = nil) throws -> CameraPoseResult {
    let c = replacement ?? context
    let metadata = CameraFrameMetadata(context: c, frameID: id, capturedAt: time,
      descriptor: try CameraFrameDescriptor(width: 1280, height: 720, bytesPerRow: 5120,
        pixelFormat: kCVPixelFormatType_32BGRA, maximumBytes: 4 * 1024 * 1024),
      rotationAngle: rotation, mirrored: false)
    let frame = PoseFrame(sessionGeneration: c.generation, frameID: id, capturedAt: time,
      cameraGeometryRevision: c.geometryRevision, imageWidth: 1280, imageHeight: 720,
      candidates: candidates)
    return .init(source: metadata, frame: frame, observationCount: count ?? candidates.count,
      invalidJointCount: 0)
  }
  mutating func synchronize() {
    let gate = self.gate
    gate.synchronize { control in
      var staged = engine
      let output = try staged.synchronize(control)
      engine = staged
      return output
    }
  }
  @discardableResult mutating func finish(_ result: CameraPoseResult,
    stamp original: CameraTrackingAdmission? = nil, age: Double = 0) throws -> Bool {
    clock.time = result.source.capturedAt + age
    synchronize()
    let stamp = try #require(original ?? gate.admit(result.source))
    let staged = try engine.staged(result, admission: stamp)
    let gate = self.gate
    return gate.finish(staged, admission: stamp, source: result.source,
      mutualCoreCount: 4) { engine = staged }
  }
  mutating func bind() throws {
    _ = try gate.arm(request: gate.makeBindingRequest())
    try #require(try finish(result(1, 0)))
    try #require(try finish(result(2, 0.125)))
    #expect(gate.snapshot.latest?.player1.state == .tracking)
    #expect(gate.snapshot.latest?.player2.state == .tracking)
  }
}

nonisolated struct LivePlayerTrackingTests {
  @Test func approvedPolicyIsExplicitAndExact() throws {
    let p = B2bExperimentalPolicyV1.value
    try p.validate()
    #expect(p == TrackingFixtures.policy())
    #expect(B2bExperimentalPolicyV1.version == "B2bExperimentalPolicyV1")
    #expect(p.minimumSharedCoreJoints == 3 && p.freshness == 0.5)
  }
  @Test func invalidPolicyFailsClosed() {
    let gate = CameraTrackingGate(policy: TrackingFixtures.policy(freshness: .nan),
      automaticDeadlines: false)
    gate.begin(CameraTestFrames.context(),
      wake: AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1)).continuation)
    #expect(throws: PlayerTrackingError.invalidPolicy) { try gate.arm(request: gate.makeBindingRequest()) }
    #expect(gate.snapshot.latest == nil)
  }
  @Test func cameraActivationDoesNotArm() throws {
    let f = try TrackingIntegrationFixture()
    let admission = try #require(f.gate.admit(f.result(1, 0).source))
    #expect(admission.requestID == nil)
    #expect(f.gate.snapshot.acknowledgment == nil && f.gate.snapshot.latest == nil)
  }
  @Test func explicitPairBindingPreservesSourceAndAcknowledgesOnce() throws {
    var f = try TrackingIntegrationFixture()
    try f.bind()
    let ack = try #require(f.gate.snapshot.acknowledgment)
    #expect(ack.source.context.generation == f.context.generation)
    #expect(ack.source.context.epoch == f.context.epoch)
    #expect(ack.source.context.rotationAngle == 180 && !ack.source.context.mirrored)
    #expect(ack.source.context.imageWidth == 1280 && ack.source.context.imageHeight == 720)
    #expect(ack.source.context.geometryRevision == 1)
    #expect(ack.source.frameID == 2 && ack.source.capturedAt == 0.125)
    #expect(ack.player1.candidateID == 10 && ack.player2.candidateID == 20)
    try #require(try f.finish(f.result(3, 0.25, TrackingFixtures.pair.reversed())))
    #expect(f.gate.snapshot.acknowledgments == 1)
    #expect(f.gate.snapshot.latest?.player1.candidateID == 10)
  }
  @Test func duplicateActiveRequestDoesNotRestartDwell() throws {
    var f = try TrackingIntegrationFixture()
    let id = try f.gate.makeBindingRequest()
    let rev = try f.gate.arm(request: id)
    try f.finish(f.result(1, 0))
    #expect(try f.gate.arm(request: id) == rev)
    try f.finish(f.result(2, 0.125))
    #expect(f.gate.snapshot.acknowledgments == 1)
  }
  @Test(arguments: [false, true])
  func cancelOrSupersedeRejectsAlreadyStagedFrame(_ supersede: Bool) throws {
    var f = try TrackingIntegrationFixture()
    _ = try f.gate.arm(request: f.gate.makeBindingRequest())
    try f.finish(f.result(1, 0))
    let next = try f.result(2, 0.125)
    let stamp = try #require(f.gate.admit(next.source))
    let staged = try f.engine.staged(next, admission: stamp)
    let before = f.engine.tracker.snapshot
    if supersede { _ = try f.gate.arm(request: f.gate.makeBindingRequest()) } else { f.gate.revoke() }
    f.clock.time = 0.125
    var didCommit = false
    #expect(!f.gate.finish(staged, admission: stamp, source: next.source,
      mutualCoreCount: 4) { didCommit = true })
    #expect(!didCommit && f.engine.tracker.snapshot == before)
    #expect(f.gate.snapshot.acknowledgment == nil && f.gate.snapshot.latest == nil)
  }
  @Test func admittedFrameCannotBorrowLaterAuthorization() throws {
    var f = try TrackingIntegrationFixture()
    let old = try f.result(1, 0)
    let stamp = try #require(f.gate.admit(old.source))
    _ = try f.gate.arm(request: f.gate.makeBindingRequest())
    #expect(stamp.requestID == nil)
    #expect(throws: PlayerTrackingError.staleControl) {
      try f.engine.staged(old, admission: stamp)
    }
    try f.finish(f.result(2, 0.125))
    #expect(f.gate.snapshot.latest?.player1.state == .unbound)
    #expect(f.gate.snapshot.acknowledgment == nil)
  }
  @Test func revocationAfterCommitClearsImmediatelyAndPreservesGuard() throws {
    var f = try TrackingIntegrationFixture()
    try f.bind()
    f.gate.revoke()
    #expect(f.gate.snapshot.latest == nil && f.gate.snapshot.acknowledgment == nil)
    f.synchronize()
    #expect(f.engine.tracker.snapshot.player1.state == .unbound)
    #expect(throws: PlayerTrackingError.bindingRequiresNewGeneration) {
      try f.gate.arm(request: f.gate.makeBindingRequest())
    }
  }
  @Test(arguments: [false, true])
  func sourceLossWithoutFrameAndNativeResumeRemainDisarmed(_ ended: Bool) throws {
    var f = try TrackingIntegrationFixture()
    try f.bind()
    let rev = f.gate.snapshot.revision
    f.gate.invalidate(f.context, ended: ended)
    #expect(f.gate.snapshot.revision == rev + 1)
    #expect(f.gate.snapshot.latest == nil)
    f.gate.resume(f.context)
    #expect(f.gate.snapshot.revision == rev + 1 && f.gate.snapshot.requestID == nil)
    if !ended {
      #expect(throws: PlayerTrackingError.bindingRequiresNewGeneration) {
        try f.gate.arm(request: f.gate.makeBindingRequest())
      }
    }
  }
  @Test func realNewSourceContextAllowsPairRebindWithoutReplacingCore() throws {
    var f = try TrackingIntegrationFixture()
    try f.bind()
    f.gate.invalidate(f.context, ended: true)
    f.synchronize()
    let next = CameraTestFrames.context(2)
    f.gate.begin(next, wake: AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1)).continuation)
    _ = try f.gate.arm(request: f.gate.makeBindingRequest())
    try f.finish(f.result(1, 1, context: next))
    try f.finish(f.result(2, 1.125, context: next))
    #expect(f.gate.snapshot.acknowledgment?.source.context.generation == next.generation)
    #expect(f.gate.snapshot.acknowledgments == 2)
  }
  @Test(arguments: [0.499, 0.5, 0.75])
  func approvedFinalCommitAgeBoundary(_ age: Double) throws {
    var f = try TrackingIntegrationFixture()
    _ = try f.gate.arm(request: f.gate.makeBindingRequest())
    let before = f.engine.tracker.snapshot
    let accepted = try f.finish(f.result(1, 0), age: age)
    #expect(accepted == (age < 0.5))
    if !accepted {
      #expect(f.engine.tracker.snapshot == before)
      #expect(f.gate.snapshot.staleRejected == 1)
    } else { #expect(f.gate.snapshot.captureToCommitAge == age) }
    #expect(f.gate.snapshot.acknowledgment == nil)
  }
  @Test func expiryDuringSlowEvaluationRefusesSameFrameHistoryCommit() throws {
    var f = try TrackingIntegrationFixture()
    try f.bind()
    let result = try f.result(3, 0.25)
    let stamp = try #require(f.gate.admit(result.source))
    let staged = try f.engine.staged(result, admission: stamp)
    let before = f.engine.tracker.snapshot
    f.clock.time = 0.625
    f.gate.expireDue(at: 0.625)
    #expect(f.gate.snapshot.latest == nil)
    let gate = f.gate
    #expect(!gate.finish(staged, admission: stamp, source: result.source,
      mutualCoreCount: 4) { f.engine = staged })
    #expect(f.engine.tracker.snapshot == before)
    f.synchronize()
    #expect(f.engine.tracker.snapshot.evaluatedAt == 0.625)
    #expect(f.engine.tracker.snapshot.player1.lastConfirmedAt == 0.125)
    #expect(f.engine.tracker.snapshot.player1.state == .uncertain)
    #expect(f.gate.snapshot.expiries == 1)
  }
  @Test func delayedTimerCallbackCannotBypassExpiryAtFinalCommit() throws {
    var f = try TrackingIntegrationFixture()
    try f.bind()
    let result = try f.result(3, 0.5)
    let admission = try #require(f.gate.admit(result.source))
    let staged = try f.engine.staged(result, admission: admission)
    let before = f.engine.tracker.snapshot
    f.clock.time = 0.65 // Result age is only 0.15s, but old confirmation expired at 0.625s.
    var committed = false
    #expect(!f.gate.finish(staged, admission: admission, source: result.source,
      mutualCoreCount: 4) { committed = true })
    #expect(!committed && f.engine.tracker.snapshot == before)
    #expect(f.gate.snapshot.watermark == 0.65 && f.gate.snapshot.latest == nil)
  }
  @Test func capturesOlderThanAppliedExpiryCannotAppearFresh() throws {
    var f = try TrackingIntegrationFixture()
    try f.bind()
    f.clock.time = 0.625
    f.gate.expireDue(at: 0.625)
    f.synchronize()
    let before = f.engine.tracker.snapshot
    #expect(throws: PlayerTrackingError.staleFrame) {
      try f.finish(f.result(3, 0.5))
    }
    #expect(f.engine.tracker.snapshot == before)
  }
  @Test func ordinaryExpiryRecoversOnlyThroughOriginalDwell() throws {
    var f = try TrackingIntegrationFixture()
    try f.bind()
    f.clock.time = 0.625
    f.gate.expireDue(at: 0.625)
    f.synchronize()
    try f.finish(f.result(3, 0.75))
    #expect(f.gate.snapshot.latest?.player1.state == .uncertain)
    try f.finish(f.result(4, 0.875))
    #expect(f.gate.snapshot.latest?.player1.state == .tracking)
    #expect(f.gate.snapshot.acknowledgments == 1)
  }
  @Test func noFrameRecoveryWindowEventuallyBecomesLost() throws {
    var f = try TrackingIntegrationFixture()
    try f.bind()
    f.clock.time = 0.625; f.gate.expireDue(at: 0.625); f.synchronize()
    f.clock.time = 2.125; f.gate.expireDue(at: 2.125); f.synchronize()
    #expect(f.gate.snapshot.latest?.player1.state == .lost)
    #expect(f.gate.snapshot.latest?.player1.requiresRebind == true)
    #expect(f.engine.tracker.snapshot.player1.lastConfirmedAt == 0.125)
  }
  @Test(arguments: [0, 1, 2])
  func contextMismatchCannotCommit(_ component: Int) throws {
    var f = try TrackingIntegrationFixture()
    try f.bind()
    let other = CameraSourceContext(generation: component == 0 ? UUID() : f.context.generation,
      epoch: component == 1 ? UUID() : f.context.epoch,
      geometryRevision: component == 2 ? 2 : f.context.geometryRevision)
    let result = try f.result(3, 0.25, context: other)
    #expect(f.gate.admit(result.source) == nil)
    let stamp = try #require(f.gate.admit(f.result(3, 0.25).source))
    #expect(throws: PlayerTrackingError.staleControl) {
      try f.engine.staged(result, admission: stamp)
    }
  }
  @Test(arguments: [false, true])
  func duplicateAndOutOfOrderSourcesFreezeHistory(_ duplicate: Bool) throws {
    var f = try TrackingIntegrationFixture()
    try f.bind()
    let before = f.engine.tracker.snapshot
    let result = try f.result(duplicate ? 2 : 1, duplicate ? 0.125 : 0.1)
    #expect(throws: PlayerTrackingError.staleFrame) { try f.finish(result) }
    #expect(f.engine.tracker.snapshot == before)
  }
  @Test(arguments: [false, true])
  func optionAComparablePartialsAndUnavailableComplementaryPair(_ comparable: Bool) throws {
    var f = try TrackingIntegrationFixture()
    try f.bind()
    let candidates = [TrackingFixtures.candidate(30, x: 0.75, missing: [.leftHip]),
      TrackingFixtures.candidate(40, x: 0.25, missing: [comparable ? .leftHip : .rightHip])]
    try f.finish(f.result(3, 0.25, candidates))
    let output = try #require(f.gate.snapshot.latest)
    if comparable {
      #expect(output.player1.state == .tracking && output.player2.state == .tracking)
    } else {
      #expect(output.player1.state != .tracking && output.player2.state != .tracking)
      #expect(output.player1.lastConfirmedAt == 0.125 && output.player2.lastConfirmedAt == 0.125)
      #expect(!output.player1.requiresRebind && !output.player2.requiresRebind)
    }
  }
  @Test func independentHealthyPeerCanContinueDuringDuplicateAmbiguity() throws {
    var f = try TrackingIntegrationFixture()
    try f.bind()
    try f.finish(f.result(3, 0.25, [TrackingFixtures.candidate(30, x: 0.75),
      TrackingFixtures.candidate(40, x: 0.751), TrackingFixtures.candidate(90, x: 0.25)]))
    let output = try #require(f.gate.snapshot.latest)
    #expect(output.player1.state != .tracking && output.player1.lastConfirmedAt == 0.125)
    #expect(output.player2.state == .tracking && output.player2.lastConfirmedAt == 0.25)
    #expect(output.player1.requiresRebind)
  }
  @Test func ambiguousCrossingCannotConfirmByArrayOrder() throws {
    var f = try TrackingIntegrationFixture()
    try f.bind()
    // A source interval permits both plausible identity hypotheses; equal current bodies overlap.
    try f.finish(f.result(3, 0.5, [TrackingFixtures.candidate(30, x: 0.5),
      TrackingFixtures.candidate(40, x: 0.5)]))
    let output = try #require(f.gate.snapshot.latest)
    #expect(output.player1.state != .tracking && output.player2.state != .tracking)
    #expect(output.player1.lastConfirmedAt == 0.125 && output.player2.lastConfirmedAt == 0.125)
  }
  @Test func actualFrameStoreAdmissionStampSurvivesPendingControlCutover() throws {
    let store = FrameStore()
    let context = CameraTestFrames.context()
    _ = store.begin(context)
    let buffer = try CameraTestFrames.buffer()
    _ = try CameraTestFrames.offer(buffer, store: store, context: context)
    let first = try CameraTestFrames.lease(store, context)
    let old = first.frame.trackingAdmission
    _ = try store.tracking.arm(request: store.tracking.makeBindingRequest())
    #expect(old.requestID == nil)
    store.complete(first)
    _ = try CameraTestFrames.offer(buffer, store: store, context: context)
    let pending = try CameraTestFrames.lease(store, context)
    let stamp = pending.frame.trackingAdmission
    store.tracking.revoke()
    #expect(stamp.requestID != nil && stamp.revision < store.tracking.snapshot.revision)
    store.complete(pending); store.end(context)
  }
  @Test(arguments: [false, true])
  func previewDoesNotChangeAdmissionOrOwnershipTopology(_ enabled: Bool) throws {
    let store = FrameStore()
    let context = CameraTestFrames.context()
    _ = store.begin(context)
    store.preview.setEnabled(enabled)
    _ = try store.tracking.arm(request: store.tracking.makeBindingRequest())
    let buffer = try CameraTestFrames.buffer()
    _ = try CameraTestFrames.offer(buffer, store: store, context: context)
    var lease: CameraProcessingLease? = try CameraTestFrames.lease(store, context)
    #expect(lease?.frame.trackingAdmission.requestID != nil)
    #expect(throws: CameraFrameError.processingBusy) { try store.acquire(context) }
    #expect(store.usage.frames == 1)
    store.complete(try #require(lease)); lease = nil
    store.end(context)
    #expect(store.usage.bytes == 0)
    #expect(store.usage.peakFrames <= 3 && store.usage.peakBytes <= 12 * 1024 * 1024)
  }
}

@MainActor struct LiveTrackingCameraLifecycleTests {
  @Test func facadeFullRebindActuallyRestartsNativeDriver() async throws {
    let driver = ControlledCameraDriver()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized), driver: driver)
    try await camera.start(generation: UUID())
    let original = try #require(camera.state.context)
    let request = try camera.makeBindingRequest()
    let revision = try camera.armBinding(request: request)
    #expect(try camera.armBinding(request: request) == revision)
    try await camera.requestFullRebind(request: camera.makeBindingRequest())
    let replacement = try #require(camera.state.context)
    #expect(replacement.generation != original.generation && replacement.epoch != original.epoch)
    #expect(await driver.starts == 2)
    #expect(await driver.stops == 1)
    #expect(camera.frames.tracking.snapshot.requestID != nil)
    await camera.stop()
    #expect(camera.frames.tracking.snapshot.latest == nil)
    #expect(camera.frames.tracking.snapshot.requestID == nil)
  }
  @Test func canceledRebindRetainsSingleOperationUntilWorkerCleanupExits() async throws {
    let driver = ControlledCameraDriver()
    let sink = ControlledCameraSink()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized),
      driver: driver, sink: sink)
    try await camera.start(generation: UUID())
    let context = try #require(camera.state.context)
    let buffer = try CameraTestFrames.buffer()
    _ = try CameraTestFrames.offer(buffer, store: camera.frames, context: context)
    await sink.untilEntered()
    let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    _ = try camera.observe { state in
      if state.status == .stopped { pair.continuation.yield(()) }
    }
    let rebinding = Task { try await camera.requestFullRebind(request: camera.makeBindingRequest()) }
    var stopped = pair.stream.makeAsyncIterator()
    _ = await stopped.next()
    camera.cancelBinding()
    await #expect(throws: CameraFailure.operationConflict) {
      try await camera.requestFullRebind(request: camera.makeBindingRequest())
    }
    #expect(camera.frames.tracking.snapshot.requestID == nil)
    #expect(await driver.starts == 1)
    await sink.release()
    await #expect(throws: CancellationError.self) { try await rebinding.value }
    await camera.stop()
    #expect(camera.frames.usage.frames == 0)
  }
  @Test func backgroundNotificationRevokesWithoutDiagnosticsObserver() async throws {
    let store = FrameStore()
    let context = CameraTestFrames.context()
    _ = store.begin(context)
    let center = NotificationCenter()
    let channel = CameraEventChannel(context: context, frames: store, notificationCenter: center)
    _ = try store.tracking.arm(request: store.tracking.makeBindingRequest())
    let revision = store.tracking.snapshot.revision
    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    #expect(store.tracking.snapshot.requestID == nil)
    #expect(store.tracking.snapshot.revision > revision)
    channel.finish()
    store.end(context)
  }
}

nonisolated final class VisionIntegrationHold: Sendable {
  let entered: AsyncStream<Void>
  private let signal: AsyncStream<Void>.Continuation
  // Test-only rendezvous for a blocking synchronous SDK seam; never production scheduling.
  private let releaseSignal = DispatchSemaphore(value: 0)
  init() {
    let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    entered = pair.stream; signal = pair.continuation
  }
  func block() { signal.yield(()); releaseSignal.wait() }
  func release() { releaseSignal.signal() }
}
nonisolated final class IntegrationPoseDetector: CameraPoseDetecting {
  private let hold: VisionIntegrationHold?
  private let observations: CameraPoseObservations
  private var calls = 0
  init(observations: CameraPoseObservations, hold: VisionIntegrationHold?) {
    self.observations = observations; self.hold = hold
  }
  func detect(in buffer: CVPixelBuffer) -> CameraPoseObservations {
    calls += 1
    if calls == 3 { hold?.block() }
    return observations
  }
}
nonisolated struct LiveTrackingWorkerTests {
  private func offer(_ store: FrameStore, context: CameraSourceContext, at time: Double)
    throws -> CameraProcessingLease {
    let buffer = try CameraTestFrames.buffer()
    let base = try CameraTestFrames.metadata(buffer, store: store, context: context)
    let source = CameraFrameMetadata(context: context, frameID: base.frameID, capturedAt: time,
      descriptor: base.descriptor, rotationAngle: 180, mirrored: false)
    try store.copy(buffer, metadata: source)
    return try #require(try store.acquire(context))
  }
  @Test(arguments: [false, true])
  func realSinkUsesOneInferenceAndExactSource(_ preview: Bool) async throws {
    let clock = TrackingIntegrationClock()
    let gate = CameraTrackingGate(automaticDeadlines: false, now: { clock.time })
    let store = FrameStore(tracking: gate)
    let context = CameraTestFrames.context()
    _ = store.begin(context)
    store.preview.setEnabled(preview)
    _ = try gate.arm(request: gate.makeBindingRequest())
    let observations = CameraPoseObservations(totalCount: 2,
      joints: TrackingFixtures.pair.map(\.joints))
    let sink = CameraCopySink(metrics: store.metrics, poses: store.poses, tracking: gate,
      makeDetector: { IntegrationPoseDetector(observations: observations, hold: nil) })
    for time in [0.0, 0.125] {
      clock.time = time
      let lease = try offer(store, context: context, at: time)
      try await sink.consume(lease.frame)
      store.complete(lease)
    }
    let raw = try #require(store.poses.snapshot.latest)
    let result = try #require(gate.snapshot.latest)
    #expect(result.source?.frameID == raw.source.frameID)
    #expect(result.source?.capturedAt == raw.source.capturedAt)
    #expect(result.source?.context.epoch == raw.source.context.epoch)
    #expect(result.player1.candidateID == 0 && result.player2.candidateID == 1)
    #expect(store.poses.snapshot.statistics.completed == 2)
    #expect(gate.snapshot.accepted == 2 && gate.snapshot.acknowledgments == 1)
    store.end(context)
    await sink.reset()
    #expect(store.metrics.snapshot.workspaceBytes == 0 && store.usage.bytes == 0)
  }
  @Test(.timeLimit(.minutes(1)))
  func lifecycleTimerWakesWorkerWithoutViewPollingOrAnotherFrame() async throws {
    let gate = CameraTrackingGate()
    let context = CameraTestFrames.context()
    let wake = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    gate.begin(context, wake: wake.continuation)
    _ = try gate.arm(request: gate.makeBindingRequest())
    var iterator = wake.stream.makeAsyncIterator()
    _ = await iterator.next() // consume explicit-arm wake; next wake must be the owned timer
    var engine = try MotionEngine(policy: B2bExperimentalPolicyV1.value)
    let time = CameraHostClock.now()
    for (id, capturedAt) in [(UInt64(1), time - 0.125), (UInt64(2), time)] {
      let source = CameraFrameMetadata(context: context, frameID: id, capturedAt: capturedAt,
        descriptor: try CameraFrameDescriptor(width: 1280, height: 720, bytesPerRow: 5120,
          pixelFormat: kCVPixelFormatType_32BGRA, maximumBytes: 4 * 1024 * 1024),
        rotationAngle: 180, mirrored: false)
      let pose = PoseFrame(sessionGeneration: context.generation, frameID: id,
        capturedAt: capturedAt, cameraGeometryRevision: context.geometryRevision,
        imageWidth: 1280, imageHeight: 720, candidates: TrackingFixtures.pair)
      let result = CameraPoseResult(source: source, frame: pose, observationCount: 2,
        invalidJointCount: 0)
      let stamp = try #require(gate.admit(source))
      let staged = try engine.staged(result, admission: stamp)
      try #require(gate.finish(staged, admission: stamp, source: source,
        mutualCoreCount: 4) { engine = staged })
    }
    try #require(gate.snapshot.latest?.player1.state == .tracking)
    _ = await iterator.next() // deadline-driven, no sleeps, fake frames, UI refresh or manual expiry
    #expect(gate.snapshot.expiries == 1)
    #expect(gate.snapshot.latest == nil)
    #expect(engine.tracker.snapshot.player1.lastConfirmedAt == time) // worker not applied yet
    gate.invalidate(context, ended: true)
    wake.continuation.finish()
  }
  @Test(arguments: ["cancel", "stop", "interruption", "expiry"])
  func blockedVisionDoesNotBlockRevocationOrExpiry(_ reason: String) async throws {
    let clock = TrackingIntegrationClock()
    let gate = CameraTrackingGate(automaticDeadlines: false, now: { clock.time })
    let store = FrameStore(tracking: gate)
    let context = CameraTestFrames.context()
    _ = store.begin(context)
    _ = try gate.arm(request: gate.makeBindingRequest())
    let hold = VisionIntegrationHold()
    defer { hold.release() }
    let observations = CameraPoseObservations(totalCount: 2,
      joints: TrackingFixtures.pair.map(\.joints))
    let sink = CameraCopySink(metrics: store.metrics, poses: store.poses, tracking: gate,
      makeDetector: { IntegrationPoseDetector(observations: observations, hold: hold) })
    for time in [0.0, 0.125] {
      clock.time = time
      let lease = try offer(store, context: context, at: time)
      try await sink.consume(lease.frame)
      store.complete(lease)
    }
    try #require(gate.snapshot.latest?.player1.state == .tracking)
    clock.time = 0.25
    var lease: CameraProcessingLease? = try offer(store, context: context, at: 0.25)
    var job: Task<Void, Error>? = Task { [frame = try #require(lease).frame] in
      try await sink.consume(frame)
    }
    var entered = hold.entered.makeAsyncIterator()
    _ = await entered.next()
    switch reason {
    case "cancel": gate.revoke()
    case "stop": store.end(context)
    case "interruption": store.suspend(context)
    default: clock.time = 0.625; gate.expireDue(at: 0.625)
    }
    #expect(gate.snapshot.latest == nil) // synchronous even though the real sink actor is blocked
    #expect(gate.snapshot.accepted == 2)
    #expect(store.usage.frames == 1) // in-use raw ownership is never reclaimed early
    hold.release()
    try await job?.value
    job = nil
    store.complete(try #require(lease)); lease = nil
    await sink.updateTracking()
    #expect(gate.snapshot.accepted == 2) // old inference never confirmed frame 3
    if reason == "expiry" {
      #expect(gate.snapshot.latest?.player1.lastConfirmedAt == 0.125)
      #expect(gate.snapshot.latest?.player1.state == .uncertain)
    } else { #expect(gate.snapshot.latest == nil) }
    store.end(context); await sink.reset()
    #expect(store.usage.bytes == 0 && store.metrics.snapshot.workspaceBytes == 0)
  }
}

actor A4TrackingSink: CameraFrameSink {
  private var downstream: CameraCopySink?
  private var completed = 0
  private var waiter: (Int, CheckedContinuation<Void, Never>)?
  func configure(_ store: FrameStore) {
    let observations = CameraPoseObservations(totalCount: 2,
      joints: TrackingFixtures.pair.map(\.joints))
    downstream = CameraCopySink(metrics: store.metrics, poses: store.poses,
      tracking: store.tracking,
      makeDetector: { IntegrationPoseDetector(observations: observations, hold: nil) })
  }
  func consume(_ frame: CameraSourceFrame) async throws {
    try await downstream!.consume(frame)
    completed += 1
    if let waiter, completed >= waiter.0 { self.waiter = nil; waiter.1.resume() }
  }
  func updateTracking() async { await downstream?.updateTracking() }
  func reset() async { await downstream?.reset() }
  func untilProcessed(_ count: Int) async {
    if completed >= count { return }
    await withCheckedContinuation { waiter = (count, $0) }
  }
}


actor A4PermissionBoundary: CameraPermissionChecking {
  private var calls = 0
  private var held: CheckedContinuation<Void, Never>?
  private var entered: CheckedContinuation<Void, Never>?
  func status() async -> CameraPermission {
    calls += 1
    if calls == 2 {
      await withCheckedContinuation {
        held = $0; entered?.resume(); entered = nil
      }
    }
    return .authorized
  }
  func request() -> Bool { true }
  func untilHeld() async {
    if held != nil { return }
    await withCheckedContinuation { entered = $0 }
  }
  func release() { held?.resume(); held = nil }
}
actor A4ReturnBoundaryDriver: CameraDriving {
  private(set) var starts = 0
  let center: NotificationCenter
  init(center: NotificationCenter) { self.center = center }
  func start(configuration: CameraCaptureConfiguration, context: CameraSourceContext,
    frames: FrameStore, events: CameraEventChannel) -> CameraNegotiatedConfiguration {
    starts += 1
    if starts == 2 {
      center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
      center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    return .init(deviceID: "fixture", deviceName: "fixture", deviceType: "fixture",
      nativeWidth: 1280, nativeHeight: 720, outputWidth: 1280, outputHeight: 720,
      framesPerSecond: 30, rotationAngle: 180, mirrored: false, centerStageActive: false,
      stabilizationEnabled: false, sessionPreset: "fixture")
  }
  func stop(context: CameraSourceContext) {}
  func resume(context: CameraSourceContext) -> CameraSourceReadiness { .running }
}

@Suite(.serialized) @MainActor struct LiveTrackingLifecycleCorrectionTests {
  private func publishPair(_ camera: CameraPipeline, _ sink: A4TrackingSink) async throws {
    let c = try #require(camera.state.context)
    let buffer = try CameraTestFrames.buffer()
    let time = CameraHostClock.now()
    for (count, capturedAt) in [(1, time - 0.125), (2, time)] {
      let source = CameraFrameMetadata(context: c,
        frameID: try camera.frames.nextIdentity(c), capturedAt: capturedAt,
        descriptor: try CameraFrameDescriptor(width: 8, height: 8,
          bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
          pixelFormat: kCVPixelFormatType_32BGRA, maximumBytes: camera.frames.maximumFrameBytes),
        rotationAngle: 180, mirrored: false)
      try camera.frames.copy(buffer, metadata: source)
      await sink.untilProcessed(count)
    }
    try #require(camera.frames.tracking.snapshot.acknowledgment != nil)
  }
  @Test func backgroundDuringCleanupCannotRestartOrArmOldRequest() async throws {
    let center = NotificationCenter()
    let driver = ControlledCameraDriver()
    let sink = ControlledCameraSink()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized),
      driver: driver, sink: sink, notificationCenter: center)
    try await camera.start(generation: UUID())
    let context = try #require(camera.state.context)
    let buffer = try CameraTestFrames.buffer()
    _ = try CameraTestFrames.offer(buffer, store: camera.frames, context: context)
    await sink.untilEntered()
    let stopped = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    _ = try camera.observe { if $0.status == .stopped { stopped.continuation.yield(()) } }
    let request = try camera.makeBindingRequest()
    let restarting = Task { try await camera.requestFullRebind(request: request) }
    var iterator = stopped.stream.makeAsyncIterator()
    _ = await iterator.next()
    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    await sink.release()
    switch await restarting.result {
    case .success: Issue.record("Pre-background rebind completed without fresh authorization")
    case .failure: break
    }
    #expect(await driver.starts == 1)
    #expect(camera.state.context == nil)
    #expect(camera.frames.tracking.snapshot.requestID == nil)
    #expect(camera.frames.tracking.snapshot.acknowledgment == nil)
    try await camera.requestFullRebind(request: camera.makeBindingRequest())
    #expect(await driver.starts == 2)
    #expect(camera.frames.tracking.snapshot.requestID != nil)
    await camera.stop()
  }
  @Test func completedFullRebindDuplicatePreservesSourceDwellAndAcknowledgment() async throws {
    let center = NotificationCenter()
    let driver = ControlledCameraDriver()
    let sink = A4TrackingSink()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized),
      driver: driver, sink: sink, notificationCenter: center)
    await sink.configure(camera.frames)
    try await camera.start(generation: UUID())
    let request = try camera.makeBindingRequest()
    try await camera.requestFullRebind(request: request)
    try await publishPair(camera, sink)
    let before = camera.frames.tracking.snapshot
    let source = camera.state.context
    let starts = await driver.starts, stops = await driver.stops
    let ack = try #require(before.acknowledgment)
    try await camera.requestFullRebind(request: request)
    let after = camera.frames.tracking.snapshot
    #expect(await driver.starts == starts)
    #expect(await driver.stops == stops)
    #expect(camera.state.context == source)
    #expect(after.revision == before.revision && after.requestID == request.requestID)
    #expect(after.acknowledgment?.source == ack.source)
    #expect(after.acknowledgments == before.acknowledgments)
    #expect(after.latest == before.latest)
    try await camera.requestFullRebind(request: camera.makeBindingRequest())
    #expect(camera.state.context?.generation != source?.generation)
    await camera.stop()
  }
  @Test func expiredCoverageIsExplicitlyHistoricalInDiagnostics() async throws {
    let sink = A4TrackingSink()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized),
      driver: ControlledCameraDriver(), sink: sink, notificationCenter: NotificationCenter())
    await sink.configure(camera.frames)
    try await camera.start(generation: UUID())
    _ = try camera.armBinding(request: camera.makeBindingRequest())
    try await publishPair(camera, sink)
    let bound = try #require(camera.frames.tracking.snapshot.latest)
    let time = try #require(bound.player1.lastConfirmedAt)
    camera.frames.tracking.expireDue(at: time + 0.5)
    let model = LiveInputDiagnosticsModel(camera: camera)
    await model.refresh()
    #expect(model.details.contains("Last accepted pair coverage"))
    #expect(!model.details.contains("Mutual current-candidate core coverage"))
    #expect(camera.frames.tracking.snapshot.latest?.player1.state != .tracking)
    await camera.stop()
  }
  private func backgroundAndForeground(_ center: NotificationCenter) {
    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
  }
  @Test func backgroundBeforeRestartTaskRunsRevokesReceipt() async throws {
    let center = NotificationCenter()
    let driver = ControlledCameraDriver()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized),
      driver: driver, notificationCenter: center)
    try await camera.start(generation: UUID())
    let original = camera.state.context
    let request = try camera.makeBindingRequest()
    let job = Task { try await camera.requestFullRebind(request: request) }
    backgroundAndForeground(center) // no actor yield: the restart task has not run
    await #expect(throws: PlayerTrackingError.staleControl) { try await job.value }
    #expect(await driver.starts == 1)
    #expect(camera.state.context == original)
    #expect(camera.frames.tracking.snapshot.requestID == nil)
    await camera.stop()
  }
  @Test func backgroundAfterCleanupDuringPermissionCannotStartReplacement() async throws {
    let center = NotificationCenter()
    let permission = A4PermissionBoundary()
    let driver = ControlledCameraDriver()
    let camera = CameraPipeline(permission: permission, driver: driver, notificationCenter: center)
    try await camera.start(generation: UUID())
    let request = try camera.makeBindingRequest()
    let job = Task { try await camera.requestFullRebind(request: request) }
    await permission.untilHeld() // cleanup finished; replacement driver.start has not been called
    backgroundAndForeground(center)
    await permission.release()
    await #expect(throws: CancellationError.self) { try await job.value }
    #expect(await driver.starts == 1)
    #expect(camera.state.context == nil)
    #expect(camera.frames.tracking.snapshot.requestID == nil)
    #expect(camera.frames.tracking.snapshot.acknowledgment == nil)
    let fresh = try camera.makeBindingRequest()
    try await camera.requestFullRebind(request: fresh)
    #expect(await driver.starts == 2)
    await camera.stop()
  }
  @Test func backgroundAtDriverReturnCannotAuthorizeCompletedRestart() async throws {
    let center = NotificationCenter()
    let driver = A4ReturnBoundaryDriver(center: center)
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized),
      driver: driver, notificationCenter: center)
    try await camera.start(generation: UUID())
    let request = try camera.makeBindingRequest()
    await #expect(throws: CancellationError.self) {
      try await camera.requestFullRebind(request: request)
    }
    #expect(await driver.starts == 2) // second start entered BEFORE the background notification
    #expect(camera.frames.tracking.snapshot.requestID == nil)
    #expect(camera.frames.tracking.snapshot.acknowledgment == nil)
    #expect(camera.state.context == nil)
    await camera.stop()
  }
  @Test(arguments: ["cancel", "supersede", "caller cancellation"])
  func staleCleanupCompletionCannotRevokeNewerRequest(_ change: String) async throws {
    let center = NotificationCenter()
    let driver = ControlledCameraDriver()
    let sink = ControlledCameraSink()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized),
      driver: driver, sink: sink, notificationCenter: center)
    try await camera.start(generation: UUID())
    let context = try #require(camera.state.context)
    let buffer = try CameraTestFrames.buffer()
    _ = try CameraTestFrames.offer(buffer, store: camera.frames, context: context)
    await sink.untilEntered()
    let stopped = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    _ = try camera.observe { if $0.status == .stopped { stopped.continuation.yield(()) } }
    let old = try camera.makeBindingRequest()
    let job = Task { try await camera.requestFullRebind(request: old) }
    var iterator = stopped.stream.makeAsyncIterator()
    _ = await iterator.next()
    if change == "cancel" { camera.cancelBinding() }
    if change == "caller cancellation" { job.cancel() }
    let newer = try camera.makeBindingRequest() // supersedes without growing an ID/task history
    await #expect(throws: CameraFailure.operationConflict) {
      try await camera.requestFullRebind(request: newer)
    }
    await sink.release()
    await #expect(throws: CancellationError.self) { try await job.value }
    try camera.frames.tracking.validateRequest(newer) // old completion did not poison this intent
    try await camera.requestFullRebind(request: newer)
    #expect(camera.frames.tracking.snapshot.requestID == newer.requestID)
    let count = await driver.starts
    await #expect(throws: PlayerTrackingError.staleControl) {
      try await camera.requestFullRebind(request: old)
    }
    #expect(throws: PlayerTrackingError.staleControl) { try camera.armBinding(request: old) }
    #expect(await driver.starts == count)
    await camera.stop()
    #expect(camera.frames.usage.bytes == 0)
  }
  @Test func pendingDuplicateSharesOneRestartTask() async throws {
    let center = NotificationCenter()
    let driver = ControlledCameraDriver()
    let sink = ControlledCameraSink()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized),
      driver: driver, sink: sink, notificationCenter: center)
    try await camera.start(generation: UUID())
    let context = try #require(camera.state.context)
    let buffer = try CameraTestFrames.buffer()
    _ = try CameraTestFrames.offer(buffer, store: camera.frames, context: context)
    await sink.untilEntered()
    let stopped = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    _ = try camera.observe { if $0.status == .stopped { stopped.continuation.yield(()) } }
    let request = try camera.makeBindingRequest()
    let first = Task { try await camera.requestFullRebind(request: request) }
    var iterator = stopped.stream.makeAsyncIterator(); _ = await iterator.next()
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let second = Task {
      entered.continuation.yield(())
      try await camera.requestFullRebind(request: request)
    }
    var duplicate = entered.stream.makeAsyncIterator(); _ = await duplicate.next()
    #expect(await driver.starts == 1)
    await sink.release()
    try await first.value
    let revision = camera.frames.tracking.snapshot.revision
    try await second.value
    #expect(await driver.starts == 2)
    #expect(camera.frames.tracking.snapshot.revision == revision)
    await camera.stop()
  }
  @Test func revokedReceiptCannotBeReplayedAfterLaterRequests() async throws {
    let center = NotificationCenter()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized),
      driver: ControlledCameraDriver(), notificationCenter: center)
    try await camera.start(generation: UUID())
    let old = try camera.makeBindingRequest()
    _ = try camera.armBinding(request: old)
    camera.cancelBinding()
    await #expect(throws: PlayerTrackingError.staleControl) {
      try await camera.requestFullRebind(request: old)
    }
    let fresh = try camera.makeBindingRequest()
    _ = try camera.armBinding(request: fresh)
    #expect(throws: PlayerTrackingError.staleControl) { try camera.armBinding(request: old) }
    #expect(camera.frames.tracking.snapshot.requestID == fresh.requestID)
    await camera.stop()
  }
  @Test func queuedDiagnosticsButtonIntentCannotBecomeFreshAfterBackground() async throws {
    let center = NotificationCenter()
    let driver = ControlledCameraDriver()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized),
      driver: driver, notificationCenter: center)
    try await camera.start(generation: UUID())
    let original = camera.state.context
    let model = LiveInputDiagnosticsModel(camera: camera)
    let task = try #require(model.rebindTracking())
    backgroundAndForeground(center) // before the queued button Task runs
    await task.value
    #expect(await driver.starts == 1)
    #expect(camera.state.context == original)
    #expect(camera.frames.tracking.snapshot.requestID == nil)
    #expect(camera.frames.tracking.snapshot.acknowledgment == nil)
    await camera.stop()
  }
  @Test func revokedRestartCannotAllocateSourceIdentity() throws {
    let gate = CameraTrackingGate(automaticDeadlines: false)
    let request = try gate.makeBindingRequest()
    try #require(try gate.prepareRestart(request))
    gate.revoke()
    var allocated = false
    #expect(throws: PlayerTrackingError.staleControl) {
      try gate.authorizeRestartSource(request) {
        allocated = true
        return CameraTestFrames.context()
      }
    }
    #expect(!allocated)
  }

}


actor A6ReturnLossDriver: CameraDriving {
  private(set) var starts = 0
  let failure: Bool
  init(failure: Bool) { self.failure = failure }
  func start(configuration: CameraCaptureConfiguration, context: CameraSourceContext,
    frames: FrameStore, events: CameraEventChannel) -> CameraNegotiatedConfiguration {
    starts += 1
    if starts == 2 { events.emit(failure ? .failure(.geometryChanged) : .interrupted(7)) }
    return .init(deviceID: "fixture", deviceName: "fixture", deviceType: "fixture",
      nativeWidth: 1280, nativeHeight: 720, outputWidth: 1280, outputHeight: 720,
      framesPerSecond: 30, rotationAngle: 180, mirrored: false, centerStageActive: false,
      stabilizationEnabled: false, sessionPreset: "fixture")
  }
  func stop(context: CameraSourceContext) {}
  func resume(context: CameraSourceContext) -> CameraSourceReadiness { .running }
}
actor A6SecondPermissionDenied: CameraPermissionChecking {
  private var calls = 0
  func status() -> CameraPermission { calls += 1; return calls == 1 ? .authorized : .denied }
  func request() -> Bool { false }
}
actor A6FailureTeardownDriver: CameraDriving {
  private(set) var starts = 0
  private var stops = 0
  private var held: CheckedContinuation<Void, Never>?
  private var entered: CheckedContinuation<Void, Never>?
  func start(configuration: CameraCaptureConfiguration, context: CameraSourceContext,
    frames: FrameStore, events: CameraEventChannel) -> CameraNegotiatedConfiguration {
    starts += 1
    return .init(deviceID: "fixture", deviceName: "fixture", deviceType: "fixture",
      nativeWidth: 1280, nativeHeight: 720, outputWidth: 1280, outputHeight: 720,
      framesPerSecond: 30, rotationAngle: 180, mirrored: false, centerStageActive: false,
      stabilizationEnabled: false, sessionPreset: "fixture")
  }
  func stop(context: CameraSourceContext) async {
    stops += 1
    if stops == 2 {
      await withCheckedContinuation { held = $0; entered?.resume(); entered = nil }
    }
  }
  func resume(context: CameraSourceContext) -> CameraSourceReadiness { .running }
  func untilFailedTeardown() async {
    if held != nil { return }
    await withCheckedContinuation { entered = $0 }
  }
  func release() { held?.resume(); held = nil }
}

@Suite(.serialized) @MainActor struct LiveTrackingNativeSourceLossTests {
  private func event(_ kind: String) -> CameraHardwareEvent {
    switch kind {
    case "interruption": .interrupted(7)
    case "stopped": .stopped
    default: .failure(.geometryChanged)
    }
  }
  @Test(arguments: ["interruption", "failure", "stopped"])
  func issuedReceiptCannotSurviveNativeLoss(_ kind: String) async throws {
    let driver = ControlledCameraDriver()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized),
      driver: driver, notificationCenter: NotificationCenter())
    try await camera.start(generation: UUID())
    let source = try #require(camera.state.context)
    let channel = try #require(await driver.events)
    let request = try camera.makeBindingRequest()
    let revision = camera.frames.tracking.snapshot.revision
    let queued = Task { try await camera.requestFullRebind(request: request) }
    channel.emit(event(kind)) // no MainActor yield: original intent has not been submitted
    #expect(camera.frames.tracking.snapshot.revision == revision + 1)
    #expect(throws: PlayerTrackingError.staleControl) {
      try camera.frames.tracking.validateRequest(request)
    }
    await #expect(throws: PlayerTrackingError.staleControl) { try await queued.value }
    #expect(await driver.starts == 1)
    #expect(camera.state.context == source)
    #expect(camera.frames.tracking.snapshot.requestID == nil)
    #expect(camera.frames.tracking.snapshot.acknowledgment == nil)
    #expect(camera.frames.tracking.snapshot.latest == nil)
    await camera.stop()
  }
  @Test(arguments: ["interruption", "failure"])
  func queuedDiagnosticsIntentCannotSurviveNativeLoss(_ kind: String) async throws {
    let driver = ControlledCameraDriver()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized),
      driver: driver, notificationCenter: NotificationCenter())
    try await camera.start(generation: UUID())
    let source = camera.state.context
    let channel = try #require(await driver.events)
    let model = LiveInputDiagnosticsModel(camera: camera)
    let queued = try #require(model.rebindTracking())
    let revision = camera.frames.tracking.snapshot.revision
    channel.emit(event(kind)) // real button-intent receipt, before the real queued Task runs
    #expect(camera.frames.tracking.snapshot.revision == revision + 1)
    await queued.value
    #expect(await driver.starts == 1)
    #expect(camera.state.context == source)
    #expect(camera.frames.tracking.snapshot.requestID == nil)
    #expect(camera.frames.tracking.snapshot.acknowledgment == nil)
    #expect(camera.frames.tracking.snapshot.latest == nil)
    await camera.stop()
  }
  @Test func unexpectedLossWhileRestartPreparedRevokesBeforeRetirement() async throws {
    let driver = ControlledCameraDriver()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized),
      driver: driver, notificationCenter: NotificationCenter())
    try await camera.start(generation: UUID())
    let source = try #require(camera.state.context)
    let channel = try #require(await driver.events)
    let request = try camera.makeBindingRequest()
    // Exercise the short restarting-before-retirement gate state without scheduler assumptions.
    try #require(try camera.frames.tracking.prepareRestart(request))
    let revision = camera.frames.tracking.snapshot.revision
    channel.emit(.failure(.geometryChanged))
    #expect(camera.frames.tracking.snapshot.revision == revision + 1)
    #expect(throws: PlayerTrackingError.staleControl) {
      try camera.frames.tracking.validateRestart(request)
    }
    var allocated = false
    #expect(throws: PlayerTrackingError.staleControl) {
      try camera.frames.tracking.authorizeRestartSource(request) { allocated = true; return source }
    }
    #expect(!allocated)
    #expect(await driver.starts == 1)
    #expect(camera.frames.tracking.snapshot.requestID == nil)
    await camera.stop()
  }
  @Test func intentionalRetirementAndLateOldEventsPreserveNewAcknowledgment() async throws {
    let driver = ControlledCameraDriver()
    let sink = A4TrackingSink()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized),
      driver: driver, sink: sink, notificationCenter: NotificationCenter())
    await sink.configure(camera.frames)
    try await camera.start(generation: UUID())
    let old = try #require(camera.state.context)
    let retiredChannel = try #require(await driver.events)
    let request = try camera.makeBindingRequest()
    let issuedRevision = camera.frames.tracking.snapshot.revision
    try await camera.requestFullRebind(request: request)
    let current = try #require(camera.state.context)
    #expect(current.generation != old.generation && current.epoch != old.epoch)
    // Intentional end, new begin and activation each advance once; no native-loss revocation.
    #expect(camera.frames.tracking.snapshot.revision == issuedRevision + 3)
    let buffer = try CameraTestFrames.buffer()
    let time = CameraHostClock.now()
    for (count, capturedAt) in [(1, time - 0.125), (2, time)] {
      let source = CameraFrameMetadata(context: current,
        frameID: try camera.frames.nextIdentity(current), capturedAt: capturedAt,
        descriptor: try CameraFrameDescriptor(width: 8, height: 8,
          bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
          pixelFormat: kCVPixelFormatType_32BGRA, maximumBytes: camera.frames.maximumFrameBytes),
        rotationAngle: 180, mirrored: false)
      try camera.frames.copy(buffer, metadata: source)
      await sink.untilProcessed(count)
    }
    let before = camera.frames.tracking.snapshot
    let acknowledgment = try #require(before.acknowledgment)
    let starts = await driver.starts, stops = await driver.stops
    retiredChannel.emit(.interrupted(7))
    retiredChannel.emit(.failure(.geometryChanged)) // actual closed source channel
    camera.frames.tracking.sourceLost(old) // also prove the exact-context gate defense
    let after = camera.frames.tracking.snapshot
    #expect(after.revision == before.revision && after.requestID == request.requestID)
    #expect(after.acknowledgment?.source == acknowledgment.source)
    #expect(after.acknowledgments == before.acknowledgments && after.latest == before.latest)
    #expect(after.invalidations == before.invalidations)
    #expect(camera.state.context == current)
    try camera.frames.tracking.validateRequest(request)
    try await camera.requestFullRebind(request: request) // completed duplicate remains idempotent
    #expect(await driver.starts == starts)
    #expect(await driver.stops == stops)
    #expect(camera.state.context == current)
    #expect(camera.frames.tracking.snapshot.revision == before.revision)
    #expect(camera.frames.tracking.snapshot.acknowledgment?.source == acknowledgment.source)
    await camera.stop()
  }
  @Test func nativeResumeDoesNotRestoreIssuedReceiptAndFreshIntentCanRebind() async throws {
    let driver = ControlledCameraDriver()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized),
      driver: driver, notificationCenter: NotificationCenter())
    try await camera.start(generation: UUID())
    let original = camera.state.context
    let channel = try #require(await driver.events)
    let resumed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var interrupted = false
    _ = try camera.observe {
      if case .interrupted = $0.status { interrupted = true }
      if interrupted, $0.status == .running { resumed.continuation.yield(()) }
    }
    let old = try camera.makeBindingRequest()
    let revision = camera.frames.tracking.snapshot.revision
    channel.emit(.interrupted(7))
    channel.emit(.interruptionEnded)
    var iterator = resumed.stream.makeAsyncIterator(); _ = await iterator.next()
    #expect(camera.state.context == original && camera.status == .running)
    #expect(camera.frames.tracking.snapshot.revision == revision + 1)
    #expect(camera.frames.tracking.snapshot.requestID == nil)
    await #expect(throws: PlayerTrackingError.staleControl) {
      try await camera.requestFullRebind(request: old)
    }
    try await camera.requestFullRebind(request: camera.makeBindingRequest())
    #expect(camera.state.context?.generation != original?.generation)
    #expect(await driver.starts == 2)
    #expect(camera.frames.tracking.snapshot.requestID != nil)
    await #expect(throws: PlayerTrackingError.staleControl) {
      try await camera.requestFullRebind(request: old)
    }
    await camera.stop()
  }
  @Test(arguments: ["stop", "background"])
  func issuedReceiptStillRevokesThroughExistingLifecycleControls(_ kind: String) async throws {
    let center = NotificationCenter()
    let driver = ControlledCameraDriver()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized),
      driver: driver, notificationCenter: center)
    try await camera.start(generation: UUID())
    let request = try camera.makeBindingRequest()
    let revision = camera.frames.tracking.snapshot.revision
    let queued = Task { try await camera.requestFullRebind(request: request) }
    if kind == "stop" { await camera.stop() }
    else {
      center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
      center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    await #expect(throws: PlayerTrackingError.staleControl) { try await queued.value }
    #expect(camera.frames.tracking.snapshot.revision == revision + 2)
    #expect(camera.frames.tracking.snapshot.requestID == nil)
    #expect(camera.frames.tracking.snapshot.acknowledgment == nil)
    #expect(await driver.starts == 1)
    await camera.stop()
  }
  @Test func repeatedLossRevokesNewPendingIntentEvenWhileSourceAlreadySuspended() async throws {
    let driver = ControlledCameraDriver()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized),
      driver: driver, notificationCenter: NotificationCenter())
    try await camera.start(generation: UUID())
    let channel = try #require(await driver.events)
    channel.emit(.interrupted(7))
    let request = try camera.makeBindingRequest()
    let revision = camera.frames.tracking.snapshot.revision
    channel.emit(.interrupted(7))
    #expect(camera.frames.tracking.snapshot.revision == revision + 1)
    #expect(throws: PlayerTrackingError.staleControl) {
      try camera.frames.tracking.validateRequest(request)
    }
    channel.emit(.interrupted(7)) // same already-revoked inactive source: no revision churn
    #expect(camera.frames.tracking.snapshot.revision == revision + 1)
    #expect(await driver.starts == 1)
    await camera.stop()
  }
  @Test(arguments: [false, true])
  func replacementNativeLossCannotActivateRestart(_ failure: Bool) async throws {
    let driver = A6ReturnLossDriver(failure: failure)
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized),
      driver: driver, notificationCenter: NotificationCenter())
    try await camera.start(generation: UUID())
    let request = try camera.makeBindingRequest()
    await #expect(throws: CancellationError.self) {
      try await camera.requestFullRebind(request: request)
    }
    #expect(throws: PlayerTrackingError.staleControl) {
      try camera.frames.tracking.validateRequest(request)
    }
    #expect(await driver.starts == 2) // replacement entered before its own native loss
    #expect(camera.state.context == nil)
    #expect(camera.frames.tracking.snapshot.requestID == nil)
    #expect(camera.frames.tracking.snapshot.acknowledgment == nil)
    await camera.stop()
  }
  @Test func preAttachmentFailureRevokesExactReceiptBeforeAwaitingTeardown() async throws {
    let driver = A6FailureTeardownDriver()
    let camera = CameraPipeline(permission: A6SecondPermissionDenied(),
      driver: driver, notificationCenter: NotificationCenter())
    try await camera.start(generation: UUID())
    let request = try camera.makeBindingRequest()
    let revision = camera.frames.tracking.snapshot.revision
    let queued = Task { try await camera.requestFullRebind(request: request) }
    await driver.untilFailedTeardown() // permission failed before replacement FrameStore.begin
    #expect(throws: PlayerTrackingError.staleControl) {
      try camera.frames.tracking.validateRequest(request)
    }
    #expect(camera.frames.tracking.snapshot.revision == revision + 2) // retirement + receipt revoke
    #expect(camera.frames.tracking.snapshot.requestID == nil)
    #expect(camera.frames.tracking.snapshot.acknowledgment == nil)
    #expect(await driver.starts == 1)
    await driver.release()
    await #expect(throws: CameraFailure.permissionDenied) { try await queued.value }
    await camera.stop()
  }

}
