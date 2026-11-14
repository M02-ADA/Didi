import Foundation
import Testing

@testable import Sedactive

actor ControlledCameraPermission: CameraPermissionChecking {
  private let answer: CameraPermission
  private let hold: Bool
  private var response: CheckedContinuation<Bool, Never>?
  private var entered: CheckedContinuation<Void, Never>?
  private(set) var requests = 0
  init(_ answer: CameraPermission, hold: Bool = false) {
    self.answer = answer
    self.hold = hold
  }
  func status() -> CameraPermission { answer }
  func request() async -> Bool {
    requests += 1
    if !hold { return true }
    return await withCheckedContinuation {
      response = $0
      entered?.resume()
      entered = nil
    }
  }
  func untilRequested() async {
    if response != nil { return }
    await withCheckedContinuation { entered = $0 }
  }
  func resolve(_ value: Bool) {
    response?.resume(returning: value)
    response = nil
  }
}
actor ControlledCameraDriver: CameraDriving {
  private let failure: CameraFailure?
  private let hold: Bool
  private var gate: CheckedContinuation<Void, Never>?
  private var entry: CheckedContinuation<Void, Never>?
  private(set) var starts = 0, stops = 0
  private var running = true
  private var interrupted = false
  private(set) var context: CameraSourceContext?
  private(set) var events: CameraEventChannel?
  init(failure: CameraFailure? = nil, hold: Bool = false) {
    self.failure = failure
    self.hold = hold
  }
  func start(
    configuration: CameraCaptureConfiguration, context: CameraSourceContext,
    frames: FrameStore, events: CameraEventChannel
  ) async throws -> CameraNegotiatedConfiguration {
    starts += 1
    self.context = context
    self.events = events
    if hold {
      await withCheckedContinuation {
        gate = $0
        entry?.resume()
        entry = nil
      }
    }
    if let failure { throw failure }
    return CameraNegotiatedConfiguration(
      deviceID: "synthetic-front", deviceName: "Synthetic",
      deviceType: "synthetic", nativeWidth: 1280, nativeHeight: 720,
      outputWidth: 1280, outputHeight: 720, framesPerSecond: 30, rotationAngle: 180,
      mirrored: false, centerStageActive: false, stabilizationEnabled: false,
      sessionPreset: "synthetic")
  }
  func stop(context: CameraSourceContext) {
    if self.context == context {
      stops += 1
      self.context = nil
    }
  }
  func resume(context: CameraSourceContext) -> CameraSourceReadiness {
    guard self.context == context else { return .stopped }
    if interrupted { return .interrupted }
    return running ? .running : .stopped
  }
  func setInterrupted(_ value: Bool) { interrupted = value }
  func setRunning(_ value: Bool) { running = value }
  func untilStarted() async {
    if gate != nil { return }
    await withCheckedContinuation { entry = $0 }
  }
  func release() {
    gate?.resume()
    gate = nil
  }
  func emit(_ event: CameraHardwareEvent) {
    switch event {
    case .interrupted: interrupted = true
    case .interruptionEnded, .started: interrupted = false
    default: break
    }
    events?.emit(event)
  }
}
actor ControlledCameraSink: CameraFrameSink {
  private var gate: CheckedContinuation<Void, Never>?
  private var entry: CheckedContinuation<Void, Never>?
  private(set) var consumed = 0, resets = 0
  func consume(_ frame: CameraSourceFrame) async throws {
    consumed += 1
    await withCheckedContinuation {
      gate = $0
      entry?.resume()
      entry = nil
    }
    try Task.checkCancellation()
  }
  func reset() { resets += 1 }
  func untilEntered() async {
    if gate != nil { return }
    await withCheckedContinuation { entry = $0 }
  }
  func release() {
    gate?.resume()
    gate = nil
  }
}
@MainActor private final class CameraStateRecorder {
  var values: [CameraPipelineStatus] = []
  private var waiting: (CameraPipelineStatus, CheckedContinuation<Void, Never>)?
  func append(_ state: CameraPipelineState) {
    values.append(state.status)
    if waiting?.0 == state.status {
      waiting?.1.resume()
      waiting = nil
    }
  }
  func until(_ status: CameraPipelineStatus, after index: Int = 0) async {
    if values.dropFirst(index).contains(status) { return }
    await withCheckedContinuation { waiting = (status, $0) }
  }
}

