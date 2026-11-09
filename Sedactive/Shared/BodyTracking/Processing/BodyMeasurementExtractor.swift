import Foundation

/// E06 numeric extraction. No mask-extrema-as-anatomy, fixed offsets, game rules or clock.
nonisolated enum BodyMeasurementExtractor {
  static func experimentalAnatomy(source: CameraFrameMetadata, controlRevision: UInt64,
    candidate: PoseCandidate, region: PersonMaskRegion, width: Int, height: Int,
    labelAt: (Int, Int) -> UInt8) -> AnatomicalPlayerCandidate {
    AnatomicalCandidateExtractor.extract(source: source, controlRevision: controlRevision,
      candidate: candidate, region: region, width: width, height: height, labelAt: labelAt)
  }
  static func unavailable(_ reason: EvidenceValidity) -> EstimatedScalar {
    // The constructor's invariant is structural and independent of input.
    try! EstimatedScalar(value: nil, validity: reason)
  }
  static func scalar(_ value: Double) -> EstimatedScalar {
    guard value.isFinite else { return unavailable(.missingLandmarks) }
    return try! EstimatedScalar(value: value, validity: .valid)
  }
  static func sample(id: PlayerID, candidate: PoseCandidate?, slot: PlayerTrackingSlotResult,
    calibration: PlayerCalibration?, layout: PlayerPlaneLayout) -> PlayerBodySample {
    let reliable = slot.state == .tracking && !slot.requiresRebind
    let status: TrackingStatus = reliable ? .reliable : (slot.state == .lost ? .lost : .uncertain)
    let invalid: EvidenceValidity = !reliable ? .identityUncertain : .notCalibrated
    let empty = unavailable(invalid)
    guard reliable, let candidate, let calibration else {
      return .init(playerID: id, calibrationRevision: calibration?.revision, trackingStatus: status,
        geometry: .init(crownY: empty, leftWristY: empty, rightWristY: empty,
          leftSoleY: empty, rightSoleY: empty, centerX: empty),
        jumpState: JumpDetector.unavailable(invalid))
    }
    func wrist(_ joint: BodyJoint) -> EstimatedScalar {
      guard let p = candidate.joints[joint] else { return unavailable(.missingLandmarks) }
      guard p.confidence >= 0.5 else { return unavailable(.lowConfidence) }
      return scalar(calibration.mapping.gameY(imageY: p.y, layout: layout))
    }
    let hips = [candidate.joints[.leftHip], candidate.joints[.rightHip]]
    let center: EstimatedScalar
    if let left = hips[0], let right = hips[1], left.confidence >= 0.5, right.confidence >= 0.5 {
      center = scalar(calibration.mapping.gameX(imageX: (left.x + right.x) / 2, playerID: id, layout: layout))
    } else { center = unavailable(.missingLandmarks) }
    // Standing offsets alone do not validate live anatomical support across crouch/occlusion.
    // Keep the CP1 requirements intact; no nose-only crown or ankle-only sole fallback.
    let anatomy = unavailable(.missingLandmarks)
    return .init(playerID: id, calibrationRevision: calibration.revision, trackingStatus: status,
      geometry: .init(crownY: anatomy, leftWristY: wrist(.leftWrist), rightWristY: wrist(.rightWrist),
        leftSoleY: anatomy, rightSoleY: anatomy, centerX: center),
      jumpState: JumpDetector.unavailable(.missingLandmarks))
  }
}
