import Foundation
import Testing
@testable import Sedactive

/// Combined deterministic domain replay. Contact actions are test-only admitted
/// membership, not a new CP1 schema or a second producer/gameplay subscriber.
@MainActor
struct D09CompleteRoundTests {
    private enum Action {
        case base(FullRoundReplayScenario.Action)
        case normalSpawn(Int, boundary: Double), normalOutside(Int), normalInside(Int)
        case vaultOutside(PlayerID, LaserVaultButton)
        case bonusOutside, bonusInside(Int), bonusPersistenceCheck
    }
    private struct Step { let sourceTime: Double; let order: Int; let action: Action }
    private struct VaultKey: Hashable { let player: PlayerID; let button: LaserVaultButton }
    private struct Trace: Equatable {
        let summary: RoundSummary
        let events: [GameEvent]
        let diamonds: [UUID: LaserDiamondState]
        let maximumHistory: Int
    }

    private func run(_ mode: FullRoundReplayCase = .allClear) async throws -> Trace {
        let scenario = try FullRoundReplayScenario.make(mode, base: LH00TestData.load("cooperative-v2"))
        let config = try LaserRoundConfiguration(evidenceTiming: scenario.configuration.evidenceTiming,
            clearanceMargin: scenario.configuration.clearanceMargin,
            diamondPoints: LaserRoundConfiguration.approvedDiamondPoints, scheduling: scenario.configuration.scheduling)
        var steps = scenario.steps.map { Step(sourceTime: $0.sourceTime, order: $0.order, action: .base($0.action)) }
        func add(_ time: Double, _ action: Action) {
            steps.append(Step(sourceTime: time, order: steps.count, action: action))
        }
        let vaultStarts = scenario.steps.filter { if case .openVault = $0.action { true } else { false } }
        let vaultTouches = scenario.steps.filter { if case .touchVault = $0.action { true } else { false } }
        for step in vaultTouches {
            if case .touchVault(_, let player, let button) = step.action {
                add(step.sourceTime - 0.05, .vaultOutside(player, button))
            }
        }
        var number = 0
        for minute in 0..<5 {
            let beginning = minute == 0 ? 0 : vaultStarts[minute - 1].sourceTime + 1.2
            let boundary = vaultStarts[minute].sourceTime
            let count = 2 + minute * 2 // Confirmed normal team ranges: 2, 4, 6, 8, 10 = 30.
            for index in 0..<count {
                number += 1
                let time = beginning + 2 + Double(index) * 50 / Double(count)
                add(time, .normalSpawn(number, boundary: boundary))
                add(time + 0.5, .normalOutside(number))
                add(time + 0.6, .normalInside(number))
            }
        }
        let bonusStart = try #require(vaultTouches.last).sourceTime
        add(bonusStart + 1, .bonusOutside)
        add(bonusStart + 1.1, .bonusInside(0))
        add(bonusStart + 2.1, .bonusOutside)
        add(bonusStart + 2.2, .bonusInside(1))
        add(bonusStart + 7, .bonusPersistenceCheck)
        steps.sort { $0.sourceTime == $1.sourceTime ? $0.order < $1.order : $0.sourceTime < $1.sourceTime }

        let source = try ReplayBodyInput(fixture: scenario.fixture)
        try await source.start(configuration: scenario.fixture.configuration)
        let context = try #require(source.currentContext)
        let stream = try source.snapshotStream(generation: context.sessionGeneration)
        var iterator = stream.makeAsyncIterator()
        var clock = try GameClock(sourceTime: 0)
        var game = try LaserGame(configuration: config, context: context, historyCapacityPerPlayer: 120)
        let lifetime = UUID(uuidString: "D0960000-0000-4000-8000-000000000001")!
        var tracker = try LaserContactEntryTracker(lifetime: lifetime, maximumContactAge: 0.5)
        var contactFrame: UInt64 = 0, maximumHistory = 0
        var events: [GameEvent] = [], vaultTargets: [VaultKey: UUID] = [:]
        var currentVault: UUID?, vaultIndex = 0

        func contact(_ membership: [UUID: [LaserContactHand: LaserContactLocation]]) throws -> [LaserContactActivation] {
            contactFrame += 1 // Domain fixture stamp only; never masquerades as CP1 frame provenance.
            return try tracker.evaluate(lifetime: lifetime, frameID: contactFrame,
                capturedAt: clock.gameTime, arrivedAt: clock.gameTime, locations: membership)
        }
        func diamondTarget(_ spawn: LaserDiamondSpawn) throws -> LaserContactTarget {
            try LaserContactTarget(id: spawn.id, eligiblePlayers: spawn.eligiblePlayers,
                activation: spawn.entry, deadline: #require(game.diamonds[spawn.id]?.interactionDeadline))
        }
        do {
            for step in steps {
                try clock.advance(to: step.sourceTime)
                if case .base(.packet) = step.action {
                    try source.advance(to: step.sourceTime)
                    let snapshot = try #require(await iterator.next(isolation: MainActor.shared))
                    let capture = try #require(clock.gameTime(forCaptureTime: snapshot.capturedAt))
                    try game.receive(snapshot, capturedGameTime: capture, arrivedAt: clock.gameTime)
                } else {
                    try game.advance(to: clock.gameTime)
                    if game.roundOutcome == nil {
                        switch step.action {
                        case .base(.register(let encounter)): try game.register(encounter)
                        case .base(.openVault(let id)):
                            try game.openVault(id: id, at: clock.gameTime)
                            currentVault = id
                            vaultTargets.removeAll()
                            var targets: [LaserContactTarget] = []
                            for (playerIndex, player) in PlayerID.allCases.enumerated() {
                                for (buttonIndex, button) in LaserVaultButton.allCases.enumerated() {
                                    let id = UUID(uuidString: String(format: "D0960000-0000-4000-8000-%012d",
                                        100 + vaultIndex * 6 + playerIndex * 3 + buttonIndex))!
                                    vaultTargets[VaultKey(player: player, button: button)] = id
                                    targets.append(try LaserContactTarget(id: id, eligiblePlayers: [player],
                                        activation: clock.gameTime, deadline: clock.gameTime + 5))
                                }
                            }
                            try tracker.replaceTargets(targets)
                            vaultIndex += 1
                        case .vaultOutside(let player, let button):
                            let id = try #require(vaultTargets[VaultKey(player: player, button: button)])
                            _ = try contact([id: [LaserContactHand(playerID: player, wrist: .left): .outside]])
                        case .base(.touchVault(_, let player, let button)):
                            let id = try #require(vaultTargets[VaultKey(player: player, button: button)])
                            let batch = try contact([id: [LaserContactHand(playerID: player, wrist: .left): .inside]])
                            #expect(batch.count == 1)
                            try game.touchVaultBatch(id: #require(currentVault), contacts: batch.map { _ in
                                LaserVaultContact(playerID: player, button: button, calibrationRevision: 1)
                            }, generation: context.sessionGeneration, at: clock.gameTime)
                            if game.roundPhase == .diamondTime {
                                let spawns = try (100...103).map { try LaserDiamondTests.spawn($0, at: clock.gameTime) }
                                try game.startDiamondTimeDiamonds(spawns)
                                try tracker.replaceTargets(spawns.map(diamondTarget))
                            }
                        case .normalSpawn(let number, let boundary):
                            let spawn = try LaserDiamondTests.spawn(number, at: clock.gameTime,
                                entry: clock.gameTime + 0.5, exit: clock.gameTime + 1.5)
                            try game.spawnNormalDiamonds([spawn], beforeVaultAt: boundary)
                            try tracker.addTargets([diamondTarget(spawn)])
                        case .normalOutside(let number):
                            let hand = LaserContactHand(playerID: number.isMultiple(of: 2) ? .player1 : .player2, wrist: .left)
                            _ = try contact([LaserDiamondTests.id(number): [hand: .outside]])
                        case .normalInside(let number):
                            let hand = LaserContactHand(playerID: number.isMultiple(of: 2) ? .player1 : .player2, wrist: .left)
                            let batch = try contact([LaserDiamondTests.id(number): [hand: .inside]])
                            #expect(batch.count == 1)
                            let collected = try game.collectDiamonds(batch, generation: context.sessionGeneration,
                                calibrationRevisions: context.calibrationRevisions,
                                capturedAt: clock.gameTime, arrivedAt: clock.gameTime)
                            #expect(collected.count == 1)
                            tracker.removeTargets(Set(collected.map(\.targetID)))
                        case .bonusOutside:
                            let outside = Dictionary(uniqueKeysWithValues: LaserContactHand.ordered.map { ($0, LaserContactLocation.outside) })
                            _ = try contact(Dictionary(uniqueKeysWithValues: game.activeDiamonds.map { ($0.id, outside) }))
                        case .bonusInside(let wave):
                            let active = game.activeDiamonds
                            #expect(active.count == 4)
                            let membership = Dictionary(uniqueKeysWithValues: active.enumerated().map {
                                ($0.element.id, [LaserContactHand.ordered[$0.offset]: LaserContactLocation.inside])
                            })
                            let batch = try contact(membership)
                            let replacements = try (0..<4).map {
                                try LaserDiamondTests.spawn(104 + wave * 4 + $0, at: clock.gameTime)
                            }
                            let accepted = try game.collectDiamonds(batch, generation: context.sessionGeneration,
                                calibrationRevisions: context.calibrationRevisions, capturedAt: clock.gameTime,
                                arrivedAt: clock.gameTime, replacements: replacements)
                            #expect(accepted.count == 4 && game.activeDiamonds.count == 4)
                            tracker.removeTargets(Set(accepted.map(\.targetID)))
                            try tracker.addTargets(replacements.map(diamondTarget))
                        case .bonusPersistenceCheck:
                            #expect(game.activeDiamonds.count == 4)
                            #expect(game.diamonds.count == 42) // Only collections created replacements.
                        case .base(.tick): break
                        default: Issue.record("Unexpected action in the controlled D09 round")
                        }
                    }
                }
                maximumHistory = max(maximumHistory, game.historyCount)
                events.append(contentsOf: game.drainEvents())
                if let summary = game.summary {
                    let trace = Trace(summary: summary, events: events, diamonds: game.diamonds, maximumHistory: maximumHistory)
                    try game.advance(to: clock.gameTime + 10)
                    #expect(game.summary == summary && game.teamScore == summary.teamScore)
                    await source.stop()
                    return trace
                }
            }
            throw LaserDataError.invalidValue("combined D09 fixture did not terminate")
        } catch {
            await source.stop()
            throw error
        }
    }

