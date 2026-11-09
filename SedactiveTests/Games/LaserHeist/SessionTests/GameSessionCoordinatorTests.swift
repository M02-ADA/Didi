import Foundation
import Testing
@testable import Sedactive

@MainActor
struct GameSessionCoordinatorTests {
    @Test func replayLifecycleNeverReadsTheLiveHostClock() async throws {
        let script = try LaserReplayScript.load()
        let driver = try LaserReplayDriver(script: script)
        var hostReads = 0
        let session = GameSessionCoordinator(provider: driver.provider, inputConfiguration: script.input.configuration,
            configuration: script.configuration, encounters: script.encounters, replayDriver: driver,
            hostNow: { hostReads += 1; return 0 })
        try await session.start()
        try await session.advance(to: 100)
        await session.stop()
        #expect(hostReads == 0 && session.summary?.teamScore == 400)
    }

    private func makeSession(_ provider: ControlledSessionInput,
                             configuration: BodyInputConfiguration? = nil) throws -> GameSessionCoordinator {
        let script = try LaserReplayScript.load()
        return GameSessionCoordinator(provider: provider,
            inputConfiguration: configuration ?? script.input.configuration,
            configuration: script.configuration, encounters: script.encounters)
    }

    @Test func injectedProviderOwnsOneStreamAndNeverRunsReplayActions() async throws {
        let provider = ControlledSessionInput()
        let session = try makeSession(provider)
        try await session.start()
        try await session.start()
        #expect(!session.isReplay)
        #expect(provider.startCount == 1 && provider.claimCount == 1)
        #expect(provider.observerCount == 1)
        #expect(session.phase == .awaitingSetup)
        #expect(session.inputStatus == .running)
        #expect(session.state == nil && session.summary == nil)
        await #expect(throws: LaserDataError.self) { try await session.advance(to: 100) }
        #expect(session.events.isEmpty && session.results.isEmpty)
        await session.stop()
        #expect(provider.releaseCount == 1 && provider.removeObserverCount == 1)
        #expect(provider.stopCount == 1)
        #expect(session.inputStatus == .stopped)
        #expect(session.latestSnapshot == nil)
        await session.stop()
        #expect(provider.stopCount == 1)
    }

    @Test func uncalibratedActiveContextNeverStartsGameplay() async throws {
        let provider = ControlledSessionInput()
        let script = try LaserReplayScript.load()
        let config = script.input.configuration.replacingCalibrations([:])
        let session = try makeSession(provider, configuration: config)
        try await session.start()
        let missing = try EstimatedScalar(value: nil, validity: .notCalibrated)
        let packet = BodySnapshot(sessionGeneration: config.sessionGeneration, frameID: 1, capturedAt: 1,
            cameraGeometryRevision: 1, players: Dictionary(uniqueKeysWithValues: PlayerID.allCases.map {
                ($0, PlayerBodySample(playerID: $0, calibrationRevision: nil, trackingStatus: .reliable,
                    geometry: BodyGeometry(crownY: missing, leftWristY: missing, rightWristY: missing,
                        leftSoleY: missing, rightSoleY: missing, centerX: missing),
                    jumpState: JumpState(phase: .unknown, validity: .notCalibrated)))
            }))
        await provider.sendAndWaitForContextRead(packet)
        #expect(session.inputContext?.accepts(packet) == true)
        #expect(session.latestSnapshot == packet)
        #expect(session.phase == .awaitingSetup)
        #expect(session.state == nil && session.summary == nil && session.results.isEmpty)
        await session.stop()
    }

    @Test func contextCutoverRejectsBufferedOldEvidenceAndKeepsOneConsumer() async throws {
        let provider = ControlledSessionInput()
        let script = try LaserReplayScript.load()
        let session = try makeSession(provider)
        try await session.start()
        let original = try #require(script.input.records.first?.snapshot)
        await provider.sendAndWaitForContextRead(original)
        #expect(session.latestSnapshot == original)
        let old = try #require(provider.currentContext)
        provider.replaceContext(BodyInputContext(sessionGeneration: old.sessionGeneration,
            cameraGeometryRevision: old.cameraGeometryRevision, calibrationRevisions: old.calibrationRevisions,
            cutovers: Dictionary(uniqueKeysWithValues: PlayerID.allCases.map {
                ($0, BodyInputCutover(frameID: original.frameID, capturedAt: original.capturedAt))
            }), isActive: true))
        #expect(session.latestSnapshot == nil)
        await provider.sendAndWaitForContextRead(original)
        #expect(session.latestSnapshot == nil)
        let next = BodySnapshot(sessionGeneration: original.sessionGeneration, frameID: original.frameID + 1,
            capturedAt: original.capturedAt + 0.1, cameraGeometryRevision: original.cameraGeometryRevision,
            players: original.players)
        await provider.sendAndWaitForContextRead(next)
        #expect(session.latestSnapshot == next)
        #expect(provider.claimCount == 1 && session.events.isEmpty)
        await session.stop()
    }

