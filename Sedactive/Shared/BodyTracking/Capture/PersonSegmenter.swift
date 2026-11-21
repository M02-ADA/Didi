import CoreVideo
import Foundation
import Vision

/// Internal same-frame output. Labels have no identity across frames. No image leaves the worker.
nonisolated enum PersonMaskQuality: String, Sendable {
  case torsoSupportedGeometryUnverified, insufficientEvidence, unsupportedOutput, requestFailed
}
nonisolated struct PersonMaskRegion: Equatable, Sendable {
  let candidateID: UInt64
  let label: UInt8
  let minX: Double, maxX: Double, minY: Double, maxY: Double
}
nonisolated struct PersonMaskObservation: Sendable {
  let source: CameraFrameMetadata
  let quality: PersonMaskQuality
  let regions: [PlayerID: PersonMaskRegion]
  let outputBytes: Int
  let serviceSeconds: Double
  var anatomy: [PlayerID: AnatomicalPlayerCandidate] = [:]
  /// Rows in the native instance mask the anatomy was read from (its Y quantization).
  var maskHeight: Int? = nil
  #if DEBUG
  var associationDiagnostics = MaskAssociationDiagnostics()
  #endif
  // Native labels do NOT establish crown or separate anatomical soles.
}
nonisolated protocol PersonMaskDetecting: AnyObject {
  func detect(in buffer: CVPixelBuffer, pose: CameraPoseResult,
    association: PlayerTrackingSnapshot) throws -> PersonMaskObservation
}
nonisolated enum PersonMaskError: Error { case unsupportedOutput }

