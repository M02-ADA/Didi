import AVFoundation
import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import Synchronization
import UIKit

// Capture-only configuration and status. CP1 hardware-independent contracts stay unchanged.
nonisolated enum CameraFailure: Error, Equatable, Sendable {
  case permissionDenied, permissionRestricted, cameraUnavailable
  case unsupported(String, alternatives: [String])
  case clockNormalizationFailure, geometryChanged, eventOverflow, sourceStopped
  case runtimeError(Int)
  case processingFailure, operationConflict, staleOperation
}
nonisolated struct CameraCaptureConfiguration: Equatable, Sendable {
  let width = 1280, height = 720, framesPerSecond = 30
  let maximumFrameBytes = 4 * 1024 * 1024
  let maximumRawBytes = 12 * 1024 * 1024
  static let experimental = Self()
}
nonisolated enum CameraPermission: Sendable { case authorized, denied, restricted, notDetermined }
protocol CameraPermissionChecking: Actor {
  func status() async -> CameraPermission
  func request() async -> Bool
}
actor SystemCameraPermission: CameraPermissionChecking {
  private var requestTask: Task<Bool, Never>?
  func status() -> CameraPermission {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: .authorized
    case .denied: .denied
    case .restricted: .restricted
    case .notDetermined: .notDetermined
    @unknown default: .restricted
    }
  }
  func request() async -> Bool {
    if let requestTask { return await requestTask.value }
    let task = Task { await AVCaptureDevice.requestAccess(for: .video) }
    requestTask = task
    let granted = await task.value
    requestTask = nil
    return granted
  }
}
nonisolated enum CameraDeviceKind: Sendable { case external, ultraWide, trueDepth, wide }
nonisolated struct CameraFormatCapability: Sendable {
  let index: Int, width: Int, height: Int
  let minimumFPS: Double, maximumFPS: Double
  let centerStageSupported: Bool
}
nonisolated struct CameraDeviceCapability: Sendable {
  let id: String, name: String
  let kind: CameraDeviceKind
  let isFront: Bool
  let formats: [CameraFormatCapability]
}
nonisolated struct CameraCaptureCandidate: Sendable {
  let device: CameraDeviceCapability
  let format: CameraFormatCapability
  let framesPerSecond: Int
}

