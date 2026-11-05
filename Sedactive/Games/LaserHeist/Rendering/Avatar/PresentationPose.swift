//
//  PresentationPose.swift
//  Sedactive
//

import Foundation

// PROPOSED presentation-only pose interface (Kevin → Edo). Not part of CP1 or
// CP2, never used for judgement, and no producer exists yet.
//
// CP1's `BodySnapshot` gives the avatar crown, both wrist heights, both sole
// heights, centre X and jump phase. That drives JUMP, DUCK, per-leg lift,
// lateral movement and frontal-plane arm raises. It cannot tell an arm raised
// sideways from one raised forward, or show lean and head tilt. Edo's raw
// Vision `PoseFrame` already carries the needed joints (shoulders, wrists,
// hips, ears, nose, ankles; elbows and knees would need adding to his joint
// table). This interface asks for them converted to the same player plane,
// for the same frames as the `BodySnapshot`.
//
// Rules, matching CP1: unmirrored player-plane game units with Y up from the
// calibrated floor; anatomical left/right unchanged (the display mirrors once);
// missing joints are absent, never guessed; one frame per snapshot frame.

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
