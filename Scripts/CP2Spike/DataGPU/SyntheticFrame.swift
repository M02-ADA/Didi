import CoreVideo
import Darwin
import Foundation

nonisolated enum SpikeError: Error { case invalid(String) }
nonisolated func check(_ value: Bool, _ message: String) throws {
  if !value { throw SpikeError.invalid(message) }
}
nonisolated func nanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
nonisolated struct PixelRect: Sendable, Equatable {
  let x: Double, y: Double, width: Double, height: Double
}
nonisolated struct Placement: Sendable {
  let sourceCropPx: PixelRect
  let textureContentRectPx: PixelRect
  let playerPlaneRect: PixelRect
  func fullQuad(width: Int, height: Int, lane: Double) throws -> PixelRect {
    let c = textureContentRectPx
    let p = playerPlaneRect
    try check(
      c.width > 0 && c.height > 0 && c.x >= 0 && c.y >= 0 && c.x + c.width <= Double(width)
        && c.y + c.height <= Double(height), "content rect")
    try check(
      [p.x, p.y, p.width, p.height, c.x, c.y, c.width, c.height].allSatisfy { $0.isFinite }
        && p.width > 0 && p.height > 0, "finite placement")
    let sx = p.width / c.width
    let sy = p.height / c.height
    try check(abs(sx - sy) < 1e-9, "uniform crop fit")
    let left = p.x - c.x * sx
    let top = p.y + p.height + c.y * sy
    let w = Double(width) * sx
    let h = Double(height) * sy
    // Reflect the full quad about this player's lane, and mirror UVs once.
    return PixelRect(x: 2 * lane - (left + w), y: top - h, width: w, height: h)
  }
}
nonisolated struct CopiedImage: Sendable {
  let bytes: Data
  let bytesPerRow: Int
  let width: Int, height: Int
  let placement: Placement
}
nonisolated struct SyntheticCutoutFrame: Sendable {
  let bodySnapshot: BodySnapshot
  let players: [PlayerID: CopiedImage]  // Missing slot is an explicit synthetic unavailable case.
  let copyMilliseconds: Double
}
nonisolated let spikeGeneration = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
nonisolated let spikeLayout = PlayerPlaneLayout(
  leftCenterX: -0.8, rightCenterX: 0.8, gameUnitsPerImageHeight: 2)
nonisolated func spikeContext(
  generation: UUID = spikeGeneration, revisions: [PlayerID: UInt64] = [.player1: 1, .player2: 1]
) -> BodyInputContext {
  BodyInputContext(
    sessionGeneration: generation, cameraGeometryRevision: 1, calibrationRevisions: revisions,
    cutovers: [:], isActive: true)
}
nonisolated func checkedBytes(width: Int, height: Int, stride: Int) throws -> Int {
  let (row, ro) = width.multipliedReportingOverflow(by: 4)
  let (size, so) = stride.multipliedReportingOverflow(by: height)
  try check(
    width == 512 && height == 768 && !ro && !so && stride >= row && stride <= 4096
      && stride % 256 == 0 && size > 0 && size <= 3 * 1024 * 1024, "bounded dimensions/row stride")
  return size
}
// Top-left raster, asymmetric padding/corners. BGRA bytes, premultiplied encoded color.
nonisolated func syntheticPixel(x: Int, y: Int, player: PlayerID, frame: UInt64) -> UInt32 {
  let bottom = player == .player1 ? 720 : 608
  guard x >= 80 && x < 432 && y >= 48 && y < bottom else { return 0 }
  var a: UInt32 = 255
  if x < 88 || x >= 424 || y < 56 || y >= bottom - 8 { a = 128 }
  var r: UInt32 = player == .player1 ? a : 0
  var b: UInt32 = player == .player2 ? a : 0
  var g: UInt32 = ((x / 32 + y / 32 + Int(frame % 2)) % 2 == 0) ? a / 3 : 0
  // Four corner identities: yellow TL, green TR, magenta BL, white BR.
  if x < 128 && y < 96 {
    r = a
    g = a
    b = 0
  }
  if x >= 384 && y < 96 {
    r = 0
    g = a
    b = 0
  }
  if x < 128 && y >= bottom - 48 {
    r = a
    g = 0
    b = a
  }
  if x >= 384 && y >= bottom - 48 {
    r = a
    g = a
    b = a
  }
  // Eight changing sequence bars, left-to-right in canonical source coordinates.
  if y >= 330 && y < 370 {
    let bit = (x - 80) / 44
    if ((frame >> bit) & 1) == 1 {
      r = a
      g = a
      b = a
    } else {
      r = 0
      g = 0
      b = 0
    }
  }
  return b | (g << 8) | (r << 16) | (a << 24)
}

