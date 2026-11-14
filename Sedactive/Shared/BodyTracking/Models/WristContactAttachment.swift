import Foundation

/// Numeric measurement only. No zone, entry transition, game time or contact verdict.
nonisolated struct WristContactObservationV1: Equatable, Sendable, Codable {
  let observed: PoseJoint?
  let observationRefusal: WristEvidenceRefusal?
  let playerPlane: WristPlanePoint?
  let contactRefusal: WristEvidenceRefusal?

  func validate() throws {
    try requireBodyValue((playerPlane != nil) == (contactRefusal == nil), "wrist XY/refusal")
    if let observed {
      try requireBodyValue([observed.x,observed.y,observed.confidence].allSatisfy(\.isFinite), "finite observed wrist")
      if observationRefusal == nil { try observed.validate() }
    }
    if let point = playerPlane {
      try requireBodyValue(point.x.isFinite && point.y.isFinite && observationRefusal == nil
        && observed != nil && observed!.confidence >= 0.5, "eligible wrist")
    }
    if observed == nil { try requireBodyValue(observationRefusal != nil, "missing wrist reason") }
    if observationRefusal != nil { try requireBodyValue(playerPlane == nil, "invalid observed wrist") }
  }
}
nonisolated struct PlayerWristContactV1: Equatable, Sendable, Codable {
  let playerID: PlayerID
  let trackingStatus: TrackingStatus
  let requiresRebind: Bool
  let candidateID: UInt64? // frame-local diagnostic provenance, NEVER a persistent player identity
  let calibrationRevision: UInt64?
  let cutover: BodyInputCutover?
  let left: WristContactObservationV1
  let right: WristContactObservationV1
}
nonisolated struct WristContactAttachmentV1: Equatable, Sendable, Codable {
  // Generation/geometry come from BodySnapshot. Original frame/time are repeated only to
  // reject accidental attachment reuse on a different snapshot; epoch is absent from CP1.
  let sourceEpoch: UUID
  let sourceFrameID: UInt64
  let sourceCapturedAt: Double
  let controlRevision: UInt64
  let bindingRequestID: UUID
  let bindingFrameID: UInt64
  let bindingCapturedAt: Double
  let acceptedContextRevision: UInt64
  let players: [PlayerID: PlayerWristContactV1]

  func validate(matching snapshot: BodySnapshot) throws {
    try requireBodyValue(sourceFrameID == snapshot.frameID && sourceCapturedAt == snapshot.capturedAt,
      "wrist source frame/time")
    try requireBodyValue(controlRevision > 0 && sourceCapturedAt.isFinite && sourceCapturedAt >= 0
      && bindingCapturedAt.isFinite && bindingCapturedAt >= 0
      && bindingFrameID <= sourceFrameID && bindingCapturedAt <= sourceCapturedAt, "wrist binding provenance")
    try requireBodyValue(Set(players.keys) == Set(PlayerID.allCases), "two wrist slots")
    let ids = players.values.filter { $0.trackingStatus == .reliable && !$0.requiresRebind }.compactMap(\.candidateID)
    try requireBodyValue(Set(ids).count == ids.count, "distinct wrist associations")
    for (id,p) in players {
      guard let sample = snapshot.players[id] else { throw BodyInputContractError.incompatibleContext }
      try requireBodyValue(p.playerID == id && p.trackingStatus == sample.trackingStatus, "wrist player status")
      try p.left.validate(); try p.right.validate()
      // A refused before-cutover measurement may retain diagnostic calibration metadata;
      // only eligible XY must match the enclosing authoritative sample's baseline.
      if p.left.playerPlane != nil || p.right.playerPlane != nil {
        try requireBodyValue(p.trackingStatus == .reliable && !p.requiresRebind && p.candidateID != nil
          && p.calibrationRevision != nil && p.calibrationRevision == sample.calibrationRevision,
          "eligible wrist association/calibration")
        guard let cut = p.cutover else { throw BodyInputContractError.incompatibleContext }
        try requireBodyValue(cut.capturedAt.isFinite && sourceFrameID > cut.frameID
          && sourceCapturedAt > cut.capturedAt, "wrist cutover")
      }
    }
  }
}

