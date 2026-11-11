#if DEBUG
import CoreGraphics
import CoreVideo
import Foundation

nonisolated enum AnatomyInspectionMeasurement: String, CaseIterable, Sendable {
  case crown, leftSole, rightSole
  var inputs: [BodyJoint] {
    self == .crown ? [.nose, .leftEye, .rightEye, .leftEar, .rightEar, .neck]
      : [.leftHip, .rightHip, .leftAnkle, .rightAnkle]
  }
  func scalar(_ value: AnatomicalPlayerCandidate?) -> AnatomicalCandidateScalar? {
    switch self { case .crown: value?.crown; case .leftSole: value?.leftSole; case .rightSole: value?.rightSole }
  }
}
nonisolated struct AnatomyInspectionKey: Hashable, Sendable {
  let player: PlayerID
  let measurement: AnatomyInspectionMeasurement
}
nonisolated struct AnatomyInspectionPoint: Equatable, Sendable { let x: Double; let y: Double }
nonisolated struct AnatomyInspectionRegion: Sendable {
  let minX: Double, minY: Double, maxX: Double, maxY: Double
  func contains(_ p: AnatomyInspectionPoint) -> Bool {
    (minX...maxX).contains(p.x) && (minY...maxY).contains(p.y)
  }
  func overlaps(_ other: Self) -> Bool {
    max(minX, other.minX) <= min(maxX, other.maxX) && max(minY, other.minY) <= min(maxY, other.maxY)
  }
}
nonisolated struct AnatomyInspectionTicket: Equatable, Sendable {
  let id: UUID
  let calibration: CalibrationAdmission
  let acceptedRevision: UInt64
  let requestedAt: Double
  let expiresAt: Double // original collection deadline; never extended by inspection
}
nonisolated struct AnatomyInspectionPlayer: Sendable {
  let candidateID: UInt64
  let tracking: PlayerTrackingSlotResult
  let joints: [BodyJoint: PoseJoint] // one original frame, at most the accepted 14 joints
  let region: PersonMaskRegion?
  let anatomy: AnatomicalPlayerCandidate?
}
nonisolated struct AnatomyInspectionFrame: Sendable {
  let ticket: AnatomyInspectionTicket
  let source: CameraFrameMetadata
  let acknowledgment: CameraBindingAcknowledgment
  let players: [PlayerID: AnatomyInspectionPlayer]
  let image: CGImage?
  let mask: CGImage?
  let nativeWidth: Int?, nativeHeight: Int?, nativeStride: Int?
  let nativeFormat: OSType?
  let quality: PersonMaskQuality
  let serviceSeconds: Double
}
nonisolated struct AnatomyInspectionReference: Sendable {
  let inspection: UUID
  let source: CameraFrameMetadata
  let key: AnatomyInspectionKey
  let candidateID: UInt64
  let point: AnatomyInspectionPoint? // nil explicitly means evaluator could not identify it
}
nonisolated struct AnatomyInspectionSummary: Sendable {
  var observed = 0, eligible = 0, noCandidate = 0, compared = 0, referenceMissing = 0
  var refusals: [AnatomicalCandidateStatus: Int] = [:]
  var totalVerticalErrorPixels = 0.0, maximumVerticalErrorPixels = 0.0
}
nonisolated struct AnatomyInspectionSummaryReceipt: Sendable {
  let ticket: AnatomyInspectionTicket
  let lastSource: CameraFrameMetadata
  let frames: Int
  let sources: [CameraFrameMetadata]
  let summaries: [AnatomyInspectionKey: AnatomyInspectionSummary]
}
nonisolated enum AnatomyInspectionFailure: String, Sendable { case rejectedCompletion }
nonisolated enum AnatomyInspectionError: Error { case inactive, busy, incompatible, ambiguousReference, completed }

