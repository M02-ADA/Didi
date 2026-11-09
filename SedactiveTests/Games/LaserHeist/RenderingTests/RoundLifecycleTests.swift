import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// Repeated rounds through the real session, presenter and mascots, torn down
/// in PlayView's order. Retry replaces the whole scene, so each round must
/// start the same, leave nothing behind and release its scene.
@MainActor
struct RoundLifecycleTests {
    private struct Totals: Equatable {
        var badges = 0, teamEffects = 0, hazards = 0, rootEntities = 0
    }

    private func play(until end: Double? = nil, weakScene: inout LaserScene?) async throws -> Totals {
        let script = try LaserReplayScript.load().freshRound(generation: UUID())
        let scene = LaserScene()
        scene.installEnvironment(authored: await LaserScene.loadAuthoredEnvironment())
        scene.installLaserArtwork(await LaserScene.loadLaserGateArtwork())
        scene.installVaultDoor(await LaserScene.loadVaultDoorArtwork())
        scene.installDiamondArt(await LaserScene.loadDiamondArtwork())
        let avatars = RobotAvatarLayer(scene: scene, calibrations: script.input.configuration.calibrations,
                                       layout: script.input.configuration.playerPlaneLayout,
                                       templates: try await RobotAvatarLayer.sharedTemplates())
        scene.robotAvatars = avatars
        let session = GameSessionCoordinator(script: script)
        try await session.start()
        let presenter = GameplayScenePresenter(scene: scene, configuration: script.configuration, encounters: script.encounters)
        let rootEntities = scene.root.children.count

        for tick in 0...Int(script.duration * 30 + 1) {
            let time = Double(tick) / 30
            if let end, time > end { break }
            try await session.advance(to: time)
            presenter.apply(state: try #require(session.state), events: session.events, snapshot: session.latestSnapshot)
        }
        if end != nil {
            await session.stop()
            presenter.apply(state: try #require(session.state), events: session.events, snapshot: session.latestSnapshot)
        }
        #expect(session.summary != nil)

        for player in PlayerID.allCases {
            #expect(scene.players[player]?.children.filter { $0.name == "player.\(player.rawValue).robot" }.count == 1)
        }
        presenter.stop()
        let totals = Totals(badges: presenter.diagnostics.badges, teamEffects: presenter.diagnostics.teamEffects,
                            hazards: presenter.diagnostics.createdHazards, rootEntities: rootEntities)

        // Nothing of the round is left showing.
        #expect(presenter.visibleHazardCount == 0)
        #expect(scene.shownMoveCue == nil)
        #expect(scene.vaultDoorDepth == nil)
        #expect(scene.root.findEntity(named: "diamonds")?.children.isEmpty == true)
        for player in PlayerID.allCases {
            #expect(scene.root.findEntity(named: "laserFeedback.badge.\(player.rawValue)")?.isEnabled == false)
        }
        scene.detachLiveAvatars()
        await session.stop()
        #expect(scene.root.findEntity(named: "robot.lights") == nil)
        for player in PlayerID.allCases {
            #expect(scene.players[player]?.children.contains { $0.name == "player.\(player.rawValue).robot" } == false)
        }
        weakScene = scene
        return totals
    }

    @Test func repeatedFullRoundsMatchAndReleaseTheirScenes() async throws {
        var results: [Totals] = []
        for _ in 0..<3 {
            weak var released: LaserScene?
            var held: LaserScene?
            results.append(try await play(weakScene: &held))
            released = held
            held = nil
            await Task.yield()
            #expect(released == nil, "a finished round's scene is still retained")
        }
        #expect(results[0].badges == 6 && results[0].teamEffects == 3)
        #expect(results[1] == results[0] && results[2] == results[0])
    }

    /// End round during the activity, the vault (17 s) and Diamond Time.
    @Test(arguments: [5.0, 18.0, 24.0])
    func endingARoundEarlyLeavesNothingBehind(at time: Double) async throws {
        var held: LaserScene?
        _ = try await play(until: time, weakScene: &held)
    }
}
