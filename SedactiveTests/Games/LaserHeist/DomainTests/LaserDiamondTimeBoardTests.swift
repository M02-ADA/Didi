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

    @Test func opposingPawsSeparateAtTheCenterAndAtTheBoardEdge() throws {
        let board = LaserDiamondTimeBoard.self
        let hands = LaserContactHand.ordered
        for x in [board.inset, board.width / 2, board.width - board.inset] {
            let meeting = try LaserDiamondPosition(x: x, y: board.inset)
            let input = Dictionary(uniqueKeysWithValues: hands.map { ($0, meeting) })
            let output = board.separateOpposingPaws(input, previous: [:])
            #expect(output.count == 4)
            for hand in hands {
                let point = try #require(output[hand])
                #expect(point.x >= board.inset - 0.000001 && point.x <= board.width - board.inset + 0.000001)
                #expect(point.y >= board.inset - 0.000001 && point.y <= board.height - board.inset + 0.000001)
                for other in hands where hand.playerID != other.playerID {
                    let opponent = try #require(output[other])
                    #expect(board.distance(point, opponent) >= board.opponentPawSpacing)
                }
            }
        }
    }

    @Test func crossedPawsKeepTheirSideAndCanContactADiamondThere() throws {
        let board = LaserDiamondTimeBoard.self
        let yellow = LaserContactHand(playerID: .player1, wrist: .right)
        let orange = LaserContactHand(playerID: .player2, wrist: .left)
        let right = try LaserDiamondPosition(x: 0.7, y: 0.5)
        let left = try LaserDiamondPosition(x: 0.65, y: 0.5)
        let separated = board.separateOpposingPaws([yellow: right, orange: left], previous: [:])
        let p1 = try #require(separated[yellow])
        let p2 = try #require(separated[orange])
        #expect(p2.x < p1.x)
        let diamond = try LaserDiamondPosition(x: p2.x - 0.12, y: p2.y)
        #expect(board.overlaps(p2, diamond))
        #expect(!board.overlaps(p1, diamond))
        #expect(board.separateOpposingPaws(separated, previous: separated) == separated)
    }

    @Test(arguments: [false, true])
    func blockedSlotsStayEmptyUntilSafeThenRefillDeterministically(solo: Bool) throws {
        let board = LaserDiamondTimeBoard.self
        let roster: Set<PlayerID> = solo ? [.player1] : Set(PlayerID.allCases)
        let positions = board.positions(solo: solo)
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
        #expect(first == second && first.count == 6)
        let capped = try planner.refillPawBoard(at: 2, deadline: 10, roster: roster,
                                               active: first, recent: recent, paws: avoid)
        #expect(capped.isEmpty)
        let refilled = try planner.refillPawBoard(at: 2, deadline: 10, roster: roster,
                                                 active: Array(first.dropLast()), recent: recent, paws: avoid)
        #expect(refilled.count == 1)
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
