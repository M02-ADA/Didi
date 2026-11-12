import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// iPad, 12 November 2026 (P0): in live rounds the DUCK beam sat too low on the mascots and a
/// parent/child pair saw one laser as two stepped halves. Live mascots never had the normalized
/// (mascot-space) laser bands the replay uses, so each lane drew its player's physical-height
/// band. Display only: targets, judged bands and verdicts are unchanged.
@MainActor
struct LiveLaserPresentationTests {
    /// The seeded full replay: P1 stands 1.60, P2 1.05 game units (a parent and a child).
    private static func round() throws -> LaserReplayScript { try LaserReplayScript.complete() }

    private static func references(_ script: LaserReplayScript) -> [PlayerID: AvatarReference] {
        let configuration = script.input.configuration
        return configuration.calibrations.mapValues { AvatarReference(calibration: $0, layout: configuration.playerPlaneLayout) }
    }

    private static func state(_ script: LaserReplayScript, _ encounter: LaserEncounter, at time: Double) -> LaserGameState {
        LaserGameState(sessionGeneration: script.input.configuration.sessionGeneration, phase: .activity,
                       gameTime: time, activityProgress: time, teamHealth: 5, teamScore: 0,
                       encounters: [LaserEncounterState(encounter: encounter,
                           judgements: Dictionary(uniqueKeysWithValues: PlayerID.allCases.map { ($0, .pending(.awaitingFinalization)) }),
                           effectsCommitted: false)])
    }

    @Test func liveMascotsDrawTheNormalizedBands() async throws {
        let scene = LaserScene()
        scene.attachLiveAvatars(mailbox: AvatarPoseMailbox(maxAge: 0.25), templates: try await RobotAvatarLayer.sharedTemplates())
        #expect(scene.robotAvatars?.normalizesLaserBands == true)
        scene.detachLiveAvatars()
    }

    @Test(arguments: [LaserMove.duck, .jump])
    func aParentAndAChildSeeOneStraightBeamAtTheMascotsHeight(_ move: LaserMove) async throws {
        let script = try Self.round()
        let scene = LaserScene()
        let layer = RobotAvatarLayer(scene: scene, players: Set(PlayerID.allCases), references: Self.references(script),
                                     templates: try await RobotAvatarLayer.sharedTemplates())
        layer.normalizesLaserBands = true
        scene.robotAvatars = layer
        let presenter = GameplayScenePresenter(scene: scene, configuration: script.configuration, encounters: script.encounters)
        let encounter = try #require(script.encounters.first { $0.targets.allSatisfy { $0.requiredMove == move } })
        let p1 = try #require(encounter.targets.first { $0.playerID == .player1 })
        let p2 = try #require(encounter.targets.first { $0.playerID == .player2 })
        presenter.apply(state: Self.state(script, encounter, at: p1.crossingTime - 2), events: [], snapshot: nil)

        // One gate, wall to wall, both emitters, no joined step.
        let key1 = LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: .player1)
        let key2 = LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: .player2)
        let lead = try #require(presenter.hazard(for: key1)), partner = try #require(presenter.hazard(for: key2))
        #expect(presenter.sharedBeams == [key1])
        #expect(lead.root.isEnabled && !partner.root.isEnabled)
        #expect(lead.span == scene.fullLaserSpan && lead.emittersShown.left && lead.emittersShown.right)
        #expect(lead.joinedBand == nil)

        // The same height for both players, relative to the 1.6 m mascot, whatever their own heights.
        let a = presenter.displayedBand(p1), b = presenter.displayedBand(p2)
        #expect(abs(a.lowerBound - b.lowerBound) < 0.005 && abs(a.upperBound - b.upperBound) < 0.005)
        let mascot = RobotAvatarLayer.standingHeight
        switch move {
        case .duck:
            // Across the top of the standing mascot's head: standing hits it, a crouch passes under.
            #expect(a.lowerBound > 0.85 * mascot && a.upperBound < mascot, "\(a)")
        case .jump:
            // Just above the mascot's soles: a valid jump lifts the feet over it.
            #expect(a.lowerBound > 0 && a.upperBound < 0.05 * mascot, "\(a)")
        }
        // Judged bands are still each player's own (the child's are lower).
        #expect(abs(p1.beam.lowerY - p2.beam.lowerY) > 0.0005)
        layer.remove()
    }

    /// A Solo Test shows Lemon alone: the missing Tangerine must not send the beam back to the
    /// player's physical height.
    @Test func soloWithOneMascotStillDrawsTheNormalizedBand() async throws {
        let script = try Self.round()
        let child = try #require(Self.references(script)[.player2]) // 1.05: a scale well away from 1
        let scene = LaserScene()
        let layer = RobotAvatarLayer(scene: scene, players: [.player1], references: [.player1: child],
                                     templates: try await RobotAvatarLayer.sharedTemplates())
        layer.normalizesLaserBands = true
        scene.robotAvatars = layer
        let presenter = GameplayScenePresenter(scene: scene, configuration: script.configuration, encounters: script.encounters)
        let duck = try #require(script.encounters.first { $0.targets.allSatisfy { $0.requiredMove == .duck } })
        let target = try #require(duck.targets.first { $0.playerID == .player1 })
        let scale = try #require(layer.laserBandScale(for: .player1, mapping: scene.mapping))
        #expect(abs(scale - 1) > 0.3)
        let shown = presenter.displayedBand(target)
        #expect(abs(shown.lowerBound - Float(target.beam.lowerY) * scale) < 1e-5)
        layer.remove()
    }
}
