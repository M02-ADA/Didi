import Foundation
import Testing
@testable import Sedactive

@MainActor
struct LiveCoordinatorRetryTests {
    @Test func flowRetriesSameRealProviderWithFreshGenerationsAndExplicitBinding() async throws {
        let driver = ControlledCameraDriver()
        let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized), driver: driver)
        let provider = BodyInputService(camera: camera)
        let flow = LaserInputFlow(makeLiveSession: {
            GameSessionCoordinator(liveProvider: provider,
                inputConfiguration: LiveVisionFixtures.configuration(UUID()))
        })
        var generations: Set<UUID> = []
        var bindingRequests: Set<UUID> = []
        for _ in 0..<3 {
            await flow.startLiveSetup()
            let session = try #require(flow.session)
            #expect(session.phase == .awaitingSetup && session.state == nil)
            let generation = session.inputConfiguration.sessionGeneration
            #expect(generations.insert(generation).inserted)
            #expect(provider.currentContext?.calibrationRevisions.isEmpty == true)
            #expect(camera.frames.tracking.snapshot.requestID == nil)
            #expect(throws: BodyInputOperationError.consumerAlreadyClaimed) {
                try provider.snapshotStream(generation: generation)
            }
            try session.setup?.beginBinding()
            let oldRequest = try #require(camera.frames.tracking.snapshot.requestID)
            #expect(bindingRequests.insert(oldRequest).inserted)
            await flow.closeLiveSetup()
            #expect(flow.canStartLive && provider.status == .stopped)
            #expect(camera.state.context == nil && camera.frames.usage.frames == 0)
            #expect(session.liveReadiness?.phase == .restartRequired)
        }
        #expect(await driver.starts == 3)
        #expect(await driver.stops == 3)
        #expect(provider.camera === camera)
    }

    @Test func retryButtonPathClosesOldCoordinatorBeforeClaimingNewStream() async throws {
        let driver = ControlledCameraDriver()
        let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized), driver: driver)
        let provider = BodyInputService(camera: camera)
        let flow = LaserInputFlow(makeLiveSession: {
            GameSessionCoordinator(liveProvider: provider,
                inputConfiguration: LiveVisionFixtures.configuration(UUID()))
        })
        await flow.startLiveSetup()
        let old = try #require(flow.session)
        await flow.retryLiveSetup()
        let current = try #require(flow.session)
        #expect(current !== old && current.inputConfiguration.sessionGeneration != old.inputConfiguration.sessionGeneration)
        #expect(old.phase == .finished && old.inputStatus == .stopped)
        #expect(current.phase == .awaitingSetup && current.setup?.phase == .awaitingBinding)
        await old.stop() // Late old-screen cleanup cannot stop the reused provider's new session.
        #expect(provider.currentContext?.sessionGeneration == current.inputConfiguration.sessionGeneration)
        #expect(provider.currentContext?.isActive == true)
        #expect(await driver.starts == 2)
        #expect(await driver.stops == 1)
        await flow.closeLiveSetup()
    }

    @Test func pendingWorkerCleanupPreventsRetryFromAllocatingAnotherSession() async throws {
        let driver = ControlledCameraDriver()
        let sink = ControlledCameraSink()
        let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized), driver: driver, sink: sink)
        let provider = BodyInputService(camera: camera)
        var constructions = 0
        let flow = LaserInputFlow(makeLiveSession: {
            constructions += 1
            return GameSessionCoordinator(liveProvider: provider,
                inputConfiguration: LiveVisionFixtures.configuration(UUID()))
        })
        await flow.startLiveSetup()
        let context = try #require(camera.state.context)
        _ = try CameraTestFrames.offer(CameraTestFrames.buffer(), store: camera.frames, context: context)
        await sink.untilEntered()
        let stopped = CoordinatorSourceStopSignal()
        let observer = try camera.observe { stopped.observe($0) }
        let close = Task { await flow.closeLiveSetup() }
        await stopped.wait()
        #expect(flow.isClosing && camera.frames.usage.frames == 1)
        await flow.retryLiveSetup()
        await flow.startLiveSetup()
        #expect(constructions == 1)
        #expect(await driver.starts == 1)
        await sink.release()
        await close.value
        #expect(camera.frames.usage.frames == 0 && flow.canStartLive)
        await flow.startLiveSetup()
        #expect(constructions == 2)
        #expect(await driver.starts == 2)
        await flow.closeLiveSetup()
        camera.removeObserver(observer)
    }
}

@MainActor private final class CoordinatorSourceStopSignal {
    private var stopped = false
    private var waiter: CheckedContinuation<Void, Never>?
    func observe(_ value: CameraPipelineState) {
        guard value.status == .stopped else { return }
        stopped = true
        waiter?.resume(); waiter = nil
    }
    func wait() async {
        if stopped { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
