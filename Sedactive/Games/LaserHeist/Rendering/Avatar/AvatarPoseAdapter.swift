//
//  AvatarPoseAdapter.swift
//  Sedactive
//

import Foundation

/// PROPOSED (D06, pending Edo/Kevin sign-off): the standing reference values
/// the avatar needs for one player, in unmirrored player-plane game units with
/// Y up from the calibrated floor. Presentation only: never a judgement input.
///
/// The retargeter reads only these numbers, never calibration internals, so
/// the agreed D06 avatar packet can supply them later without changing the
/// rig. Until then `init(calibration:layout:)` derives them, read-only, from
/// CP1's accepted `PlayerCalibration`; that adapter is the only place the
/// avatar touches calibration.
struct AvatarReference: Equatable, Sendable {
    let playerID: PlayerID
    /// The calibration these values come from; body samples and joints of any
    /// other revision are not shown on this avatar.
    let calibrationRevision: UInt64
    /// Standing crown height.
    let standingHeight: Double
    /// Standing hip-centre height.
    let standingHipY: Double
    /// Standing ankle height per anatomical side (sole plus the calibrated foot offset).
    let standingLeftAnkleY: Double
    let standingRightAnkleY: Double
    /// The player's own lane centre on the player plane (standing in place).
    let laneCenterX: Double

    func standingAnkleY(_ side: RobotPoseTargets.Side) -> Double {
        side == .left ? standingLeftAnkleY : standingRightAnkleY
    }
}

extension AvatarReference {
    /// TEMPORARY CP1 adapter (until the D06 packet): reads a player's accepted
    /// standing calibration and converts its image-space values to game units.
    init(calibration: PlayerCalibration, layout: PlayerPlaneLayout) {
        func gameY(_ imageY: Double) -> Double { calibration.mapping.gameY(imageY: imageY, layout: layout) }
        let body = calibration.standingBodyImageHeight
        self.init(playerID: calibration.playerID, calibrationRevision: calibration.revision,
                  standingHeight: gameY(calibration.standingCrownImageY),
                  standingHipY: gameY(calibration.standingHipImageY),
                  standingLeftAnkleY: gameY(calibration.standingLeftSoleImageY + calibration.leftFootOffsetShare * body),
                  standingRightAnkleY: gameY(calibration.standingRightSoleImageY + calibration.rightFootOffsetShare * body),
                  laneCenterX: layout.centerX(for: calibration.playerID))
    }
}

extension AvatarReference {
    /// From a K03 packet's compatible reference (already in game units).
    init(standing: AvatarStandingReference, playerID: PlayerID) {
        self.init(playerID: playerID, calibrationRevision: standing.calibrationRevision,
                  standingHeight: standing.standingCrownY, standingHipY: standing.standingHipY,
                  standingLeftAnkleY: standing.standingLeftAnkleY, standingRightAnkleY: standing.standingRightAnkleY,
                  laneCenterX: standing.laneCenterX)
    }
}

/// K03: converts one available slot into what the retargeter consumes.
/// Presentation values only; the slot's observed joints are not altered.
enum AvatarPoseAdapter {
    /// B1's observed keys the retargeter uses (eyes are carried but unused).
    /// No elbow or knee is ever filled: their bend stays procedural.
    static let jointNames: [BodyJoint: PresentationJoint] = [
        .nose: .nose, .leftEar: .leftEar, .rightEar: .rightEar, .neck: .neck,
        .leftShoulder: .leftShoulder, .rightShoulder: .rightShoulder, .leftWrist: .leftWrist, .rightWrist: .rightWrist,
        .leftHip: .leftHip, .rightHip: .rightHip, .leftAnkle: .leftAnkle, .rightAnkle: .rightAnkle,
    ]

    /// Calibrated: CP1's own `gameX`/`gameY` with the slot's accepted mapping
    /// (player-plane game units), plus the valid visual values. Direction
    /// only: aspect-corrected canonical image units (directions are
    /// scale-free), with no lift, sway, crouch or crown.
    static func observation(_ pose: AvatarSlotPose, playerID: PlayerID, imageAspect: Double) -> RobotRetargeter.Observation {
        var observation = RobotRetargeter.Observation()
        let reference = pose.capability.reference
        for (joint, point) in pose.joints {
            guard let name = jointNames[joint] else { continue }
            let x: Double, y: Double
            if let reference {
                x = reference.mapping.gameX(imageX: point.x, playerID: playerID, layout: reference.layout)
                y = reference.mapping.gameY(imageY: point.y, layout: reference.layout)
            } else {
                x = point.x * imageAspect
                y = point.y
            }
            observation.joints[name] = PresentationPoint(x: x, y: y, confidence: point.confidence)
        }
        guard case .calibrated(_, let visual) = pose.capability else { return observation }
        observation.calibrated = true
        if let visual {
            if visual.leftSoleY.validity == .valid, visual.rightSoleY.validity == .valid,
               let left = visual.leftSoleY.value, let right = visual.rightSoleY.value {
                observation.lowerSoleY = min(left, right)
            }
            if visual.centerX.validity == .valid { observation.centerX = visual.centerX.value }
            if visual.crownY.validity == .valid { observation.crownY = visual.crownY.value }
        }
        return observation
    }
}
