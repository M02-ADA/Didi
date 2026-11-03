import Foundation

nonisolated enum ReviewEncoding: String, CaseIterable, Sendable, Codable {
  case baselineEncodedPremultiplied, straight, linearPremultiplied, straightDilated
}
nonisolated func toLinear(_ c: Double) -> Double {
  c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}
nonisolated func toSRGB(_ c: Double) -> Double {
  c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
}
nonisolated func quantize(_ c: Double) -> UInt32 { UInt32(max(0, min(255, (c * 255).rounded()))) }
nonisolated func reviewColor(player: PlayerID, y: Int) -> SIMD3<Double> {
  if y >= 400 { return [1, 1, 1] }
  if y >= 240 { return [0.35, 0.35, 0.35] }
  return player == .player1 ? [0.8, 0.2, 0.05] : [0.05, 0.3, 0.9]
}
nonisolated func encodeRGBA(_ color: SIMD3<Double>, alpha: Double, encoding: ReviewEncoding)
  -> UInt32
{
  let values = (0..<3).map { i -> UInt32 in
    switch encoding {
    case .baselineEncodedPremultiplied: return quantize(color[i] * alpha)
    case .linearPremultiplied: return quantize(toSRGB(toLinear(color[i]) * alpha))
    case .straight, .straightDilated: return quantize(color[i])
    }
  }
  return values[2] | values[1] << 8 | values[0] << 16 | quantize(alpha) << 24
}
// Actual bytes are regenerated. A mode label never reinterprets the same fractional-alpha RGB.
actor ReviewProducer {
  let source = SyntheticProducer()
  func produce(
    frame: UInt64, generation: UUID = spikeGeneration,
    encoding: ReviewEncoding, chart: Bool = false
  ) async throws -> SyntheticCutoutFrame {
    let original = try await source.produce(frame: frame, generation: generation)
    if encoding == .baselineEncodedPremultiplied && !chart { return original }
    var images: [PlayerID: CopiedImage] = [:]
    for (id, image) in original.players {
      var words = [UInt32](repeating: 0, count: image.bytesPerRow * image.height / 4)
      let bottom = id == .player1 ? 720 : 608
      for y in 0..<768 {
        for x in 0..<512 {
          let inside = x >= 80 && x < 432 && y >= 48 && y < bottom
          let dilated =
            encoding == .straightDilated && x >= 76 && x < 436 && y >= 44 && y < bottom + 4
          if !inside && !dilated { continue }
          let sx = max(80, min(431, x))
          let sy = max(48, min(bottom - 1, y))
          let legacy = syntheticPixel(x: sx, y: sy, player: id, frame: frame)
          var a = inside ? Double((legacy >> 24) & 255) / 255 : 0
          let sourceA = Double((legacy >> 24) & 255) / 255
          var color =
            SIMD3<Double>(
              Double((legacy >> 16) & 255), Double((legacy >> 8) & 255), Double(legacy & 255))
            / (255 * sourceA)
          if chart {
            color = reviewColor(player: id, y: sy)
            let band = max(0, min(4, Int(Double(sx - 80) / 70.4)))
            a = inside ? Double([0, 64, 128, 192, 255][band]) / 255 : 0
          }
          // Straight zero-alpha black is the control; dilation retains local color at alpha zero.
          if a == 0 && encoding != .straightDilated { color = .zero }
          words[y * image.bytesPerRow / 4 + x] = encodeRGBA(color, alpha: a, encoding: encoding)
        }
      }
      let bytes = words.withUnsafeBytes { Data($0) }
      images[id] = CopiedImage(
        bytes: bytes, bytesPerRow: image.bytesPerRow, width: 512, height: 768,
        placement: image.placement)
    }
    return SyntheticCutoutFrame(
      bodySnapshot: original.bodySnapshot, players: images,
      copyMilliseconds: original.copyMilliseconds)
  }
}
