import Foundation

/// Tutorial-only observation of an ALREADY admitted E07 frame and the existing steering result.
/// Does not infer a pose, read/drain a mailbox, move a board, or authorize gameplay.
@MainActor struct LeanMovementObservation {
    struct Reading { let command: Float; let velocity: Float; let x: Float }
    let source: AvatarSourceFrame
    let context: BodyInputContext
    let players: [PlayerID: Reading]

    static func make(frame: AvatarPoseFrame, context: BodyInputContext?, generation: UUID,
                     roster: [PlayerID], eligible: Bool, now: Double,
                     reading: (PlayerID) -> RobotAvatarLayer.SteeringReading?) -> Self? {
        guard eligible, let context, context.isActive, let binding = context.wristContact,
              context.sessionGeneration == generation, frame.source.context.generation == generation,
              context.cameraGeometryRevision == frame.source.context.geometryRevision,
              binding.sourceEpoch == frame.source.context.epoch,
              binding.controlRevision == frame.source.controlRevision,
              frame.source.frameID > binding.bindingFrameID,
              frame.source.capturedAt > binding.bindingCapturedAt,
              now.isFinite, frame.source.capturedAt.isFinite, now >= frame.source.capturedAt,
              now - frame.source.capturedAt <= LiveAvatarPresenter.maximumPoseAge else { return nil }
        var values: [PlayerID: Reading] = [:]
        for player in roster {
            guard case .available(let pose) = frame.slot(player), let reference = pose.capability.reference,
                  reference.calibrationRevision == context.calibrationRevisions[player],
                  let cut = context.cutovers[player], frame.source.frameID > cut.frameID,
                  frame.source.capturedAt > cut.capturedAt,
                  let value = reading(player), value.tracked, let age = value.poseAge,
                  age >= 0, age <= LiveAvatarPresenter.maximumPoseAge,
                  value.leanSpeed.isFinite, value.targetSpeed == value.leanSpeed,
                  value.velocity.isFinite, value.appliedX.isFinite else { continue }
            values[player] = Reading(command: value.leanSpeed, velocity: value.velocity, x: value.appliedX)
        }
        return Self(source: frame.source, context: context, players: values)
    }
}
