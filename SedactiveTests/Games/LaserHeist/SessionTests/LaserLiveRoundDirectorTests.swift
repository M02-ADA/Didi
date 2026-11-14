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
        }

        /// The coordinator's order: each due action at its own exact time, then advance.
        mutating func run(to end: Double, step: Double = 0.05) throws {
            var time = game.gameTime
            while time < end {
                time = min(end, time + step)
                while let due = try director.nextDue(through: time, game: game) {
                    try game.advance(to: max(game.gameTime, due.time))
                    switch due.action {
                    case .register(let encounter):
                        try game.register(encounter); registered.append((game.gameTime, encounter))
                    case .normalDiamond(let spawn, let boundary):
                        try game.spawnNormalDiamonds([spawn], beforeVaultAt: boundary)
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

    @Test func theLiveRoundUsesTheCompleteReplaySchedule() throws {
        let rig = try Rig()
        // The same five-minute script the complete replay schedules (50 encounters).
        #expect(rig.director.baseEncounters.count == 50)
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
            #expect(abs(time - encounter.targets[0].warningTime) < 1e-9, "registered at its own warning time")
        }
        #expect(rig.vault == nil && rig.game.roundPhase == .activity)
        try rig.run(to: 61)
        let vault = try #require(rig.vault)
        #expect(vault.time >= 60 && rig.game.roundPhase == .vault)
        #expect(rig.game.pendingCrossingCount == 0, "the vault never withdraws a laser")
        // No body evidence was delivered: every verdict is UNAVAILABLE, nothing cleared or hit.
        #expect(rig.game.playerStats.values.allSatisfy { $0.cleared == 0 && $0.hit == 0 })
        #expect(rig.game.teamHealth == rig.configuration.initialTeamHealth && rig.game.teamScore == 0)
        // Six zones, three per player, on each player's outer side (P1 plane +X, P2 −X).
        #expect(vault.zones.count == 6)
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
