import CoreVideo
import Darwin
import Foundation
import Synchronization

nonisolated enum ExperimentError: Error {
  case check(String)
  case cv(Int32)
  case cancelled
}
nonisolated func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw ExperimentError.check(message) }
}
nonisolated func progress(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}
nonisolated func tick() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
nonisolated func cpuTick() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
nonisolated enum Slot: Int, CaseIterable, Sendable { case p1, p2 }
nonisolated enum Fault: String, Sendable {
  case none, cancelBefore, failBefore, failAfter, cancelAfter
}
nonisolated struct Request: Sendable {
  let generation: Int, sequence: Int
  let captured: UInt64
  let fault: Fault
}
nonisolated struct Shape: Sendable {
  let width: Int, height: Int, alignment: Int
  static let standard = Shape(width: 512, height: 768, alignment: 64)
  static let padded = Shape(width: 512, height: 768, alignment: 4096)
  func byteCount(stride: Int) throws -> Int {
    let (packed, o1) = width.multipliedReportingOverflow(by: 4)
    let (total, o2) = stride.multipliedReportingOverflow(by: height)
    try require(
      width > 0 && height > 0 && !o1 && !o2 && stride >= packed && stride % 4 == 0
        && total > 0 && total <= 8 * 1024 * 1024, "invalid/beyond-cap image byte count")
    return total
  }
}
nonisolated struct ResourceSnapshot: Codable, Sendable {
  var pools = 0, sourceBuffers = 0, sourceBytes = 0, dataPairs = 0, dataBytes = 0
  var peakPools = 0, peakSourceBuffers = 0, peakSourceBytes = 0, peakDataPairs = 0,
    peakDataBytes = 0
  var peakCombinedBytes = 0, poolsCreated = 0, poolsDestroyed = 0, locks = 0, unlocks = 0
  var uniqueBufferIDs = 0, maxImageBytes = 0
}
// Checked Sendable instrumentation only. No image resources live in the mutex or callbacks.
nonisolated final class Ledger: Sendable {
  private struct State {
    var count = ResourceSnapshot()
    var ids: Set<ObjectIdentifier> = []
  }
  private let state = Mutex(State())
  func pool(_ delta: Int) {
    state.withLock {
      $0.count.pools += delta
      if delta > 0 { $0.count.poolsCreated += 1 } else { $0.count.poolsDestroyed += 1 }
      $0.count.peakPools = max($0.count.peakPools, $0.count.pools)
    }
  }
  func source(_ delta: Int, bytes: Int) {
    state.withLock {
      $0.count.sourceBuffers += delta
      $0.count.sourceBytes += bytes
      precondition($0.count.sourceBuffers >= 0 && $0.count.sourceBytes >= 0)
      $0.count.peakSourceBuffers = max($0.count.peakSourceBuffers, $0.count.sourceBuffers)
      $0.count.peakSourceBytes = max($0.count.peakSourceBytes, $0.count.sourceBytes)
      $0.count.peakCombinedBytes = max(
        $0.count.peakCombinedBytes, $0.count.sourceBytes + $0.count.dataBytes)
    }
  }
  func copied(_ delta: Int, bytes: Int) {
    state.withLock {
      $0.count.dataPairs += delta
      $0.count.dataBytes += bytes
      precondition($0.count.dataPairs >= 0 && $0.count.dataBytes >= 0)
      $0.count.peakDataPairs = max($0.count.peakDataPairs, $0.count.dataPairs)
      $0.count.peakDataBytes = max($0.count.peakDataBytes, $0.count.dataBytes)
      $0.count.peakCombinedBytes = max(
        $0.count.peakCombinedBytes, $0.count.sourceBytes + $0.count.dataBytes)
    }
  }
  func seen(_ buffer: CVPixelBuffer, bytes: Int) {
    state.withLock {
      $0.ids.insert(ObjectIdentifier(buffer))
      $0.count.uniqueBufferIDs = $0.ids.count
      $0.count.maxImageBytes = max($0.count.maxImageBytes, bytes)
    }
  }
  func locked() { state.withLock { $0.count.locks += 1 } }
  func unlocked() { state.withLock { $0.count.unlocks += 1 } }
  func snapshot() -> ResourceSnapshot { state.withLock { $0.count } }
}
nonisolated func locked<T>(
  _ buffer: CVPixelBuffer, readOnly: Bool, ledger: Ledger,
  body: (UnsafeMutableRawPointer, Int, Int) throws -> T
) throws -> T {
  let flags: CVPixelBufferLockFlags = readOnly ? .readOnly : []
  let status = CVPixelBufferLockBaseAddress(buffer, flags)
  guard status == kCVReturnSuccess else { throw ExperimentError.cv(status) }
  ledger.locked()
  defer {
    let status = CVPixelBufferUnlockBaseAddress(buffer, flags)
    precondition(status == kCVReturnSuccess)
    ledger.unlocked()
  }
  guard let base = CVPixelBufferGetBaseAddress(buffer) else {
    throw ExperimentError.check("no base address")
  }
  return try body(base, CVPixelBufferGetBytesPerRow(buffer), CVPixelBufferGetHeight(buffer))
}
// Deterministic premultiplied BGRA; padding is 0xA5, never part of visible pixels.
nonisolated func pixel(x: Int, y: Int, slot: Slot, sequence: Int, shape: Shape) -> UInt32 {
  let outside = x < 24 || x >= shape.width - 24 || y < 24 || y >= shape.height - 24
  let edge = x < 28 || x >= shape.width - 28 || y < 28 || y >= shape.height - 28
  let a: UInt32 = outside ? 0 : (edge ? 128 : 255)
  let green: UInt32 = ((x / 32 + y / 64 + sequence) % 2 == 0) ? a / 2 : 0
  let red: UInt32 = slot == .p1 ? a : 0
  let blue: UInt32 = slot == .p2 ? a : 0
  return blue | (green << 8) | (red << 16) | (a << 24)
}
nonisolated func fillPixels(
  _ buffer: CVPixelBuffer, slot: Slot, request: Request, shape: Shape, ledger: Ledger
) throws {
  try locked(buffer, readOnly: false, ledger: ledger) { base, stride, height in
    let count = try shape.byteCount(stride: stride)
    try require(height == shape.height, "height")
    memset(base, 0xA5, count)
    for y in 0..<height {
      let row = base.advanced(by: y * stride)
      for x in 0..<shape.width {
        row.storeBytes(
          of: pixel(x: x, y: y, slot: slot, sequence: request.sequence, shape: shape),
          toByteOffset: x * 4, as: UInt32.self)
      }
    }
  }
}
nonisolated func verifyBytes(
  _ bytes: UnsafeRawPointer, stride: Int, slot: Slot,
  request: Request, shape: Shape
) throws -> UInt64 {
  _ = try shape.byteCount(stride: stride)
  // Independent known-byte anchors catch BGRA/endian/premultiplication mistakes,
  // rather than only comparing against the shared pattern function.
  let opaque = bytes.advanced(by: 32 * stride + 32 * 4).assumingMemoryBound(to: UInt8.self)
  let edge = bytes.advanced(by: 32 * stride + 24 * 4).assumingMemoryBound(to: UInt8.self)
  let transparent = bytes.advanced(by: 32 * stride).assumingMemoryBound(to: UInt8.self)
  try require(opaque[3] == 255 && edge[3] == 128, "known alpha anchors")
  try require(
    opaque[0] == (slot == .p2 ? 255 : 0) && opaque[2] == (slot == .p1 ? 255 : 0),
    "known BGRA channel anchors")
  try require(
    edge[0] == (slot == .p2 ? 128 : 0) && edge[2] == (slot == .p1 ? 128 : 0),
    "known premultiplied edge anchors")
  try require((0..<4).allSatisfy { transparent[$0] == 0 }, "known transparent anchors")
  var checksum: UInt64 = 0
  for y in 0..<shape.height {
    let row = bytes.advanced(by: y * stride)
    for x in 0..<shape.width {
      let actual = row.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self)
      try require(
        actual == pixel(x: x, y: y, slot: slot, sequence: request.sequence, shape: shape),
        "pixel/frame/channel mismatch")
      checksum = checksum &+ UInt64(actual)
    }
    let padding = bytes.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
    for x in (shape.width * 4)..<stride { try require(padding[x] == 0xA5, "row padding changed") }
  }
  return checksum
}
nonisolated final class PixelPair {
  private let buffers: [CVPixelBuffer]
  let request: Request, shape: Shape, ledger: Ledger, bytes: Int, stride: Int
  init(buffers: [CVPixelBuffer], request: Request, shape: Shape, ledger: Ledger) throws {
    try require(buffers.count == 2, "P1/P2 required")
    self.buffers = buffers
    self.request = request
    self.shape = shape
    self.ledger = ledger
    stride = CVPixelBufferGetBytesPerRow(buffers[0])
    bytes = try shape.byteCount(stride: stride) * 2
    for b in buffers {
      try require(
        CVPixelBufferGetWidth(b) == shape.width && CVPixelBufferGetBytesPerRow(b) == stride,
        "inconsistent source dimensions/stride")
      ledger.seen(b, bytes: bytes / 2)
    }
    ledger.source(2, bytes: bytes)
  }
  deinit { ledger.source(-2, bytes: -bytes) }
  func paint() throws {
    for slot in Slot.allCases {
      try fillPixels(
        buffers[slot.rawValue], slot: slot, request: request, shape: shape, ledger: ledger)
    }
  }
  func verify() throws -> UInt64 {
    var sum: UInt64 = 0
    for slot in Slot.allCases {
      sum =
        sum
        &+ (try locked(buffers[slot.rawValue], readOnly: true, ledger: ledger) { base, stride, _ in
          try verifyBytes(base, stride: stride, slot: slot, request: request, shape: shape)
        })
    }
    return sum
  }
  func copy() throws -> CopiedPair {
    var images: [Data] = []
    for b in buffers {
      let image = try locked(b, readOnly: true, ledger: ledger) { base, stride, _ in
        Data(bytes: base, count: try shape.byteCount(stride: stride))
      }
      images.append(image)
    }
    return CopiedPair(
      images: images, request: request, shape: shape, stride: stride, ledger: ledger)
  }
}
nonisolated final class CopiedPair: Sendable {
  let images: [Data], request: Request, shape: Shape, stride: Int, ledger: Ledger, bytes: Int
  init(images: [Data], request: Request, shape: Shape, stride: Int, ledger: Ledger) {
    self.images = images
    self.request = request
    self.shape = shape
    self.stride = stride
    self.ledger = ledger
    bytes = images.reduce(0) { $0 + $1.count }
    ledger.copied(1, bytes: bytes)
  }
  deinit { ledger.copied(-1, bytes: -bytes) }
  func verify() throws -> UInt64 {
    try require(images.count == 2, "copied slots")
    var sum: UInt64 = 0
    for slot in Slot.allCases {
      try require(images[slot.rawValue].count == shape.byteCount(stride: stride), "copied size")
      sum =
        sum
        &+ (try images[slot.rawValue].withUnsafeBytes { p in
          guard let base = p.baseAddress else { throw ExperimentError.check("copied base") }
          return try verifyBytes(base, stride: stride, slot: slot, request: request, shape: shape)
        })
    }
    return sum
  }
}
nonisolated final class PoolOwner {
  private let pool: CVPixelBufferPool
  let ledger: Ledger, shape: Shape
  init(shape: Shape, ledger: Ledger) throws {
    self.shape = shape
    self.ledger = ledger
    var value: CVPixelBufferPool?
    let a: [String: Any] = [
      kCVPixelBufferWidthKey as String: shape.width,
      kCVPixelBufferHeightKey as String: shape.height,
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferBytesPerRowAlignmentKey as String: shape.alignment,
    ]
    // CPU-only experiment: IOSurface bridge allocation failed (-6662) on this host.
    // This deliberately does not validate future Metal-compatible/IOSurface storage.
    let result = CVPixelBufferPoolCreate(nil, nil, a as CFDictionary, &value)
    guard result == kCVReturnSuccess, let value else { throw ExperimentError.cv(result) }
    pool = value
    ledger.pool(1)
  }
  deinit { ledger.pool(-1) }
  func pair(_ request: Request) throws -> PixelPair {
    var buffers: [CVPixelBuffer] = []
    for _ in 0..<2 {
      var value: CVPixelBuffer?
      let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary
      let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &value)
      guard result == kCVReturnSuccess, let value else { throw ExperimentError.cv(result) }
      buffers.append(value)
    }
    return try PixelPair(buffers: buffers, request: request, shape: shape, ledger: ledger)
  }
  func exhaustion() throws {
    let q = Request(generation: 1, sequence: 0, captured: tick(), fault: .none)
    var held: [PixelPair] = []
    for _ in 0..<3 { held.append(try pair(q)) }
    do {
      _ = try pair(q)
      throw ExperimentError.check("pool unexpectedly exceeded 6")
    } catch ExperimentError.cv(let status) {
      try require(status == kCVReturnWouldExceedAllocationThreshold, "wrong pool failure")
    }
    held.removeAll()
    _ = try pair(q)  // Capacity recovers after holders release, not by forced reclaim.
  }
}
