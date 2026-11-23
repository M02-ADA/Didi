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
/// - Missing soles are UNKNOWN for that frame, never airborne or grounded. Before a jump, more than
///   `dropoutFrames` such frames forget the rise seen so far. A jump in progress survives them for up
///   to `maximumGap` since its soles were last seen, and resumes only if the soles (or the hip bound,
///   `flightSoles`) still show the player up (iPad, 21 November 2026: in butt-kick jumps the tracker
///   lost the player for 5 frames, 0.17 s, at the top of the kick). Longer, a capture gap, or a new
///   calibration ends it.
///   (DEBUG: each step's decision is kept in `decision` for the jump trace, `JumpTraceLog`.)
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
  /// floor; an ankle-only jump in the pose is noise). Unknown hips do not block. Never more than the
  /// take-off line itself (21 November 2026): in a tuck jump the heels fold back as the feet leave the
  /// floor, so the soles rise by the flight PLUS the tuck while the hips rise by the flight alone, and
  /// a share of that sum refused every frame of a real jump. Still hips (ankle noise, one raised
  /// foot, a squat) still never take off.
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
  private var still = JumpStillRun()
  private var airborneSince: Double?
  private var heldRise = false
  private var recentHips: [(time: Double, hip: Double)] = []
  private var calibrationRevision: UInt64?
  private var lastFrame: UInt64 = 0
  private var lastTime: Double?
  /// When both soles were last seen (a flight survives missing soles up to `maximumGap` from here).
  private var lastSolesTime: Double?
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
  #if DEBUG
  /// DEBUG jump trace (21 November 2026, butt-kick jump diagnosis): what this step decided and why.
  private(set) var decision = ""
  #endif

  func enterThreshold(standingHeight: Double) -> Double {
    max(Self.enterShare * standingHeight, Self.noiseMultiple * noise)
  }

  /// Whether a flight is in progress: a take-off was seen from real soles and it has not ended.
  var isInFlight: Bool { airborne }

  /// BUTT-KICK FLIGHTS (Kevin, 21 November 2026 — Edo-owned, needs his review). iPad evidence
  /// (`[LaserJumpTrace]`, three butt-kick jumps, all HIT): take-off was seen (hips +0.20…+0.27), then
  /// the heels folded behind the thighs and Vision's ankle confidence fell to 0.11–0.47 for 8–9 frames
  /// (0.27–0.30 s) while the hips stayed 0.19–0.25 above standing at full confidence. With no soles
  /// the flight ended on the third frame, the crossing fell in that gap, and no usable capture was
  /// airborne at it.
  ///
  /// A foot cannot hang lower than a straight leg below the hips. So during a flight already seen
  /// (`isInFlight`), a sole whose ankle is not confidently seen is bounded at the hips minus this
  /// side's standing hip-to-sole height, used only while that bound is itself clearly off the floor
  /// (hips at least the take-off line, `enterShare` of standing height, above standing). Never for a
  /// take-off, never while grounded, never to make a landing: otherwise the sole stays missing.
  static func flightSoles(left: Double?, right: Double?, inFlight: Bool, hipY: Double?, standingHip: Double,
                          standingLeftSole: Double, standingRightSole: Double,
                          standingHeight: Double) -> (left: Double?, right: Double?, bounded: Bool) {
    guard inFlight, left == nil || right == nil, let hipY, hipY.isFinite, standingHeight > 0,
          hipY - standingHip >= enterShare * standingHeight else { return (left, right, false) }
    let l = left ?? hipY - (standingHip - standingLeftSole)
    let r = right ?? hipY - (standingHip - standingRightSole)
    return (l, r, true)
  }

  mutating func step(frameID: UInt64, capturedAt time: Double, leftSole: Double?, rightSole: Double?,
    standingLeftSole: Double, standingRightSole: Double,
    standingHeight: Double, calibrationRevision revision: UInt64,
    hipY: Double? = nil, standingHip: Double? = nil, candidateRules: Bool = false) -> JumpState {
    if calibrationRevision != revision { self = Self(); calibrationRevision = revision }
    guard frameID > lastFrame, lastTime.map({ time > $0 }) ?? true, time.isFinite else {
      #if DEBUG
      decision = "stale frame"
      #endif
      return JumpDetector.unavailable(.stale)
    }
    #if DEBUG
    decision = ""
    func note(_ text: String) { decision = decision.isEmpty ? text : decision + "; " + text }
    #endif
    let dt = lastTime.map { time - $0 } ?? 0
    if dt > Self.maximumGap {
      #if DEBUG
      note(String(format: "capture gap %.3f s resets%@", dt, airborne ? " (ENDS FLIGHT)" : ""))
      #endif
      airborne = false; missing = 0; recent = []; previousLift = nil; still.removeAll()
    }
    lastFrame = frameID; lastTime = time
    guard let leftSole, let rightSole, standingHeight > 0, standingHeight.isFinite else {
      missing += 1; lift = nil; previousLift = nil; still.removeAll()
      #if DEBUG
      let flightLost = airborne && time - (lastSolesTime ?? time) > Self.maximumGap
      note("no soles (\(missing) in a row)" + (flightLost ? " → FLIGHT ENDED BY DROPOUT" : airborne ? " (flight kept)" : "")
           + (missing > Self.dropoutFrames && !airborne ? " → rise history cleared" : ""))
      #endif
      let lost = airborne ? time - (lastSolesTime ?? time) > Self.maximumGap : missing > Self.dropoutFrames
      if lost { airborne = false; recent = [] }
      return JumpDetector.unavailable(.missingLandmarks)
    }
    missing = 0
    lastSolesTime = time
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
      still.append(time: time, raw: raw, band: band)
      if still.lastTime - still.firstTime >= Self.ballisticApexLimit - 1e-6 {
        #if DEBUG
        if airborne { note("FLIGHT ENDED: soles still \(Int(Self.ballisticApexLimit * 1000)) ms (apex rule)") }
        #endif
        if airborne { airborne = false; airborneSince = nil } // still that long: not a flight
        if upright {
          let level = still.mean
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
      #if DEBUG
      if !airborne { note(String(format: "landed (lift %.3f ≤ exit %.3f)", lifted, Self.exitShare * standingHeight)) }
      #endif
      // Candidate: a rise held past a credible flight is a tiptoe, not a jump.
      if candidateRules, airborne, let since = airborneSince, time - since > Self.maximumFlight {
        airborne = false; heldRise = true
        #if DEBUG
        note("FLIGHT ENDED: longer than max flight (held rise)")
        #endif
      }
    } else if lifted > enter {
      var takeoff = rise >= Self.riseFraction * enter
      if candidateRules {
        if heldRise { takeoff = false } // must come back down before another take-off
        else if takeoff, let hipY, let lowest = recentHips.map(\.hip).min() {
          let hipRise = hipY - lowest
          takeoff = hipRise >= min(Self.hipFollowShare * rise, enter)
          #if DEBUG
          note(String(format: "hips rose %.3f (need %.3f)", hipRise, min(Self.hipFollowShare * rise, enter)))
          #endif
        }
        #if DEBUG
        if heldRise { note("held rise: must come down first") }
        #endif
      }
      #if DEBUG
      note(String(format: "rise %.3f (need %.3f in %.2f s) → %@", rise, Self.riseFraction * enter, Self.riseWindow,
                   takeoff ? "TAKE-OFF" : "NO TAKE-OFF"))
      #endif
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


/// The jump estimator's still run (`LiveJumpEstimator.still`): the latest grounded sole heights whose
/// range stays within the still band, oldest dropped first until it does. Exactly the run the earlier
/// array kept, with its maximum, minimum and sum maintained as samples arrive and leave, so a frame
/// costs O(1) amortized however long a player stands still.
///
/// PERFORMANCE (Kevin, 22 November 2026; Edo-owned, for his review): the earlier array re-scanned the
/// whole run two or three times per frame, per player, and a player standing steady never left the
/// band, so the run grew through the round: 118 µs per step at the start of a five-minute steady
/// round, 2,036 µs at its end (Debug, `JumpEstimatorCostTests`), on the camera worker. Same members,
/// same first and last times; the mean differs from the earlier left-to-right sum only by
/// floating-point rounding (`JumpStillRunTests`).
nonisolated struct JumpStillRun: Sendable {
  private var times: [Double] = []
  private var raws: [Double] = []
  private var head = 0
  /// Indices into the run: raw heights decreasing (front = the run's maximum) and increasing (minimum).
  private var maxima: [Int] = [], maxHead = 0
  private var minima: [Int] = [], minHead = 0
  private var sum = 0.0

  var count: Int { raws.count - head }
  var isEmpty: Bool { count == 0 }
  /// The oldest and latest sample times (the run must not be empty).
  var firstTime: Double { times[head] }
  var lastTime: Double { times[times.count - 1] }
  var maximum: Double { raws[maxima[maxHead]] }
  var minimum: Double { raws[minima[minHead]] }
  var mean: Double { sum / Double(count) }

  mutating func removeAll() { self = JumpStillRun() }

  /// Adds a sample, then drops the oldest while more than one remain and their range exceeds `band`.
  mutating func append(time: Double, raw: Double, band: Double) {
    let index = raws.count
    times.append(time)
    raws.append(raw)
    sum += raw
    while maxima.count > maxHead, raws[maxima[maxima.count - 1]] <= raw { maxima.removeLast() }
    maxima.append(index)
    while minima.count > minHead, raws[minima[minima.count - 1]] >= raw { minima.removeLast() }
    minima.append(index)
    while count > 1, maximum - minimum > band {
      sum -= raws[head]
      head += 1
      if maxima[maxHead] < head { maxHead += 1 }
      if minima[minHead] < head { minHead += 1 }
    }
    if head >= 1024, head * 2 >= raws.count { compact() }
  }

  /// Drops the samples that left the run (bounded memory) and re-sums the rest exactly.
  private mutating func compact() {
    times.removeFirst(head)
    raws.removeFirst(head)
    maxima = maxima[maxHead...].map { $0 - head }
    minima = minima[minHead...].map { $0 - head }
    maxHead = 0
    minHead = 0
    head = 0
    sum = raws.reduce(0, +)
  }
}
