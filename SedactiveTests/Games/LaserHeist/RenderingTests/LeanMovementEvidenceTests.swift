import Foundation
import Testing
@testable import Sedactive

@MainActor struct LeanMovementEvidenceTests {
    @Test(arguments: ["valid", "generation", "epoch", "control", "stale", "future", "calibration", "directionOnly", "untracked", "testMove", "cutover", "notReady"])
    func existingAdmissionAndSteeringMustAgree(reason: String) throws {
        let input = try LaserReplayScript.load().input
        let source = SyntheticAvatarSource(configuration: input.configuration, cameraGeometryRevision: input.cameraGeometryRevision)
        let demo = try RobotDemoSequence(configuration: input.configuration, cameraGeometryRevision: input.cameraGeometryRevision, only: .idle).frame(1000)
        let admitted = try AvatarPoseProjection.project(source.output(demo.snapshot, joints: demo.joints), status: source.status).get()
        let s = admitted.source, c = s.context
        let modified = AvatarSourceFrame(context: .init(generation: reason == "generation" ? UUID() : c.generation,
            epoch: reason == "epoch" ? UUID() : c.epoch, geometryRevision: c.geometryRevision,
            imageWidth: c.imageWidth, imageHeight: c.imageHeight, rotationAngle: c.rotationAngle, mirrored: c.mirrored),
            frameID: s.frameID, capturedAt: s.capturedAt, controlRevision: reason == "control" ? 99 : s.controlRevision)
        let slot: AvatarSlot
        if reason == "directionOnly", case .available(let p) = admitted.player1 {
            slot = .available(.init(joints: p.joints, capability: .directionOnly))
        } else { slot = admitted.player1 }
        let frame = AvatarPoseFrame(source: modified, contextRevision: admitted.contextRevision, player1: slot, player2: admitted.player2)
        let context = BodyInputContext(sessionGeneration: c.generation, cameraGeometryRevision: c.geometryRevision,
            calibrationRevisions: source.calibrations.mapValues { reason == "calibration" ? 99 : $0.revision },
            cutovers: source.calibrations.mapValues { .init(frameID: reason == "cutover" ? s.frameID : $0.sourceFrameID, capturedAt: $0.capturedAt) },
            isActive: true, wristContact: .init(sourceEpoch: c.epoch, controlRevision: s.controlRevision,
                bindingRequestID: UUID(), bindingFrameID: 0, bindingCapturedAt: 0, acceptedContextRevision: 1, freshness: 0.25))
        let now = s.capturedAt + (reason == "stale" ? 1 : reason == "future" ? -1 : 0.01)
        let result = LeanMovementObservation.make(frame: frame, context: context, generation: c.generation,
            roster: [.player1], eligible: reason != "notReady", now: now) { _ in
                .init(solo: true, rawLean: -0.08, filteredLean: -0.08,
                    leanSpeed: -1, targetSpeed: reason == "testMove" ? 1 : -1, velocity: -1, travel: -0.1,
                    targetX: -0.8, appliedX: -0.8, constraint: .free, leftWallDistance: 1, rightWallDistance: 1,
                    partnerDistance: nil, boardWorldX: -0.8, screenX: 0.4, frameDT: 1 / 60,
                    poseAge: 0.01, tracked: reason != "untracked")
            }
        #expect((result?.players[.player1] != nil) == (reason == "valid"))
    }
}
