import Foundation
import Testing
@testable import Sedactive

/// The live round director: the complete replay's schedule rebased onto live game time.
/// Accepted calibrations here are the replay's SYNTHETIC references; no body evidence is
/// supplied, so every laser must end UNAVAILABLE (never CLEAR) and nothing scores.
@MainActor struct LaserLiveRoundDirectorTests {
    struct Rig {
        let input: BodyInputConfiguration
        let context: BodyInputContext
        let configuration: LaserRoundConfiguration
        var director: LaserLiveRoundDirector
        var game: LaserGame
        var registered: [(time: Double, encounter: LaserEncounter)] = []
        var hearts: [LaserDiamondSpawn] = []
        var diamonds: [LaserDiamondSpawn] = []
        var vault: (time: Double, id: UUID, zones: [LaserVaultZone])?

        init(segment: Double = 60) throws {
            let script = try LaserReplayScript.load()
            input = script.input.configuration
            context = BodyInputContext(sessionGeneration: input.sessionGeneration,
                cameraGeometryRevision: script.input.cameraGeometryRevision,
                calibrationRevisions: input.calibrations.mapValues(\.revision), cutovers: [:], isActive: true,
                wristContact: nil)
            configuration = try LaserFullReplayPlan.roundConfiguration()
            director = try LaserLiveRoundDirector(calibrations: input.calibrations, layout: input.playerPlaneLayout,
                configuration: configuration, seed: 3, segmentLength: segment)
            game = try LaserGame(configuration: configuration, context: context, historyCapacityPerPlayer: 120)
            game.configureBoards(try director.boards())
        }

        /// The coordinator's order: each due action at its own exact time, then advance.
        mutating func run(to end: Double, step: Double = 0.05) throws {
            var time = game.gameTime
            while time < end {
                time = min(end, time + step)
                while let due = try director.nextDue(through: time, game: game) {
                    try game.advance(to: max(game.gameTime, due.time))
                    switch due.action {
                    case .heart(let spawn, let boundary):
                        try game.spawnHeart(spawn, beforeVaultAt: boundary)
                        hearts.append(spawn)
                    case .register(let encounter):
                        try game.register(encounter); registered.append((game.gameTime, encounter))
                    case .normalDiamond(let spawn, let boundary):
                        try game.spawnNormalDiamonds([spawn], beforeVaultAt: boundary)
                        diamonds.append(spawn)
                    case .openVault(let id, let zones):
                        try game.openVault(id: id, at: game.gameTime); vault = (game.gameTime, id, zones)
                    }
                }
                try game.advance(to: time)
                if game.roundOutcome != nil { return }
            }
        }

        mutating func pressAllButtons(at time: Double) throws {
            let vault = try #require(self.vault)
            try game.touchVaultBatch(id: vault.id, contacts: vault.zones.map {
                LaserVaultContact(playerID: $0.playerID, button: $0.button,
                                  calibrationRevision: context.calibrationRevisions[$0.playerID]!)
            }, generation: context.sessionGeneration, at: time)
        }
    }

    private func scheduledDiamond(assignedTo player: PlayerID) throws -> LaserDiamondSpawn {
        var rig = try Rig()
        try rig.run(to: 58)
        let spawn = try #require(rig.diamonds.first { $0.placementPlayer == player })
        #expect(spawn.eligiblePlayers == Set(PlayerID.allCases))
        #expect(rig.hearts.allSatisfy { $0.eligiblePlayers.count == 1 && $0.placementPlayer == nil })
        let state = LaserDiamondState(spawn: spawn, lifetime: .passage)
        let presentation = LaserReplayPresentation.normalDiamonds([spawn.id: state], layout: rig.input.playerPlaneLayout)
        #expect(presentation.first?.lane == player)
        return spawn
    }

    @Test(arguments: PlayerID.allCases, [false, true])
    func scheduledCorridorDiamondAcceptsEitherPlayersWrist(assigned: PlayerID, assignedPlayerCollects: Bool) throws {
        let spawn = try scheduledDiamond(assignedTo: assigned)
        let collector = try #require(PlayerID.allCases.first { ($0 == assigned) == assignedPlayerCollects })
        let hand = LaserContactHand(playerID: collector, wrist: .left)
        let fixture = try WristGameplayFixture()
        var game = try fixture.game()
        try game.advance(to: spawn.spawnedAt)
        try game.spawnNormalDiamonds([spawn], beforeVaultAt: 60)
        var consumer = try LaserWristDiamondConsumer(configuration: fixture.plan(), context: fixture.context,
                                                      lifetime: UUID(), afterCapturedAt: 100)
        try game.advance(to: spawn.entry)
        try consumer.refresh(game: game, context: fixture.context, atHostTime: 100 + spawn.entry)
        let target = WristPlanePoint(x: spawn.position.x, y: spawn.position.y)
        try fixture.send(&consumer, &game, frame: 3, capture: spawn.entry + 0.125,
                         points: [hand: WristGameplayFixture.outside])
        let accepted = try fixture.send(&consumer, &game, frame: 4, capture: spawn.entry + 0.25,
                                        points: [hand: target])
        #expect(accepted == [.init(targetID: spawn.id, hand: hand)])
        #expect(game.teamScore == 25 && game.diamondsCollected == 1)
    }

