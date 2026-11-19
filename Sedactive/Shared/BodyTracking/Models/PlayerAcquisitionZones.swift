import Foundation

/// Where a player may be linked: the calibration stage's standing boxes, in the camera image's
/// own normalized X (the unmirrored source; the preview is mirrored for display, so P1's box on
/// the left of the screen is the right side of the image).
///
/// - The anchor is a body's torso centre (the mean of its visible shoulders and hips), so an arm
///   reaching past the edge, or a bystander's partly visible limbs, never decides anything.
/// - Each zone is the box's X range on every supported landscape iPad (`CalibrationStageLayout`,
///   aspect fill; 11-inch 1210 × 834 and 13-inch 1366 × 1024), widened by `margin`, so a player
///   standing at the edge of their box still counts. `CalibrationZoneGeometryTests` keeps these in
///   step with the drawn boxes.
/// - Zones decide LINKING only (who becomes P1/P2, and a Solo re-link). After linking, identity is
///   the tracker's: a linked player may lean or step outside their box mid-round.
/// - Height is not used: the boxes span the image's standing height, and a bystander at the edge
///   is excluded by X alone.
nonisolated enum PlayerAcquisitionZones {
    /// Hysteresis around the drawn boxes (about 15 % of a box's width).
    static let margin = 0.04
    /// The union of the drawn boxes' X ranges on the supported screens (see the type comment).
    static let player1Box = 0.521...0.808
    static let player2Box = 0.173...0.461
    static let soloBox = 0.358...0.642

    static func zone(_ player: PlayerID, solo: Bool) -> ClosedRange<Double> {
        let box = solo ? soloBox : player == .player1 ? player1Box : player2Box
        return (box.lowerBound - margin)...(box.upperBound + margin)
    }

    /// The zone (player) a torso centre at normalized `x` belongs to, or nil (outside every box).
    static func player(atX x: Double, solo: Bool) -> PlayerID? {
        if solo { return zone(.player1, solo: true).contains(x) ? .player1 : nil }
        return PlayerID.allCases.first { zone($0, solo: false).contains(x) && (($0 == .player1) == (x > 0.5)) }
    }

    /// The torso centre's normalized X from a pose candidate's confident core joints, if any.
    static func torsoCenterX(_ candidate: PoseCandidate, minimumConfidence: Double = 0.5) -> Double? {
        let xs = [BodyJoint.leftShoulder, .rightShoulder, .leftHip, .rightHip].compactMap { joint -> Double? in
            guard let p = candidate.joints[joint], p.confidence >= minimumConfidence else { return nil }
            return p.x
        }
        return xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }
}
