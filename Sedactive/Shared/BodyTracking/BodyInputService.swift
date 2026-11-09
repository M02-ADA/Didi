import Foundation
import Synchronization

/// Stream termination cannot reenter the source gate from yield/finish. A tiny bounded signal
/// records it synchronously; the next read/control reaps it, without a cleanup task per frame.
nonisolated final class LiveBodySubscriptionSignal: Sendable {
  private let state = Mutex<BodyInputTerminationReason?>(nil)
  func finish(_ reason: BodyInputTerminationReason) { state.withLock { $0 = $0 ?? reason } }
  var reason: BodyInputTerminationReason? { state.withLock { $0 } }
}

/// E05's only mutable accepted-calibration store. All access occurs under the existing
/// CameraTrackingGate mutex; the MainActor provider is its CP1 facade, not a second store.
nonisolated struct LiveBodyInputState: Sendable {
  var configuration: BodyInputConfiguration?
  var source: CameraSourceContext?
  var acceptedRevision: UInt64 = 0
  var revisionHighWater: [PlayerID: UInt64] = [:]
  var cutovers: [PlayerID: BodyInputCutover] = [:]
  var calibration = CalibrationSession()
  var latest: BodySnapshot?
  var lastAdmission: CameraFrameMetadata?
  var lastPublication: UInt64 = 0
  var delivery: BodyInputDelivery = .closed
  var diagnostics = BodyInputDiagnostics()
  var continuation: AsyncStream<BodySnapshot>.Continuation?
  var wake: AsyncStream<Void>.Continuation?
  var subscription: LiveBodySubscriptionSignal?
  var startedAt = 0.0
  var lastProgressAt: Double?
  var terminalFailure: BodyInputFailure?
  var stopped = true

  mutating func invalidate(at time: Double) {
    latest = nil; calibration.invalidate("Source/control invalidated")
    if let configuration {
      self.configuration = configuration.replacingCalibrations([:])
      for id in PlayerID.allCases {
        cutovers[id] = .init(frameID: max(lastAdmission?.frameID ?? 0, cutovers[id]?.frameID ?? 0),
          capturedAt: max(time, cutovers[id]?.capturedAt ?? 0))
      }
      if acceptedRevision < .max { acceptedRevision += 1 } else { terminalFailure = .processingFailure }
    }
    wake?.yield(())
  }
  mutating func configure(_ config: BodyInputConfiguration, source: CameraSourceContext, at time: Double = 0) throws {
    try config.validate()
    guard config.calibrations.isEmpty, config.snapshotBufferCapacity <= 64,
      config.sessionGeneration == source.generation else { throw LiveVisionError.invalidConfiguration }
    guard configuration == nil else { throw BodyInputOperationError.generationReused }
    configuration = config; self.source = source; delivery = .prepared; stopped = false; startedAt = time
    wake?.yield(())
  }
  func context(active: Bool) -> BodyInputContext? {
    guard let configuration, let source else { return nil }
    return .init(sessionGeneration: configuration.sessionGeneration,
      cameraGeometryRevision: source.geometryRevision,
      calibrationRevisions: configuration.calibrations.mapValues(\.revision), cutovers: cutovers,
      isActive: active && !stopped && terminalFailure == nil)
  }
  mutating func publish(_ pose: CameraPoseResult, association: PlayerTrackingSnapshot?) {
    guard !stopped, let config = configuration, source == pose.source.context,
      pose.source.frameID > lastPublication else { return }
    var players: [PlayerID: PlayerBodySample] = [:]
    for id in PlayerID.allCases {
      let slot = association?[id] ?? PlayerTrackingSlotResult(state: .unbound, reason: .disarmed,
        candidateID: nil, cost: nil, requiresRebind: false, lastConfirmedAt: nil)
      let candidate = pose.frame.candidates.first { $0.candidateID == slot.candidateID }
      let calibration = config.calibrations[id]
      // Samples at/before an acceptance cutover never borrow that newly accepted baseline.
      let cut = cutovers[id]
      let usable = cut.map { pose.source.frameID > $0.frameID && pose.source.capturedAt > $0.capturedAt } ?? true
      players[id] = BodyMeasurementExtractor.sample(id: id, candidate: candidate, slot: slot,
        calibration: usable ? calibration : nil, layout: config.playerPlaneLayout)
    }
    let snapshot = BodySnapshot(sessionGeneration: config.sessionGeneration,
      frameID: pose.source.frameID, capturedAt: pose.source.capturedAt,
      cameraGeometryRevision: pose.source.context.geometryRevision, players: players)
    guard (try? snapshot.validate()) != nil else { diagnostics.rejected(); return }
    latest = snapshot; lastPublication = snapshot.frameID; lastProgressAt = pose.source.capturedAt
    if let continuation {
      switch continuation.yield(snapshot) {
      case .enqueued: break
      case .dropped: diagnostics.dropped()
      case .terminated: diagnostics.terminatedYield()
      @unknown default: break
      }
    }
    wake?.yield(())
  }
  mutating func reapSubscription() {
    guard let reason = subscription?.reason else { return }
    continuation = nil; subscription = nil; delivery = .closed; diagnostics.terminated(reason)
  }
  func progress(at time: Double) -> BodyInputProgress {
    if case let .diagnostic(threshold) = configuration?.noProgressPolicy,
      time - (lastProgressAt ?? startedAt) >= threshold { return .suspectedStall }
    return latest == nil ? .waiting : .progressing
  }
  /// Atomically construct/replace the full pair. No arbitrary dictionary may create live acceptance.
  mutating func accept(candidateID: UUID, expectedRevision: UInt64, at time: Double) throws -> BodyInputContext {
    calibration.expire(at: time)
    guard acceptedRevision == expectedRevision, acceptedRevision < .max,
      let candidate = calibration.candidate, candidate.id == candidateID,
      let configuration, source == candidate.admission.source else { throw LiveVisionError.contextConflict }
    guard candidate.hasValidatedAnatomy else { throw LiveVisionError.unsupportedAnatomy }
    var values: [PlayerID: PlayerCalibration] = [:]
    for id in PlayerID.allCases {
      guard let p = candidate.players[id], let a = p.anatomy,
        let nose = p.noseY, let left = p.leftAnkleY, let right = p.rightAnkleY,
        (revisionHighWater[id] ?? 0) < .max else { throw LiveVisionError.unsupportedAnatomy }
      let height = a.crownY - min(a.leftSoleY, a.rightSoleY)
      let value = PlayerCalibration(playerID: id, sessionGeneration: configuration.sessionGeneration,
        revision: (revisionHighWater[id] ?? 0) + 1,
        cameraGeometryRevision: candidate.admission.source.geometryRevision,
        sourceFrameID: candidate.lastFrameID, capturedAt: candidate.lastCapturedAt,
        standingCrownImageY: a.crownY, standingLeftSoleImageY: a.leftSoleY,
        standingRightSoleImageY: a.rightSoleY, standingHipImageY: p.hipY,
        standingBodyImageHeight: height, standingTorsoImageLength: p.torsoLength,
        headOffsetFromNoseShare: (a.crownY - nose) / height,
        leftFootOffsetShare: (left - a.leftSoleY) / height,
        rightFootOffsetShare: (right - a.rightSoleY) / height,
        mapping: .init(imageAspectRatio: Double(candidate.imageWidth) / Double(candidate.imageHeight),
          floorImageY: min(a.leftSoleY, a.rightSoleY), originImageX: p.originX))
      try value.validate(); values[id] = value
    }
    // Validation above is all-or-nothing. Only E05 assigns revisions and acceptance here.
    let boundary = BodyInputCutover(frameID: max(lastAdmission?.frameID ?? 0, candidate.lastFrameID),
      capturedAt: max(time, lastAdmission?.capturedAt ?? candidate.lastCapturedAt))
    self.configuration = configuration.replacingCalibrations(values)
    for id in PlayerID.allCases { revisionHighWater[id] = values[id]!.revision; cutovers[id] = boundary }
    acceptedRevision += 1; latest = nil; calibration.consumed(); wake?.yield(())
    return context(active: true)!
  }
}

