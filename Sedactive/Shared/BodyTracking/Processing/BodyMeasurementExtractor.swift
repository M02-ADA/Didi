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
    // Live head-top and soles (policy V2, 11 November 2026): this frame's nose and ankles plus the
    // offsets measured on THIS player at their accepted standing calibration (TEAM_ALIGNMENT §C:
    // "estimates built from landmarks plus each player's standing calibration"). Only from a
    // calibration accepted from live standing evidence (recorded provenance); a calibration with
    // no recorded provenance still yields none. A landmark below confidence yields UNAVAILABLE.
    guard calibration.referenceQuality != nil else {
      let anatomy = unavailable(.missingLandmarks)
      return .init(playerID: id, calibrationRevision: calibration.revision, trackingStatus: status,
        geometry: .init(crownY: anatomy, leftWristY: wrist(.leftWrist), rightWristY: wrist(.rightWrist),
          leftSoleY: anatomy, rightSoleY: anatomy, centerX: center),
        jumpState: JumpDetector.unavailable(.missingLandmarks))
    }
    let height = calibration.standingBodyImageHeight
    func offset(_ joint: BodyJoint, by share: Double) -> EstimatedScalar {
      guard let p = candidate.joints[joint] else { return unavailable(.missingLandmarks) }
      guard p.confidence >= 0.5 else { return unavailable(.lowConfidence) }
      return scalar(calibration.mapping.gameY(imageY: p.y + share * height, layout: layout))
    }
    return .init(playerID: id, calibrationRevision: calibration.revision, trackingStatus: status,
      geometry: .init(crownY: offset(.nose, by: calibration.headOffsetFromNoseShare),
        leftWristY: wrist(.leftWrist), rightWristY: wrist(.rightWrist),
        leftSoleY: offset(.leftAnkle, by: -calibration.leftFootOffsetShare),
        rightSoleY: offset(.rightAnkle, by: -calibration.rightFootOffsetShare), centerX: center),
      jumpState: JumpDetector.unavailable(.missingLandmarks)) // the stateful estimator fills this in
  }

  /// POSE-FIRST CANDIDATE (Kevin, 14 Nov 2026 — needs Edo's review; DEBUG only, see
  /// `PoseFirstCandidate`). Today's sample, plus:
  /// - a player held only by squat presence is measured from the partial body Vision saw
  ///   (`slot.presentCandidateID`): each landmark on its own, missing ones stay missing;
  /// - the crown is the higher of the nose estimate and the shoulder estimate (`HeadHeightReference`),
  ///   so a head bow cannot lower it; the reference learns only from reliably tracked frames.
  static func candidateSample(id: PlayerID, candidates: [PoseCandidate], slot: PlayerTrackingSlotResult,
    calibration: PlayerCalibration?, layout: PlayerPlaneLayout, head: inout HeadHeightReference) -> PlayerBodySample {
    let reliable = slot.state == .tracking && !slot.requiresRebind
    let presence = !reliable && slot.state == .uncertain && !slot.requiresRebind ? slot.presentCandidateID : nil
    let id_ = reliable ? slot.candidateID : presence
    let candidate = id_.flatMap { cid in candidates.first { $0.candidateID == cid } }
    // Measure as a tracked player would be (reliable or presence-held), then mark the provenance.
    let measuring = (reliable || presence != nil) && candidate != nil
    let base = sample(id: id, candidate: candidate, slot: measuring ? PlayerTrackingSlotResult(state: .tracking,
      reason: slot.reason, candidateID: candidate?.candidateID, cost: slot.cost, requiresRebind: false,
      lastConfirmedAt: slot.lastConfirmedAt) : slot, calibration: calibration, layout: layout)
    guard measuring, let candidate, let calibration, calibration.referenceQuality != nil else {
      return reliable || !measuring ? base : sample(id: id, candidate: nil, slot: slot, calibration: calibration, layout: layout)
    }
    func y(_ joint: BodyJoint) -> Double? {
      guard let p = candidate.joints[joint], p.confidence >= 0.5 else { return nil }
      return calibration.mapping.gameY(imageY: p.y, layout: layout)
    }
    let shoulders = y(.leftShoulder).flatMap { l in y(.rightShoulder).map { (l + $0) / 2 } }
    let noseToCrown = calibration.headOffsetFromNoseShare * calibration.standingBodyImageHeight * layout.gameUnitsPerImageHeight
    // Learn the upright shoulder-to-nose height only from reliably tracked frames.
    if reliable, let nose = y(.nose), let shoulders { head.observe(noseY: nose, shoulderY: shoulders) }
    let crownValue = head.crown(noseCrown: base.geometry.crownY.validity == .valid ? base.geometry.crownY.value : nil,
                                shoulderY: shoulders, noseToCrown: noseToCrown)
    let crown = crownValue.map { scalar($0) } ?? base.geometry.crownY
    let g = base.geometry
    var value = PlayerBodySample(playerID: id, calibrationRevision: base.calibrationRevision,
      trackingStatus: reliable ? .reliable : .uncertain,
      geometry: .init(crownY: crown, leftWristY: g.leftWristY, rightWristY: g.rightWristY,
        leftSoleY: g.leftSoleY, rightSoleY: g.rightSoleY, centerX: g.centerX),
      jumpState: base.jumpState)
    if !reliable { value.presenceOnly = true }
    return value
  }

  /// The player's hips in game units this frame (for the airborne estimator), or nil.
  static func hipGameY(candidate: PoseCandidate?, calibration: PlayerCalibration, layout: PlayerPlaneLayout) -> Double? {
    guard let l = candidate?.joints[.leftHip], let r = candidate?.joints[.rightHip],
      l.confidence >= 0.5, r.confidence >= 0.5 else { return nil }
    return calibration.mapping.gameY(imageY: (l.y + r.y) / 2, layout: layout)
  }
}
