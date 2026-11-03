import CoreVideo
import Foundation

// Ordinary producer parameter is task-isolated, not disconnected. Compiler-only experiment; not production code.
nonisolated final class Producer {
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
  func make() throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary
    guard
      CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &result)
        == kCVReturnSuccess,
      let result
    else { throw Failure.allocation }
    return result
  }

}
@MainActor final class Receiver {
  private var held: CVPixelBuffer?
  func accept(_ value: sending CVPixelBuffer) { held = value }
}
nonisolated func transfer(_ producer: Producer, _ receiver: Receiver) async throws {
  let value = try producer.make()
  await receiver.accept(value)
}
