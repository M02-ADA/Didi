#if DEBUG
import Foundation
import Testing
@testable import Sedactive

nonisolated struct VisionPreviewTests {
  @Test func enablementRequiresIsolatedIdentityAndBothExplicitArguments() {
    let id = VisionPreviewDiagnostics.bundleID
    let args = ["--camera-diagnostics", "--vision-preview"]
    #expect(VisionPreviewDiagnostics.enabled(bundleID: id, arguments: args))
    for other in ["com.Edward-Kristian.Sedactive", "com.Edward-Kristian.Sedactive.B2bDiagnostics",
      "com.Edward-Kristian.Sedactive.MaskFeasibility"] {
      #expect(!VisionPreviewDiagnostics.enabled(bundleID: other, arguments: args))
    }
    #expect(!VisionPreviewDiagnostics.enabled(bundleID: id, arguments: [args[0]]))
    #expect(!VisionPreviewDiagnostics.enabled(bundleID: id, arguments: [args[1]]))
  }
  @Test func maskOutcomeAndStopReasonStaySeparateAndSourceQualified() throws {
    var f = try TrackingIntegrationFixture(); try f.bind()
    try f.gate.configureBody(LiveVisionFixtures.configuration(f.context.generation))
    _ = try f.gate.requestCalibration(id: UUID())
    let pose = try f.result(3, 0.25, LiveVisionFixtures.standingPair)
    let stamp = try #require(f.gate.admit(pose.source)); try #require(try f.finish(pose, stamp: stamp))
    let receipt = try #require(f.gate.snapshot.latest)
    try #require(f.gate.beginMask(pose: pose, admission: stamp, receipt: receipt))
    let mask = PersonMaskObservation(source: pose.source, quality: .unsupportedOutput,
      regions: [:], outputBytes: 0, serviceSeconds: 0.2)
    f.clock.time = 0.45
    f.gate.finishMask(mask, pose: pose, admission: stamp, receipt: receipt)
    let read = f.gate.readVisionPreviewMask()
    #expect(read.last?.source == pose.source && read.last?.bindingRevision == stamp.revision)
    #expect(read.last?.quality == .unsupportedOutput)
    #expect(f.gate.readBody().calibration.phase == .stoppedForReview)
    let text = VisionPreviewDiagnostics.text(body: f.gate.readBody(), mask: read)
    #expect(text.contains("unsupportedOutput") && text.contains("stoppedForReview"))
    #expect(text.contains("accepted players: 0/2") && text.contains("UNAVAILABLE"))
    f.gate.sourceLost(f.context)
    #expect(f.gate.readVisionPreviewMask().last == nil)
  }
  @Test func revokedOrDifferentSourceCannotPublishPreviewDiagnostic() throws {
    var f = try TrackingIntegrationFixture(); try f.bind()
    try f.gate.configureBody(LiveVisionFixtures.configuration(f.context.generation))
    _ = try f.gate.requestCalibration(id: UUID())
    let pose = try f.result(3, 0.25, LiveVisionFixtures.standingPair)
    let stamp = try #require(f.gate.admit(pose.source)); try #require(try f.finish(pose, stamp: stamp))
    let receipt = try #require(f.gate.snapshot.latest)
    try #require(f.gate.beginMask(pose: pose, admission: stamp, receipt: receipt))
    f.gate.revoke()
    f.gate.finishMask(LiveVisionFixtures.mask(pose), pose: pose, admission: stamp, receipt: receipt)
    #expect(f.gate.readVisionPreviewMask().last == nil)
    #expect(f.gate.readBody().calibration.candidate == nil)
  }
}

@MainActor struct VisionPreviewModelTests {
  @Test func previewRunsExistingProviderDisarmedAndCannotSilentlyRestart() async throws {
    let driver = ControlledCameraDriver()
    let camera = CameraPipeline(permission: ControlledCameraPermission(.authorized), driver: driver)
    let provider = BodyInputService(camera: camera)
    let model = LiveInputDiagnosticsModel(camera: camera, bodyInput: provider, visionPreview: true)
    #expect(await driver.starts == 0)
    let operation = try #require(model.start())
    await operation.value
    await model.refresh()
    #expect(await driver.starts == 1)
    #expect(provider.currentContext?.isActive == true)
    #expect(camera.frames.tracking.snapshot.requestID == nil)
    #expect(model.visionDetails.contains("E03: NOT RUN"))
    #expect(model.visionDetails.contains("accepted players: 0/2"))
    model.collectStandingCandidate()
    #expect(model.message.contains("Standing collection refused"))
    #expect(provider.calibrationProgress.request == nil)
    await model.stopAndExport()
    #expect(provider.status == .stopped && provider.currentContext?.isActive == false)
    #expect(model.start() == nil)
    #expect(await driver.starts == 1)
    #expect(camera.frames.tracking.snapshot.acknowledgment == nil)
  }
}
#endif