nonisolated enum CameraCapabilities {
  static func candidates(_ devices: [CameraDeviceCapability], configuration: CameraCaptureConfiguration)
    throws -> [CameraCaptureCandidate]
  {
    let external = devices.filter { $0.kind == .external }.sorted { $0.id < $1.id }
    let front = devices.filter { $0.kind != .external && $0.isFront }.sorted {
      let a = frontPriority($0), b = frontPriority($1)
      return a == b ? $0.id < $1.id : a < b
    }
    let orderedDevices = external + front
    let candidates = orderedDevices.flatMap { device in
      compatibleFormats(for: device, configuration: configuration).prefix(device.kind == .external ? 3 : 1)
    }
    guard !candidates.isEmpty else {
      let alternatives = orderedDevices.flatMap { device in
        device.formats.prefix(8).map {
          "\(device.name): \($0.width)x\($0.height) \($0.minimumFPS)...\($0.maximumFPS) FPS"
        }
      }
      throw CameraFailure.unsupported(
        "external UVC or front camera with a compatible landscape format",
        alternatives: Array(alternatives.prefix(12)))
    }
    return candidates
  }

  private static func frontPriority(_ device: CameraDeviceCapability) -> Int {
    if device.kind == .ultraWide { return 0 }
    // Some Center Stage front cameras are advertised as TrueDepth or Wide.
    if device.formats.contains(where: \.centerStageSupported) { return 1 }
    return 2
  }

  private static func compatibleFormats(for device: CameraDeviceCapability, configuration: CameraCaptureConfiguration)
    -> [CameraCaptureCandidate]
  {
    let fps = configuration.framesPerSecond
    let rates = device.kind == .external ? [fps, 25, 24] : [fps]
    let ranked = device.formats.compactMap { format -> (candidate: CameraCaptureCandidate, outputPixels: Int, nativePixels: Int64)? in
      guard format.minimumFPS.isFinite, format.maximumFPS.isFinite,
            format.minimumFPS <= format.maximumFPS,
            let rate = rates.first(where: { (format.minimumFPS...format.maximumFPS).contains(Double($0)) }),
            let size = outputSize(for: format, kind: device.kind, configuration: configuration) else { return nil }
      let candidate = CameraCaptureCandidate(device: device, format: format, framesPerSecond: rate)
      return (candidate, size.width * size.height, Int64(format.width) * Int64(format.height))
    }.sorted {
      // Prefer the target frame rate, then sharper output within the Vision pixel budget.
      if $0.candidate.framesPerSecond != $1.candidate.framesPerSecond {
        return $0.candidate.framesPerSecond > $1.candidate.framesPerSecond
      }
      if $0.outputPixels != $1.outputPixels { return $0.outputPixels > $1.outputPixels }
      if $0.nativePixels != $1.nativePixels { return $0.nativePixels < $1.nativePixels }
      return $0.candidate.format.index < $1.candidate.format.index
    }
    var seenFormats: Set<Int> = []
    return ranked.map(\.candidate).filter { seenFormats.insert($0.format.index).inserted }
  }

  /// Preserve the active format's aspect without sending more pixels to Vision than 720p.
  static func outputSize(for format: CameraFormatCapability, kind: CameraDeviceKind,
                         configuration: CameraCaptureConfiguration) -> (width: Int, height: Int)? {
    guard format.width > 0, format.height > 0, format.width <= Int(Int32.max),
          format.height <= Int(Int32.max) else { return nil }
    if format.width >= configuration.width, format.height >= configuration.height,
       Int64(format.width) * Int64(configuration.height) == Int64(format.height) * Int64(configuration.width) {
      return (configuration.width, configuration.height)
    }
    guard kind == .external, format.width > format.height else { return nil }
    var a = format.width, b = format.height
    while b > 0 { (a, b) = (b, a % b) }
    let unitWidth = format.width / a, unitHeight = format.height / a
    let multiple = min(configuration.width / unitWidth, configuration.height / unitHeight, a) / 2 * 2
    let width = unitWidth * multiple, height = unitHeight * multiple
    return width >= 640 && height >= 360 ? (width, height) : nil
  }
}
nonisolated struct CameraNegotiatedConfiguration: Equatable, Sendable {
  let deviceID: String, deviceName: String, deviceType: String
  let nativeWidth: Int, nativeHeight: Int
  let outputWidth: Int, outputHeight: Int
  let framesPerSecond: Int
  let rotationAngle: Double
  let mirrored: Bool
  let centerStageActive: Bool
  let stabilizationEnabled: Bool
  let sessionPreset: String
  // Actual row stride is reported in CameraFrameMetadata, never guessed here.
}
nonisolated enum CameraPipelineStatus: Equatable, Sendable {
  case stopped, requestingPermission, configuring, running
  case interrupted(Int?)
  case failed(CameraFailure)
}
nonisolated struct CameraPipelineState: Equatable, Sendable {
  let revision: UInt64
  let context: CameraSourceContext?
  let status: CameraPipelineStatus
  let negotiated: CameraNegotiatedConfiguration?
}
nonisolated enum CameraHardwareEvent: Sendable {
  case interrupted(Int?)
  case interruptionEnded, started, stopped
  case failure(CameraFailure)
}
/// Independent bounded native signal path. Overflow is explicit fail-closed, never hidden running state.
nonisolated final class CameraEventChannel: Sendable {
  let context: CameraSourceContext
  let stream: AsyncStream<CameraHardwareEvent>
  private let continuation: AsyncStream<CameraHardwareEvent>.Continuation
  private struct Signals {
    var closed = false
    var background: (any NSObjectProtocol)?
  }
  private let signals = Mutex(Signals())
  private let frames: FrameStore
  private let notificationCenter: NotificationCenter
  init(context: CameraSourceContext, frames: FrameStore,
    notificationCenter: NotificationCenter = .default) {
    self.notificationCenter = notificationCenter
    self.context = context
    self.frames = frames
    let pair = AsyncStream<CameraHardwareEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
    stream = pair.stream
    continuation = pair.continuation
    signals.withLock {
      $0.background = notificationCenter.addObserver(
        forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
      ) { [weak self] _ in self?.emit(.interrupted(nil)) }
    }
  }
  deinit {
    signals.withLock {
      if let token = $0.background { notificationCenter.removeObserver(token) }
    }
  }
  func emit(_ event: CameraHardwareEvent) {
    signals.withLock {
      guard !$0.closed else { return }
      switch event {
      case .interrupted, .stopped:
        frames.tracking.sourceLost(context)
        frames.suspend(context)
      case .failure:
        frames.tracking.sourceLost(context)
        frames.end(context)
      default: break
      }
      if case .dropped = continuation.yield(event) {
        frames.tracking.sourceLost(context)
        frames.end(context)
        continuation.yield(.failure(.eventOverflow))
        $0.closed = true
        continuation.finish()
      } else if case .failure = event {
        $0.closed = true
        continuation.finish()
      }
    }
  }
  func finish() {
    signals.withLock {
      $0.closed = true
      continuation.finish()
      if let token = $0.background { notificationCenter.removeObserver(token) }
      $0.background = nil
    }
  }
}
nonisolated enum CameraSourceReadiness: Sendable { case running, interrupted, stopped }
protocol CameraDriving: Actor {
  func start(
    configuration: CameraCaptureConfiguration, context: CameraSourceContext,
    frames: FrameStore, events: CameraEventChannel
  ) async throws -> CameraNegotiatedConfiguration
  func stop(context: CameraSourceContext) async
  func resume(context: CameraSourceContext) async throws -> CameraSourceReadiness
}

