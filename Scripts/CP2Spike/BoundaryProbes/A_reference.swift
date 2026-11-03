import CoreVideo
import Foundation

// Fresh non-Sendable reference, sending actor result. Compiler-only experiment; not production code.
actor Producer {
  func make() throws -> sending Box {
    return Box()
  }

}
@MainActor final class Receiver {
  private var held: Box?
  func accept(_ value: sending Box) { held = value }
}
@MainActor func transfer(_ producer: Producer, _ receiver: Receiver) async throws {
  let value = try await producer.make()
  receiver.accept(value)
}
