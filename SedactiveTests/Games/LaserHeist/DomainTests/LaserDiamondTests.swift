import Foundation
import Testing
@testable import Sedactive

nonisolated struct LaserDiamondTests {
    static let firstHand = LaserContactHand(playerID: .player1, wrist: .left)

    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "D0950000-0000-4000-8000-%012d", number))!
    }

    static func spawn(_ number: Int, at time: Double = 0, x: Double? = nil,
                      entry: Double? = nil, exit: Double? = nil,
                      players: Set<PlayerID> = Set(PlayerID.allCases)) throws -> LaserDiamondSpawn {
        try LaserDiamondSpawn(id: id(number), position: LaserDiamondPosition(x: x ?? Double(number), y: 1),
            eligiblePlayers: players, spawnedAt: time, entry: entry ?? time + 1, exit: exit ?? time + 4)
    }

    static func game(points: Int? = LaserRoundConfiguration.approvedDiamondPoints) throws -> (LaserGame, UUID) {
        let scenario = try LaserReplayScenarios.make()[0]
        let generation = scenario.input.configuration.sessionGeneration
        let context = BodyInputContext(sessionGeneration: generation, cameraGeometryRevision: 1,
            calibrationRevisions: [.player1: 1, .player2: 1], cutovers: [:], isActive: true)
        let config = try LaserRoundConfiguration(evidenceTiming: scenario.configuration.evidenceTiming,
            clearanceMargin: 0.005, diamondPoints: points, missionGateTarget: 1)
        return (try LaserGame(configuration: config, context: context, historyCapacityPerPlayer: 20), generation)
    }

    static func bonus(exitOffset: Double = 4) throws -> (LaserGame, UUID) {
        var (game, generation) = try game()
        let vaultID = id(100)
        try game.openVault(id: vaultID, at: 0)
        let contacts = PlayerID.allCases.flatMap { player in
            LaserVaultButton.allCases.map { LaserVaultContact(playerID: player, button: $0, calibrationRevision: 1) }
        }
        try game.touchVaultBatch(id: vaultID, contacts: contacts, generation: generation, at: 0.1)
        try game.startDiamondTimeDiamonds((1...4).map {
            try spawn($0, at: game.gameTime, exit: game.gameTime + exitOffset)
        })
        return (game, generation)
    }

    private func collect(_ game: inout LaserGame, generation: UUID, ids: [Int], capture: Double,
                         arrival: Double? = nil, replacements: [LaserDiamondSpawn] = [],
                         hands: [LaserContactHand] = [firstHand], revision: UInt64 = 1) throws -> [LaserContactActivation] {
        let commands = ids.flatMap { number in hands.map { LaserContactActivation(targetID: Self.id(number), hand: $0) } }
        return try game.collectDiamonds(commands, generation: generation,
            calibrationRevisions: [.player1: revision, .player2: revision], capturedAt: capture,
            arrivedAt: arrival ?? capture, replacements: replacements)
    }

    @Test func normalCollectionIsOnceDuringPassageAndMissHasNoDamageOrRefill() throws {
        var (game, generation) = try Self.game()
        try game.spawnNormalDiamonds([Self.spawn(1, exit: 2), Self.spawn(2, exit: 2)], beforeVaultAt: 3)
        #expect(try collect(&game, generation: generation, ids: [1], capture: 0.9).isEmpty)
        #expect(try collect(&game, generation: generation, ids: [1, 1], capture: 1.1,
                            hands: LaserContactHand.ordered.reversed()).count == 1)
        #expect(game.teamScore == 25 && game.diamondsCollected == 1)
        #expect(game.diamonds[Self.id(1)]?.outcome == .collected(hand: Self.firstHand, at: 1.1))
        #expect(try collect(&game, generation: generation, ids: [1], capture: 1.2).isEmpty)
        try game.advance(to: 2)
        #expect(game.diamonds[Self.id(2)]?.outcome == .missed(at: 2))
        #expect(game.activeDiamonds.isEmpty && game.diamonds.count == 2)
        #expect(try collect(&game, generation: generation, ids: [2], capture: 2.1).isEmpty)
        #expect(game.teamScore == 25 && game.teamHealth == 5)
    }

    @Test(arguments: [1.999, 2.0, 2.001])
    func arrivalAtPassageExitCannotAwardEarlierCapture(_ arrival: Double) throws {
        var (game, generation) = try Self.game()
        try game.spawnNormalDiamonds([Self.spawn(1, exit: 2)], beforeVaultAt: 3)
        #expect(try collect(&game, generation: generation, ids: [1], capture: 1.9, arrival: arrival).count ==
                (arrival < 2 ? 1 : 0))
        #expect(game.teamScore == (arrival < 2 ? 25 : 0))
    }

    @Test func eligibilityAndSourceContextDoNotCreateAwards() throws {
        var (game, generation) = try Self.game()
        try game.spawnNormalDiamonds([Self.spawn(1, players: [.player2])], beforeVaultAt: 5)
        #expect(try collect(&game, generation: UUID(), ids: [1], capture: 1.1).isEmpty)
        #expect(try collect(&game, generation: generation, ids: [1], capture: 1.2).isEmpty)
        let second = LaserContactHand(playerID: .player2, wrist: .right)
        #expect(try collect(&game, generation: generation, ids: [1], capture: 1.3,
                            hands: [second], revision: 2).isEmpty)
        #expect(try collect(&game, generation: generation, ids: [1], capture: 1.4,
                            hands: [second]).count == 1)
    }

    @Test func fourInitialBonusDiamondsReplaceCollectionsAtDistinctPositionsWithinCap() throws {
        var (game, generation) = try Self.bonus()
        #expect(game.activeDiamonds.count == 4)
        let time = game.gameTime + 1.2
        // Results are target-ID ordered, independently of supplied contact order.
        let replacements = [try Self.spawn(5, at: time), try Self.spawn(6, at: time)]
        let result = try collect(&game, generation: generation, ids: [2, 1], capture: time,
                                 replacements: replacements, hands: LaserContactHand.ordered)
        #expect(result.map(\.targetID) == [Self.id(1), Self.id(2)])
        #expect(game.teamScore == 50 && game.diamondsCollected == 2)
        #expect(game.activeDiamonds.count == 4 && game.diamonds.count == 6)
        #expect(try collect(&game, generation: generation, ids: [5], capture: time).isEmpty)
        // Bonus targets persist beyond the passage exit used by normal diamonds.
        try game.advance(to: 4.1)
        #expect(game.activeDiamonds.count == 4)
        #expect(game.diamonds.count == 6)
    }

    @Test func rejectedReplacementPlanCannotPartiallyConsumeOrAward() throws {
        var (game, generation) = try Self.bonus()
        let states = game.diamonds, initialTime = game.gameTime
        let time = initialTime + 1.2
        let bad = try Self.spawn(5, at: time, x: 1) // Same as collected position.
        #expect(throws: LaserDataError.self) {
            try collect(&game, generation: generation, ids: [1], capture: time, replacements: [bad])
        }
        #expect(game.diamonds == states && game.gameTime == initialTime && game.teamScore == 0)
        #expect(throws: LaserDataError.self) {
            try collect(&game, generation: generation, ids: [1], capture: time)
        }
        let overlapsActive = try Self.spawn(5, at: time, x: 2)
        #expect(throws: LaserDataError.self) {
            try collect(&game, generation: generation, ids: [1], capture: time, replacements: [overlapsActive])
        }
        #expect(game.diamonds == states && game.diamondsCollected == 0)
    }

    @Test func terminalSummaryUsesRealDiamondCountAndFreezesAfterPhaseEnd() throws {
        var (game, generation) = try Self.bonus()
        let start = game.gameTime, time = start + 1.2
        _ = try collect(&game, generation: generation, ids: [1], capture: time,
                        replacements: [Self.spawn(5, at: time)])
        try game.advance(to: start + 10)
        let summary = try #require(game.summary)
        #expect(summary.outcome == .completed && summary.diamondsCollected == 1 && summary.teamScore == 25)
        #expect(game.activeDiamonds.isEmpty)
        #expect(try collect(&game, generation: generation, ids: [2], capture: start + 10).isEmpty)
        try game.advance(to: start + 20)
        #expect(game.summary == summary && game.teamScore == 25)
        #expect(game.drainEvents().filter { if case .roundEnded = $0.kind { true } else { false } }.count == 1)
    }

    @Test func exactBonusDeadlineClosesBeforeCollectionOrReplacement() throws {
        var (game, generation) = try Self.bonus(exitOffset: 10)
        let deadline = game.gameTime + 10
        // Capture is inside this target's passage, but arrival is exactly phase end.
        #expect(try collect(&game, generation: generation, ids: [1], capture: deadline - 0.1,
                            arrival: deadline).isEmpty)
        #expect(game.summary?.outcome == .completed)
        #expect(game.summary?.diamondsCollected == 0 && game.teamScore == 0)
    }

    @Test func uncollectedBonusDiamondsStayAvailableUntilTheWholePhaseEnds() throws {
        var (game, generation) = try Self.bonus()
        let start = game.gameTime, deadline = start + 10
        try game.advance(to: start + 8)
        #expect(game.activeDiamonds.count == 4)
        #expect(game.diamonds.values.allSatisfy { $0.outcome == nil && $0.interactionDeadline == deadline })
        let time = start + 8.1
        // This is well past the normal passage exit of start+4.
        #expect(try collect(&game, generation: generation, ids: [1], capture: time,
                            replacements: [Self.spawn(5, at: time)]).count == 1)
        #expect(game.activeDiamonds.count == 4 && game.teamScore == 25)
        #expect(game.diamonds[Self.id(5)]?.interactionDeadline == deadline)
        try game.advance(to: deadline)
        #expect(game.activeDiamonds.isEmpty)
        #expect(game.diamonds.values.filter { $0.outcome == .closed }.count == 4)
        #expect(game.diamonds.values.allSatisfy {
            if case .missed = $0.outcome { false } else { true }
        })
    }

    @Test func replacementStaysCollectibleAfterItsOwnPassageExit() throws {
        var (game, generation) = try Self.bonus()
        let start = game.gameTime, firstTime = start + 1.2
        let replacement = try Self.spawn(5, at: firstTime, entry: firstTime + 0.1, exit: firstTime + 0.2)
        _ = try collect(&game, generation: generation, ids: [1], capture: firstTime, replacements: [replacement])
        let later = start + 8
        #expect(try collect(&game, generation: generation, ids: [5], capture: later,
                            replacements: [Self.spawn(6, at: later)]).count == 1)
        #expect(game.teamScore == 50 && game.activeDiamonds.count == 4)
    }

    @Test func capLimitsConcurrentDiamondsWithoutLimitingTotalCollections() throws {
        var (game, generation) = try Self.bonus()
        let firstTime = game.gameTime + 1.2
        _ = try collect(&game, generation: generation, ids: Array(1...4), capture: firstTime,
                        replacements: (5...8).map { try Self.spawn($0, at: firstTime) })
        let secondTime = firstTime + 1.2
        _ = try collect(&game, generation: generation, ids: Array(5...8), capture: secondTime,
                        replacements: (9...12).map { try Self.spawn($0, at: secondTime) })
        #expect(game.diamondsCollected == 8 && game.teamScore == 200)
        #expect(game.activeDiamonds.count == 4 && game.diamonds.count == 12)
    }

    @Test func rejectedScoreOverflowLeavesEveryDiamondAndTotalUnchanged() throws {
        var (game, generation) = try Self.game(points: Int.max)
        try game.spawnNormalDiamonds([Self.spawn(1), Self.spawn(2)], beforeVaultAt: 5)
        let before = game.diamonds
        #expect(throws: LaserDataError.self) {
            try collect(&game, generation: generation, ids: [1, 2], capture: 1.1)
        }
        #expect(game.teamScore == 0 && game.diamondsCollected == 0 && game.diamonds == before)
    }

    @Test func pauseAndAbortKeepCollectedScoreAndCloseUnresolvedDiamonds() throws {
        var (game, generation) = try Self.game()
        try game.spawnNormalDiamonds([Self.spawn(1), Self.spawn(2)], beforeVaultAt: 5)
        _ = try collect(&game, generation: generation, ids: [1], capture: 1.1)
        try game.pause(at: 1.2)
        #expect(try collect(&game, generation: generation, ids: [2], capture: 1.3).isEmpty)
        try game.advance(to: 100)
        #expect(game.gameTime == 1.2 && game.activeDiamonds.count == 1)
        game.exit()
        #expect(game.summary?.outcome == .aborted && game.summary?.diamondsCollected == 1)
        #expect(game.summary?.teamScore == 25 && game.diamonds[Self.id(2)]?.outcome == .closed)
    }

    @Test func invalidPlansAndReusedIDsAreRejectedAndVaultEntryNeedsAClearField() throws {
        var (game, generation) = try Self.game()
        #expect(throws: LaserDataError.self) {
            try game.spawnNormalDiamonds([Self.spawn(1, exit: 4)], beforeVaultAt: 3)
        }
        try game.spawnNormalDiamonds([Self.spawn(1, exit: 2)], beforeVaultAt: 3)
        #expect(throws: LaserDataError.self) { try game.openVault(id: Self.id(100), at: 1) }
        _ = try collect(&game, generation: generation, ids: [1], capture: 1.1)
        #expect(throws: LaserDataError.self) {
            try game.spawnNormalDiamonds([Self.spawn(1, at: game.gameTime)], beforeVaultAt: 6)
        }
        try game.openVault(id: Self.id(100), at: 2)
        #expect(game.roundPhase == .vault)
        var (unconfigured, _) = try Self.game(points: nil)
        #expect(throws: LaserDataError.self) {
            try unconfigured.spawnNormalDiamonds([Self.spawn(1)], beforeVaultAt: 5)
        }
        #expect(throws: LaserDataError.self) { try Self.spawn(1, entry: -0.1) }
    }
}
