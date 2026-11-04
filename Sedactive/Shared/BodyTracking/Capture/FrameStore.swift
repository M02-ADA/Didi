import CoreMedia
import CoreVideo
import Foundation
import Synchronization

// Capture-internal values. These are not body evidence or a new public CP1 API.
nonisolated enum CameraFrameError: Error, Equatable, Sendable {
  case invalidDescriptor, byteLimit, capacity, staleContext, processingBusy, lock, allocation
}
nonisolated struct CameraSourceContext: Equatable, Sendable {
  let generation: UUID
  let epoch: UUID
  let geometryRevision: UInt64
}
nonisolated struct CameraFrameDescriptor: Equatable, Sendable {
  let width: Int, height: Int, bytesPerRow: Int, byteCount: Int
  let pixelFormat: UInt32
  init(
    width: Int, height: Int, bytesPerRow: Int, pixelFormat: UInt32,
    maximumBytes: Int
  ) throws {
    let (row, overflow1) = width.multipliedReportingOverflow(by: 4)
    let (count, overflow2) = bytesPerRow.multipliedReportingOverflow(by: height)
    guard width > 0, height > 0, !overflow1, !overflow2, bytesPerRow >= row,
      bytesPerRow % 4 == 0, count > 0, pixelFormat == kCVPixelFormatType_32BGRA
    else {
      throw CameraFrameError.invalidDescriptor
    }
    guard count <= maximumBytes else { throw CameraFrameError.byteLimit }
    self.width = width
    self.height = height
    self.bytesPerRow = bytesPerRow
    self.pixelFormat = pixelFormat
    byteCount = count
  }
}
nonisolated struct CameraFrameMetadata: Equatable, Sendable {
  let context: CameraSourceContext
  let frameID: UInt64
  let capturedAt: Double
  let descriptor: CameraFrameDescriptor
  let rotationAngle: Double
  let mirrored: Bool
}
nonisolated struct CameraSourceUsage: Equatable, Sendable {
  let frames: Int, bytes: Int, peakFrames: Int, peakBytes: Int
}
nonisolated struct CameraFrameDiagnostics: Sendable {
  var sourceCallbacks: UInt64 = 0
  var avDrops: UInt64 = 0
  var superseded: UInt64 = 0
  var capacityDrops: UInt64 = 0
  var constructionDrops: UInt64 = 0
  var budgetDrops: UInt64 = 0
  var staleDrops: UInt64 = 0
  mutating func increment(_ key: WritableKeyPath<Self, UInt64>) {
    if self[keyPath: key] < .max { self[keyPath: key] += 1 }
  }
}
nonisolated private final class CameraSourceBudget: Sendable {
  struct Counts { var frames = 0, bytes = 0, peakFrames = 0, peakBytes = 0 }
  let maximumBytes: Int
  let metrics: CameraCaptureMetrics
  let state = Mutex(Counts())
  init(maximumBytes: Int, metrics: CameraCaptureMetrics) {
    self.maximumBytes = maximumBytes
    self.metrics = metrics
  }
  func reserve(_ bytes: Int) throws -> CameraSourceReservation {
    try state.withLock {
      guard bytes > 0, $0.frames < 3, bytes <= maximumBytes - $0.bytes else {
        throw CameraFrameError.capacity
      }
      $0.frames += 1
      $0.bytes += bytes
      $0.peakFrames = max($0.peakFrames, $0.frames)
      $0.peakBytes = max($0.peakBytes, $0.bytes)
      metrics.sourceBytes($0.bytes)
    }
    return CameraSourceReservation(budget: self, bytes: bytes)
  }
  func release(_ bytes: Int) {
    state.withLock {
      $0.frames -= 1
      $0.bytes -= bytes
      metrics.sourceBytes($0.bytes)
    }
  }
  var usage: CameraSourceUsage {
    state.withLock {
      CameraSourceUsage(
        frames: $0.frames, bytes: $0.bytes,
        peakFrames: $0.peakFrames, peakBytes: $0.peakBytes)
    }
  }
}
nonisolated private final class CameraSourceReservation: Sendable {
  let budget: CameraSourceBudget, bytes: Int
  init(budget: CameraSourceBudget, bytes: Int) {
    self.budget = budget
    self.bytes = bytes
  }
  deinit { budget.release(bytes) }
}
/// Private Data keeps its reservation alive through every reader, including retired epochs.
nonisolated final class CameraSourceFrame: Sendable {
  let metadata: CameraFrameMetadata
  let admittedAt: Double
  private let bytes: Data
  private let reservation: CameraSourceReservation
  fileprivate init(metadata: CameraFrameMetadata, bytes: Data, reservation: CameraSourceReservation)
  {
    self.metadata = metadata
    admittedAt = CameraHostClock.now()
    self.bytes = bytes
    self.reservation = reservation
  }
  func withBytes(_ read: (UnsafeRawBufferPointer) throws -> Void) rethrows {
    try bytes.withUnsafeBytes(read)  // Address must not escape. Copy into owned worker storage here.
  }
}
nonisolated struct CameraProcessingLease: Sendable {
  fileprivate let token: UUID
  let frame: CameraSourceFrame
}

