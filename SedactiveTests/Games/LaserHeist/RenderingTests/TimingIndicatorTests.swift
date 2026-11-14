import Foundation
import RealityKit
import Testing
@testable import Sedactive

@MainActor struct TimingIndicatorTests {
    private let generation = UUID()
    private func fixture(_ move: LaserMove = .duck, time: Double, judged: Bool = false,
                         phase: LaserRoundPhase = .activity) throws -> (LaserGameState, LaserRoundConfiguration) {
        let config = try LaserReplayScript.load().configuration
        let targets = try PlayerID.allCases.map { p in
            try LaserTarget(playerID: p, calibrationRevision: 1, requiredMove: move,
                beam: .init(lowerY: move == .duck ? 1.45 : 0.005, upperY: move == .duck ? 1.5 : 0.015), warningTime: 1, crossingTime: 4)
        }
        let id = UUID(uuidString: "AA000000-0000-4000-8000-000000000001")!
        let encounter = try LaserEncounter(id: id, attemptID: id, targets: targets)
        let verdicts = Dictionary(uniqueKeysWithValues: PlayerID.allCases.map { ($0, judged ? Judgement.clear : .pending(.awaitingFinalization)) })
        return (.init(sessionGeneration: generation, phase: phase, gameTime: time, activityProgress: 0.1,
            teamHealth: 5, teamScore: judged ? 200 : 0,
            encounters: [.init(encounter: encounter, judgements: verdicts, effectsCommitted: judged)]), config)
    }
    @Test(arguments: [LaserMove.duck, .jump], [1.15, 2.5, 3.85, 4, 4.4])
    func variantsUseIdenticalTimelineAndNeverMutateDomain(move: LaserMove, time: Double) throws {
        let (state, config) = try fixture(move, time: time, judged: time > 4.35)
        let scene = LaserScene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: config, encounters: state.encounters.map(\.encounter))
        var models: [LaserTimingPresentation] = []
        for variant in [TimingIndicatorVariant.fill, .sweep, .closing] {
            scene.selectTimingVariant(variant)
            presenter.apply(state: state, events: [], snapshot: nil)
            models.append(try #require(scene.timingPresentation))
            #expect(scene.timingVariant == variant)
            #expect(state.teamScore == (time > 4.35 ? 200 : 0) && state.gameTime == time && state.teamHealth == 5)
        }
        #expect(models.allSatisfy { $0 == models[0] })
        #expect(models[0].evidenceWindow == config.evidenceTiming.captureWindow(crossing: 4))
        #expect(models[0].move == move && models[0].generation == generation)
    }
    @Test func exactPhaseSemanticsAndNoPerfectWindow() throws {
        for (time, phase) in [(1.15, LaserTimingPresentation.Phase.approach), (2.6, .prepare), (4, .crossing), (4.2, .passed)] {
            let (state, config) = try fixture(time: time)
            let model = try #require(LaserTimingPresentation.make(state: state, configuration: config))
            #expect(model.phase == phase && !model.allClear && !model.label.contains("PERFECT"))
            #expect(model.progress == min(1, (time - 1)/3))
        }
    }
    @Test func unavailableAndHiddenOutsideActivityOrAfterTail() throws {
        let (before, config) = try fixture(time: 0.5)
        #expect(LaserTimingPresentation.make(state: before, configuration: config) == nil)
        let (vault, _) = try fixture(time: 2, phase: .vault)
        #expect(LaserTimingPresentation.make(state: vault, configuration: config) == nil)
        let (past, _) = try fixture(time: 6)
        #expect(LaserTimingPresentation.make(state: past, configuration: config) == nil)
    }
    @Test func pauseAndResumeKeepSourceProgressAndWithdrawnCannotRevive() throws {
        let (state, config) = try fixture(time: 3)
        let normal = try #require(LaserTimingPresentation.make(state: state, configuration: config))
        let paused = try #require(LaserTimingPresentation.make(state: state, configuration: config, paused: true))
        #expect(paused.phase == .paused && paused.progress == normal.progress && paused.gameTime == normal.gameTime)
        #expect(LaserTimingPresentation.make(state: state, configuration: config, withdrawn: [normal.attemptID]) == nil)
    }
    @Test func stopAndGenerationReplacementClearOldModel() throws {
        let (state, config) = try fixture(time: 3)
        let scene = LaserScene(); scene.selectTimingVariant(.fill)
        let presenter = GameplayScenePresenter(scene: scene, configuration: config, encounters: state.encounters.map(\.encounter))
        presenter.apply(state: state, events: [], snapshot: nil)
        #expect(scene.timingPresentation != nil)
        presenter.stop()
        #expect(scene.timingPresentation == nil)
        let fresh = LaserGameState(sessionGeneration: UUID(), phase: .activity, gameTime: 0,
            activityProgress: 0, teamHealth: 5, teamScore: 0, encounters: [])
        presenter.apply(state: fresh, events: [], snapshot: nil)
        #expect(scene.timingPresentation == nil && fresh.sessionGeneration != generation)
    }
    @Test func reduceMotionUsesStaticPhaseDiagramForEveryVariant() throws {
        let (state, config) = try fixture(time: 3.8)
        let m = try #require(LaserTimingPresentation.make(state: state, configuration: config))
        #expect(m.displayedProgress(reduceMotion: true) == 0.5)
        #expect(m.displayedProgress(reduceMotion: false) == m.progress)
        let renderer = TimingIndicatorRenderer()
        for v in [TimingIndicatorVariant.fill, .sweep, .closing] {
            renderer.apply(m, variant: v, reduceMotion: true)
            #expect(renderer.root.findEntity(named: "timing.marker.left")?.isEnabled == false)
            #expect(renderer.root.findEntity(named: "timing.fill")?.isEnabled == true)
        }
        renderer.apply(nil, variant: .fill, reduceMotion: true)
        #expect(!renderer.root.isEnabled)
    }
    @Test func defaultRetainsApprovedIndicatorAndSwitchIsPresentationOnly() throws {
        let (state, config) = try fixture(time: 3)
        let scene = LaserScene()
        #expect(scene.timingVariant == .approved)
        let presenter = GameplayScenePresenter(scene: scene, configuration: config, encounters: state.encounters.map(\.encounter))
        presenter.apply(state: state, events: [], snapshot: nil)
        let original = scene.timingPresentation
        scene.selectTimingVariant(.closing); scene.selectTimingVariant(.approved)
        #expect(scene.timingPresentation == original)
        #expect(scene.shownMoveCue?.move == .duck && scene.shownMoveCue?.acting == true)
    }
}
