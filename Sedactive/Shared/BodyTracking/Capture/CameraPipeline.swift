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
nonisolated enum CameraDeviceKind: Sendable { case ultraWide, trueDepth, wide }
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
nonisolated enum CameraCapabilities {
  /// Center Stage front cameras can be advertised as TrueDepth, not as an UltraWide device type.
  static func select(_ devices: [CameraDeviceCapability], configuration: CameraCaptureConfiguration)
    throws -> (CameraDeviceCapability, CameraFormatCapability)
  {
    let front = devices.filter { $0.isFront }
    let eligible = front.filter {
      $0.kind == .ultraWide || $0.formats.contains(where: \.centerStageSupported)
    }
    let selected = eligible.sorted {
      let a = $0.kind == .ultraWide ? 0 : ($0.kind == .trueDepth ? 1 : 2)
      let b = $1.kind == .ultraWide ? 0 : ($1.kind == .trueDepth ? 1 : 2)
      return a == b ? $0.id < $1.id : a < b
    }.first
    let alternatives = Array(
      front.flatMap { device in
        device.formats.prefix(8).map {
          "\(device.name): \($0.width)x\($0.height) \($0.minimumFPS)...\($0.maximumFPS) FPS"
        }
      }.prefix(12))
    guard let selected else {
      throw CameraFailure.unsupported(
        "front Ultra Wide / Center Stage camera", alternatives: alternatives)
    }
    let formats = selected.formats.filter {
      $0.width >= configuration.width && $0.height >= configuration.height
        && $0.width <= Int(Int32.max) && $0.height <= Int(Int32.max)
        && $0.minimumFPS.isFinite && $0.maximumFPS.isFinite
        && Int64($0.width) * Int64(configuration.height) == Int64($0.height)
          * Int64(configuration.width)
        && $0.minimumFPS <= Double(configuration.framesPerSecond)
        && $0.maximumFPS >= Double(configuration.framesPerSecond)
    }.sorted { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
    guard let format = formats.first else {
      throw CameraFailure.unsupported("1280x720 aspect / 30 FPS", alternatives: alternatives)
    }
    return (selected, format)  // Never try a second device to hide a configuration failure.
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
    let session = self.session ?? previewSession
    self.session = session
    self.context = context
    do {
      let devices = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInUltraWideCamera, .builtInTrueDepthCamera, .builtInWideAngleCamera],
        mediaType: .video, position: .front
      ).devices
      let summaries = devices.map { d in
        CameraDeviceCapability(
          id: d.uniqueID, name: d.localizedName,
          kind: d.deviceType == .builtInUltraWideCamera
            ? .ultraWide : (d.deviceType == .builtInTrueDepthCamera ? .trueDepth : .wide),
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
      let (selected, format) = try CameraCapabilities.select(summaries, configuration: c)
      guard let device = devices.first(where: { $0.uniqueID == selected.id }) else {
        throw CameraFailure.cameraUnavailable
      }
      frames.metrics.configuration(
        context,
        description:
          "\(device.localizedName) / \(device.deviceType.rawValue); native \(format.width)x\(format.height), range \(format.minimumFPS)...\(format.maximumFPS) FPS; Center Stage supported \(format.centerStageSupported), active \(device.isCenterStageActive); requested BGRA 1280x720 @30"
      )
      let input = try AVCaptureDeviceInput(device: device)
      let video = AVCaptureVideoDataOutput()
      session.beginConfiguration()
      do {
        defer { session.commitConfiguration() }
        for old in session.inputs { session.removeInput(old) }
        for old in session.outputs { session.removeOutput(old) }
        // Explicit active-format ownership; output resizes only to the requested 720p, no preset fallback.
        guard session.canSetSessionPreset(.inputPriority), session.canAddInput(input) else {
          throw CameraFailure.unsupported("input-priority preset / front input", alternatives: [])
        }
        session.sessionPreset = .inputPriority
        session.addInput(input)
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
          let duration = CMTime(value: 1, timescale: CMTimeScale(c.framesPerSecond))
          device.activeVideoMinFrameDuration = duration
          device.activeVideoMaxFrameDuration = duration
          guard device.minAvailableVideoZoomFactor <= 1, device.maxAvailableVideoZoomFactor >= 1
          else {
            throw CameraFailure.unsupported("uncropped zoom 1", alternatives: [])
          }
          device.videoZoomFactor = 1
        }
        guard session.canAddOutput(video) else { throw CameraFailure.cameraUnavailable }
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
          throw CameraFailure.cameraUnavailable
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
          kCVPixelBufferWidthKey as String: c.width, kCVPixelBufferHeightKey as String: c.height,
        ]
        self.device = device
        output = video
        rotation = coordinator
        let actual = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        expected = CameraNegotiatedConfiguration(
          deviceID: device.uniqueID, deviceName: device.localizedName,
          deviceType: device.deviceType.rawValue, nativeWidth: Int(actual.width),
          nativeHeight: Int(actual.height),
          outputWidth: c.width, outputHeight: c.height, framesPerSecond: c.framesPerSecond,
          rotationAngle: angle, mirrored: false, centerStageActive: device.isCenterStageActive,
          stabilizationEnabled: false, sessionPreset: session.sessionPreset.rawValue)
      }
      guard let expected else { throw CameraFailure.cameraUnavailable }
      installObservers(session: session, device: device, events: events, expected: expected)
      session.startRunning()  // Configuration is committed before this blocking operation.
      guard session.isRunning else { throw CameraFailure.cameraUnavailable }
      // Some configurations establish their clock only on startup. No sample delegate yet.
      guard let clock = session.synchronizationClock else {
        throw CameraFailure.clockNormalizationFailure
      }
      synchronizationClock = clock
      try validateGeometry()
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
      if let error = error as? CameraFailure { throw error }
      throw CameraFailure.cameraUnavailable
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
      let connection = output.connection(with: .video)
    else { throw CameraFailure.cameraUnavailable }
    let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    guard Int(dimensions.width) == expected.nativeWidth,
      Int(dimensions.height) == expected.nativeHeight,
      !device.isCenterStageActive, device.videoZoomFactor == 1,
      !connection.isVideoMirrored, Double(connection.videoRotationAngle) == expected.rotationAngle,
      Double(rotation.videoRotationAngleForHorizonLevelCapture) == expected.rotationAngle,
      connection.activeVideoStabilizationMode == .off,
      CMTimeCompare(device.activeVideoMinFrameDuration, CMTime(value: 1, timescale: 30)) == 0,
      CMTimeCompare(device.activeVideoMaxFrameDuration, CMTime(value: 1, timescale: 30)) == 0
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
        let code = ($0.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code ?? 0
        events.emit(.failure(.runtimeError(code)))
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
    session?.stopRunning()
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
