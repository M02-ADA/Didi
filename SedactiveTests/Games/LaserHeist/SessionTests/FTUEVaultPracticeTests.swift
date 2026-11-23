import Foundation
import Testing
@testable import Sedactive

@MainActor struct FTUEVaultPracticeTests {
    static func makePractice(_ fixture: WristGameplayFixture, solo: Bool = false, at time: Double = 0) throws -> FTUEVaultPractice {
        let roster = solo ? [.player1] : PlayerID.allCases
        let base = fixture.context
        let context = BodyInputContext(sessionGeneration: base.sessionGeneration, cameraGeometryRevision: base.cameraGeometryRevision,
            calibrationRevisions: base.calibrationRevisions.filter { roster.contains($0.key) },
            cutovers: base.cutovers.filter { roster.contains($0.key) }, isActive: true, wristContact: base.wristContact)
        let calibrations = try LaserReplayScript.load().input.configuration.calibrations.filter { roster.contains($0.key) }
        let plan = try LaserLiveWristRoundPlan.completeRound(context: context, calibrations: calibrations,
            layout: fixture.input.playerPlaneLayout, seed: 7, roster: roster)
        let zones = try #require(plan.director).vaultContactZones(gateIndex: 0)
        return try FTUEVaultPractice(inputs: .init(round: .init(configuration: plan.configuration, diamonds: plan.diamonds,
            context: context, roster: roster), zones: zones), at: time)
    }

    static func acceptedPractice(generation: UUID, solo: Bool) throws -> FTUEVaultPractice {
        let fixture = try WristGameplayFixture(generation: generation)
        let practice = try makePractice(fixture, solo: solo)
        try send(practice, fixture, 3, 0.2)
        try send(practice, fixture, 4, 0.4, pressing: Set(practice.inputs.round.roster))
        try #require(practice.didOpen)
        return practice
    }

    private static func send(_ practice: FTUEVaultPractice, _ fixture: WristGameplayFixture, _ frame: UInt64,
                             _ capture: Double, pressing: Set<PlayerID> = [], bad: String? = nil,
                             arrival: Double? = nil, wrongPlayer: Bool = false) throws {
        var wrists = [WristGameplayFixture.left: WristGameplayFixture.outside, WristGameplayFixture.p2: WristGameplayFixture.outside]
        for zone in practice.inputs.zones where pressing.contains(zone.playerID) {
            let player: PlayerID = wrongPlayer ? (zone.playerID == .player1 ? .player2 : .player1) : zone.playerID
            wrists[.init(playerID: player, wrist: .left)] = .init(x: zone.position.x, y: zone.position.y)
        }
        try practice.update(at: arrival ?? capture + 0.01,
            snapshot: fixture.packet(frame, capture, points: wrists, bad: bad), zoneShifts: [:])
    }

    @Test(arguments: [true, false])
    func usesProductionRosterAndCommitsOnlyOneIsolatedUnlock(solo: Bool) throws {
        let fixture = try WristGameplayFixture()
        let practice = try Self.makePractice(fixture, solo: solo)
        let normal = try fixture.game()
        #expect(practice.inputs.zones.count == (solo ? 1 : 2))
        // Starting inside never creates a contact.
        try Self.send(practice, fixture, 3, 0.2, pressing: [.player1])
        #expect(practice.state.vault?.buttons[.player1]?.isEmpty == true)
        try Self.send(practice, fixture, 4, 0.3)
        try Self.send(practice, fixture, 5, 0.4, pressing: [.player1])
        #expect(practice.state.vault?.buttons[.player1] == [.activate])
        #expect(practice.didOpen == solo)
        if !solo {
            try Self.send(practice, fixture, 5, 0.4, pressing: [.player1], arrival: 0.45)
            #expect(!practice.didOpen && practice.state.vault?.buttons[.player2]?.isEmpty == true)
            try Self.send(practice, fixture, 6, 0.5, pressing: [.player2])
        }
        #expect(practice.didOpen)
        #expect(practice.events.filter { if case .coopGateSucceeded = $0.kind { true } else { false } }.count == 1)
        #expect(practice.state.phase == .activity && practice.state.teamScore == 0 && practice.state.missionProgress == 0)
        #expect(normal.roundPhase == .activity && normal.missionProgress == 0 && normal.teamScore == 0 && normal.vault == nil)
    }

