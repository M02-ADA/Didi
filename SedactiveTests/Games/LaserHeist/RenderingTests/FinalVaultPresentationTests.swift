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
    /// 14 November 2026 regression: with the backdrop behind the mascots' landing, the corridor's
    /// floor and ceiling showed through the doorway. The sleeve lines that gap with the room art as
    /// the backdrop projects onto it (on screen it is the backdrop), stays under the wall's top edge
    /// (the corridor above the wall stays the corridor), and only exists while the doorway shows.
    @Test func theRoomSleeveIsTheBackdropSeenNearerAndStaysBehindTheWall() async throws {
        let scene = try await scene()
        let vault = FinalVaultPresentation(scene: scene)
        let timeline = LaserFinalVaultTimeline(roster: PlayerID.allCases)
        let wall = try entity(scene, "finalVault.wall"), inside = try entity(scene, "finalVault.inside")
        let sleeve = try entity(scene, "finalVault.sleeve")
        vault.update(.entry(timeline, elapsed: LaserFinalVaultTimeline.open.lowerBound - 0.01))
        #expect(!sleeve.isEnabled, "closed door: no room behind it")
        let wallTop = { wall.position.y + scene.layout.corridorWidth / FinalVaultArt.closedAspect / 2 }
        for t in [LaserFinalVaultTimeline.open.upperBound, timeline.push.lowerBound,
                  (timeline.push.lowerBound + timeline.push.upperBound) / 2, timeline.push.upperBound - 0.02] {
            vault.update(.entry(timeline, elapsed: t))
            #expect(sleeve.isEnabled && inside.isEnabled, "t \(t)")
            let bounds = sleeve.visualBounds(relativeTo: nil)
            #expect(bounds.max.z < wall.position.z && bounds.min.z <= inside.position.z, "t \(t): wall to backdrop")
            #expect(bounds.max.y < wallTop() && bounds.min.y > scene.layout.corridorFloorY, "t \(t): under the wall's top")
            // Any point of the backdrop maps to its own texture coordinate.
            for local in [SIMD3<Float>(0.3, -0.2, 0), [-0.6, 0.35, 0], [0, 0, 0]] {
                let world = inside.convert(position: local, to: nil)
                let uv = vault.roomArtCoordinate(of: world)
                #expect(abs(uv.x - (0.5 + local.x / FinalVaultArt.insideAspect)) < 1e-3 && abs(uv.y - (0.5 + local.y)) < 1e-3,
                        "t \(t) \(local): \(uv)")
            }
        }
        vault.update(.entry(timeline, elapsed: timeline.push.upperBound))
        #expect(!sleeve.isEnabled, "inside: the room backdrop alone")
        vault.update(.hidden)
        #expect(!sleeve.isEnabled)
    }

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

        vault.update(.entry(timeline, elapsed: lemon.upperBound + FinalVaultPresentation.continueDuration + 0.05))
        // Lemon has carried the jump on through the doorway and stands inside the vault, visible
        // (13 November 2026: it used to vanish here and drop in from above later).
        let inside = try #require(robots.scriptedMoves[.player1])
        #expect(inside.opacity == 1 && inside.offset.z < FinalVaultPresentation.stopZ - scene.mapping.interactionPlaneZ && abs(inside.offset.y) < 1e-4)
        #expect((robots.scriptedMoves[.player2]?.offset.y ?? 0) > 0 && robots.scriptedMoves[.player2]?.opacity == 1, "Tangerine in flight")
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

    // MARK: - One continuous jump (13 November 2026)

    /// The rendered mascot through the whole entry at 120 Hz, Solo and co-op: never hidden after
    /// take-off, no jump in place or in on-screen size between frames, never ahead of the wall
    /// while it shows, and on its own place, full size and live at the end.
    @Test(arguments: [false, true]) func theEntryIsOneContinuousMovement(solo: Bool) async throws {
        let roster: [PlayerID] = solo ? [.player1] : PlayerID.allCases
        let scene = try await scene(robots: true, players: Set(roster))
        let robots = try #require(scene.robotAvatars)
        let vault = FinalVaultPresentation(scene: scene)
        let timeline = LaserFinalVaultTimeline(roster: roster)
        let camera = scene.layout.cameraPosition
        // Position as drawn; the move's own size and opacity (the layer also dims an untracked
        // mascot, and the take-off's crouch-to-stretch is a change of shape, not of size).
        func rendered(_ player: PlayerID) throws -> (position: SIMD3<Float>, scale: Float, opacity: Float) {
            let container = try #require(robots.robots[player]?.container)
            let move = robots.scriptedMoves[player] ?? .none
            return (container.position(relativeTo: nil), move.scale, container.isEnabled ? move.opacity : 0)
        }
        var last: [PlayerID: (position: SIMD3<Float>, scale: Float, opacity: Float)] = [:]
        let dt = 1.0 / 120
        for step in 0...Int(timeline.total / dt) {
            let t = Double(step) * dt
            vault.update(.entry(timeline, elapsed: t))
            for player in roster {
                let now = try rendered(player)
                let jump = try #require(timeline.jump(of: player))
                if t >= jump.lowerBound { #expect(now.opacity == 1, "\(player) visible at \(t)") }
                if let before = last[player] {
                    #expect(simd_distance(now.position, before.position) < 0.12, "\(player) jumps \(simd_distance(now.position, before.position)) m at \(t)")
                    // On-screen size (scale over distance from the camera) changes smoothly.
                    let size = now.scale / (camera.z - now.position.z), sizeBefore = before.scale / (camera.z - before.position.z)
                    #expect(abs(size / sizeBefore - 1) < 0.05, "\(player) size step \(size / sizeBefore) at \(t)")
                }
                // While the wall shows, the mascot is never in front of it.
                if let wall = scene.root.findEntity(named: "finalVault.wall"), wall.isEnabled, t > jump.upperBound {
                    #expect(now.position.z < wall.position(relativeTo: nil).z, "\(player) behind the wall at \(t)")
                }
                last[player] = now
            }
        }
        vault.update(.entry(timeline, elapsed: timeline.total))
        #expect(robots.walksInVault, "floor walking before Diamond Time starts")
        for player in roster {
            let move = try #require(robots.scriptedMoves[player])
            #expect(move.offset == .zero && move.scale == 1 && move.squash == 1 && move.anchorWeight == 0, "\(player): live at the end")
        }
        // Diamond Time: the same place, no pop.
        let before = try roster.map { try rendered($0).position }
        vault.update(.inside(timeline))
        let after = try roster.map { try rendered($0).position }
        #expect(zip(before, after).allSatisfy { simd_distance($0, $1) < 1e-4 })
    }

    /// The jump hands over to its continuation with the same position and velocity, and comes
    /// down on the mascot's landing still falling, with no sideways or forward speed (no skating).
    @Test func theJumpCarriesOnIntoTheLandingWithoutAKink() async throws {
        let scene = try await scene()
        let vault = FinalVaultPresentation(scene: scene)
        let flight = Float(LaserFinalVaultTimeline.jumpDuration - LaserFinalVaultTimeline.anticipation)
        let span = Float(FinalVaultPresentation.continueDuration)
        let h: Float = 1e-3
        for player in PlayerID.allCases {
            #expect(simd_distance(vault.jumpOffset(player, at: 1), vault.continuation(player, at: 0)) < 1e-5)
            let jumpVelocity = (vault.jumpOffset(player, at: 1) - vault.jumpOffset(player, at: 1 - h)) / (h * flight)
            let carryVelocity = (vault.continuation(player, at: h) - vault.continuation(player, at: 0)) / (h * span)
            #expect(simd_distance(jumpVelocity, carryVelocity) < 0.05 * simd_length(jumpVelocity), "\(player): \(jumpVelocity) vs \(carryVelocity)")
            let down = vault.continuation(player, at: 1)
            #expect(simd_distance(down, [0, 0, -vault.pushDistance]) < 1e-5, "lands on its own place inside")
            let landing = (vault.continuation(player, at: 1) - vault.continuation(player, at: 1 - h)) / (h * span)
            #expect(abs(landing.x) < 0.02 && abs(landing.z) < 0.02 && landing.y < -1, "\(player) touchdown \(landing)")
            // Never below the floor on the way down.
            #expect(stride(from: Float(0), through: 1, by: 0.01).allSatisfy { vault.continuation(player, at: $0).y >= -1e-4 })
        }
    }

    /// A held root keeps the scripted mascot still against live tracking, then blends back.
    @Test func aHeldRootBlendsBackToTheTrackedRoot() async throws {
        let scene = try await scene(robots: true, players: [.player1])
        let robots = try #require(scene.robotAvatars)
        let tracked = robots.trackedRootPosition(.player1) ?? .zero
        let held = tracked + [0.4, 0, 0]
        robots.scriptedMoves[.player1] = .init(offset: [0, 0.2, 0], anchor: held, anchorWeight: 1)
        let container = try #require(robots.robots[.player1]?.container)
        #expect(simd_distance(container.position, held + [0, 0.2, 0]) < 1e-5)
        robots.scriptedMoves[.player1] = .init(anchor: held, anchorWeight: 0.5)
        #expect(simd_distance(container.position, tracked + [0.2, 0, 0]) < 1e-5)
        robots.scriptedMoves[.player1] = .init(anchor: held, anchorWeight: 0)
        #expect(simd_distance(container.position, tracked) < 1e-5)
    }
}
