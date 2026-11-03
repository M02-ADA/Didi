import CoreVideo
import Foundation

// Producer-confined pool, explicit deep-copy bounded Sendable Data. Compiler-only experiment; not production code.
nonisolated struct CopiedImage: Sendable {
  let bytes: Data
  let width: Int, height: Int, bytesPerRow: Int
}
actor Producer {
  private let pool: CVPixelBufferPool
  init() throws {
    var result: CVPixelBufferPool?
    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 96,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    guard
      CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &result) == kCVReturnSuccess,
      let result
    else { throw Failure.allocation }
    pool = result
  }
  func make() throws -> CopiedImage {
    var result: CVPixelBuffer?
    let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary
    guard
      CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &result)
        == kCVReturnSuccess,
      let result
    else { throw Failure.allocation }
    guard CVPixelBufferLockBaseAddress(result, .readOnly) == kCVReturnSuccess else {
      throw Failure.allocation
    }
    defer { CVPixelBufferUnlockBaseAddress(result, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(result) else { throw Failure.allocation }
    let count = CVPixelBufferGetBytesPerRow(result) * CVPixelBufferGetHeight(result)
    guard count > 0, count <= 65_536 else { throw Failure.allocation }
    return CopiedImage(
      bytes: Data(bytes: base, count: count), width: CVPixelBufferGetWidth(result),
      height: CVPixelBufferGetHeight(result), bytesPerRow: CVPixelBufferGetBytesPerRow(result))

  }

}
@MainActor final class Receiver {
  private var held: CopiedImage?
  func accept(_ value: CopiedImage) { held = value }
}
nonisolated func transfer(_ producer: Producer, _ receiver: Receiver) async throws {
  let value = try await producer.make()
  await receiver.accept(value)
}