/// Pure, bounded inspection state. Owned ONLY by CameraTrackingGate's existing mutex.
/// This is historical evaluation data, never a live observation, validation certificate or baseline.
nonisolated struct AnatomyInspectionState: Sendable {
  var ticket: AnatomyInspectionTicket?
  var frame: AnatomyInspectionFrame?
  var capturing = false
  var summaries: [AnatomyInspectionKey: AnatomyInspectionSummary] = [:] // at most 6 keys
  var references: [AnatomyInspectionKey: AnatomyInspectionReference] = [:] // at most 6
  var referenceRegions: [PlayerID: AnatomyInspectionRegion] = [:] // independent evaluator boxes, never mask predictions
  var inspectedSources: [CameraFrameMetadata] = [] // at most ten frame identities, never coordinate history
  var frames = 0
  var revealed = false
  private var collection: CalibrationRequest?
  private var summaryTicket: AnatomyInspectionTicket?
  private var summarySource: CameraFrameMetadata?
  var historicalSummary: AnatomyInspectionSummaryReceipt?
  var lastFailure: AnatomyInspectionFailure?
  mutating func invalidate() {
    let history = summaryTicket.flatMap { ticket in summarySource.map {
      AnatomyInspectionSummaryReceipt(ticket: ticket, lastSource: $0, frames: frames, sources: inspectedSources, summaries: summaries)
    }} ?? historicalSummary
    self = Self()
    historicalSummary = history // bounded scalars only; no image, joint data, points or player boxes
  }
  mutating func request(calibration: CalibrationAdmission, acceptedRevision: UInt64,
    at time: Double, deadline: Double, ownedBytes: Int) throws -> UUID {
    guard ownedBytes == 0, ticket == nil, frame == nil, !capturing else { throw AnatomyInspectionError.busy }
    guard time.isFinite, deadline.isFinite, deadline > time else { throw AnatomyInspectionError.inactive }
    if collection != calibration.request { self = Self(); collection = calibration.request }
    guard lastFailure == nil, frames < StandingCollectionPolicyV1.sampleCount else { throw AnatomyInspectionError.completed }
    let id = UUID()
    ticket = .init(id: id, calibration: calibration, acceptedRevision: acceptedRevision,
      requestedAt: time, expiresAt: deadline)
    references = [:]; referenceRegions = [:]; revealed = false
    return id
  }
  mutating func begin(_ id: UUID?, calibration: CalibrationAdmission?, source: CameraFrameMetadata,
    at time: Double) -> AnatomyInspectionTicket? {
    guard let ticket, id == ticket.id, !capturing, frame == nil,
      calibration == ticket.calibration, source.context == ticket.calibration.source,
      source.capturedAt >= ticket.requestedAt, time >= source.capturedAt,
      time - source.capturedAt < StandingCollectionPolicyV1.sampleFreshness,
      time < ticket.expiresAt,
      inspectedSources.last.map({ source.frameID > $0.frameID && source.capturedAt > $0.capturedAt }) ?? true else { return nil }
    capturing = true; return ticket
  }
  mutating func finish(_ value: AnatomyInspectionFrame, at time: Double) -> Bool {
    guard capturing, ticket == value.ticket, time < value.ticket.expiresAt,
      time >= value.source.capturedAt,
      time - value.source.capturedAt < StandingCollectionPolicyV1.sampleFreshness,
      value.source.context == value.ticket.calibration.source,
      Set(value.players.keys) == Set(PlayerID.allCases),
      Set(value.players.values.map(\.candidateID)).count == 2 else { return false }
    capturing = false; frame = value; frames += 1
    summaryTicket = value.ticket; summarySource = value.source; inspectedSources.append(value.source)
    for id in PlayerID.allCases {
      for measurement in AnatomyInspectionMeasurement.allCases {
        let key = AnatomyInspectionKey(player: id, measurement: measurement)
        var summary = summaries[key] ?? .init(); summary.observed += 1
        if let scalar = measurement.scalar(value.players[id]?.anatomy) {
          if scalar.status == .experimental, let y = scalar.imageY, y.isFinite, (0...1).contains(y) {
            summary.eligible += 1
          } else { summary.refusals[scalar.status, default: 0] += 1 }
        } else { summary.noCandidate += 1 }
        summaries[key] = summary
      }
    }
    return true
  }
  mutating func mark(_ value: AnatomyInspectionReference) throws {
    guard !revealed else { throw AnatomyInspectionError.completed }
    guard let frame, value.inspection == frame.ticket.id, value.source == frame.source,
      let player = frame.players[value.key.player], value.candidateID == player.candidateID else {
      throw AnatomyInspectionError.incompatible
    }
    if let point = value.point {
      guard frame.image != nil, point.x.isFinite, point.y.isFinite,
        (0...1).contains(point.x), (0...1).contains(point.y), referenceRegions.count == 2,
        referenceRegions[value.key.player]?.contains(point) == true else {
        throw AnatomyInspectionError.ambiguousReference
      }
    }
    references[value.key] = value
  }
  mutating func setRegion(inspection: UUID, source: CameraFrameMetadata, player: PlayerID,
    candidateID: UInt64, a: AnatomyInspectionPoint, b: AnatomyInspectionPoint) throws {
    guard !revealed, let frame, frame.ticket.id == inspection, frame.source == source,
      frame.players[player]?.candidateID == candidateID, frame.image != nil else {
      throw AnatomyInspectionError.incompatible
    }
    guard [a.x,a.y,b.x,b.y].allSatisfy({ $0.isFinite && (0...1).contains($0) }), a.x != b.x, a.y != b.y else {
      throw AnatomyInspectionError.ambiguousReference
    }
    let region = AnatomyInspectionRegion(minX: min(a.x,b.x), minY: min(a.y,b.y), maxX: max(a.x,b.x), maxY: max(a.y,b.y))
    guard !referenceRegions.contains(where: { $0.key != player && $0.value.overlaps(region) }) else {
      throw AnatomyInspectionError.ambiguousReference
    }
    referenceRegions[player] = region
    references = references.filter { $0.key.player != player }
  }
  mutating func reveal() throws {
    guard let frame, !revealed, references.count == 6 else { throw AnatomyInspectionError.incompatible }
    for (key, reference) in references {
      var summary = summaries[key] ?? .init()
      if let point = reference.point,
        let scalar = key.measurement.scalar(frame.players[key.player]?.anatomy),
        scalar.status == .experimental, let estimate = scalar.imageY {
        let error = abs(point.y - estimate) * Double(frame.source.descriptor.height)
        summary.compared += 1; summary.totalVerticalErrorPixels += error
        summary.maximumVerticalErrorPixels = max(summary.maximumVerticalErrorPixels, error)
      } else if reference.point == nil { summary.referenceMissing += 1 }
      summaries[key] = summary
    }
    revealed = true
  }
  mutating func discard() {
    ticket = nil; frame = nil; references = [:]; referenceRegions = [:]; revealed = false
    // Keep only six aggregate counters in this collection. No image or point history.
    // capturing remains set until the actual blocked operation exits.
  }
  mutating func ended(_ id: UUID) {
    if ticket?.id == id {
      capturing = false
      if frame == nil { ticket = nil; lastFailure = .rejectedCompletion }
    } else if ticket == nil { capturing = false }
  }
}

