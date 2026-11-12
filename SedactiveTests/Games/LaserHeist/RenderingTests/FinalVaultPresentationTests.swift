import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// The final vault (Ending Vault assets 42, 43 and Inside Vault) at the end of the
/// corridor, the scripted entry on held game time, and the room for Diamond Time.
@MainActor
struct FinalVaultPresentationTests {
    private let generation = UUID()

    private func scene(robots: Bool = false, players: Set<PlayerID> = Set(PlayerID.allCases)) async throws -> LaserScene {
        let scene = LaserScene()
        scene.installEnvironment(authored: nil)
        scene.installFinalVaultArt(try #require(await FinalVaultArt.load(), "Ending Vault art in the asset catalog"))
        if robots {
            scene.robotAvatars = RobotAvatarLayer(scene: scene, players: players,
                                                  templates: try await RobotAvatarLayer.sharedTemplates())
        }
        return scene
    }

    private func entity(_ scene: LaserScene, _ name: String) throws -> Entity {
        try #require(scene.root.findEntity(named: name))
    }

    @Test func theVaultComesUpTheCorridorToItsStopAndOpens() async throws {
        let scene = try await scene()
        let vault = FinalVaultPresentation(scene: scene)
        let timeline = LaserFinalVaultTimeline(roster: PlayerID.allCases)
        let wall = try entity(scene, "finalVault.wall"), closed = try entity(scene, "finalVault.closed")
        let open = try entity(scene, "finalVault.open"), inside = try entity(scene, "finalVault.inside")
        #expect(vault.hasArt && !wall.isEnabled)

        // Approach: from deep in the corridor to the stop, the corridor moving with it.
        #expect(vault.update(.entry(timeline, elapsed: 0)) == 0)
        #expect(wall.isEnabled && scene.isCorridorShown)
        #expect(abs(wall.position.z - (FinalVaultPresentation.stopZ - FinalVaultPresentation.approachDistance)) < 1e-4)
        var last: Float = 0
        for step in 1...30 {
            let travelled = vault.update(.entry(timeline, elapsed: LaserFinalVaultTimeline.approach.upperBound * Double(step) / 30))
            #expect(travelled >= last)
            last = travelled
        }
        #expect(abs(last - FinalVaultPresentation.approachDistance) < 1e-4)
        #expect(abs(wall.position.z - FinalVaultPresentation.stopZ) < 1e-4)
        // Leaves the vault's stop at the team's travel speed: no jump in pace.
        let early = FinalVaultPresentation.approachTravel(at: 0.01, speed: scene.layout.travelSpeed) / 0.01
        #expect(abs(early - scene.layout.travelSpeed) < 0.3)
        // Closed (Asset 42) until the door opens; then the open art (Asset 43) with the room behind.
        #expect(closed.isEnabled && !open.isEnabled && !inside.isEnabled)
        vault.update(.entry(timeline, elapsed: LaserFinalVaultTimeline.open.upperBound + 0.01))
        #expect(!closed.isEnabled && open.isEnabled && inside.isEnabled)
        #expect(inside.position.z < wall.position.z)
        // Through the doorway into the room: corridor and wall go, the room fills the view.
        vault.update(.entry(timeline, elapsed: timeline.push.upperBound))
        #expect(!wall.isEnabled && !scene.isCorridorShown && inside.isEnabled)
        #expect(inside.position.z < scene.mapping.interactionPlaneZ)
        vault.update(.hidden)
        #expect(!wall.isEnabled && !inside.isEnabled && scene.isCorridorShown)
    }

    /// The doorway's measured place in Asset 43 lines up with the corridor, and each arc
    /// carries the mascot's middle through it, not through the wall.
    @Test func eachJumpPassesThroughTheDoorway() async throws {
        let scene = try await scene()
        let vault = FinalVaultPresentation(scene: scene)
        #expect(vault.doorwayY > scene.layout.corridorFloorY + 0.5 && vault.doorwayY < scene.layout.corridorFloorY + scene.layout.corridorHeight - 0.5)
        #expect(vault.doorwayRadius > 0.6 && vault.doorwayRadius < 1)
        for player in PlayerID.allCases {
            let laneX = scene.mapping.laneCenterX[player, default: 0]
            let wallZ = FinalVaultPresentation.stopZ - scene.mapping.interactionPlaneZ
            let f = try #require(stride(from: Float(0), through: 1, by: 0.001).first { vault.jumpOffset(player, at: $0).z <= wallZ })
            let at = vault.jumpOffset(player, at: f)
            let middle = SIMD2(laneX + at.x, at.y + 0.5)
            #expect(simd_distance(middle, SIMD2(0, vault.doorwayY)) < vault.doorwayRadius * 0.6, "\(player) at f \(f)")
            #expect(vault.jumpOffset(player, at: 0) == .zero)
            // Up first: a jump, not a slide.
            #expect(vault.jumpOffset(player, at: 0.35).y > 0.8)
        }
    }

    @Test func lemonThenTangerineJumpTheirBoardsStayAndNoBoardsInside() async throws {
        let scene = try await scene(robots: true)
        let robots = try #require(scene.robotAvatars)
        let vault = FinalVaultPresentation(scene: scene)
        let timeline = LaserFinalVaultTimeline(roster: PlayerID.allCases)
        let lemon = try #require(timeline.jump(of: .player1)), tangerine = try #require(timeline.jump(of: .player2))

        vault.update(.entry(timeline, elapsed: lemon.lowerBound + 0.5))
        let p1 = try #require(robots.scriptedMoves[.player1])
        #expect(p1.offset.y > 0 && p1.offset.z < 0 && p1.opacity == 1)
        #expect(robots.scriptedMoves[.player2] ?? RobotAvatarLayer.ScriptedMove.none == RobotAvatarLayer.ScriptedMove.none)
        #expect(robots.hoverboards[.player1]?.root.isEnabled == true) // the board stays behind, fading

        vault.update(.entry(timeline, elapsed: tangerine.lowerBound + 0.5))
        #expect(robots.scriptedMoves[.player1]?.opacity == 0) // Lemon is inside
        #expect((robots.scriptedMoves[.player2]?.offset.y ?? 0) > 0 && robots.scriptedMoves[.player2]?.opacity == 1)
        #expect(robots.hoverboards[.player1]?.root.isEnabled == false)

        vault.update(.inside(timeline))
        for player in PlayerID.allCases {
            let move = try #require(robots.scriptedMoves[player])
            #expect(move.offset == .zero && move.opacity == 1 && move.scale == 1 && move.boardOpacity == 0)
            #expect(robots.hoverboards[player]?.root.isEnabled == false)
        }
        vault.update(.hidden)
        #expect(robots.scriptedMoves.isEmpty)
        #expect(PlayerID.allCases.allSatisfy { robots.hoverboards[$0]?.root.isEnabled == true })
    }

    @Test func soloMovesLemonOnly() async throws {
        let scene = try await scene(robots: true, players: [.player1])
        let robots = try #require(scene.robotAvatars)
        let vault = FinalVaultPresentation(scene: scene)
        let timeline = LaserFinalVaultTimeline(roster: [.player1])
        for t in stride(from: 0.0, through: timeline.total, by: 0.1) {
            vault.update(.entry(timeline, elapsed: t))
            #expect(robots.scriptedMoves[.player2] == nil)
        }
        vault.update(.entry(timeline, elapsed: timeline.total))
        #expect(robots.scriptedMoves[.player1]?.opacity == 1 && robots.scriptedMoves[.player1]?.offset == .zero)
    }

    // MARK: - Presenter and HUD

    private func configuration() throws -> LaserRoundConfiguration {
        try LaserRoundConfiguration(
            evidenceTiming: LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25, deliveryAllowance: 0.1),
            clearanceMargin: 0.005, diamondPoints: nil, missionGateTarget: 5, actionCueLead: 1.4)
    }