/// The sole capture lifecycle facade. No view owns a camera. DEBUG diagnostics borrow this retained instance.
@MainActor final class CameraPipeline {
  let frames: FrameStore
  private let permission: any CameraPermissionChecking
  private let driver: any CameraDriving
  private let sink: any CameraFrameSink
  private var context: CameraSourceContext?
  private var configuration: CameraCaptureConfiguration?
  private var usedGenerations: Set<UUID> = []
  private var geometryRevision: UInt64 = 0
  private var revision: UInt64 = 0
  private var operation: Task<Void, Error>?
  private var processing: (epoch: UUID, task: Task<Void, Never>)?
  private var signals: Task<Void, Never>?
  private var channel: CameraEventChannel?
  private var observer: (UUID, @MainActor (CameraPipelineState) -> Void)?
  private let notificationCenter: NotificationCenter
  private var notifying = false
  private var bodySessionOwner: UUID?
  private var bodySessionStopping = false
  private var bindingRestart: (request: CameraBindingRequest, token: UUID, task: Task<Void, Error>)?
  private(set) var status: CameraPipelineStatus = .stopped
  private(set) var negotiated: CameraNegotiatedConfiguration?
  /// Display-only handle on the retained capture session, for the setup
  /// screen's live camera image. Nil with a non-native (test) driver.
  var previewSession: AVCaptureSession? { (driver as? AVCameraDriver)?.previewSession }
  var state: CameraPipelineState {
    CameraPipelineState(
      revision: revision, context: context, status: status, negotiated: negotiated)
  }
  init(
    permission: any CameraPermissionChecking = SystemCameraPermission(),
    driver: any CameraDriving = AVCameraDriver(), sink: (any CameraFrameSink)? = nil,
    notificationCenter: NotificationCenter = .default
  ) {
    self.notificationCenter = notificationCenter
    self.permission = permission
    self.driver = driver
    let store = FrameStore()
    frames = store
    store.tracking.observeApplicationLifecycle(notificationCenter,
      initiallyForeground: UIApplication.shared.applicationState != .background)
    self.sink = sink ?? CameraCopySink(metrics: store.metrics, poses: store.poses, tracking: store.tracking)
    #if DEBUG
    // DEBUG mask feasibility spike (Kevin, needs Edo's review): drop counters for its summary.
    MaskBenchmark.recorder.attach { [store] in store.diagnostics }
    #endif
  }
  deinit {
    operation?.cancel()
    bindingRestart?.task.cancel()
    signals?.cancel()
    processing?.task.cancel()
    channel?.finish()
    if let context {
      frames.end(context)
      let native = driver
      Task { await native.stop(context: context) }
    }
  }
  /// One provider owns the retained capture composition until all old work has exited.
  func reserveBodySession() throws -> UUID {
    guard !notifying, bodySessionOwner == nil, context == nil, operation == nil,
      processing == nil, bindingRestart == nil, status == .stopped else {
      throw CameraFailure.operationConflict
    }
    let owner = UUID()
    try frames.tracking.reserveBodySession(owner)
    bodySessionOwner = owner
    return owner
  }
  func ownsBodySession(_ owner: UUID) -> Bool { bodySessionOwner == owner }
  func startBodySession(_ owner: UUID, generation: UUID) async throws {
    guard bodySessionOwner == owner, !bodySessionStopping else { throw CameraFailure.operationConflict }
    try await startCapture(generation: generation, configuration: .experimental, bindingRequest: nil)
  }
  func stopBodySession(_ owner: UUID) {
    guard bodySessionOwner == owner else { return }
    bodySessionStopping = true
    frames.tracking.stopBodySession(owner) // synchronous revocation, including issued receipts
    cancelBinding()
  }
  /// Caller has also joined its provider-start task. No new capture may start during this drain.
  func releaseBodySession(_ owner: UUID) async -> Bool {
    guard bodySessionOwner == owner, bodySessionStopping else { return false }
    let restart = bindingRestart
    let startup = operation
    await stop()
    if let restart {
      _ = try? await restart.task.value
      if bindingRestart?.token == restart.token { bindingRestart = nil }
    }
    if let startup { _ = try? await startup.value }
    await stop()
    if let previous = processing {
      await previous.task.value
      if processing?.epoch == previous.epoch { processing = nil }
    }
    guard context == nil, operation == nil, processing == nil, bindingRestart == nil,
      frames.tracking.releaseBodySession(owner) else { return false }
    bodySessionOwner = nil
    bodySessionStopping = false
    return true
  }
  func makeBindingRequest() throws -> CameraBindingRequest {
    guard !notifying, !bodySessionStopping else { throw CameraFailure.operationConflict }
    return try frames.tracking.makeBindingRequest()
  }
  /// Diagnostic control boundary; camera activation never invokes this implicitly.
  @discardableResult func armBinding(request: CameraBindingRequest) throws -> UInt64 {
    guard !notifying, !bodySessionStopping, bindingRestart == nil, status == .running else {
      throw CameraFailure.operationConflict
    }
    return try frames.tracking.arm(request: request)
  }
  func cancelBinding() {
    bindingRestart?.task.cancel()
    // Keep the single operation occupied until native/worker cleanup actually exits.
    frames.tracking.revoke()
  }
  func requestFullRebind(request: CameraBindingRequest) async throws {
    guard !notifying, !bodySessionStopping else { throw CameraFailure.operationConflict }
    try frames.tracking.validateRequest(request)
    if let bindingRestart {
      guard bindingRestart.request == request else { throw CameraFailure.operationConflict }
      try await awaitRestart(bindingRestart.task, request: request)
      return
    }
    guard try frames.tracking.prepareRestart(request) else { return }
    let config = configuration ?? .experimental
    let token = UUID()
    let task = Task { @MainActor [weak self] in
      guard let self else { throw CancellationError() }
      try self.checkRestart(request)
      await self.stopCapture()
      try self.checkRestart(request)
      try await self.startCapture(generation: UUID(), configuration: config, bindingRequest: request)
      try self.checkRestart(request)
      guard let context = self.context, self.status == .running else {
        throw CameraFailure.operationConflict
      }
      _ = try self.frames.tracking.completeRestart(request, context: context)
    }
    bindingRestart = (request, token, task)
    defer { if bindingRestart?.token == token { bindingRestart = nil } }
    do { try await awaitRestart(task, request: request) }
    catch { frames.tracking.abandonRequest(request); throw error }
  }
  private func awaitRestart(_ task: Task<Void, Error>, request: CameraBindingRequest) async throws {
    let gate = frames.tracking
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
      gate.abandonRequest(request)
    }
  }
  private func checkRestart(_ request: CameraBindingRequest?) throws {
    try Task.checkCancellation()
    guard let request else { return }
    do { try frames.tracking.validateRestart(request) }
    catch { throw CancellationError() }
  }
  func permissionStatus() async -> CameraPermission { await permission.status() }
  func observe(_ callback: @escaping @MainActor (CameraPipelineState) -> Void) throws -> UUID {
    guard !notifying, observer == nil else { throw CameraFailure.operationConflict }
    let token = UUID()
    observer = (token, callback)
    notify(increment: false)
    return token
  }
  func removeObserver(_ token: UUID) { if observer?.0 == token { observer = nil } }
  private func notify(increment: Bool = true) {
    if increment && revision < .max { revision += 1 }
    guard let observer else { return }
    notifying = true
    defer { notifying = false }
    observer.1(state)
  }
  func start(generation: UUID, configuration: CameraCaptureConfiguration = .experimental)
    async throws {
    guard bodySessionOwner == nil else { throw CameraFailure.operationConflict }
    try await startCapture(generation: generation, configuration: configuration, bindingRequest: nil)
  }
  private func startCapture(generation: UUID, configuration: CameraCaptureConfiguration,
    bindingRequest: CameraBindingRequest?) async throws
  {
    guard !notifying, !bodySessionStopping, frames.tracking.isForeground else { throw CameraFailure.operationConflict }
    if bindingRestart != nil, bindingRestart?.request != bindingRequest {
      throw CameraFailure.operationConflict
    }
    try checkRestart(bindingRequest)
    if let context {
      guard context.generation == generation, self.configuration == configuration else {
        throw CameraFailure.operationConflict
      }
      if let operation { return try await operation.value }
      switch status {
      case .running, .interrupted: return
      default: throw CameraFailure.operationConflict
      }
    }
    guard !usedGenerations.contains(generation), geometryRevision < .max else {
      throw CameraFailure.staleOperation
    }
    let allocate = {
      self.usedGenerations.insert(generation)
      self.geometryRevision += 1
      let current = CameraSourceContext(
        generation: generation, epoch: UUID(), geometryRevision: self.geometryRevision)
      self.context = current
      self.configuration = configuration
      self.negotiated = nil
      return current
    }
    let current: CameraSourceContext
    if let bindingRequest {
      current = try frames.tracking.authorizeRestartSource(bindingRequest, allocate: allocate)
    } else { current = allocate() }
    status = .requestingPermission
    notify()
    let task = Task { @MainActor [weak self] in
      guard let self else { throw CancellationError() }
      try await self.startSource(current, configuration: configuration, bindingRequest: bindingRequest)
    }
    operation = task
    do {
      let store = frames
      try await withTaskCancellationHandler {
        try await task.value
      } onCancel: { [weak self] in
        task.cancel()
        store.end(current)
        Task { @MainActor [weak self] in
          if self?.context == current {
            if bindingRequest != nil { await self?.stopCapture() }
            else { await self?.stop() }
          }
        }
      }
      if context == current { operation = nil }
    } catch {
      if context == current {
        operation = nil
        if error is CancellationError {
          if bindingRequest != nil { await stopCapture() }
          else { await stop() }
        } else {
          // Permission/configuration can fail before FrameStore attaches this replacement.
          // Revoke only its exact receipt before awaiting native teardown.
          if let bindingRequest { frames.tracking.abandonRequest(bindingRequest) }
          await fail(current, error: (error as? CameraFailure) ?? .processingFailure)
        }
      }
      throw error
    }
  }
  private func check(_ current: CameraSourceContext) throws {
    guard context == current, !Task.isCancelled else { throw CancellationError() }
  }
  private func startSource(
    _ current: CameraSourceContext, configuration: CameraCaptureConfiguration,
    bindingRequest: CameraBindingRequest?
  ) async throws {
    let authorization = await permission.status()
    try check(current)
    try checkRestart(bindingRequest)
    switch authorization {
    case .denied: throw CameraFailure.permissionDenied
    case .restricted: throw CameraFailure.permissionRestricted
    case .notDetermined:
      let granted = await permission.request()
      try check(current)
      try checkRestart(bindingRequest)
      guard granted else { throw CameraFailure.permissionDenied }
    case .authorized: break
    }
    if let previous = processing { await previous.task.value }
    try check(current)
    try checkRestart(bindingRequest)
    status = .configuring
    notify()
    let wake = frames.begin(current)
    let events = CameraEventChannel(context: current, frames: frames, notificationCenter: notificationCenter)
    channel = events
    signals = Task { @MainActor [weak self] in
      for await event in events.stream {
        guard !Task.isCancelled, let self, self.context == current else { break }
        await self.handle(event, context: current)
      }
    }
    let store = frames
    let sink = self.sink
    let pump = Task { @concurrent in
      for await _ in wake {
        if Task.isCancelled { break }
        await sink.updateTracking()
        do {
          if let lease = try store.acquire(current) {
            do {
              if store.isCurrent(current) {
                let started = CameraHostClock.now()
                try await sink.consume(lease.frame)
                store.metrics.completed(
                  lease.frame, startedAt: started, completedAt: CameraHostClock.now())
              }
            } catch {
              store.metrics.rejected(current)
              events.emit(.failure(.processingFailure))
            }
            store.complete(lease)
          }
        } catch CameraFrameError.staleContext {
          // Interruption suspends admission, but must not destroy the retained worker loop.
          if !store.containsContext(current) { break }
        } catch {
          events.emit(.failure(.processingFailure))
          break
        }
      }
      await sink.reset()
    }
    processing = (current.epoch, pump)
    try checkRestart(bindingRequest)
    let result = try await driver.start(
      configuration: configuration, context: current, frames: frames, events: events)
    try check(current)
    try checkRestart(bindingRequest)
    if case .failed(let failure) = status { throw failure }
    negotiated = result
    if case .configuring = status { status = .running }
    notify()
  }
  func stop() async {
    guard !notifying else { return }
    cancelBinding()
    await stopCapture()
  }
  private func stopCapture() async {
    guard !notifying else { return }
    guard let old = context else { return }
    context = nil
    operation?.cancel()
    operation = nil
    frames.end(old)
    channel?.finish()
    channel = nil
    signals?.cancel()
    signals = nil
    let previous = processing
    previous?.task.cancel()
    status = .stopped
    negotiated = nil
    notify()
    await driver.stop(context: old)
    if let previous {
      await previous.task.value
      if processing?.epoch == previous.epoch { processing = nil }
    }
  }
  private func fail(_ current: CameraSourceContext, error: CameraFailure) async {
    guard context == current else { return }
    frames.tracking.sourceLost(current)
    frames.end(current)
    channel?.finish()
    channel = nil
    processing?.task.cancel()
    status = .failed(error)
    notify()
    await driver.stop(context: current)
    // Failure remains visible until explicit stop; generation cannot silently restart.
  }
  private func handle(_ event: CameraHardwareEvent, context current: CameraSourceContext) async {
    guard context == current else { return }
    if case .failed = status { return }
    switch event {
    case .failure(let error): await fail(current, error: error)
    case .stopped:
      if case .interrupted = status { return }
      do {
        // Native notifications may be delayed; inspect actual source state before failing.
        let readiness = try await driver.resume(context: current)
        guard context == current else { return }
        switch readiness {
        case .running: frames.resume(current)
        case .interrupted:
          status = .interrupted(nil)
          notify()
        case .stopped: await fail(current, error: .sourceStopped)
        }
      } catch { await fail(current, error: (error as? CameraFailure) ?? .geometryChanged) }
    case .interrupted(let reason):
      status = .interrupted(reason)
      notify()
    case .interruptionEnded, .started:
      guard case .interrupted = status else { return }
      do {
        let readiness = try await driver.resume(context: current)
        if case .running = readiness, context == current, case .interrupted = status {
          frames.resume(current)
          status = .running
          notify()
        }
      } catch { await fail(current, error: (error as? CameraFailure) ?? .geometryChanged) }
    }
  }
}

