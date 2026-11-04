import Foundation
import Testing

@testable import Sedactive

nonisolated struct CameraDiagnosticsTests {
  @Test func percentileWindowIsBoundedAndUsesNearestRank() {
    var window = CameraLatencyWindow()
    for index in 1...100 { window.record(seconds: Double(index) / 1000) }
    #expect(window.summary.count == 100)
    #expect(window.summary.p50MS == 50)
    #expect(window.summary.p95MS == 95)
    window.record(seconds: -.infinity)
    window.record(seconds: .nan)
    window.record(seconds: -1)
    #expect(window.summary.count == 100)
    for _ in 0..<2048 { window.record(seconds: 0.002) }
    #expect(window.summary.retainedSamples == 1024)
    #expect(window.summary.count == 2148)
    #expect(window.summary.p95MS == 2)
  }
  @Test func contextReplacementRejectsOldMetricsAndPreservesActualWorkspaceOwnership() {
    let metrics = CameraCaptureMetrics()
    let old = CameraTestFrames.context()
    let current = CameraTestFrames.context(2)
    metrics.begin(old)
    metrics.workspace(bytes: 512)
    metrics.callback(old, seconds: 0.01)
    metrics.begin(current)
    metrics.callback(old, seconds: 10)
    metrics.configuration(old, description: "stale")
    metrics.rejected(old)
    #expect(metrics.snapshot.callback.count == 0)
    #expect(metrics.snapshot.configurationDetails != "stale")
    #expect(metrics.snapshot.processingRejects == 0)
    #expect(metrics.snapshot.workspaceBytes == 512)
    metrics.workspace(bytes: 0)
    #expect(metrics.snapshot.workspaceBytes == 0)
    #expect(metrics.snapshot.peakWorkspaceBytes == 512)
  }
  @Test func combinedPeakTracksSimultaneousResourcesRatherThanAddingSeparatePeaks() {
    let metrics = CameraCaptureMetrics()
    metrics.begin(CameraTestFrames.context())
    metrics.sourceBytes(1024)
    metrics.sourceBytes(0)
    metrics.workspace(bytes: 512)
    #expect(metrics.snapshot.ownedPixelBytes == 512)
    #expect(metrics.snapshot.peakOwnedPixelBytes == 1024)
    metrics.sourceBytes(768)
    #expect(metrics.snapshot.peakOwnedPixelBytes == 1280)
    metrics.workspace(bytes: 0)
    metrics.sourceBytes(0)
    #expect(metrics.snapshot.ownedPixelBytes == 0)
    #expect(metrics.snapshot.peakOwnedPixelBytes == 1280)
  }
  @Test func syntheticMetricsPreserveSourceAndSeparateWaitingFromProcessing() throws {
    let store = FrameStore()
    let context = CameraTestFrames.context()
    _ = store.begin(context)
    let buffer = try CameraTestFrames.buffer()
    let metadata = try CameraTestFrames.offer(buffer, store: store, context: context)
    let lease = try CameraTestFrames.lease(store, context)
    store.metrics.delivered(metadata)
    let started = lease.frame.admittedAt + 1
    store.metrics.completed(lease.frame, startedAt: started, completedAt: started + 2)
    let snapshot = store.metrics.snapshot
    #expect(snapshot.lastFrame == metadata)
    #expect(snapshot.admitted == 1)
    #expect(snapshot.delivered == 1)
    #expect(snapshot.processed == 1)
    #expect(snapshot.wait.p50MS == 1000)
    #expect(snapshot.processing.p95MS == 2000)
    #expect(snapshot.endToEnd.count == 1)
    store.complete(lease)
    store.end(context)
  }
  @Test func reconstructionWorkspaceReportsItsPoolAndResetsToZero() async throws {
    let store = FrameStore()
    let context = CameraTestFrames.context()
    _ = store.begin(context)
    let source = try CameraTestFrames.buffer()
    _ = try CameraTestFrames.offer(source, store: store, context: context)
    let lease = try CameraTestFrames.lease(store, context)
    let sink = CameraCopySink(metrics: store.metrics)
    try await sink.consume(lease.frame)
    let bytes = store.metrics.snapshot.workspaceBytes
    #expect(bytes >= 8 * 8 * 4)
    #expect(bytes <= 4 * 1024 * 1024)
    await sink.reset()
    #expect(store.metrics.snapshot.workspaceBytes == 0)
    #expect(store.metrics.snapshot.peakWorkspaceBytes == bytes)
    store.complete(lease)
    store.end(context)
  }
  #if DEBUG
    @MainActor @Test func elapsedFreezesAndRepeatedCleanupDoesNotReplaceStopMeasurement()
      async throws
    {
      let clock = DiagnosticTestClock()
      let driver = ControlledCameraDriver(hold: true)
      let camera = CameraPipeline(
        permission: ControlledCameraPermission(.authorized), driver: driver)
      let model = LiveInputDiagnosticsModel(camera: camera, now: { clock.time })
      model.start()
      await driver.untilStarted()
      clock.time = 12
      await model.stopAndExport()
      #expect(model.elapsedSeconds == 2)
      let frozenDetails = model.details
      clock.time = 50
      await model.stopAndExport()
      #expect(model.elapsedSeconds == 2)
      #expect(model.details == frozenDetails)
      #expect(await driver.stops == 1)
      await driver.release()
    }
    @MainActor @Test func compositionRetainsOneCameraAndReportsPermissionWithoutStarting()
      async throws
    {
      let dependencies = AppDependencies.shared
      #expect(dependencies.camera === dependencies.cameraDiagnostics.camera)
      #expect(dependencies === AppDependencies.shared)
      let driver = ControlledCameraDriver()
      let camera = CameraPipeline(permission: ControlledCameraPermission(.denied), driver: driver)
      let model = LiveInputDiagnosticsModel(camera: camera)
      await model.refresh()
      #expect(model.permission == "denied")
      #expect(model.details.contains("not calibrated gameplay evidence"))
      #expect(model.details.contains("No validated camera frame"))
      #expect(await driver.starts == 0)
      #expect(camera.status == .stopped)
    }
  #endif
}

#if DEBUG
  @MainActor private final class DiagnosticTestClock { var time = 10.0 }
#endif
