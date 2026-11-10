import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// The Sketch gameplay HUD (Hi-Fi Revisi 30 OCT) reads only Jevon's state,
/// events and configuration; the vault buttons come from the `VaultDoor`
/// Reality Composer Pro scene; Diamond Time shows only what its source lists.
@MainActor
struct GameplayHUDTests {
    private let generation = UUID()

    private func configuration(vaults: Int = 5) throws -> LaserRoundConfiguration {
        try LaserRoundConfiguration(
            evidenceTiming: LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25, deliveryAllowance: 0.1),
            clearanceMargin: 0.005, diamondPoints: nil, missionGateTarget: vaults, actionCueLead: 1.4)
    }

    private func state(_ time: Double, _ phase: LaserRoundPhase, activity: Double = 0, health: Int = 5, score: Int = 0,
                       opened: Int = 0, target: Int = 5, vault: LaserVaultState? = nil) -> LaserGameState {
        LaserGameState(sessionGeneration: generation, phase: phase, gameTime: time, activityProgress: activity,
                       teamHealth: health, teamScore: score, encounters: [], missionProgress: opened,
                       missionTarget: target, vault: vault)
    }

    private func event(_ sequence: UInt64, _ time: Double, _ kind: LaserGameEventKind) -> GameEvent {
        GameEvent(id: UUID(), sessionGeneration: generation, sequence: sequence, gameTime: time, kind: kind)
    }

    private func vault(opened: Bool = false) -> LaserVaultState {
        LaserVaultState(id: UUID(), deadline: 30, buttons: [.player1: [], .player2: []], opened: opened)
    }

    // MARK: - HUD model

    @Test func showsTheAuthoritativeHealthScoreAndVaults() throws {
        let model = GameplayHUDModel(state: state(4, .activity, health: 3, score: 700, opened: 2), events: [],
                                     configuration: try configuration(), activityDuration: 300)
        #expect(model.health == 3 && model.maxHealth == 5 && model.score == 700)
        #expect(model.checkpoints == 5 && model.vaultsOpened == 2)
        #expect(model.banner == .none && model.diamondSecondsLeft == nil && model.diamondsCollected == nil)
    }

    @Test func beforeTheRoundStartsItShowsFullHealthAndAnEmptyBar() throws {
        let model = GameplayHUDModel(state: nil, events: [], configuration: try configuration(), activityDuration: 300)
        #expect(model.health == 5 && model.score == 0 && model.fillEnd == GameplayHUDModel.fillStart)
        #expect(!model.diamondReached && model.banner == .none)
    }

    @Test func fiveCheckpointsSitAtTheSketchSpacing() {
        let dots = GameplayHUDModel.checkpointPositions(count: 5)
        // Measured on the Sketch 6 NOV progress group (dot centres over the 667 pt track).
        let sketch = [0.219, 0.380, 0.540, 0.700, 0.862]
        #expect(zip(dots, sketch).allSatisfy { abs($0 - $1) < 0.002 })
        #expect(abs(GameplayHUDModel.checkpointPositions(count: 1)[0] - 0.5405) < 1e-9)
        #expect(GameplayHUDModel.checkpointPositions(count: 0).isEmpty)
    }

    /// Five markers always, each completed only once the authoritative fill has passed it.
    @Test func fiveMarkersFollowTheAuthoritativeFill() throws {
        let start = GameplayHUDModel(state: state(0, .activity), events: [], configuration: try configuration(), activityDuration: 300)
        #expect(start.markerStates == [.current, .upcoming, .upcoming, .upcoming, .upcoming])
        // Two vaults opened, the third being attempted: its marker is current, not done.
        let third = GameplayHUDModel(state: state(180, .vault, activity: 180, opened: 2, vault: vault()), events: [],
                                     configuration: try configuration(), activityDuration: 300)
        #expect(third.markerStates == [.completed, .completed, .current, .upcoming, .upcoming])
        let done = GameplayHUDModel(state: state(300, .diamondTime, activity: 300, opened: 5), events: [],
                                    configuration: try configuration(), activityDuration: 300)
        #expect(done.markerStates == Array(repeating: .completed, count: 5))
    }

    /// The one-vault replay slice still shows five markers; its vault lands on the middle one.
    @Test func aOneVaultRoundStillShowsFiveMarkers() throws {
        let waiting = GameplayHUDModel(state: state(20, .vault, activity: 20, opened: 0, target: 1, vault: vault()), events: [],
                                       configuration: try configuration(vaults: 1), activityDuration: 40)
        #expect(waiting.markerStates.count == 5)
        #expect(abs(waiting.fillEnd - GameplayHUDModel.checkpointPositions(count: 5)[2]) < 1e-9)
        #expect(waiting.markerStates == [.completed, .completed, .current, .upcoming, .upcoming])
    }

    @Test func theFillNeverPassesAVaultNotYetOpened() throws {
        let dots = GameplayHUDModel.checkpointPositions(count: 5)
        // Most of the activity has passed, but no vault has opened yet.
        let early = GameplayHUDModel(state: state(200, .activity, activity: 200), events: [],
                                     configuration: try configuration(), activityDuration: 300)
        #expect(early.fillEnd < dots[0])
        // Two vaults opened very early in activity time: the fill holds at the second.
        let ahead = GameplayHUDModel(state: state(10, .activity, activity: 10, opened: 2), events: [],
                                     configuration: try configuration(), activityDuration: 300)
        #expect(abs(ahead.fillEnd - dots[1]) < 1e-9)
    }

    @Test func atAVaultTheFillSitsOnItsCheckpointWithTheTitle() throws {
        let dots = GameplayHUDModel.checkpointPositions(count: 5)
        let waiting = GameplayHUDModel(state: state(60, .vault, activity: 60, opened: 1, vault: vault()), events: [],
                                       configuration: try configuration(), activityDuration: 300)
        #expect(waiting.fillEnd == dots[1] && waiting.banner == .pressButtons)
        let open = GameplayHUDModel(state: state(61, .vault, activity: 60, opened: 1, vault: vault(opened: true)), events: [],
                                    configuration: try configuration(), activityDuration: 300)
        #expect(open.banner == .none)
    }

    @Test func diamondTimeFillsTheBarAndCountsDownFromThePhaseChange() throws {
        let events = [event(1, 100, .phaseChanged(.vault)), event(2, 103.2, .phaseChanged(.diamondTime))]
        let model = GameplayHUDModel(state: state(106.5, .diamondTime, activity: 100, opened: 5), events: events,
                                     configuration: try configuration(), activityDuration: 300)
        #expect(model.diamondReached && model.fillEnd == GameplayHUDModel.fillFull)
        #expect(model.banner == .retrieveDiamonds)
        // 103.2 + 10 configured seconds − 106.5 = 6.7 → 7 shown.
        #expect(model.diamondSecondsLeft == 7)
        // No J05 source: no diamond count, and never a fixture label.
        #expect(model.diamondsCollected == nil && !model.diamondsAreFixture)
        // Without the authoritative phase-change event, no time is invented.
        let noEvent = GameplayHUDModel(state: state(106.5, .diamondTime, opened: 5), events: [],
                                       configuration: try configuration(), activityDuration: 300)
        #expect(noEvent.diamondSecondsLeft == nil)
    }

    @Test func theDiamondTimeCountdownNeverGoesBelowZeroAndIgnoresOtherGenerations() throws {
        let other = GameEvent(id: UUID(), sessionGeneration: UUID(), sequence: 1, gameTime: 0, kind: .phaseChanged(.diamondTime))
        let late = GameplayHUDModel(state: state(200, .diamondTime, opened: 5), events: [event(2, 150, .phaseChanged(.diamondTime))],
                                    configuration: try configuration(), activityDuration: 300)
        #expect(late.diamondSecondsLeft == 0)
        let foreign = GameplayHUDModel(state: state(5, .diamondTime, opened: 5), events: [other],
                                       configuration: try configuration(), activityDuration: 300)
        #expect(foreign.diamondSecondsLeft == nil)
    }

    // MARK: - Pause safety

    /// Pausing is offered only when the session supplies both pause and resume
    /// (Jevon); today's session supplies neither, so the HUD shows no working
    /// pause while the round keeps running. Leaving stays its own intent.
    @Test func pauseIsOfferedOnlyWithTheSessionsPauseAndResume() {
        #expect(!GameplayHUDActions(pause: nil, resume: nil, leave: {}).canPause)
        #expect(!GameplayHUDActions(pause: {}, resume: nil, leave: {}).canPause)
        #expect(!GameplayHUDActions(pause: nil, resume: {}, leave: nil).canPause)
        var calls: [String] = []
        let actions = GameplayHUDActions(pause: { calls.append("pause") }, resume: { calls.append("resume") }, leave: nil)
        #expect(actions.canPause && actions.leave == nil)
        actions.pause?()
        actions.resume?()
        #expect(calls == ["pause", "resume"])
    }

    // MARK: - Vault buttons from Reality Composer Pro

    @Test func theVaultDoorSceneCarriesTheoButtonTemplates() async throws {
        let artwork = try #require(await LaserScene.loadVaultDoorArtwork())
        let scene = LaserScene()
        scene.installVaultDoor(artwork)
        let art = try #require(scene.vaultButtonArt)
        #expect(Set(art.keys) == Set(VaultButtonArtKey.allCases))
        for template in art.values {
            let model = try #require(template.components[ModelComponent.self])
            let size = model.mesh.bounds.extents
            #expect(abs(size.x - VaultPresentation.buttonSize.x) < 0.01 && abs(size.y - VaultPresentation.buttonSize.y) < 0.01)
        }
        // The presenter mounts clones on the walls: each active state adds a check (not colour alone).
        let presenter = VaultPresentation(scene: scene, configuration: try configuration(vaults: 1))
        for player in PlayerID.allCases {
            for button in LaserVaultButton.allCases {
                let part = try #require(presenter.buttons.findEntity(named: "vault.indicator.\(player.rawValue).\(button.rawValue)"))
                #expect(part.children.count == 2)
                #expect(part.children[1].findEntity(named: "vault.indicator.check") != nil)
                #expect(part.children[0].findEntity(named: "vault.indicator.check") == nil)
                let x = part.position(relativeTo: nil).x
                #expect(player == .player1 ? x < -2 : x > 2)
            }
        }
    }

    // MARK: - Diamond Time

    private func diamondScene() async throws -> LaserScene {
        let scene = LaserScene()
        scene.installDiamondArt(try #require(await LaserScene.loadDiamondArtwork()))
        return scene
    }

    @Test func diamondsShowOnlyWhatTheSourceListsDuringDiamondTime() async throws {
        let scene = try await diamondScene()
        let presentation = DiamondTimePresentation(scene: scene)
        presentation.source = nil
        presentation.update(state: state(1, .diamondTime), diamondTimeStartedAt: 0)
        #expect(presentation.floatingIDs.isEmpty)   // production today: no J05 source, nothing invented

        var collected = false
        presentation.source = { _ in
            [DiamondTimeDiamond(id: 1, lane: .player1, offsetX: -0.5, heightAboveFloor: 1.8, collected: collected),
             DiamondTimeDiamond(id: 2, lane: .player2, offsetX: 0.5, heightAboveFloor: 1.0, collected: false)]
        }
        presentation.update(state: state(1, .activity), diamondTimeStartedAt: 0)
        #expect(presentation.floatingIDs.isEmpty)   // only in Diamond Time
        presentation.update(state: state(2, .diamondTime), diamondTimeStartedAt: 0)
        #expect(presentation.floatingIDs == [1, 2])
        let p1 = try #require(scene.root.findEntity(named: "diamondTime.diamond.1"))
        #expect(p1.position(relativeTo: nil).x < scene.mapping.playerPosition(.player1).x)
        collected = true
        presentation.update(state: state(3, .diamondTime), diamondTimeStartedAt: 0)
        #expect(presentation.floatingIDs == [2])
        presentation.update(state: state(4, .ended(.completed)), diamondTimeStartedAt: 0)
        #expect(presentation.floatingIDs.isEmpty)
        #expect(scene.root.findEntity(named: "diamondTime.diamond.2") == nil)
    }

    @Test func theFixtureKeepsAtMostFourDiamondsAndOnlyCountsScriptedPickups() {
        var previous = 0
        for step in 0...120 {
            let elapsed = Double(step) * 0.1
            let floating = DiamondTimeFixture.diamonds(elapsed: elapsed).filter { !$0.collected }
            #expect(floating.count <= 4, "at \(elapsed)")
            let count = DiamondTimeFixture.collectedCount(elapsed: elapsed)
            #expect(count >= previous)
            previous = count
        }
        #expect(DiamondTimeFixture.collectedCount(elapsed: 0) == 0)
    }
}
