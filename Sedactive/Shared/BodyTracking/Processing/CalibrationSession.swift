import Foundation

nonisolated enum LiveVisionError: Error, Equatable {
  case inactiveSource, invalidRequest, staleEvidence, contextConflict, unsupportedAnatomy
  case invalidConfiguration, revisionExhausted
}
/// Sprint collection limits, not measured production thresholds or B2 policy changes.
nonisolated enum StandingCollectionPolicyV1 {
  static let version = "StandingCollectionPolicyV1.1-EXPERIMENTAL"
  /// Seconds between samples. Was 1.0 (10 samples took ≥ 10 s, the main setup delay). Each
  /// sample still needs its own fresh frame, pose, association and person mask.
  static let sampleInterval = 0.25, requestLifetime = 30.0, candidateLifetime = 5.0
  /// A player's 10 stable samples must lie within this much capture time (standing STILL).
  static let maximumWindowSpan = 10.0
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
  /// The players this request measures: both, or P1 alone in a DEBUG Solo Test session.
  var roster: [PlayerID] = PlayerID.allCases
}
nonisolated enum StandingCalibrationPhase: String, Sendable {
  case idle, collecting, waitingForReliablePair, candidateReady, accepted, cancelled, expired, stoppedForReview
}
nonisolated enum AnatomicalReferenceQuality: String, Sendable, Codable {
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
    Set(players.keys) == Set(admission.roster)
      && players.values.allSatisfy { $0.anatomy?.quality == .validated }
  }
  /// Whether this candidate may become the accepted standing reference, and on what basis.
  /// It never changes the references' own quality: stable estimates stay `.experimental`.
  var acceptance: StandingCandidateAcceptance {
    if hasValidatedAnatomy { return .validated }
    guard Set(players.keys) == Set(admission.roster), samples == StandingCollectionPolicyV1.sampleCount,
      !mirrored, rotationAngle == 0 || rotationAngle == 180 else {
      return .refused("Standing collection was incomplete. Collect a fresh calibration.")
    }
    for id in admission.roster {
      if let reason = StandingEstimateAcceptancePolicyV1.refusal(players[id]!, player: id) { return .refused(reason) }
    }
    return .stableEstimate
  }
}

nonisolated enum StandingCandidateAcceptance: Equatable, Sendable {
  /// Independently validated head-top and sole references (no producer creates these yet).
  case validated
  /// Mask-derived head-top/sole estimates that passed `StandingEstimateAcceptancePolicyV1`.
  /// Accepted as estimates (TEAM_ALIGNMENT §C); their quality stays `.experimental`.
  case stableEstimate
  case refused(String)
  var isAcceptable: Bool { if case .refused = self { false } else { true } }
}