    @Test func sourceInterruptionClearsLatestWithoutFramesOrReentrantControl() async throws {
        let provider = ControlledSessionInput()
        let session = try makeSession(provider)
        try await session.start()
        let packet = try #require(LaserReplayScript.load().input.records.first?.snapshot)
        await provider.sendAndWaitForContextRead(packet)
        #expect(session.latestSnapshot != nil)
        provider.interrupt()
        #expect(session.inputStatus == .interrupted(.system))
        #expect(session.inputContext?.isActive == false)
        #expect(session.latestSnapshot == nil)
        #expect(provider.stopCount == 0 && provider.releaseCount == 0)
        #expect(session.phase == .awaitingSetup && session.state == nil)
        await session.stop()
    }

    @Test func stopDuringSuspendedStartCannotResurrectSession() async throws {
        let provider = ControlledSessionInput()
        provider.suspendStart = true
        let session = try makeSession(provider)
        let start = Task { try await session.start() }
        await provider.waitForSuspendedStart()
        #expect(session.phase == .starting)
        try await session.start()
        #expect(provider.startCount == 1)
        let stop = Task { await session.stop() }
        await provider.waitForStop()
        // Cleanup holds the source claim while its suspended startup still owns work.
        let competingSession = try makeSession(provider)
        await #expect(throws: BodyInputOperationError.observerAlreadyRegistered) {
            try await competingSession.start()
        }
        provider.resumeStart()
        await stop.value
        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(session.phase == .finished)
        #expect(provider.claimCount == 0 && provider.currentContext?.isActive == false)
        #expect(provider.observerCount == provider.removeObserverCount)
        #expect(session.state == nil && session.latestSnapshot == nil)
    }

    @Test func taskCancellationDuringStartCleansUpSourceAndObserver() async throws {
        let provider = ControlledSessionInput()
        provider.suspendStart = true
        let session = try makeSession(provider)
        let start = Task { try await session.start() }
        await provider.waitForSuspendedStart()
        start.cancel()
        provider.resumeStart()
        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(session.phase == .finished)
        #expect(provider.stopCount == 1 && provider.claimCount == 0)
        #expect(provider.removeObserverCount == 1)
    }

    @Test func failedStreamClaimReleasesOwnedStatusAndStopsInput() async throws {
        let provider = ControlledSessionInput()
        provider.rejectStreamClaim = true
        let session = try makeSession(provider)
        await #expect(throws: BodyInputOperationError.consumerAlreadyClaimed) { try await session.start() }
        #expect(provider.stopCount == 1 && provider.removeObserverCount == 1)
        #expect(provider.releaseCount == 0)
        #expect(session.state == nil && session.summary == nil)
        if case .failed = session.phase {} else { Issue.record("Failed input must not stay starting") }
    }

    @Test func occupiedStatusObserverIsNotStolenOrStopped() async throws {
        let provider = ControlledSessionInput()
        let existing = try provider.statusUpdates { _ in }
        let session = try makeSession(provider)
        await #expect(throws: BodyInputOperationError.observerAlreadyRegistered) { try await session.start() }
        #expect(provider.startCount == 0 && provider.stopCount == 0)
        #expect(provider.removeObserverCount == 0)
        try provider.removeStatusObserver(existing)
    }

    @Test func activeProviderCannotBeTakenOverOrStoppedAfterAClaimFailure() async throws {
        let provider = ControlledSessionInput()
        provider.status = .running
        let session = try makeSession(provider)
        await #expect(throws: LaserDataError.self) { try await session.start() }
        #expect(provider.startCount == 0 && provider.stopCount == 0 && provider.claimCount == 0)
        #expect(provider.observerCount == 0 && provider.status == .running)
    }
}

