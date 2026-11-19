import Foundation
import Testing
@testable import Sedactive

@MainActor struct FTUECollectibleEncounterTests {
    @Test func requiresOrderedDomainReceiptsAndAcceptsHeartAtFullHealth() throws {
        let f = LeanTutorialTests.Fixture(), tutorial = f.tutorial()
        f.tick(tutorial, 0...80)
        #expect(tutorial.stage == .collectiblesIntroduction)
        tutorial.finishCollectiblesIntroduction(generation: f.generation)
        let config = try LaserReplayScript.load().configuration
        let position = try LaserDiamondPosition(x: 0, y: 1)
        var diamond = try FTUECollectibleEncounter(kind: .diamond, configuration: config, context: f.context,
            position: position, roster: [.player1])
        var heart = try FTUECollectibleEncounter(kind: .heart, configuration: config, context: f.context,
            position: position, roster: [.player1])
        try diamond.collect([.player1], context: f.context)
        #expect(diamond.receipt == nil, "before the passage")
        try diamond.advance(to: 2)
        try diamond.collect([.player2], context: f.context)
        #expect(diamond.receipt == nil, "ineligible roster")
        try heart.advance(to: 2)
        try heart.collect([.player1], context: f.context)
        let heartReceipt = try #require(heart.receipt)
        #expect(heart.game.lastHeartPickup?.restored == false)
        #expect(heart.game.teamHealth == config.initialTeamHealth)
        tutorial.acceptPickup(heartReceipt)
        #expect(tutorial.collection == .diamond)
        try diamond.collect([.player1], context: f.context)
        let diamondReceipt = try #require(diamond.receipt)
        tutorial.acceptPickup(diamondReceipt)
        tutorial.acceptPickup(diamondReceipt)
        #expect(tutorial.collection == .heart)
        tutorial.acceptPickup(heartReceipt)
        #expect(tutorial.heartPhase == .introduction)
    }

    @Test(arguments: [FTUECollectible.diamond, .heart])
    func expiryAndContextMismatchCannotGrantReceipt(kind: FTUECollectible) throws {
        let f = LeanTutorialTests.Fixture()
        let other = LeanTutorialTests.Fixture()
        var encounter = try FTUECollectibleEncounter(kind: kind, configuration: LaserReplayScript.load().configuration,
            context: f.context, position: .init(x: 0, y: 1), roster: [.player1])
        try encounter.advance(to: 2)
        try encounter.collect([.player1], context: other.context)
        #expect(encounter.receipt == nil)
        try encounter.advance(to: encounter.spawn.exit)
        try encounter.collect([.player1], context: f.context)
        #expect(encounter.receipt == nil)
    }
}
