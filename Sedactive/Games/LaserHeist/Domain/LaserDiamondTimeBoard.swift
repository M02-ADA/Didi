import Foundation

/// Logical screen units. The overlay fits this rectangle uniformly inside its safe area.
nonisolated enum LaserDiamondTimeBoard {
    static let width = 1.8
    static let height = 1.0
    static let pawRadius = 0.082
    static let diamondRadius = 0.052
    static let spawnClearance = pawRadius + diamondRadius + 0.038
    static let interDiamondSpacing = 2 * diamondRadius + 0.06
    static let pickupEffectDuration = 0.42

    static let inset = pawRadius + 0.014
    static let lowWristHeight = 0.38
    static let highWristHeight = 1.05
    static let lateralGain = 1.65

    static func paw(_ wrist: WristPlanePoint, laneX: Double, standingHeight: Double,
                    player: PlayerID, solo: Bool) -> LaserDiamondPosition? {
        guard standingHeight.isFinite, standingHeight > 0 else { return nil }
        let home = homeX(player: player, solo: solo)
        let x = home + (laneX - wrist.x) / standingHeight * lateralGain
        let raised = (wrist.y / standingHeight - lowWristHeight) / (highWristHeight - lowWristHeight)
        let y = height - inset - raised * (height - 2 * inset)
        return try? LaserDiamondPosition(x: min(width - inset, max(inset, x)),
                                         y: min(height - inset, max(inset, y)))
    }

    static func homeX(player: PlayerID, solo: Bool) -> Double {
        solo ? width / 2 : width * (player == .player1 ? 0.30 : 0.70)
    }

    static func distance(_ a: LaserDiamondPosition, _ b: LaserDiamondPosition) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }

    static func overlaps(_ paw: LaserDiamondPosition, _ diamond: LaserDiamondPosition) -> Bool {
        distance(paw, diamond) <= pawRadius + diamondRadius
    }

    /// A seeded choice among evenly spaced positions spanning both players' calibrated reach.
    static func positions(solo: Bool) -> [LaserDiamondPosition] {
        let margin = solo ? 0.29 : 0.22
        return (0..<5).flatMap { row in
            (0..<9).map { column in
                // All values are finite constants.
                try! LaserDiamondPosition(x: margin + (width - 2 * margin) * Double(column) / 8,
                                          y: 0.16 + 0.17 * Double(row))
            }
        }
    }
}
