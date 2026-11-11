import Dispatch
import Foundation
import Synchronization
import UIKit
#if DEBUG
import CoreGraphics
#endif

nonisolated struct CameraPoseStatistics: Sendable {
  var completed: UInt64 = 0, rejected: UInt64 = 0, failures: UInt64 = 0
  var counts: [UInt64] = [0, 0, 0, 0]  // Successful frames with zero / one / two / more bodies.
  var inference = CameraLatencyWindow(), age = CameraLatencyWindow()
  var firstCompletion: Double?, lastCompletion: Double?
  mutating func increment(_ key: WritableKeyPath<Self, UInt64>) {
    if self[keyPath: key] < .max { self[keyPath: key] += 1 }
  }
  var framesPerSecond: Double? {
    guard completed > 1, let firstCompletion, let lastCompletion,
      lastCompletion > firstCompletion else { return nil }
    return Double(completed - 1) / (lastCompletion - firstCompletion)
  }
}
nonisolated struct CameraPoseSnapshot: Sendable {
  let latest: CameraPoseResult?
  let statistics: CameraPoseStatistics
}

/// One latest immutable result, no observer/stream and no raw image ownership or pose history.
nonisolated final class CameraPoseResults: Sendable {
  private struct State {
    var context: CameraSourceContext?
    var token = UUID()
    var lastStarted: UInt64?
    var latest: CameraPoseResult?
    var statistics = CameraPoseStatistics()
  }
  private let state = Mutex(State())
  nonisolated struct Ticket: Sendable {
    let source: CameraFrameMetadata
    fileprivate let token: UUID
  }
  func begin(_ context: CameraSourceContext) {
    state.withLock {
      guard $0.context != context else { return }
      $0 = State(context: context)
    }
  }
  func invalidate(_ context: CameraSourceContext) {
    state.withLock {
      guard $0.context == context else { return }
      $0.context = nil
      $0.latest = nil
      $0.token = UUID()
    }
  }
  func start(_ source: CameraFrameMetadata) -> Ticket? {
    state.withLock {
      guard $0.context == source.context, source.frameID > ($0.lastStarted ?? 0) else {
        $0.statistics.increment(\.rejected)
        return nil
      }
      $0.lastStarted = source.frameID
      return Ticket(source: source, token: $0.token)
    }
  }
  @discardableResult
  func finish(_ result: CameraPoseResult, ticket: Ticket, startedAt: Double, completedAt: Double,
    cancelled: Bool = false) -> Bool
  {
    state.withLock {
      guard !cancelled, $0.context == ticket.source.context, $0.token == ticket.token,
        result.source == ticket.source, result.matchesSource, $0.lastStarted == result.source.frameID,
        result.source.frameID > ($0.latest?.source.frameID ?? 0),
        startedAt.isFinite, completedAt.isFinite, completedAt >= startedAt,
        startedAt >= result.source.capturedAt
      else {
        $0.statistics.increment(\.rejected)
        return false
      }
      $0.latest = result
      $0.statistics.increment(\.completed)
      let bucket = min(result.observationCount, 3)
      if $0.statistics.counts[bucket] < .max { $0.statistics.counts[bucket] += 1 }
      $0.statistics.inference.record(seconds: completedAt - startedAt)
      $0.statistics.age.record(seconds: completedAt - result.source.capturedAt)
      $0.statistics.firstCompletion = $0.statistics.firstCompletion ?? completedAt
      $0.statistics.lastCompletion = completedAt
      return true
    }
  }
  func failed(_ ticket: Ticket) {
    state.withLock {
      guard $0.context == ticket.source.context, $0.token == ticket.token,
        $0.lastStarted == ticket.source.frameID,
        ($0.latest?.source.frameID ?? 0) < ticket.source.frameID else {
        $0.statistics.increment(\.rejected)
        return
      }
      $0.statistics.increment(\.failures)
      $0.latest = nil
    }
  }
  var snapshot: CameraPoseSnapshot {
    state.withLock { CameraPoseSnapshot(latest: $0.latest, statistics: $0.statistics) }
  }
}



/// An opaque, gate-issued request receipt. Retrying this value is safe; minting a new one is
/// an explicit new intent. The serial prevents replay without retaining a growing UUID registry.
nonisolated struct CameraBindingRequest: Equatable, Sendable {
  let requestID: UUID
  fileprivate let serial: UInt64
}
nonisolated private enum CameraBindingCommandPhase { case issued, restarting, active, revoked }

// B2b control/publication gate. No PlayerTracker or image ownership is stored in this gate.
nonisolated struct CameraTrackingAdmission: Equatable, Sendable {
  let context: CameraSourceContext
  let revision: UInt64
  let requestID: UUID?
  var calibration: CalibrationAdmission? = nil
  var acceptedBodyRevision: UInt64? = nil // E08 only; immutable acceptance context at admission
  var presentationRevision: UInt64? = nil
  /// DEBUG Solo Test session: the tracker acquires one person into P1 only.
  var solo = false
  #if DEBUG
  var anatomyInspection: UUID? = nil
  #endif
}
nonisolated struct CameraTrackingControl: Sendable {
  let revision: UInt64
  let requestID: UUID?
  let watermark: Double
}
nonisolated struct CameraBindingAcknowledgment: Sendable {
  let requestID: UUID
  let source: PlayerTrackingSource
  let player1: PlayerTrackingSlotResult
  let player2: PlayerTrackingSlotResult
}
nonisolated struct CameraTrackingDiagnostics: Sendable {
  let policyVersion: String
  let revision: UInt64
  let requestID: UUID?
  let acknowledgment: CameraBindingAcknowledgment?
  let latest: PlayerTrackingSnapshot?
  let reason: String
  let accepted: UInt64
  let rejected: UInt64
  let staleRejected: UInt64
  let captureToCommitAge: Double?
  let refusals: UInt64
  let expiries: UInt64
  let invalidations: UInt64
  let acknowledgments: UInt64
  let mutualCoreCount: Int?
  let watermark: Double
}

