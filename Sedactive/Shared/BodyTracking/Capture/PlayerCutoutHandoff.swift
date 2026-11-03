import Foundation

nonisolated struct CutoutConsumerToken: Hashable, Sendable {
  fileprivate let id: UUID
  let sessionGeneration: UUID
}
nonisolated struct CutoutLeaseToken: Hashable, Sendable { fileprivate let id: UUID }
nonisolated struct CutoutLease: Sendable {
  let token: CutoutLeaseToken
  let consumer: CutoutConsumerToken
  let frame: PlayerCutoutFrame
  /// Available slots compatible at acquisition. Recheck isCurrent after suspension.
  let availablePlayers: Set<PlayerID>
}
nonisolated struct CutoutFreshnessPolicy: Sendable, Equatable {
  let maximumCaptureAge: Double?
  init(maximumCaptureAge: Double? = nil) throws {
    if let maximumCaptureAge {
      try requireCutout(maximumCaptureAge.isFinite && maximumCaptureAge >= 0, "capture age")
    }
    self.maximumCaptureAge = maximumCaptureAge
  }
  func accepts(_ snapshot: BodySnapshot, at now: Double) -> Bool {
    now.isFinite && now >= snapshot.capturedAt
      && (maximumCaptureAge.map { now - snapshot.capturedAt <= $0 } ?? true)
  }
}
nonisolated struct CutoutHandoffState: Sendable, Equatable {
  let revision: UInt64
  let input: BodyInputStatusEvent?
  let consumer: CutoutConsumerToken?
}
nonisolated enum CutoutHandoffEvent: Sendable {
  case state(CutoutHandoffState)
  case imageAvailable
}
nonisolated struct CutoutHandoffDiagnostics: Sendable {
  private(set) var superseded: UInt64 = 0
  private(set) var rejected: UInt64 = 0
  private(set) var released: UInt64 = 0
  mutating func supersede() { if superseded < .max { superseded += 1 } }
  mutating func reject() { if rejected < .max { rejected += 1 } }
  mutating func release() { if released < .max { released += 1 } }
}
@MainActor protocol PlayerCutoutProviding: AnyObject {
  var state: CutoutHandoffState { get }
  func claimConsumer(generation: UUID) throws -> CutoutConsumerToken
  func acquireLatest(_ consumer: CutoutConsumerToken, at now: Double) throws -> CutoutLease?
  func isCurrent(_ lease: CutoutLease, playerID: PlayerID, at now: Double) -> Bool
  @discardableResult func release(_ token: CutoutLeaseToken) throws -> Bool
  @discardableResult func releaseConsumer(_ token: CutoutConsumerToken) throws -> Bool
  func observe(_ callback: @escaping @MainActor (CutoutHandoffEvent) -> Void) throws -> UUID
  func removeObserver(_ token: UUID) throws
}

