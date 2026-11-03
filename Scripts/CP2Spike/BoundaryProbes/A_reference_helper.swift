import CoreVideo
import Foundation

// Fresh reference after synchronous helper mutation. Compiler-only experiment; not production code.
actor Producer {
  func make() throws -> sending Box {
    let value = Box()
    Self.inspect(value)
    return value
  }
  static func inspect(_ value: Box) { value.value = 1 }
}
@MainActor final class Receiver {
  private var held: Box?
  func accept(_ value: sending Box) { held = value }
}
@MainActor func transfer(_ producer: Producer, _ receiver: Receiver) async throws {
  let value = try await producer.make()
  receiver.accept(value)
}
