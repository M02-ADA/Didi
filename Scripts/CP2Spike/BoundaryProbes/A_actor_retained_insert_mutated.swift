import CoreVideo
import Foundation

// Same plain Swift actor-state writer with subscript insertion. Compiler-only experiment; not production code.
nonisolated final class Boxes {
  let values: [Int: Box]
  init(_ values: [Int: Box]) { self.values = values }
}
actor Producer {
  let value = Box()
  func make() -> sending Boxes {
    {
      var values: [Int: Box] = [:]
      values[0] = value
      return Boxes(values)
    }()
  }
  func mutate() { value.value += 1 }
}
@MainActor final class Receiver {
  private var held: Boxes?
  func accept(_ value: sending Boxes) { held = value }
}
nonisolated func expose(_ producer: Producer, _ receiver: Receiver) async {
  let packet = await producer.make()
  await receiver.accept(packet)
  await producer.mutate()
}