/// Current gate-owned authority, reread after suspension and before every domain progression.
/// Not a second calibration store. Freshness is the unchanged live tracker policy.
nonisolated struct WristContactContextV1: Equatable, Sendable {
  let sourceEpoch: UUID
  let controlRevision: UInt64
  let bindingRequestID: UUID
  let bindingFrameID: UInt64
  let bindingCapturedAt: Double
  let acceptedContextRevision: UInt64
  let freshness: Double
}
extension BodyInputContext {
  /// `after*` are mandatory domain activation/resume or last-processed capture watermarks.
  /// Time is capture/host clock, NOT GameClock. This checks measurement eligibility, not entry.
  nonisolated func acceptsWristContact(_ snapshot: BodySnapshot, playerID: PlayerID,
    at time: Double, afterFrameID: UInt64, afterCapturedAt: Double) -> Bool {
    guard isActive, (try? snapshot.validate()) != nil, accepts(snapshot,playerID:playerID),
      let current = wristContact, let value = snapshot.wristContact, let p = value.players[playerID],
      current.sourceEpoch == value.sourceEpoch, current.controlRevision == value.controlRevision,
      current.bindingRequestID == value.bindingRequestID, current.bindingFrameID == value.bindingFrameID,
      current.bindingCapturedAt == value.bindingCapturedAt,
      current.acceptedContextRevision == value.acceptedContextRevision,
      time.isFinite, current.freshness.isFinite, current.freshness > 0,
      time >= snapshot.capturedAt, time - snapshot.capturedAt < current.freshness,
      afterCapturedAt.isFinite, snapshot.frameID > afterFrameID, snapshot.capturedAt > afterCapturedAt,
      p.trackingStatus == .reliable, !p.requiresRebind, p.calibrationRevision != nil,
      p.calibrationRevision == calibrationRevisions[playerID], p.cutover == cutovers[playerID],
      p.left.playerPlane != nil || p.right.playerPlane != nil else { return false }
    return true // inspect each wrist's optional XY/refusal independently
  }
}
extension PreparedWristFrame {
  nonisolated func attachment(matching snapshot: BodySnapshot) -> WristContactAttachmentV1? {
    guard source.context.generation == snapshot.sessionGeneration,
      source.context.geometryRevision == snapshot.cameraGeometryRevision,
      source.frameID == snapshot.frameID, source.capturedAt == snapshot.capturedAt else { return nil }
    func wrist(_ v: PreparedWristEvidence) -> WristContactObservationV1 {
      .init(observed:v.observed,observationRefusal:v.observationRefusal,
        playerPlane:v.playerPlane,contactRefusal:v.contactRefusal)
    }
    let value = WristContactAttachmentV1(sourceEpoch:source.context.epoch,sourceFrameID:source.frameID,
      sourceCapturedAt:source.capturedAt,controlRevision:controlRevision,bindingRequestID:bindingRequest,
      bindingFrameID:bindingSource.frameID,bindingCapturedAt:bindingSource.capturedAt,
      acceptedContextRevision:acceptedContextRevision,players:players.mapValues { p in
        let status: TrackingStatus = p.tracking.state == .tracking && !p.tracking.requiresRebind ? .reliable
          : p.tracking.state == .lost ? .lost : .uncertain
        return .init(playerID:p.playerID,trackingStatus:status,requiresRebind:p.tracking.requiresRebind,
          candidateID:p.tracking.candidateID,calibrationRevision:p.calibrationRevision,cutover:p.cutover,
          left:wrist(p.left),right:wrist(p.right))
      })
    return (try? value.validate(matching:snapshot)) != nil ? value : nil
  }
}
