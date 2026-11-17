import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// Lemon and Tangerine are slightly see-through so lasers behind them stay readable, while their
/// hoverboards, the HIT zap and the reach cursors stay at full strength. Presentation only.
@MainActor
struct AvatarTranslucencyTests {
    /// Whether `entity` sits anywhere under `ancestor`.
    private func isDescendant(_ entity: Entity, of ancestor: Entity) -> Bool {
        var parent = entity.parent
        while let current = parent {
            if current === ancestor { return true }
            parent = current.parent
        }
        return false
    }

    /// One stable body opacity for both mascots (the 65 % design decision); the untracked dim
    /// stays clearly lower.
    @Test func theBodyOpacityIsTheDesignedSixtyFivePercent() {
        #expect(RobotAvatarLayer.bodyOpacity == 0.65)
        #expect(RobotAvatarLayer.unavailableOpacity == RobotAvatarLayer.bodyOpacity * 0.5)
    }

    /// A HIT: fully opaque on the very first frame, held through the strongest impact, then a
    /// quick, monotone ease back to exactly the baseline, well inside the reaction.
    @Test func aHitIsSolidAtOnceHoldsThenEasesBack() {
        typealias R = LaserHitReaction
        #expect(R.solidity(-0.01) == 0 && R.solidity(R.duration) == 0)
        for tau in stride(from: 0.0, through: R.impactHold, by: 0.01) { #expect(R.solidity(tau) == 1, "hold \(tau)") }
        #expect(R.impactHold > R.hitStop && R.impactHold > 0.11, "held past the hit-stop and the recoil peak")
        #expect(R.impactRelease - R.impactHold <= 0.3, "a snap back, not a slow fade")
        #expect(R.solidity(R.impactRelease) == 0 && R.impactRelease < R.duration)
        var last = 1.0
        for tau in stride(from: R.impactHold, through: R.impactRelease, by: 0.005) {
            let s = R.solidity(tau)
            #expect(s <= last + 1e-12, "monotone at \(tau)")
            last = s
        }
        // The frame carries it, with and without Reduce Motion (opacity is not motion).
        for reduce in [false, true] {
            let r = R(region: .upper, side: 1, reduceMotion: reduce)
            #expect(r.frame(at: 0).solidity == 1 && r.frame(at: 0.3).solidity < 1 && r.frame(at: 0.5).solidity == 0)
        }
    }

    /// The rule: tracked 65 % → 100 % by its own HIT; untracked stays dimmed whatever the HIT;
    /// a scripted fade multiplies on top.
    @Test func onlyATrackedStruckMascotTurnsSolid() {
        let body = RobotAvatarLayer.bodyOpacity, dim = RobotAvatarLayer.unavailableOpacity
        #expect(RobotAvatarLayer.shownOpacity(tracked: true, solidity: 0) == body)
        #expect(RobotAvatarLayer.shownOpacity(tracked: true, solidity: 1) == 1)
        #expect(abs(RobotAvatarLayer.shownOpacity(tracked: true, solidity: 0.5) - (body + (1 - body) * 0.5)) < 1e-6)
        #expect(RobotAvatarLayer.shownOpacity(tracked: false, solidity: 1) == dim, "a dimmed mascot is never lit by a HIT")
        #expect(RobotAvatarLayer.shownOpacity(tracked: true, solidity: 1, scripted: 0.5) == 0.5)
    }

    /// Each mascot's skinned model shares the depth pre-pass group, so a translucent body never
    /// shows its own far side through itself.
    @Test func bothMascotsDrawWithADepthPrePass() async throws {
        let layer = RobotAvatarLayer(scene: LaserScene(), players: Set(PlayerID.allCases),
                                     templates: try await RobotAvatarLayer.sharedTemplates())
        defer { layer.remove() }
        #expect(RobotAvatarLayer.mascotSortGroup.depthPass == .prePass)
        for player in PlayerID.allCases {
            let robot = try #require(layer.robots[player])
            let sort = try #require(robot.model.components[ModelSortGroupComponent.self], "\(player)")
            #expect(sort.group == RobotAvatarLayer.mascotSortGroup, "\(player)")
        }
    }

    /// The body fade lives on the mascot's container only: the board, the HIT zap and the reach
    /// cursors are its siblings on the lane and stay opaque; a scripted fade multiplies on top.
    @Test func onlyTheBodyIsTranslucent() async throws {
        let scene = LaserScene()
        let layer = RobotAvatarLayer(scene: scene, players: Set(PlayerID.allCases),
                                     templates: try await RobotAvatarLayer.sharedTemplates())
        defer { layer.remove() }
        for player in PlayerID.allCases {
            let robot = try #require(layer.robots[player])
            let shown = robot.retargeter.isAvailable ? RobotAvatarLayer.bodyOpacity : RobotAvatarLayer.unavailableOpacity
            #expect(robot.container.components[OpacityComponent.self]?.opacity == shown, "\(player)")

            let board = try #require(layer.hoverboards[player], "\(player) board")
            #expect(board.root.components[OpacityComponent.self] == nil, "\(player) board stays opaque")
            #expect(!isDescendant(board.root, of: robot.container), "\(player) board")

            layer.startHitReaction(player, contact: robot.container.position(relativeTo: nil) + [0, 1.2, 0])
            let zap = try #require(scene.root.findEntity(named: "player.\(player.rawValue).laserHitZap"))
            #expect(!isDescendant(zap, of: robot.container), "\(player) zap stays at full strength")
            for side in RobotPoseTargets.Side.allCases {
                let cursor = try #require(scene.root.findEntity(named: "player.\(player.rawValue).reachCursor.\(side)"))
                #expect(!isDescendant(cursor, of: robot.container), "\(player) \(side) cursor")
            }

            var move = RobotAvatarLayer.ScriptedMove()
            move.opacity = 0.5
            layer.scriptedMoves[player] = move
            #expect(robot.container.components[OpacityComponent.self]?.opacity == shown * 0.5, "\(player) scripted fade")
            #expect(board.root.components[OpacityComponent.self] == nil, "\(player) board ignores the body fade")
        }
    }
}
