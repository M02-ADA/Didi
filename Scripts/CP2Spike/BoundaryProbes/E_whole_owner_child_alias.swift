import CoreVideo
import Foundation

// Consumer retains child CV buffer while returning whole owner. Compiler-only experiment; not production code.
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
@MainActor final class Retainer { var held: CVPixelBuffer? }
@MainActor func leak(_ owner: sending Workspace, into retainer: Retainer) -> sending Workspace {
  retainer.held = owner.images[0]
  return owner
}