/// Owner-approved (11 November 2026) acceptance of stable mask-derived estimates.
///
/// What it relies on, all checked before a candidate exists:
/// - genuine B2 pair association, fresh per-player tracking and no rebind in every sample
///   (`CalibrationSession.observe` resets the window otherwise);
/// - shoulders, hips, nose and both ankles at confidence 0.5 or more in every sample;
/// - an `AnatomicalCandidateExtractor` head-top and both soles in EVERY one of the 10
///   samples: a missing, cropped (truncated), occluded or ambiguous reading in any sample
///   leaves the player's references nil;
/// - each reference's spread across the 10 samples within the existing 3 px candidate
///   (`AnatomicalCandidatePolicyV1.standingSpreadPixels`), a stability check, NOT proof of
///   physical accuracy.
///
/// What this adds: the averaged estimates must agree with the averaged pose landmarks
/// (head-top above the nose, each sole at or below its own ankle, hips between). Each
/// player is checked on its own observations only; no value is copied, defaulted or invented.
nonisolated enum StandingEstimateAcceptancePolicyV1 {
  static let version = "StandingEstimateAcceptancePolicyV1"
  /// The refusals below are written for the players; producer errors are not.
  static func isPlayerFacing(_ reason: String) -> Bool {
    reason.hasPrefix("P1's") || reason.hasPrefix("P2's") || reason.hasPrefix("Standing collection")
  }
  static func refusal(_ p: StandingPlayerObservation, player: PlayerID) -> String? {
    let name = player == .player1 ? "P1" : "P2"
    guard let a = p.anatomy else {
      return "\(name)'s head or feet were not seen clearly in every sample (missing, cut off, hidden or moving). Stand fully in view, feet apart, and collect again."
    }
    guard a.quality == .experimental || a.quality == .validated,
      [a.crownY, a.leftSoleY, a.rightSoleY, p.hipY].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
      return "\(name)'s head and foot estimates are unavailable. Collect again."
    }
    guard let nose = p.noseY, let leftAnkle = p.leftAnkleY, let rightAnkle = p.rightAnkleY,
      a.crownY > nose, a.leftSoleY <= leftAnkle, a.rightSoleY <= rightAnkle,
      a.crownY > p.hipY, p.hipY > max(a.leftSoleY, a.rightSoleY) else {
      return "\(name)'s head and foot estimates disagree with the body landmarks. Stand upright, fully in view, and collect again."
    }
    // Policy V2: the AVERAGED references must be anatomically plausible too (scale-free shares of
    // the head-top-to-ankle span), so a stable but wrong estimate is never accepted.
    let span = a.crownY - min(leftAnkle, rightAnkle)
    let crownShare = (a.crownY - nose) / span
    guard span > 0, crownShare >= AnatomicalCandidatePolicyV1.minimumCrownAboveNoseShare,
      crownShare <= AnatomicalCandidatePolicyV1.maximumCrownAboveNoseShare else {
      return "\(name)'s head or foot estimates are not in human proportion. Stand upright, hands down, feet flat, and collect again."
    }
    return nil
  }
}
nonisolated struct StandingCalibrationProgress: Sendable {
  let request: CalibrationRequest?
  let phase: StandingCalibrationPhase
  let sampleCount: Int
  let candidate: StandingCalibrationCandidate?
  let reason: String
  /// Per-player window progress and refusal reasons (presentation and diagnostics only).
  var players: [PlayerID: StandingPlayerProgress] = [:]
}

/// One bounded paired window. No accepted references, raw images or pose history.
/// Observation aggregates describe standing candidates only; stillness/anatomy remain experimental.
/// Why one player's sample did not join their standing window. Player-facing hints map from these.
nonisolated enum StandingSampleIssue: String, Sendable, CaseIterable {
  /// The mask could not separate this player (overlap, or only one person in view).
  case notSeparated
  /// Pair association is not currently tracking this player: their window restarts.
  case trackingLost
  /// Shoulders or hips missing or below confidence.
  case bodyNotFullyVisible
  /// Nose, eyes or ears missing or below confidence, or the head turned away.
  case faceNotVisible
  /// Ankles missing or below confidence.
  case feetNotVisible
  /// Landmarks are not in standing order (crouching, leaning, lying).
  case notUpright
  /// The head touches the image edge.
  case headCutOff
  /// A foot touches the image edge.
  case feetCutOff
  /// The head-top is too high for a head: hands or an object above it.
  case headObstructed
  /// The head outline is cut short or does not rise above the eyes (lighting, background).
  case headUnclear
  /// The feet are too close together, or merged, to measure each sole on its own.
  case feetTogether
  /// Legs crossed, or a foot's landmarks do not lie on the player's own outline.
  case feetUnclear
  /// Outside the stability tolerance: the sample was skipped, or the window restarted after a move.
  case moving
  /// Face or ankles not found while the player fills under 40 % of the frame height
  /// (iPad, 11 November 2026: at ~30 % ankle confidence measured 0.2–0.5).
  case tooFar

  /// Below this share of the frame height, missing face/ankles are reported as "too far".
  static let tooFarHeightShare = 0.4

  /// The player-facing reason for one estimator refusal.
  init(_ detail: AnatomicalRefusalDetail) {
    switch detail {
    case .incompatibleSource, .headOffMask: self = .bodyNotFullyVisible
    case .headLandmarksMissing, .headLowConfidence, .headTurned: self = .faceNotVisible
    case .headTopUneven, .headCorridorBlocked, .headTopTooHigh: self = .headObstructed
    case .headTopUnclear, .headTopTooLow: self = .headUnclear
    case .headCutOff: self = .headCutOff
    case .anklesMissing, .anklesLowConfidence: self = .feetNotVisible
    case .feetTooClose, .feetJoined: self = .feetTogether
    case .legsCrossed, .ankleOffMask, .soleNotBelowAnkle, .soleImplausible: self = .feetUnclear
    case .feetCutOff: self = .feetCutOff
    }
  }
}

