import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import Sedactive

nonisolated enum CameraTestFrames {
  static func context(_ revision: UInt64 = 1) -> CameraSourceContext {
    CameraSourceContext(generation: UUID(), epoch: UUID(), geometryRevision: revision)
  }
  static func buffer() throws -> CVPixelBuffer {
    var value: CVPixelBuffer?
    let attributes = [kCVPixelBufferBytesPerRowAlignmentKey as String: 64] as CFDictionary
    try #require(
      CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_32BGRA, attributes, &value)
        == kCVReturnSuccess)
    return try #require(value)
  }
  static func fill(_ buffer: CVPixelBuffer, _ byte: UInt8) throws {
    try #require(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = try #require(CVPixelBufferGetBaseAddress(buffer))
    base.initializeMemory(
      as: UInt8.self, repeating: byte,
      count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
  }
  static func metadata(_ buffer: CVPixelBuffer, store: FrameStore, context: CameraSourceContext)
    throws -> CameraFrameMetadata
  {
    let id = try store.nextIdentity(context)
    return CameraFrameMetadata(
      context: context, frameID: id, capturedAt: Double(id),
      descriptor: try CameraFrameDescriptor(
        width: 8, height: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), pixelFormat: kCVPixelFormatType_32BGRA,
        maximumBytes: 1024), rotationAngle: 180, mirrored: false)
  }
  static func offer(_ buffer: CVPixelBuffer, store: FrameStore, context: CameraSourceContext) throws
    -> CameraFrameMetadata
  {
    let value = try metadata(buffer, store: store, context: context)
    try store.copy(buffer, metadata: value)
    return value
  }
  static func lease(_ store: FrameStore, _ context: CameraSourceContext) throws
    -> CameraProcessingLease
  {
    try #require(try store.acquire(context))
  }
  static func firstByte(_ frame: CameraSourceFrame) -> UInt8 {
    var value: UInt8 = 0
    frame.withBytes { value = $0[0] }
    return value
  }
}
nonisolated struct FrameStoreTests {
  @Test(arguments: [0, -1, Int.max]) func invalidDimensionsAndOverflow(_ width: Int) {
    #expect(throws: CameraFrameError.invalidDescriptor) {
      try CameraFrameDescriptor(
        width: width, height: 8, bytesPerRow: 32,
        pixelFormat: kCVPixelFormatType_32BGRA, maximumBytes: 1024)
    }
  }
  @Test func strideFormatAndByteArithmeticAreChecked() {
    for row in [0, 31, 33, Int.max - 3] {
      #expect(throws: CameraFrameError.self) {
        try CameraFrameDescriptor(
          width: 8, height: 8, bytesPerRow: row,
          pixelFormat: kCVPixelFormatType_32BGRA, maximumBytes: 1024)
      }
    }
    #expect(throws: CameraFrameError.invalidDescriptor) {
      try CameraFrameDescriptor(
        width: 8, height: 8, bytesPerRow: 32,
        pixelFormat: kCVPixelFormatType_32ARGB, maximumBytes: 1024)
    }
    #expect(throws: CameraFrameError.byteLimit) {
      try CameraFrameDescriptor(
        width: 1280, height: 720, bytesPerRow: 6144,
        pixelFormat: kCVPixelFormatType_32BGRA, maximumBytes: 4 * 1024 * 1024)
    }
  }
  @Test func sourceCopyIsIndependentAndPaddedBytesAreZero() throws {
    let store = FrameStore()
    let context = CameraTestFrames.context()
    _ = store.begin(context)
    let source = try CameraTestFrames.buffer()
    try CameraTestFrames.fill(source, 0x5B)
    let metadata = try CameraTestFrames.offer(source, store: store, context: context)
    let lease = try CameraTestFrames.lease(store, context)
    try CameraTestFrames.fill(source, 0xEE)
    #expect(lease.frame.metadata == metadata)
    var correct = true
    let stride = metadata.descriptor.bytesPerRow
    #expect(stride > 32)
    lease.frame.withBytes { bytes in
      for row in 0..<8 {
        for x in 0..<stride {
          if bytes[row * stride + x] != (x < 32 ? 0x5B : 0) { correct = false }
        }
      }
    }
    #expect(correct)
    store.complete(lease)
    store.end(context)
  }
  @Test func latestPendingAndOneProcessingAreBounded() throws {
    let store = FrameStore(maximumFrameBytes: 1024, maximumRetainedBytes: 3072)
    let context = CameraTestFrames.context()
    _ = store.begin(context)
    let source = try CameraTestFrames.buffer()
    try CameraTestFrames.fill(source, 1)
    _ = try CameraTestFrames.offer(source, store: store, context: context)
    var first: CameraProcessingLease? = try CameraTestFrames.lease(store, context)
    for _ in 2...10 { _ = try CameraTestFrames.offer(source, store: store, context: context) }
    #expect(throws: CameraFrameError.processingBusy) { try store.acquire(context) }
    #expect(store.diagnostics.superseded == 8)
    #expect(store.usage.frames == 2)
    #expect(store.usage.peakFrames == 3)
    #expect(store.usage.peakBytes <= 3072)
    store.complete(first!)
    first = nil
    var next: CameraProcessingLease? = try CameraTestFrames.lease(store, context)
    #expect(next?.frame.metadata.frameID == 10)
    // The previous completed token cannot release the current processing job.
    store.complete(next!)
    next = nil
    #expect(store.usage.frames == 0)
    store.end(context)
  }
  @Test func retiredReferencesRemainChargedAcrossRestart() throws {
    let store = FrameStore(maximumFrameBytes: 1024, maximumRetainedBytes: 512)
    let old = CameraTestFrames.context()
    _ = store.begin(old)
    let source = try CameraTestFrames.buffer()
    try CameraTestFrames.fill(source, 9)
    _ = try CameraTestFrames.offer(source, store: store, context: old)
    var lease: CameraProcessingLease? = try CameraTestFrames.lease(store, old)
    var reader: CameraSourceFrame? = lease!.frame
    store.complete(lease!)
    lease = nil
    store.end(old)
    let current = CameraTestFrames.context(2)
    _ = store.begin(current)
    #expect(store.usage.frames == 1)
    #expect(CameraTestFrames.firstByte(reader!) == 9)
    #expect(throws: CameraFrameError.capacity) {
      try CameraTestFrames.offer(source, store: store, context: current)
    }
    reader = nil
    #expect(store.usage.bytes == 0)
    _ = try CameraTestFrames.offer(source, store: store, context: current)
    store.end(current)
    #expect(store.usage.frames == 0)
  }
  @Test func retainedCompletedReadersCannotBypassThreeOwnerLimit() throws {
    let store = FrameStore(maximumFrameBytes: 1024, maximumRetainedBytes: 12 * 1024 * 1024)
    let context = CameraTestFrames.context()
    _ = store.begin(context)
    let buffer = try CameraTestFrames.buffer()
    var readers: [CameraSourceFrame] = []
    for _ in 0..<3 {
      _ = try CameraTestFrames.offer(buffer, store: store, context: context)
      let lease = try CameraTestFrames.lease(store, context)
      readers.append(lease.frame)
      store.complete(lease)
    }
    #expect(store.usage.frames == 3)
    #expect(throws: CameraFrameError.capacity) {
      try CameraTestFrames.offer(buffer, store: store, context: context)
    }
    readers.removeAll()
    #expect(store.usage.bytes == 0)
    _ = try CameraTestFrames.offer(buffer, store: store, context: context)
    store.end(context)
    #expect(!store.containsContext(context))
    #expect(store.usage.frames == 0)
  }
  @Test func descriptorOverStoreLimitReservesNothing() throws {
    let store = FrameStore(maximumFrameBytes: 256, maximumRetainedBytes: 1024)
    let context = CameraTestFrames.context()
    _ = store.begin(context)
    let source = try CameraTestFrames.buffer()
    #expect(throws: CameraFrameError.self) {
      try CameraTestFrames.offer(source, store: store, context: context)
    }
    #expect(store.usage.frames == 0)
    store.end(context)
  }
  @Test func noStaleEpochDuplicateOrOldLeaseResurrection() throws {
    let store = FrameStore()
    let old = CameraTestFrames.context()
    _ = store.begin(old)
    let source = try CameraTestFrames.buffer()
    let metadata = try CameraTestFrames.offer(source, store: store, context: old)
    let oldLease = try CameraTestFrames.lease(store, old)
    store.complete(oldLease)
    #expect(throws: CameraFrameError.staleContext) { try store.copy(source, metadata: metadata) }
    store.end(old)
    let current = CameraTestFrames.context(2)
    _ = store.begin(current)
    #expect(throws: CameraFrameError.staleContext) { try store.nextIdentity(old) }
    #expect(throws: CameraFrameError.staleContext) { try store.copy(source, metadata: metadata) }
    let fresh = try CameraTestFrames.offer(source, store: store, context: current)
    #expect(fresh.frameID == 1)
    #expect(fresh.context != oldLease.frame.metadata.context)
    let next = try CameraTestFrames.lease(store, current)
    store.complete(oldLease)
    #expect(throws: CameraFrameError.processingBusy) { try store.acquire(current) }
    store.complete(next)
    store.end(current)
  }
  @Test func droppedCallbacksConsumeIDsAndSuspensionDropsPending() throws {
    let store = FrameStore()
    let context = CameraTestFrames.context()
    _ = store.begin(context)
    let source = try CameraTestFrames.buffer()
    #expect(try CameraTestFrames.offer(source, store: store, context: context).frameID == 1)
    #expect(try store.nextIdentity(context, dropped: true) == 2)
    store.suspend(context)
    #expect(!store.isCurrent(context))
    #expect(store.containsContext(context))
    #expect(throws: CameraFrameError.staleContext) { try store.acquire(context) }
    store.resume(context)
    #expect(try store.acquire(context) == nil)
    #expect(try CameraTestFrames.offer(source, store: store, context: context).frameID == 3)
    #expect(store.diagnostics.avDrops == 1)
    #expect(store.diagnostics.sourceCallbacks == 3)
    store.end(context)
  }
  @Test func workerOwnedReconstructionExecutesWithoutReturningCV() async throws {
    let store = FrameStore()
    let context = CameraTestFrames.context()
    _ = store.begin(context)
    let source = try CameraTestFrames.buffer()
    _ = try CameraTestFrames.offer(source, store: store, context: context)
    var lease: CameraProcessingLease? = try CameraTestFrames.lease(store, context)
    let sink = CameraCopySink()
    try await sink.consume(lease!.frame)
    await sink.reset()
    store.complete(lease!)
    lease = nil
    store.end(context)
    #expect(store.usage.frames == 0)
  }
  @Test func actualHostClockAndNonidentityCoreMediaTimebaseConversion() throws {
    let host = CMClockGetHostTimeClock()
    #expect(try CameraSourceTime.normalize(CMTime(value: 123, timescale: 1), from: host) == 123)
    var value: CMTimebase?
    try #require(
      CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: host, timebaseOut: &value)
        == noErr)
    let timebase = try #require(value)
    try #require(
      CMTimebaseSetRateAndAnchorTime(
        timebase, rate: 2,
        anchorTime: CMTime(value: 20, timescale: 1),
        immediateSourceTime: CMTime(value: 200, timescale: 1)) == noErr)
    let normalized = try CameraSourceTime.hostSeconds(CMTime(value: 26, timescale: 1)) {
      CMSyncConvertTime($0, from: timebase, to: host)
    }
    #expect(abs(normalized - 203) < 0.000001)
  }
  @Test func invalidClockInputAndOutputNeverBecomeArrivalTime() {
    for time in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity] {
      #expect(throws: CameraFailure.clockNormalizationFailure) {
        try CameraSourceTime.hostSeconds(time) { $0 }
      }
    }
    #expect(throws: CameraFailure.clockNormalizationFailure) {
      try CameraSourceTime.hostSeconds(CMTime(value: 1, timescale: 1)) { _ in .invalid }
    }
  }
}
