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
  var measurements = LiveMeasurementFlow()
  var latest: BodySnapshot?
  /// Per-player live airborne estimators (reset with each calibration revision or source change).
  var jumps: [PlayerID: LiveJumpEstimator] = [:]
  var wrists: PreparedWristFrame?
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
    measurements.invalidate()
    latest = nil; wrists = nil; jumps = [:]; calibration.invalidate("Source/control invalidated")
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
  func context(active: Bool, wristContact: WristContactContextV1? = nil) -> BodyInputContext? {
    guard let configuration, let source else { return nil }
    return .init(sessionGeneration: configuration.sessionGeneration,
      cameraGeometryRevision: source.geometryRevision,
      calibrationRevisions: configuration.calibrations.mapValues(\.revision), cutovers: cutovers,
      isActive: active && !stopped && terminalFailure == nil, wristContact: wristContact)
  }
  mutating func publish(_ pose: CameraPoseResult, association: PlayerTrackingSnapshot?,
    admission: CameraTrackingAdmission, acknowledgment: CameraBindingAcknowledgment?) {
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
      var sample = BodyMeasurementExtractor.sample(id: id, candidate: candidate, slot: slot,
        calibration: usable ? calibration : nil, layout: config.playerPlaneLayout)
      // Live airborne estimate from this frame's valid soles against the standing reference.
      if usable, let calibration, calibration.referenceQuality != nil, sample.trackingStatus == .reliable {
        let layout = config.playerPlaneLayout
        let floorLeft = calibration.mapping.gameY(imageY: calibration.standingLeftSoleImageY, layout: layout)
        let floorRight = calibration.mapping.gameY(imageY: calibration.standingRightSoleImageY, layout: layout)
        var estimator = jumps[id] ?? LiveJumpEstimator()
        let jump = estimator.step(frameID: pose.source.frameID, capturedAt: pose.source.capturedAt,
          leftSole: sample.geometry.leftSoleY.validity == .valid ? sample.geometry.leftSoleY.value : nil,
          rightSole: sample.geometry.rightSoleY.validity == .valid ? sample.geometry.rightSoleY.value : nil,
          standingLeftSole: floorLeft, standingRightSole: floorRight,
          standingHeight: calibration.mapping.gameY(imageY: calibration.standingCrownImageY, layout: layout)
            - min(floorLeft, floorRight),
          calibrationRevision: calibration.revision)
        jumps[id] = estimator
        #if DEBUG
        // Frame-level jump evidence while the lower sole is off the floor (no image data).
        let standing = calibration.mapping.gameY(imageY: calibration.standingCrownImageY, layout: layout) - min(floorLeft, floorRight)
        let enter = estimator.enterThreshold(standingHeight: standing)
        if jump.phase != .grounded || (estimator.lift ?? 0) > enter / 2 {
          print(String(format: "[LaserJumpFrame] %@ frame %llu t %.3f · lift %@ baseline %.3f enter %.3f noise %.4f → %@",
            id.rawValue, pose.source.frameID, pose.source.capturedAt,
            estimator.lift.map { String(format: "%.3f", $0) } ?? "-", estimator.baseline, enter, estimator.noise,
            "\(jump.phase)"))
        }
        #endif
        sample = PlayerBodySample(playerID: sample.playerID, calibrationRevision: sample.calibrationRevision,
          trackingStatus: sample.trackingStatus, geometry: sample.geometry, jumpState: jump)
      } else { jumps[id] = nil }
      players[id] = sample
    }
    let base = BodySnapshot(sessionGeneration: config.sessionGeneration,
      frameID: pose.source.frameID, capturedAt: pose.source.capturedAt,
      cameraGeometryRevision: pose.source.context.geometryRevision, players: players)
    wrists = WristEvidencePreparation.prepare(pose, association: association, admission: admission,
      acknowledgment: acknowledgment, body: self)
    let snapshot = BodySnapshot(sessionGeneration:base.sessionGeneration,frameID:base.frameID,
      capturedAt:base.capturedAt,cameraGeometryRevision:base.cameraGeometryRevision,
      players:base.players,wristContact:wrists?.attachment(matching:base))
    guard (try? snapshot.validate()) != nil else { wrists = nil; diagnostics.rejected(); return }
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
    guard candidate.acceptance.isAcceptable else { throw LiveVisionError.unsupportedAnatomy }
    var values: [PlayerID: PlayerCalibration] = [:]
    for id in candidate.admission.roster {
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
          floorImageY: min(a.leftSoleY, a.rightSoleY), originImageX: p.originX),
        referenceQuality: a.quality)
      try value.validate(); values[id] = value
    }
    // Validation above is all-or-nothing. Only E05 assigns revisions and acceptance here.
    let boundary = BodyInputCutover(frameID: max(lastAdmission?.frameID ?? 0, candidate.lastFrameID),
      capturedAt: max(time, lastAdmission?.capturedAt ?? candidate.lastCapturedAt))
    self.configuration = configuration.replacingCalibrations(values)
    for id in candidate.admission.roster { revisionHighWater[id] = values[id]!.revision; cutovers[id] = boundary }
    acceptedRevision += 1; latest = nil; wrists = nil; calibration.consumed(); wake?.yield(())
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
  var wrists: PreparedWristFrame? = nil // internal atomic preparation; not a second gameplay stream
  let measurements: LiveMeasurementSnapshot?
}

