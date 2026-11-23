import Foundation
import Testing
@testable import Sedactive

@MainActor struct FTUEDiamondTimeSessionTests {
    static func makeRound(generation: UUID, solo: Bool = false) throws -> FTUEDiamondTimeSession {
        let fixture = try WristGameplayFixture(generation: generation)
        return try makeRound(fixture, solo: solo)
    }

    static func finishRound(_ round: FTUEDiamondTimeSession) throws {
        let entered = round.entry.timeline.end
        try round.update(at: entered, snapshot: nil)
        try round.update(at: entered + LaserRoundConfiguration.defaultDiamondTimeDuration + 0.01, snapshot: nil)
    }

    private static func makeRound(_ fixture: WristGameplayFixture, solo: Bool) throws -> FTUEDiamondTimeSession {
        let roster: [PlayerID] = solo ? [.player1] : PlayerID.allCases
        let calibration = try LaserReplayScript.load().input.configuration.calibrations.filter { roster.contains($0.key) }
        let base = fixture.context
        let context = BodyInputContext(sessionGeneration: base.sessionGeneration,
            cameraGeometryRevision: base.cameraGeometryRevision,
            calibrationRevisions: base.calibrationRevisions.filter { roster.contains($0.key) },
            cutovers: base.cutovers.filter { roster.contains($0.key) }, isActive: true, wristContact: base.wristContact)
        let plan = try LaserLiveWristRoundPlan.completeRound(context: context, calibrations: calibration,
            layout: fixture.input.playerPlaneLayout, seed: 7, roster: roster)
        return try .init(inputs: .init(configuration: plan.configuration, diamonds: plan.diamonds,
                                       context: context, roster: roster), at: 0)
    }

    @Test(arguments: [true, false])
    func sharesWristEligibilityReplacementAndPointsWithoutTouchingNormalRound(solo: Bool) throws {
        let fixture = try WristGameplayFixture(generation: UUID())
        let round = try Self.makeRound(fixture, solo: solo)
        let normalRound = try fixture.game()
        let player: PlayerID = solo ? .player1 : .player2
        let hand = LaserContactHand(playerID: player, wrist: .left)
        let outside = [hand: WristPlanePoint(x: -4, y: 0)]
        let opening = round.entry.timeline.end
        try round.update(at: opening, snapshot: try fixture.packet(3, opening - 0.1, points: outside))
        #expect(round.showsPawBoard && round.game.gameTime == 0 && round.game.activeDiamonds.isEmpty)
        #expect(round.entry.timeline.jumpers == (solo ? [.player1] : PlayerID.allCases))

        let otherGeneration = try WristGameplayFixture(generation: UUID())
        try round.update(at: opening + 0.1,
            snapshot: try otherGeneration.packet(999, opening + 0.09, points: outside))
        #expect(round.paws.isEmpty && round.game.activeDiamonds.isEmpty)

        let p2 = LaserContactHand(playerID: .player2, wrist: .left)
        let supplied = solo ? outside.merging([p2: WristGameplayFixture.outside]) { first, _ in first } : outside
        try round.update(at: opening + 0.25, snapshot: try fixture.packet(4, opening + 0.22, points: supplied))
        #expect(Set(round.paws.keys) == [hand])
        let initial = round.game.activeDiamonds
        #expect(initial.count == 6)
        let target = try #require(initial.max { $0.position.y < $1.position.y })
        let board = round.inputs.diamonds
        let height = try #require(board.standingHeights[player])
        let home = LaserDiamondTimeBoard.homeX(player: player, solo: solo)
        let raised = (LaserDiamondTimeBoard.height - LaserDiamondTimeBoard.inset - target.position.y)
            / (LaserDiamondTimeBoard.height - 2 * LaserDiamondTimeBoard.inset)
        let wrist = WristPlanePoint(x: board.layout.centerX(for: player)
            + (home - target.position.x) * height / LaserDiamondTimeBoard.lateralGain,
            y: height * (LaserDiamondTimeBoard.lowWristHeight
                + raised * (LaserDiamondTimeBoard.highWristHeight - LaserDiamondTimeBoard.lowWristHeight)))
        try round.update(at: opening + 0.36,
            snapshot: try fixture.packet(5, opening + 0.34, points: outside))
        let hit = try fixture.packet(6, opening + 0.46, points: [hand: wrist])
        try round.update(at: opening + 0.5, snapshot: hit)
        let outcome = try #require(round.game.diamonds[target.id]?.outcome)
        guard case .collected(let collector, _) = outcome else {
            Issue.record("Expected an accepted pickup")
            return
        }
        #expect(collector == hand)
        let count = round.game.diamondsCollected
        #expect(count > 0)
        #expect(round.game.teamScore == count * LaserRoundConfiguration.approvedDiamondPoints)
        #expect(round.game.activeDiamonds.count == 6)
        #expect(round.game.activeDiamonds.contains { spawn in !initial.contains { $0.id == spawn.id } })
        try round.update(at: opening + 0.55, snapshot: hit)
        #expect(round.game.diamondsCollected == count)
        #expect(round.game.missionProgress == 0 && round.game.vault == nil)
        #expect(normalRound.teamScore == 0 && normalRound.roundPhase == .activity)
    }

    @Test(arguments: [true, false])
    func displaysAdmittedWristAfterShortRenderWindowAndClearsItOnExpiry(solo: Bool) throws {
        let fixture = try WristGameplayFixture(generation: UUID())
        let round = try Self.makeRound(fixture, solo: solo)
        let player: PlayerID = solo ? .player1 : .player2
        let hand = LaserContactHand(playerID: player, wrist: .left)
        let opening = round.entry.timeline.end
        try round.update(at: opening, snapshot: nil)

        let freshness = try #require(round.inputs.context.wristContact?.freshness)
        #expect(freshness > 0.15)
        let capture = opening + 0.1
        let age = (0.15 + freshness) / 2
        let packet = try fixture.packet(4, capture, points: [hand: WristGameplayFixture.outside])
        try round.update(at: capture + age, snapshot: packet)
        #expect(Set(round.paws.keys) == [hand])
        #expect(round.game.activeDiamonds.count == 6)
        #expect(round.game.teamScore == 0)

        try round.update(at: capture + freshness + 0.01, snapshot: packet)
        #expect(round.paws.isEmpty)
        #expect(round.game.teamScore == 0)
    }

    @Test func suspendingEntryAndRoundHoldsCountdownAndReplayStartsFresh() throws {
        let generation = UUID()
        let round = try Self.makeRound(generation: generation)
        try round.update(at: 1, snapshot: nil)
        round.suspend(at: 1)
        try round.update(at: 45, snapshot: nil)
        #expect(round.entry.elapsed == 1)
        try round.update(at: 51, snapshot: nil)
        #expect(round.showsPawBoard)
        try round.update(at: 53, snapshot: nil)
        round.suspend(at: 60)
        try round.update(at: 100, snapshot: nil)
        #expect(round.game.gameTime == 2)
        let model = GameplayHUDModel(state: round.state(health: nil), events: round.events,
            configuration: round.inputs.configuration, activityDuration: 60, diamondsCollected: 0)
        #expect(model.diamondSecondsLeft == 18)
        try round.update(at: 118, snapshot: nil)
        #expect(round.isComplete && !round.showsPawBoard)
        #expect(round.game.activeDiamonds.isEmpty)
        let next = try Self.makeRound(generation: UUID(), solo: true)
        #expect(next.presentationID != round.presentationID && next.entry.elapsed == 0 && next.game.teamScore == 0)
    }
}
