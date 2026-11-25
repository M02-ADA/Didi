import Foundation

/// Tutorial-only observation of an ALREADY admitted E07 frame and the existing steering result.
/// Does not infer a pose, read/drain a mailbox, move a board, or authorize gameplay.
@MainActor struct LeanMovementObservation {
    struct Reading {
        let command: Float
        let velocity: Float
        let x: Float
        /// Direction actually blocked this steering step; never inferred from screen position.
        var blockedDirection: Float = 0
    }
    let source: AvatarSourceFrame
    let context: BodyInputContext
    let players: [PlayerID: Reading]

    /// Players with a current, source-correlated avatar pose, independent of steering.
    static func posedPlayers(in frame: AvatarPoseFrame, context: BodyInputContext?, generation: UUID,
                             roster: [PlayerID], now: Double) -> [PlayerID]? {
        guard let context, context.isActive, let binding = context.wristContact,
              context.sessionGeneration == generation, frame.source.context.generation == generation,
              context.cameraGeometryRevision == frame.source.context.geometryRevision,
              binding.sourceEpoch == frame.source.context.epoch,
              binding.controlRevision == frame.source.controlRevision,
              frame.source.frameID > binding.bindingFrameID,
              frame.source.capturedAt > binding.bindingCapturedAt,
              now.isFinite, frame.source.capturedAt.isFinite, now >= frame.source.capturedAt,
              now - frame.source.capturedAt <= LiveAvatarPresenter.maximumPoseAge else { return nil }
        return roster.filter { player in
            guard case .available(let pose) = frame.slot(player), let reference = pose.capability.reference,
                  reference.calibrationRevision == context.calibrationRevisions[player],
                  let cut = context.cutovers[player] else { return false }
            return frame.source.frameID > cut.frameID && frame.source.capturedAt > cut.capturedAt
        }
    }

    static func make(frame: AvatarPoseFrame, context: BodyInputContext?, generation: UUID,
                     roster: [PlayerID], eligible: Bool, now: Double, bounds: ClosedRange<Float>? = nil,
                     reading: (PlayerID) -> RobotAvatarLayer.SteeringReading?) -> Self? {
        guard eligible, let context else { return nil }
        guard let posed = posedPlayers(in: frame, context: context, generation: generation, roster: roster, now: now)
        else { return nil }
        var values: [PlayerID: Reading] = [:]
        for player in posed {
            guard let value = reading(player), value.tracked, let age = value.poseAge,
                  age >= 0, age <= LiveAvatarPresenter.maximumPoseAge,
                  value.leanSpeed.isFinite, value.targetSpeed == value.leanSpeed,
                  value.velocity.isFinite, value.appliedX.isFinite else { continue }
            // The existing controller zeros only the blocked velocity. Partner contact is
            // directional: P1 can be blocked to the right, P2 to the left (not vice versa).
            let blocked: Float
            switch value.constraint {
            case .free: blocked = 0
            case .leftLimit: blocked = -1
            case .rightLimit: blocked = 1
            case .partner:
                // Separation resolution can overwrite a simultaneous wall-limit label.
                // Require BOTH the reported constraint and the controller's exact limit.
                // boardX reconstructs lane + travel + sway; allow one Float ULP
                // of arithmetic round-off, not a new movement/lean threshold.
                if let bounds, value.leanSpeed < 0, value.targetX <= bounds.lowerBound.nextUp { blocked = -1 }
                else if let bounds, value.leanSpeed > 0, value.targetX >= bounds.upperBound.nextDown { blocked = 1 }
                else { blocked = player == .player1 ? 1 : -1 }
            }
            values[player] = Reading(command: value.leanSpeed, velocity: value.velocity,
                x: value.appliedX, blockedDirection: value.velocity == 0 ? blocked : 0)
        }
        return Self(source: frame.source, context: context, players: values)
    }
}