/// A0's native boundary: explicit nonisolated callbacks, no actor-owned mutable buffer access.
nonisolated final class CameraSampleDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate
{
  private let context: CameraSourceContext
  private let clock: CMClock
  private let store: FrameStore
  private let events: CameraEventChannel
  private let expected: CameraNegotiatedConfiguration
  init(
    context: CameraSourceContext, clock: CMClock, store: FrameStore,
    events: CameraEventChannel, expected: CameraNegotiatedConfiguration
  ) {
    self.context = context
    self.clock = clock
    self.store = store
    self.events = events
    self.expected = expected
  }
  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    let enteredAt = CameraHostClock.now()
    defer { store.metrics.callback(context, seconds: CameraHostClock.now() - enteredAt) }
    do {
      let id = try store.nextIdentity(context)
      let capturedAt = try CameraSourceTime.normalize(
        CMSampleBufferGetPresentationTimeStamp(sampleBuffer), from: clock)
      guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else {
        throw CameraFrameError.invalidDescriptor
      }
      guard CVPixelBufferGetWidth(pixel) == expected.outputWidth,
        CVPixelBufferGetHeight(pixel) == expected.outputHeight,
        !connection.isVideoMirrored,
        Double(connection.videoRotationAngle) == expected.rotationAngle,
        connection.activeVideoStabilizationMode == .off
      else { throw CameraFailure.geometryChanged }
      let descriptor = try CameraFrameDescriptor(
        width: CVPixelBufferGetWidth(pixel),
        height: CVPixelBufferGetHeight(pixel), bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
        pixelFormat: CVPixelBufferGetPixelFormatType(pixel), maximumBytes: store.maximumFrameBytes)
      let metadata = CameraFrameMetadata(
        context: context, frameID: id, capturedAt: capturedAt,
        descriptor: descriptor, rotationAngle: expected.rotationAngle, mirrored: false)
      store.metrics.delivered(metadata)
      try store.copy(pixel, metadata: metadata)
    } catch CameraFrameError.capacity { /* Expected bounded backpressure; source stays running. */
    } catch CameraFrameError.staleContext { /* Old callbacks cannot revive another epoch. */
    } catch let error as CameraFailure { events.emit(.failure(error)) } catch {
      events.emit(.failure(.unsupported("delivered BGRA/dimensions/stride", alternatives: [])))
    }
  }
  func captureOutput(
    _ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    _ = try? store.nextIdentity(context, dropped: true)  // No image buffer exists for this callback.
  }
}

