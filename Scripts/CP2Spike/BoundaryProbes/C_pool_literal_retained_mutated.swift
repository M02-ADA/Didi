import CoreVideo
import Foundation

// Pooled literal wrongly accepts retained producer writer alias. Compiler-only experiment; not production code.
// DELIBERATELY UNSAFE CONTROL: compiler acceptance is NOT an approved workaround.
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
  private var retained: CVPixelBuffer?
  func mutate() { if let retained { CVBufferRemoveAllAttachments(retained) } }
  func make() throws -> sending Images {
    var result: CVPixelBuffer?
    let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary
    guard
      CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &result)
        == kCVReturnSuccess,
      let result
    else { throw Failure.allocation }
    retained = result
    return Images([0: result])
  }

}
@MainActor final class Receiver {
  private var held: Images?
  func accept(_ value: sending Images) { held = value }
}
nonisolated func transfer(_ producer: Producer, _ receiver: Receiver) async throws {
  let value = try await producer.make()
  await receiver.accept(value)
  await producer.mutate()
}
