import CoreVideo
import Foundation
import Synchronization

nonisolated struct CutoutMemoryUsage: Sendable, Equatable {
  let images: Int, bytes: Int, peakImages: Int, peakBytes: Int
}
/// One instance shared by the producer and its handoff, including retired consumer-held payloads.
nonisolated final class CutoutMemoryBudget: Sendable {
  let id = UUID()
  let limits: CutoutMemoryLimits
  private struct State { var images = 0, bytes = 0, peakImages = 0, peakBytes = 0 }
  private let state = Mutex(State())
  init(limits: CutoutMemoryLimits) { self.limits = limits }
  var usage: CutoutMemoryUsage {
    state.withLock {
      CutoutMemoryUsage(
        images: $0.images, bytes: $0.bytes,
        peakImages: $0.peakImages, peakBytes: $0.peakBytes)
    }
  }
  fileprivate func reserve(_ bytes: Int) throws -> CutoutMemoryReservation {
    try state.withLock {
      guard bytes > 0 && bytes <= limits.maximumImageBytes,
        $0.images < limits.maximumImages,
        bytes <= limits.maximumRetainedBytes - $0.bytes
      else { throw CutoutError.resourcePressure }
      $0.images += 1
      $0.bytes += bytes
      $0.peakImages = max($0.peakImages, $0.images)
      $0.peakBytes = max($0.peakBytes, $0.bytes)
    }
    return CutoutMemoryReservation(budget: self, bytes: bytes)
  }
  fileprivate func release(_ bytes: Int) {
    state.withLock {
      $0.images -= 1
      $0.bytes -= bytes
      precondition($0.images >= 0 && $0.bytes >= 0)
    }
  }
}
nonisolated private final class CutoutMemoryReservation: Sendable {
  let budget: CutoutMemoryBudget
  let bytes: Int
  init(budget: CutoutMemoryBudget, bytes: Int) {
    self.budget = budget
    self.bytes = bytes
  }
  deinit { budget.release(bytes) }
}
/// Immutable checked-Sendable Data storage. It owns no Core Video or GPU resource.
nonisolated final class CutoutImage: Sendable {
  let source: CutoutImageSource
  let descriptor: CutoutImageDescriptor
  private let data: Data
  private let reservation: CutoutMemoryReservation
  var budgetID: UUID { reservation.budget.id }
  var byteCount: Int { data.count }
  fileprivate init(
    source: CutoutImageSource, descriptor: CutoutImageDescriptor, data: Data,
    reservation: CutoutMemoryReservation
  ) {
    self.source = source
    self.descriptor = descriptor
    self.data = data
    self.reservation = reservation
  }
  /// Scoped read only. Do not escape the address or build no-copy aliases; copy into owned staging here.
  /// A naked Data getter is intentionally absent: retained images keep their budget reservation alive.
  func withUnsafeBytes(_ body: (UnsafeRawBufferPointer) throws -> Void) rethrows {
    try data.withUnsafeBytes(body)
  }
}
nonisolated enum CutoutSourceAlpha: Sendable {
  case straight
  /// RGB bytes were multiplied by alpha in the encoded sRGB domain.
  case premultipliedSRGB
  /// RGB bytes encode sRGB(linearRGB * alpha).
  case premultipliedLinear
}

