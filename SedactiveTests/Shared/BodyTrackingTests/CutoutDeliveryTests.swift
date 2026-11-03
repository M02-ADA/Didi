import Foundation
import Testing

@testable import Sedactive

@MainActor struct CutoutDeliveryTests {
  private func requireLease(_ value: CutoutLease?) throws -> CutoutLease { try #require(value) }
  @Test func realHandoffAndIndependentSyntheticProducerWithMockConsumer() async throws {
    let budget = CutoutMemoryBudget(limits: try CutoutMemoryLimits())
    let producer = try CutoutTestProducer(budget: budget)
    let channel = PlayerCutoutHandoff(budget: budget, freshness: try CutoutFreshnessPolicy())
    let event = try CutoutTestData.event()
    try channel.updateInput(event)
    let consumer = try channel.claimConsumer(generation: event.sessionGeneration!)
    // Independent actor returns only immutable production values; no CV resource crosses executors.
    try await producer.publish(CutoutTestData.snapshot(1), to: channel)
    var lease: CutoutLease? = try requireLease(channel.acquireLatest(consumer, at: 1))
    let body = try CutoutTestData.snapshot(1)
    #expect(lease?.frame.bodySnapshot == body)
    #expect(lease?.availablePlayers == Set(PlayerID.allCases))
    for id in PlayerID.allCases {
      let image = try CutoutTestData.image(lease!.frame, id)
      #expect(
        CutoutTestData.firstPixel(image) == (id == .player1 ? [0, 0, 255, 128] : [255, 0, 0, 128]))
      #expect(channel.isCurrent(lease!, playerID: id, at: 1))
    }
    #expect(try channel.release(lease!.token))
    #expect(!channel.isCurrent(lease!, playerID: .player1, at: 1))
    lease = nil
    #expect(budget.usage.images == 0)
    #expect(try channel.releaseConsumer(consumer))
  }
  @Test func oneConsumerAndOneAcquisitionWithLatestReplacement() async throws {
    let budget = CutoutMemoryBudget(limits: try CutoutMemoryLimits())
    let producer = try CutoutTestProducer(budget: budget)
    let channel = PlayerCutoutHandoff(budget: budget, freshness: try CutoutFreshnessPolicy())
    let event = try CutoutTestData.event()
    try channel.updateInput(event)
    let consumer = try channel.claimConsumer(generation: event.sessionGeneration!)
    #expect(throws: CutoutError.consumerAlreadyClaimed) {
      try channel.claimConsumer(generation: event.sessionGeneration!)
    }
    try await producer.publish(CutoutTestData.snapshot(1), to: channel)
    var first: CutoutLease? = try requireLease(channel.acquireLatest(consumer, at: 1))
    for frame in 2...25 {
      try await producer.publish(CutoutTestData.snapshot(UInt64(frame)), to: channel)
    }
    #expect(try channel.acquireLatest(consumer, at: 25) == nil)
    #expect(channel.diagnostics.superseded == 23)
    #expect(budget.usage.images == 4)
    #expect(budget.usage.peakImages <= 6)
    #expect(budget.usage.peakBytes <= budget.limits.maximumRetainedBytes)
    try channel.release(first!.token)
    first = nil
    var latest: CutoutLease? = try requireLease(channel.acquireLatest(consumer, at: 25))
    #expect(latest?.frame.bodySnapshot.frameID == 25)
    try channel.release(latest!.token)
    latest = nil
    #expect(budget.usage.images == 0)
  }
  @Test func duplicateAndOlderCompletionsCannotRegressAfterAcquire() async throws {
    let budget = CutoutMemoryBudget(limits: try CutoutMemoryLimits())
    let producer = try CutoutTestProducer(budget: budget)
    let channel = PlayerCutoutHandoff(budget: budget, freshness: try CutoutFreshnessPolicy())
    let event = try CutoutTestData.event()
    try channel.updateInput(event)
    let token = try channel.claimConsumer(generation: event.sessionGeneration!)
    try await producer.publish(CutoutTestData.snapshot(3), to: channel)
    let lease = try #require(try channel.acquireLatest(token, at: 3))
    for old in [3, 2, 1] {
      await #expect(throws: CutoutError.staleObservation) {
        try await producer.publish(CutoutTestData.snapshot(UInt64(old)), to: channel)
      }
    }
    #expect(!channel.hasPendingFrame)
    #expect(channel.isCurrent(lease, playerID: .player1, at: 3))
    try channel.release(lease.token)
  }
  @Test func consumerReleaseDoesNotFreeDataStillRetainedByItsReader() async throws {
    let budget = CutoutMemoryBudget(
      limits: try CutoutMemoryLimits(maximumRetainedBytes: 1_000_000, maximumImages: 2))
    let producer = try CutoutTestProducer(budget: budget)
    let channel = PlayerCutoutHandoff(budget: budget, freshness: try CutoutFreshnessPolicy())
    let event = try CutoutTestData.event()
    try channel.updateInput(event)
    let token = try channel.claimConsumer(generation: event.sessionGeneration!)
    try await producer.publish(CutoutTestData.snapshot(1), to: channel)
    var held: CutoutLease? = try requireLease(channel.acquireLatest(token, at: 1))
    try channel.releaseConsumer(token)
    #expect(!channel.isCurrent(held!, playerID: .player1, at: 1))
    #expect(budget.usage.images == 2)
    await #expect(throws: CutoutError.resourcePressure) {
      try await producer.publish(CutoutTestData.snapshot(2), to: channel)
    }
    let heldToken = held!.token
    held = nil
    #expect(budget.usage.images == 0)
    let next = try channel.claimConsumer(generation: event.sessionGeneration!)
    try await producer.publish(CutoutTestData.snapshot(3), to: channel)
    let lease = try #require(try channel.acquireLatest(next, at: 3))
    #expect(!(try channel.release(heldToken)))  // Late release cannot reclaim the replacement.
    #expect(channel.isCurrent(lease, playerID: .player1, at: 3))
    try channel.release(lease.token)
  }
  @Test func cancellationBeforeAcquireAllowsSafeReattachment() async throws {
    let budget = CutoutMemoryBudget(limits: try CutoutMemoryLimits())
    let producer = try CutoutTestProducer(budget: budget)
    let channel = PlayerCutoutHandoff(budget: budget, freshness: try CutoutFreshnessPolicy())
    let event = try CutoutTestData.event()
    try channel.updateInput(event)
    let old = try channel.claimConsumer(generation: event.sessionGeneration!)
    try await producer.publish(CutoutTestData.snapshot(1), to: channel)
    try channel.releaseConsumer(old)
    #expect(channel.state.input?.status == .running)
    #expect(throws: CutoutError.invalidConsumer) { try channel.acquireLatest(old, at: 1) }
    let next = try channel.claimConsumer(generation: event.sessionGeneration!)
    #expect(!(try channel.releaseConsumer(old)))
    let lease = try #require(try channel.acquireLatest(next, at: 1))
    #expect(lease.frame.bodySnapshot.frameID == 1)
    try channel.release(lease.token)
  }
  @Test func foreignBudgetCannotBypassGlobalAdmission() async throws {
    let budget = CutoutMemoryBudget(limits: try CutoutMemoryLimits())
    let producer = try CutoutTestProducer(budget: CutoutMemoryBudget(limits: CutoutMemoryLimits()))
    let channel = PlayerCutoutHandoff(budget: budget, freshness: try CutoutFreshnessPolicy())
    try channel.updateInput(CutoutTestData.event())
    await #expect(throws: CutoutError.foreignBudget) {
      try await producer.publish(CutoutTestData.snapshot(1), to: channel)
    }
    #expect(!channel.hasPendingFrame)
    #expect(budget.usage.bytes == 0)
  }
  @Test func freshnessIsCheckedAgainAtAcquireAndAfterSuspension() async throws {
    let budget = CutoutMemoryBudget(limits: try CutoutMemoryLimits())
    let producer = try CutoutTestProducer(budget: budget)
    let channel = PlayerCutoutHandoff(
      budget: budget, freshness: try CutoutFreshnessPolicy(maximumCaptureAge: 0.5))
    let event = try CutoutTestData.event()
    try channel.updateInput(event)
    let token = try channel.claimConsumer(generation: event.sessionGeneration!)
    try await producer.publish(CutoutTestData.snapshot(1), to: channel)
    #expect(try channel.acquireLatest(token, at: 2) == nil)
    try await producer.publish(CutoutTestData.snapshot(3), to: channel)
    let lease = try #require(try channel.acquireLatest(token, at: 3))
    #expect(channel.isCurrent(lease, playerID: .player1, at: 3.5))
    #expect(!channel.isCurrent(lease, playerID: .player1, at: 3.6))
    #expect(!channel.isCurrent(lease, playerID: .player1, at: .nan))
    try channel.release(lease.token)
  }
  @Test func blockedCutoutReaderDoesNotBlockActualCP1Publication() async throws {
    let fixture = try LH00TestData.load()
    let body = try ReplayBodyInput(fixture: fixture)
    try await body.start(configuration: fixture.configuration)
    var iterator = try body.snapshotStream(generation: fixture.configuration.sessionGeneration)
      .makeAsyncIterator()
    let budget = CutoutMemoryBudget(limits: try CutoutMemoryLimits())
    let producer = try CutoutTestProducer(budget: budget)
    let channel = PlayerCutoutHandoff(budget: budget, freshness: try CutoutFreshnessPolicy())
    try channel.updateInput(CutoutTestData.event())
    let consumer = try channel.claimConsumer(generation: fixture.configuration.sessionGeneration)
    try await producer.publish(CutoutTestData.snapshot(1), to: channel)
    let held = try #require(try channel.acquireLatest(consumer, at: 1))
    try body.advance(to: 1)
    let published = try #require(await iterator.next())
    #expect(published.frameID == 1)
    #expect(channel.hasAcquiredFrame)  // CP1 progressed with no release or cutout consumption.
    try channel.release(held.token)
    try body.releaseSnapshotSubscription(generation: fixture.configuration.sessionGeneration)
  }
}