    @Test(arguments: PlayerID.allCases)
    func scheduledCorridorDiamondAcceptsOtherPlayersBody(assigned: PlayerID) throws {
        let spawn = try scheduledDiamond(assignedTo: assigned)
        let collector = try #require(PlayerID.allCases.first { $0 != assigned })
        let fixture = try WristGameplayFixture()
        var game = try fixture.game()
        try game.advance(to: spawn.spawnedAt)
        try game.spawnNormalDiamonds([spawn], beforeVaultAt: 60)
        var consumer = try LaserWristDiamondConsumer(configuration: fixture.plan(), context: fixture.context,
                                                      lifetime: UUID(), afterCapturedAt: 100)
        try game.advance(to: spawn.entry)
        try consumer.receiveBodyContacts([spawn.id: [collector]], context: fixture.context,
                                         atHostTime: 100 + spawn.entry, game: &game)
        #expect(game.diamonds[spawn.id]?.outcome == .collectedByBody(player: collector, at: spawn.entry))
        #expect(game.teamScore == 25 && game.diamondsCollected == 1)
    }

    @Test(arguments: [false, true])
    func simultaneousSharedContactsRespectValidityAndDeadline(atDeadline: Bool) throws {
        let spawn = try scheduledDiamond(assignedTo: .player2)
        let fixture = try WristGameplayFixture()
        var game = try fixture.game()
        try game.advance(to: spawn.spawnedAt)
        try game.spawnNormalDiamonds([spawn], beforeVaultAt: 60)
        let hands = [WristGameplayFixture.left, WristGameplayFixture.p2]
        let contacts = hands.map { LaserContactActivation(targetID: spawn.id, hand: $0) }
        let bodies = [spawn.id: Set(PlayerID.allCases)]
        let time = atDeadline ? spawn.exit : spawn.entry + 0.25
        let invalid = try game.collectDiamonds(contacts, generation: fixture.context.sessionGeneration,
            calibrationRevisions: [.player1: 99, .player2: 99], capturedAt: time, arrivedAt: time, bodyContacts: bodies)
        #expect(invalid.isEmpty && game.teamScore == 0)
        for _ in 0..<2 {
            try game.collectDiamonds(contacts, generation: fixture.context.sessionGeneration,
                calibrationRevisions: fixture.context.calibrationRevisions, capturedAt: time, arrivedAt: time,
                bodyContacts: bodies)
        }
        #expect(game.teamScore == (atDeadline ? 0 : 25))
        #expect(game.diamondsCollected == (atDeadline ? 0 : 1))
    }

    @Test func theLiveRoundUsesTheCompleteReplaySchedule() throws {
        let rig = try Rig()
        // The same five-minute script the complete replay schedules (73 encounters).
        #expect(rig.director.baseEncounters.count == 73)
        for encounter in rig.director.baseEncounters {
            for target in encounter.targets {
                #expect(target.calibrationRevision == rig.context.calibrationRevisions[target.playerID])
            }
        }
        #expect(rig.director.diamondRadius > 0)
    }

