import CoreVideo
import Foundation

// Fresh local pool control only, not a reusable allocation strategy. Compiler-only experiment; not production code.
actor Producer {
  func make() throws -> sending CVPixelBuffer {
    var local: CVPixelBufferPool?
    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 96,
    ]
    guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &local) == kCVReturnSuccess,
      let pool = local
    else { throw Failure.allocation }
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
  let value = try await producer.make()
  await receiver.accept(value)
}
