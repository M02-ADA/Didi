import Foundation
import Testing
@testable import Sedactive

struct DiamondTimePickupRhythmTests {
    private func states(_ times: [Double]) throws -> [UUID: LaserDiamondState] {
        let hand = LaserContactHand(playerID: .player1, wrist: .left)
        return try Dictionary(uniqueKeysWithValues: times.enumerated().map { index, time in
            let id = UUID()
            let spawn = try LaserDiamondSpawn(id: id, position: .init(x: Double(index), y: 0.4),
                                             eligiblePlayers: [.player1, .player2], spawnedAt: 0, entry: 0, exit: 20)
            return (id, LaserDiamondState(spawn: spawn, lifetime: .diamondTime(deadline: 20),
                                         outcome: .collected(hand: hand, at: time)))
        })
    }

    @Test func nearbyPickupsShareOneAccentAndChainLevelsCapThenReset() throws {
        let rhythm = DiamondTimePickupRhythm.beats(in: try states([1, 1.04, 1.07, 1.40, 1.80, 2.15, 3.1]))
        #expect(rhythm.map(\.start) == [1, 1.40, 1.80, 2.15, 3.1])
        #expect(rhythm.map(\.level) == [3, 4, 5, 5, 1])
        #expect(rhythm.map { $0.ids.count } == [3, 1, 1, 1, 1])
    }

    @Test func shakeOnlyRunsAtTheCrestAndDecaysBackToZero() {
        #expect(DiamondTimePickupRhythm.shake(age: 0.025, level: 2) == 0)
        #expect(DiamondTimePickupRhythm.shake(age: -0.025, level: 3) == 0)
        let crest = DiamondTimePickupRhythm.shake(age: 0.025, level: 3)
        #expect(crest > 0 && crest < 0.006)
        #expect(DiamondTimePickupRhythm.shake(age: 0.025, level: 5) > crest)
        #expect(abs(DiamondTimePickupRhythm.shake(age: 0.125, level: 3)) < crest)
        #expect(DiamondTimePickupRhythm.shake(age: 0.20, level: 5) == 0)
    }
}
