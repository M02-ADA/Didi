import CoreVideo
import Foundation
import Vision

// Capture-internal seam. Implementations and their CV/VN objects never leave the processing actor.
nonisolated protocol CameraPoseDetecting: AnyObject {
  func detect(in buffer: CVPixelBuffer) throws -> CameraPoseObservations
}
nonisolated struct CameraPoseObservations: Sendable {
  let totalCount: Int
  let joints: [[BodyJoint: PoseJoint]]
}
nonisolated struct CameraPoseResult: Sendable {
  let source: CameraFrameMetadata  // Includes epoch and already-applied orientation; not added to CP1.
  let frame: PoseFrame
  let observationCount: Int
  let invalidJointCount: Int
  var matchesSource: Bool {
    frame.sessionGeneration == source.context.generation && frame.frameID == source.frameID
      && frame.capturedAt == source.capturedAt
      && frame.cameraGeometryRevision == source.context.geometryRevision
      && frame.imageWidth == source.descriptor.width && frame.imageHeight == source.descriptor.height
      && !source.mirrored && (source.rotationAngle == 0 || source.rotationAngle == 180)
      && observationCount >= frame.candidates.count && invalidJointCount >= 0
  }
}
nonisolated enum CameraPoseError: Error { case incompatibleSource, invalidResult }

/// Worker-confined synchronous Vision adapter. No completion block, mutable request or CV escapes.
nonisolated final class PoseEstimator: CameraPoseDetecting {
  static let maximumCandidates = 8  // Bounded raw candidates, not two selected/tracked players.
  static let joints: [(BodyJoint, VNHumanBodyPoseObservation.JointName)] = [
    (.nose, .nose), (.leftEye, .leftEye), (.rightEye, .rightEye),
    (.leftEar, .leftEar), (.rightEar, .rightEar), (.neck, .neck),
    (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
    (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
    (.leftHip, .leftHip), (.rightHip, .rightHip),
    (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle),
    (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
  ]
  func detect(in buffer: CVPixelBuffer) throws -> CameraPoseObservations {
    try autoreleasepool {
      let request = VNDetectHumanBodyPoseRequest()
      // Source pixels have already been rotated upright by the capture connection; never rotate twice.
      let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
      try handler.perform([request])
      let observations = request.results ?? []
      let values = try observations.prefix(Self.maximumCandidates).map { observation in
        let points = try observation.recognizedPoints(.all)
        var result: [BodyJoint: PoseJoint] = [:]
        for (joint, name) in Self.joints {
          if let point = points[name] {
            result[joint] = PoseJoint(
              x: Double(point.location.x), y: Double(point.location.y),
              confidence: Double(point.confidence))
          }
        }
        return result
      }
      return CameraPoseObservations(totalCount: observations.count, joints: values)
    }
  }
}

/// Numeric conversion is testable without constructing VNObservation or inventing live mock results.
nonisolated enum CameraPoseAdapter {
  static func convert(_ observations: CameraPoseObservations, source: CameraFrameMetadata) throws
    -> CameraPoseResult
  {
    guard !source.mirrored, source.rotationAngle == 0 || source.rotationAngle == 180,
      observations.totalCount >= observations.joints.count,
      observations.joints.count <= PoseEstimator.maximumCandidates,
      observations.joints.count == min(observations.totalCount, PoseEstimator.maximumCandidates)
    else { throw CameraPoseError.incompatibleSource }
    var invalid = 0
    let candidates = observations.joints.enumerated().map { index, points in
      var valid: [BodyJoint: PoseJoint] = [:]
      for (joint, point) in points {
        // Zero confidence means unobserved. Low but positive confidence is retained as raw evidence.
        if point.x.isFinite, point.y.isFinite, point.confidence.isFinite,
          (0...1).contains(point.x), (0...1).contains(point.y),
          point.confidence > 0, point.confidence <= 1
        { valid[joint] = point } else { invalid += 1 }
      }
      return PoseCandidate(
        candidateID: UInt64(index), joints: valid,
        maskTopImageY: nil, maskBottomImageY: nil,
        leftFootBottomImageY: nil, rightFootBottomImageY: nil, maskAssociation: .unavailable)
    }
    let frame = PoseFrame(
      sessionGeneration: source.context.generation, frameID: source.frameID,
      capturedAt: source.capturedAt, cameraGeometryRevision: source.context.geometryRevision,
      imageWidth: source.descriptor.width, imageHeight: source.descriptor.height,
      candidates: candidates)
    try frame.validate()
    return CameraPoseResult(
      source: source, frame: frame, observationCount: observations.totalCount,
      invalidJointCount: invalid)
  }
}