    @Test func fullRoundCombinesLaserContactsNormalDiamondsVaultsAndBonusTotals() async throws {
        let trace = try await run()
        #expect(trace.summary.outcome == .completed && trace.summary.remainingTeamHealth == 5)
        #expect(trace.summary.teamScore == 10_950 && trace.summary.diamondsCollected == 38)
        #expect(trace.summary.vaultsOpened == 5 && trace.summary.targets.allSatisfy { $0.scheduled == 50 && $0.cleared == 50 })
        #expect(abs(trace.summary.gameDuration - 316) < 1e-8)
        #expect(abs(trace.summary.activityDuration - 310) < 1e-8)
        #expect(trace.maximumHistory <= 240)
        #expect(trace.events.last?.kind == .roundEnded(.completed))
        #expect(trace.events.filter { if case .coopGateSucceeded = $0.kind { true } else { false } }.count == 5)
    }

    @Test func completeRoundIsDeterministicAndDuplicateCP1DeliveryDoesNotMultiplyAwards() async throws {
        let first = try await run()
        let second = try await run()
        let duplicates = try await run(.duplicateFrames)
        #expect(first == second)
        #expect(first.summary == duplicates.summary && first.diamonds == duplicates.diamonds)
        #expect(first.events == duplicates.events)
    }
}
