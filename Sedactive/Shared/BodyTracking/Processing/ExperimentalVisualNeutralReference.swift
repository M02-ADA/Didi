import Foundation

/// Caller-selected EXPERIMENT settings, not approved calibration/posture thresholds.
/// No defaults: the eventual owner must select/document settings before runtime hookup.
nonisolated struct VisualNeutralReferencePolicy: Sendable {
  let sampleCount: Int
  let minimumSpan, collectionTimeout, maximumGap, referenceLifetime: Double
  let relativeTolerance, centerTolerance, angleTolerance, asymmetryTolerance: Double

  func validate() throws {
    let values = [minimumSpan, collectionTimeout, maximumGap, referenceLifetime,
      relativeTolerance, centerTolerance, angleTolerance, asymmetryTolerance]
    guard (3...32).contains(sampleCount), values.allSatisfy({ $0.isFinite && $0 > 0 }),
      collectionTimeout > minimumSpan, maximumGap <= B2bExperimentalPolicyV1.value.freshness,
      minimumSpan < Double(sampleCount - 1) * maximumGap else { throw VisualNeutralRefusal.invalidPolicy }
  }
}
nonisolated enum VisualNeutralRefusal: String, Error, Sendable {
  case invalidPolicy, uprightIntentRequired, inactive, invalidTiming, invalidEvidence
  case contextChanged, reset, preRequest, outOfOrder, stale, frameGap, expired
  case unreliableTracking, unsupportedFeatures, unstable, insufficientSpan, perspectiveAmbiguous
}
nonisolated enum VisualNeutralPhase: Sendable { case idle, collecting, ready, unavailable }

/// Scalar-only, projected image features. No physical or accepted standing reference.
nonisolated struct VisualNeutralValues: Equatable, Sendable {
  let shoulderY, hipY, torso, lean, roll, left, right, bilateral, confidence: Double
  fileprivate init(_ p: ExperimentalPlayerPosture) throws {
    let scalars = [p.shoulderCenterY, p.hipCenterY, p.torsoLength, p.torsoLeanRadians,
      p.shoulderRollRadians, p.leftLegExtentOverTorso, p.rightLegExtentOverTorso, p.bilateralExtentOverTorso]
    guard scalars.allSatisfy({ s in
      s.refusal == nil && s.value?.isFinite == true && s.confidence.map {
        $0.isFinite && $0 >= B2bExperimentalPolicyV1.value.minimumJointConfidence && $0 <= 1
      } == true
    }) else { throw VisualNeutralRefusal.unsupportedFeatures }
    shoulderY = scalars[0].value!; hipY = scalars[1].value!; torso = scalars[2].value!
    lean = scalars[3].value!; roll = scalars[4].value!; left = scalars[5].value!
    right = scalars[6].value!; bilateral = scalars[7].value!
    confidence = scalars.map { $0.confidence! }.min()!
    guard torso > 0, left > 0, right > 0, bilateral > 0 else { throw VisualNeutralRefusal.unsupportedFeatures }
  }
  fileprivate init(samples: [Self]) {
    func median(_ key: KeyPath<Self, Double>) -> Double {
      let a = samples.map { $0[keyPath: key] }.sorted(), middle = a.count / 2
      return a.count % 2 == 0 ? (a[middle-1] + a[middle]) / 2 : a[middle]
    }
    shoulderY = median(\.shoulderY); hipY = median(\.hipY); torso = median(\.torso)
    lean = median(\.lean); roll = median(\.roll); left = median(\.left); right = median(\.right)
    // Derive from the aggregated legs rather than combining unrelated median extrema.
    bilateral = max(left, right); confidence = samples.map(\.confidence).min()!
  }
}
nonisolated struct ExperimentalVisualNeutralCandidate: Sendable {
  let requestID: UUID
  let playerID: PlayerID
  let requestedAt: Double
  let firstSource, lastSource: PlayerTrackingSource
  let firstCandidateID, lastCandidateID: UInt64
  let presentationRevision, acceptedContextRevision: UInt64
  let sampleCount: Int
  let values: VisualNeutralValues
}
nonisolated struct ExperimentalVisualNeutralComparison: Sendable {
  let playerID: PlayerID
  let referenceRequestID: UUID
  let source: PlayerTrackingSource
  let candidateID: UInt64
  let presentationRevision, acceptedContextRevision: UInt64
  let leftExtentRatioToNeutral, rightExtentRatioToNeutral, bilateralExtentRatioToNeutral: Double
  let torsoLeanDeltaRadians, shoulderRollDeltaRadians: Double
  let confidence: Double
  /// ALWAYS ambiguous for physical posture. Equal projections cannot rule out yaw,
  /// perspective/camera movement, or certify an upright pose. No squat/airborne verdict.
  let physicalInterpretationIsAmbiguous = true
}
nonisolated struct ExperimentalVisualNeutralResult: Sendable {
  let phase: VisualNeutralPhase
  let sampleCount: Int
  let candidate: ExperimentalVisualNeutralCandidate?
  let comparison: ExperimentalVisualNeutralComparison?
  let refusal: VisualNeutralRefusal?
}

