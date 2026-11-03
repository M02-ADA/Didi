import Foundation
import Testing

@testable import Sedactive

@MainActor private final class CutoutCancellationGate {
  private var reader: CheckedContinuation<Void, Never>?
  private var entry: CheckedContinuation<Void, Never>?
  func block() async {
    await withCheckedContinuation {
      reader = $0
      entry?.resume()
      entry = nil
    }
  }
  func untilBlocked() async {
    if reader != nil { return }
    await withCheckedContinuation { entry = $0 }
  }
  func resume() {
    reader?.resume()
    reader = nil
  }
}

@MainActor struct CutoutLifecycleTests {
  @Test func acquiredEligibilityStaysFixedAcrossCalibrationCutoversAndNewAcquisition() async throws {
    let budget = CutoutMemoryBudget(limits: try CutoutMemoryLimits())
    let producer = try CutoutTestProducer(budget: budget)
    let channel = PlayerCutoutHandoff(budget: budget, freshness: try CutoutFreshnessPolicy())
    let first = try CutoutTestData.event()
    try channel.updateInput(first)
    let consumer = try channel.claimConsumer(generation: first.sessionGeneration!)
    try await producer.publish(CutoutTestData.snapshot(1), to: channel)
    // Replace P1's calibration before acquisition; unchanged P2 remains eligible.
    try channel.updateInput(
      CutoutTestData.event(
        2, revisions: [.player1: 2, .player2: 1],
        cutovers: [.player1: BodyInputCutover(frameID: 1, capturedAt: 2)]))
    let old = try #require(try channel.acquireLatest(consumer, at: 2))
    #expect(old.availablePlayers == [.player2])
    #expect(!channel.isCurrent(old, playerID: .player1, at: 2))
    #expect(channel.isCurrent(old, playerID: .player2, at: 2))

    try channel.updateInput(
      CutoutTestData.event(
        3, revisions: [.player1: 3, .player2: 1],
        cutovers: [.player1: BodyInputCutover(frameID: 1, capturedAt: 3)]))
    #expect(old.availablePlayers == [.player2])
    #expect(!channel.isCurrent(old, playerID: .player1, at: 3))
    #expect(channel.isCurrent(old, playerID: .player2, at: 3))
    // Only a newer capture using the accepted revision and passing both cutovers qualifies.
    try await producer.publish(
      CutoutTestData.snapshot(4, revisions: [.player1: 3, .player2: 1]), to: channel)
    try channel.release(old.token)
    let current = try #require(try channel.acquireLatest(consumer, at: 4))
    #expect(current.availablePlayers == Set(PlayerID.allCases))
    #expect(channel.isCurrent(current, playerID: .player1, at: 4))
    #expect(channel.isCurrent(current, playerID: .player2, at: 4))
    #expect(old.availablePlayers == [.player2])
    #expect(!channel.isCurrent(old, playerID: .player1, at: 4))

    // Membership never replaces the existing independent context/calibration checks.
    try channel.updateInput(
      CutoutTestData.event(
        4, revisions: [.player1: 3, .player2: 2],
        cutovers: [
          .player1: BodyInputCutover(frameID: 1, capturedAt: 3),
          .player2: BodyInputCutover(frameID: 4, capturedAt: 4),
        ]))
    #expect(channel.isCurrent(current, playerID: .player1, at: 4))
    #expect(!channel.isCurrent(current, playerID: .player2, at: 4))
    try channel.release(current.token)
  }
  @Test func generationReplacementRevokesOldClaimsAndLateRelease() async throws {
    let budget = CutoutMemoryBudget(limits: try CutoutMemoryLimits())
    let producer = try CutoutTestProducer(budget: budget)
    let channel = PlayerCutoutHandoff(budget: budget, freshness: try CutoutFreshnessPolicy())
    let first = try CutoutTestData.event()
    try channel.updateInput(first)
    let old = try channel.claimConsumer(generation: first.sessionGeneration!)
    try await producer.publish(CutoutTestData.snapshot(1), to: channel)
    let lease = try #require(try channel.acquireLatest(old, at: 1))
    let generation = UUID(uuidString: "00000000-0000-4000-8000-00000000C202")!
    try channel.updateInput(CutoutTestData.event(2, generation: generation))
    #expect(!channel.isCurrent(lease, playerID: .player1, at: 2))
    #expect(!(try channel.release(lease.token)))
    #expect(throws: CutoutError.invalidConsumer) { try channel.acquireLatest(old, at: 2) }
    await #expect(throws: CutoutError.incompatibleContext) {
      try await producer.publish(CutoutTestData.snapshot(2), to: channel)
    }
    let next = try channel.claimConsumer(generation: generation)
    try await producer.publish(CutoutTestData.snapshot(1, generation: generation), to: channel)
    let current = try #require(try channel.acquireLatest(next, at: 1))
    #expect(channel.isCurrent(current, playerID: .player1, at: 1))
    #expect(!(try channel.releaseConsumer(old)))
    try channel.release(current.token)
  }
  @Test func calibrationRemovalAndReacceptanceDoNotResurrectOldPixels() async throws {
    let budget = CutoutMemoryBudget(limits: try CutoutMemoryLimits())
    let producer = try CutoutTestProducer(budget: budget)
    let channel = PlayerCutoutHandoff(budget: budget, freshness: try CutoutFreshnessPolicy())
    let first = try CutoutTestData.event()
    try channel.updateInput(first)
    let token = try channel.claimConsumer(generation: first.sessionGeneration!)
    try await producer.publish(CutoutTestData.snapshot(1), to: channel)
    let lease = try #require(try channel.acquireLatest(token, at: 1))
    try channel.updateInput(CutoutTestData.event(2, revisions: [.player2: 1]))
    #expect(!channel.isCurrent(lease, playerID: .player1, at: 2))
    #expect(channel.isCurrent(lease, playerID: .player2, at: 2))
    try channel.updateInput(
      CutoutTestData.event(3, cutovers: [.player1: BodyInputCutover(frameID: 1, capturedAt: 1)]))
    #expect(!channel.isCurrent(lease, playerID: .player1, at: 3))
    #expect(channel.isCurrent(lease, playerID: .player2, at: 3))
    try channel.release(lease.token)
    try await producer.publish(CutoutTestData.snapshot(4), to: channel)
    let current = try #require(try channel.acquireLatest(token, at: 4))
    #expect(current.availablePlayers == Set(PlayerID.allCases))
    #expect(channel.isCurrent(current, playerID: .player1, at: 4))
    try channel.release(current.token)
  }
  @Test func pendingPacketRemainsImmutableWhenOnlyOnePlayerIsCompatible() async throws {
    let budget = CutoutMemoryBudget(limits: try CutoutMemoryLimits())
    let producer = try CutoutTestProducer(budget: budget)
    let channel = PlayerCutoutHandoff(budget: budget, freshness: try CutoutFreshnessPolicy())
    let event = try CutoutTestData.event()
    try channel.updateInput(event)
    let token = try channel.claimConsumer(generation: event.sessionGeneration!)
    try await producer.publish(CutoutTestData.snapshot(1), to: channel)
    try channel.updateInput(CutoutTestData.event(2, revisions: [.player2: 1]))
    let pending = try #require(try channel.acquireLatest(token, at: 2))
    #expect(pending.availablePlayers == [.player2])
    #expect(try CutoutTestData.image(pending.frame, .player1).source.calibrationRevision == 1)
    #expect(!channel.isCurrent(pending, playerID: .player1, at: 2))
    try channel.release(pending.token)
    // The source sequence does not restart when calibration acceptance changes.
    await #expect(throws: CutoutError.staleObservation) {
      try await producer.publish(CutoutTestData.snapshot(1), to: channel)
    }
  }
  @Test func cameraChangeInvalidatesLeaseWithoutResettingObservationIdentity() async throws {
    let budget = CutoutMemoryBudget(limits: try CutoutMemoryLimits())
    let producer = try CutoutTestProducer(budget: budget)
    let channel = PlayerCutoutHandoff(budget: budget, freshness: try CutoutFreshnessPolicy())
    let event = try CutoutTestData.event()
    try channel.updateInput(event)
    let token = try channel.claimConsumer(generation: event.sessionGeneration!)
    try await producer.publish(CutoutTestData.snapshot(5), to: channel)
    let lease = try #require(try channel.acquireLatest(token, at: 5))
    try channel.updateInput(CutoutTestData.event(2, camera: 2))
    #expect(!channel.isCurrent(lease, playerID: .player1, at: 5))
    await #expect(throws: CutoutError.staleObservation) {
      try await producer.publish(CutoutTestData.snapshot(5, camera: 2), to: channel)
    }
    try await producer.publish(CutoutTestData.snapshot(6, camera: 2), to: channel)
    let current = try #require(try channel.acquireLatest(token, at: 6))
    #expect(channel.isCurrent(current, playerID: .player1, at: 6))
    try channel.release(current.token)
  }
  @Test func independentOrderedStatusAndCurrentReplayNeedNoImages() throws {
    let channel = PlayerCutoutHandoff(
      budget: CutoutMemoryBudget(limits: try CutoutMemoryLimits()),
      freshness: try CutoutFreshnessPolicy())
    var states: [CutoutHandoffState] = []
    let observer = try channel.observe { event in
      if case .state(let state) = event { states.append(state) }
    }
    #expect(states.count == 1 && states[0].input == nil)
    #expect(throws: CutoutError.observerAlreadyRegistered) { try channel.observe { _ in } }
    let statuses: [BodyInputStatus] = [
      .starting, .running, .interrupted(.system), .failed(.cameraUnavailable), .stopped,
    ]
    for (index, status) in statuses.enumerated() {
      try channel.updateInput(CutoutTestData.event(UInt64(index + 1), status: status))
    }
    #expect(states.dropFirst().compactMap { $0.input?.status } == statuses)
    #expect(states.map(\.revision) == Array(0...5).map(UInt64.init))
    try channel.removeObserver(observer)
    var replay: CutoutHandoffState?
    let next = try channel.observe { if case .state(let state) = $0 { replay = state } }
    #expect(replay == states.last)
    try channel.removeObserver(observer)  // Old observer token cannot remove the new one.
    try channel.updateInput(CutoutTestData.event(6, status: .running))
    #expect(replay?.input?.statusRevision == 6)
    try channel.removeObserver(next)
  }
  @Test func inputValidationAndObserverReentryAreAtomic() throws {
    let channel = PlayerCutoutHandoff(
      budget: CutoutMemoryBudget(limits: try CutoutMemoryLimits()),
      freshness: try CutoutFreshnessPolicy())
    let first = try CutoutTestData.event()
    try channel.updateInput(first)
    let before = channel.state
    #expect(throws: CutoutError.staleInputEvent) {
      try channel.updateInput(CutoutTestData.event(0, status: .stopped))
    }
    #expect(channel.state == before)
    var blocked = false
    let observer = try channel.observe { _ in
      do { _ = try channel.claimConsumer(generation: first.sessionGeneration!) } catch CutoutError
        .reentrantControl
      { blocked = true } catch { Issue.record("Unexpected error: \(error)") }
    }
    #expect(blocked)
    #expect(channel.state == before)
    try channel.removeObserver(observer)
    try channel.updateInput(first)  // Exact duplicate input state is idempotent.
    #expect(channel.state == before)
  }
  @Test func explicitUnavailablePacketsCanArriveBeforeCalibration() throws {
    let budget = CutoutMemoryBudget(limits: try CutoutMemoryLimits())
    let channel = PlayerCutoutHandoff(budget: budget, freshness: try CutoutFreshnessPolicy())
    let event = try CutoutTestData.event(revisions: [:])
    try channel.updateInput(event)
    let token = try channel.claimConsumer(generation: event.sessionGeneration!)
    let body = BodySnapshot(
      sessionGeneration: event.sessionGeneration!, frameID: 1, capturedAt: 1,
      cameraGeometryRevision: 1,
      players: try Dictionary(
        uniqueKeysWithValues: PlayerID.allCases.map { ($0, try LH00TestData.unavailableSample($0)) }
      ))
    let frame = try PlayerCutoutFrame(
      bodySnapshot: body, sourceImageSizePx: CutoutImageSize(width: 8, height: 8),
      players: [.player1: .unavailable(.notCalibrated), .player2: .unavailable(.notCalibrated)])
    try channel.offer(frame, at: 1)
    let lease = try #require(try channel.acquireLatest(token, at: 1))
    #expect(lease.availablePlayers.isEmpty)
    #expect(budget.usage.bytes == 0)
    try channel.release(lease.token)
  }
  @Test func historicalStatusTimeDoesNotPretendToBeCurrentCaptureAge() async throws {
    let budget = CutoutMemoryBudget(limits: try CutoutMemoryLimits())
    let producer = try CutoutTestProducer(budget: budget)
    let channel = PlayerCutoutHandoff(
      budget: budget, freshness: try CutoutFreshnessPolicy(maximumCaptureAge: 0.5))
    let event = try CutoutTestData.event()
    try channel.updateInput(event)
    let token = try channel.claimConsumer(generation: event.sessionGeneration!)
    try await producer.publish(CutoutTestData.snapshot(10), to: channel)
    try channel.updateInput(CutoutTestData.event(2))  // Original event time 2; packet capture time 10.
    let lease = try #require(try channel.acquireLatest(token, at: 10))
    #expect(lease.frame.bodySnapshot.frameID == 10)
    try channel.release(lease.token)
  }
  @Test func cooperativeTaskCancellationReleasesClaimWithoutStoppingInput() async throws {
    let budget = CutoutMemoryBudget(limits: try CutoutMemoryLimits())
    let producer = try CutoutTestProducer(budget: budget)
    let channel = PlayerCutoutHandoff(budget: budget, freshness: try CutoutFreshnessPolicy())
    let event = try CutoutTestData.event()
    try channel.updateInput(event)
    let token = try channel.claimConsumer(generation: event.sessionGeneration!)
    try await producer.publish(CutoutTestData.snapshot(1), to: channel)
    let gate = CutoutCancellationGate()
    let task = Task { @MainActor in
      let lease = try #require(try channel.acquireLatest(token, at: 1))
      defer {
        do {
          try channel.release(lease.token)
          try channel.releaseConsumer(token)
        } catch { Issue.record("Cleanup failed: \(error)") }
      }
      await gate.block()
      try Task.checkCancellation()
    }
    await gate.untilBlocked()
    task.cancel()
    #expect(channel.hasAcquiredFrame && budget.usage.images == 2)
    gate.resume()
    do {
      try await task.value
      Issue.record("Expected cancellation")
    } catch is CancellationError {}
    #expect(!channel.hasAcquiredFrame && channel.state.consumer == nil)
    #expect(channel.state.input?.status == .running)
    #expect(budget.usage.images == 0)
  }
}
