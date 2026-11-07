import Dispatch
import Foundation
import Synchronization
import UIKit

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
    var commandPhase: CameraBindingCommandPhase = .revoked
    var restartFromGeneration: UUID?
  }
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
      return .init(context: source.context, revision: $0.revision, requestID: $0.requestID)
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
        return false
      }
      commit() // LINEARIZATION: authoritative worker assignment inside the revocation critical section.
      $0.latest = result
      $0.lastFrame = source.frameID
      $0.lastCapture = source.capturedAt
      $0.mutualCoreCount = mutualCoreCount
      $0.captureToCommitAge = time - source.capturedAt
      $0.reason = "source accepted"
      increment(&$0.accepted)
      if result.player1.state != .tracking || result.player2.state != .tracking {
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
    if let deadline = s.deadline {
      s.timer?.schedule(deadline: .now() + max(0, deadline - time))
    } else { s.timer?.schedule(deadline: .distantFuture) }
  }
  /// Timer and deterministic tests use the same path. Does not wait for Vision or mutate the core.
  func expireDue() { expireDue(at: now()) }
  func expireDue(at time: Double) {
    state.withLock { expire(&$0, at: time) }
  }
  private func expire(_ s: inout State, at time: Double) {
    guard time.isFinite, let deadline = s.deadline, time >= deadline,
      s.active, s.requestID != nil else { return }
    s.watermark = max(s.watermark, time)
    s.latest = nil
    s.reason = "expired — worker application pending"
    s.deadline = nil
    s.timer?.schedule(deadline: .distantFuture)
    increment(&s.expiries)
    s.wake?.yield(())
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
