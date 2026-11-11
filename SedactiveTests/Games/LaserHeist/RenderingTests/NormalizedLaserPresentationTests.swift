import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// The mascot-normalized laser presentation in gameplay (D07 mapping "B",
/// display only): a shared beam lines up for players of very different
/// heights, and a round where any player lacks an avatar scale falls back to
/// the judged bands for everyone. Targets and verdicts are never touched.
@MainActor
struct NormalizedLaserPresentationTests {
    /// The seeded full replay: P1 stands 1.60, P2 1.05 game units.
    private static func round() throws -> LaserReplayScript { try LaserReplayScript.complete() }

    private static func presenter(_ script: LaserReplayScript, references: [PlayerID: AvatarReference],
                                  players: Set<PlayerID> = Set(PlayerID.allCases)) async throws
        -> (GameplayScenePresenter, RobotAvatarLayer) {
        let scene = LaserScene()
        let layer = RobotAvatarLayer(scene: scene, players: players, references: references,
                                     templates: try await RobotAvatarLayer.sharedTemplates())
        layer.normalizesLaserBands = true
        scene.robotAvatars = layer
        return (GameplayScenePresenter(scene: scene, configuration: script.configuration, encounters: script.encounters), layer)
    }

    private static func references(_ script: LaserReplayScript) -> [PlayerID: AvatarReference] {
        let configuration = script.input.configuration
        return configuration.calibrations.mapValues { AvatarReference(calibration: $0, layout: configuration.playerPlaneLayout) }
    }

    @Test("Players 0.55 apart in height share one straight DUCK and JUMP beam, while their judged bands stay apart")
    func sharedBeamsLineUp() async throws {
        let script = try Self.round()
        let (presenter, layer) = try await Self.presenter(script, references: Self.references(script))
        for move in [LaserMove.duck, .jump] {
            let encounter = try #require(script.encounters.first { $0.targets.allSatisfy { $0.requiredMove == move } })
            let p1 = try #require(encounter.targets.first { $0.playerID == .player1 })
            let p2 = try #require(encounter.targets.first { $0.playerID == .player2 })
            if move == .duck {
                #expect(abs(p1.beam.lowerY - p2.beam.lowerY) > 0.4, "the judged bands really differ")
            }
            let a = presenter.displayedBand(p1), b = presenter.displayedBand(p2)
            // Only the fixed clearance margin scales differently: a few millimetres.
            #expect(abs(a.lowerBound - b.lowerBound) < 0.005 && abs(a.upperBound - b.upperBound) < 0.005,
                    "\(move): \(a) vs \(b)")
        }
        layer.remove()
    }

    @Test("A player without an avatar scale sends every lane back to its judged band")
    func missingScaleFallsBackForEveryone() async throws {
        let script = try Self.round()
        var references = Self.references(script)
        references[.player2] = nil   // P2 has an avatar but no compatible calibration: no scale
        let (presenter, layer) = try await Self.presenter(script, references: references)
        let encounter = try #require(script.encounters.first { $0.targets.allSatisfy { $0.requiredMove == .duck } })
        for target in encounter.targets {
            #expect(presenter.displayedBand(target) == Float(target.beam.lowerY)...Float(target.beam.upperY),
                    "\(target.playerID) is drawn at its judged band")
        }
        layer.remove()
    }
}

/// When both players' drawn bands coincide, the shared laser is ONE gate drawn
/// from wall to wall (no seam can open between two halves), and its look is
/// the more urgent of the two players'.
@MainActor
struct SharedBeamGateTests {
    /// The replay slice: both players share every band exactly.
    private static func setup() throws -> (LaserScene, GameplayScenePresenter, LaserReplayScript, LaserEncounter) {
        let script = try LaserReplayScript.load()
        let scene = LaserScene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: script.configuration, encounters: script.encounters)
        let duck = try #require(script.encounters.first { $0.targets.allSatisfy { $0.requiredMove == .duck } })
        return (scene, presenter, script, duck)
    }

    private static func state(_ script: LaserReplayScript, _ time: Double, judged: [PlayerID: Judgement] = [:],
                              encounter: LaserEncounter) -> LaserGameState {
        let judgements = Dictionary(uniqueKeysWithValues: PlayerID.allCases.map {
            ($0, judged[$0] ?? Judgement.pending(.awaitingFinalization))
        })
        return LaserGameState(sessionGeneration: script.input.configuration.sessionGeneration, phase: .activity,
                              gameTime: time, activityProgress: time, teamHealth: 5, teamScore: 0,
                              encounters: [LaserEncounterState(encounter: encounter, judgements: judgements, effectsCommitted: false)])
    }

    private static func key(_ encounter: LaserEncounter, _ player: PlayerID) -> LaserTargetKey {
        LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: player)
    }

    @Test("Coinciding bands draw one wall-to-wall gate; the partner's half is not drawn")
    func oneGateWallToWall() throws {
        let (scene, presenter, script, duck) = try Self.setup()
        let crossing = try #require(duck.targets.first?.crossingTime)
        presenter.apply(state: Self.state(script, crossing - 2, encounter: duck), events: [], snapshot: nil)
        let p1 = try #require(presenter.hazard(for: Self.key(duck, .player1)))
        let p2 = try #require(presenter.hazard(for: Self.key(duck, .player2)))
        #expect(presenter.sharedBeams == [Self.key(duck, .player1)])
        #expect(p1.root.isEnabled && !p2.root.isEnabled)
        #expect(p1.span == scene.fullLaserSpan && p1.emittersShown.left && p1.emittersShown.right)
        #expect(p1.joinedBand == nil)
        // Each player's band is still their own judged band.
        for target in duck.targets {
            #expect(presenter.displayedBand(target) == Float(target.beam.lowerY)...Float(target.beam.upperY))
        }
    }

    @Test("Either player's HIT flares the one shared gate")
    func partnerHitFlaresTheSharedGate() throws {
        let (_, presenter, script, duck) = try Self.setup()
        let crossing = try #require(duck.targets.first?.crossingTime)
        presenter.apply(state: Self.state(script, crossing - 0.5, encounter: duck), events: [], snapshot: nil)
        let p1 = try #require(presenter.hazard(for: Self.key(duck, .player1)))
        #expect(p1.state == .active)
        presenter.apply(state: Self.state(script, crossing + 0.3, judged: [.player1: .clear, .player2: .hit(.notAirborne)],
                                          encounter: duck), events: [], snapshot: nil)
        #expect(p1.state == .hit)
    }
}
