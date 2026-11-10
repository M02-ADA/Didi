import Foundation

/// Internal E07 seam, NOT the frozen D06 packet and never a gameplay stream.
nonisolated struct VisionPoseAttachment: Equatable, Sendable { fileprivate let id: UUID }
nonisolated struct VisionNumericPoseOutput: Sendable {
  let presentationRevision: UInt64 // originally stamped at admission, never assigned after inference
  let tracking: PlayerTrackingSnapshot
  let pose: PoseFrame // original 14-joint vocabulary, absent keys and confidence unchanged
  let acceptedCalibrations: [PlayerID: PlayerCalibration]
  let cutovers: [PlayerID: BodyInputCutover]
  let layout: PlayerPlaneLayout?
}
nonisolated struct VisionNumericPoseStatus: Sendable {
  let revision: UInt64
  let active: Bool
  let context: PlayerTrackingContext?
  let controlRevision: UInt64
  let acceptedContextRevision: UInt64
  let layout: PlayerPlaneLayout?
  let calibrationRevisions: [PlayerID: UInt64]
  let cutovers: [PlayerID: BodyInputCutover]
}
nonisolated struct VisionNumericPoseDrain: Sendable {
  let status: VisionNumericPoseStatus
  /// Sticky across coalescing until drained. Consumer clears held poses/filters before applying output.
  let resetAll: Bool
  let output: VisionNumericPoseOutput?
}

/// Accessed ONLY under CameraTrackingGate. No lock/callback/task/consumer or tracking authority.
nonisolated struct VisionNumericPoseChannel: Sendable {
  private(set) var revision: UInt64 = 0
  private var attachment: VisionPoseAttachment?
  private var context: PlayerTrackingContext?
  private var active = false
  private var resetAll = false
  private var pending: VisionNumericPoseOutput?
  private var lastFrame: UInt64 = 0
  private var lastCapture: Double? // ordering watermark, retained across invalidation
  private var freshFrom: Double? // capture-clock anchor for the current active presentation epoch
  private var exhausted = false
  private mutating func advance() {
    if revision == .max { exhausted = true } else { revision += 1 }
  }
  mutating func invalidate() {
    advance(); active = false; pending = nil; resetAll = true
  }
  /// Session teardown retires the lease, not only its current pose. Reattach for Retry.
  mutating func endSession() {
    invalidate(); attachment = nil; context = nil; lastFrame = 0; lastCapture = nil; freshFrom = nil
  }
  mutating func attach() throws -> VisionPoseAttachment {
    guard !exhausted, revision < .max else { throw LiveVisionError.revisionExhausted }
    invalidate()
    let lease = VisionPoseAttachment(id: UUID()); attachment = lease
    return lease
  }
  mutating func cancel(_ lease: VisionPoseAttachment) {
    guard attachment == lease else { return }
    invalidate(); attachment = nil
  }
  mutating func admit(_ source: CameraFrameMetadata, authorized: Bool) -> UInt64? {
    guard attachment != nil, !exhausted else { return nil }
    let c = PlayerTrackingContext(generation: source.context.generation, epoch: source.context.epoch,
      geometryRevision: source.context.geometryRevision, imageWidth: source.descriptor.width,
      imageHeight: source.descriptor.height, rotationAngle: source.rotationAngle, mirrored: source.mirrored)
    if context != c || active != authorized {
      invalidate()
      if context != c { lastFrame = 0; lastCapture = nil }
      // A fresh admitted epoch must survive render ticks during inference. No old pose is
      // reused: invalidate already cleared pending and retained the sticky reset/watermark.
      context = c; active = authorized; freshFrom = source.capturedAt
    }
    return !exhausted ? revision : nil
  }
  mutating func publish(_ pose: CameraPoseResult, receipt: PlayerTrackingSnapshot,
    admission: CameraTrackingAdmission, body: LiveBodyInputState) {
    guard attachment != nil, !exhausted, active, admission.presentationRevision == revision,
      let original = receipt.source, original.context == context,
      original.frameID == pose.source.frameID, original.capturedAt == pose.source.capturedAt,
      original.controlRevision == admission.revision, receipt.controlRevision == admission.revision,
      pose.matchesSource, (try? pose.frame.validate()) != nil,
      pose.frame.candidates.count <= PoseEstimator.maximumCandidates,
      original.frameID > lastFrame, lastCapture.map({ original.capturedAt > $0 }) ?? true else { return }
    let available = PlayerID.allCases.filter { receipt[$0].state == .tracking && !receipt[$0].requiresRebind }
    let ids = available.compactMap { receipt[$0].candidateID }
    guard ids.count == available.count, Set(ids).count == ids.count,
      ids.allSatisfy({ id in pose.frame.candidates.contains { $0.candidateID == id } }) else { return }
    var accepted: [PlayerID: PlayerCalibration] = [:]
    if body.source == pose.source.context {
      for (id, value) in body.configuration?.calibrations ?? [:] {
        let cut = body.cutovers[id]
        if value.sessionGeneration == original.context.generation,
          value.cameraGeometryRevision == original.context.geometryRevision,
          cut.map({ original.frameID > $0.frameID && original.capturedAt > $0.capturedAt }) ?? false {
          accepted[id] = value
        }
      }
    }
    pending = .init(presentationRevision: revision, tracking: receipt, pose: pose.frame,
      acceptedCalibrations: accepted, cutovers: body.cutovers,
      layout: accepted.isEmpty ? nil : body.configuration?.playerPlaneLayout)
    lastFrame = original.frameID; lastCapture = original.capturedAt; freshFrom = original.capturedAt
  }
  mutating func drain(_ lease: VisionPoseAttachment, time: Double, freshness: Double,
    controlRevision: UInt64, body: LiveBodyInputState) -> VisionNumericPoseDrain? {
    guard attachment == lease else { return nil }
    if active, let freshFrom, !time.isFinite || time < freshFrom || time - freshFrom >= freshness {
      invalidate() // no fake frame, watermark preserved
    }
    let status = VisionNumericPoseStatus(revision: revision, active: active && !exhausted,
      context: context, controlRevision: controlRevision, acceptedContextRevision: body.acceptedRevision,
      layout: body.configuration?.calibrations.isEmpty == false ? body.configuration?.playerPlaneLayout : nil,
      calibrationRevisions: body.configuration?.calibrations.mapValues(\.revision) ?? [:], cutovers: body.cutovers)
    let result = VisionNumericPoseDrain(status: status, resetAll: resetAll, output: active ? pending : nil)
    pending = nil; resetAll = false
    return result
  }
}

/// App-owned adapter can be polled by Kevin's existing render tick. No subscriber to CP1.
/// Drain status/reset BEFORE projecting any output. Cached values must be rechecked every tick.
nonisolated final class VisionNumericPoseBridge: Sendable {
  private let gate: CameraTrackingGate
  init(gate: CameraTrackingGate) { self.gate = gate }
  func attach() throws -> VisionPoseAttachment { try gate.attachPresentation() }
  func drain(_ attachment: VisionPoseAttachment) -> VisionNumericPoseDrain? { gate.drainPresentation(attachment) }
  func cancel(_ attachment: VisionPoseAttachment) { gate.cancelPresentation(attachment) }
}
