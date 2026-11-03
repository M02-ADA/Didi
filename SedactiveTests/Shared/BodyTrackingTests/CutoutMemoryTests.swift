import Foundation
import Testing

@testable import Sedactive

nonisolated struct CutoutMemoryTests {
  @Test func copiedDataSurvivesSourceRewriteAndPoolReuse() async throws {
    let budget = CutoutMemoryBudget(limits: try CutoutMemoryLimits())
    let producer = try CutoutTestProducer(budget: budget)
    let first = try await producer.image(CutoutTestData.snapshot(1), retainSource: true)
    let stamp = CutoutTestData.firstPixel(first)
    await producer.rewriteSourcesAndRelease()
    let next = try await producer.image(CutoutTestData.snapshot(2), .player2)
    #expect(CutoutTestData.firstPixel(first) == stamp)
    #expect(CutoutTestData.firstPixel(next) == [255, 0, 0, 128])
    #expect(first.source.frameID == 1)
    #expect(budget.usage.images == 2)
  }
  @Test func paddedRowsArePreservedButPaddingBytesAreCleared() async throws {
    let producer = try CutoutTestProducer(
      budget: CutoutMemoryBudget(limits: CutoutMemoryLimits()), alignment: 4096)
    let image = try await producer.image(CutoutTestData.snapshot(1))
    #expect(image.descriptor.bytesPerRow >= 4096)
    #expect(image.byteCount == image.descriptor.bytesPerRow * 8)
    var paddingClear = true
    image.withUnsafeBytes { raw in
      for y in 0..<8 {
        for x in 32..<image.descriptor.bytesPerRow {
          if raw[y * image.descriptor.bytesPerRow + x] != 0 { paddingClear = false }
        }
      }
    }
    #expect(paddingClear)
  }
  @Test func writerFailureReleasesReservation() async throws {
    let budget = CutoutMemoryBudget(limits: try CutoutMemoryLimits())
    let producer = try CutoutTestProducer(budget: budget)
    await #expect(throws: CutoutError.self) {
      try await producer.image(CutoutTestData.snapshot(1), fail: true)
    }
    #expect(budget.usage.images == 0)
    #expect(budget.usage.bytes == 0)
  }
  @Test func sourcePoolHasAnActualCheckoutThreshold() async throws {
    let producer = try CutoutTestProducer(
      budget: CutoutMemoryBudget(limits: CutoutMemoryLimits()), sourceLimit: 1)
    let first = try await producer.image(CutoutTestData.snapshot(1), retainSource: true)
    await #expect(throws: CutoutError.resourcePressure) {
      try await producer.image(CutoutTestData.snapshot(2))
    }
    await producer.rewriteSourcesAndRelease()
    let next = try await producer.image(CutoutTestData.snapshot(3))
    #expect(CutoutTestData.firstPixel(first) == CutoutTestData.firstPixel(next))
  }
  @Test func imageCountAndByteBudgetsAreIndependent() async throws {
    for limits in [
      try CutoutMemoryLimits(maximumRetainedBytes: 1024 * 1024, maximumImages: 1),
      try CutoutMemoryLimits(maximumRetainedBytes: 512, maximumImages: 6),
    ] {
      let budget = CutoutMemoryBudget(limits: limits)
      let producer = try CutoutTestProducer(budget: budget)
      var image: CutoutImage? = try await producer.image(CutoutTestData.snapshot(1))
      let bytes = try #require(image?.byteCount)
      #expect(budget.usage.bytes == bytes)
      await #expect(throws: CutoutError.resourcePressure) {
        try await producer.image(CutoutTestData.snapshot(2))
      }
      image = nil
      #expect(budget.usage.bytes == 0)
      #expect(budget.usage.images == 0)
      let replacement = try await producer.image(CutoutTestData.snapshot(3))
      #expect(replacement.source.frameID == 3)
    }
  }
}
