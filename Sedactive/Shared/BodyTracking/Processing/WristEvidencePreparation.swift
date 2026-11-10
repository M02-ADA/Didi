import Foundation

/// Vision-owned E08 preparation, converted atomically to the CP1 attachment; never a contact verdict.
/// Image coordinates remain normalized upright/unmirrored. Plane coordinates use ONLY
/// the existing accepted PlayerCalibration mapping and configured PlayerPlaneLayout.
nonisolated enum WristEvidenceRefusal: String, Sendable, Codable {
  case identityUnavailable, missingJoint, lowConfidence, invalidCoordinate
  case notCalibrated, incompatibleCalibration, beforeCutover, contextChanged
}
nonisolated struct WristPlanePoint: Equatable, Sendable, Codable { let x: Double; let y: Double }
nonisolated struct PreparedWristEvidence: Sendable {
  let observed: PoseJoint? // original value, including actual confidence; no synthesized points
  let observationRefusal: WristEvidenceRefusal?
  let playerPlane: WristPlanePoint?
  let contactRefusal: WristEvidenceRefusal?
}
nonisolated struct PreparedPlayerWrists: Sendable {
  let playerID: PlayerID
  let tracking: PlayerTrackingSlotResult
  let calibrationRevision: UInt64?
  let cutover: BodyInputCutover?
  let left: PreparedWristEvidence
  let right: PreparedWristEvidence
}
nonisolated struct PreparedWristFrame: Sendable {
  let source: CameraFrameMetadata
  let controlRevision: UInt64
  let bindingRequest: UUID
  let bindingSource: PlayerTrackingSource // original atomic pair acknowledgment, not this frame
  let acceptedContextRevision: UInt64
  let players: [PlayerID: PreparedPlayerWrists] // exactly two, no history
}
nonisolated enum WristEvidencePreparation {
  static func prepare(_ pose: CameraPoseResult, association: PlayerTrackingSnapshot?,
    admission: CameraTrackingAdmission, acknowledgment: CameraBindingAcknowledgment?,
    body: LiveBodyInputState) -> PreparedWristFrame? {
    guard pose.matchesSource, Set(pose.frame.candidates.map(\.candidateID)).count == pose.frame.candidates.count,
      admission.acceptedBodyRevision == body.acceptedRevision,
      pose.frame.candidates.count <= PoseEstimator.maximumCandidates,
      let association, let source = association.source, let ack = acknowledgment,
      let request = admission.requestID, request == ack.requestID,
      admission.context == pose.source.context, body.source == pose.source.context,
      source.context.generation == pose.source.context.generation,
      source.context.epoch == pose.source.context.epoch,
      source.context.geometryRevision == pose.source.context.geometryRevision,
      source.context.imageWidth == pose.frame.imageWidth, source.context.imageHeight == pose.frame.imageHeight,
      source.context.rotationAngle == pose.source.rotationAngle, source.context.mirrored == pose.source.mirrored,
      ack.source.context == source.context, ack.source.controlRevision == admission.revision,
      source.frameID == pose.source.frameID, source.capturedAt == pose.source.capturedAt,
      source.controlRevision == admission.revision, association.controlRevision == admission.revision,
      let config = body.configuration, !body.stopped else { return nil }
    let reliable = PlayerID.allCases.filter { association[$0].state == .tracking && !association[$0].requiresRebind }
    let ids = reliable.compactMap { association[$0].candidateID }
    guard ids.count == reliable.count, Set(ids).count == ids.count else { return nil }
    var players: [PlayerID: PreparedPlayerWrists] = [:]
    for id in PlayerID.allCases {
      let slot = association[id], calibration = config.calibrations[id], cut = body.cutovers[id]
      let candidate = reliable.contains(id) ? pose.frame.candidates.first { $0.candidateID == slot.candidateID } : nil
      func wrist(_ name: BodyJoint) -> PreparedWristEvidence {
        guard let candidate else { return .init(observed:nil, observationRefusal:.identityUnavailable,
          playerPlane:nil, contactRefusal:.identityUnavailable) }
        guard let joint = candidate.joints[name] else { return .init(observed:nil,
          observationRefusal:.missingJoint, playerPlane:nil, contactRefusal:.missingJoint) }
        func refused(_ reason: WristEvidenceRefusal, observation: Bool = false) -> PreparedWristEvidence {
          .init(observed:joint, observationRefusal:observation ? reason : nil, playerPlane:nil, contactRefusal:reason)
        }
        guard (try? joint.validate()) != nil else { return refused(.invalidCoordinate, observation:true) }
        guard joint.confidence >= 0.5 else { return refused(.lowConfidence, observation:true) }
        guard admission.acceptedBodyRevision == body.acceptedRevision else { return refused(.contextChanged) }
        guard let calibration else { return refused(.notCalibrated) }
        guard (try? calibration.validate()) != nil, (try? config.playerPlaneLayout.validate()) != nil,
          calibration.playerID == id, calibration.sessionGeneration == pose.source.context.generation,
          config.sessionGeneration == pose.source.context.generation,
          calibration.cameraGeometryRevision == pose.source.context.geometryRevision,
          abs(calibration.mapping.imageAspectRatio - Double(pose.frame.imageWidth)/Double(pose.frame.imageHeight)) < 0.000001
          else { return refused(.incompatibleCalibration) }
        guard let cut, pose.source.frameID > cut.frameID, pose.source.capturedAt > cut.capturedAt,
          pose.source.frameID > calibration.sourceFrameID, pose.source.capturedAt > calibration.capturedAt
          else { return refused(.beforeCutover) }
        let point = WristPlanePoint(x:calibration.mapping.gameX(imageX:joint.x,playerID:id,layout:config.playerPlaneLayout),
          y:calibration.mapping.gameY(imageY:joint.y,layout:config.playerPlaneLayout))
        guard point.x.isFinite, point.y.isFinite else { return refused(.incompatibleCalibration) }
        return .init(observed:joint,observationRefusal:nil,playerPlane:point,contactRefusal:nil)
      }
      players[id] = .init(playerID:id,tracking:slot,calibrationRevision:calibration?.revision,
        cutover:cut,left:wrist(.leftWrist),right:wrist(.rightWrist))
    }
    return .init(source:pose.source,controlRevision:admission.revision,bindingRequest:request,
      bindingSource:ack.source,acceptedContextRevision:body.acceptedRevision,players:players)
  }
}