#if DEBUG
/// One non-authoritative numeric observation, never an image, pose history or accepted reference.
nonisolated struct VisionPreviewMaskDiagnostic: Sendable {
  let source: CameraFrameMetadata
  let bindingRevision: UInt64
  let calibrationRequest: UUID
  let quality: PersonMaskQuality
  let supportedRegions: Int
  let reportedOutputBytes: Int
  let serviceSeconds: Double
}
nonisolated struct VisionPreviewMaskRead: Sendable {
  let last: VisionPreviewMaskDiagnostic?
  let isCurrentSourceAndFresh: Bool
}
#endif

/// Sole source/control linearization authority. The worker supplies a synchronous nonescaping
/// commit closure; only that actor owns/mutates its MotionEngine. No inference occurs under lock.
/// Lock order: FrameStore -> CameraPoseResults (B1) -> this gate, never the reverse.
nonisolated final class CameraTrackingGate: Sendable {
  private struct State {
    var context: CameraSourceContext?
    var active = false
    var revision: UInt64 = 0
    var requestID: UUID?
    var acknowledgment: CameraBindingAcknowledgment?
    // Bounded authorization receipt, NOT another identity tracker. Survives revocation.
    var lastBoundGeneration: UUID?
    var latest: PlayerTrackingSnapshot?
    var lastFrame: UInt64 = 0
    var lastCapture: Double?
    var watermark: Double = 0
    var reason = "disarmed"
    var accepted: UInt64 = 0, rejected: UInt64 = 0, refusals: UInt64 = 0
    var expiries: UInt64 = 0, invalidations: UInt64 = 0, acknowledgments: UInt64 = 0
    var mutualCoreCount: Int?
    var captureToCommitAge: Double?
    var staleRejected: UInt64 = 0
    var wake: AsyncStream<Void>.Continuation?
    var timer: (any DispatchSourceTimer)?
    var deadline: Double?
    var validPolicy = true
    var foreground = true
    var notificationCenter: NotificationCenter?
    var lifecycleObservers: [any NSObjectProtocol] = []
    var requestSerial: UInt64 = 0
    var command: CameraBindingRequest?
    var bodySessionOwner: UUID?
    var body = LiveBodyInputState()
    var presentation = VisionNumericPoseChannel()
    #if DEBUG
    var anatomyInspection = AnatomyInspectionState()
    var visionPreviewMask: VisionPreviewMaskDiagnostic?
    #endif
    var commandPhase: CameraBindingCommandPhase = .revoked
    var restartFromGeneration: UUID?
  }
  #if DEBUG
  let anatomyInspectionBudget = CameraPreviewBudget(limit: 8 * 1024 * 1024)
  #endif
  let policy: PlayerTrackingPolicy
  let policyVersion: String
  private let now: @Sendable () -> Double
  private let state: Mutex<State>
  init(policy: PlayerTrackingPolicy = B2bExperimentalPolicyV1.value,
    version: String = B2bExperimentalPolicyV1.version,
    automaticDeadlines: Bool = true, now: @escaping @Sendable () -> Double = CameraHostClock.now) {
    self.policy = policy
    policyVersion = version
    self.now = now
    var initial = State()
    do { try policy.validate() } catch {
      initial.validPolicy = false
      initial.reason = "invalid experimental policy"
    }
    state = Mutex(initial)
    if automaticDeadlines {
      let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(
        label: "Sedactive.tracking.expiry", qos: .userInitiated))
      timer.setEventHandler { [weak self] in self?.expireDue() }
      state.withLock { $0.timer = timer }
      timer.activate()
    }
  }
  deinit {
    state.withLock {
      $0.timer?.cancel()
      if let center = $0.notificationCenter {
        for token in $0.lifecycleObservers { center.removeObserver(token) }
      }
    }
  }
  private func increment(_ value: inout UInt64) { if value < .max { value += 1 } }
  private func clear(_ s: inout State, reason: String) {
    s.body.invalidate(at: now())
    s.presentation.invalidate()
    #if DEBUG
    s.visionPreviewMask = nil
    s.anatomyInspection.invalidate()
    #endif
    s.requestID = nil
    s.acknowledgment = nil
    s.latest = nil
    s.lastFrame = 0
    s.lastCapture = nil
    s.watermark = 0
    s.mutualCoreCount = nil
    s.captureToCommitAge = nil
    s.reason = reason
    s.deadline = nil
    s.timer?.schedule(deadline: .distantFuture)
  }
  private func advance(_ s: inout State) -> Bool {
    guard s.revision < .max else {
      s.validPolicy = false
      clear(&s, reason: "control revision exhausted")
      return false
    }
    s.revision += 1
    return true
  }
  func begin(_ context: CameraSourceContext, wake: AsyncStream<Void>.Continuation) {
    state.withLock {
      guard $0.context != context else { return }
      if $0.commandPhase == .active { $0.commandPhase = .revoked }
      _ = advance(&$0)
      clear(&$0, reason: $0.validPolicy ? "disarmed" : "invalid experimental policy")
      $0.context = context
      $0.active = true
      $0.wake = wake
    }
  }
  func resume(_ context: CameraSourceContext) {
    state.withLock { if $0.context == context { $0.active = true } }
  }
  /// Unexpected loss on the still-current native source revokes even an unsubmitted intent.
  /// Deliberate old-source retirement uses invalidate instead; retired callbacks cannot revoke
  /// a replacement because source identity and the receipt transition share this mutex.
  func sourceLost(_ context: CameraSourceContext) {
    state.withLock {
      guard $0.context == context else { return }
      let changed = $0.active || $0.commandPhase != .revoked || $0.requestID != nil
      $0.commandPhase = .revoked
      if changed {
        _ = advance(&$0)
        increment(&$0.invalidations)
        clear(&$0, reason: "native source lost — explicit authorization revoked")
      }
      $0.active = false
      $0.wake?.yield(())
    }
  }
  func invalidate(_ context: CameraSourceContext, ended: Bool) {
    state.withLock {
      guard $0.context == context else { return }
      if $0.commandPhase == .active
        || ($0.commandPhase == .restarting
          && $0.restartFromGeneration != context.generation) {
        $0.commandPhase = .revoked
      }
      if $0.active {
        _ = advance(&$0)
        increment(&$0.invalidations)
        clear(&$0, reason: "source invalidated")
      }
      $0.active = false
      if ended { $0.context = nil }
      $0.wake?.yield(())
    }
  }

  /// Retained by the gate, not by an individual native source. No MainActor hop is needed
  /// to revoke while cleanup/inference is blocked. Call once from retained camera composition.
  func observeApplicationLifecycle(_ center: NotificationCenter, initiallyForeground: Bool) {
    state.withLock {
      guard $0.notificationCenter == nil else { return }
      $0.notificationCenter = center
      $0.foreground = initiallyForeground
      $0.lifecycleObservers = [
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
          object: nil, queue: nil) { [weak self] _ in self?.enteredBackground() },
        center.addObserver(forName: UIApplication.didBecomeActiveNotification,
          object: nil, queue: nil) { [weak self] _ in self?.enteredForeground() },
      ]
    }
  }
  private func enteredBackground() {
    state.withLock {
      guard $0.foreground else { return }
      $0.foreground = false
      $0.commandPhase = .revoked
      _ = advance(&$0)
      clear(&$0, reason: "background — explicit authorization revoked")
      increment(&$0.invalidations)
      $0.wake?.yield(())
    }
  }
  private func enteredForeground() {
    state.withLock { $0.foreground = true } // Never restores a request or advances its revision.
  }
  var isForeground: Bool { state.withLock { $0.foreground } }

  func makeBindingRequest() throws -> CameraBindingRequest {
    try state.withLock {
      guard $0.validPolicy else { throw PlayerTrackingError.invalidPolicy }
      guard $0.foreground, $0.requestSerial < .max, advance(&$0) else {
        throw PlayerTrackingError.staleControl
      }
      $0.requestSerial += 1
      let request = CameraBindingRequest(requestID: UUID(), serial: $0.requestSerial)
      clear(&$0, reason: "new request prepared — not armed")
      $0.command = request
      $0.commandPhase = .issued
      $0.restartFromGeneration = nil
      $0.wake?.yield(())
      return request
    }
  }
  private func validate(_ request: CameraBindingRequest, state s: State) throws {
    guard s.validPolicy else { throw PlayerTrackingError.invalidPolicy }
    guard s.foreground, s.command == request, s.requestSerial == request.serial,
      s.commandPhase != .revoked else { throw PlayerTrackingError.staleControl }
  }
  func validateRequest(_ request: CameraBindingRequest) throws {
    try state.withLock { try validate(request, state: $0) }
  }
  /// false = this exact request is already active (including completed restart); no new run.
  func prepareRestart(_ request: CameraBindingRequest) throws -> Bool {
    try state.withLock {
      try validate(request, state: $0)
      if $0.commandPhase == .active, $0.requestID == request.requestID { return false }
      guard $0.commandPhase == .issued else { throw PlayerTrackingError.staleControl }
      $0.commandPhase = .restarting
      $0.restartFromGeneration = $0.context?.generation
      return true
    }
  }
  func validateRestart(_ request: CameraBindingRequest) throws {
    try state.withLock {
      try validate(request, state: $0)
      guard $0.commandPhase == .restarting else { throw PlayerTrackingError.staleControl }
    }
  }
  /// Capture facade reserves its new source identity under the same revocation gate.
  /// Allocation is pure owner-local bookkeeping: no observers, await or native API calls here.
  func authorizeRestartSource(_ request: CameraBindingRequest,
    allocate: () -> CameraSourceContext) throws -> CameraSourceContext {
    try state.withLock {
      try validate(request, state: $0)
      guard $0.commandPhase == .restarting else { throw PlayerTrackingError.staleControl }
      return allocate()
    }
  }
  func abandonRequest(_ request: CameraBindingRequest) {
    state.withLock {
      guard $0.command == request else { return } // old completion cannot revoke a newer intent
      revoke(&$0)
    }
  }
  @discardableResult func completeRestart(_ request: CameraBindingRequest,
    context: CameraSourceContext) throws -> UInt64 {
    try state.withLock {
      try validate(request, state: $0)
      guard $0.commandPhase == .restarting, $0.context == context,
        $0.restartFromGeneration != context.generation else {
        throw PlayerTrackingError.incompatibleSource
      }
      return try arm(request, state: &$0)
    }
  }
  @discardableResult func arm(request: CameraBindingRequest) throws -> UInt64 {
    try state.withLock {
      try validate(request, state: $0)
      if $0.commandPhase == .active, $0.requestID == request.requestID { return $0.revision }
      guard $0.commandPhase == .issued else { throw PlayerTrackingError.staleControl }
      return try arm(request, state: &$0)
    }
  }
  private func arm(_ request: CameraBindingRequest, state s: inout State) throws -> UInt64 {
    guard s.active, s.foreground, let context = s.context else {
      throw PlayerTrackingError.incompatibleSource
    }
    guard s.lastBoundGeneration != context.generation else {
      throw PlayerTrackingError.bindingRequiresNewGeneration
    }
    guard advance(&s) else { throw PlayerTrackingError.staleControl }
    clear(&s, reason: "armed — awaiting atomic pair")
    s.requestID = request.requestID
    s.commandPhase = .active
    s.wake?.yield(())
    return s.revision
  }
  private func revoke(_ s: inout State) {
    guard s.commandPhase != .revoked || s.requestID != nil else { return }
    s.commandPhase = .revoked
    _ = advance(&s)
    clear(&s, reason: "authorization revoked")
    increment(&s.invalidations)
    s.wake?.yield(())
  }
  func revoke() { state.withLock { revoke(&$0) } }
  func admit(_ source: CameraFrameMetadata) -> CameraTrackingAdmission? {
    state.withLock {
      guard $0.validPolicy, $0.foreground, $0.active, $0.context == source.context else { return nil }
      $0.body.calibration.expire(at: now())
      if $0.body.source == source.context { $0.body.lastAdmission = source }
      var stamp = CameraTrackingAdmission(context: source.context, revision: $0.revision, requestID: $0.requestID,
        calibration: $0.body.calibration.admission,
        acceptedBodyRevision: $0.body.acceptedRevision,
        presentationRevision: $0.presentation.admit(source, authorized: $0.requestID != nil))
      stamp.solo = $0.body.configuration?.soloPlayer != nil
      #if DEBUG
      stamp.anatomyInspection = $0.anatomyInspection.ticket?.id
      #endif
      return stamp
    }
  }
  func rejected(_ error: Error? = nil) {
    let stale: Bool
    switch error as? PlayerTrackingError {
    case .staleControl, .staleFrame, .incompatibleSource: stale = true
    default: stale = false
    }
    state.withLock {
      increment(&$0.rejected)
      if stale { increment(&$0.staleRejected) }
    }
  }

  /// Both actor-owned state assignment and the matching publication/ack are protected by this lock.
  /// Revocation cannot interleave between validation and commit. The closure MUST NOT suspend,
  /// perform inference, call lifecycle/control APIs or reenter this gate.
  @discardableResult
  func finish(_ staged: MotionEngine, admission: CameraTrackingAdmission,
    source: CameraFrameMetadata, mutualCoreCount: Int?, cancelled: Bool = false,
    commit: () -> Void) -> Bool {
    state.withLock {
      let time = now()
      expire(&$0, at: time) // A delayed timer callback cannot allow a post-deadline commit.
      let result = staged.tracker.snapshot
      guard !cancelled, $0.validPolicy, $0.active, $0.context == source.context,
        admission.context == source.context, admission.revision == $0.revision,
        let request = admission.requestID, request == $0.requestID,
        time.isFinite, time >= source.capturedAt, time - source.capturedAt < policy.freshness,
        source.frameID > $0.lastFrame,
        $0.lastCapture.map({ source.capturedAt > $0 }) ?? true,
        source.capturedAt >= $0.watermark, staged.appliedExpiry >= $0.watermark,
        let original = result.source,
        original.controlRevision == admission.revision,
        original.context.generation == source.context.generation,
        original.context.epoch == source.context.epoch,
        original.context.geometryRevision == source.context.geometryRevision,
        original.context.imageWidth == source.descriptor.width,
        original.context.imageHeight == source.descriptor.height,
        original.context.rotationAngle == source.rotationAngle,
        original.context.mirrored == source.mirrored,
        original.frameID == source.frameID, original.capturedAt == source.capturedAt
      else {
        increment(&$0.rejected)
        increment(&$0.staleRejected)
        #if DEBUG
        print(String(format: "[LaserTrack] t %.3f · frame %llu REJECTED · age %.0f ms (limit %.0f) · cancelled %@ · context %@ · revision %@",
                     time, source.frameID, (time - source.capturedAt) * 1000, policy.freshness * 1000,
                     cancelled ? "yes" : "no", $0.context == source.context ? "same" : "CHANGED",
                     admission.revision == $0.revision ? "same" : "CHANGED"))
        #endif
        return false
      }
      #if DEBUG
      let before = $0.latest?[.player1], after = result[.player1]
      if before?.state != after.state || before?.reason != after.reason || before?.requiresRebind != after.requiresRebind {
        print(String(format: "[LaserTrack] t %.3f · frame %llu · P1 %@/%@ → %@/%@%@ · age %.0f ms · gap %.0f ms · candidate %@",
                     time, source.frameID, before?.state.rawValue ?? "-", before?.reason.rawValue ?? "-",
                     after.state.rawValue, after.reason.rawValue, after.requiresRebind ? " REBIND" : "",
                     (time - source.capturedAt) * 1000, $0.lastCapture.map { (source.capturedAt - $0) * 1000 } ?? -1,
                     after.candidateID.map { "\($0)" } ?? "none"))
      }
      #endif
      let roster = $0.body.configuration?.roster ?? PlayerID.allCases
      if roster.contains(where: { result[$0].state != .tracking || result[$0].requiresRebind }) {
        $0.body.calibration.uncertain()
        #if DEBUG
        if $0.anatomyInspection.frame == nil { $0.anatomyInspection.invalidate() }
        #endif
      }
      commit() // LINEARIZATION: authoritative worker assignment inside the revocation critical section.
      $0.latest = result
      $0.lastFrame = source.frameID
      $0.lastCapture = source.capturedAt
      $0.mutualCoreCount = mutualCoreCount
      $0.captureToCommitAge = time - source.capturedAt
      $0.reason = "source accepted"
      increment(&$0.accepted)
      if roster.contains(where: { result[$0].state != .tracking }) {
        increment(&$0.refusals)
      } else if $0.acknowledgment == nil {
        $0.acknowledgment = .init(requestID: request, source: original,
          player1: result.player1, player2: result.player2)
        $0.lastBoundGeneration = source.context.generation
        increment(&$0.acknowledgments)
      }
      schedule(&$0, result: result, at: time)
      return true
    }
  }
  /// Worker-only synchronous control/expiry application, under the SAME lock as publication.
  func synchronize(_ apply: (CameraTrackingControl) throws -> PlayerTrackingSnapshot?) {
    state.withLock {
      expire(&$0, at: now())
      let result: PlayerTrackingSnapshot?
      do {
        result = try apply(.init(revision: $0.revision, requestID: $0.requestID,
          watermark: $0.watermark))
      } catch { increment(&$0.rejected); return }
      if let result, $0.active, $0.requestID != nil,
        result.controlRevision == $0.revision {
        $0.latest = result
        schedule(&$0, result: result, at: now())
      }
    }
  }
  private func schedule(_ s: inout State, result: PlayerTrackingSnapshot, at time: Double) {
    let slots = [result.player1, result.player2]
    var deadlines = slots.filter { $0.state != .lost }.compactMap(\.lastConfirmedAt)
      .flatMap { [$0 + policy.freshness, $0 + policy.recoveryWindow] }
      .filter { $0 > time }
    if result.provisionalDescriptorCount > 0, slots.allSatisfy({ $0.state == .unbound }),
      let source = result.source {
      let acquisitionExpiry = (source.capturedAt + policy.maximumObservationGap).nextUp
      if acquisitionExpiry > time { deadlines.append(acquisitionExpiry) }
    }
    s.deadline = deadlines.min()
    programTimer(&s, at: time)
  }
  private func programTimer(_ s: inout State, at time: Double) {
    var deadlines = [s.deadline, s.body.calibration.nextDeadline]
    #if DEBUG
    deadlines.append(s.anatomyInspection.ticket?.expiresAt)
    #endif
    if let deadline = deadlines.compactMap({ $0 }).min() {
      s.timer?.schedule(deadline: .now() + max(0, deadline - time))
    } else { s.timer?.schedule(deadline: .distantFuture) }
  }
  /// Timer and deterministic tests use the same path. Does not wait for Vision or mutate the core.
  func expireDue() { expireDue(at: now()) }
  func expireDue(at time: Double) {
    state.withLock { expire(&$0, at: time) }
  }
  private func expire(_ s: inout State, at time: Double) {
    guard time.isFinite else { return }
    #if DEBUG
    if let ticket = s.anatomyInspection.ticket,
      time >= ticket.expiresAt || s.context != ticket.calibration.source
        || s.revision != ticket.calibration.bindingRevision || s.requestID != ticket.calibration.bindingRequest
        || s.body.acceptedRevision != ticket.acceptedRevision || !s.active || !s.foreground || s.body.stopped {
      s.anatomyInspection.invalidate()
    }
    #endif
    let old = s.body.calibration.phase
    s.body.calibration.expire(at: time)
    if old != s.body.calibration.phase { s.body.wake?.yield(()) }
    defer { programTimer(&s, at: time) }
    guard time.isFinite, let deadline = s.deadline, time >= deadline,
      s.active, s.requestID != nil else { return }
    s.presentation.invalidate()
    #if DEBUG
    if s.anatomyInspection.frame == nil { s.anatomyInspection.invalidate() }
    #endif
    #if DEBUG
    print(String(format: "[LaserTrack] t %.3f · no committed frame by the deadline: tracking EXPIRED (last capture %.0f ms ago, %llu stale rejected)",
                 time, s.lastCapture.map { (time - $0) * 1000 } ?? -1, s.staleRejected))
    #endif
    s.body.calibration.uncertain()
    s.body.measurements.invalidate()
    s.body.latest = nil; s.body.wrists = nil
    s.body.wake?.yield(())
    s.watermark = max(s.watermark, time)
    s.latest = nil
    s.reason = "expired — worker application pending"
    s.deadline = nil
    s.timer?.schedule(deadline: .distantFuture)
    increment(&s.expiries)
    s.wake?.yield(())
  }

  // E03-E06 additions never call FrameStore, inference, lifecycle APIs or client callbacks in lock.
  private func pairEligible(_ s: State) -> Bool {
    guard s.active, s.foreground, s.requestID != nil, s.acknowledgment != nil,
      let pair = s.latest, pair.controlRevision == s.revision else { return false }
    return (s.body.configuration?.roster ?? PlayerID.allCases).allSatisfy {
      pair[$0].state == .tracking && !pair[$0].requiresRebind
    }
  }
  // CameraPipeline reserves/releases this lease only at fully drained capture boundaries.
  // It does not reset B2 control/request serials or the worker's retained-generation guard.
  func reserveBodySession(_ owner: UUID) throws {
    try state.withLock {
      guard $0.bodySessionOwner == nil, $0.body.configuration == nil, $0.body.stopped,
        !$0.active, $0.context == nil else { throw BodyInputOperationError.configurationChanged }
      revoke(&$0)
      $0.presentation.endSession()
      $0.bodySessionOwner = owner
    }
  }
  func stopBodySession(_ owner: UUID) {
    state.withLock {
      guard $0.bodySessionOwner == owner else { return }
      revoke(&$0)
      $0.presentation.endSession()
      stopBody(&$0)
    }
  }
  func releaseBodySession(_ owner: UUID) -> Bool {
    state.withLock {
      guard $0.bodySessionOwner == owner, !$0.active, $0.context == nil,
        $0.body.stopped else { return false }
      var calibration = $0.body.calibration
      calibration.resetForNewSession()
      $0.body = LiveBodyInputState()
      $0.body.calibration = calibration
      $0.bodySessionOwner = nil
      return true
    }
  }
  func configureBody(_ configuration: BodyInputConfiguration, session: UUID? = nil) throws {
    try state.withLock {
      guard $0.bodySessionOwner == session, $0.active, $0.foreground, let context = $0.context else { throw LiveVisionError.inactiveSource }
      try $0.body.configure(configuration, source: context, at: now())
    }
  }
  func bodyWake(_ wake: AsyncStream<Void>.Continuation) { state.withLock { $0.body.wake = wake } }
  private func stopBody(_ s: inout State) {
    #if DEBUG
    s.anatomyInspection.invalidate()
    #endif
    s.presentation.invalidate()
    s.body.invalidate(at: now()); s.body.subscription = nil
    s.body.continuation?.finish(); s.body.continuation = nil
    s.body.delivery = .closed; s.body.stopped = true
    s.body.wake?.finish(); s.body.wake = nil
  }
  private func wristContext(_ s: State) -> WristContactContextV1? {
    guard s.active, s.foreground, !s.body.stopped, s.body.source == s.context,
      let source = s.context, let request = s.requestID, let ack = s.acknowledgment,
      ack.requestID == request, ack.source.context.generation == source.generation,
      ack.source.context.epoch == source.epoch, ack.source.context.geometryRevision == source.geometryRevision,
      ack.source.controlRevision == s.revision else { return nil }
    return .init(sourceEpoch:source.epoch,controlRevision:s.revision,bindingRequestID:request,
      bindingFrameID:ack.source.frameID,bindingCapturedAt:ack.source.capturedAt,
      acceptedContextRevision:s.body.acceptedRevision,freshness:policy.freshness)
  }
  func readBody() -> LiveBodyInputRead {
    state.withLock {
      let time = now(); expire(&$0, at: time); $0.body.calibration.expire(at: time)
      $0.body.reapSubscription()
      let active = $0.active && $0.foreground && !$0.body.stopped && $0.context == $0.body.source
      let latest = $0.body.latest.flatMap { snapshot -> BodySnapshot? in
        guard active, time >= snapshot.capturedAt, time - snapshot.capturedAt < policy.freshness else { return nil }
        return snapshot
      }
      let status: BodyInputStatus = $0.body.terminalFailure.map { .failed($0) }
        ?? ($0.body.configuration == nil || $0.body.stopped ? .stopped : active ? .running : .interrupted(.system))
      return .init(context: $0.body.context(active: active, wristContact: wristContext($0)), latest: latest, status: status,
        diagnostics: $0.body.diagnostics, delivery: $0.body.delivery,
        calibration: $0.body.calibration.progress, acceptedRevision: $0.body.acceptedRevision,
        progress: $0.body.progress(at: time), wrists: latest == nil ? nil : $0.body.wrists, measurements: active ? $0.body.measurements.latest.flatMap {
          time >= $0.source.capturedAt && time - $0.source.capturedAt < policy.freshness ? $0 : nil
        } : nil)
    }
  }
  /// Read-only copy of the accepted standing references (empty until acceptance).
  func acceptedBodyCalibrations() -> [PlayerID: PlayerCalibration] {
    state.withLock { $0.body.stopped ? [:] : $0.body.configuration?.calibrations ?? [:] }
  }
  func requestCalibration(id: UUID) throws -> CalibrationRequest {
    try state.withLock {
      let time = now(); expire(&$0, at: time)
      guard pairEligible($0), let source = $0.context, let request = $0.requestID,
        $0.body.source == source, $0.body.configuration != nil else { throw LiveVisionError.inactiveSource }
      let prior = $0.body.calibration.admission?.request
      let result = try $0.body.calibration.request(id: id, source: source, revision: $0.revision,
        bindingRequest: request, at: time, roster: $0.body.configuration?.roster ?? PlayerID.allCases)
      if result != prior {
        $0.body.measurements.invalidate()
        #if DEBUG
        $0.anatomyInspection.invalidate()
        #endif
      }
      programTimer(&$0, at: time); $0.body.wake?.yield(())
      return result
    }
  }
  func cancelCalibration(_ request: CalibrationRequest) {
    state.withLock {
      guard $0.body.calibration.admission?.request == request else { return }
      $0.body.measurements.invalidate()
      #if DEBUG
      $0.anatomyInspection.invalidate()
      #endif
      $0.body.calibration.invalidate("Explicit calibration cancel"); $0.body.wake?.yield(())
      programTimer(&$0, at: now())
    }
  }
  func beginMask(pose: CameraPoseResult, admission: CameraTrackingAdmission,
    receipt: PlayerTrackingSnapshot) -> Bool {
    state.withLock {
      let time = now(); expire(&$0, at: time)
      guard pairEligible($0), $0.latest == receipt, $0.lastFrame == pose.source.frameID,
        $0.context == pose.source.context, admission.revision == $0.revision,
        admission.requestID == $0.requestID, let stamp = admission.calibration else { return false }
      let admitted = $0.body.calibration.beginSample(stamp, source: pose.source, at: time)
      if admitted { $0.body.measurements.noteMaskRequest(pose.source) }
      return admitted
    }
  }
  func finishMask(_ observation: PersonMaskObservation, pose: CameraPoseResult,
    admission: CameraTrackingAdmission, receipt: PlayerTrackingSnapshot) {
    state.withLock {
      let time = now()
      #if DEBUG
      if let stamp = admission.calibration, $0.body.calibration.admission == stamp,
        admission.context == pose.source.context, $0.context == pose.source.context,
        $0.active, $0.foreground, admission.revision == $0.revision,
        admission.requestID == $0.requestID, $0.latest == receipt,
        $0.lastFrame == pose.source.frameID, observation.source == pose.source {
        $0.visionPreviewMask = .init(source: pose.source, bindingRevision: admission.revision,
          calibrationRequest: stamp.request.id, quality: observation.quality,
          supportedRegions: observation.regions.count, reportedOutputBytes: observation.outputBytes,
          serviceSeconds: observation.serviceSeconds)
      }
      #endif
      // A slow optional call cannot erase its STOP/REVIEW latch merely by becoming too old
      // to contribute calibration evidence. This never publishes the stale observation.
      if let stamp = admission.calibration, $0.context == pose.source.context,
        admission.revision == $0.revision, admission.requestID == $0.requestID,
        observation.serviceSeconds > StandingCollectionPolicyV1.serviceTripwire {
        $0.body.calibration.stopForReview(stamp)
        #if DEBUG
        $0.anatomyInspection.invalidate()
        #endif
      }
      expire(&$0, at: time)
      guard pairEligible($0), $0.latest == receipt, $0.lastFrame == pose.source.frameID,
        $0.context == pose.source.context, admission.context == pose.source.context,
        admission.revision == $0.revision, admission.requestID == $0.requestID,
        let stamp = admission.calibration, $0.body.calibration.admission == stamp,
        time >= pose.source.capturedAt, time - pose.source.capturedAt < policy.freshness,
        pose.source.capturedAt >= $0.watermark else { return }
      $0.body.calibration.observe(observation, pose: pose, association: receipt, stamp: stamp, at: time)
      $0.body.wake?.yield(())
      programTimer(&$0, at: time)
    }
  }
  #if DEBUG
  func readVisionPreviewMask() -> VisionPreviewMaskRead {
    state.withLock {
      let time = now()
      let fresh = $0.visionPreviewMask.map {
        time >= $0.source.capturedAt && time - $0.source.capturedAt < policy.freshness
      } ?? false
      return .init(last: $0.visionPreviewMask, isCurrentSourceAndFresh: fresh && $0.active
        && $0.foreground && $0.visionPreviewMask?.source.context == $0.context
        && $0.visionPreviewMask?.bindingRevision == $0.revision)
    }
  }
  #endif
  /// Final numeric experiment commit; primary CP1/B2 publication remains before optional masks.
  func publishMeasurements(_ pose: CameraPoseResult, admission: CameraTrackingAdmission,
    receipt: PlayerTrackingSnapshot?, mask: PersonMaskObservation?) {
    state.withLock {
      let time = now(); expire(&$0, at: time)
      guard !$0.body.stopped, $0.active, $0.foreground, $0.body.source == pose.source.context,
        $0.context == pose.source.context, admission.context == pose.source.context,
        admission.revision == $0.revision, admission.requestID == $0.requestID,
        time.isFinite, time >= pose.source.capturedAt, time - pose.source.capturedAt < policy.freshness,
        pose.source.capturedAt >= $0.watermark else { return }
      if admission.requestID != nil {
        guard let receipt, $0.latest == receipt, $0.lastFrame == pose.source.frameID else { return }
      }
      let currentCalibration = $0.body.calibration.admission
      let eligibleMask = mask.flatMap { value -> PersonMaskObservation? in
        guard let stamp = admission.calibration, currentCalibration == stamp,
          stamp.source == pose.source.context, stamp.bindingRevision == admission.revision,
          stamp.bindingRequest == admission.requestID, value.source == pose.source else { return nil }
        return value
      }
      $0.body.measurements.process(pose: pose, association: receipt, controlRevision: admission.revision,
        acceptedContextRevision: $0.body.acceptedRevision,
        calibrations: $0.body.configuration?.calibrations ?? [:], mask: eligibleMask)
    }
  }
  #if DEBUG
  /// Explicit DEBUG intent only. It cannot start calibration, arm B2 or create an acknowledgment.
  @discardableResult func requestAnatomyInspection() throws -> UUID {
    try state.withLock {
      let time = now(); expire(&$0, at: time)
      guard pairEligible($0), !$0.body.stopped, $0.body.source == $0.context,
        let stamp = $0.body.calibration.admission,
        stamp.source == $0.context, stamp.bindingRevision == $0.revision,
        stamp.bindingRequest == $0.requestID,
        $0.body.calibration.phase == .collecting || $0.body.calibration.phase == .waitingForReliablePair,
        let deadline = $0.body.calibration.inspectionRequestDeadline else { throw AnatomyInspectionError.inactive }
      let id = try $0.anatomyInspection.request(calibration: stamp,
        acceptedRevision: $0.body.acceptedRevision, at: time, deadline: deadline,
        ownedBytes: anatomyInspectionBudget.usage.bytes)
      programTimer(&$0, at: time)
      return id
    }
  }
  func beginAnatomyInspection(pose: CameraPoseResult, admission: CameraTrackingAdmission,
    receipt: PlayerTrackingSnapshot) -> AnatomyInspectionTicket? {
    state.withLock {
      let time = now(); expire(&$0, at: time)
      guard pairEligible($0), !$0.body.stopped, $0.context == pose.source.context,
        $0.latest == receipt, $0.lastFrame == pose.source.frameID,
        admission.context == pose.source.context, admission.revision == $0.revision,
        admission.requestID == $0.requestID, admission.acceptedBodyRevision == $0.body.acceptedRevision,
        admission.calibration == $0.body.calibration.admission else { return nil }
      return $0.anatomyInspection.begin(admission.anatomyInspection, calibration: admission.calibration,
        source: pose.source, at: time)
    }
  }
  func finishAnatomyInspection(_ ticket: AnatomyInspectionTicket, pose: CameraPoseResult,
    admission: CameraTrackingAdmission, receipt: PlayerTrackingSnapshot,
    mask: PersonMaskObservation, images: AnatomyInspectionImageBuilder, image: CGImage?, cancelled: Bool = false) {
    state.withLock { state in
      let time = now(); expire(&state, at: time)
      defer { state.anatomyInspection.ended(ticket.id) }
      guard !cancelled, pairEligible(state), !state.body.stopped, state.context == pose.source.context,
        admission.context == pose.source.context, admission.revision == state.revision,
        admission.requestID == state.requestID, admission.acceptedBodyRevision == state.body.acceptedRevision,
        admission.calibration == ticket.calibration, admission.anatomyInspection == ticket.id,
        state.body.calibration.admission == ticket.calibration,
        state.body.calibration.phase != .stoppedForReview,
        state.latest == receipt, state.lastFrame == pose.source.frameID, pose.matchesSource,
        mask.source == pose.source, images.source == pose.source,
        mask.serviceSeconds.isFinite, mask.serviceSeconds >= 0,
        mask.serviceSeconds <= StandingCollectionPolicyV1.serviceTripwire,
        let ack = state.acknowledgment, ack.requestID == ticket.calibration.bindingRequest else { return }
      var players: [PlayerID: AnatomyInspectionPlayer] = [:]
      for id in PlayerID.allCases {
        guard let candidate = pose.frame.candidates.first(where: { $0.candidateID == receipt[id].candidateID }) else { return }
        let raw = mask.anatomy[id]
        let anatomy = raw.flatMap { value in
          value.source == pose.source && value.controlRevision == admission.revision
            && value.candidateID == candidate.candidateID ? value : nil
        }
        let region = mask.regions[id].flatMap { $0.candidateID == candidate.candidateID ? $0 : nil }
        players[id] = .init(candidateID: candidate.candidateID, tracking: receipt[id], joints: candidate.joints, region: region, anatomy: anatomy)
      }
      let value = AnatomyInspectionFrame(ticket: ticket, source: pose.source, acknowledgment: ack,
        players: players, image: image, mask: images.mask, nativeWidth: images.width,
        nativeHeight: images.height, nativeStride: images.stride, nativeFormat: images.format,
        quality: mask.quality, serviceSeconds: mask.serviceSeconds)
      _ = state.anatomyInspection.finish(value, at: time)
      programTimer(&state, at: time)
    }
  }
  func readAnatomyInspection() -> AnatomyInspectionState {
    state.withLock { expire(&$0, at: now()); return $0.anatomyInspection }
  }
  func markAnatomyReference(_ reference: AnatomyInspectionReference) throws {
    try state.withLock {
      expire(&$0, at: now())
      guard now().isFinite, $0.active, $0.foreground, !$0.body.stopped else { throw AnatomyInspectionError.inactive }
      try $0.anatomyInspection.mark(reference)
    }
  }
  func setAnatomyReferenceRegion(inspection: UUID, source: CameraFrameMetadata, player: PlayerID,
    candidateID: UInt64, a: AnatomyInspectionPoint, b: AnatomyInspectionPoint) throws {
    try state.withLock {
      expire(&$0, at: now())
      guard now().isFinite, $0.active, $0.foreground, !$0.body.stopped else { throw AnatomyInspectionError.inactive }
      try $0.anatomyInspection.setRegion(inspection: inspection, source: source, player: player,
        candidateID: candidateID, a: a, b: b)
    }
  }
  func revealAnatomyComparisons() throws {
    try state.withLock {
      expire(&$0, at: now())
      guard now().isFinite, $0.active, $0.foreground, !$0.body.stopped else { throw AnatomyInspectionError.inactive }
      try $0.anatomyInspection.reveal()
    }
  }
  func discardAnatomyInspection() {
    state.withLock { $0.anatomyInspection.discard(); programTimer(&$0, at: now()) }
  }
  #endif

  func attachPresentation() throws -> VisionPoseAttachment {
    try state.withLock { try $0.presentation.attach() }
  }
  func cancelPresentation(_ lease: VisionPoseAttachment) {
    state.withLock { $0.presentation.cancel(lease) }
  }
  func drainPresentation(_ lease: VisionPoseAttachment) -> VisionNumericPoseDrain? {
    state.withLock {
      let time = now(); expire(&$0, at: time)
      return $0.presentation.drain(lease, time: time, freshness: policy.freshness,
        controlRevision: $0.revision, body: $0.body)
    }
  }
  func publishPresentation(_ pose: CameraPoseResult, admission: CameraTrackingAdmission,
    receipt: PlayerTrackingSnapshot) {
    state.withLock {
      let time = now(); expire(&$0, at: time)
      guard $0.active, $0.foreground, $0.context == pose.source.context,
        admission.context == pose.source.context, admission.revision == $0.revision,
        let request = admission.requestID, request == $0.requestID,
        $0.latest == receipt, $0.lastFrame == pose.source.frameID,
        time.isFinite, time >= pose.source.capturedAt, time - pose.source.capturedAt < policy.freshness,
        pose.source.capturedAt >= $0.watermark else { return }
      $0.presentation.publish(pose, receipt: receipt, admission: admission, body: $0.body)
    }
  }
  func publishBody(_ pose: CameraPoseResult, admission: CameraTrackingAdmission,
    receipt: PlayerTrackingSnapshot?) {
    state.withLock {
      let time = now(); expire(&$0, at: time)
      guard $0.active, $0.foreground, $0.context == pose.source.context,
        admission.context == pose.source.context, admission.revision == $0.revision,
        admission.requestID == $0.requestID, pose.matchesSource,
        time.isFinite, time >= pose.source.capturedAt, time - pose.source.capturedAt < policy.freshness,
        pose.source.capturedAt >= $0.watermark else { return }
      if admission.requestID != nil {
        guard let receipt, $0.latest == receipt, $0.lastFrame == pose.source.frameID else { return }
      }
      $0.body.publish(pose, association: receipt, admission: admission, acknowledgment: $0.acknowledgment)
    }
  }
  func acceptBodyCandidate(_ id: UUID, expectedRevision: UInt64) throws -> BodyInputContext {
    try state.withLock {
      let time = now(); expire(&$0, at: time)
      guard pairEligible($0), let stamp = $0.body.calibration.admission,
        stamp.source == $0.context, stamp.bindingRevision == $0.revision,
        stamp.bindingRequest == $0.requestID else { throw LiveVisionError.staleEvidence }
      _ = try $0.body.accept(candidateID: id, expectedRevision: expectedRevision, at: time)
      #if DEBUG
      $0.anatomyInspection.invalidate()
      #endif
      $0.presentation.invalidate()
      programTimer(&$0, at: time)
      return $0.body.context(active: true, wristContact: wristContext($0))!
    }
  }
  func replaceBodyCalibrations(_ values: [PlayerID: PlayerCalibration], generation: UUID) throws -> BodyInputContext {
    try state.withLock {
      guard $0.active, $0.foreground, $0.context == $0.body.source,
        let config = $0.body.configuration else { throw BodyInputOperationError.notRunning }
      guard config.sessionGeneration == generation else { throw BodyInputOperationError.wrongGeneration }
      for (id, value) in values {
        guard config.calibrations[id] == value else { throw LiveVisionError.unsupportedAnatomy }
      }
      if values != config.calibrations {
        guard $0.body.acceptedRevision < .max else { throw LiveVisionError.revisionExhausted }
        for id in PlayerID.allCases where values[id] != config.calibrations[id] {
          $0.body.cutovers[id] = .init(frameID: $0.body.lastAdmission?.frameID ?? 0, capturedAt: now())
        }
        $0.body.configuration = config.replacingCalibrations(values)
        $0.presentation.invalidate()
        $0.body.acceptedRevision += 1; $0.body.latest = nil; $0.body.wrists = nil; $0.body.wake?.yield(())
      }
      return $0.body.context(active: true, wristContact: wristContext($0))!
    }
  }
  func bodyStream(generation: UUID) throws -> AsyncStream<BodySnapshot> {
    try state.withLock {
      guard !$0.body.stopped, let config = $0.body.configuration, config.sessionGeneration == generation else {
        throw BodyInputOperationError.wrongGeneration
      }
      $0.body.reapSubscription()
      guard $0.body.delivery != .claimed else { throw BodyInputOperationError.consumerAlreadyClaimed }
      let pair = AsyncStream<BodySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(config.snapshotBufferCapacity))
      let signal = LiveBodySubscriptionSignal()
      let wake = $0.body.wake
      pair.continuation.onTermination = { termination in
        switch termination {
        case .cancelled: signal.finish(.cancelled)
        case .finished: signal.finish(.finished)
        @unknown default: signal.finish(.finished)
        }
        wake?.yield(()) // no source-gate entry, callbacks or tasks under yield/finish
      }
      $0.body.subscription = signal
      $0.body.continuation = pair.continuation; $0.body.delivery = .claimed
      return pair.stream
    }
  }
  func releaseBodyStream(generation: UUID) throws {
    try state.withLock {
      guard $0.body.configuration?.sessionGeneration == generation else { throw BodyInputOperationError.wrongGeneration }
      $0.body.reapSubscription()
      if $0.body.delivery != .closed {
        $0.body.subscription = nil
        $0.body.continuation?.finish(); $0.body.continuation = nil; $0.body.delivery = .closed
        $0.body.diagnostics.terminated(.released)
      }
    }
  }
  var snapshot: CameraTrackingDiagnostics {
    state.withLock {
      expire(&$0, at: now())
      return .init(policyVersion: policyVersion, revision: $0.revision,
        requestID: $0.requestID, acknowledgment: $0.acknowledgment, latest: $0.latest,
        reason: $0.reason, accepted: $0.accepted, rejected: $0.rejected,
        staleRejected: $0.staleRejected, captureToCommitAge: $0.captureToCommitAge,
        refusals: $0.refusals, expiries: $0.expiries, invalidations: $0.invalidations,
        acknowledgments: $0.acknowledgments, mutualCoreCount: $0.mutualCoreCount,
        watermark: $0.watermark)
    }
  }
}