/// One construction, latest pending, one processing job; no image Task/queue per callback.
nonisolated final class FrameStore: Sendable {
  private struct State {
    var context: CameraSourceContext?
    var admitting = false
    var construction = false
    var processing: UUID?
    var pending: CameraSourceFrame?
    var sequence: UInt64 = 0
    var lastOffered: UInt64?
    var wake: AsyncStream<Void>.Continuation?
    var diagnostics = CameraFrameDiagnostics()
  }
  let maximumFrameBytes: Int
  let metrics: CameraCaptureMetrics
  private let budget: CameraSourceBudget
  private let state = Mutex(State())
  init(maximumFrameBytes: Int = 4 * 1024 * 1024, maximumRetainedBytes: Int = 12 * 1024 * 1024) {
    precondition(maximumFrameBytes > 0 && maximumRetainedBytes > 0)
    self.maximumFrameBytes = maximumFrameBytes
    let metrics = CameraCaptureMetrics()
    self.metrics = metrics
    budget = CameraSourceBudget(maximumBytes: maximumRetainedBytes, metrics: metrics)
  }
  var usage: CameraSourceUsage { budget.usage }
  var diagnostics: CameraFrameDiagnostics { state.withLock { $0.diagnostics } }
  func begin(_ context: CameraSourceContext) -> AsyncStream<Void> {
    metrics.begin(context)
    let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    state.withLock {
      $0.wake?.finish()
      $0.pending = nil
      $0.context = context
      $0.admitting = true
      $0.sequence = 0
      $0.lastOffered = nil
      $0.diagnostics = CameraFrameDiagnostics()
      $0.wake = pair.continuation
      // In-use construction/processing is never reclaimed, even across generations.
    }
    return pair.stream
  }
  func end(_ context: CameraSourceContext) {
    state.withLock {
      guard $0.context == context else { return }
      $0.context = nil
      $0.admitting = false
      $0.pending = nil
      $0.wake?.finish()
      $0.wake = nil
    }
  }
  func suspend(_ context: CameraSourceContext) {
    state.withLock {
      guard $0.context == context else { return }
      $0.admitting = false
      $0.pending = nil
    }
  }
  func resume(_ context: CameraSourceContext) {
    state.withLock { if $0.context == context { $0.admitting = true } }
  }
  func containsContext(_ context: CameraSourceContext) -> Bool {
    state.withLock { $0.context == context }
  }
  func isCurrent(_ context: CameraSourceContext) -> Bool {
    state.withLock { $0.context == context && $0.admitting }
  }
  /// Called BEFORE application admission; AV drops consume IDs too. Never counts invisible exposures.
  func nextIdentity(_ context: CameraSourceContext, dropped: Bool = false) throws -> UInt64 {
    try state.withLock {
      guard $0.context == context else { throw CameraFrameError.staleContext }
      guard $0.sequence < .max else { throw CameraFrameError.invalidDescriptor }
      $0.sequence += 1
      $0.diagnostics.increment(\.sourceCallbacks)
      if dropped { $0.diagnostics.increment(\.avDrops) }
      return $0.sequence
    }
  }
  /// Scoped source access only. Reserve before Data allocation; original pixels never escape.
  func copy(_ buffer: CVPixelBuffer, metadata: CameraFrameMetadata) throws {
    let d = metadata.descriptor
    guard metadata.capturedAt.isFinite, metadata.capturedAt >= 0,
      !metadata.mirrored, metadata.rotationAngle.isFinite,
      !CVPixelBufferIsPlanar(buffer),
      CVPixelBufferGetWidth(buffer) == d.width, CVPixelBufferGetHeight(buffer) == d.height,
      CVPixelBufferGetBytesPerRow(buffer) == d.bytesPerRow,
      CVPixelBufferGetPixelFormatType(buffer) == d.pixelFormat,
      d.byteCount <= maximumFrameBytes
    else { throw CameraFrameError.invalidDescriptor }
    let reservation: CameraSourceReservation = try state.withLock {
      guard $0.context == metadata.context, $0.admitting else {
        $0.diagnostics.increment(\.staleDrops)
        throw CameraFrameError.staleContext
      }
      guard $0.lastOffered.map({ metadata.frameID > $0 }) ?? true else {
        $0.diagnostics.increment(\.staleDrops)
        throw CameraFrameError.staleContext
      }
      guard !$0.construction else {
        $0.diagnostics.increment(\.constructionDrops)
        $0.diagnostics.increment(\.capacityDrops)
        throw CameraFrameError.capacity
      }
      do {
        let reservation = try budget.reserve(d.byteCount)
        $0.construction = true
        return reservation
      } catch {
        $0.diagnostics.increment(\.budgetDrops)
        $0.diagnostics.increment(\.capacityDrops)
        throw error
      }
    }
    defer { state.withLock { $0.construction = false } }
    guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
      throw CameraFrameError.lock
    }
    defer { precondition(CVPixelBufferUnlockBaseAddress(buffer, .readOnly) == kCVReturnSuccess) }
    guard let address = CVPixelBufferGetBaseAddress(buffer) else {
      throw CameraFrameError.invalidDescriptor
    }
    let copyStart = CameraHostClock.now()
    var data = Data(count: d.byteCount)
    data.withUnsafeMutableBytes { destination in
      for row in 0..<d.height {
        destination.baseAddress!.advanced(by: row * d.bytesPerRow).copyMemory(
          from: address.advanced(by: row * d.bytesPerRow), byteCount: d.width * 4)
      }
    }
    metrics.copied(metadata.context, seconds: CameraHostClock.now() - copyStart)
    let frame = CameraSourceFrame(metadata: metadata, bytes: data, reservation: reservation)
    try state.withLock {
      guard $0.context == metadata.context, $0.admitting else {
        $0.diagnostics.increment(\.staleDrops)
        throw CameraFrameError.staleContext
      }
      if $0.pending != nil { $0.diagnostics.increment(\.superseded) }
      $0.pending = frame
      $0.lastOffered = metadata.frameID
      metrics.admitted(metadata.context)
      $0.wake?.yield(())
    }
  }
  func acquire(_ context: CameraSourceContext) throws -> CameraProcessingLease? {
    try state.withLock {
      guard $0.context == context, $0.admitting else { throw CameraFrameError.staleContext }
      guard $0.processing == nil else { throw CameraFrameError.processingBusy }
      guard let frame = $0.pending else { return nil }
      let token = UUID()
      $0.processing = token
      $0.pending = nil
      return CameraProcessingLease(token: token, frame: frame)
    }
  }
  func complete(_ lease: CameraProcessingLease) {
    state.withLock {
      guard $0.processing == lease.token else { return }
      $0.processing = nil
      if $0.pending != nil { $0.wake?.yield(()) }
    }
  }
}

