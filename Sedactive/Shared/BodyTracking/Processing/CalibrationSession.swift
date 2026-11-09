import Foundation

nonisolated enum LiveVisionError: Error, Equatable {
  case inactiveSource, invalidRequest, staleEvidence, contextConflict, unsupportedAnatomy
  case invalidConfiguration, revisionExhausted
}
/// Sprint collection limits, not measured production thresholds or B2 policy changes.
nonisolated enum StandingCollectionPolicyV1 {
  static let version = "StandingCollectionPolicyV1-EXPERIMENTAL"
  static let sampleInterval = 1.0, requestLifetime = 30.0, candidateLifetime = 5.0
  static let serviceTripwire = 0.1, sampleFreshness = 0.5
  static let sampleCount = 10
}
nonisolated struct CalibrationRequest: Equatable, Sendable {
  let id: UUID
  fileprivate let serial: UInt64
}
nonisolated struct CalibrationAdmission: Equatable, Sendable {
  let request: CalibrationRequest
  let source: CameraSourceContext
  let bindingRevision: UInt64
  let bindingRequest: UUID
}
nonisolated enum StandingCalibrationPhase: String, Sendable {
  case idle, collecting, waitingForReliablePair, candidateReady, accepted, cancelled, expired, stoppedForReview
}
nonisolated enum AnatomicalReferenceQuality: String, Sendable {
  case unavailable, experimental, validated
}
/// A reference must come from an independently justified producer; a whole-mask extremum,
/// nose or ankle is NOT this evidence. The current collector intentionally never creates one.
nonisolated struct StandingAnatomicalReferences: Equatable, Sendable {
  let crownY: Double, leftSoleY: Double, rightSoleY: Double
  let quality: AnatomicalReferenceQuality
}
nonisolated struct StandingPlayerObservation: Equatable, Sendable {
  let noseY: Double?, leftAnkleY: Double?, rightAnkleY: Double?
  let hipY: Double, torsoLength: Double, originX: Double
  let maskMinY: Double, maskMaxY: Double
  let anatomy: StandingAnatomicalReferences?
}
nonisolated struct StandingCalibrationCandidate: Sendable {
  let id: UUID
  let admission: CalibrationAdmission
  let firstFrameID: UInt64, lastFrameID: UInt64
  let firstCapturedAt: Double, lastCapturedAt: Double, expiresAt: Double
  let players: [PlayerID: StandingPlayerObservation]
  let imageWidth: Int, imageHeight: Int
  let rotationAngle: Double
  let mirrored: Bool
  let samples: Int
  var hasValidatedAnatomy: Bool {
    Set(players.keys) == Set(PlayerID.allCases)
      && players.values.allSatisfy { $0.anatomy?.quality == .validated }
  }
}
nonisolated struct StandingCalibrationProgress: Sendable {
  let request: CalibrationRequest?
  let phase: StandingCalibrationPhase
  let sampleCount: Int
  let candidate: StandingCalibrationCandidate?
  let reason: String
}

