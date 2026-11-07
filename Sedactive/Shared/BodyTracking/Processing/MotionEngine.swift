import Foundation

/// Approved 7 November 2026 for controlled numeric diagnostics only; never production thresholds.
nonisolated enum B2bExperimentalPolicyV1 {
  static let version = "B2bExperimentalPolicyV1"
  static var value: PlayerTrackingPolicy {
    PlayerTrackingPolicy(minimumJointConfidence: 0.5, minimumTorsoExtent: 0.02,
      minimumPairSeparation: 0.12, centerGuardFraction: 0.04, acquisitionDwell: 0.125,
      recoveryDwell: 0.125, maximumObservationGap: 1.0, recoveryWindow: 2.0,
      freshness: 0.5, maximumSpeed: 0.5, positionGate: 0.15, jointResidualGate: 0.22,
      maximumLogScaleChange: 0.35, positionWeight: 0.4, jointWeight: 0.4, shapeWeight: 0.2,
      missingEvidencePenalty: 0.3, unmatchedCost: 2.0, assignmentMargin: 0.15,
      minimumSharedCoreJoints: 3)
  }
}

/// Exactly one committed value on CameraCopySink. Copies below are disposable transactions,
/// not independently live trackers. No raw buffers, Vision, calibration or gameplay authority.
nonisolated struct MotionEngine: Sendable {
  private(set) var tracker: PlayerTracker
  private var revision: UInt64 = 0
  private var context: PlayerTrackingContext?
  private(set) var appliedExpiry: Double = 0
  init(policy: PlayerTrackingPolicy) throws { tracker = try PlayerTracker(policy: policy) }

  mutating func synchronize(_ control: CameraTrackingControl) throws -> PlayerTrackingSnapshot? {
    if control.requestID == nil, control.revision > revision {
      try tracker.invalidate(controlRevision: control.revision)
      revision = control.revision
      context = nil
      appliedExpiry = 0
      return nil
    }
    guard revision == control.revision, context != nil, control.watermark > appliedExpiry else {
      return nil
    }
    let result = try tracker.expire(at: control.watermark, controlRevision: revision)
    appliedExpiry = control.watermark
    return result
  }

  func staged(_ result: CameraPoseResult, admission: CameraTrackingAdmission) throws -> Self {
    var copy = self
    let source = try copy.prepare(result.source, admission: admission)
    _ = try copy.tracker.process(.init(source: source, frame: result.frame,
      observationCount: result.observationCount))
    return copy
  }
  func stagedFailure(_ metadata: CameraFrameMetadata, admission: CameraTrackingAdmission)
    throws -> Self {
    var copy = self
    let source = try copy.prepare(metadata, admission: admission)
    _ = try copy.tracker.inferenceFailed(source: source)
    return copy
  }
  private mutating func prepare(_ source: CameraFrameMetadata,
    admission: CameraTrackingAdmission) throws -> PlayerTrackingSource {
    guard admission.context == source.context, admission.requestID != nil else {
      throw PlayerTrackingError.staleControl
    }
    let c = PlayerTrackingContext(generation: source.context.generation, epoch: source.context.epoch,
      geometryRevision: source.context.geometryRevision, imageWidth: source.descriptor.width,
      imageHeight: source.descriptor.height, rotationAngle: source.rotationAngle,
      mirrored: source.mirrored)
    if admission.revision != revision {
      try tracker.reset(context: c, controlRevision: admission.revision)
      revision = admission.revision
      context = c
      appliedExpiry = 0
      try tracker.armBinding(controlRevision: revision)
    }
    guard context == c else { throw PlayerTrackingError.incompatibleSource }
    return .init(context: c, frameID: source.frameID, capturedAt: source.capturedAt,
      controlRevision: admission.revision)
  }
}