/// Sequential live CP1 sessions on the existing retained CameraPipeline. Await stop before Retry.
/// Binding is explicit. This provider never chooses game time, phases, verdicts or render output.
@MainActor final class BodyInputService: BodyInputProviding {
  let camera: CameraPipeline
  private enum Lifecycle: Equatable { case idle, starting, running, stopping }
  private var lifecycle = Lifecycle.idle
  private var session: UUID?
  private var starting: Task<Void, Error>?
  private var stopping: Task<Void, Never>?
  private var stoppedRead = LiveBodyInputRead(context: nil, latest: nil, status: .stopped,
    diagnostics: .init(), delivery: .closed,
    calibration: CalibrationSession().progress, acceptedRevision: 0, progress: .waiting,
    measurements: nil)
  private var startConfiguration: BodyInputConfiguration?
  private var observer: (@MainActor (BodyInputStatusEvent) -> Void)?
  private var observerToken: UUID?
  private var notifying = false
  private var eventRevision: UInt64 = 0
  private var statusTask: Task<Void, Never>?
  private var read: LiveBodyInputRead {
    guard let session, camera.ownsBodySession(session) else { return stoppedRead }
    return camera.frames.tracking.readBody()
  }
  var latestSnapshot: BodySnapshot? { read.latest }
  var currentContext: BodyInputContext? { read.context }
  var status: BodyInputStatus { read.status }
  var diagnostics: BodyInputDiagnostics { read.diagnostics }
  var calibrationProgress: StandingCalibrationProgress { read.calibration }
  var acceptedContextRevision: UInt64 { read.acceptedRevision }
  var acceptedCalibrations: [PlayerID: PlayerCalibration] {
    guard let session, camera.ownsBodySession(session) else { return [:] }
    return camera.frames.tracking.acceptedBodyCalibrations()
  }
  init(camera: CameraPipeline) { self.camera = camera }
  deinit { statusTask?.cancel() }

