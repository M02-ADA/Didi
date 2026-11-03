import CoreVideo
import Foundation

// Plain Swift literal wrongly accepts retained actor-state writer. Compiler-only experiment; not production code.
// DELIBERATELY UNSAFE CONTROL: compiler acceptance is NOT an approved workaround.
nonisolated final class Boxes {
  let values: [Int: Box]
  init(_ values: [Int: Box]) { self.values = values }
}
actor Producer {
  let value = Box()
  func make() -> sending Boxes { Boxes([0: value]) }
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
