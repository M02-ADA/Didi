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

    /// Names `entity` (a new one by default) and adds it to `parent`; returned for chaining.
    @discardableResult
    private func named(_ name: String, in parent: Entity, _ entity: Entity? = nil) -> Entity {
        let entity = entity ?? Entity()
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

    // MARK: - Approach

    /// With the session's time to the next vault, the locked door comes down the
    /// corridor from the laser spawn depth, closer every frame, and is exactly at
    /// its stop when the vault begins: no jump, no second fade-in, no handoff copy.
    @Test func theDoorApproachesDownTheCorridorAndArrivesAtItsStop() throws {
        let (scene, _) = scene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [])
        let speed = scene.layout.travelSpeed
        let stop = scene.layout.vaultDoorStopZ
        let horizon = presenter.vault.approachHorizonZ
        #expect(horizon > scene.layout.corridorFarZ && horizon < scene.layout.laserSpawnZ, "inside the corridor's far end")
        // Farther away than the corridor is long: the door already stands at its
        // far end, fully opaque, with no fade running.
        let far = Double((stop - horizon) / speed) + 4
        presenter.apply(state: state(17 - far, .activity), events: [], snapshot: nil, upcomingVaultIn: far)
        #expect(abs((scene.vaultDoorDepth ?? .nan) - horizon) < 1e-4)
        #expect(scene.vaultDoorOpacity == 1)

        // Then it comes closer every frame, from the far end to its stop.
        var depths: [Float] = [try #require(scene.vaultDoorDepth)]
        let tick = 0.25
        for lead in stride(from: far - tick, to: 0, by: -tick) {
            presenter.apply(state: state(17 - lead, .activity), events: [], snapshot: nil, upcomingVaultIn: lead)
            let depth = try #require(scene.vaultDoorDepth)
            #expect(abs(depth - max(horizon, stop - speed * Float(lead))) < 1e-4)
            #expect(scene.vaultDoorOpacity == 1, "never faded")
            depths.append(depth)
        }
        #expect(zip(depths, depths.dropFirst()).allSatisfy { $0 <= $1 }, "the door never moves away")
        #expect(zip(depths, depths.dropFirst()).allSatisfy { $1 - $0 <= speed * Float(tick) + 1e-4 }, "no jump between frames")
        #expect(depths.last! > depths.first!, "it approaches")
        #expect(scene.vaultDoorState == .locked)
        #expect(presenter.vault.approaching && presenter.vault.diagnostics.approaches == 1)
        #expect(presenter.vault.countdownFraction == nil && !presenter.vault.indicatorsShown,
                "no countdown or buttons before the vault begins")

        presenter.apply(state: state(17, .vault, vault: vault()), events: [], snapshot: nil)
        #expect(abs((scene.vaultDoorDepth ?? .nan) - stop) < 1e-4)
        #expect(!presenter.vault.approaching && presenter.vault.diagnostics.handoffs == 0)
        #expect(presenter.vault.countdownFraction == 1 && presenter.vault.indicatorsShown)
        #expect(scene.root.children.filter { $0.name == "vaultDoor.exiting" }.isEmpty)
    }

    /// Without a schedule (production until Jevon exposes one) nothing approaches.
    @Test func withoutTheScheduleTheDoorStillFadesInAtItsStop() throws {
        let (scene, _) = scene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [])
        presenter.apply(state: state(16, .activity), events: [], snapshot: nil)
        #expect(scene.vaultDoorDepth == nil && presenter.vault.diagnostics.approaches == 0)
        presenter.apply(state: state(17, .vault, vault: vault()), events: [], snapshot: nil)
        #expect(abs((scene.vaultDoorDepth ?? .nan) - scene.layout.vaultDoorStopZ) < 1e-4)
    }

    /// The round ending mid-approach removes the door.
    @Test func anApproachingDoorIsRemovedWhenTheRoundEnds() throws {
        let (scene, _) = scene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [])
        presenter.apply(state: state(16, .activity), events: [], snapshot: nil, upcomingVaultIn: 1)
        #expect(scene.vaultDoorDepth != nil)
        presenter.apply(state: state(16.2, .ended(.aborted)), events: [], snapshot: nil)
        #expect(scene.vaultDoorDepth == nil && !presenter.vault.approaching)
    }

    /// The complete replay's vaults open at the end of each activity minute: the
    /// time to the next one comes from authoritative progress only.
    @Test func theCompleteReplayReportsTheTimeToItsNextVault() {
        func at(_ activity: Double, opened: Int, _ phase: LaserRoundPhase = .activity) -> LaserGameState {
            LaserGameState(sessionGeneration: generation, phase: phase, gameTime: activity + Double(opened) * 1.2,
                           activityProgress: activity, teamHealth: 5, teamScore: 0, encounters: [],
                           missionProgress: opened, missionTarget: 5, vault: nil)
        }
        #expect(LaserReplayPresentation.upcomingVaultIn(state: at(50, opened: 0), activityDuration: 300) == 10)
        #expect(LaserReplayPresentation.upcomingVaultIn(state: at(60, opened: 1), activityDuration: 300) == 60,
                "right after a vault the next one is a minute away")
        #expect(LaserReplayPresentation.upcomingVaultIn(state: at(290, opened: 4), activityDuration: 300) == 10)
        #expect(LaserReplayPresentation.upcomingVaultIn(state: at(300, opened: 5), activityDuration: 300) == nil, "no sixth vault")
        #expect(LaserReplayPresentation.upcomingVaultIn(state: at(60, opened: 0, .vault), activityDuration: 300) == nil)
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
        let bottom = try #require(presenter.vault.buttons.findEntity(named: "vault.indicator.player1.bottom"))
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
        // On the corridor walls (Sketch): P1's column on the left wall, P2's mirroring it on the right.
        for button in LaserVaultButton.allCases {
            let p1 = try #require(presenter.vault.buttons.findEntity(named: "vault.indicator.player1.\(button.rawValue)"))
            let p2 = try #require(presenter.vault.buttons.findEntity(named: "vault.indicator.player2.\(button.rawValue)"))
            let world1 = p1.position(relativeTo: nil), world2 = p2.position(relativeTo: nil)
            #expect(world1.x < 0 && world2.x > 0 && abs(world1.x + world2.x) < 1e-5 && world1.y == world2.y)
            #expect(abs(world1.x) == VaultPresentation.indicatorColumnX && abs(world1.x) < scene.layout.corridorWidth / 2)
            #expect(abs(world1.z - (VaultPresentation.indicatorDepthZ + 0.05)) < 1e-4)
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
        // The gameplay HUD (`GameplayHUD`, Sketch 1210 × 834 pt scaled by k): its top bar with the
        // score chip under the hearts (to y 171 pt), and the phase title band (606 pt wide, y 136–237 pt).
        let k = min(Float(viewport.width) / 1210, Float(viewport.height) / 834)
        let w = Float(viewport.width), h = Float(viewport.height)
        let topBar = SIMD4<Float>(0, 1, 0, 171 * k / h)
        let title = SIMD4<Float>(0.5 - 303 * k / w, 0.5 + 303 * k / w, 136 * k / h, 237 * k / h)
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
        for obstacle in figures + [topBar, title, light] {
            #expect(!overlaps(countdown, obstacle))
        }
        var rects: [PlayerID: [SIMD4<Float>]] = [:]
        for player in PlayerID.allCases {
            for button in LaserVaultButton.allCases {
                let part = try #require(presenter.vault.buttons.findEntity(named: "vault.indicator.\(player.rawValue).\(button.rawValue)"))
                let rect = screenRect(part.position(relativeTo: nil), size: .init(repeating: VaultPresentation.indicatorSize),
                                      in: scene, aspect: aspect)
                #expect(rect.x >= screen.x && rect.y <= screen.y && rect.z >= screen.z && rect.w <= screen.w)
                for obstacle in figures + [topBar, title, countdown, light] {
                    #expect(!overlaps(rect, obstacle), "\(player) \(button) overlaps at \(viewport)")
                }
                rects[player, default: []].append(rect)
            }
        }
        // The seconds-left number between the columns (a generous glyph box), and each
        // column's completion outline, stay clear of the figures, HUD, countdown and light.
        let digit = screenRect([0, VaultPresentation.digitCenterY, door + 0.05],
                               size: [0.36, VaultPresentation.digitHeight], in: scene, aspect: aspect)
        for obstacle in figures + [topBar, title, countdown, light] {
            #expect(!overlaps(digit, obstacle), "number overlaps at \(viewport)")
        }
        for player in PlayerID.allCases {
            let x = (player == .player1 ? -1 : 1) * VaultPresentation.indicatorColumnX
            let outline = screenRect([x, VaultPresentation.outlineCenterY, VaultPresentation.indicatorDepthZ + 0.045],
                                     size: VaultPresentation.outlineSize, in: scene, aspect: aspect)
            #expect(outline.x >= 0 && outline.y <= 1 && outline.z >= 0 && outline.w <= 1)
            for obstacle in figures + [topBar, title, countdown, light, digit] {
                #expect(!overlaps(outline, obstacle), "\(player) outline overlaps at \(viewport)")
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
        let session = try LaserReplayDriver.makeSession(script: script)
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

// MARK: - Vault experience across a round (Jevon's real LaserGame)

/// Jevon's `LaserGame`, driven only through its existing public vault API
/// (`openVault`, `touchVault`, `advance`, `pause`/`resume`), as the replay
/// session does: SYNTHETIC verified contacts, no camera, no renderer.
/// The state is built the way `GameSessionCoordinator.refresh` builds it.
@MainActor
private struct DomainRound {
    private(set) var game: LaserGame
    let configuration: LaserRoundConfiguration
    let generation: UUID
    private let revisions: [PlayerID: UInt64]
    private(set) var events: [GameEvent] = []

    init(vaults: Int, generation: UUID = UUID()) throws {
        let fixture = try LaserReplayScript.load().input
        let context = BodyInputContext(sessionGeneration: generation, cameraGeometryRevision: fixture.cameraGeometryRevision,
            calibrationRevisions: fixture.configuration.calibrations.mapValues(\.revision),
            cutovers: fixture.configuration.calibrations.mapValues {
                BodyInputCutover(frameID: $0.sourceFrameID, capturedAt: $0.capturedAt)
            }, isActive: true)
        configuration = try LaserRoundConfiguration(
            evidenceTiming: LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25, deliveryAllowance: 0.1),
            clearanceMargin: 0.005, diamondPoints: nil, missionGateTarget: vaults, actionCueLead: 1.4)
        game = try LaserGame(configuration: configuration, context: context, historyCapacityPerPlayer: 120)
        self.generation = generation
        revisions = context.calibrationRevisions
    }

    var state: LaserGameState {
        var state = LaserGameState(sessionGeneration: generation, phase: game.roundPhase, gameTime: game.gameTime,
                                   activityProgress: game.activityProgress, teamHealth: game.teamHealth,
                                   teamScore: game.teamScore, encounters: [])
        state.missionProgress = game.missionProgress
        state.missionTarget = game.missionTarget
        state.vault = game.vault
        return state
    }

    mutating func advance(to time: Double) throws {
        try game.advance(to: time)
        events += game.drainEvents()
    }

    mutating func open(_ id: UUID, at time: Double) throws {
        try game.openVault(id: id, at: time)
        events += game.drainEvents()
    }

    mutating func touch(_ id: UUID, _ player: PlayerID, _ button: LaserVaultButton, at time: Double) throws {
        try game.touchVault(id: id, playerID: player, button: button, validity: .valid, generation: generation,
                            calibrationRevision: revisions[player]!, at: time)
        events += game.drainEvents()
    }

    /// Both sides complete in the replay's order, 0.1 s apart from `time`.
    mutating func completeBothSides(_ id: UUID, from time: Double) throws {
        var t = time
        for player in PlayerID.allCases {
            for button in [LaserVaultButton.bottom, .top, .middle] {
                try touch(id, player, button, at: t)
                t += 0.1
            }
        }
    }

    mutating func pause() { game.pause() }
    /// Player Stop / End round.
    mutating func exit() {
        game.exit(outcome: .aborted)
        events += game.drainEvents()
    }
    mutating func resume() { game.resume() }
}

extension VaultPresentationTests {
    private func makePresenter(for round: DomainRound, reduceMotion: Bool = false) throws -> (GameplayScenePresenter, LaserScene) {
        let (scene, _) = scene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: round.configuration, encounters: [])
        presenter.vault.reducesMotion = { reduceMotion }
        return (presenter, scene)
    }

    private func apply(_ presenter: GameplayScenePresenter, _ round: DomainRound) {
        presenter.apply(state: round.state, events: round.events, snapshot: nil)
    }

    private func allIndicators(_ presenter: GameplayScenePresenter) -> [VaultPresentation.Indicator?] {
        PlayerID.allCases.flatMap { player in LaserVaultButton.allCases.map { presenter.vault.indicator(player, $0) } }
    }

    /// Every door entity in the scene: the real one and any exiting copy.
    private func doorEntities(in scene: LaserScene) -> [Entity] {
        func walk(_ entity: Entity) -> [Entity] {
            (entity.name.hasPrefix("vaultDoor") ? [entity] : []) + entity.children.flatMap(walk)
        }
        return walk(scene.root)
    }

    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "17000000-0000-4000-8000-%012d", n))! }

    // MARK: Sequential vaults and phases

    /// activity → vault → activity → vault → … → Diamond Time → completed,
    /// rendered every 0.1 s from the real game: each vault reveals once,
    /// fresh, opens once, and the round ends with nothing left over.
    @Test func sequentialVaultsEachRevealFreshAndOpenOnceThroughDiamondTime() throws {
        var round = try DomainRound(vaults: 3)
        let (presenter, scene) = try makePresenter(for: round)
        var phases: [LaserRoundPhase] = []
        func render(until end: Double) throws {
            var t = round.state.gameTime
            while t < end - 1e-9 {
                t = min(end, t + 0.1)
                try round.advance(to: t)
                apply(presenter, round)
                if phases.last != round.state.phase { phases.append(round.state.phase) }
            }
        }
        for (index, start) in [2.0, 14.0, 26.0].enumerated() {
            try render(until: start)
            try round.open(id(index + 1), at: start)
            apply(presenter, round)
            phases.append(round.state.phase)
            // Each vault starts clean: locked door at its stop, six idle indicators, full countdown.
            #expect(presenter.vault.diagnostics.reveals == index + 1)
            #expect(scene.vaultDoorState == .locked)
            #expect(abs((scene.vaultDoorDepth ?? .nan) - scene.layout.vaultDoorStopZ) < 1e-4)
            #expect(allIndicators(presenter).allSatisfy { $0 == .idle })
            #expect(PlayerID.allCases.allSatisfy { presenter.vault.sideComplete($0) == false })
            #expect(presenter.vault.countdownDigit == 5 && presenter.vault.countdownFraction == 1)
            try round.completeBothSides(id(index + 1), from: start + 0.5)
            apply(presenter, round)
            #expect(presenter.vault.diagnostics.opens == index + 1)
            #expect(scene.vaultDoorState == .open)
        }
        try render(until: 26.5 + 0.6 + LaserRoundConfiguration.defaultDiamondTimeDuration + 1)
        #expect(phases == [.activity, .vault, .activity, .vault, .activity, .vault, .diamondTime, .ended(.completed)])
        let d = presenter.vault.diagnostics
        #expect(d.reveals == 3 && d.opens == 3 && d.activations == 18 && d.sideCompletions == 6 && d.timeouts == 0)
        // Vaults are 12 s apart, so each opened door has passed the camera before the next: no handoff.
        #expect(d.handoffs == 0)
        #expect(scene.vaultDoorDepth == nil)
        #expect(doorEntities(in: scene).count == 1)
    }

    /// The next vault begins while the previous opened door is still passing
    /// the players: that door fades out in place as a single copy, and the
    /// real door starts the new vault at its stop. No jump, no stale state.
    @Test func newVaultDuringThePreviousDoorsExitHandsItOffWithoutAJump() throws {
        var round = try DomainRound(vaults: 3)
        let (presenter, scene) = try makePresenter(for: round)
        try round.open(id(1), at: 1)
        apply(presenter, round)
        try round.completeBothSides(id(1), from: 1.2)
        apply(presenter, round)
        try round.advance(to: 2)
        apply(presenter, round)
        let passing = try #require(scene.vaultDoorDepth)
        #expect(passing > scene.layout.vaultDoorStopZ + 0.1)  // moved toward the players

        try round.open(id(2), at: 2)
        apply(presenter, round)
        let exiting = try #require(presenter.vault.exitingDoor)
        #expect(abs(exiting.position(relativeTo: nil).z - passing) < 1e-4)  // left where it was
        #expect(exiting.findEntity(named: "vault.indicators") == nil)       // no copied indicators
        #expect(abs((scene.vaultDoorDepth ?? .nan) - scene.layout.vaultDoorStopZ) < 1e-4)
        #expect(scene.vaultDoorState == .locked)
        #expect(allIndicators(presenter).allSatisfy { $0 == .idle })
        #expect(presenter.vault.diagnostics.handoffs == 1 && presenter.vault.diagnostics.reveals == 2)

        // A third quick vault replaces the copy: never more than one.
        try round.completeBothSides(id(2), from: 2.2)
        try round.advance(to: 3)
        apply(presenter, round)
        try round.open(id(3), at: 3)
        apply(presenter, round)
        #expect(presenter.vault.diagnostics.handoffs == 2)
        #expect(doorEntities(in: scene).count <= 2)
        #expect(doorEntities(in: scene).filter { $0.name == "vaultDoor.exiting" }.count <= 1)

        presenter.stop()
        #expect(presenter.vault.exitingDoor == nil && doorEntities(in: scene).count == 1)
        #expect(scene.vaultDoorDepth == nil)
    }

    /// Re-applying the same state and events (rendered frames between game
    /// updates) never replays an activation, completion, opening or timeout.
    @Test func repeatedUpdatesNeverReplayAnimationsOrTerminalStates() throws {
        var round = try DomainRound(vaults: 2)
        let (presenter, scene) = try makePresenter(for: round)
        try round.open(id(1), at: 1)
        try round.touch(id(1), .player1, .top, at: 1.2)
        for _ in 0..<5 { apply(presenter, round) }
        #expect(presenter.vault.diagnostics.activations == 1)
        try round.completeBothSides(id(1), from: 1.4)
        for _ in 0..<5 { apply(presenter, round) }
        let opened = presenter.vault.diagnostics
        #expect(opened.opens == 1 && opened.activations == 6 && opened.sideCompletions == 2 && opened.reveals == 1)
        #expect(scene.vaultDoorState == .open)

        var failing = try DomainRound(vaults: 1)
        let (other, _) = try makePresenter(for: failing)
        try failing.open(id(2), at: 1)
        apply(other, failing)
        try failing.advance(to: 7)
        for _ in 0..<5 { apply(other, failing) }
        #expect(other.vault.diagnostics.timeouts == 1 && other.vault.diagnostics.opens == 0)
    }

    // MARK: Success, failure, same-tick resolution

    /// Timeout from the real game: the countdown empties, reads 0 and turns
    /// red; the door stays locked; a completed side keeps its outline.
    @Test func timeoutShowsZeroAnEmptyBarAndKeepsCompletedSides() throws {
        var round = try DomainRound(vaults: 1)
        let (presenter, scene) = try makePresenter(for: round)
        try round.open(id(1), at: 1)
        for (k, button) in LaserVaultButton.allCases.enumerated() {
            try round.touch(id(1), .player1, button, at: 1.5 + Double(k) * 0.2)
        }
        try round.advance(to: 4)
        apply(presenter, round)
        #expect(presenter.vault.sideComplete(.player1) == true && presenter.vault.sideComplete(.player2) == false)
        try round.advance(to: 6.5)
        apply(presenter, round)
        #expect(round.state.phase == .ended(.vaultFailed))
        #expect(presenter.vault.diagnostics.timeouts == 1)
        #expect(presenter.vault.countdownFraction == 0 && presenter.vault.countdownDigit == 0)
        #expect(scene.vaultDoorState == .locked && scene.vaultDoorDepth != nil)
        #expect(presenter.vault.sideComplete(.player1) == true)
        presenter.stop()
        #expect(scene.vaultDoorDepth == nil && presenter.vault.countdownDigit == nil)
    }

    /// A vault that begins and resolves between two updates (one long frame)
    /// is still shown, from its own success or timeout event.
    @Test func aVaultResolvedBetweenTwoUpdatesIsStillShown() throws {
        var opening = try DomainRound(vaults: 2)
        let (presenter, scene) = try makePresenter(for: opening)
        try opening.advance(to: 0.5)
        apply(presenter, opening)
        try opening.open(id(1), at: 1)
        try opening.completeBothSides(id(1), from: 1.1)
        try opening.advance(to: 2)
        apply(presenter, opening)
        #expect(opening.state.phase == .activity)
        #expect(presenter.vault.diagnostics.reveals == 1 && presenter.vault.diagnostics.opens == 1)
        #expect(scene.vaultDoorState == .open && scene.vaultDoorDepth != nil)

        var failing = try DomainRound(vaults: 1)
        let (other, otherScene) = try makePresenter(for: failing)
        try failing.advance(to: 0.5)
        apply(other, failing)
        try failing.open(id(2), at: 1)
        try failing.advance(to: 8)
        apply(other, failing)
        #expect(other.vault.diagnostics.reveals == 1 && other.vault.diagnostics.timeouts == 1)
        #expect(other.vault.countdownDigit == 0 && otherScene.vaultDoorState == .locked)
    }

    /// A presenter whose first state already holds a vault opened earlier
    /// doesn't show it: it was not entered or resolved while presenting.
    @Test func aVaultAlreadyOpenedBeforePresentingIsNotShown() throws {
        var round = try DomainRound(vaults: 2)
        try round.open(id(1), at: 1)
        try round.completeBothSides(id(1), from: 1.1)
        try round.advance(to: 4)
        let (presenter, scene) = try makePresenter(for: round)
        apply(presenter, round)
        #expect(presenter.vault.diagnostics.reveals == 0 && scene.vaultDoorDepth == nil)
    }

    // MARK: Pause, urgency, clocks

    /// Pause freezes game time, so the countdown, its number and the door
    /// hold; after resume the vault continues with its remaining time.
    /// The presentation reads no other clock: real time passing changes nothing.
    @Test func pauseHoldsTheDeadlineAndNoOtherClockMovesIt() throws {
        var round = try DomainRound(vaults: 1)
        let (presenter, scene) = try makePresenter(for: round)
        try round.open(id(1), at: 1)
        try round.advance(to: 3.2)
        apply(presenter, round)
        #expect(presenter.vault.countdownDigit == 3 && presenter.vault.countdownUrgent == false)
        let fraction = try #require(presenter.vault.countdownFraction)
        round.pause()
        for later in [4.0, 6.0, 9.0] {
            try round.advance(to: later)  // ignored while paused
            Thread.sleep(forTimeInterval: 0.02)
            apply(presenter, round)
            #expect(presenter.vault.countdownFraction == fraction && presenter.vault.countdownDigit == 3)
            #expect(abs((scene.vaultDoorDepth ?? .nan) - scene.layout.vaultDoorStopZ) < 1e-4)
        }
        #expect(round.state.phase == .vault)
        round.resume()
        try round.advance(to: 4.6)  // 1.4 s of game time left
        apply(presenter, round)
        #expect(presenter.vault.countdownDigit == 2 && presenter.vault.countdownUrgent == true)
        let countdown = try #require(presenter.vault.root.findEntity(named: "vault.countdown"))
        #expect(countdown.scale.y > 1.5)  // urgency is also thickness, not colour alone
    }

    // MARK: Stop, abort, retry

    @Test func stopAbortAndRetryLeaveNothingBehind() throws {
        var round = try DomainRound(vaults: 3)
        let (presenter, scene) = try makePresenter(for: round)
        try round.open(id(1), at: 1)
        apply(presenter, round)
        try round.completeBothSides(id(1), from: 1.2)
        try round.advance(to: 2)
        apply(presenter, round)
        try round.open(id(2), at: 2)
        try round.touch(id(2), .player2, .middle, at: 2.3)
        apply(presenter, round)
        #expect(presenter.vault.exitingDoor != nil)
        // Abort mid-vault (End round): everything hides, the copy included.
        round.exit()
        apply(presenter, round)
        #expect(round.state.phase == .ended(.aborted))
        #expect(scene.vaultDoorDepth == nil && presenter.vault.exitingDoor == nil)
        #expect(allIndicators(presenter).allSatisfy { $0 == nil } && presenter.vault.countdownDigit == nil)

        // Retry: a new generation starts with no vault and a clean first reveal.
        var retry = try DomainRound(vaults: 3)
        try retry.advance(to: 0.5)
        apply(presenter, retry)
        #expect(scene.vaultDoorDepth == nil && scene.vaultDoorState == .locked)
        try retry.open(id(1), at: 1)
        apply(presenter, retry)
        #expect(allIndicators(presenter).allSatisfy { $0 == .idle })
        #expect(PlayerID.allCases.allSatisfy { presenter.vault.sideComplete($0) == false })
        #expect(presenter.vault.countdownDigit == 5 && presenter.vault.exitingDoor == nil)
        #expect(doorEntities(in: scene).count == 1)
    }

    // MARK: Reduce Motion

    /// With Reduce Motion nothing pops or slides, the copy is dropped at once,
    /// and every state still reads: check vs ring, outline, number, door light.
    @Test func reduceMotionKeepsEveryStateReadableWithoutMovement() throws {
        var round = try DomainRound(vaults: 2)
        let (presenter, scene) = try makePresenter(for: round, reduceMotion: true)
        try round.open(id(1), at: 1)
        try round.touch(id(1), .player1, .top, at: 1.2)
        apply(presenter, round)
        let top = try #require(presenter.vault.buttons.findEntity(named: "vault.indicator.player1.top"))
        #expect(presenter.vault.indicator(.player1, .top) == .active)
        #expect(top.scale == .one && presenter.vault.diagnostics.pops == 0)
        try round.completeBothSides(id(1), from: 1.4)
        apply(presenter, round)
        let outline = try #require(presenter.vault.buttons.findEntity(named: "vault.outline.player1"))
        #expect(presenter.vault.diagnostics.sideCompletions == 2 && outline.isEnabled && outline.scale == .one)
        #expect(presenter.vault.diagnostics.pops == 0)
        // The door opens by fading its panels, which stay in place.
        #expect(scene.vaultDoorState == .open)
        let door = try #require(scene.root.findEntity(named: "vaultDoor"))
        for name in ["LeftDoorPanel", "RightDoorPanel"] {
            let panel = try #require(door.findEntity(named: name))
            #expect(abs(panel.position.x) < 1e-5)
            #expect(panel.components[OpacityComponent.self]?.opacity == 0)
        }
        // The next vault during the exit: the old door is simply gone.
        try round.advance(to: 2.2)
        apply(presenter, round)
        #expect(scene.vaultDoorDepth != nil)
        try round.open(id(2), at: 2.2)
        apply(presenter, round)
        #expect(presenter.vault.diagnostics.handoffs == 1 && presenter.vault.exitingDoor == nil)
        #expect(doorEntities(in: scene).count == 1)
        #expect(presenter.vault.countdownDigit == 5 && allIndicators(presenter).allSatisfy { $0 == .idle })
    }

    /// Without Reduce Motion the panels slide (no fade), and each activation
    /// and completed side pops once.
    @Test func withMotionThePanelsSlideOpen() throws {
        var round = try DomainRound(vaults: 1)
        let (presenter, scene) = try makePresenter(for: round)
        try round.open(id(1), at: 1)
        apply(presenter, round)
        try round.completeBothSides(id(1), from: 1.2)
        apply(presenter, round)
        let door = try #require(scene.root.findEntity(named: "vaultDoor"))
        let left = try #require(door.findEntity(named: "LeftDoorPanel"))
        let right = try #require(door.findEntity(named: "RightDoorPanel"))
        #expect(left.position.x < -1 && right.position.x > 1)  // slid out by their width
        #expect(left.components[OpacityComponent.self] == nil)
        #expect(presenter.vault.diagnostics.pops == 6 + 2)
    }

    // MARK: Bounded entities

    /// The presentation builds its parts once: many vaults later there are
    /// still six indicators, two outlines, one countdown and one door.
    @Test func entitiesStayBoundedAcrossManyVaults() throws {
        var round = try DomainRound(vaults: 5)
        let (presenter, scene) = try makePresenter(for: round)
        func count(_ prefix: String) -> Int {
            func walk(_ e: Entity) -> Int { (e.name.hasPrefix(prefix) ? 1 : 0) + e.children.reduce(0) { $0 + walk($1) } }
            return walk(scene.root)
        }
        var t = 1.0
        for n in 1...5 {
            try round.open(id(n), at: t)
            apply(presenter, round)
            try round.completeBothSides(id(n), from: t + 0.2)
            apply(presenter, round)
            t += 2
            try round.advance(to: t)
            apply(presenter, round)
        }
        #expect(presenter.vault.diagnostics.reveals == 5 && presenter.vault.diagnostics.opens == 5)
        #expect(count("vault.indicator.") == 6 && count("vault.outline.") == 2 && count("vault.countdown.digit.") == 6)
        #expect(count("vault.countdown") == 1 + 1 + 6)  // bar, digits holder, digits
        #expect(count("vaultDoor") <= 2 && count("vaultDoor.exiting") <= 1)
        presenter.stop()
        #expect(count("vaultDoor.exiting") == 0)
    }
}
