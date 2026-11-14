import Foundation

nonisolated enum CutoutError: Error, Equatable, Sendable {
  case invalidValue(String)
  case resourcePressure
  case sourceBuffer(Int32)
  case incompatibleContext, staleObservation, foreignBudget, notRunning
  case consumerAlreadyClaimed, invalidConsumer, observerAlreadyRegistered, reentrantControl
  case staleInputEvent
}
nonisolated func requireCutout(_ condition: Bool, _ field: String) throws {
  if !condition { throw CutoutError.invalidValue(field) }
}

/// Safety ceilings, configurable at composition time; not validated iPad performance budgets.
nonisolated struct CutoutMemoryLimits: Sendable, Equatable {
  let maximumDimension: Int
  let maximumImageBytes: Int
  let maximumRetainedBytes: Int
  let maximumImages: Int
  init(
    maximumDimension: Int = 2048, maximumImageBytes: Int = 8 * 1024 * 1024,
    maximumRetainedBytes: Int = 18 * 1024 * 1024, maximumImages: Int = 6
  ) throws {
    try requireCutout(
      maximumDimension > 0 && maximumImageBytes > 0
        && maximumRetainedBytes > 0 && maximumImages > 0, "memory limits")
    self.maximumDimension = maximumDimension
    self.maximumImageBytes = maximumImageBytes
    self.maximumRetainedBytes = maximumRetainedBytes
    self.maximumImages = maximumImages
  }
}
nonisolated enum CutoutPixelFormat: Sendable { case bgra8 }
nonisolated enum CutoutColorEncoding: Sendable { case sRGB }
nonisolated enum CutoutAlphaConvention: Sendable { case straight }
nonisolated enum CutoutZeroAlphaColor: Sendable {
  case zeroRGB
  /// Producer-prepared color outside the matte. Alpha remains zero; no dilation algorithm implied.
  case preservedEdgeColor
}
nonisolated struct CutoutImageDescriptor: Sendable, Equatable {
  let width: Int, height: Int, bytesPerRow: Int, byteCount: Int
  let pixelFormat: CutoutPixelFormat = .bgra8
  let colorEncoding: CutoutColorEncoding = .sRGB
  let alpha: CutoutAlphaConvention = .straight
  let zeroAlphaColor: CutoutZeroAlphaColor
  /// Upright, unmirrored, top-left raster rows. Anatomical labels remain canonical.
  init(
    width: Int, height: Int, bytesPerRow: Int, zeroAlphaColor: CutoutZeroAlphaColor = .zeroRGB,
    limits: CutoutMemoryLimits
  ) throws {
    let (row, rowOverflow) = width.multipliedReportingOverflow(by: 4)
    let (bytes, byteOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
    try requireCutout(
      width > 0 && height > 0 && width <= limits.maximumDimension
        && height <= limits.maximumDimension && !rowOverflow && !byteOverflow
        && bytesPerRow >= row && bytesPerRow % 4 == 0 && bytes > 0
        && bytes <= limits.maximumImageBytes, "image dimensions/stride/bytes")
    self.width = width
    self.height = height
    self.bytesPerRow = bytesPerRow
    byteCount = bytes
    self.zeroAlphaColor = zeroAlphaColor
  }
}

nonisolated struct CutoutImageSize: Sendable, Equatable {
  let width: Int, height: Int
  init(width: Int, height: Int) throws {
    try requireCutout(width > 0 && height > 0, "source image size")
    self.width = width
    self.height = height
  }
}
/// Integer pixel edges. Source crop uses bottom-left; canvas content uses top-left.
nonisolated struct CutoutPixelRect: Sendable, Equatable {
  let x: Int, y: Int, width: Int, height: Int
  init(x: Int, y: Int, width: Int, height: Int) throws {
    let (_, ox) = x.addingReportingOverflow(width)
    let (_, oy) = y.addingReportingOverflow(height)
    try requireCutout(x >= 0 && y >= 0 && width > 0 && height > 0 && !ox && !oy, "pixel rect")
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
  func fits(width: Int, height: Int) -> Bool {
    x + self.width <= width && y + self.height <= height
  }
}
nonisolated struct CutoutPlayerPlaneRect: Sendable, Equatable {
  let x: Double, y: Double, width: Double, height: Double
  init(x: Double, y: Double, width: Double, height: Double) throws {
    try requireCutout(
      [x, y, width, height, x + width, y + height].allSatisfy(\.isFinite)
        && width > 0 && height > 0, "player plane rect")
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}
nonisolated struct CutoutPlacement: Sendable, Equatable {
  let sourceCropPx: CutoutPixelRect
  let textureContentRectPx: CutoutPixelRect
  let playerPlaneRect: CutoutPlayerPlaneRect
  func validate(sourceSize: CutoutImageSize, descriptor: CutoutImageDescriptor) throws {
    try requireCutout(
      sourceCropPx.fits(width: sourceSize.width, height: sourceSize.height)
        && textureContentRectPx.fits(width: descriptor.width, height: descriptor.height),
      "crop/content bounds")
    let sourceAspect = Double(sourceCropPx.width) / Double(sourceCropPx.height)
    let contentAspect = Double(textureContentRectPx.width) / Double(textureContentRectPx.height)
    let unitsX = playerPlaneRect.width / Double(textureContentRectPx.width)
    let unitsY = playerPlaneRect.height / Double(textureContentRectPx.height)
    // Integer fitting can round by a pixel; reject independent stretching, allow that rounding.
    try requireCutout(
      abs(sourceAspect - contentAspect) <= 2 / Double(textureContentRectPx.height)
        && unitsX.isFinite && unitsY.isFinite && unitsX > 0 && unitsY > 0
        && abs(unitsX - unitsY) <= max(unitsX, unitsY) * 1e-9, "uniform crop mapping")
  }
}
/// Source binding is attached when pixels are copied, then checked against the envelope.
nonisolated struct CutoutImageSource: Sendable, Equatable {
  let playerID: PlayerID
  let sessionGeneration: UUID
  let frameID: UInt64
  let capturedAt: Double
  let cameraGeometryRevision: UInt64
  let calibrationRevision: UInt64
  init(snapshot: BodySnapshot, playerID: PlayerID) throws {
    try snapshot.validate()
    guard let sample = snapshot.players[playerID], let revision = sample.calibrationRevision,
      sample.trackingStatus == .reliable
    else { throw CutoutError.incompatibleContext }
    self.playerID = playerID
    sessionGeneration = snapshot.sessionGeneration
    frameID = snapshot.frameID
    capturedAt = snapshot.capturedAt
    cameraGeometryRevision = snapshot.cameraGeometryRevision
    calibrationRevision = revision
  }
}
nonisolated enum CutoutUnavailableReason: String, Sendable {
  case notCalibrated, identityUncertain, trackingLost, maskMissing, maskUnmatched, maskAmbiguous
  case sourceUnavailable, compositionFailed, resourcePressure
}
nonisolated enum PlayerCutoutSlot: Sendable {
  case available(image: CutoutImage, placement: CutoutPlacement)
  case unavailable(CutoutUnavailableReason)
}
nonisolated struct PlayerCutoutFrame: Sendable {
  let bodySnapshot: BodySnapshot
  let sourceImageSizePx: CutoutImageSize
  let players: [PlayerID: PlayerCutoutSlot]
  init(
    bodySnapshot: BodySnapshot, sourceImageSizePx: CutoutImageSize,
    players: [PlayerID: PlayerCutoutSlot]
  ) throws {
    try bodySnapshot.validate()
    try requireCutout(Set(players.keys) == Set(PlayerID.allCases), "exactly P1/P2 outcomes")
    for (id, slot) in players {
      if case .available(let image, let placement) = slot {
        try requireCutout(
          image.source == CutoutImageSource(snapshot: bodySnapshot, playerID: id),
          "image/body source mismatch")
        try placement.validate(sourceSize: sourceImageSizePx, descriptor: image.descriptor)
      }
    }
    self.bodySnapshot = bodySnapshot
    self.sourceImageSizePx = sourceImageSizePx
    self.players = players
  }
}