nonisolated enum CameraSourceTime {
  static func hostSeconds(_ pts: CMTime, convert: (CMTime) -> CMTime) throws -> Double {
    guard pts.isNumeric else { throw CameraFailure.clockNormalizationFailure }
    let converted = convert(pts)
    guard converted.isNumeric, converted.seconds.isFinite, converted.seconds >= 0 else {
      throw CameraFailure.clockNormalizationFailure
    }
    return converted.seconds
  }
  static func normalize(_ pts: CMTime, from clock: CMClock) throws -> Double {
    try hostSeconds(pts) { CMSyncConvertTime($0, from: clock, to: CMClockGetHostTimeClock()) }
  }
}

/// Future processing uses the same owned bytes; this A1 sink performs reconstruction only.
protocol CameraFrameSink: Actor {
  func consume(_ frame: CameraSourceFrame) async throws
  func reset() async
}
actor CameraCopySink: CameraFrameSink {
  private let metrics: CameraCaptureMetrics?
  init(metrics: CameraCaptureMetrics? = nil) { self.metrics = metrics }
  private var workspace: CameraReconstructionWorkspace?
  func consume(_ frame: CameraSourceFrame) throws {
    if workspace?.width != frame.metadata.descriptor.width
      || workspace?.height != frame.metadata.descriptor.height
    {
      workspace = try CameraReconstructionWorkspace(descriptor: frame.metadata.descriptor)
    }
    try workspace!.copy(frame, metrics: metrics)  // No Vision, body evidence or image rendering.
  }
  func reset() {
    workspace = nil
    metrics?.workspace(bytes: 0)
  }
}
nonisolated private final class CameraReconstructionWorkspace {
  let width: Int, height: Int
  private let pool: CVPixelBufferPool
  init(descriptor: CameraFrameDescriptor) throws {
    width = descriptor.width
    height = descriptor.height
    var result: CVPixelBufferPool?
    let attributes: [String: Any] = [
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]
    guard
      CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &result) == kCVReturnSuccess,
      let result
    else { throw CameraFrameError.allocation }
    pool = result
  }
  func copy(_ frame: CameraSourceFrame, metrics: CameraCaptureMetrics?) throws {
    var value: CVPixelBuffer?
    let threshold = [kCVPixelBufferPoolAllocationThresholdKey as String: 1] as CFDictionary
    guard
      CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, threshold, &value)
        == kCVReturnSuccess,
      let value
    else { throw CameraFrameError.allocation }
    let d = try CameraFrameDescriptor(
      width: width, height: height,
      bytesPerRow: CVPixelBufferGetBytesPerRow(value), pixelFormat: kCVPixelFormatType_32BGRA,
      maximumBytes: 4 * 1024 * 1024)
    metrics?.workspace(bytes: d.byteCount)
    guard CVPixelBufferLockBaseAddress(value, []) == kCVReturnSuccess else {
      throw CameraFrameError.lock
    }
    defer { precondition(CVPixelBufferUnlockBaseAddress(value, []) == kCVReturnSuccess) }
    guard let destination = CVPixelBufferGetBaseAddress(value) else {
      throw CameraFrameError.invalidDescriptor
    }
    destination.initializeMemory(as: UInt8.self, repeating: 0, count: d.byteCount)
    frame.withBytes { source in
      for row in 0..<height {
        destination.advanced(by: row * d.bytesPerRow).copyMemory(
          from: source.baseAddress!.advanced(by: row * frame.metadata.descriptor.bytesPerRow),
          byteCount: width * 4)
      }
    }
  }
}
