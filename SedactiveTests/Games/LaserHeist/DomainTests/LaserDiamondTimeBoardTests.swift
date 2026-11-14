import Foundation
import Testing
@testable import Sedactive

struct LaserDiamondTimeBoardTests {
    @Test func equalRelativeReachesMapTheSameForChildAndAdult() throws {
        let board = LaserDiamondTimeBoard.self
        let child = try #require(board.paw(.init(x: -0.24, y: 0.8), laneX: 0,
                                           standingHeight: 1, player: .player1, solo: false))
        let adult = try #require(board.paw(.init(x: 1.52, y: 1.6), laneX: 2,
                                           standingHeight: 2, player: .player1, solo: false))
        #expect(board.distance(child, adult) < 0.000001)
        let opposite = try #require(board.paw(.init(x: 0.24, y: 0.8), laneX: 0,
                                              standingHeight: 1, player: .player2, solo: false))
        #expect(abs(child.x + opposite.x - board.width) < 0.000001)
        #expect(child.y == opposite.y)
    }

    @Test func blockedSlotsStayEmptyUntilSafeThenRefillDeterministically() throws {
        let board = LaserDiamondTimeBoard.self
        let roster = Set(PlayerID.allCases)
        let positions = board.positions(solo: false)
        let placements = positions.map { LaserDiamondPlacement(position: $0, eligiblePlayers: roster) }
        var planner = try LaserDiamondPlanner(seed: 42, placements: placements, approachLead: 1, passageDuration: 1)
        var duplicate = planner
        let blocked = try planner.refillPawBoard(at: 0, deadline: 10, roster: roster,
                                                active: [], recent: [], paws: positions)
        #expect(blocked.isEmpty)

        let avoid = Array(positions.prefix(4))
        let recent = [positions[20]]
        let first = try planner.refillPawBoard(at: 1, deadline: 10, roster: roster,
                                              active: [], recent: recent, paws: avoid)
        let second = try duplicate.refillPawBoard(at: 1, deadline: 10, roster: roster,
                                                 active: [], recent: recent, paws: avoid)
        #expect(first == second && first.count == 4)
        for (index, spawn) in first.enumerated() {
            #expect(spawn.eligiblePlayers == roster && spawn.entry == 1 && spawn.exit == 10)
            #expect(!recent.contains(spawn.position))
            #expect(avoid.allSatisfy { board.distance($0, spawn.position) >= board.spawnClearance })
            #expect(first.prefix(index).allSatisfy {
                board.distance($0.position, spawn.position) >= board.interDiamondSpacing
            })
        }
    }
}