nonisolated struct LiveBodyInputRead: Sendable {
  let context: BodyInputContext?
  let latest: BodySnapshot?
  let status: BodyInputStatus
  let diagnostics: BodyInputDiagnostics
  let delivery: BodyInputDelivery
  let calibration: StandingCalibrationProgress
  let acceptedRevision: UInt64
  let progress: BodyInputProgress
}

/// One-shot live CP1 provider per session. App injects the existing retained CameraPipeline.
/// Binding is explicit. This provider never chooses game time, phases, verdicts or render output.
@MainActor final class BodyInputService: BodyInputProviding {
  let camera: CameraPipeline
  private var used = false
  private var startConfiguration: BodyInputConfiguration?
  private var observer: (@MainActor (BodyInputStatusEvent) -> Void)?
  private var observerToken: UUID?
  private var notifying = false
  private var eventRevision: UInt64 = 0
  private var statusTask: Task<Void, Never>?
  private var read: LiveBodyInputRead { camera.frames.tracking.readBody() }
  var latestSnapshot: BodySnapshot? { read.latest }
  var currentContext: BodyInputContext? { read.context }
  var status: BodyInputStatus { read.status }
  var diagnostics: BodyInputDiagnostics { read.diagnostics }
  var calibrationProgress: StandingCalibrationProgress { read.calibration }
  var acceptedContextRevision: UInt64 { read.acceptedRevision }
  init(camera: CameraPipeline) { self.camera = camera }
  deinit { statusTask?.cancel() }