/// One bounded paired window. No accepted references, raw images or pose history.
/// Observation aggregates describe standing candidates only; stillness/anatomy remain experimental.
nonisolated struct CalibrationSession: Sendable {
  private(set) var admission: CalibrationAdmission?
  private(set) var phase: StandingCalibrationPhase = .idle
  private(set) var candidate: StandingCalibrationCandidate?
  private(set) var count = 0
  private var serial: UInt64 = 0
  private var deadline = 0.0
  private var firstSource: CameraFrameMetadata?
  private var lastAttempt: Double?
  private var lastAttemptHost: Double?
  private var lastFrame: UInt64 = 0
  private var pendingSource: CameraFrameMetadata?
  private var anatomicalSums: [PlayerID: [Double]] = [:]
  private var anatomicalMin: [PlayerID: [Double]] = [:]
  private var anatomicalMax: [PlayerID: [Double]] = [:]
  private var anatomicalCount = 0
  private(set) var latestAnatomy: [PlayerID: AnatomicalPlayerCandidate] = [:]
  private var sums: [PlayerID: [Double]] = [:] // exactly 2 x 9 numeric scalars
  private(set) var reason = "No calibration requested"

  mutating func request(id: UUID, source: CameraSourceContext, revision: UInt64,
    bindingRequest: UUID, at time: Double) throws -> CalibrationRequest {
    if let admission, admission.request.id == id {
      guard phase == .collecting || phase == .waitingForReliablePair || phase == .candidateReady else {
        throw LiveVisionError.invalidRequest
      }
      return admission.request // no deadline extension
    }
    guard serial < .max, time.isFinite else { throw LiveVisionError.revisionExhausted }
    serial += 1
    let token = CalibrationRequest(id: id, serial: serial)
    admission = .init(request: token, source: source, bindingRevision: revision, bindingRequest: bindingRequest)
    deadline = time + StandingCollectionPolicyV1.requestLifetime
    phase = .collecting; candidate = nil; resetWindow()
    lastAttempt = nil; lastAttemptHost = nil
    reason = "Collecting paired observations; anatomical validation required"
    return token
  }
  mutating func invalidate(_ why: String) {
    admission = nil; candidate = nil; phase = .cancelled; resetWindow(); reason = why
  }
  mutating func expire(at time: Double) {
    guard admission != nil else { return }
    if time >= deadline || candidate.map({ time >= $0.expiresAt }) == true {
      invalidate("Calibration expired"); phase = .expired
    }
  }
  mutating func uncertain() {
    guard admission != nil else { return }
    if phase == .candidateReady { invalidate("Candidate withdrawn after tracking uncertainty") }
    else if phase == .collecting || phase == .waitingForReliablePair {
      resetWindow(); phase = .waitingForReliablePair; reason = "Window reset; awaiting reliable pair"
    }
  }
  private mutating func resetWindow() {
    count = 0; sums = [:]; firstSource = nil; lastFrame = 0; pendingSource = nil
    anatomicalSums = [:]; anatomicalMin = [:]; anatomicalMax = [:]; anatomicalCount = 0; latestAnatomy = [:]
  }
  mutating func beginSample(_ stamp: CalibrationAdmission, source: CameraFrameMetadata,
    at time: Double) -> Bool {
    expire(at: time)
    guard pendingSource == nil, admission == stamp, stamp.source == source.context,
      phase == .collecting || phase == .waitingForReliablePair,
      source.frameID > lastFrame, time >= source.capturedAt,
      time - source.capturedAt < StandingCollectionPolicyV1.sampleFreshness,
      lastAttempt.map({ source.capturedAt - $0 >= StandingCollectionPolicyV1.sampleInterval }) ?? true,
      lastAttemptHost.map({ time - $0 >= StandingCollectionPolicyV1.sampleInterval }) ?? true else { return false }
    lastAttempt = source.capturedAt; lastAttemptHost = time; pendingSource = source
    return true
  }
  mutating func observe(_ mask: PersonMaskObservation, pose: CameraPoseResult,
    association: PlayerTrackingSnapshot, stamp: CalibrationAdmission, at time: Double) {
    expire(at: time)
    guard admission == stamp, pendingSource == pose.source, mask.source == pose.source, stamp.source == pose.source.context,
      sourceIsFresh(pose.source, time), pose.source.frameID > lastFrame,
      phase == .collecting || phase == .waitingForReliablePair else { return }
    pendingSource = nil
    guard let original = association.source, original.frameID == pose.source.frameID,
      original.capturedAt == pose.source.capturedAt, original.context.epoch == stamp.source.epoch,
      original.context.generation == stamp.source.generation,
      association.controlRevision == stamp.bindingRevision,
      mask.outputBytes >= 0, mask.outputBytes <= PersonSegmenter.maximumOutputBytes else {
      uncertain(); return
    }
    guard mask.serviceSeconds.isFinite, mask.serviceSeconds >= 0,
      mask.serviceSeconds <= StandingCollectionPolicyV1.serviceTripwire else {
      invalidate("Mask service exceeded experimental budget; STOP/REVIEW"); phase = .stoppedForReview; return
    }
    guard mask.quality == .torsoSupportedGeometryUnverified, mask.regions.count == 2 else {
      uncertain(); return
    }
    var values: [PlayerID: [Double]] = [:]
    for id in PlayerID.allCases {
      guard association[id].state == .tracking, !association[id].requiresRebind,
        let region = mask.regions[id], region.candidateID == association[id].candidateID,
        let c = pose.frame.candidates.first(where: { $0.candidateID == region.candidateID }),
        let ls = c.joints[.leftShoulder], let rs = c.joints[.rightShoulder],
        let lh = c.joints[.leftHip], let rh = c.joints[.rightHip],
        let nose = c.joints[.nose], let la = c.joints[.leftAnkle], let ra = c.joints[.rightAnkle],
        [ls, rs, lh, rh, nose, la, ra].allSatisfy({ $0.confidence >= 0.5 }) else {
        uncertain(); return
      }
      let hip = (lh.y + rh.y) / 2, shoulder = (ls.y + rs.y) / 2
      // Ordering is necessary, not sufficient, for a real standing posture. No invented offsets.
      guard shoulder > hip, nose.y > shoulder, la.y < hip, ra.y < hip else { uncertain(); return }
      values[id] = [nose.y, la.y, ra.y, hip, shoulder - hip,
        (ls.x + rs.x + lh.x + rh.x) / 4, region.minY, region.maxY, 1]
    }
    latestAnatomy = mask.anatomy.filter { id, value in
      value.source == pose.source && value.controlRevision == stamp.bindingRevision
        && value.candidateID == association[id].candidateID
    }
    if latestAnatomy.count == 2, latestAnatomy.values.allSatisfy({ $0.experimentalReferences != nil }) {
      for id in PlayerID.allCases {
        let a = latestAnatomy[id]!.experimentalReferences!
        let v = [a.crownY, a.leftSoleY, a.rightSoleY]
        anatomicalSums[id] = zip(anatomicalSums[id] ?? [0, 0, 0], v).map(+)
        anatomicalMin[id] = zip(anatomicalMin[id] ?? v, v).map { min($0, $1) }
        anatomicalMax[id] = zip(anatomicalMax[id] ?? v, v).map { max($0, $1) }
      }
      anatomicalCount += 1
    }
    firstSource = firstSource ?? pose.source; lastFrame = pose.source.frameID
    for id in PlayerID.allCases {
      let previous = sums[id] ?? Array(repeating: 0.0, count: 9)
      sums[id] = zip(previous, values[id]!).map(+)
    }
    count += 1; phase = .collecting
    if count == StandingCollectionPolicyV1.sampleCount, let firstSource {
      var players: [PlayerID: StandingPlayerObservation] = [:]
      for id in PlayerID.allCases {
        let v = sums[id]!.map { $0 / Double(count) }
        var anatomy: StandingAnatomicalReferences?
        if anatomicalCount == count, let total = anatomicalSums[id],
          let lo = anatomicalMin[id], let hi = anatomicalMax[id],
          zip(lo, hi).allSatisfy({ ($1 - $0) * Double(pose.frame.imageHeight) <= AnatomicalCandidatePolicyV1.standingSpreadPixels }) {
          let mean = total.map { $0 / Double(count) }
          anatomy = .init(crownY: mean[0], leftSoleY: mean[1], rightSoleY: mean[2], quality: .experimental)
        }
        players[id] = .init(noseY: v[0], leftAnkleY: v[1], rightAnkleY: v[2], hipY: v[3],
          torsoLength: v[4], originX: v[5], maskMinY: v[6], maskMaxY: v[7], anatomy: anatomy)
      }
      candidate = .init(id: UUID(), admission: stamp, firstFrameID: firstSource.frameID,
        lastFrameID: pose.source.frameID, firstCapturedAt: firstSource.capturedAt,
        lastCapturedAt: pose.source.capturedAt,
        expiresAt: min(deadline, time + StandingCollectionPolicyV1.candidateLifetime),
        players: players, imageWidth: pose.frame.imageWidth, imageHeight: pose.frame.imageHeight,
        rotationAngle: pose.source.rotationAngle, mirrored: pose.source.mirrored, samples: count)
      phase = .candidateReady; reason = "Unaccepted paired candidate; any silhouette estimates are EXPERIMENTAL, never authoritative"
    }
  }
  private func sourceIsFresh(_ source: CameraFrameMetadata, _ time: Double) -> Bool {
    time.isFinite && time >= source.capturedAt
      && time - source.capturedAt < StandingCollectionPolicyV1.sampleFreshness
  }
  var nextDeadline: Double? {
    guard admission != nil else { return nil }
    return candidate.map { min(deadline, $0.expiresAt) } ?? deadline
  }
  mutating func stopForReview(_ stamp: CalibrationAdmission) {
    guard admission == stamp else { return }
    invalidate("Mask service exceeded experimental budget; STOP/REVIEW"); phase = .stoppedForReview
  }
  mutating func consumed() { candidate = nil; admission = nil; phase = .accepted; reason = "Accepted by live provider" }
  var progress: StandingCalibrationProgress {
    .init(request: admission?.request, phase: phase, sampleCount: count, candidate: candidate, reason: reason)
  }
}
