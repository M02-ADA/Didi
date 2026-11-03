import CoreVideo
// CPU/Core Video allocation diagnostic only; no Metal, IOSurface API calls or GPU work.
import Foundation

nonisolated struct BackingObservation: Codable {
  let requestedIOSurface: Bool
  let alignment: Int
  let poolStatus: Int32
  let bufferStatus: Int32
  let actualBytesPerRow: Int
}
@main struct RuntimeBackingProbe {
  static func main() throws {
    var results: [BackingObservation] = []
    for surface in [false, true] {
      for alignment in [64, 4096] {
        var pool: CVPixelBufferPool?
        var attributes: [String: Any] = [
          kCVPixelBufferWidthKey as String: 512,
          kCVPixelBufferHeightKey as String: 768,
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
          kCVPixelBufferBytesPerRowAlignmentKey as String: alignment,
        ]
        if surface { attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]() }
        let created = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        var buffer: CVPixelBuffer?
        let allocated =
          pool.map {
            CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
              nil, $0,
              [kCVPixelBufferPoolAllocationThresholdKey as String: 6] as CFDictionary, &buffer)
          } ?? -1
        results.append(
          BackingObservation(
            requestedIOSurface: surface, alignment: alignment,
            poolStatus: created, bufferStatus: allocated,
            actualBytesPerRow: buffer.map { CVPixelBufferGetBytesPerRow($0) } ?? 0))
      }
    }
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try e.encode(results)
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
  }
}