/// Pure, synchronous value state. One owner calls begin/update/invalidate on its existing
/// E07 tick; no drain, actor, task, timer, images, UI, calibration authority or subscription.
/// At most two 32-sample scalar windows, two candidates and two latest comparisons.
nonisolated struct ExperimentalVisualNeutralReference: Sendable {
  private struct Fence: Equatable, Sendable {
    let context: PlayerTrackingContext
    let presentation, control, accepted: UInt64
    let calibrations: [PlayerID: UInt64]
    init?(_ s: VisionNumericPoseStatus?) {
      guard let s, s.active, let c = s.context else { return nil }
      context = c; presentation = s.revision; control = s.controlRevision
      accepted = s.acceptedContextRevision; calibrations = s.calibrationRevisions
    }
  }
  private struct Slot: Sendable {
    var phase: VisualNeutralPhase = .idle
    var requestID = UUID()
    var requestedAt: Double = 0
    var fence: Fence?
    var samples: [VisualNeutralValues] = []
    var first: PlayerTrackingSource?
    var firstCandidateID: UInt64?
    var last: PlayerTrackingSource?
    var candidate: ExperimentalVisualNeutralCandidate?
    var comparison: ExperimentalVisualNeutralComparison?
    var refusal: VisualNeutralRefusal?
    mutating func invalidate(_ reason: VisualNeutralRefusal) {
      phase = .unavailable; samples.removeAll(keepingCapacity: false)
      candidate = nil; comparison = nil; first = nil; firstCandidateID = nil; last = nil; fence = nil; refusal = reason
    }
    var result: ExperimentalVisualNeutralResult {
      .init(phase: phase, sampleCount: candidate?.sampleCount ?? samples.count,
        candidate: candidate, comparison: comparison, refusal: refusal)
    }
  }
  private let policy: VisualNeutralReferencePolicy
  private var slots: [PlayerID: Slot] = [.player1: Slot(), .player2: Slot()]
  private var lastEvaluation: Double?

  init(policy: VisualNeutralReferencePolicy) throws { try policy.validate(); self.policy = policy }

  /// Explicit user assertion, NOT a detected standing pose. Recapture clears ONLY this player.
  @discardableResult mutating func begin(for player: PlayerID, userIdentifiedUprightNeutral: Bool,
    status: VisionNumericPoseStatus?, at time: Double) -> VisualNeutralRefusal? {
    var slot = Slot()
    if !time.isFinite || time < 0 || lastEvaluation.map({ time < $0 }) == true {
      slot.invalidate(.invalidTiming)
    } else if !userIdentifiedUprightNeutral { slot.invalidate(.uprightIntentRequired)
    } else if let fence = Fence(status) {
      slot.phase = .collecting; slot.requestedAt = time; slot.fence = fence
    } else { slot.invalidate(.inactive) }
    slots[player] = slot
    return slot.refusal
  }

  mutating func invalidate() {
    for id in PlayerID.allCases { slots[id]!.invalidate(.reset) }
    // Keep the host-time watermark: no old session clock can revive a reference.
  }

  /// Call on EVERY existing tick, including no-output ticks and nil/inactive drain.
  /// Returns only status-qualified results; the owner must not cache them across invalidation.
  mutating func update(_ batch: ExperimentalVisualPostureBatch, at time: Double,
    maximumAge: Double) -> [PlayerID: ExperimentalVisualNeutralResult] {
    let global: VisualNeutralRefusal?
    if !VisualPosturePreparation.validClock(time, maximumAge) || lastEvaluation.map({ time < $0 }) == true {
      global = .invalidTiming
    } else if batch.refusal != nil { global = batch.refusal == .inactive ? .inactive : .invalidEvidence
    } else if Fence(batch.status) == nil { global = .inactive
    } else if batch.resetAll { global = .reset
    } else { global = nil }
    if time.isFinite, time >= 0 { lastEvaluation = max(lastEvaluation ?? time, time) }
    for id in PlayerID.allCases {
      var slot = slots[id]!
      if slot.phase == .collecting || slot.phase == .ready {
        if let global { slot.invalidate(global) }
        else if slot.fence != Fence(batch.status) { slot.invalidate(.contextChanged) }
        else if slot.phase == .collecting && time - slot.requestedAt >= policy.collectionTimeout { slot.invalidate(.expired) }
        else if let c = slot.candidate, time - c.lastSource.capturedAt >= policy.referenceLifetime { slot.invalidate(.expired) }
        else if let last = slot.last, time - last.capturedAt >= min(maximumAge, policy.maximumGap) { slot.invalidate(.frameGap) }
        else if let frame = batch.frame {
          ingest(frame, player: id, status: batch.status, time: time, age: maximumAge, into: &slot)
        }
      }
      slots[id] = slot
    }
    return slots.mapValues(\.result)
  }

  private func ingest(_ frame: ExperimentalVisualPostureFrame, player: PlayerID,
    status: VisionNumericPoseStatus?, time: Double, age: Double, into slot: inout Slot) {
    guard frame.isCurrent(in: status, at: time, maximumAge: age) else { slot.invalidate(.stale); return }
    guard frame.source.capturedAt > slot.requestedAt else { slot.invalidate(.preRequest); return }
    if let last = slot.last {
      guard frame.source.frameID > last.frameID, frame.source.capturedAt > last.capturedAt else {
        slot.invalidate(.outOfOrder); return
      }
      guard frame.source.capturedAt - last.capturedAt < policy.maximumGap else { slot.invalidate(.frameGap); return }
    }
    let p = frame[player]
    guard p.playerID == player, p.trackingState == .tracking, !p.requiresRebind, p.candidateID != nil else {
      slot.invalidate(.unreliableTracking); return
    }
    do {
      let values = try VisualNeutralValues(p)
      if slot.phase == .collecting {
        if slot.first == nil { slot.first = frame.source; slot.firstCandidateID = p.candidateID }
        slot.samples.append(values) // never more than validated sampleCount (<=32)
        if slot.samples.count == policy.sampleCount {
          guard frame.source.capturedAt - slot.first!.capturedAt >= policy.minimumSpan else {
            slot.invalidate(.insufficientSpan); return
          }
          let median = VisualNeutralValues(samples: slot.samples)
          guard slot.samples.allSatisfy({ stable($0, relativeTo: median, collecting: true) }) else {
            slot.invalidate(.unstable); return
          }
          slot.candidate = .init(requestID: slot.requestID, playerID: player, requestedAt: slot.requestedAt,
            firstSource: slot.first!, lastSource: frame.source,
            firstCandidateID: slot.firstCandidateID!, lastCandidateID: p.candidateID!, presentationRevision: frame.presentationRevision,
            acceptedContextRevision: slot.fence!.accepted, sampleCount: slot.samples.count, values: median)
          slot.samples.removeAll(keepingCapacity: false); slot.phase = .ready
        }
      } else if let candidate = slot.candidate {
        let ref = candidate.values
        guard stable(values, relativeTo: ref, collecting: false) else { slot.invalidate(.perspectiveAmbiguous); return }
        slot.comparison = .init(playerID: player, referenceRequestID: candidate.requestID, source: frame.source, candidateID: p.candidateID!,
          presentationRevision: frame.presentationRevision, acceptedContextRevision: slot.fence!.accepted,
          leftExtentRatioToNeutral: values.left / ref.left, rightExtentRatioToNeutral: values.right / ref.right,
          bilateralExtentRatioToNeutral: values.bilateral / ref.bilateral,
          torsoLeanDeltaRadians: values.lean - ref.lean, shoulderRollDeltaRadians: values.roll - ref.roll,
          confidence: min(values.confidence, ref.confidence))
      }
      slot.last = frame.source
    } catch { slot.invalidate(.unsupportedFeatures) }
  }

  private func stable(_ v: VisualNeutralValues, relativeTo r: VisualNeutralValues, collecting: Bool) -> Bool {
    let common = abs(v.torso / r.torso - 1) <= policy.relativeTolerance
      && abs(v.shoulderY - r.shoulderY) <= policy.centerTolerance
      && abs(v.hipY - r.hipY) <= policy.centerTolerance
      && abs(v.lean - r.lean) <= policy.angleTolerance && abs(v.roll - r.roll) <= policy.angleTolerance
      && abs(v.left / v.right - r.left / r.right) <= policy.asymmetryTolerance
    return common && (!collecting || (abs(v.left / r.left - 1) <= policy.relativeTolerance
      && abs(v.right / r.right - 1) <= policy.relativeTolerance))
  }
}