#if DEBUG
/// One player's latest sample, as measured (setup diagnostics only; no image data).
nonisolated struct StandingSampleDiagnostics: Equatable, Sendable {
  var frameID: UInt64 = 0
  var capturedAt: Double = 0
  /// Joint confidences, 0 when not observed.
  var confidence: [BodyJoint: Double] = [:]
  var crown: AnatomicalRefusalDetail?
  var soles: AnatomicalRefusalDetail?
  var crownSeen = false, solesSeen = false
  /// Horizontal ankle separation in image pixels, and as a share of the body's pixel height.
  var ankleSeparationPixels: Double?
  var ankleSeparationShare: Double?
  var bodyHeightPixels: Double?
  var resets = 0
  /// The mask for this sample: quality, how many players it separated, Vision's body count.
  var maskQuality = "-"
  var maskRegions = 0
  var visionBodies = 0
  var headBeyondEars: Double?, crownAboveEyes: Double?, feetGapFilled: Double?
  var crownAboveNose: Double?, footHeight: Double?
}
#endif

/// One player's collection state, for progress and recovery hints. Not calibration evidence.
nonisolated struct StandingPlayerProgress: Equatable, Sendable {
  /// Consecutive stable samples now in the player's window (0...sampleCount).
  var samples = 0
  var accepted = 0
  var rejected: [StandingSampleIssue: Int] = [:]
  var latestIssue: StandingSampleIssue?
  #if DEBUG
  /// Largest head-top/sole spread across the current window, in image pixels (diagnostic).
  var spreadPixels: Double = 0
  /// Head-top, left and right sole range in pixels, window plus the newest sample (diagnostic).
  var moveRangePixels: [Double] = []
  var maskRows: Int?
  var last = StandingSampleDiagnostics()
  #endif
}

