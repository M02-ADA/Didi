import Foundation
import Testing
@testable import Sedactive

/// Explicit test-only circles. These dimensions are not production mapping/reach approval.
nonisolated struct D09SyntheticVaultFixture {
    struct Point { let x: Double; let y: Double }
    struct Zone {
        let id: UUID
        let player: PlayerID
        let button: LaserVaultButton
        let center: Point
        let radius = 0.125
    }
    static let vaultID = UUID(uuidString: "D0940000-0000-4000-8000-000000000001")!
    let generation: UUID
    let zones: [Zone]
    var lifetime = UUID()
    var tracker: LaserContactEntryTracker
    var game: LaserGame

    init(missionTarget: Int = 1) throws {
        let scenario = try LaserReplayScenarios.make()[0]
        generation = scenario.input.configuration.sessionGeneration
        let context = BodyInputContext(sessionGeneration: generation, cameraGeometryRevision: 1,
            calibrationRevisions: [.player1: 1, .player2: 1], cutovers: [:], isActive: true)
        let config = try LaserRoundConfiguration(evidenceTiming: scenario.configuration.evidenceTiming,
            clearanceMargin: 0.005, diamondPoints: 25, missionGateTarget: missionTarget)
        game = try LaserGame(configuration: config, context: context, historyCapacityPerPlayer: 20)
        zones = PlayerID.allCases.enumerated().flatMap { index, player in
            LaserVaultButton.allCases.enumerated().map { offset, button in
                Zone(id: UUID(uuidString: String(format: "D0940000-0000-4000-8000-%012d", 10 + index * 3 + offset))!,
                    player: player, button: button, center: Point(x: player == .player1 ? -1 : 1,
                                                                y: 1.5 - Double(offset) * 0.5))
            }
        }
        tracker = try LaserContactEntryTracker(lifetime: lifetime, maximumContactAge: 0.5)
        try tracker.replaceTargets(zones.map {
            try LaserContactTarget(id: $0.id, eligiblePlayers: [$0.player], activation: 0, deadline: 5)
        })
        try game.openVault(id: Self.vaultID, at: 0)
    }

    var outside: [LaserContactHand: Point] {
        Dictionary(uniqueKeysWithValues: LaserContactHand.ordered.map { ($0, Point(x: 0, y: 0)) })
    }

    func points(_ buttons: [LaserContactWrist: LaserVaultButton]) -> [LaserContactHand: Point] {
        var points = outside
        for zone in zones {
            for (wrist, button) in buttons where zone.button == button {
                points[LaserContactHand(playerID: zone.player, wrist: wrist)] = zone.center
            }
        }
        return points
    }

    @discardableResult
    mutating func receive(frame: UInt64, capture: Double, arrival: Double? = nil,
                          points: [LaserContactHand: Point]) throws -> Int {
        guard !game.isPaused, game.roundOutcome == nil else { return 0 }
        let arrival = arrival ?? capture
        let membership = Dictionary(uniqueKeysWithValues: zones.map { zone in
            (zone.id, Dictionary(uniqueKeysWithValues: points.map { hand, point in
                (hand, hypot(point.x - zone.center.x, point.y - zone.center.y) <= zone.radius
                    ? LaserContactLocation.inside : .outside)
            }))
        })
        let batch = try tracker.evaluate(lifetime: lifetime, frameID: frame, capturedAt: capture,
                                        arrivedAt: arrival, locations: membership)
        let commands = batch.compactMap { activation -> LaserVaultContact? in
            guard let zone = zones.first(where: { $0.id == activation.targetID }) else { return nil }
            return LaserVaultContact(playerID: activation.hand.playerID, button: zone.button, calibrationRevision: 1)
        }
        let count = try game.touchVaultBatch(id: Self.vaultID, contacts: commands, generation: generation, at: arrival)
        try game.advance(to: arrival)
        return count
    }

    mutating func pause(at time: Double) throws {
        try game.pause(at: time)
        lifetime = UUID()
        try tracker.invalidate(lifetime: lifetime, capturedAfter: time)
    }
}

