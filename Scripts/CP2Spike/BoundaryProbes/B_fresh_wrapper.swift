import CoreVideo
import Foundation

// Fresh non-pooled CVPixelBuffer inside immutable reference wrapper. Compiler-only experiment; not production code.
actor Producer {
  func make() throws -> sending Image {
    var result: CVPixelBuffer?
    guard
      CVPixelBufferCreate(nil, 64, 96, kCVPixelFormatType_32BGRA, nil, &result) == kCVReturnSuccess,
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
