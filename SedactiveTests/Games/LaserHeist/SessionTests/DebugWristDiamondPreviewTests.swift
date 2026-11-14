#if DEBUG
import Foundation
import RealityKit
import Testing
@testable import Sedactive

@MainActor struct DebugWristDiamondPreviewTests {
    @Test func actualCP1J07DomainK06AndHudCollectExactly25() async throws {
        let fixture = try DebugWristDiamondFixture.make(generation:UUID()), session = try fixture.makeSession()
        try await session.start();try await session.advance(to:0.25)
        #expect(session.isDebugWristPreview && session.isCompleteReplay && session.isReplay)
        let scene = LaserScene();scene.installDiamondArt(try #require(await LaserScene.loadDiamondArtwork()))
        let renderer = NormalDiamondPresentation(scene:scene)
        renderer.source = { LaserReplayPresentation.normalDiamonds(session.diamondStates,
            layout:fixture.script.input.configuration.playerPlaneLayout) }
        renderer.update(state:try #require(session.state))
        #expect(renderer.shownIDs == [DebugWristDiamondFixture.normalID])
        let entity = try #require(scene.root.findEntity(named:"diamond"))
        let position = try #require(session.diamondStates[DebugWristDiamondFixture.normalID]).spawn.position
        let lane = scene.mapping.playerPosition(.player1, heightAboveFloor: Float(position.y))
        // Placement comes from the approved catalog and is still mirrored about the lane.
        let expectedX = lane.x + Float(fixture.plan.layout.centerX(for: .player1) - position.x) * scene.mapping.metersPerGameUnit
        #expect(abs(entity.position.x-expectedX) < 1e-5)
        try await session.advance(to:0.875)
        #expect(session.state?.teamScore == 0 && session.diamondsCollected == 0)
        let snapshot = try #require(session.latestSnapshot), context = try #require(session.inputContext)
        #expect(context.acceptsWristContact(snapshot,playerID:.player1,at:0.875,afterFrameID:0,afterCapturedAt:0))
        try await session.advance(to:1)
        renderer.update(state:try #require(session.state))
        #expect(renderer.collections == 1 && session.diamondsCollected == 1 && session.state?.teamScore == 25)
        let hud = GameplayHUDModel(state:session.state,events:session.events,configuration:fixture.script.configuration,
            activityDuration:session.activityDuration,diamondsCollected:session.diamondsCollected,diamondsAreFixture:false)
        #expect(hud.score == 25)
        try await session.advance(to:1.0625) // real repeated CP1 frame/time in the replay stream
        renderer.update(state:try #require(session.state))
        #expect(renderer.collections == 1 && session.state?.teamScore == 25)
        try await session.advance(to:1.5);renderer.update(state:try #require(session.state))
        #expect(renderer.shownIDs.isEmpty)
        await session.stop();renderer.clear()
    }
    @Test func realBonusDomainReplacesOnceAndDeadlineDoesNotAward() async throws {
        let fixture = try DebugWristDiamondFixture.make(generation:UUID()), session = try fixture.makeSession()
        try await session.start();try await session.advance(to:0.25)
        try await session.advance(to:1.5)
        try await session.advance(to:2.25)
        #expect(session.state?.phase == .diamondTime)
        let initial = Set(session.diamondStates.values.filter { $0.outcome == nil }.map { $0.spawn.id })
        #expect(initial.count == 4)
        try await session.advance(to:2.5);try await session.advance(to:2.625)
        let after = Set(session.diamondStates.values.filter { $0.outcome == nil }.map { $0.spawn.id })
        #expect(after.count == 4 && after.intersection(initial).count == 3)
        #expect(session.diamondsCollected == 2 && session.state?.teamScore == 50)
        try await session.advance(to:12) // still four persistent targets, despite old passage exits
        #expect(session.diamondStates.values.filter { $0.outcome == nil }.count == 4)
        try await session.advance(to:DebugWristDiamondFixture.deadline)
        #expect(session.summary?.outcome == .completed && session.summary?.teamScore == 50)
        #expect(session.diamondStates.values.allSatisfy { $0.outcome != nil })
    }
    @Test func stopRetryRetiresOldSourceAndSceneCounts() async throws {
        let first = try DebugWristDiamondFixture.make(generation:UUID()), old = try first.makeSession()
        try await old.start();try await old.advance(to:0.25);try await old.advance(to:1)
        let packet = try #require(old.latestSnapshot)
        await old.stop();try await old.advance(to:2.625)
        #expect(old.summary?.teamScore == 25 && old.latestSnapshot == nil)
        let next = try DebugWristDiamondFixture.make(generation:UUID()), fresh = try next.makeSession()
        try await fresh.start();try await fresh.advance(to:0.25)
        #expect(fresh.state?.teamScore == 0 && fresh.diamondsCollected == 0)
        #expect(fresh.inputContext?.acceptsWristContact(packet,playerID:.player1,at:1.1,afterFrameID:0,afterCapturedAt:0) == false)
        #expect(first.authority.sourceEpoch != next.authority.sourceEpoch)
        let readout = DebugDiamondVisualReadout()
        readout.record(normal:[DebugWristDiamondFixture.normalID],bonus:[],collections:1,generation:packet.sessionGeneration)
        readout.clear();#expect(readout.normalIDs.isEmpty && readout.collections == 0 && readout.generation == nil)
        await fresh.stop()
    }
    @Test func replayAuthorizationAndTerminalCleanupStayOnOriginalFixtureClock() async throws {
        let f = try DebugWristDiamondFixture.make(generation:UUID())
        let driver = try LaserReplayDriver(script:f.script)
        try driver.enableDebugWristFixture(f.authority)
        var hostReads = 0
        let session = GameSessionCoordinator(provider:driver.provider,inputConfiguration:f.script.input.configuration,
            configuration:f.script.configuration,encounters:[],replayDriver:driver,wristDiamondConfiguration:f.plan,
            hostNow:{ hostReads += 1;return 1000 })
        try await session.start();try await session.advance(to:0.25)
        try await session.advance(to:DebugWristDiamondFixture.deadline)
        #expect(session.summary?.teamScore == 50 && hostReads == 0)
        await session.stop();#expect(hostReads == 0)
    }
    @Test func syntheticXYMatchesItsOriginalNormalizedJointAndAcceptedMapping() throws {
        let f = try DebugWristDiamondFixture.make(generation:UUID())
        for record in f.script.input.records {
            let snapshot = try #require(record.snapshot)
            for id in PlayerID.allCases {
                let calibration = try #require(f.script.input.configuration.calibrations[id])
                let player = try #require(snapshot.wristContact?.players[id])
                for wrist in [player.left,player.right] {
                    let xy = try #require(wrist.playerPlane), joint = try #require(wrist.observed)
                    #expect(abs(calibration.mapping.gameX(imageX:joint.x,playerID:id,layout:f.plan.layout)-xy.x)<1e-12)
                    #expect(abs(calibration.mapping.gameY(imageY:joint.y,layout:f.plan.layout)-xy.y)<1e-12)
                }
            }
        }
        #expect(!DebugWristDiamondControls.requested(["--wrist-diamond-preview"]))
        #expect(DebugWristDiamondControls.requested(["--synthetic-gameplay-preview","--wrist-diamond-preview"]))
    }
}
#endif