    @Test func pauseAndInvalidInputRequireANewOutsideEntry() throws {
        let fixture = try WristGameplayFixture()
        let practice = try Self.makePractice(fixture)
        try Self.send(practice, fixture, 3, 0.2)
        try Self.send(practice, fixture, 4, 0.3, pressing: [.player1], bad: "calibration")
        try Self.send(practice, fixture, 5, 0.4, pressing: [.player1], wrongPlayer: true)
        #expect(practice.state.vault?.buttons.values.allSatisfy(\.isEmpty) == true)
        try Self.send(practice, fixture, 6, 0.5)
        try Self.send(practice, fixture, 7, 0.6, pressing: [.player1])
        practice.suspend(at: 0.7)
        try practice.update(at: 10, snapshot: nil, zoneShifts: [:])
        #expect(abs(practice.state.gameTime - 0.61) < 0.0001)
        let staleGeneration = try WristGameplayFixture(generation: UUID())
        try Self.send(practice, staleGeneration, 999, 10.1, pressing: [.player2])
        try Self.send(practice, fixture, 8, 0.65, pressing: [.player2], arrival: 10.2)
        try Self.send(practice, fixture, 9, 10.3, pressing: [.player2])
        #expect(!practice.didOpen && practice.state.vault?.buttons[.player1] == [.activate])
        try Self.send(practice, fixture, 10, 10.4)
        try Self.send(practice, fixture, 11, 10.5, pressing: [.player2])
        #expect(practice.didOpen)
    }

    @Test(arguments: [true, false])
    func recoversFromMissingInputAndAcceptsCurrentWristTrafficOnFreshVisits(solo: Bool) throws {
        for visit in 0..<2 {
            let fixture = try WristGameplayFixture(generation: UUID())
            let practice = try Self.makePractice(fixture, solo: solo, at: Double(visit))
            let now = Double(visit) + 1
            #expect(!FTUEVaultPractice.hasCurrentBodySnapshot(nil, inputs: practice.inputs, at: now))
            practice.suspend(at: now)
            let foreign = try WristGameplayFixture(generation: UUID())
            let wrongSource = try foreign.packet(98, now + 0.2, points: [:])
            #expect(!FTUEVaultPractice.hasCurrentBodySnapshot(wrongSource, inputs: practice.inputs, at: now + 0.3))
            let outside = try fixture.packet(3, now + 0.1, points: [:])
            #expect(FTUEVaultPractice.hasCurrentBodySnapshot(outside, inputs: practice.inputs, at: now + 0.42))
            #expect(!FTUEVaultPractice.hasCurrentBodySnapshot(outside, inputs: practice.inputs, at: now + 0.61))
            // The first delayed packet can resume the clock, but predates its new
            // activation watermark. A later outside/inside pair is still required.
            try practice.update(at: now + 0.42, snapshot: outside, zoneShifts: [:])
            let roster = Set(practice.inputs.round.roster)
            try Self.send(practice, fixture, 4, now + 0.5, pressing: roster, arrival: now + 0.82)
            #expect(!practice.didOpen)
            try Self.send(practice, fixture, 5, now + 0.6, arrival: now + 0.92)
            try Self.send(practice, fixture, 6, now + 0.7, pressing: roster, arrival: now + 1.02)
            #expect(practice.didOpen)
        }
    }

    @Test func productionDeadlineFailsAndANewAttemptStartsEmpty() throws {
        let fixture = try WristGameplayFixture()
        let expired = try Self.makePractice(fixture)
        try Self.send(expired, fixture, 3, 0.2)
        let deadline = try #require(expired.state.vault?.deadline)
        try Self.send(expired, fixture, 4, deadline - 0.02, pressing: Set(PlayerID.allCases), arrival: deadline)
        #expect(!expired.didOpen && expired.failedAt == deadline)
        let retry = try Self.makePractice(fixture, at: deadline + 0.1)
        #expect(retry.presentationID != expired.presentationID && retry.state.vault?.id != expired.state.vault?.id)
        #expect(retry.state.vault?.buttons.values.allSatisfy(\.isEmpty) == true)
    }
}
