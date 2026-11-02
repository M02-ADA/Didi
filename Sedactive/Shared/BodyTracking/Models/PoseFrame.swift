//
//  PoseFrame.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation

nonisolated enum BodyJoint: String, Sendable, Codable {
    case nose, leftEye, rightEye, leftEar, rightEar, neck
    case leftShoulder, rightShoulder, leftWrist, rightWrist
    case leftHip, rightHip, leftAnkle, rightAnkle
}

nonisolated struct PoseJoint: Equatable, Sendable, Codable {
    let x: Double
    let y: Double
    let confidence: Double
    func validate() throws {
        for value in [x, y, confidence] {
            try requireBodyValue(value.isFinite && (0...1).contains(value), "normalized pose joint")
        }
    }
}

nonisolated enum MaskAssociation: String, Sendable, Codable { case matched, ambiguous, unavailable }

/// Candidate IDs are frame-local. Mask bounds are raw observations, not crown/sole estimates.
nonisolated struct PoseCandidate: Equatable, Sendable, Codable {
    let candidateID: UInt64
    let joints: [BodyJoint: PoseJoint]
    let maskTopImageY: Double?
    let maskBottomImageY: Double?
    let leftFootBottomImageY: Double?
    let rightFootBottomImageY: Double?
    let maskAssociation: MaskAssociation
}

/// Input must already be normalized upright/unmirrored; no image buffers or tracking algorithm.
nonisolated struct PoseFrame: Equatable, Sendable, Codable {
    let sessionGeneration: UUID
    let frameID: UInt64
    let capturedAt: Double
    let cameraGeometryRevision: UInt64
    let imageWidth: Int
    let imageHeight: Int
    let candidates: [PoseCandidate]

    func validate() throws {
        try requireBodyValue(capturedAt.isFinite && capturedAt >= 0 && cameraGeometryRevision > 0,
                             "pose frame metadata")
        try requireBodyValue(imageWidth > 0 && imageHeight > 0, "image dimensions")
        try requireBodyValue(Set(candidates.map(\.candidateID)).count == candidates.count, "candidate IDs")
        for candidate in candidates {
            for joint in candidate.joints.values { try joint.validate() }
            for y in [candidate.maskTopImageY, candidate.maskBottomImageY,
                      candidate.leftFootBottomImageY, candidate.rightFootBottomImageY].compactMap({ $0 }) {
                try requireBodyValue(y.isFinite && (0...1).contains(y), "mask image Y")
            }
        }
    }
}
