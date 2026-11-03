import CoreVideo
import Foundation

// Non-pooled fresh buffers accumulated in dictionary. Compiler-only experiment; not production code.
actor Producer {
  func make() throws -> sending Images {
    var values: [Int: CVPixelBuffer] = [:]
    for key in 0..<2 {
      var result: CVPixelBuffer?
      guard
        CVPixelBufferCreate(nil, 64, 96, kCVPixelFormatType_32BGRA, nil, &result)
          == kCVReturnSuccess,
        let result
      else { throw Failure.allocation }
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
