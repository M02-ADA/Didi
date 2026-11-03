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
        var values = fixture.configuration.calibrations
        values[.player1] = LH00TestData.calibration(try #require(values[.player1]), revision: 2)
        let context = try await provider.setCalibrations(values, generation: fixture.configuration.sessionGeneration)
        #expect(!context.accepts(old, playerID: .player1))
        #expect(context.accepts(old, playerID: .player2))
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
        let second = try LH00TestData.load("two-player-recovery-v2")
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

    @Test func fullReplacementPublishesExactAcceptedKeysFromEmptyThroughRemoval() async throws {
        let base = try LH00TestData.load()
        let generation = base.configuration.sessionGeneration
        let p1 = try #require(base.configuration.calibrations[.player1])
        let p2 = try #require(base.configuration.calibrations[.player2])
        let empty = LH00TestData.configuration(base.configuration, calibrations: [:])
        let calibrated = try LH00TestData.snapshot(2)
        let unbound = BodySnapshot(sessionGeneration: generation, frameID: 1, capturedAt: 1, cameraGeometryRevision: 1,
                                   players: [.player1: try LH00TestData.unavailableSample(.player1),
                                             .player2: try LH00TestData.unavailableSample(.player2)])
        let partial = BodySnapshot(sessionGeneration: generation, frameID: 3, capturedAt: 3, cameraGeometryRevision: 1,
                                   players: [.player1: try LH00TestData.unavailableSample(.player1, tracking: .reliable),
                                             .player2: try #require(calibrated.players[.player2])])
        let records = [ReplayRecord(deliveredAt: 1, snapshot: unbound),
                       ReplayRecord(deliveredAt: 2, snapshot: calibrated),
                       ReplayRecord(deliveredAt: 3, snapshot: partial)]
        let provider = try ReplayBodyInput(fixture: LH00TestData.fixture(records, configuration: empty))
        var observed: [BodyInputStatusEvent] = []
        let token = try provider.statusUpdates { observed.append($0) }
        try await provider.start(configuration: empty)
        #expect(provider.status == .running)
        #expect(provider.currentContext?.calibrationRevisions.isEmpty == true)
        var iterator = try provider.snapshotStream(generation: generation).makeAsyncIterator()
        try provider.advance(to: 1)
        let unboundPacket = try #require(await iterator.next())
        #expect(unboundPacket == unbound)
        #expect(unboundPacket.players.values.allSatisfy { $0.trackingStatus == .lost && $0.calibrationRevision == nil })
        let onlyP1 = try await provider.setCalibrations([.player1: p1], generation: generation)
        #expect(onlyP1.calibrationRevisions == [.player1: 1])
        #expect(observed.last?.context == onlyP1)
        let both = try await provider.setCalibrations([.player1: p1, .player2: p2], generation: generation)
        #expect(both.calibrationRevisions == [.player1: 1, .player2: 1])
        #expect(both.cutovers[.player1] == onlyP1.cutovers[.player1])
        #expect(observed.last?.context == both)
        try provider.advance(to: 2)
        #expect(await iterator.next() == calibrated)
        let eventCount = observed.count
        let equal = try await provider.setCalibrations([.player1: p1, .player2: p2], generation: generation)
        #expect(equal == both)
        #expect(provider.latestSnapshot == calibrated)
        #expect(observed.count == eventCount) // Identical replacement is a no-op.
        let onlyP2 = try await provider.setCalibrations([.player2: p2], generation: generation)
        #expect(onlyP2.calibrationRevisions == [.player2: 1])
        #expect(observed.last?.context == onlyP2)
        #expect(!onlyP2.accepts(calibrated, playerID: .player1))
        #expect(onlyP2.accepts(calibrated, playerID: .player2))
        #expect(onlyP2.cutovers[.player2] == both.cutovers[.player2])
        #expect(provider.latestSnapshot == nil)
        try provider.advance(to: 3)
        let partialPacket = try #require(await iterator.next())
        #expect(partialPacket == partial)
        #expect(Set(partialPacket.players.keys) == Set(PlayerID.allCases))
        #expect(partialPacket.players[.player1]?.geometry.crownY.validity == .notCalibrated)
        let cleared = try await provider.setCalibrations([:], generation: generation)
        #expect(cleared.calibrationRevisions.isEmpty)
        #expect(observed.last?.context == cleared)
        #expect(provider.latestSnapshot == nil)
        #expect(provider.status == .running) // Accepted calibrations are not a Shared gameplay phase.
        try provider.releaseSnapshotSubscription(generation: generation)
        try provider.removeStatusObserver(token)
    }

    @Test func mixedInvalidReplacementCannotPartiallyCommitOrClearEvidence() async throws {
        let fixture = try LH00TestData.load()
        let provider = try ReplayBodyInput(fixture: fixture)
        let generation = fixture.configuration.sessionGeneration
        let p1 = try #require(fixture.configuration.calibrations[.player1])
        let p2 = try #require(fixture.configuration.calibrations[.player2])
        let changedP1 = LH00TestData.calibration(p1, revision: 2)
        let badP2 = [LH00TestData.calibration(p2, revision: 1, sourceFrameID: 1, capturedAt: 1),
                     LH00TestData.calibration(p2, revision: 2, capturedAt: 2),
                     LH00TestData.calibration(p2, revision: 2, generation: UUID()),
                     LH00TestData.calibration(p2, revision: 2, cameraRevision: 2), changedP1]
        try await provider.start(configuration: fixture.configuration)
        _ = try provider.snapshotStream(generation: generation)
        try provider.advance(to: 1)
        let before = provider.currentContext
        let latest = provider.latestSnapshot
        let subscription = provider.subscriptionToken
        var events: [BodyInputStatusEvent] = []
        let observer = try provider.statusUpdates { events.append($0) }
        for invalid in badP2 {
            await #expect(throws: BodyInputContractError.self) {
                try await provider.setCalibrations([.player1: changedP1, .player2: invalid], generation: generation)
            }
            #expect(provider.currentContext == before)
            #expect(provider.latestSnapshot == latest)
            #expect(provider.subscriptionToken == subscription)
            #expect(events.count == 1)
        }
        try provider.removeStatusObserver(observer)
        try provider.releaseSnapshotSubscription(generation: generation)
    }

    @Test func removalAndSameRevisionReacceptanceNeverReviveOldBufferedEvidence() async throws {
        let base = try LH00TestData.load()
        let generation = base.configuration.sessionGeneration
        let records = [ReplayRecord(deliveredAt: 1, snapshot: try LH00TestData.snapshot(1)),
                       ReplayRecord(deliveredAt: 3, snapshot: try LH00TestData.snapshot(2, capturedAt: 1.5)),
                       ReplayRecord(deliveredAt: 4, snapshot: try LH00TestData.snapshot(3, capturedAt: 4))]
        let provider = try ReplayBodyInput(fixture: LH00TestData.fixture(records))
        try await provider.start(configuration: base.configuration)
        var iterator = try provider.snapshotStream(generation: generation).makeAsyncIterator()
        try provider.advance(to: 2)
        let old = try #require(provider.latestSnapshot)
        let p2 = try #require(base.configuration.calibrations[.player2])
        let removed = try await provider.setCalibrations([.player2: p2], generation: generation)
        #expect(removed.calibrationRevisions == [.player2: 1])
        try provider.advance(to: 2.5)
        let reaccepted = try await provider.setCalibrations(base.configuration.calibrations, generation: generation)
        #expect(reaccepted.calibrationRevisions == [.player1: 1, .player2: 1])
        #expect(!reaccepted.accepts(old, playerID: .player1))
        #expect(reaccepted.accepts(old, playerID: .player2))
        #expect(await iterator.next() == old) // Drainable, never relabeled or made compatible again.
        try provider.advance(to: 4)
        #expect(provider.diagnostics.rejectedSnapshotCount == 1)
        let current = try #require(await iterator.next())
        #expect(current.frameID == 3)
        #expect(provider.currentContext?.accepts(current) == true)
        try provider.releaseSnapshotSubscription(generation: generation)
    }

    @Test func reusedSlotAndFrameLabelsStillRequireTheNewGeneration() async throws {
        let first = try LH00TestData.load()
        let second = try LH00TestData.load("two-player-recovery-v2")
        let old = try LH00TestData.snapshot(1)
        let new = try LH00TestData.snapshot(1, generation: second.configuration.sessionGeneration)
        let provider = try ReplayBodyInput(fixture: LH00TestData.fixture([
            ReplayRecord(deliveredAt: 1, snapshot: old), ReplayRecord(deliveredAt: 2, snapshot: new)]))
        try await provider.start(configuration: first.configuration)
        try provider.advance(to: 1)
        await provider.stop()
        try await provider.start(configuration: second.configuration)
        var iterator = try provider.snapshotStream(generation: second.configuration.sessionGeneration).makeAsyncIterator()
        try provider.advance(to: 2)
        #expect(provider.currentContext?.accepts(old) == false)
        #expect(provider.diagnostics.rejectedSnapshotCount == 1)
        #expect(await iterator.next() == new)
        #expect(provider.latestSnapshot == new)
        await #expect(throws: BodyInputContractError.self) {
            try await provider.setCalibrations(first.configuration.calibrations,
                                               generation: second.configuration.sessionGeneration)
        }
        #expect(provider.currentContext?.calibrationRevisions == [.player1: 1, .player2: 1])
        try provider.releaseSnapshotSubscription(generation: second.configuration.sessionGeneration)
    }

}
