import Foundation

/// Airborne evidence needs justified independent soles AND an accepted floor/time model.
/// Ankle elevation or a mask bottom alone never supplies this authority.
nonisolated enum JumpDetector {
  static func unavailable(_ reason: EvidenceValidity = .missingLandmarks) -> JumpState {
    .init(phase: .unknown, validity: reason == .valid ? .missingLandmarks : reason)
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
