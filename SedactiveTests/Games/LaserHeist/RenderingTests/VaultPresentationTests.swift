import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// LH-18 P0: the vault door, countdown and six button indicators follow
/// Jevon's authoritative vault state and events, and clean up on every exit.
@MainActor
struct VaultPresentationTests {
    private let generation = UUID()
    private let vaultID = UUID()

    private func configuration() throws -> LaserRoundConfiguration {
        try LaserRoundConfiguration(
            evidenceTiming: LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25, deliveryAllowance: 0.1),
            clearanceMargin: 0.005, diamondPoints: nil, actionCueLead: 1.4)
    }

    private func named(_ name: String, in parent: Entity, _ entity: Entity = Entity()) -> Entity {
        entity.name = name
        parent.addChild(entity)
        return entity
    }

    /// A scene with door artwork and an authored corridor `Travel` group looping every 12 m.
    private func scene() -> (LaserScene, travel: Entity) {
        let authored = Entity()
        let travel = named("Travel", in: authored)
        named("TravelLoop", in: named("Anchors", in: authored)).position = [0, 0, -12]
        let scene = LaserScene()
        scene.installEnvironment(authored: authored)
        let artwork = Entity()
        let door = named("VaultDoorRoot", in: artwork)
        named("UnlockedLight", in: door)
        for side in ["LeftDoorPanel", "RightDoorPanel"] {
            named("Art", in: named(side, in: door), ModelEntity(mesh: .generatePlane(width: 2.4, height: 3.2)))
        }
        scene.installVaultDoor(artwork)
        return (scene, travel)
    }

    private func vault(_ buttons: [PlayerID: Set<LaserVaultButton>] = [:], opened: Bool = false) -> LaserVaultState {
        LaserVaultState(id: vaultID, deadline: 22, buttons: [.player1: buttons[.player1] ?? [], .player2: buttons[.player2] ?? []],
                        opened: opened)
    }

    private func state(_ time: Double, _ phase: LaserRoundPhase, vault: LaserVaultState? = nil,
                       generation: UUID? = nil) -> LaserGameState {
        LaserGameState(sessionGeneration: generation ?? self.generation, phase: phase, gameTime: time, activityProgress: 0,
                       teamHealth: 5, teamScore: 0, encounters: [], vault: vault)
    }

    private func succeeded(_ sequence: UInt64, _ time: Double) -> GameEvent {
        GameEvent(id: UUID(), sessionGeneration: generation, sequence: sequence, gameTime: time,
                  kind: .coopGateSucceeded(gateID: vaultID, progress: 1))
    }

    // MARK: - Entry, countdown, pause

    @Test func enteringTheVaultRevealsTheLockedDoorAndCountdown() throws {
        let (scene, _) = scene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [])
        presenter.apply(state: state(16, .activity), events: [], snapshot: nil)
        #expect(scene.vaultDoorDepth == nil)
        #expect(presenter.vault.indicator(.player1, .top) == nil)

        presenter.apply(state: state(17, .vault, vault: vault()), events: [], snapshot: nil)
        #expect(abs((scene.vaultDoorDepth ?? .nan) - scene.layout.vaultDoorStopZ) < 1e-4)
        #expect(scene.vaultDoorState == .locked)
        #expect(presenter.vault.diagnostics.reveals == 1)
        #expect(presenter.vault.countdownFraction == 1)
        for player in PlayerID.allCases {
            for button in LaserVaultButton.allCases {
                #expect(presenter.vault.indicator(player, button) == .idle)
            }
        }

        presenter.apply(state: state(19.5, .vault, vault: vault()), events: [], snapshot: nil)
        #expect(abs((presenter.vault.countdownFraction ?? .nan) - 0.5) < 1e-5)
        // A pause: game time holds, so do the countdown and the door.
        presenter.apply(state: state(19.5, .vault, vault: vault()), events: [], snapshot: nil)
        #expect(abs((presenter.vault.countdownFraction ?? .nan) - 0.5) < 1e-5)
        #expect(abs((scene.vaultDoorDepth ?? .nan) - scene.layout.vaultDoorStopZ) < 1e-4)
        #expect(presenter.vault.diagnostics.reveals == 1)
    }

    // MARK: - Buttons

    @Test func indicatorsMirrorTheButtonSetsAndAnimateEachActivationOnce() throws {
        let (scene, _) = scene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [])
        presenter.apply(state: state(17, .vault, vault: vault()), events: [], snapshot: nil)
        let bottom = try #require(presenter.vault.root.findEntity(named: "vault.indicator.player1.bottom"))
        let placed = bottom.position
        let first = vault([.player1: [.bottom]])
        presenter.apply(state: state(17.4, .vault, vault: first), events: [], snapshot: nil)
        presenter.apply(state: state(17.5, .vault, vault: first), events: [], snapshot: nil)
        #expect(presenter.vault.indicator(.player1, .bottom) == .active)
        #expect(presenter.vault.indicator(.player1, .top) == .idle)
        #expect(presenter.vault.diagnostics.activations == 1)
        // The activation pop keeps the indicator in its place.
        #expect(bottom.position == placed && bottom.transform.translation == placed)

        let more = vault([.player1: [.bottom, .top], .player2: [.top]])
        presenter.apply(state: state(18, .vault, vault: more), events: [], snapshot: nil)
        #expect(presenter.vault.indicator(.player1, .top) == .active)
        #expect(presenter.vault.indicator(.player2, .top) == .active)
        #expect(presenter.vault.indicator(.player2, .middle) == .idle)
        #expect(presenter.vault.diagnostics.activations == 3)
        // On the door: P1's column left of the centre seam, P2's mirroring it on the right.
        for button in LaserVaultButton.allCases {
            let p1 = try #require(presenter.vault.root.findEntity(named: "vault.indicator.player1.\(button.rawValue)"))
            let p2 = try #require(presenter.vault.root.findEntity(named: "vault.indicator.player2.\(button.rawValue)"))
            let world1 = p1.position(relativeTo: nil), world2 = p2.position(relativeTo: nil)
            #expect(world1.x < 0 && world2.x > 0 && abs(world1.x + world2.x) < 1e-5 && world1.y == world2.y)
            #expect(abs(world1.z - (scene.layout.vaultDoorStopZ + 0.05)) < 1e-4)
        }
    }

    // MARK: - Placement in the landscape view

    /// Normalised screen position (0…1, origin top-left) of a world point
    /// through the scene's game camera, for a landscape viewport.
    private func project(_ point: SIMD3<Float>, in scene: LaserScene, aspect: Float) -> SIMD2<Float> {
        let camera = scene.layout.cameraPosition
        let forward = normalize(scene.layout.cameraTarget - camera)
        let right = normalize(cross(forward, [0, 1, 0]))
        let up = cross(right, forward)
        let d = point - camera
        let t = tan(scene.layout.cameraVerticalFieldOfView * .pi / 360)
        let depth = dot(d, forward)
        return [0.5 + dot(d, right) / (depth * t * aspect) / 2, 0.5 - dot(d, up) / (depth * t) / 2]
    }

    /// Screen rectangle (minX, maxX, minY, maxY) of a world-space box facing the camera.
    private func screenRect(_ center: SIMD3<Float>, size: SIMD2<Float>, in scene: LaserScene, aspect: Float) -> SIMD4<Float> {
        let corners = [SIMD2<Float>(-1, -1), [1, -1], [-1, 1], [1, 1]].map {
            project(center + SIMD3($0.x * size.x / 2, $0.y * size.y / 2, 0), in: scene, aspect: aspect)
        }
        return [corners.map(\.x).min()!, corners.map(\.x).max()!, corners.map(\.y).min()!, corners.map(\.y).max()!]
    }

    private func overlaps(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Bool {
        !(a.y <= b.x || b.y <= a.x || a.w <= b.z || b.w <= a.z)
    }

    @Test(arguments: [(1366, 1024), (1210, 834), (1194, 834), (1180, 820), (1133, 744)])
    func indicatorsAndCountdownStayClearOfPlayersHUDAndLight(viewport: (width: Int, height: Int)) throws {
        let (scene, _) = scene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [])
        presenter.apply(state: state(17, .vault, vault: vault()), events: [], snapshot: nil)
        let aspect = Float(viewport.width) / Float(viewport.height)
        // The replay HUD panel measured in a landscape screenshot: 356 × 474 pt from the top-left, plus 8 pt.
        let hud = SIMD4<Float>(0, 364 / Float(viewport.width), 0, 482 / Float(viewport.height))
        // Each player's figure on the interaction plane, plus 0.1 m all round.
        let plane = scene.mapping.interactionPlaneZ
        let figures = PlayerID.allCases.map { player -> SIMD4<Float> in
            let size = player == .player1 ? scene.layout.player1Size : scene.layout.player2Size
            let base = scene.mapping.playerPosition(player)
            return screenRect([base.x, (size.y + 0.1) / 2, plane], size: [size.x + 0.2, size.y + 0.1], in: scene, aspect: aspect)
        }
        let door = scene.layout.vaultDoorStopZ
        let countdown = screenRect([0, VaultPresentation.countdownHeight, door + 0.04],
                                   size: [VaultPresentation.countdownWidth, 0.1], in: scene, aspect: aspect)
        // The authored lock light (VaultDoor.usda `UnlockedLight`).
        let light = screenRect([0, 2.91, door], size: [1.45, 0.24], in: scene, aspect: aspect)
        let screen = SIMD4<Float>(0, 1, 0, 1)
        for obstacle in figures + [hud, light] {
            #expect(!overlaps(countdown, obstacle))
        }
        var rects: [PlayerID: [SIMD4<Float>]] = [:]
        for player in PlayerID.allCases {
            for button in LaserVaultButton.allCases {
                let part = try #require(presenter.vault.root.findEntity(named: "vault.indicator.\(player.rawValue).\(button.rawValue)"))
                let rect = screenRect(part.position(relativeTo: nil), size: .init(repeating: VaultPresentation.indicatorSize),
                                      in: scene, aspect: aspect)
                #expect(rect.x >= screen.x && rect.y <= screen.y && rect.z >= screen.z && rect.w <= screen.w)
                for obstacle in figures + [hud, countdown, light] {
                    #expect(!overlaps(rect, obstacle), "\(player) \(button) overlaps at \(viewport)")
                }
                rects[player, default: []].append(rect)
            }
        }
        // Balanced: P2's column mirrors P1's about the screen centre.
        for (left, right) in zip(rects[.player1]!, rects[.player2]!) {
            #expect(abs((left.x + left.y) / 2 + (right.x + right.y) / 2 - 1) < 1e-3)
            #expect(abs(left.z - right.z) < 1e-5)
        }
    }

    // MARK: - Opening and travel

    @Test func doorOpensOnceThenPassesWithTheCorridor() throws {
        let (scene, travel) = scene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [])
        presenter.apply(state: state(17, .vault, vault: vault()), events: [], snapshot: nil)
        let all: [PlayerID: Set<LaserVaultButton>] = [.player1: Set(LaserVaultButton.allCases), .player2: Set(LaserVaultButton.allCases)]
        let events = [succeeded(1, 21)]
        // Rendered frames run throughout the vault, as in a session.
        presenter.apply(state: state(20.95, .vault, vault: vault()), events: [], snapshot: nil)
        // Success: the opened flag and the event arrive together; the door opens once.
        presenter.apply(state: state(21, .activity, vault: vault(all, opened: true)), events: events, snapshot: nil)
        presenter.apply(state: state(21, .activity, vault: vault(all, opened: true)), events: events, snapshot: nil)
        #expect(presenter.vault.diagnostics.opens == 1)
        #expect(scene.vaultDoorState == .open)
        #expect(presenter.vault.countdownFraction == nil)
        #expect(presenter.vault.indicator(.player1, .top) == nil)

        // Travel resumes: the door and the corridor move toward the players together.
        let corridor = travel.position.z
        let door = try #require(scene.vaultDoorDepth)
        presenter.apply(state: state(22, .activity, vault: vault(all, opened: true)), events: events, snapshot: nil)
        let moved = scene.layout.travelSpeed
        #expect(abs((scene.vaultDoorDepth ?? .nan) - (door + moved)) < 1e-4)
        #expect(abs((travel.position.z - corridor + 12).truncatingRemainder(dividingBy: 12) - moved) < 1e-4)
        // It is hidden before reaching the camera and never shown again for this vault.
        presenter.apply(state: state(26, .activity, vault: vault(all, opened: true)), events: events, snapshot: nil)
        #expect(scene.vaultDoorDepth == nil)
        presenter.apply(state: state(27, .diamondTime, vault: vault(all, opened: true)), events: events, snapshot: nil)
        #expect(scene.vaultDoorDepth == nil)
        #expect(presenter.vault.diagnostics.reveals == 1)
    }

    @Test func theSuccessEventAloneOpensTheDoor() throws {
        let (scene, _) = scene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [])
        presenter.apply(state: state(17, .vault, vault: vault()), events: [], snapshot: nil)
        presenter.apply(state: state(20, .vault, vault: vault()), events: [succeeded(1, 20)], snapshot: nil)
        #expect(presenter.vault.diagnostics.opens == 1)
        #expect(scene.vaultDoorState == .open)
    }

    // MARK: - Timeout, abort, Retry

    @Test func timeoutEmptiesTheCountdownAndStopCleansUp() throws {
        let (scene, _) = scene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [])
        presenter.apply(state: state(17, .vault, vault: vault([.player1: [.top]])), events: [], snapshot: nil)
        let failed = state(22, .ended(.vaultFailed), vault: vault([.player1: [.top]]))
        presenter.apply(state: failed, events: [], snapshot: nil)
        presenter.apply(state: failed, events: [], snapshot: nil)
        #expect(presenter.vault.diagnostics.timeouts == 1)
        #expect(presenter.vault.countdownFraction == 0)
        #expect(scene.vaultDoorState == .locked)
        #expect(scene.vaultDoorDepth != nil)
        #expect(presenter.vault.indicator(.player1, .top) == .active)

        // Results then stops the presentation.
        presenter.stop()
        #expect(scene.vaultDoorDepth == nil)
        #expect(presenter.vault.indicator(.player1, .top) == nil)
        #expect(presenter.vault.countdownFraction == nil)
    }

    @Test func endingTheRoundDuringTheVaultHidesIt() throws {
        let (scene, _) = scene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [])
        presenter.apply(state: state(17, .vault, vault: vault()), events: [], snapshot: nil)
        presenter.apply(state: state(18, .ended(.aborted), vault: vault()), events: [], snapshot: nil)
        #expect(scene.vaultDoorDepth == nil)
        #expect(presenter.vault.indicator(.player2, .bottom) == nil)
        #expect(presenter.vault.countdownFraction == nil)
        #expect(presenter.vault.diagnostics.timeouts == 0)
    }

    @Test func aNewGenerationStartsWithNoVaultShowing() throws {
        let (scene, _) = scene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [])
        presenter.apply(state: state(17, .vault, vault: vault([.player1: [.top]])), events: [], snapshot: nil)
        // Retry: a new generation, back in activity.
        let next = UUID()
        presenter.apply(state: state(0.5, .activity, generation: next), events: [], snapshot: nil)
        #expect(scene.vaultDoorDepth == nil)
        #expect(scene.vaultDoorState == .locked)
        // Its own vault is revealed fresh, with nothing activated.
        presenter.apply(state: state(17, .vault, vault: vault(), generation: next), events: [], snapshot: nil)
        #expect(presenter.vault.diagnostics.reveals == 2)
        #expect(presenter.vault.indicator(.player1, .top) == .idle)
    }

    // MARK: - Real replay round

    @Test func replayVaultShowsSixActivationsOpensOnceAndClearsTheScreen() async throws {
        let script = try LaserReplayScript.load().freshRound(generation: UUID())
        let session = GameSessionCoordinator(script: script)
        try await session.start()
        let (scene, _) = scene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: script.configuration, encounters: script.encounters)
        var hazardsDuringVault = 0
        var lastFraction: Float = 1
        var countdownRose = false
        for tick in 0...Int(script.duration * 30 + 1) {
            try await session.advance(to: Double(tick) / 30)
            guard let state = session.state else { continue }
            presenter.apply(state: state, events: session.events, snapshot: session.latestSnapshot)
            if state.phase == .vault {
                hazardsDuringVault += presenter.visibleHazardCount
                #expect(abs((scene.vaultDoorDepth ?? .nan) - scene.layout.vaultDoorStopZ) < 1e-4)
                if let fraction = presenter.vault.countdownFraction {
                    if fraction > lastFraction + 1e-6 { countdownRose = true }
                    lastFraction = fraction
                }
            }
        }
        #expect(session.phase == .finished)
        #expect(presenter.vault.diagnostics.reveals == 1)
        #expect(presenter.vault.diagnostics.activations == 6)
        #expect(presenter.vault.diagnostics.opens == 1)
        #expect(presenter.vault.diagnostics.timeouts == 0)
        #expect(!countdownRose)
        // Lasers are withdrawn when the vault starts; none show while it runs.
        #expect(hazardsDuringVault == 0)
        // The opened door has passed the players during Diamond Time.
        #expect(scene.vaultDoorDepth == nil)
        presenter.stop()
        #expect(presenter.vault.indicator(.player1, .top) == nil)
    }
}