/// Deterministic CP1 test source. No camera, clock, sleeps, or inferred gameplay measurements.
@MainActor
final class ControlledSessionInput: BodyInputProviding {
    var latestSnapshot: BodySnapshot?
    private var context: BodyInputContext?
    var currentContext: BodyInputContext? {
        let waiter = contextRead
        contextRead = nil
        waiter?.resume()
        return context
    }
    var status: BodyInputStatus = .stopped
    var diagnostics = BodyInputDiagnostics()
    var startCount = 0, stopCount = 0, claimCount = 0, releaseCount = 0
    var observerCount = 0, removeObserverCount = 0
    var suspendStart = false, rejectStreamClaim = false
    private var observer: (@MainActor (BodyInputStatusEvent) -> Void)?
    private var observerToken: UUID?
    private var continuation: AsyncStream<BodySnapshot>.Continuation?
    private var contextRead: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var stopWaiter: CheckedContinuation<Void, Never>?

    func start(configuration: BodyInputConfiguration) async throws {
        startCount += 1
        if suspendStart {
            await withCheckedContinuation {
                startContinuation = $0
                startWaiter?.resume()
                startWaiter = nil
            }
        }
        context = BodyInputContext(sessionGeneration: configuration.sessionGeneration,
            cameraGeometryRevision: 1, calibrationRevisions: configuration.calibrations.mapValues(\.revision),
            cutovers: [:], isActive: true)
        status = .running
        notify()
    }

    func stop() async {
        stopCount += 1
        stopWaiter?.resume()
        stopWaiter = nil
        continuation?.finish()
        continuation = nil
        status = .stopped
        if let context {
            self.context = BodyInputContext(sessionGeneration: context.sessionGeneration,
                cameraGeometryRevision: context.cameraGeometryRevision,
                calibrationRevisions: [:], cutovers: context.cutovers, isActive: false)
        }
        notify()
    }

    func snapshotStream(generation: UUID) throws -> AsyncStream<BodySnapshot> {
        if rejectStreamClaim || continuation != nil { throw BodyInputOperationError.consumerAlreadyClaimed }
        claimCount += 1
        let pair = AsyncStream<BodySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(8))
        continuation = pair.continuation
        return pair.stream
    }

    func releaseSnapshotSubscription(generation: UUID) throws {
        releaseCount += 1
        continuation?.finish()
        continuation = nil
    }

    func statusUpdates(_ observer: @escaping @MainActor (BodyInputStatusEvent) -> Void) throws -> UUID {
        guard self.observer == nil else { throw BodyInputOperationError.observerAlreadyRegistered }
        observerCount += 1
        let token = UUID()
        self.observer = observer
        observerToken = token
        notify()
        return token
    }

    func removeStatusObserver(_ token: UUID) throws {
        guard token == observerToken else { return }
        removeObserverCount += 1
        observer = nil
        observerToken = nil
    }

    func setCalibrations(_ values: [PlayerID: PlayerCalibration], generation: UUID) async throws -> BodyInputContext {
        throw BodyInputOperationError.notRunning // Candidate production/acceptance is outside J01.
    }

    func sendAndWaitForContextRead(_ packet: BodySnapshot) async {
        await withCheckedContinuation {
            contextRead = $0
            continuation?.yield(packet)
        }
    }

    func replaceContext(_ value: BodyInputContext) { context = value; notify() }

    func interrupt() {
        status = .interrupted(.system)
        if let context {
            self.context = BodyInputContext(sessionGeneration: context.sessionGeneration,
                cameraGeometryRevision: context.cameraGeometryRevision,
                calibrationRevisions: context.calibrationRevisions, cutovers: context.cutovers, isActive: false)
        }
        notify()
    }

    func waitForSuspendedStart() async {
        if startContinuation != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func resumeStart() { startContinuation?.resume(); startContinuation = nil }

    func waitForStop() async {
        if stopCount > 0 { return }
        await withCheckedContinuation { stopWaiter = $0 }
    }

    private func notify() {
        observer?(BodyInputStatusEvent(sessionGeneration: context?.sessionGeneration, occurredAt: 0,
            statusRevision: 0, status: status, context: context,
            delivery: continuation == nil ? .closed : .claimed, progress: .waiting))
    }
}
