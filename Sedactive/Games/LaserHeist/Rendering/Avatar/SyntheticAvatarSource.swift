//
//  SyntheticAvatarSource.swift
//  Sedactive
//

#if DEBUG
import Foundation

/// DEBUG/test-only, labelled SYNTHETIC: builds K03 `AvatarSourceOutput`s
/// from the synthetic demo's (or the bundled historical replay fixture's)
/// CP1-shaped frames, so the D06 packet path can run without a camera.
/// Not E07, not a producer, not a CP1 subscriber: it converts fixture values
/// it is handed. Its calibration inputs and visual values come from the same
/// synthetic frame; joints are converted back to canonical normalized image
/// space with each player's accepted mapping, keeping only B1's keys (the
/// demo's elbows and knees are dropped, as B1 has none). Candidate IDs are
/// fixed per player and listed P2 first: identity comes from the tracker
/// slots, never from candidate order.
struct SyntheticAvatarSource {
    let context: AvatarSourceContext
    let layout: PlayerPlaneLayout
    let calibrations: [PlayerID: PlayerCalibration]
    var controlRevision: UInt64 = 1
    var statusRevision: UInt64 = 1
    static let epoch = UUID(uuidString: "5E000000-0000-4000-8000-0000000000EE")!
    static let candidateIDs: [PlayerID: UInt64] = [.player1: 101, .player2: 202]

    init(configuration: BodyInputConfiguration, cameraGeometryRevision: UInt64) {
        let aspect = configuration.calibrations.values.first?.mapping.imageAspectRatio ?? 16.0 / 9
        context = AvatarSourceContext(generation: configuration.sessionGeneration, epoch: Self.epoch,
                                      geometryRevision: cameraGeometryRevision,
                                      imageWidth: Int((aspect * 1080).rounded()), imageHeight: 1080,
                                      rotationAngle: 0, mirrored: false)
        layout = configuration.playerPlaneLayout
        calibrations = configuration.calibrations
    }

    var status: AvatarSourceStatus {
        AvatarSourceStatus(revision: statusRevision, isActive: true, context: context, controlRevision: controlRevision,
                           layout: layout, calibrations: calibrations.mapValues {
                               AvatarCalibrationStatus(revision: $0.revision,
                                                       cutover: BodyInputCutover(frameID: $0.sourceFrameID, capturedAt: $0.capturedAt))
                           })
    }

    /// One synthetic frame as a packet stamped with the current status.
    func output(_ snapshot: BodySnapshot, joints: PresentationPoseFrame? = nil) -> AvatarSourceOutput {
        var slots: [PlayerID: AvatarTrackedSlot] = [:]
        var candidates: [PoseCandidate] = []
        var calibration: [PlayerID: AvatarCalibrationInput] = [:]
        for player in [PlayerID.player2, .player1] {
            guard let sample = snapshot.players[player], let accepted = calibrations[player] else {
                slots[player] = AvatarTrackedSlot(state: .lost, candidateID: nil, requiresRebind: false)
                continue
            }
            guard sample.trackingStatus == .reliable else {
                slots[player] = AvatarTrackedSlot(state: .uncertain, candidateID: nil, requiresRebind: false)
                continue
            }
            let id = Self.candidateIDs[player]!
            slots[player] = AvatarTrackedSlot(state: .tracking, candidateID: id, requiresRebind: false)
            candidates.append(PoseCandidate(candidateID: id, joints: imageJoints(joints?.players[player], player, accepted),
                                            maskTopImageY: nil, maskBottomImageY: nil, leftFootBottomImageY: nil,
                                            rightFootBottomImageY: nil, maskAssociation: .unavailable))
            let body = accepted.standingBodyImageHeight
            calibration[player] = AvatarCalibrationInput(
                revision: accepted.revision, mapping: accepted.mapping,
                standingCrownImageY: accepted.standingCrownImageY, standingHipImageY: accepted.standingHipImageY,
                standingLeftAnkleImageY: accepted.standingLeftSoleImageY + accepted.leftFootOffsetShare * body,
                standingRightAnkleImageY: accepted.standingRightSoleImageY + accepted.rightFootOffsetShare * body,
                visual: sample.geometry)
        }
        return AvatarSourceOutput(source: AvatarSourceFrame(context: context, frameID: snapshot.frameID,
                                                            capturedAt: snapshot.capturedAt, controlRevision: controlRevision),
                                  contextRevision: statusRevision, player1: slots[.player1]!, player2: slots[.player2]!,
                                  candidates: candidates, calibration: calibration)
    }

    /// Player-plane game units back to canonical normalized image space; B1 keys only.
    private func imageJoints(_ sample: PresentationPoseSample?, _ player: PlayerID,
                             _ calibration: PlayerCalibration) -> [BodyJoint: PoseJoint] {
        guard let sample else { return [:] }
        let m = calibration.mapping
        var out: [BodyJoint: PoseJoint] = [:]
        for (joint, name) in AvatarPoseAdapter.jointNames {
            guard let p = sample.joints[name] else { continue }
            let x = (p.x - layout.centerX(for: player)) / (m.imageAspectRatio * layout.gameUnitsPerImageHeight) + m.originImageX
            let y = p.y / layout.gameUnitsPerImageHeight + m.floorImageY
            guard (0...1).contains(x), (0...1).contains(y), (0...1).contains(p.confidence) else { continue }
            out[joint] = PoseJoint(x: x, y: y, confidence: p.confidence)
        }
        return out
    }
}
#endif
