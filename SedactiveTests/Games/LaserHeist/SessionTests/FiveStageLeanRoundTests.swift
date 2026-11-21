import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// The complete five-stage round with vertical lasers through the production coordinator
/// (16 November 2026): the game places every LEAN beam itself from its own boards, exactly where the
/// replay's synthetic players expect, and the renderer draws those beams and boards.
@MainActor
struct FiveStageLeanRoundTests {
    private func run(_ script: LaserReplayScript, step: Double = 0.25) async throws -> GameSessionCoordinator {
        let session = try LaserReplayDriver.makeSession(script: script)
        try await session.start()
        var time = 0.0
        while time < script.duration {
            try await session.advance(to: time)
            time += step
        }
        try await session.advance(to: script.duration)
        return session
    }

    @Test func theGamePlacesEveryLeanBeamAsPlannedAndEveryDodgeClears() async throws {
        let script = try LaserReplayScript.complete(seed: 1)
        let plan = try #require(script.fullRound)
        let session = try await run(script)
        let summary = try #require(session.summary)
        #expect(summary.outcome == .completed && summary.vaultsOpened == 5)
        let leans = session.encounters.flatMap(\.targets).filter { $0.requiredMove == .lean }
        #expect(leans.count == 38)
        for planned in session.encounters {
            let encounter = session.state?.encounters.first { $0.encounter.attemptID == planned.attemptID }?.encounter ?? planned
            let predicted = try #require(plan.predictedEncounters.first { $0.id == encounter.id })
            for target in encounter.targets where target.requiredMove == .lean {
                let beam = try #require(target.lean), expected = try #require(predicted.targets.first { $0.playerID == target.playerID }?.lean)
                #expect(!beam.voided && beam.escape == expected.escape)
                #expect(abs((beam.centerX ?? .nan) - (expected.centerX ?? .nan)) < 0.01, "\(encounter.id) \(target.playerID)")
            }
        }
        // The combined encounters actually played: 0 / 1 / 2 / 3 / 4 by stage, each a LEAN layer (both
        // players' beams, or one near one player) then ONE full-width DUCK 1.75 s later, both players
        // judged on their own; and no horizontal laser is ever split between DUCK and JUMP.
        let beats = LaserWaveBeat.fiveMinuteScript()
        var combinedByStage = [0, 0, 0, 0, 0]
        for (index, beat) in beats.enumerated() where beat.followsLayer {
            // As registered (the game places LEAN beams itself), from game state.
            let registered = try #require(session.state).encounters.map(\.encounter)
            let duck = try #require(registered.first { $0.id == beat.id })
            let layer = try #require(registered.first { $0.id == beats[index - 1].id })
            #expect(duck.targets.count == 2 && duck.targets.allSatisfy { $0.requiredMove == .duck })
            #expect(!layer.targets.isEmpty && layer.targets.allSatisfy { $0.requiredMove == .lean && $0.lean?.centerX != nil })
            #expect(abs(duck.targets[0].crossingTime - layer.targets[0].crossingTime - LaserWaveBeat.layerGap) < 1e-9)
            for target in duck.targets + layer.targets {
                #expect(session.results.contains { $0.playerID == target.playerID
                    && ($0.encounterID == duck.id || $0.encounterID == layer.id) })
            }
            combinedByStage[Int(beat.nominalCrossingTime / 60)] += 1
        }
        #expect(combinedByStage == [0, 1, 2, 3, 4])
        for encounter in session.encounters {
            #expect(Set(encounter.targets.map(\.requiredMove)).count == 1, "one continuous beam")
        }
        // Every LEAN target is a real CLEAR (no voids, no UNAVAILABLE), as every DUCK and JUMP.
        #expect(session.results.count == 96 && session.results.allSatisfy { $0.judgement == .clear })
        // The boards are game state, published with it, inside the corridor and apart.
        let boards = try #require(session.state?.boards)
        let a = try #require(boards[.player1]?.x), b = try #require(boards[.player2]?.x)
        #expect(LaserBoardGeometry.bounds.contains(a) && LaserBoardGeometry.bounds.contains(b))
        #expect(b - a >= LaserBoardGeometry.minimumSeparation - 1e-4)
    }

    @Test func standingStillThroughLeanBeamsIsHit() async throws {
        let script = try LaserReplayScript.complete(seed: 1, scenario: .healthDepleted)
        let session = try await run(script)
        // The first stage opens with LEAN OUT for both players: standing still is a HIT for each.
        let first = try #require(session.results.first)
        #expect(first.judgement == .hit(.insufficientClearance))
        #expect(session.summary?.outcome == .healthDepleted)
    }

    @Test func thePresenterDrawsLeanTargetsAsVerticalLasersWhereGameStatePlacedThem() async throws {
        let script = try LaserReplayScript.complete(seed: 1)
        let session = try LaserReplayDriver.makeSession(script: script)
        try await session.start()
        // Stage 1's first LEAN OUT crosses at 6 s: placed at 2 s, warning at 3 s.
        try await session.advance(to: 4)
        let state = try #require(session.state)
        let scene = LaserScene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: script.configuration, encounters: script.encounters)
        presenter.apply(state: state, events: session.events, snapshot: nil)
        let encounter = try #require(state.encounters.first { $0.encounter.targets.contains { $0.requiredMove == .lean } })
        for target in encounter.encounter.targets {
            let beam = try #require(target.lean)
            let id = "\(encounter.encounter.attemptID.uuidString)-\(target.playerID.rawValue)"
            let laser = try #require(presenter.verticalLasers.laser(for: id))
            #expect(laser.root.isEnabled)
            #expect(abs(Double(laser.root.position.x) - (beam.centerX ?? .nan)) < 1e-5)
            // No horizontal gate for a LEAN target.
            let key = LaserTargetKey(encounterID: encounter.encounter.id, attemptID: encounter.encounter.attemptID,
                                     playerID: target.playerID)
            #expect(presenter.hazard(for: key) == nil)
        }
        await session.stop()
    }
}
