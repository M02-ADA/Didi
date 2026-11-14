import Foundation

nonisolated struct LivePlayerMeasurement: Sendable {
  let playerID: PlayerID
  let candidateID: UInt64?
  let confirmedAssociation: Bool
  let calibrationRevision: UInt64?
  let observedLeftAnkleY: Double?, observedRightAnkleY: Double?, observedHipY: Double?
  let anatomy: AnatomicalPlayerCandidate
  let temporal: ExperimentalAirborneResult
}
nonisolated struct LiveMeasurementSnapshot: Sendable {
  let source: CameraFrameMetadata
  let controlRevision: UInt64
  let acceptedContextRevision: UInt64
  let samples: UInt64
  /// Adjacent admitted capture spacing, not a throughput distribution or a timer frequency.
  let captureInterval: Double?
  let maskRequests: UInt64
  let maskRequestCaptureInterval: Double?
  let maskCompletions: UInt64
  let maskCaptureInterval: Double?
  let lastMaskSource: CameraFrameMetadata?
  let lastMaskQuality: PersonMaskQuality?
  let lastMaskServiceSeconds: Double?
  let lastMaskAnatomy: [PlayerID: AnatomicalPlayerCandidate]
  let players: [PlayerID: LivePlayerMeasurement]
}

/// Existing worker -> existing source gate -> bounded numeric experiment state. Never CP1 authority.
/// The gate validates the original receipt and commits this value; no image or extra request here.
nonisolated struct LiveMeasurementFlow: Sendable {
  private var lastSource: CameraFrameMetadata?
  private var control: UInt64?
  private var contextRevision: UInt64?
  private var samples: UInt64 = 0
  private var maskRequests: UInt64 = 0
  private var requestInterval: Double?
  private var lastMaskRequest: CameraFrameMetadata?
  private var maskCompletions: UInt64 = 0
  private var lastMask: PersonMaskObservation?
  private var maskInterval: Double?
  private var detectors: [PlayerID: ExperimentalJumpDetector] = [:]
  private(set) var latest: LiveMeasurementSnapshot?
  mutating func invalidate() { self = Self() }

  mutating func noteMaskRequest(_ source: CameraFrameMetadata) {
    requestInterval = lastMaskRequest.flatMap {
      $0.context == source.context && source.capturedAt > $0.capturedAt ? source.capturedAt - $0.capturedAt : nil
    }
    lastMaskRequest = source
    if maskRequests < .max { maskRequests += 1 }
  }
  mutating func process(pose: CameraPoseResult, association: PlayerTrackingSnapshot?,
    controlRevision: UInt64, acceptedContextRevision: UInt64,
    calibrations: [PlayerID: PlayerCalibration], mask: PersonMaskObservation?,
    references: [PlayerID: ExperimentalStandingSurface] = [:], stationaryCameraEvidence: Bool = false) {
    let source = pose.source
    guard pose.matchesSource, (try? pose.frame.validate()) != nil else { invalidate(); return }
    if let previous = lastSource,
      previous.context != source.context || previous.descriptor != source.descriptor
        || previous.rotationAngle != source.rotationAngle || previous.mirrored != source.mirrored || control != controlRevision || contextRevision != acceptedContextRevision {
      invalidate()
    }
    guard lastSource.map({ source.frameID > $0.frameID && source.capturedAt > $0.capturedAt }) ?? true else {
      // Refused ordering cannot seed a later temporal run, even though the source gate also checks it.
      detectors = [:]; latest = nil; return
    }
    let interval = lastSource.map { source.capturedAt - $0.capturedAt }
    lastSource = source; control = controlRevision; contextRevision = acceptedContextRevision
    if samples < .max { samples += 1 }
    var sameFrameMask: PersonMaskObservation?
    if let mask, mask.source == source {
      maskInterval = lastMask.map { source.capturedAt - $0.source.capturedAt }
      lastMask = mask; sameFrameMask = mask
      if maskCompletions < .max { maskCompletions += 1 }
    }
    let exact = association?.source
    let associated = exact.map {
      $0.frameID == source.frameID && $0.capturedAt == source.capturedAt
        && $0.context.generation == source.context.generation && $0.context.epoch == source.context.epoch
        && $0.context.geometryRevision == source.context.geometryRevision
        && $0.context.imageWidth == source.descriptor.width && $0.context.imageHeight == source.descriptor.height
        && $0.context.rotationAngle == source.rotationAngle && $0.context.mirrored == source.mirrored
        && $0.controlRevision == controlRevision && association?.controlRevision == controlRevision
    } ?? false
    let ids = PlayerID.allCases.compactMap { association?[$0].candidateID }
    let injective = ids.count == Set(ids).count
    var players: [PlayerID: LivePlayerMeasurement] = [:]
    for id in PlayerID.allCases {
      let slot = association?[id]
      let reliable = associated && injective && slot?.state == .tracking && slot?.requiresRebind == false
        && slot?.candidateID != nil && pose.frame.candidates.contains(where: { $0.candidateID == slot?.candidateID })
      let candidate = reliable ? pose.frame.candidates.first { $0.candidateID == slot?.candidateID } : nil
      func joint(_ name: BodyJoint) -> Double? {
        guard let p = candidate?.joints[name], (try? p.validate()) != nil, p.confidence >= 0.5 else { return nil }
        return p.y
      }
      let lh = joint(.leftHip), rh = joint(.rightHip)
      let hip = lh.flatMap { l in rh.map { (l + $0) / 2 } }
      let missing = AnatomicalCandidateScalar.refused(reliable ? .missingLandmarks : .ambiguous)
      let empty = AnatomicalPlayerCandidate(source: source, controlRevision: controlRevision,
        candidateID: candidate?.candidateID ?? 0, crown: missing, leftSole: missing, rightSole: missing)
      let raw = sameFrameMask?.anatomy[id]
      let anatomy = reliable && raw?.source == source && raw?.controlRevision == controlRevision
        && raw?.candidateID == candidate?.candidateID ? raw! : empty
      var detector = detectors[id] ?? ExperimentalJumpDetector()
      // An accepted revision alone is not a source of uncertainty or ground-contact evidence.
      // E05 must supply a compatible reference, including measured uncertainty, before using one.
      let reference = references[id].flatMap { value -> ExperimentalStandingSurface? in
        guard let calibration = calibrations[id], calibration.playerID == id,
          calibration.sessionGeneration == source.context.generation,
          calibration.cameraGeometryRevision == source.context.geometryRevision,
          calibration.sourceFrameID < source.frameID, calibration.capturedAt < source.capturedAt,
          calibration.revision == value.calibrationRevision else { return nil }
        return value
      }
      let result = detector.processLive(anatomy, hipY: hip, reference: reference, playerID: id,
        confirmedAssociation: reliable, cameraStationaryEvidence: stationaryCameraEvidence)
      detectors[id] = detector
      players[id] = .init(playerID: id, candidateID: candidate?.candidateID,
        confirmedAssociation: reliable, calibrationRevision: calibrations[id]?.revision,
        observedLeftAnkleY: joint(.leftAnkle), observedRightAnkleY: joint(.rightAnkle),
        observedHipY: hip, anatomy: anatomy, temporal: result)
    }
    latest = .init(source: source, controlRevision: controlRevision,
      acceptedContextRevision: acceptedContextRevision, samples: samples, captureInterval: interval,
      maskRequests: maskRequests, maskRequestCaptureInterval: requestInterval,
      maskCompletions: maskCompletions, maskCaptureInterval: maskInterval, lastMaskSource: lastMask?.source,
      lastMaskQuality: lastMask?.quality, lastMaskServiceSeconds: lastMask?.serviceSeconds,
      lastMaskAnatomy: lastMask?.anatomy ?? [:], players: players)
  }
}