/// Full-frame revision-1 request, synchronous on CameraCopySink, never a new consumer.
/// Native OneComponent8 is an explicit restrictive whitelist, NOT an SDK format guarantee.
nonisolated final class PersonSegmenter: PersonMaskDetecting {
  #if DEBUG
  // Set and cleared synchronously by CameraCopySink for one explicitly requested frame.
  var anatomyInspectionImages: AnatomyInspectionImageBuilder?
  #endif
  static let maximumOutputBytes = 4 * 1024 * 1024
  private let onOwnedBytes: @Sendable (Int) -> Void
  init(onOwnedBytes: @escaping @Sendable (Int) -> Void = { _ in }) { self.onOwnedBytes = onOwnedBytes }
  func detect(in buffer: CVPixelBuffer, pose: CameraPoseResult,
    association: PlayerTrackingSnapshot) throws -> PersonMaskObservation {
    let start = CameraHostClock.now()
    defer { onOwnedBytes(0) } // after autoreleasepool and all native request/output owners exit
    return try autoreleasepool {
      let request = VNGeneratePersonInstanceMaskRequest()
      request.revision = VNGeneratePersonInstanceMaskRequestRevision1
      let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
      try handler.perform([request])
      // At least one instance per linked player (two in co-op, one in a DEBUG Solo Test). Other
      // people may be in view: each linked player is found by their own torso (`associate`),
      // and a bystander's instance never contributes a pixel to a player's measurements.
      let roster = Self.linkedRoster(association)
      guard !roster.isEmpty, let observations = request.results, observations.count == 1,
        let observation = observations.first, observation.allInstances.count >= roster.count,
        observation.allInstances.allSatisfy({ $0 > 0 && $0 <= 255 }) else {
        var refused = PersonMaskObservation(source: pose.source, quality: .insufficientEvidence, regions: [:],
          outputBytes: 0, serviceSeconds: CameraHostClock.now() - start)
        #if DEBUG
        refused.associationDiagnostics.global = "nativeInstanceCountOrResults"
        refused.associationDiagnostics.instanceCount = request.results?.first?.allInstances.count
        #endif
        return refused
      }
      let mask = observation.instanceMask
      onOwnedBytes(CVPixelBufferGetDataSize(mask))
      let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)
      let stride = CVPixelBufferGetBytesPerRow(mask)
      let (bytes, overflow) = stride.multipliedReportingOverflow(by: h)
      guard !CVPixelBufferIsPlanar(mask),
        CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8,
        w > 0, h > 0, w <= pose.frame.imageWidth, h <= pose.frame.imageHeight,
        stride >= w, !overflow, bytes > 0, bytes <= Self.maximumOutputBytes,
        CVPixelBufferGetDataSize(mask) <= Self.maximumOutputBytes,
        CVPixelBufferLockBaseAddress(mask, .readOnly) == kCVReturnSuccess else {
        throw PersonMaskError.unsupportedOutput
      }
      defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
      guard let base = CVPixelBufferGetBaseAddress(mask) else { throw PersonMaskError.unsupportedOutput }
      let labels = observation.allInstances.map { UInt8($0) }
      // Bounded four scalars per label; no mask copy or coordinate history.
      var bounds = labels.map { _ in [w, -1, h, -1] }
      for y in 0..<h {
        let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<w {
          let label = row[x]
          guard label == 0 || labels.contains(label) else { throw PersonMaskError.unsupportedOutput }
          if let i = labels.firstIndex(of: label) {
            bounds[i][0] = min(bounds[i][0], x); bounds[i][1] = max(bounds[i][1], x)
            bounds[i][2] = min(bounds[i][2], y); bounds[i][3] = max(bounds[i][3], y)
          }
        }
      }
      onOwnedBytes(max(bytes, CVPixelBufferGetDataSize(mask)))
      let result = Self.associate(pose: pose, association: association, labels: labels,
        bounds: bounds, width: w, height: h) { x, y in
          base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)[x]
        }
      #if DEBUG
      anatomyInspectionImages?.captureMask(source: pose.source, width: w, height: h,
        stride: stride, format: CVPixelBufferGetPixelFormatType(mask), base: base)
      #endif
      var anatomy: [PlayerID: AnatomicalPlayerCandidate] = [:]
      for (id, region) in result {
        if let candidate = pose.frame.candidates.first(where: { $0.candidateID == region.candidateID }) {
          anatomy[id] = BodyMeasurementExtractor.experimentalAnatomy(source: pose.source,
            controlRevision: association.controlRevision, candidate: candidate, region: region,
            width: w, height: h) { x, y in
              base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)[x]
            }
        }
      }
      var output = PersonMaskObservation(source: pose.source,
        quality: result.count == roster.count ? .torsoSupportedGeometryUnverified : .insufficientEvidence,
        regions: result, outputBytes: max(bytes, CVPixelBufferGetDataSize(mask)),
        serviceSeconds: CameraHostClock.now() - start, anatomy: anatomy, maskHeight: h)
      #if DEBUG
      output.associationDiagnostics = Self.diagnoseAssociation(pose: pose, association: association,
        labels: labels, bounds: bounds, width: w, height: h, result: result) { x, y in
          base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)[x]
        }
      #endif
      return output
    }
  }

  /// Explicit provisional lower-left Vision -> top-row CV transform. Optical alignment remains
  /// UNVERIFIED; these diagnostic regions cannot become authoritative anatomy/calibration.
  ///
  /// Each linked player's instance is the one under all four of THEIR torso joints. Other people
  /// (bystanders, outside the boxes or not) are allowed in view, but a player's instance must be
  /// shown to be theirs alone, or that player gets no region this frame (refused as not
  /// separated), never a measurement that may include someone else:
  /// - every person Vision saw must be a pose candidate (none omitted by the candidate cap), so
  ///   nobody in view is unchecked;
  /// - each other person is located by EVERY joint Vision observed for them, at any confidence
  ///   (a bystander half out of frame often has no confident torso); if any lands on a player's
  ///   instance, Vision may have merged them;
  /// - another person with no joint inside the image cannot be located, so nobody is admitted.
  ///
  /// Limit: a person Vision's pose request misses entirely is invisible here; if the mask merges
  /// such a person into a player, this check cannot tell (as before bystanders were allowed).
  static func associate(pose: CameraPoseResult, association: PlayerTrackingSnapshot,
    labels: [UInt8], bounds: [[Int]], width: Int, height: Int,
    labelAt: (Int, Int) -> UInt8) -> [PlayerID: PersonMaskRegion] {
    let roster = linkedRoster(association)
    guard !roster.isEmpty, pose.matchesSource, pose.frame.candidates.count >= roster.count,
      pose.observationCount == pose.frame.candidates.count,
      let original = association.source, original.frameID == pose.source.frameID,
      original.capturedAt == pose.source.capturedAt, original.controlRevision == association.controlRevision,
      original.context.generation == pose.source.context.generation,
      original.context.epoch == pose.source.context.epoch,
      original.context.geometryRevision == pose.source.context.geometryRevision,
      original.context.imageWidth == pose.frame.imageWidth,
      original.context.imageHeight == pose.frame.imageHeight,
      original.context.rotationAngle == pose.source.rotationAngle, !original.context.mirrored,
      width > 0, height > 0, labels.count >= roster.count, Set(labels).count == labels.count,
      !labels.contains(0), bounds.count == labels.count, bounds.allSatisfy({ $0.count == 4 }) else { return [:] }
    let players = Set(roster.compactMap { association[$0].candidateID })
    // Instances under any observed joint of someone who is not a linked player.
    var foreign: Set<UInt8> = []
    for other in pose.frame.candidates where !players.contains(other.candidateID) {
      let located = other.joints.values.compactMap { observedLabel($0, width: width, height: height, labelAt: labelAt) }
      guard !located.isEmpty else { return [:] } // cannot be located: separation unproven
      foreign.formUnion(located)
    }
    foreign.remove(0)
    var output: [PlayerID: PersonMaskRegion] = [:]
    for id in roster {
      let slot = association[id]
      guard slot.state == .tracking, !slot.requiresRebind,
        let candidate = pose.frame.candidates.first(where: { $0.candidateID == slot.candidateID })
      else { return [:] }
      var support: UInt8?
      for joint in [BodyJoint.leftShoulder, .rightShoulder, .leftHip, .rightHip] {
        guard let p = candidate.joints[joint], (try? p.validate()) != nil,
          p.confidence >= 0.5, p.x > 0, p.x < 1, p.y > 0, p.y < 1 else { return [:] }
        let x = Int(p.x * Double(width)), y = Int((1 - p.y) * Double(height))
        // Reject floating-point boundary rounding before accessing native mask memory.
        guard (0..<width).contains(x), (0..<height).contains(y) else { return [:] }
        let label = labelAt(x, y)
        guard labels.contains(label), support == nil || support == label else { return [:] }
        support = label
      }
      guard let support, let i = labels.firstIndex(of: support), bounds[i][1] >= bounds[i][0],
        bounds[i][3] >= bounds[i][2] else { return [:] }
      guard !foreign.contains(support) else { continue } // merged with another person: not separated
      let b = bounds[i]
      output[id] = .init(candidateID: candidate.candidateID, label: support,
        minX: Double(b[0]) / Double(width), maxX: Double(b[1] + 1) / Double(width),
        minY: 1 - Double(b[3] + 1) / Double(height), maxY: 1 - Double(b[2]) / Double(height))
    }
    guard roster.count == 1 || output[.player1]?.label != output[.player2]?.label else { return [:] }
    return output
  }

  /// The mask label under an observed joint (any positive confidence) inside the image, or nil.
  static func observedLabel(_ p: PoseJoint, width: Int, height: Int, labelAt: (Int, Int) -> UInt8) -> UInt8? {
    guard (try? p.validate()) != nil, p.confidence > 0, p.x > 0, p.x < 1, p.y > 0, p.y < 1 else { return nil }
    let x = Int(p.x * Double(width)), y = Int((1 - p.y) * Double(height))
    guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
    return labelAt(x, y)
  }

  /// The players the tracker has linked (co-op: both after binding; DEBUG Solo Test: P1 only,
  /// P2 never bound). Each needs its own person in the mask; nobody else may be in it.
  static func linkedRoster(_ association: PlayerTrackingSnapshot) -> [PlayerID] {
    PlayerID.allCases.filter { association[$0].state != .unbound }
  }
}

