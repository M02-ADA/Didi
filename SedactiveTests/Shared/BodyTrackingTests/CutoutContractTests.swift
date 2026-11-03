import CoreVideo
import Foundation
import Testing

@testable import Sedactive

nonisolated enum CutoutTestData {
  static func snapshot(
    _ frame: UInt64, generation: UUID? = nil,
    revisions: [PlayerID: UInt64] = [.player1: 1, .player2: 1],
    camera: UInt64 = 1
  ) throws -> BodySnapshot {
    let original = try LH00TestData.snapshot(frame, generation: generation)
    return BodySnapshot(
      sessionGeneration: original.sessionGeneration, frameID: frame, capturedAt: Double(frame),
      cameraGeometryRevision: camera,
      players: original.players.mapValues {
        PlayerBodySample(
          playerID: $0.playerID, calibrationRevision: revisions[$0.playerID],
          trackingStatus: $0.trackingStatus, geometry: $0.geometry, jumpState: $0.jumpState)
      })
  }
  static func event(
    _ revision: UInt64 = 1, status: BodyInputStatus = .running, generation: UUID? = nil,
    revisions: [PlayerID: UInt64] = [.player1: 1, .player2: 1],
    cutovers: [PlayerID: BodyInputCutover] = [:], camera: UInt64 = 1
  ) throws -> BodyInputStatusEvent {
    let generation = try generation ?? LH00TestData.load().configuration.sessionGeneration
    return BodyInputStatusEvent(
      sessionGeneration: generation, occurredAt: Double(revision), statusRevision: revision,
      status: status,
      context: BodyInputContext(
        sessionGeneration: generation,
        cameraGeometryRevision: camera, calibrationRevisions: revisions, cutovers: cutovers,
        isActive: status == .running), delivery: .prepared, progress: .waiting)
  }
  static func placement(_ id: PlayerID) throws -> CutoutPlacement {
    CutoutPlacement(
      sourceCropPx: try CutoutPixelRect(x: 0, y: 0, width: 8, height: 8),
      textureContentRectPx: try CutoutPixelRect(x: 0, y: 0, width: 8, height: 8),
      playerPlaneRect: try CutoutPlayerPlaneRect(
        x: id == .player1 ? -1.05 : 0.25,
        y: 0, width: 0.8, height: 0.8))
  }
  static func firstPixel(_ image: CutoutImage, y: Int = 1) -> [UInt8] {
    var bytes: [UInt8] = []
    image.withUnsafeBytes {
      bytes = Array($0[(y * image.descriptor.bytesPerRow)..<(y * image.descriptor.bytesPerRow + 4)])
    }
    return bytes
  }
  static func image(_ frame: PlayerCutoutFrame, _ id: PlayerID = .player1) throws -> CutoutImage {
    guard case .available(let image, _) = frame.players[id] else {
      throw CutoutError.invalidValue("missing test image")
    }
    return image
  }
}

