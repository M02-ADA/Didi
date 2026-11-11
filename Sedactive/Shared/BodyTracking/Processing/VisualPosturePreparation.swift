#if DEBUG
import Foundation

/// Experimental projected-image features ONLY. Never EstimatedScalar/BodyGeometry, standing
/// calibration, a crouch verdict or airborne evidence. No new E07/D06 packet fields.
nonisolated enum VisualPostureRefusal: String, Error, Sendable {
  case inactive, invalidPacket, invalidTiming, stale
  case unbound, uncertain, lost, rebindRequired, notObserved
  case missingJoint, lowConfidence, degenerateTorso, unresolvedLegProjection
}
nonisolated struct ExperimentalPostureScalar: Equatable, Sendable {
  let value: Double?
  /// Minimum actual observed confidence of the joints used; not probability of a posture.
  let confidence: Double?
  let refusal: VisualPostureRefusal?
  private init(value: Double?, confidence: Double?, refusal: VisualPostureRefusal?) {
    self.value = value; self.confidence = confidence; self.refusal = refusal
  }
  static func refused(_ reason: VisualPostureRefusal) -> Self {
    .init(value: nil, confidence: nil, refusal: reason)
  }
  static func experimental(_ value: Double, confidence: Double) -> Self {
    guard value.isFinite, confidence.isFinite else { return .refused(.degenerateTorso) }
    return .init(value: value, confidence: confidence, refusal: nil)
  }
}
nonisolated struct ExperimentalPlayerPosture: Equatable, Sendable {
  let playerID: PlayerID
  let candidateID: UInt64? // same-frame association only, never a persistent identity
  let trackingState: PlayerTrackingState
  let requiresRebind: Bool
  let shoulderCenterY, hipCenterY, torsoLength: ExperimentalPostureScalar
  /// Canonical image-right inclination, radians; aspect corrected, not a 3D bend angle.
  let torsoLeanRadians, shoulderRollRadians: ExperimentalPostureScalar
  /// Each hip-to-ankle vertical projection divided by THIS frame's torso length.
  /// Ankles remain ankles: no sole/floor/contact interpretation and no standing reference.
  let leftLegExtentOverTorso, rightLegExtentOverTorso: ExperimentalPostureScalar
  /// max(left,right), only with both usable and non-crossed 2D support. Lower values may
  /// describe bilateral compression, NOT a calibrated 0...1 crouch amount or a squat verdict.
  let bilateralExtentOverTorso: ExperimentalPostureScalar
}
nonisolated struct ExperimentalVisualPostureFrame: Equatable, Sendable {
  let source: PlayerTrackingSource // original generation/epoch/geometry/frame/capture/control
  let presentationRevision: UInt64
  let player1, player2: ExperimentalPlayerPosture
  subscript(_ id: PlayerID) -> ExperimentalPlayerPosture { id == .player1 ? player1 : player2 }

  /// Reread the existing E07 drain every tick. A cached status is not continuing permission.
  /// Calibration/control cutovers already advance this existing presentation fence.
  func isCurrent(in status: VisionNumericPoseStatus?, at time: Double, maximumAge: Double) -> Bool {
    guard VisualPosturePreparation.validClock(time, maximumAge), let status, status.active,
      status.context == source.context, status.revision == presentationRevision,
      status.controlRevision == source.controlRevision, source.capturedAt.isFinite, source.capturedAt >= 0,
      time >= source.capturedAt,
      time - source.capturedAt < maximumAge else { return false }
    return true
  }
}
nonisolated struct ExperimentalVisualPostureBatch: Sendable {
  let status: VisionNumericPoseStatus?
  let resetAll: Bool
  let frame: ExperimentalVisualPostureFrame? // nil between camera frames, no fake new observation
  let refusal: VisualPostureRefusal?

  /// Pure latest-only render handoff. Retains nothing itself. Never combines fields from
  /// different captures: choose one complete fresh frame or unavailable. Reset BEFORE apply.
  func resolve(held: ExperimentalVisualPostureFrame?, at time: Double,
    maximumAge: Double) -> ExperimentalVisualPostureFrame? {
    guard refusal == nil else { return nil }
    let candidate = frame ?? (resetAll ? nil : held)
    guard let candidate, candidate.isCurrent(in: status, at: time, maximumAge: maximumAge) else { return nil }
    if let frame, let held, !resetAll, held.isCurrent(in: status, at: time, maximumAge: maximumAge) {
      guard frame.source.frameID > held.source.frameID,
        frame.source.capturedAt > held.source.capturedAt else { return nil }
    }
    return candidate
  }
}

