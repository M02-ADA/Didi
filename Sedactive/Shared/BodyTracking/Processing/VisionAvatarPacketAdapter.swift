import Foundation

/// Internal derived input to a factory, not a replacement/freeze of Kevin's packet schema.
nonisolated struct VisionAvatarCalibrationValues: Equatable, Sendable {
  let revision: UInt64
  let mapping: ImageToPlayerPlaneMapping
  let standingCrownImageY: Double, standingHipImageY: Double
  let standingLeftAnkleImageY: Double, standingRightAnkleImageY: Double
}
/// Concrete K03 types live in Kevin's newer branch, not this target. App supplies this pure factory
/// after owner coordination; Shared never imports or duplicates his Rendering types.
nonisolated protocol VisionAvatarPacketFactory {
  associatedtype Status
  associatedtype Output
  static func status(_ source: VisionNumericPoseStatus) -> Status
  static func output(source: PlayerTrackingSource, revision: UInt64,
    player1: PlayerTrackingSlotResult, player2: PlayerTrackingSlotResult,
    candidates: [PoseCandidate], calibration: [PlayerID: VisionAvatarCalibrationValues]) -> Output
}
nonisolated struct VisionAvatarPacketBatch<S, O> {
  let status: S
  let resetAll: Bool
  let output: O?
}
nonisolated enum VisionAvatarMappingError: Error, Equatable {
  case invalidStatus, incompatibleSource, stalePresentation, invalidPose, invalidCalibration
}
nonisolated enum VisionAvatarPacketAdapter {
  /// Entire validation precedes either factory call; invalid input cannot partly update a mailbox.
  static func map<F: VisionAvatarPacketFactory>(_ delivery: VisionNumericPoseDrain,
    using: F.Type) throws -> VisionAvatarPacketBatch<F.Status, F.Output> {
    let status = delivery.status
    if let layout = status.layout { try layout.validate() }
    guard !status.active || status.context != nil else { throw VisionAvatarMappingError.invalidStatus }
    if let c = status.context {
      guard c.geometryRevision > 0, c.imageWidth > 0, c.imageHeight > 0,
        !c.mirrored, c.rotationAngle == 0 || c.rotationAngle == 180 else { throw VisionAvatarMappingError.invalidStatus }
    }
    guard status.calibrationRevisions.count <= 2,
      status.calibrationRevisions.allSatisfy({ id, revision in
        revision > 0 && status.cutovers[id].map { $0.capturedAt.isFinite && $0.capturedAt >= 0 } == true
      }) else { throw VisionAvatarMappingError.invalidStatus }
    var output: F.Output?
    if status.active, let value = delivery.output {
      guard value.presentationRevision == status.revision else { throw VisionAvatarMappingError.stalePresentation }
      guard let source = value.tracking.source, source.context == status.context,
        source.controlRevision == status.controlRevision,
        value.tracking.controlRevision == status.controlRevision,
        source.frameID == value.pose.frameID, source.capturedAt == value.pose.capturedAt,
        source.context.generation == value.pose.sessionGeneration,
        source.context.geometryRevision == value.pose.cameraGeometryRevision,
        source.context.imageWidth == value.pose.imageWidth, source.context.imageHeight == value.pose.imageHeight else {
        throw VisionAvatarMappingError.incompatibleSource
      }
      guard (try? value.pose.validate()) != nil, value.pose.candidates.count <= 8 else {
        throw VisionAvatarMappingError.invalidPose
      }
      let tracked = PlayerID.allCases.filter { value.tracking[$0].state == .tracking && !value.tracking[$0].requiresRebind }
      let ids = tracked.compactMap { value.tracking[$0].candidateID }
      guard ids.count == tracked.count, Set(ids).count == ids.count,
        ids.allSatisfy({ id in value.pose.candidates.contains { $0.candidateID == id } }) else {
        throw VisionAvatarMappingError.invalidPose
      }
      var calibration: [PlayerID: VisionAvatarCalibrationValues] = [:]
      for (id, c) in value.acceptedCalibrations {
        guard status.calibrationRevisions[id] == c.revision, let cut = status.cutovers[id],
          value.cutovers[id] == cut, source.frameID > cut.frameID, source.capturedAt > cut.capturedAt else {
          continue // compatible tracking remains direction-only for this slot
        }
        guard c.playerID == id, c.sessionGeneration == source.context.generation,
          c.cameraGeometryRevision == source.context.geometryRevision,
          (try? c.validate()) != nil, let layout = value.layout, layout == status.layout else {
          throw VisionAvatarMappingError.invalidCalibration
        }
        try layout.validate()
        let left = c.standingLeftSoleImageY + c.leftFootOffsetShare * c.standingBodyImageHeight
        let right = c.standingRightSoleImageY + c.rightFootOffsetShare * c.standingBodyImageHeight
        guard [left, right].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
          throw VisionAvatarMappingError.invalidCalibration
        }
        calibration[id] = .init(revision: c.revision, mapping: c.mapping,
          standingCrownImageY: c.standingCrownImageY, standingHipImageY: c.standingHipImageY,
          standingLeftAnkleImageY: left, standingRightAnkleImageY: right)
      }
      output = F.output(source: source, revision: value.presentationRevision,
        player1: value.tracking.player1, player2: value.tracking.player2,
        candidates: value.pose.candidates, calibration: calibration)
    }
    return .init(status: F.status(status), resetAll: delivery.resetAll || !status.active, output: output)
  }
}
