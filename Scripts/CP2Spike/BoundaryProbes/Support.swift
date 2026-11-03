import CoreVideo
// Shared declarations only; one independent case is SIL-compiled per invocation.
import Foundation

nonisolated enum Failure: Error { case allocation }
nonisolated final class Box { var value = 0 }
nonisolated final class Image {
  let value: CVPixelBuffer
  init(_ value: CVPixelBuffer) { self.value = value }
}
nonisolated final class Images {
  let values: [Int: CVPixelBuffer]
  init(_ values: [Int: CVPixelBuffer]) { self.values = values }
}
