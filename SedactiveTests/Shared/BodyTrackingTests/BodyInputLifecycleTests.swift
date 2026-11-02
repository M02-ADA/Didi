import Foundation
import Testing
@testable import Sedactive

@MainActor
struct BodyInputLifecycleTests {
    @Test func recalibrationInvalidatesQueuedAndRelabeledOldCaptures() async throws {
        let records = [
            ReplayRecord(deliveredAt: 1, snapshot: try LH00TestData.snapshot(1)),
            ReplayRecord(deliveredAt: 3, snapshot: try LH00TestData.snapshot(2, capturedAt: 1.5)),
            ReplayRecord(deliveredAt: 3.1, snapshot: try LH00TestData.snapshot(3, capturedAt: 1.7, revision: 2)),
            ReplayRecord(deliveredAt: 4, snapshot: try LH00TestData.snapshot(4, capturedAt: 3, revision: 2))
        ]
        let fixture = try LH00TestData.fixture(records)
        let provider = try ReplayBodyInput(fixture: fixture)
        try await provider.start(configuration: fixture.configuration)
        var iterator = try provider.snapshotStream(generation: fixture.configuration.sessionGeneration).makeAsyncIterator()
        try provider.advance(to: 2)
        let old = try #require(provider.latestSnapshot)
        let values = fixture.configuration.calibrations.mapValues {
            LH00TestData.calibration($0, revision: 2, sourceFrameID: 1, capturedAt: 1)
        }
        let context = try await provider.setCalibrations(values, generation: fixture.configuration.sessionGeneration)
        #expect(provider.latestSnapshot == nil)
        let buffered = try #require(await iterator.next())
        #expect(buffered == old) // AsyncStream does not erase buffered values; metadata stays immutable.
        #expect(!context.accepts(buffered))
        try provider.advance(to: 4)
        let current = try #require(await iterator.next())
        #expect(current.frameID == 4)
        #expect(provider.currentContext?.accepts(current) == true)
        #expect(provider.diagnostics.rejectedSnapshotCount == 2)
        #expect(old.players.values.allSatisfy { $0.calibrationRevision == 1 })
        try provider.releaseSnapshotSubscription(generation: fixture.configuration.sessionGeneration)
    }

