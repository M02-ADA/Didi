import CoreVideo
import Foundation

// Same bounded pool owner reused via two immutable round trips. Compiler-only experiment; not production code.
nonisolated final class Workspace {
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
  private(set) var images: [Int: CVPixelBuffer] = [:]
  func compose() throws {
    images = [:]  // Only after previous consumer has returned the entire owner.
    for key in 0..<2 {
      var result: CVPixelBuffer?
      let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary
      guard
        CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &result)
          == kCVReturnSuccess,
        let result
      else { throw Failure.allocation }
      images[key] = result
    }
  }
}
@concurrent nonisolated func produce(_ owner: sending Workspace) async throws -> sending Workspace {
  try owner.compose()
  return owner
}
@MainActor func consume(_ owner: sending Workspace) async -> sending Workspace {
  precondition(owner.images.count == 2)
  // Future consumer may return ownership only after every image read has completed.
  return owner
}
@concurrent nonisolated func roundTrip() async throws {
  let initial = try Workspace()
  let firstProduced = try await produce(initial)
  let firstReturned = await consume(firstProduced)
  let secondProduced = try await produce(firstReturned)
  let secondReturned = await consume(secondProduced)
  _ = secondReturned
}