nonisolated struct D09SyntheticVaultTests {
    @Test func independentHandsActivateFreeOrderAndSameFrameCompletionOpensOnce() throws {
        var fixture = try D09SyntheticVaultFixture()
        #expect(try fixture.receive(frame: 1, capture: 1, points: fixture.outside) == 0)
        #expect(try fixture.receive(frame: 2, capture: 1.1,
                                   points: fixture.points([.left: .bottom, .right: .top])) == 4)
        #expect(fixture.game.missionProgress == 0)
        #expect(try fixture.receive(frame: 3, capture: 1.2, points: fixture.outside) == 0)
        let final = fixture.points([.left: .middle, .right: .middle])
        #expect(try fixture.receive(frame: 4, capture: 1.3, points: final) == 2)
        #expect(try fixture.receive(frame: 4, capture: 1.3, points: final) == 0)
        #expect(fixture.game.missionProgress == 1)
        #expect(fixture.game.roundPhase == .diamondTime)
        #expect(fixture.game.teamHealth == 5 && fixture.game.teamScore == 0)
        #expect(fixture.game.vault?.buttons.values.allSatisfy { $0.count == 3 } == true)
        let events = fixture.game.drainEvents()
        #expect(events.filter { if case .coopGateSucceeded = $0.kind { true } else { false } }.count == 1)
        #expect(events.filter { $0.kind == .phaseChanged(.diamondTime) }.count == 1)
    }

    @Test func exactCircleBoundaryIsInsideButFirstInsideDoesNotActivate() throws {
        var fixture = try D09SyntheticVaultFixture()
        let hand = LaserContactHand(playerID: .player1, wrist: .left)
        let point = D09SyntheticVaultFixture.Point(x: -0.875, y: 0.5)
        #expect(try fixture.receive(frame: 1, capture: 1, points: [hand: point]) == 0)
        _ = try fixture.receive(frame: 2, capture: 1.1, points: fixture.outside)
        #expect(try fixture.receive(frame: 3, capture: 1.2, points: [hand: point]) == 1)
        #expect(fixture.game.vault?.buttons[.player1] == [.bottom])
        #expect(fixture.game.vault?.buttons[.player2]?.isEmpty == true)
    }

    @Test func pauseRetainsCommittedButtonsButRequiresFreshEntryForRemainingOnes() throws {
        var fixture = try D09SyntheticVaultFixture()
        _ = try fixture.receive(frame: 1, capture: 1, points: fixture.outside)
        _ = try fixture.receive(frame: 2, capture: 1.1, points: fixture.points([.left: .top]))
        _ = try fixture.receive(frame: 3, capture: 1.2, points: fixture.outside)
        try fixture.pause(at: 1.2)
        fixture.game.resume()
        #expect(try fixture.receive(frame: 4, capture: 1.3, points: fixture.points([.left: .middle])) == 0)
        _ = try fixture.receive(frame: 5, capture: 1.4, points: fixture.outside)
        #expect(try fixture.receive(frame: 6, capture: 1.5, points: fixture.points([.left: .middle])) == 2)
        #expect(fixture.game.vault?.buttons[.player1] == [.top, .middle])
        #expect(fixture.game.vault?.deadline == 5)
        #expect(fixture.game.activityProgress == 0)
    }

    @Test(arguments: [4.999, 5.0, 5.001])
    func deadlineRejectsLateBatchWithoutPartialProgress(_ arrival: Double) throws {
        var fixture = try D09SyntheticVaultFixture()
        _ = try fixture.receive(frame: 1, capture: 4.7, points: fixture.outside)
        let result = try fixture.receive(frame: 2, capture: 4.9, arrival: arrival,
                                        points: fixture.points([.left: .top, .right: .bottom]))
        #expect(result == (arrival < 5 ? 4 : 0))
        #expect(fixture.game.roundOutcome == (arrival < 5 ? nil : .vaultFailed))
        #expect(fixture.game.teamHealth == 5 && fixture.game.teamScore == 0)
    }

    @Test func batchFiltersWrongGenerationAndCalibrationAndDeduplicatesButtons() throws {
        var fixture = try D09SyntheticVaultFixture()
        let valid = LaserVaultContact(playerID: .player1, button: .top, calibrationRevision: 1)
        let invalid = LaserVaultContact(playerID: .player2, button: .top, calibrationRevision: 2)
        #expect(try fixture.game.touchVaultBatch(id: D09SyntheticVaultFixture.vaultID,
            contacts: [valid], generation: UUID(), at: 1) == 0)
        #expect(try fixture.game.touchVaultBatch(id: D09SyntheticVaultFixture.vaultID,
            contacts: [valid, valid, invalid], generation: fixture.generation, at: 1) == 1)
        #expect(fixture.game.vault?.buttons[.player1] == [.top])
        #expect(fixture.game.vault?.buttons[.player2]?.isEmpty == true)
    }
}
