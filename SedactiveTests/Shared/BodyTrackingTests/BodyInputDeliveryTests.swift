import Foundation
import Testing
@testable import Sedactive

@MainActor
struct BodyInputDeliveryTests {
    @Test(arguments: [8, 2])
    func overflowIsBoundedByWholePackets(_ capacity: Int) async throws {
        let base = try LH00TestData.load()
        let records = try (1...10).map { ReplayRecord(deliveredAt: Double($0), snapshot: try LH00TestData.snapshot(UInt64($0))) }
        let config = LH00TestData.configuration(base.configuration, capacity: capacity)
        let provider = try ReplayBodyInput(fixture: LH00TestData.fixture(records, configuration: config))
        try await provider.start(configuration: config)
        let stream = try provider.snapshotStream(generation: config.sessionGeneration)
        try provider.advance(to: 10) // Deliberately hold reader, independent of executor scheduling.
        #expect(provider.diagnostics.droppedSnapshotCount == UInt64(10 - capacity))
        #expect(provider.status == .running)
        #expect(provider.latestSnapshot?.frameID == 10)
        var iterator = stream.makeAsyncIterator()
        for expected in (11 - capacity)...10 {
            let packet = try #require(await iterator.next())
            #expect(packet.frameID == UInt64(expected))
            #expect(Set(packet.players.keys) == Set(config.selectedPlayers.ids))
        }
        try provider.releaseSnapshotSubscription(generation: config.sessionGeneration)
    }

    @Test func publicationOrderAndDuplicateDoNotRegressCache() async throws {
        let ids: [UInt64] = [101, 103, 102, 102]
        let records = try ids.enumerated().map { index, id in
            ReplayRecord(deliveredAt: Double(index + 10),
                         snapshot: try LH00TestData.snapshot(id, capturedAt: Double(id - 100)))
        }
        let fixture = try LH00TestData.fixture(records)
        let provider = try ReplayBodyInput(fixture: fixture)
        try await provider.start(configuration: fixture.configuration)
        let stream = try provider.snapshotStream(generation: fixture.configuration.sessionGeneration)
        try provider.advance(to: 13)
        var iterator = stream.makeAsyncIterator()
        for id in ids {
            let packet = try #require(await iterator.next())
            #expect(packet.frameID == id)
            #expect(packet.capturedAt == Double(id - 100))
        }
        #expect(provider.latestSnapshot?.frameID == 103)
        #expect(provider.diagnostics.droppedSnapshotCount == 0)
        try provider.releaseSnapshotSubscription(generation: fixture.configuration.sessionGeneration)
    }

    @Test func newestMeansPublicationOrderNotCaptureOrder() async throws {
        let base = try LH00TestData.load()
        let ids: [UInt64] = [101, 103, 102]
        let records = try ids.enumerated().map {
            ReplayRecord(deliveredAt: Double($0.offset + 10),
                         snapshot: try LH00TestData.snapshot($0.element, capturedAt: Double($0.element - 100)))
        }
        let config = LH00TestData.configuration(base.configuration, capacity: 2)
        let provider = try ReplayBodyInput(fixture: LH00TestData.fixture(records, configuration: config))
        try await provider.start(configuration: config)
        var iterator = try provider.snapshotStream(generation: config.sessionGeneration).makeAsyncIterator()
        try provider.advance(to: 12)
        #expect(await iterator.next()?.frameID == 103)
        #expect(await iterator.next()?.frameID == 102)
        #expect(provider.latestSnapshot?.frameID == 103)
        #expect(provider.diagnostics.droppedSnapshotCount == 1)
        try provider.releaseSnapshotSubscription(generation: config.sessionGeneration)
    }

    @Test func explicitReattachmentRejectsOldTerminationCallback() async throws {
        let fixture = try LH00TestData.load()
        let provider = try ReplayBodyInput(fixture: fixture)
        let generation = fixture.configuration.sessionGeneration
        try await provider.start(configuration: fixture.configuration)
        let oldStream = try provider.snapshotStream(generation: generation)
        let oldToken = try #require(provider.subscriptionToken)
        #expect(throws: BodyInputOperationError.consumerAlreadyClaimed) { try provider.snapshotStream(generation: generation) }
        try provider.releaseSnapshotSubscription(generation: generation)
        let newStream = try provider.snapshotStream(generation: generation)
        provider.deliveryTerminated(token: oldToken, generation: generation)
        #expect(provider.delivery == .claimed)
        #expect(provider.diagnostics.subscriptionTerminationCount == 1)
        var oldIterator = oldStream.makeAsyncIterator()
        #expect(await oldIterator.next() == nil)
        try provider.advance(to: 1)
        var iterator = newStream.makeAsyncIterator()
        #expect(await iterator.next()?.frameID == 1)
        try provider.releaseSnapshotSubscription(generation: generation)
    }