nonisolated enum AnatomyInspectionGeometry {
  static func canonical(_ location: CGPoint, image: CGSize, bounds: CGSize, mirrored: Bool) -> AnatomyInspectionPoint? {
    let rect = CameraPreviewLayout.rect(image: image, in: bounds)
    guard rect.width > 0, rect.height > 0, rect.contains(location) else { return nil }
    let x = Double((location.x - rect.minX) / rect.width)
    return .init(x: mirrored ? 1 - x : x, y: 1 - Double((location.y - rect.minY) / rect.height))
  }
  static func display(_ point: AnatomyInspectionPoint, in rect: CGRect, mirrored: Bool) -> CGPoint {
    .init(x: rect.minX + (mirrored ? 1 - point.x : point.x) * rect.width,
      y: rect.minY + (1 - point.y) * rect.height)
  }
}

/// Worker-confined builder. Native buffers never escape. Only immutable, budgeted CG images do.
nonisolated final class AnatomyInspectionImageBuilder {
  let source: CameraFrameMetadata
  private let budget: CameraPreviewBudget
  private(set) var mask: CGImage?
  private(set) var width: Int?, height: Int?, stride: Int?, format: OSType?
  init(source: CameraFrameMetadata, budget: CameraPreviewBudget) { self.source = source; self.budget = budget }
  func captureMask(source: CameraFrameMetadata, width: Int, height: Int, stride: Int,
    format: OSType, base: UnsafeRawPointer) {
    guard source == self.source, format == kCVPixelFormatType_OneComponent8,
      width > 0, height > 0, width <= source.descriptor.width, height <= source.descriptor.height,
      stride >= width else { return }
    let (nativeBytes, overflow) = stride.multipliedReportingOverflow(by: height)
    guard !overflow, nativeBytes > 0, nativeBytes <= PersonSegmenter.maximumOutputBytes else { return }
    self.width = width; self.height = height; self.stride = stride; self.format = format
    mask = image(width: width, height: height) { destination in
      for y in 0..<height {
        let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
          let offset = (y * width + x) * 4, label = row[x]
          // Label colors only, NOT P1/P2 identity or anatomical classes.
          destination[offset] = label == 0 ? 0 : 220
          destination[offset + 1] = label == 0 ? 0 : (label % 2 == 0 ? 120 : 220)
          destination[offset + 2] = label == 0 ? 0 : (label % 2 == 0 ? 240 : 40)
          destination[offset + 3] = 0
        }
      }
    }
  }
  func cameraImage(_ buffer: CVPixelBuffer) -> CGImage? {
    guard CVPixelBufferGetWidth(buffer) == source.descriptor.width,
      CVPixelBufferGetHeight(buffer) == source.descriptor.height,
      !CVPixelBufferIsPlanar(buffer), CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
      CVPixelBufferGetBytesPerRow(buffer) >= source.descriptor.width * 4,
      CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    return image(width: source.descriptor.width, height: source.descriptor.height) { destination in
      for y in 0..<source.descriptor.height {
        destination.baseAddress!.advanced(by: y * source.descriptor.width * 4).copyMemory(
          from: base.advanced(by: y * stride), byteCount: source.descriptor.width * 4)
      }
    }
  }
  private func image(width: Int, height: Int, fill: (UnsafeMutableRawBufferPointer) -> Void) -> CGImage? {
    let (row, overflow) = width.multipliedReportingOverflow(by: 4)
    guard !overflow, let descriptor = try? CameraFrameDescriptor(width: width, height: height,
      bytesPerRow: row, pixelFormat: kCVPixelFormatType_32BGRA, maximumBytes: 4 * 1024 * 1024),
      let reservation = budget.reserve(descriptor.byteCount) else { return nil }
    var bytes = Data(count: descriptor.byteCount)
    bytes.withUnsafeMutableBytes(fill)
    return CameraPreviewBacking(bytes: bytes, reservation: reservation).image(descriptor: descriptor)
  }
}
#endif