#if DEBUG
/// Optional same-worker hook, also injectable in focused worker fixtures. No request of its own.
nonisolated protocol AnatomyInspectionMaskDetecting: PersonMaskDetecting {
  var anatomyInspectionImages: AnatomyInspectionImageBuilder? { get set }
}
extension PersonSegmenter: AnatomyInspectionMaskDetecting {}
#endif

#if DEBUG
/// Latest scalar-only association diagnosis. Never used to admit a sample or weaken pair rules.
nonisolated struct MaskAssociationPlayerDiagnostic: Equatable, Sendable {
  var reason = "unobserved"
  var joint: BodyJoint?
  var confidence: Double?
  var label: UInt8?
}
nonisolated struct MaskAssociationDiagnostics: Equatable, Sendable {
  var global = "unobserved"
  var instanceCount: Int?
  /// Pose candidates in view besides the linked players (bystanders), this frame.
  var otherPeople: Int?
  var players: [PlayerID: MaskAssociationPlayerDiagnostic] = [:]
}
extension PersonSegmenter {
  static func diagnoseAssociation(pose: CameraPoseResult, association: PlayerTrackingSnapshot,
    labels: [UInt8], bounds: [[Int]], width: Int, height: Int,
    result: [PlayerID: PersonMaskRegion], labelAt: (Int, Int) -> UInt8) -> MaskAssociationDiagnostics {
    var d = MaskAssociationDiagnostics(global: "contextOrRosterMismatch", instanceCount: labels.count)
    let roster = linkedRoster(association)
    // Mirror production preconditions to distinguish global refusal from per-player torso
    // support. Diagnostics never turn a refused production association into success.
    guard width > 0, height > 0 else { return d }
    let original = association.source
    d.otherPeople = max(0, pose.frame.candidates.count - roster.count)
    guard !roster.isEmpty, pose.matchesSource, pose.frame.candidates.count >= roster.count,
      pose.observationCount == pose.frame.candidates.count,
      original?.frameID == pose.source.frameID, original?.capturedAt == pose.source.capturedAt,
      original?.controlRevision == association.controlRevision,
      original?.context.generation == pose.source.context.generation,
      original?.context.epoch == pose.source.context.epoch,
      original?.context.geometryRevision == pose.source.context.geometryRevision,
      original?.context.imageWidth == pose.frame.imageWidth,
      original?.context.imageHeight == pose.frame.imageHeight,
      original?.context.rotationAngle == pose.source.rotationAngle, original?.context.mirrored == false,
      labels.count >= roster.count, Set(labels).count == labels.count, !labels.contains(0),
      bounds.count == labels.count, bounds.allSatisfy({ $0.count == 4 }) else { return d }
    d.global = result.count == roster.count ? "supported" : "pairAssociationRefused"
    for id in roster {
      let slot = association[id]
      var player = MaskAssociationPlayerDiagnostic(reason: "torsoSupportedPartnerRefused")
      if slot.state != .tracking || slot.requiresRebind {
        player.reason = "trackingOrRebind"
      } else if let c = pose.frame.candidates.first(where: { $0.candidateID == slot.candidateID }) {
        var support: UInt8?
        for j in [BodyJoint.leftShoulder, .rightShoulder, .leftHip, .rightHip] {
          player.joint = j; player.confidence = nil; player.label = nil
          guard let v = c.joints[j] else { player.reason = "torsoMissing"; break }
          player.confidence = v.confidence
          guard (try? v.validate()) != nil, v.x > 0, v.x < 1, v.y > 0, v.y < 1 else {
            player.reason = "torsoInvalidCoordinate"; break
          }
          guard v.confidence >= 0.5 else { player.reason = "torsoLowConfidence"; break }
          let x = Int(v.x * Double(width)), y = Int((1 - v.y) * Double(height))
          guard (0..<width).contains(x), (0..<height).contains(y) else {
            player.reason = "maskSamplingBounds"; break
          }
          let label = labelAt(x, y); player.label = label
          guard labels.contains(label) else { player.reason = "torsoBackgroundOrUnknownLabel"; break }
          guard support == nil || support == label else { player.reason = "torsoMixedLabels"; break }
          support = label
        }
        if player.reason == "torsoSupportedPartnerRefused", let support,
          let i = labels.firstIndex(of: support) {
          if bounds[i][1] < bounds[i][0] || bounds[i][3] < bounds[i][2] { player.reason = "invalidInstanceBounds" }
          else if result[id] != nil { player.reason = "supported" }
          else if d.otherPeople ?? 0 > 0 { player.reason = "mergedWithAnotherPerson" }
        }
      } else { player.reason = "candidateMissing" }
      d.players[id] = player
    }
    let supported = d.players.filter { $0.value.reason == "torsoSupportedPartnerRefused" }
    if supported.count == roster.count, Set(supported.values.compactMap(\.label)).count < roster.count {
      d.global = "sharedInstanceLabel"
      for id in roster { d.players[id]?.reason = "sharedInstanceLabel" }
    }
    return d
  }
}
#endif

