import CoreVideo
import Foundation

// Pooled accumulation with inline CV metadata read. Compiler-only experiment; not production code.
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
    var values: [Int: CVPixelBuffer] = [:]
    for key in 0..<2 {
      var result: CVPixelBuffer?
      let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary
      guard
        CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &result)
          == kCVReturnSuccess,
        let result
      else { throw Failure.allocation }
      _ = CVPixelBufferGetWidth(result)
      values[key] = result
    }
    return Images(values)
  }

}
@MainActor final class Receiver {
  private var held: Images?
  func accept(_ value: sending Images) { held = value }
}
@MainActor func transfer(_ producer: Producer, _ receiver: Receiver) async throws {
  let value = try await producer.make()
  receiver.accept(value)
}
