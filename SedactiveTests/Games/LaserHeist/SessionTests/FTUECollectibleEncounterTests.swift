import Foundation
import Testing
@testable import Sedactive

@MainActor struct FTUECollectibleEncounterTests {
    @Test func collectibleTravelContinuesWithoutContactAndStopsWithoutReadiness() async throws {
        let f = LeanTutorialTests.Fixture()
        let script = try LaserReplayScript.load().freshRound(generation: f.generation)
        var input = script.input.configuration
        input.soloPlayer = .player1
        let scene = LaserScene()
        scene.installEnvironment(authored: try #require(await LaserScene.loadAuthoredEnvironment()))
        scene.attachLiveAvatars(mailbox: AvatarPoseMailbox(maxAge: 0.25),
                                templates: try await RobotAvatarLayer.sharedTemplates(), players: [.player1])
        defer { scene.detachLiveAvatars() }
        let presentation = FTUECollectiblePresentation()
        func tick(_ now: Double, ready: Bool = true) {
            let receipt = presentation.update(scene: scene, kind: .diamond, configuration: script.configuration,
                input: input, context: f.context, at: now, ready: ready, contactsFrom: [], heartArt: nil)
            #expect(receipt == nil, "scrolling without contact cannot produce a pickup")
        }
        let start = scene.travelOffset
        tick(1); tick(1.125); tick(1.25)
        let moved = scene.travelOffset
        #expect(abs(moved - start - scene.layout.travelSpeed * 0.25) < 0.00001)
        tick(1.375, ready: false); tick(20)
        #expect(scene.travelOffset == moved, "resuming cannot catch up time spent without readiness")
        tick(20.125)
        #expect(scene.travelOffset > moved)
        let beforeSlowUpdate = scene.travelOffset
        tick(21.125)
        #expect(abs(scene.travelOffset - beforeSlowUpdate - scene.layout.travelSpeed * 0.25) < 0.00001)
        presentation.clear()
        let retired = scene.travelOffset
        tick(21.25)
        #expect(scene.travelOffset == retired, "a new visit cannot reuse the previous render tick")
    }

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