    @Test func recalibratingOnePlayerPreservesTheOtherPlayersCompatibleEvidence() async throws {
        let fixture = try LH00TestData.load()
        let provider = try ReplayBodyInput(fixture: fixture)
        try await provider.start(configuration: fixture.configuration)
        try provider.advance(to: 2)
        let old = try #require(provider.latestSnapshot)
        let selection = fixture.configuration.selectedPlayers
        var values = fixture.configuration.calibrations
        values[selection.firstID] = LH00TestData.calibration(try #require(values[selection.firstID]), revision: 2)
        let context = try await provider.setCalibrations(values, generation: fixture.configuration.sessionGeneration)
        #expect(!context.accepts(old, playerID: selection.firstID))
        #expect(context.accepts(old, playerID: selection.secondID))
        #expect(!context.accepts(old))
    }

    @Test func rejectedCalibrationIsAtomicAndSameRevisionCannotChangeBaseline() async throws {
        let fixture = try LH00TestData.load()
        let provider = try ReplayBodyInput(fixture: fixture)
        try await provider.start(configuration: fixture.configuration)
        try provider.advance(to: 1)
        let before = provider.currentContext
        let latest = provider.latestSnapshot
        let changedSameRevision = fixture.configuration.calibrations.mapValues {
            LH00TestData.calibration($0, revision: 1, sourceFrameID: 1, capturedAt: 1)
        }
        await #expect(throws: BodyInputContractError.self) {
            try await provider.setCalibrations(changedSameRevision, generation: fixture.configuration.sessionGeneration)
        }
        await #expect(throws: BodyInputOperationError.wrongGeneration) {
            try await provider.setCalibrations([:], generation: UUID())
        }
        #expect(provider.currentContext == before)
        #expect(provider.latestSnapshot == latest)
    }

    @Test func startIsIdempotentAndStopRestartRejectsOldGeneration() async throws {
        let first = try LH00TestData.load()
        let second = try LH00TestData.load("reversed-selection-v1")
        let records = [ReplayRecord(deliveredAt: 1, snapshot: try LH00TestData.snapshot(1)),
                       ReplayRecord(deliveredAt: 2, snapshot: try LH00TestData.snapshot(2,
                                           generation: second.configuration.sessionGeneration))]
        let provider = try ReplayBodyInput(fixture: LH00TestData.fixture(records))
        try await provider.start(configuration: first.configuration)
        let stream = try provider.snapshotStream(generation: first.configuration.sessionGeneration)
        let oldToken = try #require(provider.subscriptionToken)
        try provider.advance(to: 1)
        try await provider.start(configuration: first.configuration)
        #expect(provider.subscriptionToken == oldToken)
        #expect(provider.latestSnapshot?.frameID == 1)
        await #expect(throws: BodyInputOperationError.configurationChanged) {
            try await provider.start(configuration: second.configuration)
        }
        await provider.stop()
        #expect(provider.latestSnapshot == nil)
        #expect(provider.currentContext?.isActive == false)
        try await provider.start(configuration: second.configuration)
        var replacement = try provider.snapshotStream(generation: second.configuration.sessionGeneration).makeAsyncIterator()
        provider.deliveryTerminated(token: oldToken, generation: first.configuration.sessionGeneration)
        try provider.advance(to: 2)
        var old = stream.makeAsyncIterator()
        let stale = try #require(await old.next())
        #expect(provider.currentContext?.accepts(stale) == false)
        #expect(await old.next() == nil)
        #expect(await replacement.next()?.sessionGeneration == second.configuration.sessionGeneration)
        #expect(provider.diagnostics.rejectedSnapshotCount == 1)
        await provider.stop()
        await provider.stop()
        await #expect(throws: BodyInputOperationError.generationReused) {
            try await provider.start(configuration: second.configuration)
        }
        await #expect(throws: BodyInputOperationError.generationReused) {
            try await provider.start(configuration: first.configuration)
        }
    }

    @Test func lifecycleStatusIsOrderedWithoutAnyCameraFrames() async throws {
        let records = [ReplayRecord(deliveredAt: 1, status: .interrupted(.system)),
                       ReplayRecord(deliveredAt: 2, status: .running),
                       ReplayRecord(deliveredAt: 3, status: .failed(.cameraUnavailable))]
        let fixture = try LH00TestData.fixture(records)
        let provider = try ReplayBodyInput(fixture: fixture)
        var events: [BodyInputStatusEvent] = []
        let observer = try provider.statusUpdates { events.append($0) }
        #expect(events.map(\.status) == [.stopped])
        #expect(throws: BodyInputOperationError.observerAlreadyRegistered) { try provider.statusUpdates { _ in } }
        try await provider.start(configuration: fixture.configuration)
        try provider.advance(to: 3)
        #expect(events.map(\.status) == [.stopped, .starting, .running, .interrupted(.system), .running, .failed(.cameraUnavailable)])
        #expect(events.map(\.statusRevision) == Array(0...5).map(UInt64.init))
        #expect(provider.latestSnapshot == nil)
        #expect(provider.status == .failed(.cameraUnavailable))
        #expect(provider.currentContext?.isActive == false)
        try provider.removeStatusObserver(observer)
        var replayed: [BodyInputStatusEvent] = []
        let next = try provider.statusUpdates { replayed.append($0) }
        #expect(replayed.count == 1)
        #expect(replayed[0].status == .failed(.cameraUnavailable))
        await provider.stop()
        #expect(replayed.last?.status == .stopped)
        try provider.removeStatusObserver(next)
    }

    @Test func currentStateReplayPreservesTheTransitionTimestamp() async throws {
        let fixture = try LH00TestData.load()
        let provider = try ReplayBodyInput(fixture: fixture)
        var events: [BodyInputStatusEvent] = []
        let token = try provider.statusUpdates { events.append($0) }
        try await provider.start(configuration: fixture.configuration)
        try provider.advance(to: 1)
        let original = try #require(events.last)
        try provider.advance(to: 1.5)
        try provider.removeStatusObserver(token)
        var replayed: BodyInputStatusEvent?
        let replacement = try provider.statusUpdates { replayed = $0 }
        #expect(replayed == original)
        #expect(replayed?.occurredAt == 1)
        try provider.removeStatusObserver(replacement)
    }

    @Test func observerCannotReenterControlAndCorruptCurrentState() async throws {
        let fixture = try LH00TestData.load()
        let provider = try ReplayBodyInput(fixture: fixture)
        var errors: [BodyInputOperationError] = []
        let token = try provider.statusUpdates { _ in
            do { _ = try provider.snapshotStream(generation: fixture.configuration.sessionGeneration) }
            catch let error as BodyInputOperationError { errors.append(error) }
            catch { Issue.record("Unexpected observer error: \(error)") }
        }
        try await provider.start(configuration: fixture.configuration)
        #expect(errors == [.reentrantControl, .reentrantControl, .reentrantControl])
        #expect(provider.delivery == .prepared)
        try provider.removeStatusObserver(token)
    }

    @Test func cameraGeometryChangeInvalidatesMappingAndOldEvidence() async throws {
        let records = [ReplayRecord(deliveredAt: 1, snapshot: try LH00TestData.snapshot(1)),
                       ReplayRecord(deliveredAt: 2, cameraGeometryRevision: 2),
                       ReplayRecord(deliveredAt: 3, snapshot: try LH00TestData.snapshot(3))]
        let fixture = try LH00TestData.fixture(records)
        let provider = try ReplayBodyInput(fixture: fixture)
        try await provider.start(configuration: fixture.configuration)
        try provider.advance(to: 1)
        let old = try #require(provider.latestSnapshot)
        try provider.advance(to: 2)
        #expect(provider.latestSnapshot == nil)
        #expect(provider.currentContext?.cameraGeometryRevision == 2)
        #expect(provider.currentContext?.calibrationRevisions.isEmpty == true)
        #expect(provider.currentContext?.accepts(old) == false)
        try provider.advance(to: 3)
        #expect(provider.diagnostics.rejectedSnapshotCount == 1)
    }

    @Test func diagnosticStallUsesInjectedTimeAndUniqueLateCompletions() async throws {
        let base = try LH00TestData.load()
        let config = LH00TestData.configuration(base.configuration, policy: .diagnostic(threshold: 1))
        let records = [ReplayRecord(deliveredAt: 1, snapshot: try LH00TestData.snapshot(101, capturedAt: 1)),
                       ReplayRecord(deliveredAt: 1.3, snapshot: try LH00TestData.snapshot(103, capturedAt: 1.3)),
                       ReplayRecord(deliveredAt: 1.5, snapshot: try LH00TestData.snapshot(103, capturedAt: 1.3)),
                       ReplayRecord(deliveredAt: 3, snapshot: try LH00TestData.snapshot(102, capturedAt: 1.2))]
        let provider = try ReplayBodyInput(fixture: LH00TestData.fixture(records, configuration: config))
        try await provider.start(configuration: config)
        try provider.advance(to: 0.9)
        #expect(provider.progress == .waiting)
        try provider.advance(to: 2.31)
        #expect(provider.progress == .suspectedStall)
        #expect(provider.status == .running)
        try provider.advance(to: 3)
        #expect(provider.progress == .progressing)
        #expect(provider.latestSnapshot?.frameID == 103)
        try provider.advance(to: 3.9)
        #expect(provider.progress == .progressing)
        let values = config.calibrations.mapValues { LH00TestData.calibration($0, revision: 2) }
        _ = try await provider.setCalibrations(values, generation: config.sessionGeneration)
        try provider.advance(to: 100)
        #expect(provider.progress == .waiting) // Known context transition waits for first compatible output.
        #expect(provider.status == .running)
    }

    @Test func lostTrackingAndOverflowAreStillProcessingProgress() async throws {
        let base = try LH00TestData.load()
        let config = LH00TestData.configuration(base.configuration, policy: .diagnostic(threshold: 1))
        let provider = try ReplayBodyInput(fixture: LH00TestData.fixture(base.records, configuration: config))
        try await provider.start(configuration: config)
        try provider.advance(to: 9)
        #expect(provider.progress == .progressing)
        #expect(provider.status == .running)
        #expect(provider.latestSnapshot?.players.values.contains { $0.trackingStatus == .lost } == true)
        #expect(provider.diagnostics.droppedSnapshotCount == 1)
    }
}
