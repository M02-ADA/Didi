import CoreVideo
import Foundation

// Two pooled buffers, literal after metadata helper. Compiler-only experiment; not production code.
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
  func make() throws -> sending Images {
    var first: CVPixelBuffer?
    let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary
    guard
      CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &first)
        == kCVReturnSuccess,
      let first
    else { throw Failure.allocation }
    var second: CVPixelBuffer?
    let secondLimits = [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary
    guard
      CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, secondLimits, &second)
        == kCVReturnSuccess,
      let second
    else { throw Failure.allocation }
    Self.inspect(first)
    Self.inspect(second)
    return Images([0: first, 1: second])
  }
  static func inspect(_ value: CVPixelBuffer) { _ = CVPixelBufferGetWidth(value) }
}
@MainActor final class Receiver {
  private var held: Images?
  func accept(_ value: sending Images) { held = value }
}
nonisolated func transfer(_ producer: Producer, _ receiver: Receiver) async throws {
  let value = try await producer.make()
  await receiver.accept(value)
}