/// Vision-owned pure preparation on the SAME E07 drain already read by the App pump.
/// No gate, consumer, task, baseline, mutable tracker or renderer state. Not automatically
/// wired into K03: its visual-only field mapping still requires Kevin's agreement.
nonisolated enum VisualPosturePreparation {
  static func validClock(_ time: Double, _ maximumAge: Double) -> Bool {
    time.isFinite && time >= 0 && maximumAge.isFinite && maximumAge > 0
      && maximumAge <= B2bExperimentalPolicyV1.value.freshness
  }
  static func prepare(_ delivery: VisionNumericPoseDrain?, at time: Double,
    maximumAge: Double) -> ExperimentalVisualPostureBatch {
    func refused(_ reason: VisualPostureRefusal) -> ExperimentalVisualPostureBatch {
      .init(status: delivery?.status, resetAll: true, frame: nil, refusal: reason)
    }
    guard validClock(time, maximumAge) else { return refused(.invalidTiming) }
    guard let delivery, delivery.status.active else { return refused(.inactive) }
    do {
      // Reuse the accepted E07 exact-source/control/pose/association validation. No
      // independently read latest snapshot and no change to that adapter or its contract.
      let batch = try VisionAvatarPacketAdapter.map(delivery, using: PostureFeatureFactory.self)
      if let frame = batch.output, !frame.isCurrent(in: batch.status, at: time, maximumAge: maximumAge) {
        return refused(.stale)
      }
      return .init(status: batch.status, resetAll: batch.resetAll, frame: batch.output, refusal: nil)
    } catch { return refused(.invalidPacket) }
  }

  fileprivate static func measure(_ id: PlayerID, slot: PlayerTrackingSlotResult,
    candidates: [PoseCandidate], width: Int, height: Int) -> ExperimentalPlayerPosture {
    func sample(_ reason: VisualPostureRefusal) -> ExperimentalPlayerPosture {
      let missing = ExperimentalPostureScalar.refused(reason)
      return .init(playerID: id, candidateID: slot.state == .tracking && !slot.requiresRebind ? slot.candidateID : nil,
        trackingState: slot.state, requiresRebind: slot.requiresRebind,
        shoulderCenterY: missing, hipCenterY: missing, torsoLength: missing,
        torsoLeanRadians: missing, shoulderRollRadians: missing,
        leftLegExtentOverTorso: missing, rightLegExtentOverTorso: missing, bilateralExtentOverTorso: missing)
    }
    guard !slot.requiresRebind else { return sample(.rebindRequired) }
    switch slot.state {
    case .unbound: return sample(.unbound)
    case .uncertain: return sample(.uncertain)
    case .lost: return sample(.lost)
    case .tracking: break
    }
    guard let candidate = candidates.first(where: { $0.candidateID == slot.candidateID }) else {
      return sample(.notObserved)
    }
    func point(_ name: BodyJoint) throws -> PoseJoint {
      guard let p = candidate.joints[name] else { throw VisualPostureRefusal.missingJoint }
      guard (try? p.validate()) != nil else { throw VisualPostureRefusal.invalidPacket }
      // Reuse the unchanged 0.5 observed-joint gate; not a new accepted tracking threshold.
      guard p.confidence >= B2bExperimentalPolicyV1.value.minimumJointConfidence else {
        throw VisualPostureRefusal.lowConfidence
      }
      return p
    }
    do {
      let ls = try point(.leftShoulder), rs = try point(.rightShoulder)
      let lh = try point(.leftHip), rh = try point(.rightHip)
      let aspect = Double(width) / Double(height)
      let sy = (ls.y + rs.y) / 2, hy = (lh.y + rh.y) / 2
      let dx = ((ls.x + rs.x) / 2 - (lh.x + rh.x) / 2) * aspect
      let dy = sy - hy, torso = hypot(dx, dy)
      // Subpixel or inverted projected torsos cannot support stable normalization.
      // This is source-resolution arithmetic, not an anthropometric/body-size threshold.
      guard dy > 0, torso * Double(height) > 1 else { return sample(.degenerateTorso) }
      let confidence = min(min(ls.confidence, rs.confidence), min(lh.confidence, rh.confidence))
      func value(_ x: Double) -> ExperimentalPostureScalar { .experimental(x, confidence: confidence) }
      let imageLeft = ls.x < rs.x ? ls : rs, imageRight = ls.x < rs.x ? rs : ls
      let roll: ExperimentalPostureScalar = abs(ls.x - rs.x) * Double(width) >= 1
        ? value(atan2(imageRight.y - imageLeft.y, (imageRight.x - imageLeft.x) * aspect))
        : .refused(.degenerateTorso)
      func leg(_ ankle: BodyJoint, hip: PoseJoint) -> ExperimentalPostureScalar {
        do {
          let a = try point(ankle), span = hip.y - a.y
          guard span * Double(height) > 1 else { return .refused(.unresolvedLegProjection) }
          return .experimental(span / torso, confidence: min(confidence, a.confidence))
        } catch let reason as VisualPostureRefusal { return .refused(reason) }
        catch { return .refused(.invalidPacket) }
      }
      let left = leg(.leftAnkle, hip: lh), right = leg(.rightAnkle, hip: rh)
      let bilateral: ExperimentalPostureScalar
      if let l = left.value, let r = right.value,
        let la = candidate.joints[.leftAnkle], let ra = candidate.joints[.rightAnkle],
        abs(lh.x - rh.x) * Double(width) >= 1, abs(la.x - ra.x) * Double(width) >= 1,
        (lh.x - rh.x) * (la.x - ra.x) > 0 {
        bilateral = .experimental(max(l, r), confidence: min(left.confidence!, right.confidence!))
      } else {
        bilateral = .refused(left.refusal ?? right.refusal ?? .unresolvedLegProjection)
      }
      return .init(playerID: id, candidateID: candidate.candidateID,
        trackingState: slot.state, requiresRebind: slot.requiresRebind,
        shoulderCenterY: value(sy), hipCenterY: value(hy), torsoLength: value(torso),
        torsoLeanRadians: value(atan2(dx, dy)), shoulderRollRadians: roll,
        leftLegExtentOverTorso: left, rightLegExtentOverTorso: right, bilateralExtentOverTorso: bilateral)
    } catch let reason as VisualPostureRefusal { return sample(reason) }
    catch { return sample(.invalidPacket) }
  }
}

nonisolated private enum PostureFeatureFactory: VisionAvatarPacketFactory {
  static func status(_ status: VisionNumericPoseStatus) -> VisionNumericPoseStatus { status }
  static func output(source: PlayerTrackingSource, revision: UInt64,
    player1: PlayerTrackingSlotResult, player2: PlayerTrackingSlotResult,
    candidates: [PoseCandidate], calibration: [PlayerID: VisionAvatarCalibrationValues]) -> ExperimentalVisualPostureFrame {
    // Accepted calibration inputs deliberately unused. No visual feature can accept a reference.
    .init(source: source, presentationRevision: revision,
      player1: VisualPosturePreparation.measure(.player1, slot: player1, candidates: candidates,
        width: source.context.imageWidth, height: source.context.imageHeight),
      player2: VisualPosturePreparation.measure(.player2, slot: player2, candidates: candidates,
        width: source.context.imageWidth, height: source.context.imageHeight))
  }
}

#endif
