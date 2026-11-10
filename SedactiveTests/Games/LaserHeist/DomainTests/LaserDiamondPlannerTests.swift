import Foundation
import Testing
@testable import Sedactive

nonisolated struct LaserDiamondPlannerTests {
    static func planner(seed: UInt64 = 1) throws -> LaserDiamondPlanner {
        try LaserDiamondPlanner(seed: seed, placements: (0..<8).map {
            try LaserDiamondPlacement(position: LaserDiamondPosition(x: Double($0), y: 1),
                                      eligiblePlayers: [$0.isMultiple(of: 2) ? .player1 : .player2])
        }, approachLead: 0.5, passageDuration: 1)
    }

    @Test(arguments: [UInt64(0), 1, 12345])
    func seededMinutesHaveStableIDsPositionsAndDeclaredTeamCounts(_ seed: UInt64) throws {
        var first = try Self.planner(seed: seed), second = try Self.planner(seed: seed)
        for minute in 0..<5 {
            let start = Double(minute * 60)
            let plan = try first.normalMinute(minute, from: start, until: start + 60)
            let repeated = try second.normalMinute(minute, from: start, until: start + 60)
            #expect(plan == repeated)
            #expect((2 + minute * 2 ... 4 + minute * 2).contains(plan.count))
            #expect(plan.allSatisfy { $0.spawnedAt > start && $0.entry > $0.spawnedAt && $0.exit < start + 60 })
            #expect(Set(plan.map(\.id)).count == plan.count)
        }
    }

    @Test func differentSeedsChangePlacementAndFailureDoesNotConsumePlannerState() throws {
        var first = try Self.planner(seed: 1), second = try Self.planner(seed: 2)
        #expect(try first.normalMinute(0, from: 0, until: 60) != second.normalMinute(0, from: 0, until: 60))
        var reference = first
        #expect(throws: LaserDataError.self) { try first.bonusInitial(at: 10, deadline: 10) }
        #expect(try first.bonusInitial(at: 10, deadline: 20) == reference.bonusInitial(at: 10, deadline: 20))
    }

    @Test func longBonusKeepsBoundedHistoryWithoutPickupQuotaOrRetiredIDAwards() throws {
        var planner = try Self.planner()
        var field = LaserDiamondField()
        let initial = try planner.bonusInitial(at: 0, deadline: 10)
        try field.spawn(initial, at: 0, before: 10, maximumActive: 4, bonusDeadline: 10)
        for step in 1...200 {
            let time = Double(step) / 100
            let old = field.active
            let contacts = old.map { LaserContactActivation(targetID: $0.id,
                hand: LaserContactHand(playerID: $0.eligiblePlayers.first!, wrist: .left)) }
            let replacements = try planner.bonusReplacements(collected: old, surviving: [], at: time, deadline: 10)
            #expect(try field.collect(contacts, capturedAt: time, arrivedAt: time,
                                      replacements: replacements, bonusDeadline: 10).count == 4)
            #expect(field.active.count == 4)
            #expect(field.states.count <= LaserDiamondField.retainedTerminalLimit + 4)
        }
        #expect(field.collectedCount == 800)
        #expect(field.states[initial[0].id] == nil)
        let reused = try LaserDiamondSpawn(id: initial[0].id, position: initial[0].position,
            eligiblePlayers: initial[0].eligiblePlayers, spawnedAt: 3, entry: 3, exit: 10)
        #expect(throws: LaserDataError.self) {
            try field.spawn([reused], at: 3, before: 10, maximumActive: 4, bonusDeadline: 10)
        }
        #expect(try field.collect([LaserContactActivation(targetID: initial[0].id,
            hand: LaserDiamondTests.firstHand)], capturedAt: 3, arrivedAt: 3,
            replacements: [], bonusDeadline: 10).isEmpty)
        #expect(field.collectedCount == 800)
    }
}