/// CPU handoff only. No image processing, Metal, RealityKit, gameplay stream, task queue or timer.
@MainActor final class PlayerCutoutHandoff: PlayerCutoutProviding {
  private let budget: CutoutMemoryBudget
  private let freshness: CutoutFreshnessPolicy
  private var input: BodyInputStatusEvent?
  private var consumer: CutoutConsumerToken?
  private var pending: PlayerCutoutFrame?
  private var acquired: CutoutLease?
  private var watermark: UInt64?
  private var revision: UInt64 = 0
  private var observer: (id: UUID, callback: @MainActor (CutoutHandoffEvent) -> Void)?
  private var notifying = false
  private(set) var diagnostics = CutoutHandoffDiagnostics()
  var state: CutoutHandoffState {
    CutoutHandoffState(revision: revision, input: input, consumer: consumer)
  }
  var hasPendingFrame: Bool { pending != nil }
  var hasAcquiredFrame: Bool { acquired != nil }
  init(budget: CutoutMemoryBudget, freshness: CutoutFreshnessPolicy) {
    self.budget = budget
    self.freshness = freshness
  }
  private func control() throws { if notifying { throw CutoutError.reentrantControl } }
  private var running: Bool { input?.status == .running && input?.context?.isActive == true }
  private func emit(_ event: CutoutHandoffEvent) {
    guard let callback = observer?.callback else { return }
    notifying = true
    defer { notifying = false }
    callback(event)
  }
  private func changed() {
    if revision < .max { revision += 1 }
    emit(.state(state))
  }
  /// Called by the authoritative input owner/internal tee, NOT by a second CP1 status subscriber.
  /// Source revisions must remain monotonic across restart, just as the existing CP1 status contract.
  func updateInput(_ event: BodyInputStatusEvent) throws {
    try control()
    try requireCutout(event.occurredAt.isFinite && event.occurredAt >= 0, "input timestamp")
    if let previous = input {
      if previous == event { return }
      guard event.statusRevision > previous.statusRevision else {
        throw CutoutError.staleInputEvent
      }
    }
    if let context = event.context {
      try requireCutout(
        event.sessionGeneration == context.sessionGeneration
          && context.cameraGeometryRevision > 0
          && context.calibrationRevisions.values.allSatisfy { $0 > 0 }
          && Set(context.cutovers.keys).isSubset(of: Set(context.calibrationRevisions.keys))
          && context.cutovers.values.allSatisfy { $0.capturedAt.isFinite && $0.capturedAt >= 0 },
        "input context")
    }
    if event.status == .running {
      try requireCutout(event.context?.isActive == true, "running context")
    }
    let generationChanged = input?.sessionGeneration != event.sessionGeneration
    let cameraChanged =
      input?.context?.cameraGeometryRevision != event.context?.cameraGeometryRevision
    input = event
    if generationChanged {
      watermark = nil
      consumer = nil
    }
    if generationChanged || cameraChanged || !running {
      pending = nil
      acquired = nil
    } else if let pending, !compatibleEnvelope(pending) {
      self.pending = nil
    }
    if event.status == .stopped { consumer = nil }
    changed()
    if pending != nil { emit(.imageAvailable) }
  }
  private func compatible(_ frame: PlayerCutoutFrame, playerID: PlayerID) -> Bool {
    guard running, let context = input?.context,
      context.calibrationRevisions[playerID] != nil,
      frame.bodySnapshot.players[playerID]?.trackingStatus == .reliable,
      context.accepts(frame.bodySnapshot, playerID: playerID),
      case .available = frame.players[playerID]
    else { return false }
    return true
  }
  private func compatibleEnvelope(_ frame: PlayerCutoutFrame, at now: Double? = nil) -> Bool {
    guard running, let context = input?.context,
      frame.bodySnapshot.sessionGeneration == context.sessionGeneration,
      frame.bodySnapshot.cameraGeometryRevision == context.cameraGeometryRevision,
      now.map({ freshness.accepts(frame.bodySnapshot, at: $0) }) ?? true
    else { return false }
    var hasImage = false
    for (id, slot) in frame.players {
      if case .available = slot {
        hasImage = true
        if compatible(frame, playerID: id) { return true }
      }
    }
    return !hasImage  // Explicit no-image outcomes are deliverable before both calibrations exist.
  }
  /// Bounded synchronous offer: latest pending + one acquired pair. Pixel copies happen elsewhere.
  func offer(_ frame: PlayerCutoutFrame, at now: Double) throws {
    try control()
    do {
      guard compatibleEnvelope(frame, at: now) else { throw CutoutError.incompatibleContext }
      if let watermark, frame.bodySnapshot.frameID <= watermark {
        throw CutoutError.staleObservation
      }
      for slot in frame.players.values {
        if case .available(let image, _) = slot, image.budgetID != budget.id {
          throw CutoutError.foreignBudget
        }
      }
      let notify = pending == nil
      if pending != nil { diagnostics.supersede() }
      watermark = frame.bodySnapshot.frameID
      pending = frame
      if notify { emit(.imageAvailable) }
    } catch {
      diagnostics.reject()
      throw error
    }
  }
  func claimConsumer(generation: UUID) throws -> CutoutConsumerToken {
    try control()
    guard running, generation == input?.sessionGeneration else { throw CutoutError.notRunning }
    guard consumer == nil else { throw CutoutError.consumerAlreadyClaimed }
    let token = CutoutConsumerToken(id: UUID(), sessionGeneration: generation)
    consumer = token
    changed()
    if pending != nil { emit(.imageAvailable) }
    return token
  }
  func acquireLatest(_ consumer: CutoutConsumerToken, at now: Double) throws -> CutoutLease? {
    try control()
    guard self.consumer == consumer else { throw CutoutError.invalidConsumer }
    guard acquired == nil else { return nil }
    guard let frame = pending else { return nil }
    pending = nil
    guard compatibleEnvelope(frame, at: now) else {
      diagnostics.reject()
      return nil
    }
    let valid = Set(PlayerID.allCases.filter { compatible(frame, playerID: $0) })
    let lease = CutoutLease(
      token: CutoutLeaseToken(id: UUID()), consumer: consumer,
      frame: frame, availablePlayers: valid)
    acquired = lease
    return lease
  }
  /// Recheck before presentation/after every await, including a GPU completion owned by Kevin.
  func isCurrent(_ lease: CutoutLease, playerID: PlayerID, at now: Double) -> Bool {
    acquired?.token == lease.token && consumer == lease.consumer
      && freshness.accepts(lease.frame.bodySnapshot, at: now)
      && compatible(lease.frame, playerID: playerID)
  }
  @discardableResult func release(_ token: CutoutLeaseToken) throws -> Bool {
    try control()
    guard acquired?.token == token else { return false }
    acquired = nil
    diagnostics.release()
    if pending != nil { emit(.imageAvailable) }
    return true
  }
  @discardableResult func releaseConsumer(_ token: CutoutConsumerToken) throws -> Bool {
    try control()
    guard consumer == token else { return false }
    acquired = nil
    consumer = nil
    changed()
    return true
  }
  func observe(_ callback: @escaping @MainActor (CutoutHandoffEvent) -> Void) throws -> UUID {
    try control()
    guard observer == nil else { throw CutoutError.observerAlreadyRegistered }
    let id = UUID()
    observer = (id, callback)
    emit(.state(state))
    if pending != nil { emit(.imageAvailable) }
    return id
  }
  func removeObserver(_ token: UUID) throws {
    try control()
    if observer?.id == token { observer = nil }
  }
}