/// One bounded standing window PER PLAYER. No accepted references, raw images or pose history.
///
/// Each sample is checked for each player independently: a rejected or missing reading for one
/// player is skipped without discarding the other player's samples or their own earlier stable
/// samples; only an identity failure (pair association) restarts a window. A candidate exists
/// once BOTH players hold `sampleCount` consecutive stable samples whose head-top and soles agree
/// within the stability tolerance. Stability is not accuracy: references stay `.experimental`.
nonisolated struct CalibrationSession: Sendable {
  private struct PlayerSample: Sendable {
    let source: CameraFrameMetadata
    /// nose, left ankle, right ankle, hip, torso length, origin X, mask min Y, mask max Y
    let values: [Double]
    /// crown, left sole, right sole
    let anatomy: [Double]
    /// Normalized stability tolerance for this sample's mask resolution.
    let tolerance: Double
  }
  private(set) var admission: CalibrationAdmission?
  private(set) var phase: StandingCalibrationPhase = .idle
  private(set) var candidate: StandingCalibrationCandidate?
  /// Samples in the window that is closest to complete (for the pair's progress).
  var count: Int { (admission?.roster ?? PlayerID.allCases).map { windows[$0]?.count ?? 0 }.min() ?? 0 }
  private var serial: UInt64 = 0
  private var deadline = 0.0
  private var lastAttempt: Double?
  private var lastAttemptHost: Double?
  private var lastFrame: UInt64 = 0
  private var pendingSource: CameraFrameMetadata?
  private var windows: [PlayerID: [PlayerSample]] = [:]
  /// The latest skipped out-of-tolerance sample per player (cleared with its window).
  private var outliers: [PlayerID: PlayerSample] = [:]
  private(set) var players: [PlayerID: StandingPlayerProgress] = [:]
  private(set) var latestAnatomy: [PlayerID: AnatomicalPlayerCandidate] = [:]
  private(set) var reason = "No calibration requested"

  /// Drop the entire collection while retaining token anti-replay/exhaustion across sessions.
  mutating func resetForNewSession() {
    let highWater = serial
    self = Self()
    serial = highWater
  }
  mutating func request(id: UUID, source: CameraSourceContext, revision: UInt64,
    bindingRequest: UUID, at time: Double, roster: [PlayerID] = PlayerID.allCases) throws -> CalibrationRequest {
    if let admission, admission.request.id == id {
      guard phase == .collecting || phase == .waitingForReliablePair || phase == .candidateReady else {
        throw LiveVisionError.invalidRequest
      }
      return admission.request // no deadline extension
    }
    guard serial < .max, time.isFinite else { throw LiveVisionError.revisionExhausted }
    serial += 1
    let token = CalibrationRequest(id: id, serial: serial)
    admission = .init(request: token, source: source, bindingRevision: revision, bindingRequest: bindingRequest,
      roster: roster)
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
      let hint = dominantIssue.map { " (\($0.rawValue))" } ?? ""
      invalidate("Calibration expired" + hint); phase = .expired
    }
  }
  /// The most frequent reason samples were refused in this request, if any.
  var dominantIssue: StandingSampleIssue? {
    var totals: [StandingSampleIssue: Int] = [:]
    for value in players.values { totals.merge(value.rejected, uniquingKeysWith: +) }
    return totals.max { $0.value == $1.value ? $0.key.rawValue > $1.key.rawValue : $0.value < $1.value }?.key
  }
  /// Pair-level uncertainty (association/identity): both windows restart.
  mutating func uncertain() {
    guard admission != nil else { return }
    if phase == .candidateReady { invalidate("Candidate withdrawn after tracking uncertainty") }
    else if phase == .collecting || phase == .waitingForReliablePair {
      resetWindow(keepCounters: true); phase = .waitingForReliablePair; reason = "Window reset; awaiting reliable pair"
    }
  }
  private mutating func resetWindow(keepCounters: Bool = false) {
    lastFrame = 0; pendingSource = nil; windows = [:]; outliers = [:]; latestAnatomy = [:]
    if keepCounters { for id in players.keys { players[id]?.samples = 0 } } else { players = [:] }
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
  private mutating func reject(_ id: PlayerID, _ issue: StandingSampleIssue) {
    players[id, default: .init()].rejected[issue, default: 0] += 1
    players[id, default: .init()].latestIssue = issue
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
    lastFrame = pose.source.frameID
    latestAnatomy = mask.anatomy.filter { id, value in
      value.source == pose.source && value.controlRevision == stamp.bindingRevision
        && value.candidateID == association[id].candidateID
    }
    let imageHeight = Double(max(1, pose.frame.imageHeight))
    let tolerance = max(AnatomicalCandidatePolicyV1.standingSpreadPixels / imageHeight,
      mask.maskHeight.map { 1 / Double(max(1, $0)) } ?? 0)
    for id in stamp.roster {
      // Identity first: a slot that is not tracking (or needs rebind) restarts this player only.
      guard association[id].state == .tracking, !association[id].requiresRebind else {
        windows[id] = []; outliers[id] = nil; players[id, default: .init()].samples = 0; reject(id, .trackingLost)
        #if DEBUG
        players[id, default: .init()].last.resets += 1
        #endif
        continue
      }
      #if DEBUG
      recordDiagnostics(id, pose: pose, region: mask.regions[id], anatomy: latestAnatomy[id])
      #endif
      #if DEBUG
      players[id, default: .init()].last.maskQuality = mask.quality.rawValue
      players[id, default: .init()].last.maskRegions = mask.regions.count
      #endif
      guard mask.quality == .torsoSupportedGeometryUnverified, let region = mask.regions[id],
        region.candidateID == association[id].candidateID,
        let c = pose.frame.candidates.first(where: { $0.candidateID == region.candidateID }) else {
        reject(id, .notSeparated); continue
      }
      func seen(_ joint: BodyJoint) -> PoseJoint? { c.joints[joint].flatMap { $0.confidence >= 0.5 ? $0 : nil } }
      guard let ls = seen(.leftShoulder), let rs = seen(.rightShoulder),
        let lh = seen(.leftHip), let rh = seen(.rightHip) else { reject(id, .bodyNotFullyVisible); continue }
      let small = region.maxY - region.minY < StandingSampleIssue.tooFarHeightShare
      guard let nose = seen(.nose) else { reject(id, small ? .tooFar : .faceNotVisible); continue }
      guard let la = seen(.leftAnkle), let ra = seen(.rightAnkle) else { reject(id, small ? .tooFar : .feetNotVisible); continue }
      let hip = (lh.y + rh.y) / 2, shoulder = (ls.y + rs.y) / 2
      // Ordering is necessary, not sufficient, for a real standing posture. No invented offsets.
      guard shoulder > hip, nose.y > shoulder, la.y < hip, ra.y < hip else { reject(id, .notUpright); continue }
      guard let anatomy = latestAnatomy[id], let a = anatomy.experimentalReferences else {
        // The first precise reason: head first (it is read first), then the feet.
        let details = [latestAnatomy[id]?.crown, latestAnatomy[id]?.leftSole, latestAnatomy[id]?.rightSole]
          .compactMap { $0 }.filter { $0.status != .experimental }.compactMap(\.detail)
        reject(id, details.first.map(StandingSampleIssue.init) ?? .bodyNotFullyVisible)
        continue
      }
      var window = windows[id] ?? []
      let sample = PlayerSample(source: pose.source,
        values: [nose.y, la.y, ra.y, hip, shoulder - hip, (ls.x + rs.x + lh.x + rh.x) / 4, region.minY, region.maxY],
        anatomy: [a.crownY, a.leftSoleY, a.rightSoleY], tolerance: tolerance)
      players[id, default: .init()].accepted += 1
      // Recency: a window spans at most `maximumWindowSpan` of capture time.
      while let first = window.first,
        pose.source.capturedAt - first.source.capturedAt > StandingCollectionPolicyV1.maximumWindowSpan {
        window.removeFirst()
      }
      // Stability (same tolerance; a billionth of the image height absorbs rounding of equal mask
      // rows). A sample outside the window's tolerance is skipped on its own (iPad, 11 November
      // 2026: one jittery mask reading collapsed the window 31 times, 84 s to calibrate). Two
      // consecutive samples that agree with each other but not with the window mean the player
      // moved: the window restarts from them. The window itself always agrees within tolerance.
      var dropped = false
      #if DEBUG
      players[id, default: .init()].moveRangePixels = Self.ranges(window + [sample]).map { $0 * imageHeight }
      #endif
      if Self.spread(window + [sample]) <= tolerance + 1e-9 {
        window.append(sample)
        outliers[id] = nil
      } else if let previous = outliers[id], Self.spread([previous, sample]) <= tolerance + 1e-9,
        sample.source.capturedAt - previous.source.capturedAt <= StandingCollectionPolicyV1.maximumWindowSpan {
        window = [previous, sample]; outliers[id] = nil; dropped = true
      } else {
        outliers[id] = sample; dropped = true
      }
      if dropped { reject(id, .moving) }
      if window.count > StandingCollectionPolicyV1.sampleCount {
        window.removeFirst(window.count - StandingCollectionPolicyV1.sampleCount)
      }
      windows[id] = window
      players[id, default: .init()].samples = window.count
      if !dropped { players[id, default: .init()].latestIssue = nil }
      #if DEBUG
      players[id, default: .init()].spreadPixels = Self.spread(window) * imageHeight
      players[id, default: .init()].maskRows = mask.maskHeight
      #endif
    }
    phase = .collecting
    guard stamp.roster.allSatisfy({ windows[$0]?.count == StandingCollectionPolicyV1.sampleCount }) else { return }
    var observations: [PlayerID: StandingPlayerObservation] = [:]
    for id in stamp.roster {
      let window = windows[id]!
      let n = Double(window.count)
      let v = (0..<8).map { i in window.reduce(0) { $0 + $1.values[i] } / n }
      let a = (0..<3).map { i in window.reduce(0) { $0 + $1.anatomy[i] } / n }
      observations[id] = .init(noseY: v[0], leftAnkleY: v[1], rightAnkleY: v[2], hipY: v[3],
        torsoLength: v[4], originX: v[5], maskMinY: v[6], maskMaxY: v[7],
        anatomy: .init(crownY: a[0], leftSoleY: a[1], rightSoleY: a[2], quality: .experimental))
    }
    let first = stamp.roster.compactMap { windows[$0]?.first?.source }.min { $0.frameID < $1.frameID }!
    candidate = .init(id: UUID(), admission: stamp, firstFrameID: first.frameID,
      lastFrameID: pose.source.frameID, firstCapturedAt: first.capturedAt,
      lastCapturedAt: pose.source.capturedAt,
      expiresAt: min(deadline, time + StandingCollectionPolicyV1.candidateLifetime),
      players: observations, imageWidth: pose.frame.imageWidth, imageHeight: pose.frame.imageHeight,
      rotationAngle: pose.source.rotationAngle, mirrored: pose.source.mirrored,
      samples: StandingCollectionPolicyV1.sampleCount)
    phase = .candidateReady; reason = "Unaccepted paired candidate; any silhouette estimates are EXPERIMENTAL, never authoritative"
  }
  #if DEBUG
  private mutating func recordDiagnostics(_ id: PlayerID, pose: CameraPoseResult, region: PersonMaskRegion?,
    anatomy: AnatomicalPlayerCandidate?) {
    var d = players[id, default: .init()].last
    d.frameID = pose.source.frameID; d.capturedAt = pose.source.capturedAt
    d.visionBodies = pose.observationCount
    let candidate = region.flatMap { r in pose.frame.candidates.first { $0.candidateID == r.candidateID } }
    let joints: [BodyJoint] = [.nose, .leftEye, .rightEye, .leftEar, .rightEar, .neck, .leftShoulder, .rightShoulder,
      .leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle]
    d.confidence = Dictionary(uniqueKeysWithValues: joints.map { ($0, candidate?.joints[$0]?.confidence ?? 0) })
    d.headBeyondEars = anatomy?.headBeyondEarsShare
    d.crownAboveEyes = anatomy?.crownAboveEyesShare
    d.feetGapFilled = anatomy?.feetGapFilledShare
    d.crownAboveNose = anatomy?.crownAboveNoseShare
    d.footHeight = anatomy?.footHeightShare
    d.crownSeen = anatomy?.crown.status == .experimental
    d.solesSeen = anatomy?.leftSole.status == .experimental && anatomy?.rightSole.status == .experimental
    d.crown = anatomy?.crown.detail
    d.soles = anatomy?.leftSole.detail ?? anatomy?.rightSole.detail
    let w = Double(pose.frame.imageWidth), h = Double(pose.frame.imageHeight)
    if let la = candidate?.joints[.leftAnkle], let ra = candidate?.joints[.rightAnkle] {
      d.ankleSeparationPixels = abs(la.x - ra.x) * w
      let top = candidate?.joints[.nose]?.y ?? (region?.maxY ?? 1)
      let body = (top - min(la.y, ra.y)) * h
      d.bodyHeightPixels = body > 0 ? body : nil
      d.ankleSeparationShare = body > 0 ? abs(la.x - ra.x) * w / body : nil
    } else { d.ankleSeparationPixels = nil; d.ankleSeparationShare = nil }
    players[id, default: .init()].last = d
  }
  #endif
  /// Largest head-top or sole range across a window, normalized.
  private static func spread(_ window: [PlayerSample]) -> Double { ranges(window).max() ?? 0 }
  /// Head-top, left sole and right sole ranges across a window, normalized.
  private static func ranges(_ window: [PlayerSample]) -> [Double] {
    (0..<3).map { i in
      let values = window.map { $0.anatomy[i] }
      return (values.max() ?? 0) - (values.min() ?? 0)
    }
  }
  private func sourceIsFresh(_ source: CameraFrameMetadata, _ time: Double) -> Bool {
    time.isFinite && time >= source.capturedAt
      && time - source.capturedAt < StandingCollectionPolicyV1.sampleFreshness
  }
  #if DEBUG
  var inspectionRequestDeadline: Double? { admission == nil ? nil : deadline }
  #endif
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
    .init(request: admission?.request, phase: phase, sampleCount: count, candidate: candidate, reason: reason,
      players: players)
  }
}
