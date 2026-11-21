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

    /// One wrist of each listed player on that player's activation button; every other hand outside.
    func pressing(_ hands: [PlayerID: LaserContactWrist]) -> [LaserContactHand: Point] {
        var points = outside
        for zone in zones { if let wrist = hands[zone.player] { points[LaserContactHand(playerID: zone.player, wrist: wrist)] = zone.center } }
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
    /// One activation button per player: either wrist presses it, in either order; the vault opens
    /// only once both players have pressed, once.
    @Test func independentPlayersActivateInFreeOrderAndTheVaultOpensOnceBothPressed() throws {
        var fixture = try D09SyntheticVaultFixture()
        #expect(try fixture.receive(frame: 1, capture: 1, points: fixture.outside) == 0)
        #expect(try fixture.receive(frame: 2, capture: 1.1, points: fixture.pressing([.player2: .right])) == 1)
        #expect(fixture.game.missionProgress == 0 && fixture.game.roundPhase == .vault, "one player alone never opens it")
        #expect(fixture.game.vault?.buttons[.player2] == [.activate] && fixture.game.vault?.buttons[.player1]?.isEmpty == true)
        #expect(try fixture.receive(frame: 3, capture: 1.2, points: fixture.outside) == 0)
        // P2 pressing again changes nothing; P1's press opens the vault.
        #expect(try fixture.receive(frame: 4, capture: 1.25, points: fixture.pressing([.player2: .left])) == 0)
        let final = fixture.pressing([.player1: .left])
        #expect(try fixture.receive(frame: 5, capture: 1.3, points: final) == 1)
        #expect(try fixture.receive(frame: 5, capture: 1.3, points: final) == 0)
        #expect(fixture.game.missionProgress == 1)
        #expect(fixture.game.roundPhase == .diamondTime)
        #expect(fixture.game.teamHealth == 5 && fixture.game.teamScore == 0)
        #expect(fixture.game.vault?.buttons.values.allSatisfy { $0 == [.activate] } == true)
        let events = fixture.game.drainEvents()
        #expect(events.filter { if case .coopGateSucceeded = $0.kind { true } else { false } }.count == 1)
        #expect(events.filter { $0.kind == .phaseChanged(.diamondTime) }.count == 1)
    }

    @Test func bothPlayersPressingInTheSameFrameOpensOnce() throws {
        var fixture = try D09SyntheticVaultFixture()
        _ = try fixture.receive(frame: 1, capture: 1, points: fixture.outside)
        let both = fixture.pressing([.player1: .left, .player2: .right])
        #expect(try fixture.receive(frame: 2, capture: 1.1, points: both) == 2)
        #expect(try fixture.receive(frame: 2, capture: 1.1, points: both) == 0)
        #expect(fixture.game.missionProgress == 1)
        #expect(fixture.game.drainEvents().filter { if case .coopGateSucceeded = $0.kind { true } else { false } }.count == 1)
    }

    /// There is no other button: the former HIGH / LOW places are not press targets.
    @Test func eachPlayerHasExactlyOneActivationZone() throws {
        let fixture = try D09SyntheticVaultFixture()
        #expect(LaserVaultButton.allCases == [.activate])
        #expect(fixture.zones.count == PlayerID.allCases.count)
        #expect(Set(fixture.zones.map(\.player)) == Set(PlayerID.allCases))
    }

    @Test func exactCircleBoundaryIsInsideButFirstInsideDoesNotActivate() throws {
        var fixture = try D09SyntheticVaultFixture()
        let hand = LaserContactHand(playerID: .player1, wrist: .left)
        let point = D09SyntheticVaultFixture.Point(x: -0.875, y: 1.5)
        #expect(try fixture.receive(frame: 1, capture: 1, points: [hand: point]) == 0)
        _ = try fixture.receive(frame: 2, capture: 1.1, points: fixture.outside)
        #expect(try fixture.receive(frame: 3, capture: 1.2, points: [hand: point]) == 1)
        #expect(fixture.game.vault?.buttons[.player1] == [.activate])
        #expect(fixture.game.vault?.buttons[.player2]?.isEmpty == true)
    }

    @Test func pauseRetainsACommittedPressButRequiresFreshEntryForTheOtherPlayer() throws {
        var fixture = try D09SyntheticVaultFixture()
        _ = try fixture.receive(frame: 1, capture: 1, points: fixture.outside)
        _ = try fixture.receive(frame: 2, capture: 1.1, points: fixture.pressing([.player1: .left]))
        _ = try fixture.receive(frame: 3, capture: 1.2, points: fixture.outside)
        try fixture.pause(at: 1.2)
        fixture.game.resume()
        #expect(try fixture.receive(frame: 4, capture: 1.3, points: fixture.pressing([.player2: .left])) == 0)
        #expect(fixture.game.vault?.buttons[.player1] == [.activate], "kept across the pause")
        #expect(fixture.game.vault?.deadline == 5 && fixture.game.missionProgress == 0)
        _ = try fixture.receive(frame: 5, capture: 1.4, points: fixture.outside)
        #expect(try fixture.receive(frame: 6, capture: 1.5, points: fixture.pressing([.player2: .left])) == 1)
        #expect(fixture.game.missionProgress == 1)
    }

    @Test(arguments: [4.999, 5.0, 5.001])
    func deadlineRejectsLateBatchWithoutPartialProgress(_ arrival: Double) throws {
        var fixture = try D09SyntheticVaultFixture()
        _ = try fixture.receive(frame: 1, capture: 4.7, points: fixture.outside)
        let result = try fixture.receive(frame: 2, capture: 4.9, arrival: arrival,
                                        points: fixture.pressing([.player1: .left, .player2: .right]))
        #expect(result == (arrival < 5 ? 2 : 0))
        #expect(fixture.game.roundOutcome == (arrival < 5 ? nil : .vaultFailed))
        #expect(fixture.game.teamHealth == 5 && fixture.game.teamScore == 0)
    }

    @Test func batchFiltersWrongGenerationAndCalibrationAndDeduplicatesButtons() throws {
        var fixture = try D09SyntheticVaultFixture()
        let valid = LaserVaultContact(playerID: .player1, button: .activate, calibrationRevision: 1)
        let invalid = LaserVaultContact(playerID: .player2, button: .activate, calibrationRevision: 2)
        #expect(try fixture.game.touchVaultBatch(id: D09SyntheticVaultFixture.vaultID,
            contacts: [valid], generation: UUID(), at: 1) == 0)
        #expect(try fixture.game.touchVaultBatch(id: D09SyntheticVaultFixture.vaultID,
            contacts: [valid, valid, invalid], generation: fixture.generation, at: 1) == 1)
        #expect(fixture.game.vault?.buttons[.player1] == [.activate])
        #expect(fixture.game.vault?.buttons[.player2]?.isEmpty == true)
    }
}