/// One native session for this pipeline's lifetime. All mutations/blocking start/stop run on this actor.
private nonisolated final class CameraStartupError: Sendable {
  let code = Mutex<Int?>(nil)
}

actor AVCameraDriver: CameraDriving {
  /// The one retained native session, readable for display only (an
  /// `AVCaptureVideoPreviewLayer`). Every configuration change still happens
  /// on this actor; a preview layer never configures, starts or stops it.
  nonisolated(unsafe) let previewSession = AVCaptureSession()
  private var session: AVCaptureSession?
  private var context: CameraSourceContext?
  private var device: AVCaptureDevice?
  private var output: AVCaptureVideoDataOutput?
  private var delegate: CameraSampleDelegate?
  private var rotation: AVCaptureDevice.RotationCoordinator?
  private var observations: [NSKeyValueObservation] = []
  private var notifications: [any NSObjectProtocol] = []
  private var expected: CameraNegotiatedConfiguration?
  private var synchronizationClock: CMClock?
  private let callbackQueue = DispatchQueue(label: "Sedactive.camera.samples", qos: .userInitiated)

  func start(
    configuration c: CameraCaptureConfiguration, context: CameraSourceContext,
    frames: FrameStore, events: CameraEventChannel
  ) throws -> CameraNegotiatedConfiguration {
    guard self.context == nil else { throw CameraFailure.operationConflict }
    let builtIn = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInUltraWideCamera, .builtInTrueDepthCamera, .builtInWideAngleCamera],
      mediaType: .video, position: .front
    ).devices
    let external = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.external], mediaType: .video, position: .unspecified
    ).devices
    let devices = (external + builtIn).filter(\.isConnected)
    let summaries = devices.map { d in
      CameraDeviceCapability(
        id: d.uniqueID, name: d.localizedName,
        kind: d.deviceType == .external ? .external : (d.deviceType == .builtInUltraWideCamera
          ? .ultraWide : (d.deviceType == .builtInTrueDepthCamera ? .trueDepth : .wide)),
        isFront: d.position == .front,
        formats: d.formats.enumerated().flatMap { index, format in
          let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
          return format.videoSupportedFrameRateRanges.map {
            CameraFormatCapability(
              index: index, width: Int(size.width), height: Int(size.height),
              minimumFPS: $0.minFrameRate, maximumFPS: $0.maxFrameRate,
              centerStageSupported: format.isCenterStageSupported)
          }
        })
    }
    let candidates = try CameraCapabilities.candidates(summaries, configuration: c)
    var firstFailure: CameraFailure?
    for candidate in candidates {
      guard !Task.isCancelled, frames.containsContext(context) else { throw CameraFailure.staleOperation }
      guard let device = devices.first(where: { $0.uniqueID == candidate.device.id && $0.isConnected }) else {
        firstFailure = firstFailure ?? .cameraUnavailable
        continue
      }
      do {
        return try startCandidate(candidate, device: device, configuration: c, context: context, frames: frames, events: events)
      } catch let failure as CameraFailure {
        firstFailure = firstFailure ?? failure
      }
    }
    throw firstFailure ?? .cameraUnavailable
  }

  private func startCandidate(
    _ candidate: CameraCaptureCandidate, device: AVCaptureDevice, configuration c: CameraCaptureConfiguration,
    context: CameraSourceContext, frames: FrameStore, events: CameraEventChannel
  ) throws -> CameraNegotiatedConfiguration {
    let format = candidate.format
    let fps = candidate.framesPerSecond
    guard let size = CameraCapabilities.outputSize(for: format, kind: candidate.device.kind, configuration: c)
    else { throw CameraFailure.cameraUnavailable }

    let session = self.session ?? previewSession
    self.session = session
    self.context = context
    var startupStage = "camera input"
    do {
      frames.metrics.configuration(
        context,
        description:
          "\(device.localizedName) / \(device.deviceType.rawValue); native \(format.width)x\(format.height), range \(format.minimumFPS)...\(format.maximumFPS) FPS; Center Stage supported \(format.centerStageSupported), active \(device.isCenterStageActive); requested BGRA \(size.width)x\(size.height) @\(fps)"
      )
      let input = try AVCaptureDeviceInput(device: device)
      let video = AVCaptureVideoDataOutput()
      session.beginConfiguration()
      do {
        defer { session.commitConfiguration() }
        for old in session.inputs { session.removeInput(old) }
        for old in session.outputs { session.removeOutput(old) }
        guard session.canAddInput(input) else { throw CameraFailure.unsupported("camera input connection", alternatives: []) }
        session.addInput(input)
        // Validate the preset against the actual input, since webcams expose different capabilities.
        guard session.canSetSessionPreset(.inputPriority) else {
          throw CameraFailure.unsupported("input-priority preset", alternatives: [])
        }
        session.sessionPreset = .inputPriority
        startupStage = "camera format and frame rate"
        try device.lockForConfiguration()
        do {
          defer { device.unlockForConfiguration() }
          device.activeFormat = device.formats[format.index]
          guard !device.isCenterStageActive else {
            throw CameraFailure.unsupported(
              "disable active Center Stage before calibrated capture", alternatives: [])
          }
          // Do not change global user Center Stage ownership. Fail if it becomes active.
          if device.activeFormat.isAutoVideoFrameRateSupported {
            device.isAutoVideoFrameRateEnabled = false
          }
          let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
          device.activeVideoMinFrameDuration = duration
          device.activeVideoMaxFrameDuration = duration
          guard device.minAvailableVideoZoomFactor <= 1, device.maxAvailableVideoZoomFactor >= 1
          else {
            throw CameraFailure.unsupported("uncropped zoom 1", alternatives: [])
          }
          if device.videoZoomFactor != 1 { device.videoZoomFactor = 1 }
        }
        startupStage = "video output"
        guard session.canAddOutput(video) else { throw CameraFailure.unsupported(startupStage, alternatives: []) }
        session.addOutput(video)
        guard video.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_32BGRA) else {
          throw CameraFailure.unsupported(
            "BGRA output",
            alternatives: video.availableVideoPixelFormatTypes.prefix(12).map(String.init))
        }
        video.alwaysDiscardsLateVideoFrames = true
        video.automaticallyConfiguresOutputBufferDimensions = false
        video.deliversPreviewSizedOutputBuffers = false
        guard let connection = video.connection(with: .video) else {
          throw CameraFailure.unsupported("video output connection", alternatives: [])
        }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        let angle = Double(coordinator.videoRotationAngleForHorizonLevelCapture)
        // Capture physically upright landscape. Never depend on the M4's default 180° connection.
        guard angle.isFinite, angle == 0 || angle == 180,
          connection.isVideoRotationAngleSupported(CGFloat(angle))
        else {
          throw CameraFailure.unsupported(
            "mounted landscape rotation", alternatives: ["current capture angle: \(angle)"])
        }
        connection.videoRotationAngle = CGFloat(angle)
        if connection.isVideoMirroringSupported {
          connection.automaticallyAdjustsVideoMirroring = false
          connection.isVideoMirrored = false
        }
        guard !connection.isVideoMirrored else { throw CameraFailure.geometryChanged }
        if connection.isVideoStabilizationSupported {
          connection.preferredVideoStabilizationMode = .off
        }
        video.videoSettings = [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
          kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
        ]
        self.device = device
        output = video
        rotation = coordinator
        let actual = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        expected = CameraNegotiatedConfiguration(
          deviceID: device.uniqueID, deviceName: device.localizedName,
          deviceType: device.deviceType.rawValue, nativeWidth: Int(actual.width),
          nativeHeight: Int(actual.height),
          outputWidth: size.width, outputHeight: size.height, framesPerSecond: fps,
          rotationAngle: angle, mirrored: false, centerStageActive: device.isCenterStageActive,
          stabilizationEnabled: false, sessionPreset: session.sessionPreset.rawValue)
      }
      guard let expected else { throw CameraFailure.cameraUnavailable }
      startupStage = "starting capture"
      // Failed candidates must stay private until a camera is ready to publish frames.
      let startupError = CameraStartupError()
      let center = NotificationCenter.default
      let startupObserver = center.addObserver(
        forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
      ) { notification in
        let code = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code ?? 0
        startupError.code.withLock { $0 = code }
      }
      defer { center.removeObserver(startupObserver) }
      session.startRunning()  // Configuration is committed before this blocking operation.
      if let code = startupError.code.withLock({ $0 }) { throw CameraFailure.runtimeError(code) }
      guard session.isRunning else { throw CameraFailure.unsupported(startupStage, alternatives: []) }
      guard let clock = session.synchronizationClock else {
        throw CameraFailure.clockNormalizationFailure
      }
      synchronizationClock = clock
      try validateGeometry()
      guard !Task.isCancelled, frames.containsContext(context) else { throw CameraFailure.staleOperation }
      installObservers(session: session, device: device, events: events, expected: expected)
      if let code = startupError.code.withLock({ $0 }) {
        events.emit(.failure(.runtimeError(code)))
        return expected
      }
      if session.isInterrupted {
        events.emit(.interrupted(nil))
      } else if !session.isRunning || !device.isConnected {
        events.emit(.failure(.cameraUnavailable))
        return expected
      }
      let delegate = CameraSampleDelegate(
        context: context, clock: clock, store: frames, events: events, expected: expected)
      self.delegate = delegate
      video.setSampleBufferDelegate(delegate, queue: callbackQueue)
      observations.append(
        session.observe(\.synchronizationClock, options: [.new]) { _, _ in
          events.emit(.failure(.clockNormalizationFailure))
        })
      return expected
    } catch {
      cleanup(context)
      #if DEBUG
      print("[SedactiveCamera] \(device.localizedName) · \(startupStage) · \(error)")
      #endif
      if let error = error as? CameraFailure { throw error }
      let failure = error as NSError
      throw CameraFailure.unsupported("\(startupStage) (\(failure.domain) \(failure.code))", alternatives: [])
    }
  }
  func stop(context: CameraSourceContext) { cleanup(context) }
  func resume(context: CameraSourceContext) throws -> CameraSourceReadiness {
    guard self.context == context else { throw CameraFailure.staleOperation }
    try validateGeometry()
    if session?.isInterrupted == true { return .interrupted }
    return session?.isRunning == true ? .running : .stopped
  }
  private func validateGeometry() throws {
    guard let synchronizationClock, let currentClock = session?.synchronizationClock,
      CFEqual(synchronizationClock, currentClock)
    else { throw CameraFailure.clockNormalizationFailure }
    guard let device, let output, let expected, let rotation,
      device.isConnected, let connection = output.connection(with: .video)
    else { throw CameraFailure.cameraUnavailable }
    let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    let duration = CMTime(value: 1, timescale: CMTimeScale(expected.framesPerSecond))
    guard Int(dimensions.width) == expected.nativeWidth,
      Int(dimensions.height) == expected.nativeHeight,
      !device.isCenterStageActive, device.videoZoomFactor == 1,
      !connection.isVideoMirrored, Double(connection.videoRotationAngle) == expected.rotationAngle,
      Double(rotation.videoRotationAngleForHorizonLevelCapture) == expected.rotationAngle,
      connection.activeVideoStabilizationMode == .off,
      CMTimeCompare(device.activeVideoMinFrameDuration, duration) == 0,
      CMTimeCompare(device.activeVideoMaxFrameDuration, duration) == 0
    else {
      throw CameraFailure.geometryChanged
    }
  }
  private func installObservers(
    session: AVCaptureSession, device: AVCaptureDevice,
    events: CameraEventChannel, expected: CameraNegotiatedConfiguration
  ) {
    let center = NotificationCenter.default
    notifications = [
      center.addObserver(
        forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil
      ) { _ in
        // A new camera needs a new source generation and its own calibration.
        events.emit(.failure(.cameraUnavailable))
      },
      center.addObserver(
        forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
      ) {
        let reason = ($0.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
        events.emit(.interrupted(reason))
      },
      center.addObserver(
        forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
      ) { _ in
        events.emit(.interruptionEnded)
      },
      center.addObserver(
        forName: AVCaptureSession.didStartRunningNotification, object: session, queue: nil
      ) { _ in
        events.emit(.started)
      },
      center.addObserver(
        forName: AVCaptureSession.didStopRunningNotification, object: session, queue: nil
      ) { _ in
        events.emit(.stopped)
      },
      center.addObserver(
        forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
      ) {
        let code = ($0.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code
        events.emit(.failure(.runtimeError(code ?? 0)))
      },
    ]
    observations = [
      device.observe(\.activeFormat, options: [.new]) { _, _ in
        events.emit(.failure(.geometryChanged))
      },
      device.observe(\.videoZoomFactor, options: [.new]) { _, value in
        if value.newValue != 1 { events.emit(.failure(.geometryChanged)) }
      },
      device.observe(\.isCenterStageActive, options: [.new]) { _, value in
        if value.newValue == true { events.emit(.failure(.geometryChanged)) }
      },
    ]
    if let rotation {
      observations.append(
        rotation.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { _, value in
          if value.newValue.map(Double.init) != expected.rotationAngle {
            events.emit(.failure(.geometryChanged))
          }
        })
    }
  }
  private func cleanup(_ old: CameraSourceContext) {
    guard context == old else { return }
    for token in notifications { NotificationCenter.default.removeObserver(token) }
    notifications = []
    observations = []
    output?.setSampleBufferDelegate(nil, queue: nil)
    if let session {
      session.stopRunning()
      // Release the device on Stop, including after a failed start. The preview keeps
      // its session object, but Retry attaches a fresh set of camera connections.
      session.beginConfiguration()
      for output in session.outputs { session.removeOutput(output) }
      for input in session.inputs { session.removeInput(input) }
      session.commitConfiguration()
    }
    delegate = nil
    output = nil
    device = nil
    rotation = nil
    expected = nil
    synchronizationClock = nil
    context = nil
    // Retain this same AVCaptureSession for the next explicit generation.
  }
}
