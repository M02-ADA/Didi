import Foundation
import Testing
@testable import Sedactive

nonisolated struct D09SyntheticDiamondTests {
    /// All positions/radii here are explicit synthetic inputs, not approved device reach.
    private func membership(_ spawns: [LaserDiamondSpawn], points: [LaserContactHand: LaserDiamondPosition])
        -> [UUID: [LaserContactHand: LaserContactLocation]] {
        Dictionary(uniqueKeysWithValues: spawns.map { spawn in
            (spawn.id, Dictionary(uniqueKeysWithValues: points.map { hand, point in
                (hand, hypot(point.x - spawn.position.x, point.y - spawn.position.y) <= 0.125
                    ? LaserContactLocation.inside : .outside)
            }))
        })
    }

    private func targets(_ spawns: [LaserDiamondSpawn], game: LaserGame) throws -> [LaserContactTarget] {
        try spawns.map { try LaserContactTarget(id: $0.id, eligiblePlayers: $0.eligiblePlayers,
            activation: $0.entry, deadline: #require(game.diamonds[$0.id]?.interactionDeadline)) }
    }

    private func positions(_ point: LaserDiamondPosition) -> [LaserContactHand: LaserDiamondPosition] {
        Dictionary(uniqueKeysWithValues: LaserContactHand.ordered.map { ($0, point) })
    }

    @Test func freshContactCanCollectAPersistentBonusTargetLateInThePhase() throws {
        var (game, generation) = try LaserDiamondTests.bonus()
        let lifetime = UUID(), start = game.gameTime
        var tracker = try LaserContactEntryTracker(lifetime: lifetime, maximumContactAge: 0.5)
        try tracker.replaceTargets(targets(game.activeDiamonds, game: game))
        try game.advance(to: start + 8)
        #expect(game.activeDiamonds.count == 4)
        _ = try tracker.evaluate(lifetime: lifetime, frameID: 1, capturedAt: start + 8,
            arrivedAt: start + 8, locations: membership(game.activeDiamonds,
                points: positions(LaserDiamondPosition(x: 0, y: 0))))
        let first = try #require(game.diamonds[LaserDiamondTests.id(1)]?.spawn)
        let time = start + 8.1
        let batch = try tracker.evaluate(lifetime: lifetime, frameID: 2, capturedAt: time,
            arrivedAt: time, locations: membership(game.activeDiamonds, points: positions(first.position)))
        #expect(try game.collectDiamonds(batch, generation: generation,
            calibrationRevisions: [.player1: 1, .player2: 1], capturedAt: time, arrivedAt: time,
            replacements: [LaserDiamondTests.spawn(5, at: time)]).count == 1)
        #expect(game.teamScore == 25 && game.activeDiamonds.count == 4)
    }

    @Test func sameFrameTeamPickupReplacesOnceAndNewTargetNeedsItsOwnFreshEntry() throws {
        var (game, generation) = try LaserDiamondTests.bonus()
        let lifetime = UUID(), start = game.gameTime
        var tracker = try LaserContactEntryTracker(lifetime: lifetime, maximumContactAge: 0.5)
        try tracker.replaceTargets(targets(game.activeDiamonds, game: game))
        let outside = try positions(LaserDiamondPosition(x: 0, y: 0))
        let first = try #require(game.diamonds[LaserDiamondTests.id(1)]?.spawn)
        _ = try tracker.evaluate(lifetime: lifetime, frameID: 1, capturedAt: start + 1,
            arrivedAt: start + 1, locations: membership(game.activeDiamonds, points: outside))
        let time = start + 1.1
        let batch = try tracker.evaluate(lifetime: lifetime, frameID: 2, capturedAt: time, arrivedAt: time,
            locations: membership(game.activeDiamonds, points: positions(first.position)))
        #expect(batch == [LaserContactActivation(targetID: first.id, hand: LaserDiamondTests.firstHand)])
        let replacement = try LaserDiamondTests.spawn(5, at: time)
        let accepted = try game.collectDiamonds(batch, generation: generation,
            calibrationRevisions: [.player1: 1, .player2: 1], capturedAt: time, arrivedAt: time,
            replacements: [replacement])
        #expect(accepted.count == 1 && game.teamScore == 25 && game.activeDiamonds.count == 4)
        tracker.removeTargets([first.id])
        try tracker.addTargets(targets([replacement], game: game))
        // A target cannot start its entry history during approach or from a held first-inside pose.
        let held = positions(replacement.position)
        for (frame, capture) in [(UInt64(3), time + 0.1), (4, replacement.entry), (5, replacement.entry + 0.1)] {
            #expect(try tracker.evaluate(lifetime: lifetime, frameID: frame, capturedAt: capture,
                arrivedAt: capture, locations: membership(game.activeDiamonds, points: held)).isEmpty)
        }
        _ = try tracker.evaluate(lifetime: lifetime, frameID: 6, capturedAt: replacement.entry + 0.2,
            arrivedAt: replacement.entry + 0.2, locations: membership(game.activeDiamonds, points: outside))
        let nextTime = replacement.entry + 0.3
        let nextBatch = try tracker.evaluate(lifetime: lifetime, frameID: 7, capturedAt: nextTime, arrivedAt: nextTime,
            locations: membership(game.activeDiamonds, points: held))
        let secondReplacement = try LaserDiamondTests.spawn(6, at: nextTime)
        #expect(try game.collectDiamonds(nextBatch, generation: generation,
            calibrationRevisions: [.player1: 1, .player2: 1], capturedAt: nextTime, arrivedAt: nextTime,
            replacements: [secondReplacement]).count == 1)
        #expect(game.teamScore == 50 && game.diamondsCollected == 2 && game.activeDiamonds.count == 4)
    }

    @Test func addingReplacementDoesNotEraseAnotherTargetsEligibleOutsideHistory() throws {
        let lifetime = UUID(), first = LaserDiamondTests.id(1), second = LaserDiamondTests.id(2)
        var tracker = try LaserContactEntryTracker(lifetime: lifetime, maximumContactAge: 0.5)
        try tracker.replaceTargets([
            LaserContactTarget(id: first, eligiblePlayers: [.player1], activation: 1, deadline: 4),
            LaserContactTarget(id: second, eligiblePlayers: [.player2], activation: 1, deadline: 4)
        ])
        let left = LaserDiamondTests.firstHand, right = LaserContactHand(playerID: .player2, wrist: .right)
        _ = try tracker.evaluate(lifetime: lifetime, frameID: 1, capturedAt: 1, arrivedAt: 1,
                                locations: [first: [left: .outside], second: [right: .outside]])
        _ = try tracker.evaluate(lifetime: lifetime, frameID: 2, capturedAt: 1.1, arrivedAt: 1.1,
                                locations: [first: [left: .inside], second: [right: .outside]])
        tracker.removeTargets([first])
        try tracker.addTargets([LaserContactTarget(id: LaserDiamondTests.id(3), eligiblePlayers: [.player1],
                                                   activation: 1.1, deadline: 4)])
        let batch = try tracker.evaluate(lifetime: lifetime, frameID: 3, capturedAt: 1.2, arrivedAt: 1.2,
                                        locations: [second: [right: .inside]])
        #expect(batch == [LaserContactActivation(targetID: second, hand: right)])
    }

    @Test func invalidPlanCanBeRetriedWithoutPartiallyConsumingTrackerOrGameState() throws {
        var (game, generation) = try LaserDiamondTests.bonus()
        let lifetime = UUID(), start = game.gameTime
        var tracker = try LaserContactEntryTracker(lifetime: lifetime, maximumContactAge: 0.5)
        try tracker.replaceTargets(targets(game.activeDiamonds, game: game))
        _ = try tracker.evaluate(lifetime: lifetime, frameID: 1, capturedAt: start + 1, arrivedAt: start + 1,
            locations: membership(game.activeDiamonds, points: positions(LaserDiamondPosition(x: 0, y: 0))))
        let spawn = try #require(game.diamonds[LaserDiamondTests.id(1)]?.spawn), time = start + 1.1
        // Fixture orchestration stages both values; a rejected plan commits neither.
        var candidate = tracker
        let batch = try candidate.evaluate(lifetime: lifetime, frameID: 2, capturedAt: time, arrivedAt: time,
            locations: membership(game.activeDiamonds, points: positions(spawn.position)))
        #expect(throws: LaserDataError.self) {
            try game.collectDiamonds(batch, generation: generation, calibrationRevisions: [.player1: 1, .player2: 1],
                capturedAt: time, arrivedAt: time, replacements: [LaserDiamondTests.spawn(5, at: time, x: 1)])
        }
        #expect(game.teamScore == 0 && game.diamondsCollected == 0)
        let retry = try tracker.evaluate(lifetime: lifetime, frameID: 2, capturedAt: time, arrivedAt: time,
            locations: membership(game.activeDiamonds, points: positions(spawn.position)))
        #expect(try game.collectDiamonds(retry, generation: generation, calibrationRevisions: [.player1: 1, .player2: 1],
            capturedAt: time, arrivedAt: time, replacements: [LaserDiamondTests.spawn(5, at: time)]).count == 1)
        #expect(game.teamScore == 25)
    }
}