    private func state(_ time: Double, _ phase: LaserRoundPhase) -> LaserGameState {
        LaserGameState(sessionGeneration: generation, phase: phase, gameTime: time, activityProgress: 60,
                       teamHealth: 5, teamScore: 0, encounters: [], missionProgress: 5, missionTarget: 5, vault: nil)
    }

    @Test func diamondTimeDiamondsAppearOnlyInsideTheVault() async throws {
        let scene = try await scene()
        scene.installDiamondArt(await LaserScene.loadDiamondArtwork())
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [])
        presenter.diamondTime.source = { _ in
            [DiamondTimeDiamond(id: 1, lane: .player1, offsetX: 0.3, heightAboveFloor: 1.4, collected: false)]
        }
        let events = [GameEvent(id: UUID(), sessionGeneration: generation, sequence: 1, gameTime: 60,
                                kind: .phaseChanged(.diamondTime))]
        var entry = LaserFinalVaultEntry(roster: PlayerID.allCases)
        entry.advance(by: 1)
        presenter.apply(state: state(60, .diamondTime), events: events, snapshot: nil, finalVault: entry)
        #expect(presenter.finalVault.stage == .entry(entry.timeline, elapsed: 1))
        #expect(presenter.diamondTime.floatingIDs.isEmpty && scene.isCorridorShown)
        entry.advance(by: 10)
        presenter.apply(state: state(60.5, .diamondTime), events: events, snapshot: nil, finalVault: entry)
        #expect(presenter.finalVault.stage == .inside(entry.timeline))
        #expect(presenter.diamondTime.floatingIDs == [1] && !scene.isCorridorShown)
        // Replay has no entry: Diamond Time is shown inside at once. Before it, nothing.
        presenter.apply(state: state(61, .diamondTime), events: events, snapshot: nil)
        #expect(presenter.finalVault.stage == .inside(nil))
        let fresh = GameplayScenePresenter(scene: try await self.scene(), configuration: try configuration(), encounters: [])
        fresh.apply(state: state(30, .activity), events: [], snapshot: nil)
        #expect(fresh.finalVault.stage == .hidden)
    }

    @Test func theHudWaitsForTheTeamToBeInsideBeforeDiamondTimesTitleAndSeconds() throws {
        let events = [GameEvent(id: UUID(), sessionGeneration: generation, sequence: 1, gameTime: 60,
                                kind: .phaseChanged(.diamondTime))]
        let entering = GameplayHUDModel(state: state(60, .diamondTime), events: events, configuration: try configuration(),
                                        activityDuration: 60, enteringFinalVault: true)
        #expect(entering.banner == .none && entering.diamondSecondsLeft == nil && entering.diamondReached)
        let inside = GameplayHUDModel(state: state(60, .diamondTime), events: events, configuration: try configuration(),
                                      activityDuration: 60)
        #expect(inside.banner == .retrieveDiamonds && inside.diamondSecondsLeft == 10)
    }
}