extension PersonSegmenter {
  /// Loads Vision's person-instance-mask model before a calibration needs it. The first request in
  /// a process loads the model (iPad Pro 11" M5, 18 November 2026: 90.7 ms on an idle device,
  /// 111 ms in the app, against a 4–12 ms warm request), and inside a calibration attempt that
  /// first mask exceeds the 100 ms STOP/REVIEW budget and costs the attempt. One throwaway
  /// request on a small blank image, on a background queue: it never blocks the camera worker or
  /// the main actor, produces no evidence and changes no budget.
  static func warmUp() {
    DispatchQueue.global(qos: .userInitiated).async {
      var buffer: CVPixelBuffer?
      guard CVPixelBufferCreate(nil, 256, 144, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
        let buffer else { return }
      CVPixelBufferLockBaseAddress(buffer, [])
      if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, 0x80, CVPixelBufferGetDataSize(buffer)) }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      #if DEBUG
      let start = CameraHostClock.now()
      #endif
      autoreleasepool {
        let request = VNGeneratePersonInstanceMaskRequest()
        request.revision = VNGeneratePersonInstanceMaskRequestRevision1
        try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:]).perform([request])
      }
      #if DEBUG
      print(String(format: "[LaserSetupTiming] Vision mask warm-up %.1f ms (off the camera worker)", (CameraHostClock.now() - start) * 1000))
      #endif
    }
  }
}
