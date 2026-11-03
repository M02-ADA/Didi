import CoreVideo
import Foundation

// Nonisolated helper with ordinary borrowed pool parameter. Compiler-only experiment; not production code.
nonisolated func allocate(_ pool: CVPixelBufferPool) throws -> sending CVPixelBuffer {
  var result: CVPixelBuffer?
  let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary
  guard
    CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &result)
      == kCVReturnSuccess,
    let result
  else { throw Failure.allocation }
  return result
}
