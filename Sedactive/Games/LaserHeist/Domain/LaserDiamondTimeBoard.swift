import Foundation

/// Logical screen units. The overlay fits this rectangle uniformly inside its safe area.
nonisolated enum LaserDiamondTimeBoard {
    static let maximumActiveDiamonds = 6
    static let width = 1.8
    static let height = 1.0
    static let pawRadius = 0.082
    // Includes the outer edge of the illustrated outline.
    static let opponentPawSpacing = 2 * pawRadius + 0.006
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

    /// Separate opposing paws after smoothing, keeping their centres inside the board.
    static func separateOpposingPaws(_ paws: [LaserContactHand: LaserDiamondPosition],
                                     previous: [LaserContactHand: LaserDiamondPosition])
        -> [LaserContactHand: LaserDiamondPosition] {
        let yellow = LaserContactHand.ordered.filter { $0.playerID == .player1 && paws[$0] != nil }
        let orange = LaserContactHand.ordered.filter { $0.playerID == .player2 && paws[$0] != nil }
        let pairs = yellow.flatMap { a in orange.map { (a, $0) } }
        var positions = paws
        let clearance = opponentPawSpacing + 0.0001

        for _ in 0..<32 {
            var moved = false
            for (yellowHand, orangeHand) in pairs {
                guard let a = positions[yellowHand], let b = positions[orangeHand],
                      distance(a, b) < opponentPawSpacing else { continue }
                var axis = SIMD2(b.x - a.x, b.y - a.y)
                if hypot(axis.x, axis.y) < 0.000001 {
                    if let left = previous[yellowHand], let right = previous[orangeHand] {
                        axis = SIMD2(right.x - left.x, right.y - left.y)
                    }
                    if hypot(axis.x, axis.y) < 0.000001 { axis = SIMD2(1, 0) }
                }
                axis *= clearance / hypot(axis.x, axis.y)
                // Slide the pair together when the wall blocks a symmetric split.
                let x = min(width - inset - abs(axis.x) / 2,
                            max(inset + abs(axis.x) / 2, (a.x + b.x) / 2))
                let y = min(height - inset - abs(axis.y) / 2,
                            max(inset + abs(axis.y) / 2, (a.y + b.y) / 2))
                positions[yellowHand] = try? LaserDiamondPosition(x: x - axis.x / 2, y: y - axis.y / 2)
                positions[orangeHand] = try? LaserDiamondPosition(x: x + axis.x / 2, y: y + axis.y / 2)
                moved = true
            }
            if !moved { return positions }
        }
        // A crowded cluster may need a final pass that preserves all pair gaps at once.
        for (a, b) in pairs {
            guard let first = positions[a], let second = positions[b],
                  distance(first, second) < opponentPawSpacing else { continue }
            let split = min(width - inset - clearance / 2,
                            max(inset + clearance / 2, (first.x + second.x) / 2))
            let yellowIsLeft = first.x <= second.x
            for hand in yellow + orange {
                guard let point = positions[hand] else { continue }
                let onLeft = (hand.playerID == .player1) == yellowIsLeft
                let x = onLeft ? min(point.x, split - clearance / 2) : max(point.x, split + clearance / 2)
                positions[hand] = try? LaserDiamondPosition(x: x, y: point.y)
            }
            break
        }
        return positions
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