@MainActor struct CameraPipelineTests {
  @Test(arguments: [CameraPermission.denied, .restricted])
  func deniedOrRestrictedNeverStartsCapture(_ permission: CameraPermission) async throws {
    let authorizer = ControlledCameraPermission(permission)
    let driver = ControlledCameraDriver()
    let pipeline = CameraPipeline(permission: authorizer, driver: driver)
    let expected: CameraFailure = permission == .denied ? .permissionDenied : .permissionRestricted
    await #expect(throws: expected) { try await pipeline.start(generation: UUID()) }
    #expect(await driver.starts == 0)
    #expect(await authorizer.requests == 0)
    #expect(pipeline.status == .failed(expected))
    await pipeline.stop()
  }
  @Test(arguments: [CameraPermission.authorized, .notDetermined])
  func authorizedOrGrantedStartsOnceAndRepeatedOperationsAreCompatible(
    _ permission: CameraPermission
  ) async throws {
    let authorizer = ControlledCameraPermission(permission)
    let driver = ControlledCameraDriver()
    let pipeline = CameraPipeline(permission: authorizer, driver: driver)
    let generation = UUID()
    try await pipeline.start(generation: generation)
    try await pipeline.start(generation: generation)
    #expect(pipeline.status == .running)
    #expect(pipeline.negotiated?.outputWidth == 1280)
    #expect(await driver.starts == 1)
    #expect(await authorizer.requests == (permission == .notDetermined ? 1 : 0))
    await #expect(throws: CameraFailure.operationConflict) {
      try await pipeline.start(generation: UUID())
    }
    await pipeline.stop()
    await pipeline.stop()
    #expect(await driver.stops == 1)
    #expect(pipeline.status == .stopped)
    await #expect(throws: CameraFailure.staleOperation) {
      try await pipeline.start(generation: generation)
    }
  }
  @Test func stopDuringPermissionRejectsLateGrantedReply() async throws {
    let permission = ControlledCameraPermission(.notDetermined, hold: true)
    let driver = ControlledCameraDriver()
    // Use the asserted driver instance; no native objects or permission prompt are involved.
    let source = CameraPipeline(permission: permission, driver: driver)
    let start = Task { try await source.start(generation: UUID()) }
    await permission.untilRequested()
    await source.stop()
    #expect(source.status == .stopped)
    await permission.resolve(true)
    await #expect(throws: CancellationError.self) { try await start.value }
    #expect(await driver.starts == 0)
    #expect(source.status == .stopped)
  }
  @Test func deniedPermissionReplyNeverStartsCapture() async throws {
    let permission = ControlledCameraPermission(.notDetermined, hold: true)
    let driver = ControlledCameraDriver()
    let source = CameraPipeline(permission: permission, driver: driver)
    let start = Task { try await source.start(generation: UUID()) }
    await permission.untilRequested()
    await permission.resolve(false)
    await #expect(throws: CameraFailure.permissionDenied) { try await start.value }
    #expect(await driver.starts == 0)
    await source.stop()
  }
  @Test func cancelledStartupReleasesWithoutStartingAfterAuthorization() async throws {
    let permission = ControlledCameraPermission(.notDetermined, hold: true)
    let driver = ControlledCameraDriver()
    let source = CameraPipeline(permission: permission, driver: driver)
    let recorder = CameraStateRecorder()
    _ = try source.observe { recorder.append($0) }
    let start = Task { try await source.start(generation: UUID()) }
    await permission.untilRequested()
    let stopStart = recorder.values.count
    start.cancel()
    await recorder.until(.stopped, after: stopStart)
    await permission.resolve(true)
    await #expect(throws: CancellationError.self) { try await start.value }
    #expect(await driver.starts == 0)
  }
  @Test func concurrentCompatibleStartSharesOneOperationAndFailureCannotBecomeRunning() async throws
  {
    let driver = ControlledCameraDriver(hold: true)
    let source = CameraPipeline(permission: ControlledCameraPermission(.authorized), driver: driver)
    let recorder = CameraStateRecorder()
    _ = try source.observe { recorder.append($0) }
    let generation = UUID()
    let first = Task { try await source.start(generation: generation) }
    await driver.untilStarted()
    let second = Task { try await source.start(generation: generation) }
    await driver.emit(.failure(.runtimeError(17)))
    await recorder.until(.failed(.runtimeError(17)))
    await driver.release()
    await #expect(throws: CameraFailure.runtimeError(17)) { try await first.value }
    await #expect(throws: CameraFailure.self) { try await second.value }
    #expect(await driver.starts == 1)
    #expect(source.status == .failed(.runtimeError(17)))
    await source.stop()
  }
  @Test func interruptionAndRuntimeFailureAreObservedWithoutFrames() async throws {
    let driver = ControlledCameraDriver()
    let source = CameraPipeline(permission: ControlledCameraPermission(.authorized), driver: driver)
    let recorder = CameraStateRecorder()
    _ = try source.observe { recorder.append($0) }
    #expect(recorder.values == [.stopped])
    try await source.start(generation: UUID())
    let context = try #require(source.state.context)
    let recoveryStart = recorder.values.count
    await driver.emit(.interrupted(7))
    await driver.emit(.stopped)  // Native stop as part of interruption is not fatal.
    await recorder.until(.interrupted(7))
    #expect(!source.frames.isCurrent(context))
    await driver.emit(.interruptionEnded)
    await recorder.until(.running, after: recoveryStart)
    #expect(source.frames.isCurrent(context))
    await driver.emit(.failure(.runtimeError(42)))
    await recorder.until(.failed(.runtimeError(42)))
    #expect(!source.frames.isCurrent(context))
    #expect(source.frames.diagnostics.sourceCallbacks == 0)
    await source.stop()
  }
  @Test func sourceStopWithoutInterruptionFailsButDelayedStopCannotHideRunningSource() async throws
  {
    let driver = ControlledCameraDriver()
    let source = CameraPipeline(permission: ControlledCameraPermission(.authorized), driver: driver)
    let recorder = CameraStateRecorder()
    _ = try source.observe { recorder.append($0) }
    try await source.start(generation: UUID())
    let current = try #require(source.state.context)
    let recoveryStart = recorder.values.count
    // A stale stop signal suspends admission immediately; a following interruption/start
    // pair deterministically acknowledges source revalidation without sleeps.
    await driver.emit(.stopped)
    await driver.emit(.interrupted(1))
    await driver.emit(.interruptionEnded)
    await recorder.until(.interrupted(1))
    await recorder.until(.running, after: recoveryStart)
    #expect(source.frames.isCurrent(current))
    await driver.setRunning(false)
    await driver.emit(.stopped)
    await recorder.until(.failed(.sourceStopped))
    #expect(!source.frames.isCurrent(current))
    await source.stop()
  }
  @Test func stopNotificationBeforeInterruptionDoesNotBecomeFatalFailure() async throws {
    let driver = ControlledCameraDriver()
    let source = CameraPipeline(permission: ControlledCameraPermission(.authorized), driver: driver)
    let recorder = CameraStateRecorder()
    _ = try source.observe { recorder.append($0) }
    try await source.start(generation: UUID())
    let context = try #require(source.state.context)
    let recoveryStart = recorder.values.count
    await driver.setInterrupted(true)
    await driver.emit(.stopped)
    await recorder.until(.interrupted(nil))
    #expect(!source.frames.isCurrent(context))
    await driver.emit(.interrupted(8))
    await recorder.until(.interrupted(8))
    await driver.emit(.interruptionEnded)
    await recorder.until(.running, after: recoveryStart)
    await driver.emit(.failure(.geometryChanged))
    await recorder.until(.failed(.geometryChanged))
    await source.stop()
  }
  @Test func lateOldEventsCannotChangeReplacementGeneration() async throws {
    let driver = ControlledCameraDriver()
    let source = CameraPipeline(permission: ControlledCameraPermission(.authorized), driver: driver)
    try await source.start(generation: UUID())
    let old = try #require(await driver.events)
    let oldContext = try #require(source.state.context)
    await source.stop()
    try await source.start(generation: UUID())
    old.emit(.failure(.geometryChanged))
    #expect(source.status == .running)
    #expect(source.state.context?.epoch != oldContext.epoch)
    #expect(throws: CameraFrameError.staleContext) { try source.frames.nextIdentity(oldContext) }
    await source.stop()
  }
  @Test func cancelledDelayedProcessingRetainsBudgetAndRestartWaitsForTheSingleWorker() async throws
  {
    let driver = ControlledCameraDriver()
    let sink = ControlledCameraSink()
    let source = CameraPipeline(
      permission: ControlledCameraPermission(.authorized), driver: driver, sink: sink)
    let recorder = CameraStateRecorder()
    _ = try source.observe { recorder.append($0) }
    try await source.start(generation: UUID())
    let old = try #require(source.state.context)
    let buffer = try CameraTestFrames.buffer()
    _ = try CameraTestFrames.offer(buffer, store: source.frames, context: old)
    await sink.untilEntered()
    let stopStart = recorder.values.count
    let stopping = Task { await source.stop() }
    await recorder.until(.stopped, after: stopStart)
    #expect(source.frames.usage.frames == 1)
    let restarting = Task { try await source.start(generation: UUID()) }
    await sink.release()
    await stopping.value
    try await restarting.value
    #expect(await driver.starts == 2)
    #expect(await sink.consumed == 1)
    #expect(source.frames.usage.frames == 0)
    await source.stop()
  }
  @Test(arguments: ["preset", "pixel format", "FPS", "camera"])
  func unsupportedConfigurationStopsExplicitly(_ requirement: String) async throws {
    let failure = CameraFailure.unsupported(requirement, alternatives: ["synthetic alternative"])
    let source = CameraPipeline(
      permission: ControlledCameraPermission(.authorized),
      driver: ControlledCameraDriver(failure: failure))
    await #expect(throws: failure) { try await source.start(generation: UUID()) }
    #expect(source.status == .failed(failure))
    #expect(source.state.context.map { source.frames.isCurrent($0) } == false)
    await source.stop()
  }
  @Test func eventOverflowFailsClosedAndCannotLeaveImagesCurrent() async throws {
    let store = FrameStore()
    let context = CameraTestFrames.context()
    _ = store.begin(context)
    let channel = CameraEventChannel(context: context, frames: store)
    for _ in 0..<20 { channel.emit(.started) }
    var last: CameraHardwareEvent?
    for await event in channel.stream { last = event }
    if case .failure(.eventOverflow) = last {
    } else {
      Issue.record("Missing terminal overflow failure")
    }
    #expect(!store.isCurrent(context))
  }
  @Test
  func capabilitySelectionSupportsCenterStageFrontAndNeverUsesRearOrSilentlyTriesAnotherDevice()
    throws
  {
    let valid = CameraFormatCapability(
      index: 0, width: 1920, height: 1080,
      minimumFPS: 24, maximumFPS: 60, centerStageSupported: true)
    let front = CameraDeviceCapability(
      id: "front", name: "front", kind: .trueDepth, isFront: true, formats: [valid])
    let rear = CameraDeviceCapability(
      id: "rear", name: "rear", kind: .ultraWide, isFront: false, formats: [valid])
    #expect(
      try CameraCapabilities.select([rear, front], configuration: .experimental).0.id == "front")
    #expect(throws: CameraFailure.self) {
      try CameraCapabilities.select([rear], configuration: .experimental)
    }
    for bad in [
      CameraFormatCapability(
        index: 0, width: 640, height: 480, minimumFPS: 30, maximumFPS: 30,
        centerStageSupported: false),
      CameraFormatCapability(
        index: 0, width: 1280, height: 720, minimumFPS: 60, maximumFPS: 60,
        centerStageSupported: false),
    ] {
      let preferred = CameraDeviceCapability(
        id: "preferred", name: "ultra", kind: .ultraWide, isFront: true, formats: [bad])
      #expect(throws: CameraFailure.self) {
        try CameraCapabilities.select([preferred, front], configuration: .experimental)
      }
    }
  }
}