/// Intentionally NON-Sendable. Keep one fixed-size workspace confined to the producer's worker actor.
/// The callback must finish all writes before returning. No live calibration/segmentation algorithm here.
nonisolated final class CutoutPixelCopier {
  private let pool: CVPixelBufferPool
  private let budget: CutoutMemoryBudget
  private let poolLimit: Int
  private let width: Int, height: Int
  init(
    width: Int, height: Int, budget: CutoutMemoryBudget,
    rowAlignment: Int = 64, sourceBufferLimit: Int = 2
  ) throws {
    try requireCutout(
      rowAlignment >= 4 && rowAlignment <= 4096
        && rowAlignment & (rowAlignment - 1) == 0
        && sourceBufferLimit > 0 && sourceBufferLimit <= 6, "source pool limits")
    let (row, overflow) = width.multipliedReportingOverflow(by: 4)
    try requireCutout(!overflow, "source width overflow")
    _ = try CutoutImageDescriptor(
      width: width, height: height, bytesPerRow: row, limits: budget.limits)
    let attributes: [String: Any] = [
      kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferBytesPerRowAlignmentKey as String: rowAlignment,
    ]
    var created: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
    guard status == kCVReturnSuccess, let created else { throw CutoutError.sourceBuffer(status) }
    pool = created
    self.width = width
    self.height = height
    self.budget = budget
    poolLimit = sourceBufferLimit
  }
  func makeImage(
    source: CutoutImageSource, sourceAlpha: CutoutSourceAlpha = .straight,
    zeroAlphaColor: CutoutZeroAlphaColor = .zeroRGB,
    renderCompleted: (CVPixelBuffer) throws -> Void
  ) throws -> CutoutImage {
    // Every checkout uses a threshold; cached source storage never crosses the worker boundary.
    let auxiliary = [kCVPixelBufferPoolAllocationThresholdKey as String: poolLimit] as CFDictionary
    var value: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, auxiliary, &value)
    guard status == kCVReturnSuccess, let buffer = value else {
      if status == kCVReturnWouldExceedAllocationThreshold { throw CutoutError.resourcePressure }
      throw CutoutError.sourceBuffer(status)
    }
    let descriptor = try CutoutImageDescriptor(
      width: width, height: height,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), zeroAlphaColor: zeroAlphaColor,
      limits: budget.limits)
    let reservation = try budget.reserve(descriptor.byteCount)
    try requireCutout(
      zeroAlphaColor != .preservedEdgeColor || sourceAlpha == .straight,
      "preserved edge color requires prepared straight source")
    // Clear source storage, including row padding, before the producer writes this canvas.
    try withBuffer(buffer, flags: []) { base in
      base.initializeMemory(
        as: UInt8.self,
        repeating: 0, count: descriptor.byteCount)
    }
    try renderCompleted(buffer)
    var data = Data(count: descriptor.byteCount)
    try withBuffer(buffer, flags: .readOnly) { sourceBase in
      try data.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
        for y in 0..<height {
          for x in 0..<width {
            let offset = y * descriptor.bytesPerRow + x * 4
            let input = sourceBase.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            let alpha = Int(input[3])
            output[offset + 3] = input[3]
            for channel in 0..<3 {
              var color = Int(input[channel])
              if alpha == 0 {
                if sourceAlpha != .straight {
                  try requireCutout(color == 0, "invalid premultiplied zero alpha")
                }
                if zeroAlphaColor == .zeroRGB { color = 0 }
              } else {
                switch sourceAlpha {
                case .straight: break
                case .premultipliedSRGB:
                  try requireCutout(color <= alpha, "invalid encoded premultiplied pixel")
                  color = min(255, (color * 255 + alpha / 2) / alpha)
                case .premultipliedLinear:
                  let c = Double(color) / 255
                  let linear = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
                  let a = Double(alpha) / 255
                  let maximumEncoded = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055
                  try requireCutout(
                    color <= Int((maximumEncoded * 255).rounded()),
                    "invalid linear premultiplied pixel")
                  let straight = min(1, linear / (Double(alpha) / 255))
                  let encoded =
                    straight <= 0.0031308
                    ? straight * 12.92 : 1.055 * pow(straight, 1 / 2.4) - 0.055
                  color = Int((encoded * 255).rounded())
                }
              }
              output[offset + channel] = UInt8(color)
            }
          }
        }
      }
    }
    // Source CVPixelBuffer may be reused immediately; Data is a separate allocation.
    return CutoutImage(source: source, descriptor: descriptor, data: data, reservation: reservation)
  }
  private func withBuffer(
    _ buffer: CVPixelBuffer, flags: CVPixelBufferLockFlags,
    _ body: (UnsafeMutableRawPointer) throws -> Void
  ) throws {
    let status = CVPixelBufferLockBaseAddress(buffer, flags)
    guard status == kCVReturnSuccess else { throw CutoutError.sourceBuffer(status) }
    defer { precondition(CVPixelBufferUnlockBaseAddress(buffer, flags) == kCVReturnSuccess) }
    guard let address = CVPixelBufferGetBaseAddress(buffer) else {
      throw CutoutError.invalidValue("source address")
    }
    try body(address)
  }
}
