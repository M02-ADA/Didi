import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// Performance and lifecycle (Kevin, 22 November 2026): consecutive rounds, each through Diamond Time
/// to its Results (or ended early in Diamond Time), torn down in PlayView's order, must release EVERY
/// session-scoped object (session, presenter, mascots, scene), so nothing from an earlier round keeps
/// running or holding resources in the next, and each round must judge and score exactly the same.
@MainActor
struct SessionReleaseTests {
    private struct Held {
        weak var session: GameSessionCoordinator?
        weak var presenter: GameplayScenePresenter?
        weak var avatars: RobotAvatarLayer?
        weak var scene: LaserScene?
        var released: Bool { session == nil && presenter == nil && avatars == nil && scene == nil }
        var line: String { "session \(session != nil) presenter \(presenter != nil) avatars \(avatars != nil) scene \(scene != nil)" }
    }

    private struct Outcome: Equatable {
        var score: Int, health: Int, verdicts: [String], diamonds: Int
    }

    private func round(endingAt end: Double?) async throws -> (Outcome, Held) {
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
        let session = try LaserReplayDriver.makeSession(script: script)
        try await session.start()
        let presenter = GameplayScenePresenter(scene: scene, configuration: script.configuration, encounters: script.encounters)
        var sawDiamondTime = false
        for tick in 0...Int(script.duration * 30 + 1) {
            let time = Double(tick) / 30
            if let end, time > end { break }
            try await session.advance(to: time)
            let state = try #require(session.state)
            if state.phase == .diamondTime { sawDiamondTime = true }
            presenter.apply(state: state, events: session.events, snapshot: session.latestSnapshot)
        }
        #expect(sawDiamondTime, "the round reached Diamond Time")
        await session.stop()
        let state = try #require(session.state)
        let outcome = Outcome(score: state.teamScore, health: state.teamHealth,
                              verdicts: state.encounters.map { e in
                                  e.encounter.targets.map { "\($0.playerID.rawValue):\(String(describing: e.judgements[$0.playerID]))" }
                                      .joined(separator: ",") },
                              diamonds: session.diamondsCollected)
        // PlayView's teardown order.
        presenter.stop()
        scene.detachLiveAvatars()
        let held = Held(session: session, presenter: presenter, avatars: avatars, scene: scene)
        return (outcome, held)
    }

    @Test(arguments: [nil, 24.0] as [Double?])
    func consecutiveRoundsReleaseEverythingAndPlayTheSame(endingAt end: Double?) async throws {
        var outcomes: [Outcome] = []
        for index in 0..<3 {
            let (outcome, held) = try await round(endingAt: end)
            await Task.yield()
            #expect(held.released, "round \(index + 1) left session-scoped objects alive: \(held.line)")
            outcomes.append(outcome)
        }
        #expect(outcomes[1] == outcomes[0] && outcomes[2] == outcomes[0], "every round judges and scores the same")
    }
}
