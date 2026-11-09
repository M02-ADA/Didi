//
//  PresentationPose.swift
//  Sedactive
//

import Foundation

// The retargeter's internal presentation joint names and points. Not an
// interface: production joints arrive as B1 `BodyJoint`s in `AvatarPoseFrame`
// (D06) and `AvatarPoseAdapter` converts them; B1 has no elbows or knees, so
// those keys are only ever filled by the DEBUG synthetic demo.
//
// `PresentationPoseSample`/`PresentationPoseFrame` (below) are the earlier
// spike's per-frame joint packet, kept DEBUG-only for the synthetic demo and
// its tests. D06 superseded them.

nonisolated enum PresentationJoint: String, CaseIterable, Sendable, Codable {
    case nose, leftEar, rightEar, neck
    case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle
}

nonisolated struct PresentationPoint: Equatable, Sendable, Codable {
    let x: Double
    let y: Double
    let confidence: Double
}

#if DEBUG
nonisolated struct PresentationPoseSample: Equatable, Sendable, Codable {
    let playerID: PlayerID
    let calibrationRevision: UInt64
    let joints: [PresentationJoint: PresentationPoint]

    /// A joint at or above `minimumConfidence`, else `nil`.
    func point(_ joint: PresentationJoint, minimumConfidence: Double = 0.3) -> PresentationPoint? {
        guard let point = joints[joint], point.confidence >= minimumConfidence,
              point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }
}

/// Joints for one camera frame; `frameID` and `capturedAt` equal the matching `BodySnapshot`'s.
nonisolated struct PresentationPoseFrame: Equatable, Sendable, Codable {
    let sessionGeneration: UUID
    let frameID: UInt64
    let capturedAt: Double
    let players: [PlayerID: PresentationPoseSample]

    /// Whether this frame belongs to `snapshot` (same generation and frame).
    func matches(_ snapshot: BodySnapshot) -> Bool {
        sessionGeneration == snapshot.sessionGeneration && frameID == snapshot.frameID
    }
}
#endif
