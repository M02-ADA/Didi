import Foundation

/// Airborne evidence needs justified independent soles AND an accepted floor/time model.
/// Ankle elevation or a mask bottom alone never supplies this authority.
nonisolated enum JumpDetector {
  static func unavailable(_ reason: EvidenceValidity = .missingLandmarks) -> JumpState {
    .init(phase: .unknown, validity: reason == .valid ? .missingLandmarks : reason)
  }
}

/// Live airborne estimate, one per player, game units. The temporal rule of the
/// `spike/front-facing-avatar` `LiveJumpDetector` ("tuned"), adopted 11 November 2026 after the
/// fixed-floor rule never reported airborne on the iPad: live standing soles sat 0.05–0.08 above
/// the calibrated floor, more than the 3 % threshold, so the player was never "seen grounded".
///
/// - Lift = the LOWER sole above a grounded baseline that starts at the calibrated floor and
///   follows slow posture/depth drift (time constant `baselineTime`) whenever no jump or quick
///   rise is in progress. A slow rise (tiptoe, stepping closer) is absorbed, never a jump.
/// - AIRBORNE starts when lift exceeds max(`enterShare` × standing height, `noiseMultiple` ×
///   this player's own frame-to-frame foot noise) AND rose by `riseFraction` of that within
///   `riseWindow` (a hop, not a slow rise). One raised foot never counts (the lower sole stays down).
/// - It ends below `exitShare` (hysteresis); the first frame after is LANDING.
/// - Missing soles are UNKNOWN for that frame, never airborne or grounded. A jump in progress
///   survives `dropoutFrames` such frames; more, a capture gap, or a new calibration ends it.
/// Reference values come from synthetic tracks (spike `LiveJumpTuningTests`), not device data.
nonisolated struct LiveJumpEstimator: Sendable {
  static let enterShare = 0.03, exitShare = 0.015, noiseMultiple = 4.0
  static let riseWindow = 0.25, riseFraction = 0.8
  static let dropoutFrames = 2, baselineTime = 1.0
  static let maximumGap = 0.2
  /// POSE-FIRST CANDIDATE (Kevin, 14 Nov 2026 — needs Edo's review; values to tune on device):
  /// a flight longer than this is a held rise (tiptoe), not a jump; a 30 cm jump flies ~0.5 s.
  static let maximumFlight = 0.7
  /// At take-off the hips must rise at least this share of the soles' rise (whole body leaves the
  /// floor; an ankle-only jump in the pose is noise). Unknown hips do not block.
  static let hipFollowShare = 0.5
  /// FLOOR RE-ANCHORING (Kevin, 14 Nov 2026 — Edo-owned, needs his review). iPad logs: while the
  /// player squats, the ankle-based sole reads 0.1–0.2 below the real floor; the floor baseline
  /// followed it down (to −0.18…−0.20 after each duck) and, standing again, the player's real
  /// floor read 0.06–0.2 "lifted" for 1–3 s. A jump then was mis-measured both ways: a landing
  /// back on the real floor stayed "airborne" (a false CLEAR from an early jump) and a small jump
  /// rose too little above the stale floor to take off (a missed jump). The candidate therefore:
  /// - learns the floor only while UPRIGHT: hips at least `uprightLegShare` of the calibrated
  ///   standing leg above the soles (a squat deep enough for a high laser drops them further);
  /// - re-anchors it to where the soles actually are once they have been STILL — within
  ///   `stillBandShare` of standing height — for `ballisticApexLimit`, upright and grounded;
  /// - never moves it during a flight; a "flight" that has gone still that long is not one (a body
  ///   in free flight stays within 1 % of height of its apex for only 2·√(2δ/g) ≈ 0.12 s, even for
  ///   a 1.9 m player), so it ends there, which a real jump's brief apex never triggers.
  static let stillBandShare = 0.01
  static let ballisticApexLimit = 0.15
  static let uprightLegShare = 0.9
  /// Candidate: the latest run of grounded sole heights (relative to the calibrated soles) that
  /// stayed within the still band; emptied by any gap in sole evidence.
  private var still: [(time: Double, raw: Double)] = []
  private var airborneSince: Double?
  private var heldRise = false
  private var recentHips: [(time: Double, hip: Double)] = []
  private var calibrationRevision: UInt64?
  private var lastFrame: UInt64 = 0
  private var lastTime: Double?
  private var airborne = false
  private var missing = 0
  private var recent: [(time: Double, lift: Double)] = []
  private var noiseVariance = 0.0
  private var previousLift: Double?
  /// Grounded floor offset from the calibrated soles, game units.
  private(set) var baseline = 0.0
  /// This frame's lower-sole lift above the baseline (nil without both soles).
  private(set) var lift: Double?
  private(set) var noise = 0.0

  func enterThreshold(standingHeight: Double) -> Double {
    max(Self.enterShare * standingHeight, Self.noiseMultiple * noise)
  }

  mutating func step(frameID: UInt64, capturedAt time: Double, leftSole: Double?, rightSole: Double?,
    standingLeftSole: Double, standingRightSole: Double,
    standingHeight: Double, calibrationRevision revision: UInt64,
    hipY: Double? = nil, standingHip: Double? = nil, candidateRules: Bool = false) -> JumpState {
    if calibrationRevision != revision { self = Self(); calibrationRevision = revision }
    guard frameID > lastFrame, lastTime.map({ time > $0 }) ?? true, time.isFinite else {
      return JumpDetector.unavailable(.stale)
    }
    let dt = lastTime.map { time - $0 } ?? 0
    if dt > Self.maximumGap { airborne = false; missing = 0; recent = []; previousLift = nil; still = [] }
    lastFrame = frameID; lastTime = time
    guard let leftSole, let rightSole, standingHeight > 0, standingHeight.isFinite else {
      missing += 1; lift = nil; previousLift = nil; still = []
      if missing > Self.dropoutFrames { airborne = false; recent = [] }
      return JumpDetector.unavailable(.missingLandmarks)
    }
    missing = 0
    let raw = min(leftSole - standingLeftSole, rightSole - standingRightSole)
    let wasAirborne = airborne
    // Candidate: upright (hips high over the soles) and still (soles within the band for long enough).
    var upright = false
    if candidateRules {
      let floorLevel = min(standingLeftSole, standingRightSole)
      if let hipY, let standingHip, standingHip > floorLevel {
        upright = hipY - (raw + floorLevel) >= Self.uprightLegShare * (standingHip - floorLevel)
      }
      let band = max(Self.stillBandShare * standingHeight, Self.noiseMultiple * noise)
      still.append((time, raw))
      while still.count > 1, still.map(\.raw).max()! - still.map(\.raw).min()! > band { still.removeFirst() }
      if still.last!.time - still.first!.time >= Self.ballisticApexLimit - 1e-6 {
        if airborne { airborne = false; airborneSince = nil } // still that long: not a flight
        if upright {
          let level = still.map(\.raw).reduce(0, +) / Double(still.count)
          let shift = level - baseline
          baseline = level
          recent = recent.map { ($0.time, $0.lift - shift) }
          previousLift = previousLift.map { $0 - shift }
          heldRise = false
        }
      }
    }
    let lifted = raw - baseline
    lift = lifted
    recent.append((time, lifted))
    recent.removeAll { time - $0.time > Self.riseWindow }
    let enter = enterThreshold(standingHeight: standingHeight)
    let rise = lifted - (recent.map(\.lift).min() ?? lifted)
    if candidateRules, let hipY {
      recentHips.append((time, hipY))
      recentHips.removeAll { time - $0.time > Self.riseWindow }
    }
    if airborne {
      airborne = lifted > Self.exitShare * standingHeight
      // Candidate: a rise held past a credible flight is a tiptoe, not a jump.
      if candidateRules, airborne, let since = airborneSince, time - since > Self.maximumFlight {
        airborne = false; heldRise = true
      }
    } else if lifted > enter {
      var takeoff = rise >= Self.riseFraction * enter
      if candidateRules {
        if heldRise { takeoff = false } // must come back down before another take-off
        else if takeoff, let hipY, let lowest = recentHips.map(\.hip).min() {
          takeoff = hipY - lowest >= Self.hipFollowShare * rise
        }
      }
      airborne = takeoff
    }
    if candidateRules {
      if airborne, airborneSince == nil { airborneSince = time }
      if !airborne { airborneSince = nil }
      if heldRise, lifted <= Self.exitShare * standingHeight { heldRise = false }
    }
    // Follow the grounded floor while no jump or quick rise is in progress (judged against the
    // fixed 3 %, never the learned threshold, so the two cannot feed each other). The noise is
    // the frame-to-frame jitter, which a slow posture shift such as a duck barely changes (iPad,
    // 11 November 2026: measured against the floor it reached 0.038 after a duck, threshold 0.15).
    let base = Self.enterShare * standingHeight
    // Candidate: the slow drift too learns only from upright frames (never from a squat).
    if !airborne, rise < Self.riseFraction * base, dt > 0, !candidateRules || upright {
      let k = 1 - exp(-dt / Self.baselineTime)
      baseline += k * lifted
      if let previous = previousLift {
        let step = lifted - previous
        noiseVariance += k * (step * step / 2 - noiseVariance)
        noise = noiseVariance.squareRoot()
      }
    }
    previousLift = lifted
    return .init(phase: airborne ? .airborne : (wasAirborne ? .landing : .grounded), validity: .valid)
  }
}