    @Test func cancellationReleasesDeliveryWithoutStoppingSource() async throws {
        let fixture = try LH00TestData.load()
        let provider = try ReplayBodyInput(fixture: fixture)
        let generation = fixture.configuration.sessionGeneration
        try await provider.start(configuration: fixture.configuration)
        let stream = try provider.snapshotStream(generation: generation)
        var reader: Task<BodySnapshot?, Never>?
        await withCheckedContinuation { ready in
            reader = Task { @MainActor in
                var iterator = stream.makeAsyncIterator()
                ready.resume()
                return await iterator.next()
            }
        }
        let task = try #require(reader)
        task.cancel()
        // No actor suspension between cancel and offer: cleanup is pending, yield sees termination.
        try provider.advance(to: 1)
        #expect(provider.diagnostics.terminatedYieldCount == 1)
        #expect(await task.value == nil)
        try provider.releaseSnapshotSubscription(generation: generation)
        #expect(provider.delivery == .closed)
        #expect(provider.status == .running)
        #expect(provider.currentContext?.isActive == true)
        #expect(provider.latestSnapshot?.frameID == 1)
        var replacement = try provider.snapshotStream(generation: generation).makeAsyncIterator()
        try provider.advance(to: 2)
        #expect(await replacement.next()?.frameID == 2)
        try provider.releaseSnapshotSubscription(generation: generation)
    }

    @Test func cancellationAutomaticallyReleasesItsClaim() async throws {
        let fixture = try LH00TestData.load()
        let provider = try ReplayBodyInput(fixture: fixture)
        let generation = fixture.configuration.sessionGeneration
        try await provider.start(configuration: fixture.configuration)
        let stream = try provider.snapshotStream(generation: generation)
        var reader: Task<BodySnapshot?, Never>?
        await withCheckedContinuation { ready in
            reader = Task { @MainActor in
                var iterator = stream.makeAsyncIterator()
                ready.resume()
                return await iterator.next()
            }
        }
        let task = try #require(reader)
        var observerToken: UUID?
        try await withCheckedThrowingContinuation { (closed: CheckedContinuation<Void, any Error>) in
            do {
                observerToken = try provider.statusUpdates { event in
                    if event.delivery == .closed { closed.resume() }
                }
                task.cancel()
            } catch { closed.resume(throwing: error) }
        }
        #expect(await task.value == nil)
        #expect(provider.delivery == .closed)
        #expect(provider.diagnostics.lastTerminationReason == .cancelled)
        #expect(provider.status == .running)
        try provider.removeStatusObserver(try #require(observerToken))
        _ = try provider.snapshotStream(generation: generation)
        #expect(provider.delivery == .claimed)
        try provider.releaseSnapshotSubscription(generation: generation)
    }

    @Test func continuouslyDrainingConsumerHasExplicitAcknowledgements() async throws {
        let fixture = try LH00TestData.load()
        let provider = try ReplayBodyInput(fixture: fixture)
        let generation = fixture.configuration.sessionGeneration
        try await provider.start(configuration: fixture.configuration)
        let stream = try provider.snapshotStream(generation: generation)
        let acknowledgements = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let consumer = Task { @MainActor in
            var frames: [UInt64] = []
            for await packet in stream {
                if provider.currentContext?.accepts(packet) == true {
                    frames.append(packet.frameID)
                    acknowledgements.continuation.yield(packet.frameID)
                }
                if frames.count == 3 { break }
            }
            try provider.releaseSnapshotSubscription(generation: generation)
            return frames
        }
        var ack = acknowledgements.stream.makeAsyncIterator()
        for frame in 1...3 {
            try provider.advance(to: Double(frame))
            #expect(await ack.next() == UInt64(frame))
        }
        #expect(try await consumer.value == [1, 2, 3])
        #expect(provider.diagnostics.droppedSnapshotCount == 0)
        acknowledgements.continuation.finish()
    }
}