  func start(configuration: BodyInputConfiguration) async throws {
    guard !notifying else { throw BodyInputOperationError.reentrantControl }
    guard lifecycle != .stopping else { throw BodyInputOperationError.notRunning }
    if lifecycle == .starting || lifecycle == .running {
      guard startConfiguration == configuration else { throw BodyInputOperationError.configurationChanged }
      if let starting { try await starting.value }
      guard lifecycle == .running, currentContext?.isActive == true else {
        throw BodyInputOperationError.notRunning
      }
      return
    }
    try configuration.validate()
    guard configuration.calibrations.isEmpty, configuration.snapshotBufferCapacity <= 64 else {
      throw LiveVisionError.invalidConfiguration
    }
    #if DEBUG
    print("[LaserSetupRestart] provider: reserving camera (lifecycle \(lifecycle))")
    #endif
    let owner = try camera.reserveBodySession()
    session = owner; lifecycle = .starting; startConfiguration = configuration
    let gate = camera.frames.tracking
    let task = Task { @MainActor in
      try await self.camera.startBodySession(owner, generation: configuration.sessionGeneration)
      #if DEBUG
      print("[LaserSetupRestart] provider: camera started")
      #endif
      try Task.checkCancellation()
      guard self.session == owner, self.lifecycle == .starting else { throw CancellationError() }
      try gate.configureBody(configuration, session: owner)
      let signals = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      gate.bodyWake(signals.continuation)
      self.statusTask = Task { @MainActor [weak self] in
        for await _ in signals.stream {
          guard !Task.isCancelled, let self else { break }
          self.notify()
        }
      }
      self.lifecycle = .running
      self.notify()
    }
    starting = task
    do {
      try await withTaskCancellationHandler { try await task.value } onCancel: {
        task.cancel()
        gate.stopBodySession(owner) // old cancellation cannot affect a replacement lease
      }
      try Task.checkCancellation()
      guard session == owner, lifecycle == .running else { throw CancellationError() }
      starting = nil
    } catch {
      if session == owner { await stop() }
      throw error
    }
  }
  func stop() async {
    guard !notifying else { return }
    if let stopping { await stopping.value; return }
    guard let owner = session else { return }
    lifecycle = .stopping
    starting?.cancel()
    camera.stopBodySession(owner)
    let startup = starting
    statusTask?.cancel()
    let statusUpdates = statusTask
    notify() // unavailable immediately, even while native/worker cleanup remains blocked
    let task = Task { @MainActor in
      #if DEBUG
      print("[LaserSetupRestart] provider: stopping camera")
      #endif
      await self.camera.stop()
      #if DEBUG
      print("[LaserSetupRestart] provider: camera stopped; joining startup and status")
      #endif
      if let startup { _ = try? await startup.value }
      if let statusUpdates { await statusUpdates.value }
      #if DEBUG
      print("[LaserSetupRestart] provider: releasing body session")
      #endif
      // Keep the stopped context available to old callers without exposing a future session.
      self.stoppedRead = self.camera.frames.tracking.readBody()
      let released = await self.camera.releaseBodySession(owner)
      #if DEBUG
      print("[LaserSetupRestart] provider: released \(released)")
      #endif
      self.starting = nil; self.statusTask = nil; self.stopping = nil
      if released {
        self.session = nil; self.startConfiguration = nil; self.lifecycle = .idle
      } // Failed drain retains exclusive ownership and refuses Retry.
      self.notify()
    }
    stopping = task
    await task.value
  }
  private func requireRunning() throws {
    guard !notifying else { throw BodyInputOperationError.reentrantControl }
    guard lifecycle == .running else { throw BodyInputOperationError.notRunning }
  }
  func makeBindingRequest() throws -> CameraBindingRequest {
    try requireRunning()
    return try camera.makeBindingRequest()
  }
  func armBinding(_ request: CameraBindingRequest) throws {
    try requireRunning()
    _ = try camera.armBinding(request: request)
  }
  func cancelBinding() { guard !notifying, lifecycle == .running else { return }; camera.cancelBinding() }
  func requestStandingCalibration(id: UUID) throws -> CalibrationRequest {
    try requireRunning()
    return try camera.frames.tracking.requestCalibration(id: id)
  }
  func cancelStandingCalibration(_ request: CalibrationRequest) {
    guard !notifying, lifecycle == .running else { return }
    camera.frames.tracking.cancelCalibration(request)
  }
  @discardableResult func confirmStandingCandidate(_ id: UUID,
    expectedContextRevision: UInt64) throws -> BodyInputContext {
    try requireRunning()
    return try camera.frames.tracking.acceptBodyCandidate(id, expectedRevision: expectedContextRevision)
  }
  @discardableResult func setCalibrations(_ values: [PlayerID: PlayerCalibration],
    generation: UUID) async throws -> BodyInputContext {
    try requireRunning()
    return try camera.frames.tracking.replaceBodyCalibrations(values, generation: generation)
  }
  func snapshotStream(generation: UUID) throws -> AsyncStream<BodySnapshot> {
    try requireRunning()
    return try camera.frames.tracking.bodyStream(generation: generation)
  }
  func releaseSnapshotSubscription(generation: UUID) throws {
    try requireRunning()
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