actor SyntheticProducer {
  private var pool: CVPixelBufferPool?
  private let padded: Bool
  init(padded: Bool = false) { self.padded = padded }
  func produce(frame: UInt64, generation: UUID = spikeGeneration) throws -> SyntheticCutoutFrame {
    if pool == nil {
      var created: CVPixelBufferPool?
      let attrs: [String: Any] = [
        kCVPixelBufferWidthKey as String: 512, kCVPixelBufferHeightKey as String: 768,
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferBytesPerRowAlignmentKey as String: padded ? 4096 : 64,
      ]
      try check(
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &created) == kCVReturnSuccess,
        "pool create")
      pool = created
    }
    var images: [PlayerID: CopiedImage] = [:]
    var copyNS: UInt64 = 0
    var samples: [PlayerID: PlayerBodySample] = [:]
    for id in PlayerID.allCases {
      var raw: CVPixelBuffer?
      let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: 2] as CFDictionary
      try check(
        CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool!, aux, &raw)
          == kCVReturnSuccess, "bounded pool checkout")
      guard let buffer = raw else { throw SpikeError.invalid("no source") }
      let stride = CVPixelBufferGetBytesPerRow(buffer)
      let size = try checkedBytes(width: 512, height: 768, stride: stride)
      try check(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess, "writer lock")
      do {
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
          throw SpikeError.invalid("source address")
        }
        memset(base, 0xA5, size)
        for y in 0..<768 {
          for x in 0..<512 {
            base.storeBytes(
              of: syntheticPixel(x: x, y: y, player: id, frame: frame),
              toByteOffset: y * stride + x * 4, as: UInt32.self)
          }
        }
      } catch {
        CVPixelBufferUnlockBaseAddress(buffer, [])
        throw error
      }
      try check(CVPixelBufferUnlockBaseAddress(buffer, []) == kCVReturnSuccess, "writer unlock")
      try check(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess, "reader lock")
      guard let base = CVPixelBufferGetBaseAddress(buffer) else {
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        throw SpikeError.invalid("read address")
      }
      let t = nanos()
      let data = Data(bytes: base, count: size)  // Explicit independent copy; no pointer escapes.
      copyNS += nanos() - t
      try check(
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly) == kCVReturnSuccess, "reader unlock")
      let lane = spikeLayout.centerX(for: id)
      let scale = 0.002  // Same scale for both players; shorter P2 source crop, not height normalization.
      let h = id == .player1 ? 672.0 : 560.0
      let placement = Placement(
        sourceCropPx: .init(x: 0, y: 0, width: 352, height: h),
        textureContentRectPx: .init(x: 80, y: 48, width: 352, height: h),
        playerPlaneRect: .init(
          x: lane - 0.352 + Double(frame % 2) * 0.04, y: Double(frame % 3) * 0.025,
          width: 352 * scale, height: h * scale))
      images[id] = CopiedImage(
        bytes: data, bytesPerRow: stride, width: 512, height: 768, placement: placement)
      let scalar: (Double) throws -> EstimatedScalar = {
        try EstimatedScalar(value: $0, validity: .valid)
      }
      samples[id] = try PlayerBodySample(
        playerID: id, calibrationRevision: 1, trackingStatus: .reliable,
        geometry: BodyGeometry(
          crownY: scalar(placement.playerPlaneRect.y + placement.playerPlaneRect.height),
          leftWristY: scalar(0.8), rightWristY: scalar(0.8),
          leftSoleY: scalar(placement.playerPlaneRect.y),
          rightSoleY: scalar(placement.playerPlaneRect.y),
          centerX: scalar(lane + Double(frame % 2) * 0.04)),
        jumpState: JumpState(phase: .grounded, validity: .valid))
      // Raw buffer leaves scope; producer keeps only its pool. The exported Data stays independent.
    }
    let snapshot = BodySnapshot(
      sessionGeneration: generation, frameID: frame, capturedAt: Double(frame) / 60,
      cameraGeometryRevision: 1, players: samples)
    try snapshot.validate()
    return SyntheticCutoutFrame(
      bodySnapshot: snapshot, players: images, copyMilliseconds: Double(copyNS) / 1e6)
  }
}

nonisolated func verifyImage(_ image: CopiedImage, player: PlayerID, frame: UInt64) throws {
  let size = try checkedBytes(width: image.width, height: image.height, stride: image.bytesPerRow)
  try check(image.bytes.count == size, "data size")
  try image.bytes.withUnsafeBytes { bytes in
    for y in 0..<image.height {
      for x in 0..<image.width {
        try check(
          bytes.loadUnaligned(fromByteOffset: y * image.bytesPerRow + x * 4, as: UInt32.self)
            == syntheticPixel(x: x, y: y, player: player, frame: frame), "exact source pixel")
      }
    }
    for y in 0..<image.height {
      for x in (image.width * 4)..<image.bytesPerRow {
        try check(bytes[y * image.bytesPerRow + x] == 0xA5, "row padding")
      }
    }
  }
}