    @Test func minuteOneRegistersAtWarningTimesAndTheVaultWaitsForEveryVerdict() throws {
        var rig = try Rig()
        try rig.run(to: 59.9)
        let minute = rig.director.baseEncounters.filter { $0.targets[0].crossingTime < 60 }
        #expect(rig.registered.count == minute.count)
        for (time, encounter) in rig.registered {
            // At its own warning time; one with a LEAN target 1 s earlier, when its beam is placed (vertical lasers).
            #expect(abs(time - LaserLiveRoundDirector.registrationTime(encounter)) < 1e-9, "registered at its own time")
            #expect(LaserLiveRoundDirector.registrationTime(encounter) == (encounter.targets.contains { $0.requiredMove == .lean }
                ? encounter.targets[0].crossingTime - LaserBoardGeometry.revealLead : encounter.targets[0].warningTime))
        }
        #expect(rig.vault == nil && rig.game.roundPhase == .activity)
        #expect(rig.hearts.count == 1 && rig.hearts.allSatisfy { $0.spawnedAt > 0 && $0.exit < 60 })
        try rig.run(to: 61)
        let vault = try #require(rig.vault)
        #expect(vault.time >= 60 && rig.game.roundPhase == .vault)
        #expect(rig.game.heart == nil)
        #expect(rig.game.pendingCrossingCount == 0, "the vault never withdraws a laser")
        // No body evidence was delivered: every verdict is UNAVAILABLE, nothing cleared or hit.
        #expect(rig.game.playerStats.values.allSatisfy { $0.cleared == 0 && $0.hit == 0 })
        #expect(rig.game.teamHealth == rig.configuration.initialTeamHealth && rig.game.teamScore == 0)
        // One activation zone per player, on each player's outer side (P1 plane +X, P2 −X).
        #expect(vault.zones.count == 2 && Set(vault.zones.map(\.playerID)) == Set(PlayerID.allCases))
        for zone in vault.zones {
            let lane = rig.input.playerPlaneLayout.centerX(for: zone.playerID)
            #expect((zone.position.x - lane) * LaserLiveRoundGeometryV1.outward(zone.playerID) > 0)
        }
    }

    @Test func aLongerLiveVaultMovesTheNextMinuteNotItsSpacing() throws {
        var rig = try Rig()
        try rig.run(to: 61)
        let opened = try #require(rig.vault?.time)
        // The players take 3.5 s of the 5 s vault.
        try rig.run(to: opened + 3.5)
        try rig.pressAllButtons(at: opened + 3.5)
        #expect(rig.game.roundPhase == .activity && rig.game.missionProgress == 1)
        let before = rig.registered.count
        try rig.run(to: opened + 3.5 + 30)
        let next = rig.registered.dropFirst(before)
        let first = try #require(next.first?.encounter)
        let base = try #require(rig.director.baseEncounters.first { $0.id == first.id })
        #expect(abs(first.targets[0].warningTime - (opened + 3.5 + base.targets[0].warningTime - 60)) < 0.06)
        #expect(Set(next.map(\.encounter.attemptID)).count == next.count)
    }

    @Test func aVaultNobodyPressesEndsTheRound() throws {
        var rig = try Rig()
        try rig.run(to: 70)
        #expect(rig.game.roundOutcome == .vaultFailed && rig.game.summary != nil)
    }

    @Test func fullLiveRoundSchedulesElevenHeartsWithoutOverlappingPassages() throws {
        var rig = try Rig()
        var stageStart = 0.0
        for expected in [1, 2, 2, 3, 3] {
            let previousCount = rig.hearts.count
            try rig.run(to: stageStart + 60)
            let vault = try #require(rig.vault)
            let hearts = rig.hearts.dropFirst(previousCount)
            #expect(hearts.count == expected)
            #expect(hearts.allSatisfy { $0.spawnedAt > stageStart && $0.exit < vault.time })
            for (first, second) in zip(hearts, hearts.dropFirst()) {
                #expect(first.exit < second.spawnedAt)
            }
            stageStart = vault.time + 1
            try rig.pressAllButtons(at: stageStart)
        }
        #expect(rig.hearts.count == 11 && Set(rig.hearts.map(\.id)).count == 11)
        #expect(rig.game.roundPhase == .diamondTime && rig.game.heart == nil)
    }

    @Test func recoveryKeepsMoveBeamAndWarningAndShiftsTheRestOfTheMinute() throws {
        var rig = try Rig()
        try rig.run(to: 20)
        let boundary = try #require(rig.director.vaultBoundary)
        let withdrawn = Array(rig.registered.suffix(2).map(\.encounter))
        let request = LaserLiveRecoveryRequest(withdrawn: withdrawn, gameTime: 25, hostTime: 100, context: rig.context)
        let replacements = try rig.director.recover(request)
        try LaserLiveRecovery.validate(replacements, request: request, configuration: rig.configuration,
                                       boundary: rig.director.vaultBoundary)
        #expect(Set(replacements.map(\.id)) == Set(withdrawn.map(\.id)))
        #expect(Set(replacements.map(\.attemptID)).isDisjoint(with: withdrawn.map(\.attemptID)))
        let delta = try #require(rig.director.vaultBoundary) - boundary
        #expect(delta >= 0)
        for replacement in replacements {
            let old = try #require(withdrawn.first { $0.id == replacement.id })
            #expect(replacement.targets[0].beam == old.targets[0].beam
                && replacement.targets[0].requiredMove == old.targets[0].requiredMove)
            #expect(abs(replacement.targets[0].crossingTime - old.targets[0].crossingTime - delta) < 1e-9)
            #expect(replacement.targets[0].warningTime >= request.gameTime)
        }
    }

    #if DEBUG
    @Test func theDebugShortRoundPlaysTheSameScriptsOpeningSeconds() throws {
        var rig = try Rig(segment: 15)
        let all = try Rig().director.baseEncounters
        #expect(Set(rig.director.baseEncounters.map(\.id)).isSubset(of: all.map(\.id)))
        #expect(rig.director.baseEncounters.count < all.count && !rig.director.baseEncounters.isEmpty)
        try rig.run(to: 16)
        #expect(rig.vault != nil && rig.game.roundPhase == .vault)
        #expect(AppDependencies.liveSegmentLength(arguments: ["-liveShortRound", "15"]) == 15)
        #expect(AppDependencies.liveSegmentLength(arguments: ["-liveShortRound", "3"]) == 60)
    }
    #endif
}
