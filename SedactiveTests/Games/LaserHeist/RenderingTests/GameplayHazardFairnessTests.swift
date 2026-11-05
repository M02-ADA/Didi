import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// PR #17 review (Edo): the renderer must never hide a laser that gameplay
/// still expects a player to avoid. A pending target that is armed (or in
/// view while the team travels) always has a visible gate; only cosmetic
/// power-down tails may be dropped.
@MainActor
struct GameplayHazardFairnessTests {
    private let generation = UUID()

    private func configuration() throws -> LaserRoundConfiguration {
        try LaserRoundConfiguration(
            evidenceTiming: LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25, deliveryAllowance: 0.1),
            clearanceMargin: 0.005, diamondPoints: nil, actionCueLead: 1.4)
    }

    private func encounter(_ index: Int, crossing: [PlayerID: Double], warningLead: Double = 3) throws -> LaserEncounter {
        let id = UUID(uuidString: String(format: "18000000-0000-4000-8000-%012d", index))!
        let targets = try PlayerID.allCases.map { player in
            try LaserTarget(playerID: player, calibrationRevision: 1, requiredMove: .duck,
                            beam: LaserBeamBand(lowerY: player == .player1 ? 1.6 : 1.1, upperY: player == .player1 ? 1.62 : 1.12),
                            warningTime: crossing[player]! - warningLead, crossingTime: crossing[player]!)
        }
        return try LaserEncounter(id: id, attemptID: id, targets: targets)
    }

    private func state(_ time: Double, _ encounters: [LaserEncounter], judged: [UUID: [PlayerID: Judgement]] = [:],
                       phase: LaserRoundPhase = .activity) -> LaserGameState {
        LaserGameState(sessionGeneration: generation, phase: phase, gameTime: time, activityProgress: 0,
                       teamHealth: 5, teamScore: 0, encounters: encounters.map { encounter in
            LaserEncounterState(encounter: encounter, judgements: PlayerID.allCases.reduce(into: [:]) {
                $0[$1] = judged[encounter.id]?[$1] ?? .pending(.awaitingFinalization)
            }, effectsCommitted: false)
        })
    }

    private func key(_ encounter: LaserEncounter, _ player: PlayerID) -> LaserTargetKey {
        LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: player)
    }

    @Test func everyPendingHazardShowsUnderHeavyOverlap() throws {
        let scene = LaserScene()
        // Six encounters 0.5 s apart with a 6 s warning: all twelve targets armed at once.
        let encounters = try (0..<6).map { try encounter($0, crossing: [.player1: 10 + 0.5 * Double($0), .player2: 10 + 0.5 * Double($0)], warningLead: 6) }
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: encounters)
        presenter.apply(state: state(9.5, encounters), events: [], snapshot: nil)
        for encounter in encounters {
            for player in PlayerID.allCases {
                #expect(presenter.hazard(for: key(encounter, player))?.root.isEnabled == true)
            }
        }
        #expect(presenter.diagnostics.droppedHazards == 0)
    }

    @Test func pendingHazardsShowEvenWhenTheScheduleWasUnknownAtStart() throws {
        let scene = LaserScene()
        let encounters = try (0..<3).map { try encounter($0, crossing: [.player1: 10 + Double($0), .player2: 10 + Double($0)], warningLead: 5) }
        // The pool is sized from no schedule at all, e.g. encounters registered later.
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [])
        presenter.apply(state: state(8, encounters), events: [], snapshot: nil)
        #expect(presenter.visibleHazardCount == 6)
        #expect(presenter.diagnostics.droppedHazards == 0)
    }

    @Test func tailsAreCosmeticAndAlwaysYieldToPendingHazards() throws {
        let scene = LaserScene()
        // Five targets judged together leave five power-down tails; one more is pending.
        let judgedSet = try (0..<5).map { try encounter($0, crossing: [.player1: 10, .player2: 10]) }
        let next = try encounter(9, crossing: [.player1: 12, .player2: 12])
        let all = judgedSet + [next]
        // Expected peak sized from one encounter only: 2 per player.
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [next])
        let judged = Dictionary(uniqueKeysWithValues: judgedSet.map { ($0.id, [PlayerID.player1: Judgement.clear, .player2: .clear]) })
        presenter.apply(state: state(10.4, all, judged: judged), events: [], snapshot: nil)
        for player in PlayerID.allCases {
            #expect(presenter.hazard(for: key(next, player))?.root.isEnabled == true)
        }
        #expect(presenter.diagnostics.droppedHazards == 0)
        #expect(presenter.diagnostics.droppedTails > 0)
        #expect(presenter.visibleHazardCount == 4)
    }

    @Test func withdrawalAndPhaseChangesNeverHideAnArmedHazard() throws {
        let scene = LaserScene()
        let first = try encounter(1, crossing: [.player1: 10, .player2: 10])
        let second = try encounter(2, crossing: [.player1: 14, .player2: 14.5], warningLead: 5)
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [first, second])
        // The first attempt is withdrawn; the second is armed (warning at 9 / 9.5).
        let withdrawn = [GameEvent(id: UUID(), sessionGeneration: generation, sequence: 1, gameTime: 9.6,
                                   kind: .attemptWithdrawn(encounterID: first.id, attemptID: first.attemptID))]
        presenter.apply(state: state(9.6, [first, second]), events: withdrawn, snapshot: nil)
        #expect(presenter.hazard(for: key(first, .player1))?.state == .disabled)
        for player in PlayerID.allCases {
            #expect(presenter.hazard(for: key(second, player))?.root.isEnabled == true)
        }
        // Even if a stopped phase ever overlapped an armed target, it stays visible.
        presenter.apply(state: state(9.7, [first, second], phase: .vault), events: withdrawn, snapshot: nil)
        for player in PlayerID.allCases {
            #expect(presenter.hazard(for: key(second, player))?.root.isEnabled == true)
        }
        #expect(presenter.diagnostics.droppedHazards == 0)
    }

    /// Runs a schedule frame by frame (each target judged CLEAR at finalization)
    /// and checks that every pending target that should be visible has a gate.
    private func sweep(_ encounters: [LaserEncounter], configuration: LaserRoundConfiguration,
                       sizedFrom known: [LaserEncounter]? = nil, step: Double = 0.05) throws -> GameplayScenePresenter {
        let scene = LaserScene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: configuration, encounters: known ?? encounters)
        let lead = GameplayScenePresenter.approachLead(in: scene)
        let end = (encounters.flatMap(\.targets).map(\.crossingTime).max() ?? 0) + 2
        var missing = 0
        for tick in 0...Int(end / step) {
            let time = Double(tick) * step
            var judged: [UUID: [PlayerID: Judgement]] = [:]
            for encounter in encounters {
                for target in encounter.targets where time >= configuration.evidenceTiming.finalizationTime(crossing: target.crossingTime) {
                    judged[encounter.id, default: [:]][target.playerID] = .clear
                }
            }
            presenter.apply(state: state(time, encounters, judged: judged), events: [], snapshot: nil)
            for encounter in encounters {
                for target in encounter.targets where judged[encounter.id]?[target.playerID] == nil
                    && (time >= target.warningTime || time >= target.crossingTime - lead)
                    && time <= target.crossingTime {
                    if presenter.hazard(for: key(encounter, target.playerID))?.root.isEnabled != true { missing += 1 }
                }
            }
        }
        #expect(missing == 0)
        return presenter
    }

    @Test func asymmetricOverlappingCrossingsKeepEveryPendingHazard() throws {
        // P2 crosses 0.4 s after P1; encounters 1 s apart with a 5 s warning.
        let encounters = try (0..<8).map {
            try encounter($0, crossing: [.player1: 8 + Double($0), .player2: 8.4 + Double($0)], warningLead: 5)
        }
        let presenter = try sweep(encounters, configuration: try configuration())
        #expect(presenter.diagnostics.droppedHazards == 0)
        #expect(presenter.diagnostics.poolGrowth == 0)
        // The same schedule, unknown at the start, still shows everything (the pool grows).
        let late = try sweep(encounters, configuration: try configuration(), sizedFrom: [])
        #expect(late.diagnostics.droppedHazards == 0)
        #expect(late.diagnostics.poolGrowth > 0)
    }

    @Test(arguments: [(warning: 3.0, offset: 0.0), (warning: 4.5, offset: 1.5), (warning: 6.0, offset: 0.7)])
    func supportedDirectorRoundsNeverHideAHazard(profile: (warning: Double, offset: Double)) throws {
        let fixture = try #require(LaserReplayScenarios.make().first).input.configuration
        let base = LaserPlayerDifficulty.conservativeCandidate
        let second = LaserPlayerDifficulty(
            requestedCrownDropShare: base.requestedCrownDropShare, requestedSoleLiftShare: base.requestedSoleLiftShare,
            beamThicknessShare: base.beamThicknessShare, maximumCrownDropShare: base.maximumCrownDropShare,
            maximumSoleLiftShare: base.maximumSoleLiftShare, clearanceReserveShare: base.clearanceReserveShare,
            maximumJumpsInWindow: base.maximumJumpsInWindow, jumpWindow: base.jumpWindow,
            minimumJumpSpacing: base.minimumJumpSpacing, maximumConsecutiveJumps: base.maximumConsecutiveJumps,
            minimumTargetSpacing: base.minimumTargetSpacing, warningLead: profile.warning, cueLead: base.cueLead,
            crossingOffset: profile.offset)
        let configuration = try LaserRoundConfiguration(
            evidenceTiming: LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25, deliveryAllowance: 0.1),
            clearanceMargin: 0.005, diamondPoints: nil,
            scheduling: LaserSchedulingConfiguration(players: [.player1: base, .player2: second],
                                                     searchStep: 0.25, maximumSearchSteps: 2000))
        let schedule = try LaserWaveDirector().schedule(script: LaserWaveBeat.fiveMinuteScript(), calibrations: fixture.calibrations,
                                                        layout: fixture.playerPlaneLayout, configuration: configuration)
        let presenter = try sweep(schedule.encounters, configuration: configuration, step: 0.1)
        #expect(presenter.diagnostics.droppedHazards == 0)
        // The schedule-based estimate covered the whole round.
        #expect(presenter.diagnostics.poolGrowth == 0)
    }
}