/// Synthetic test producer, not fake input wired into gameplay. Its CV pool stays actor-confined.
actor CutoutTestProducer {
  private let copier: CutoutPixelCopier
  private var retained: [CVPixelBuffer] = []
  init(budget: CutoutMemoryBudget, alignment: Int = 64, sourceLimit: Int = 2) throws {
    copier = try CutoutPixelCopier(
      width: 8, height: 8, budget: budget,
      rowAlignment: alignment, sourceBufferLimit: sourceLimit)
  }
  func image(
    _ snapshot: BodySnapshot, _ id: PlayerID = .player1,
    alpha: CutoutSourceAlpha = .straight, edge: CutoutZeroAlphaColor = .zeroRGB,
    retainSource: Bool = false, fail: Bool = false
  ) throws -> CutoutImage {
    try copier.makeImage(
      source: CutoutImageSource(snapshot: snapshot, playerID: id),
      sourceAlpha: alpha, zeroAlphaColor: edge
    ) { buffer in
      if fail { throw CutoutError.invalidValue("injected writer failure") }
      if retainSource { retained.append(buffer) }
      let lock = CVPixelBufferLockBaseAddress(buffer, [])
      guard lock == kCVReturnSuccess else { throw CutoutError.sourceBuffer(lock) }
      defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
      let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(buffer)
      for y in 0..<8 {
        for x in 0..<8 {
          let p = y * stride + x * 4
          if y == 0 {
            base[p] = alpha == .straight ? 17 : 0
            base[p + 1] = 0
            base[p + 2] = 0
            base[p + 3] = 0
          } else {
            let color: UInt8 = alpha == .straight ? 255 : (alpha == .premultipliedSRGB ? 128 : 188)
            base[p] = id == .player2 ? color : 0
            base[p + 1] = 0
            base[p + 2] = id == .player1 ? color : 0
            base[p + 3] = 128
          }
        }
        for x in 32..<stride { base[y * stride + x] = 0xA5 }
      }
    }
  }
  func frame(_ snapshot: BodySnapshot, missing: Set<PlayerID> = []) throws -> PlayerCutoutFrame {
    var slots: [PlayerID: PlayerCutoutSlot] = [:]
    for id in PlayerID.allCases {
      slots[id] =
        missing.contains(id)
        ? .unavailable(.maskMissing)
        : .available(image: try image(snapshot, id), placement: try CutoutTestData.placement(id))
    }
    return try PlayerCutoutFrame(
      bodySnapshot: snapshot, sourceImageSizePx: CutoutImageSize(width: 8, height: 8),
      players: slots)
  }
  func publish(_ snapshot: BodySnapshot, to handoff: PlayerCutoutHandoff) async throws {
    let packet = try frame(snapshot)
    try await handoff.offer(packet, at: snapshot.capturedAt)
  }
  func rewriteSourcesAndRelease() {
    for buffer in retained {
      CVPixelBufferLockBaseAddress(buffer, [])
      memset(
        CVPixelBufferGetBaseAddress(buffer)!, 0xEE,
        CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
      CVPixelBufferUnlockBaseAddress(buffer, [])
    }
    retained.removeAll()
  }
}

nonisolated struct CutoutContractTests {
  @Test func packetKeepsExactEvidenceAndBothSlots() async throws {
    let budget = CutoutMemoryBudget(limits: try CutoutMemoryLimits())
    let producer = try CutoutTestProducer(budget: budget)
    let body = try CutoutTestData.snapshot(1)
    let packet = try await producer.frame(body)
    #expect(packet.bodySnapshot == body)
    #expect(Set(packet.players.keys) == Set(PlayerID.allCases))
    for id in PlayerID.allCases {
      let image = try CutoutTestData.image(packet, id)
      #expect(image.source == (try CutoutImageSource(snapshot: body, playerID: id)))
      #expect(image.descriptor.alpha == .straight)
      #expect(image.descriptor.colorEncoding == .sRGB)
      #expect(
        CutoutTestData.firstPixel(image) == (id == .player1 ? [0, 0, 255, 128] : [255, 0, 0, 128]))
    }
    #expect(throws: CutoutError.self) {
      try PlayerCutoutFrame(
        bodySnapshot: body, sourceImageSizePx: CutoutImageSize(width: 8, height: 8),
        players: [.player1: .unavailable(.maskMissing)])
    }
  }
  @Test func mismatchedSlotOrFrameIsRejected() async throws {
    let producer = try CutoutTestProducer(budget: CutoutMemoryBudget(limits: CutoutMemoryLimits()))
    let first = try CutoutTestData.snapshot(1)
    let next = try CutoutTestData.snapshot(2)
    let image = try await producer.image(first)
    for (body, id) in [(first, PlayerID.player2), (next, .player1)] {
      #expect(throws: CutoutError.self) {
        try PlayerCutoutFrame(
          bodySnapshot: body, sourceImageSizePx: CutoutImageSize(width: 8, height: 8),
          players: [
            id: .available(image: image, placement: CutoutTestData.placement(id)),
            id == .player1 ? .player2 : .player1: .unavailable(.maskMissing),
          ])
      }
    }
  }
  @Test(arguments: [CutoutSourceAlpha.straight, .premultipliedSRGB, .premultipliedLinear])
  func sourceAlphaIsActuallyConverted(_ alpha: CutoutSourceAlpha) async throws {
    let producer = try CutoutTestProducer(budget: CutoutMemoryBudget(limits: CutoutMemoryLimits()))
    let image = try await producer.image(CutoutTestData.snapshot(1), alpha: alpha)
    #expect(CutoutTestData.firstPixel(image) == [0, 0, 255, 128])
    #expect(CutoutTestData.firstPixel(image, y: 0) == [0, 0, 0, 0])
  }
  @Test func preservedStraightEdgeColorIsExplicit() async throws {
    let producer = try CutoutTestProducer(budget: CutoutMemoryBudget(limits: CutoutMemoryLimits()))
    let image = try await producer.image(CutoutTestData.snapshot(1), edge: .preservedEdgeColor)
    #expect(CutoutTestData.firstPixel(image, y: 0) == [17, 0, 0, 0])
    await #expect(throws: CutoutError.self) {
      try await producer.image(
        CutoutTestData.snapshot(2), alpha: .premultipliedSRGB, edge: .preservedEdgeColor)
    }
  }
  @Test func descriptorChecksOverflowAndPaddedRows() throws {
    let limits = try CutoutMemoryLimits()
    let descriptor = try CutoutImageDescriptor(width: 8, height: 8, bytesPerRow: 64, limits: limits)
    #expect(descriptor.byteCount == 512)
    for values in [
      (0, 8, 64), (8, 0, 64), (8, 8, 31), (8, 8, 33), (Int.max, 8, Int.max), (8, Int.max, 64),
    ] {
      #expect(throws: CutoutError.self) {
        try CutoutImageDescriptor(
          width: values.0, height: values.1, bytesPerRow: values.2, limits: limits)
      }
    }
    #expect(throws: CutoutError.self) { try CutoutPixelRect(x: Int.max, y: 0, width: 1, height: 1) }
    #expect(throws: CutoutError.self) {
      try CutoutPlayerPlaneRect(x: .nan, y: 0, width: 1, height: 1)
    }
  }
  @Test func partialOutcomesAndInvalidJointEvidenceStayIndependent() async throws {
    let producer = try CutoutTestProducer(budget: CutoutMemoryBudget(limits: CutoutMemoryLimits()))
    let packet = try await producer.frame(CutoutTestData.snapshot(1), missing: [.player1])
    guard case .unavailable(.maskMissing) = packet.players[.player1] else {
      Issue.record("P1 reason lost")
      return
    }
    #expect(try CutoutTestData.image(packet, .player2).source.playerID == .player2)
    let body = try CutoutTestData.snapshot(2)
    let original = body.players[.player1]!
    let missing = try EstimatedScalar(value: nil, validity: .missingLandmarks)
    var samples = body.players
    let g = original.geometry
    samples[.player1] = PlayerBodySample(
      playerID: .player1, calibrationRevision: 1, trackingStatus: .reliable,
      geometry: BodyGeometry(
        crownY: g.crownY, leftWristY: missing, rightWristY: g.rightWristY,
        leftSoleY: g.leftSoleY, rightSoleY: g.rightSoleY, centerX: g.centerX),
      jumpState: original.jumpState)
    let partialBody = BodySnapshot(
      sessionGeneration: body.sessionGeneration, frameID: 2, capturedAt: 2,
      cameraGeometryRevision: 1, players: samples)
    let withImage = try await producer.frame(partialBody)
    #expect(
      withImage.bodySnapshot.players[.player1]?.geometry.leftWristY.validity == .missingLandmarks)
    #expect(try CutoutTestData.image(withImage).source.frameID == 2)
  }
}
