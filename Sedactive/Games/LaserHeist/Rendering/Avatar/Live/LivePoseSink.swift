//
//  LivePoseSink.swift
//  Sedactive
//

#if DEBUG
import CoreVideo
import Foundation
import Vision

// TEMPORARY Debug-only bridge for the Live Avatar Lab (needs Edo's review).
//
// Edo's `CameraPipeline` accepts one `CameraFrameSink`. The lab constructs its
// own pipeline with this sink, so capture, format negotiation, upright
// rotation, unmirrored output, host-clock timestamps, the latest-frame-only
// `FrameStore` and interruption handling are all Edo's, unchanged. Only one
// pipeline runs at a time: the lab covers the whole app, and the shared
// diagnostics camera cannot be opened while it is shown.
//
// Vision pose detection here duplicates the work on Edo's unmerged
// `feat/vision-pose` branch (not on this branch). Replace this sink's Vision
// call with his `PoseEstimator` once it lands. Nothing here feeds gameplay.

/// Vision's body joints the avatar uses.
nonisolated enum LiveJoint: String, CaseIterable, Sendable {
    case nose, leftEye, rightEye, leftEar, rightEar, neck
    case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case root, leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle

    var vision: VNHumanBodyPoseObservation.JointName {
        switch self {
        case .nose: .nose
        case .leftEye: .leftEye
        case .rightEye: .rightEye
        case .leftEar: .leftEar
        case .rightEar: .rightEar
        case .neck: .neck
        case .leftShoulder: .leftShoulder
        case .rightShoulder: .rightShoulder
        case .leftElbow: .leftElbow
        case .rightElbow: .rightElbow
        case .leftWrist: .leftWrist
        case .rightWrist: .rightWrist
        case .root: .root
        case .leftHip: .leftHip
        case .rightHip: .rightHip
        case .leftKnee: .leftKnee
        case .rightKnee: .rightKnee
        case .leftAnkle: .leftAnkle
        case .rightAnkle: .rightAnkle
        }
    }
}

/// One joint in the upright, UNMIRRORED camera image: normalized 0…1, origin
/// bottom-left, y up (Vision's convention). Anatomical side as Vision labels it.
nonisolated struct LivePoint: Equatable, Sendable {
    let x: Double
    let y: Double
    let confidence: Double
}

nonisolated struct LivePerson: Equatable, Sendable {
    let joints: [LiveJoint: LivePoint]

    func point(_ joint: LiveJoint, minimumConfidence: Double = 0.3) -> LivePoint? {
        guard let p = joints[joint], p.confidence >= minimumConfidence else { return nil }
        return p
    }
}

/// Vision's result for one camera frame. Times are host-clock seconds (the
/// camera's capture clock), so `visionCompletedAt - capturedAt` is real latency.
nonisolated struct LiveBodyFrame: Equatable, Sendable {
    let frameID: UInt64
    let capturedAt: Double
    let visionCompletedAt: Double
    /// Upright image width / height.
    let imageAspect: Double
    let cameraGeometryRevision: UInt64
    let people: [LivePerson]
}

actor LivePoseSink: CameraFrameSink {
    static let maximumPeople = 4

    /// Newest result only: a slow consumer never sees a backlog of old movement.
    nonisolated let results: AsyncStream<LiveBodyFrame>
    private let continuation: AsyncStream<LiveBodyFrame>.Continuation
    private var pool: CVPixelBufferPool?
    private var poolSize: (Int, Int) = (0, 0)
    private let request = VNDetectHumanBodyPoseRequest()

    init() {
        (results, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func consume(_ frame: CameraSourceFrame) throws {
        let d = frame.metadata.descriptor
        let buffer = try pixelBuffer(width: d.width, height: d.height)
        CVPixelBufferLockBaseAddress(buffer, [])
        let destination = CVPixelBufferGetBaseAddress(buffer)!
        let destinationRow = CVPixelBufferGetBytesPerRow(buffer)
        frame.withBytes { source in
            for row in 0..<d.height {
                memcpy(destination + row * destinationRow, source.baseAddress! + row * d.bytesPerRow, d.width * 4)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        // Frames are already upright (the capture connection rotates them); never rotate twice.
        try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:]).perform([request])
        let people = (request.results ?? []).prefix(Self.maximumPeople).map { observation in
            var joints: [LiveJoint: LivePoint] = [:]
            for joint in LiveJoint.allCases {
                guard let p = try? observation.recognizedPoint(joint.vision), p.confidence > 0 else { continue }
                joints[joint] = LivePoint(x: Double(p.location.x), y: Double(p.location.y), confidence: Double(p.confidence))
            }
            return LivePerson(joints: joints)
        }
        continuation.yield(LiveBodyFrame(
            frameID: frame.metadata.frameID, capturedAt: frame.metadata.capturedAt,
            visionCompletedAt: CameraHostClock.now(), imageAspect: Double(d.width) / Double(d.height),
            cameraGeometryRevision: frame.metadata.context.geometryRevision, people: Array(people)))
    }

    func reset() {
        pool = nil
    }

    nonisolated func finish() { continuation.finish() }

    private func pixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        if pool == nil || poolSize != (width, height) {
            var created: CVPixelBufferPool?
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created) == kCVReturnSuccess else {
                throw CameraFrameError.invalidDescriptor
            }
            pool = created
            poolSize = (width, height)
        }
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
            throw CameraFrameError.invalidDescriptor
        }
        return buffer
    }
}
#endif