  func start(configuration: BodyInputConfiguration) async throws {
    guard !notifying else { throw BodyInputOperationError.reentrantControl }
    if currentContext?.isActive == true {
      guard startConfiguration == configuration else { throw BodyInputOperationError.configurationChanged }
      return
    }
    guard !used, configuration.calibrations.isEmpty else { throw LiveVisionError.invalidConfiguration }
    try configuration.validate()
    guard configuration.snapshotBufferCapacity <= 64 else { throw LiveVisionError.invalidConfiguration }
    used = true; startConfiguration = configuration
    try await camera.start(generation: configuration.sessionGeneration)
    let gate = camera.frames.tracking
    try gate.configureBody(configuration)
    let signals = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    gate.bodyWake(signals.continuation)
    statusTask = Task { @MainActor [weak self] in
      for await _ in signals.stream {
        guard !Task.isCancelled, let self else { break }
        self.notify()
      }
    }
    notify()
  }
  func stop() async {
    guard !notifying else { return }
    camera.frames.tracking.stopBody()
    await camera.stop()
    statusTask?.cancel(); statusTask = nil
    notify()
  }
  func makeBindingRequest() throws -> CameraBindingRequest {
    guard !notifying else { throw BodyInputOperationError.reentrantControl }
    return try camera.makeBindingRequest()
  }
  func armBinding(_ request: CameraBindingRequest) throws {
    guard !notifying else { throw BodyInputOperationError.reentrantControl }
    _ = try camera.armBinding(request: request)
  }
  func cancelBinding() { guard !notifying else { return }; camera.cancelBinding() }
  func requestStandingCalibration(id: UUID) throws -> CalibrationRequest {
    guard !notifying else { throw BodyInputOperationError.reentrantControl }
    return try camera.frames.tracking.requestCalibration(id: id)
  }
  func cancelStandingCalibration(_ request: CalibrationRequest) {
    guard !notifying else { return }
    camera.frames.tracking.cancelCalibration(request)
  }
  @discardableResult func confirmStandingCandidate(_ id: UUID,
    expectedContextRevision: UInt64) throws -> BodyInputContext {
    guard !notifying else { throw BodyInputOperationError.reentrantControl }
    return try camera.frames.tracking.acceptBodyCandidate(id, expectedRevision: expectedContextRevision)
  }
  @discardableResult func setCalibrations(_ values: [PlayerID: PlayerCalibration],
    generation: UUID) async throws -> BodyInputContext {
    guard !notifying else { throw BodyInputOperationError.reentrantControl }
    return try camera.frames.tracking.replaceBodyCalibrations(values, generation: generation)
  }
  func snapshotStream(generation: UUID) throws -> AsyncStream<BodySnapshot> {
    guard !notifying else { throw BodyInputOperationError.reentrantControl }
    return try camera.frames.tracking.bodyStream(generation: generation)
  }
  func releaseSnapshotSubscription(generation: UUID) throws {
    guard !notifying else { throw BodyInputOperationError.reentrantControl }
    try camera.frames.tracking.releaseBodyStream(generation: generation)
  }
  func statusUpdates(_ observer: @escaping @MainActor (BodyInputStatusEvent) -> Void) throws -> UUID {
    guard !notifying else { throw BodyInputOperationError.reentrantControl }
    guard self.observer == nil else { throw BodyInputOperationError.observerAlreadyRegistered }
    let token = UUID(); observerToken = token; self.observer = observer; notify(); return token
  }
  func removeStatusObserver(_ token: UUID) throws {
    guard !notifying else { throw BodyInputOperationError.reentrantControl }
    if observerToken == token { observerToken = nil; observer = nil }
  }
  private func notify() {
    guard !notifying, let observer else { return }
    notifying = true; defer { notifying = false }
    if eventRevision < .max { eventRevision += 1 }
    let r = read
    observer(.init(sessionGeneration: r.context?.sessionGeneration, occurredAt: CameraHostClock.now(),
      statusRevision: eventRevision, status: r.status, context: r.context, delivery: r.delivery,
      progress: r.progress))
  }
}
