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