nonisolated struct ExperimentalStandingSurface: Equatable, Sendable {
  let source: CameraSourceContext
  let playerID: PlayerID
  let controlRevision: UInt64, calibrationRevision: UInt64
  let leftSoleY: Double, rightSoleY: Double, hipY: Double
  /// Supplied uncertainty envelope, not a hard-coded body offset or production jump height.
  let uncertaintyImageY: Double
}
nonisolated enum ExperimentalAirbornePhase: String, Sendable { case unknown, groundedCandidate, airborneCandidate }
nonisolated struct ExperimentalAirborneResult: Equatable, Sendable {
  let phase: ExperimentalAirbornePhase
  let reason: String
  /// Experimental classification never grants CP1 airborne authority.
  var authoritative: JumpState { JumpDetector.unavailable() }
}
/// Finite temporal evidence window, no person association or wall clock. 3 samples AND80ms,
/// gaps<=200ms are trial values. Existing 1Hz calibration masks cannot satisfy this cadence.
nonisolated enum ExperimentalJumpPolicyV1 {
  static let version = "ExperimentalJumpPolicyV1-NOT-PRODUCTION"
  static let maximumGap = 0.2, dwell = 0.08
  static let minimumSamples = 3
}
nonisolated struct ExperimentalJumpDetector: Sendable {
  private var reference: ExperimentalStandingSurface?
  private var lastTime: Double?
  private var lastFrame: UInt64 = 0
  private var runStart: Double?
  private var count = 0
  private var grounded = false
  private var run: ExperimentalAirbornePhase = .unknown
  /// Live adapter always executes, including unbound/uncalibrated and non-mask frames.
  /// Unknown input resets temporal continuity; a cached mask is never substituted here.
  mutating func processLive(_ anatomy: AnatomicalPlayerCandidate, hipY: Double?,
    reference: ExperimentalStandingSurface?, playerID: PlayerID, confirmedAssociation: Bool,
    cameraStationaryEvidence: Bool) -> ExperimentalAirborneResult {
    guard confirmedAssociation else {
      reset(); return .init(phase: .unknown, reason: "No confirmed same-source player association")
    }
    guard let reference else {
      reset(); return .init(phase: .unknown, reason: "No compatible accepted standing reference with uncertainty")
    }
    guard anatomy.experimentalReferences != nil else {
      reset(); return .init(phase: .unknown, reason: "No independent SAME-FRAME sole evidence; ankles are not soles")
    }
    return process(anatomy, hipY: hipY, reference: reference, playerID: playerID,
      cameraStationaryEvidence: cameraStationaryEvidence)
  }
  mutating func reset() { self = Self() }
  mutating func process(_ anatomy: AnatomicalPlayerCandidate, hipY: Double?,
    reference baseline: ExperimentalStandingSurface, playerID: PlayerID, cameraStationaryEvidence: Bool) -> ExperimentalAirborneResult {
    func unknown(_ reason: String) -> ExperimentalAirborneResult { .init(phase: .unknown, reason: reason) }
    guard playerID == baseline.playerID, anatomy.source.context == baseline.source, anatomy.controlRevision == baseline.controlRevision,
      baseline.calibrationRevision > 0, baseline.uncertaintyImageY.isFinite,
      baseline.uncertaintyImageY > 0,
      [baseline.leftSoleY, baseline.rightSoleY, baseline.hipY].allSatisfy({ $0.isFinite && (0...1).contains($0) })
    else { reset(); return unknown("Incompatible reference/source") }
    if reference != baseline { reset(); reference = baseline }
    let time = anatomy.source.capturedAt
    guard time.isFinite, time >= 0, anatomy.source.frameID > lastFrame,
      lastTime.map({ time > $0 }) ?? true else {
      grounded = false; count = 0; runStart = nil; run = .unknown
      return unknown("Stale/duplicate observation")
    }
    let continuous = lastTime.map { time - $0 <= ExperimentalJumpPolicyV1.maximumGap } ?? true
    lastTime = time; lastFrame = anatomy.source.frameID
    guard continuous, cameraStationaryEvidence, let feet = anatomy.experimentalReferences,
      let hipY, hipY.isFinite, (0...1).contains(hipY) else {
      grounded = false; count = 0; runStart = nil; run = .unknown
      return unknown("Missing, discontinuous or camera-ambiguous evidence")
    }
    let epsilon = baseline.uncertaintyImageY
    let phase: ExperimentalAirbornePhase
    if abs(feet.leftSoleY - baseline.leftSoleY) <= epsilon,
      abs(feet.rightSoleY - baseline.rightSoleY) <= epsilon {
      phase = .groundedCandidate
    } else if grounded, feet.leftSoleY > baseline.leftSoleY + epsilon,
      feet.rightSoleY > baseline.rightSoleY + epsilon, hipY > baseline.hipY + epsilon {
      phase = .airborneCandidate
    } else {
      grounded = false; count = 0; runStart = nil; run = .unknown
      return unknown("Both feet and body rise not supported")
    }
    if run != phase { run = phase; count = 0; runStart = time }
    count = min(count + 1, ExperimentalJumpPolicyV1.minimumSamples)
    guard count >= ExperimentalJumpPolicyV1.minimumSamples, time - (runStart ?? time) >= ExperimentalJumpPolicyV1.dwell else { return unknown("Temporal dwell pending") }
    if phase == .groundedCandidate { grounded = true }
    return .init(phase: phase, reason: "EXPERIMENTAL only; 2D projection is not physical ground-contact proof")
  }
}
