import CoreVideo
import Foundation

// Persistent actor pool, single-image wrapper. Compiler-only experiment; not production code.
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
  func make() throws -> sending Image {
    var result: CVPixelBuffer?
    let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary
    guard
      CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &result)
        == kCVReturnSuccess,
      let result
    else { throw Failure.allocation }
    return Image(result)
  }

}
@MainActor final class Receiver {
  private var held: Image?
  func accept(_ value: sending Image) { held = value }
}
@MainActor func transfer(_ producer: Producer, _ receiver: Receiver) async throws {
  let value = try await producer.make()
  receiver.accept(value)
}
