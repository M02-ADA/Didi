import Foundation
import RealityKit
import UIKit
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
        for variant in [TimingIndicatorVariant.fill, .sweep, .closing, .circular] {
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
            #expect(renderer.root.findEntity(named: "timing.fill")?.isEnabled == (v != .closing))
            #expect(renderer.root.findEntity(named: "timing.circle")?.isEnabled == (v == .closing))
            #expect(renderer.root.findEntity(named: "timing.circle.halo")?.isEnabled == false)
        }
        renderer.apply(nil, variant: .fill, reduceMotion: true)
        #expect(!renderer.root.isEnabled)
    }
    @Test func defaultSelectsClosingAndLegacyFallbackIsPresentationOnly() throws {
        let (state, config) = try fixture(time: 3)
        let scene = LaserScene()
        #expect(scene.timingVariant == .circular)
        let presenter = GameplayScenePresenter(scene: scene, configuration: config, encounters: state.encounters.map(\.encounter))
        presenter.apply(state: state, events: [], snapshot: nil)
        let original = scene.timingPresentation
        scene.selectTimingVariant(.closing); scene.selectTimingVariant(.approved)
        #expect(scene.timingPresentation == original)
        #expect(scene.shownMoveCue?.move == .duck && scene.shownMoveCue?.acting == true)
        #expect(scene.root.findEntity(named: "laserFeedback.cue.duck")?.isEnabled == true)
    }
    @Test(arguments: [LaserMove.duck, .jump])
    func circleIsStationaryAndMarkersPassThroughInFrontAtConstantSpeed(move: LaserMove) throws {
        let renderer = TimingIndicatorRenderer()
        for time in [1.15, 2.6, 3.85, 3.99, 4, 4.06, 4.12, 4.13] {
            let (state, config) = try fixture(move, time: time)
            let m = try #require(LaserTimingPresentation.make(state: state, configuration: config))
            renderer.apply(m, variant: .closing, reduceMotion: false)
            let circle = try #require(renderer.root.findEntity(named: "timing.circle"))
            let left = try #require(renderer.root.findEntity(named: "timing.marker.left"))
            let right = try #require(renderer.root.findEntity(named: "timing.marker.right"))
            #expect(circle.position.x == 0 && circle.position.y == 0 && circle.isEnabled)
            #expect(abs(left.position.x + right.position.x) < 0.00001)
            #expect(left.position.z > circle.position.z + 0.003 && right.position.z == left.position.z)
            let expected = Float(min(time-4, 0.12)/3) * TimingIndicatorRenderer.width/2
            #expect(abs(left.position.x - expected) < 0.000001)
            if time == 4 { #expect(left.position.x == 0 && right.position.x == 0) }
            if time > 4 { #expect(left.position.x > 0 && right.position.x < 0, "Markers swapped sides") }
            if time == 4.12 {
                #expect(left.isEnabled && right.isEnabled)
                #expect((left.components[OpacityComponent.self]?.opacity ?? 0) > 0.44)
            }
            if time == 4.06 { #expect(circle.scale.x > 1.09) }
            if time == 4.13 { #expect(circle.scale.x == 1) }
        }
    }
    @Test func markerTravelIsContinuousAcrossCrossingAndFollowThroughIsBounded() throws {
        let r = TimingIndicatorRenderer()
        func offset(_ t: Double) throws -> Float {
            let (s, c) = try fixture(time: t)
            r.apply(try #require(LaserTimingPresentation.make(state: s, configuration: c)), variant: .closing, reduceMotion: false)
            return try #require(r.root.findEntity(named: "timing.marker.left")).position.x
        }
        let before = try offset(3.999999), at = try offset(4), after = try offset(4.000001)
        #expect(abs(before-at) < 0.000001 && abs(after-at) < 0.000001)
        let first = try offset(4.03), second = try offset(4.06), third = try offset(4.09)
        #expect(abs((second-first)-(third-second)) < 0.000001)
        let end = try offset(4.12), held = try offset(4.2)
        #expect(end == held)
    }
    @Test func greenTargetIsVisibleBeforeAnySuccessfulJudgement() throws {
        let renderer = TimingIndicatorRenderer()
        for time in [1.15, 2.6, 4.0] {
            let (state, config) = try fixture(time: time)
            let m = try #require(LaserTimingPresentation.make(state: state, configuration: config))
            renderer.apply(m, variant: .closing, reduceMotion: false)
            let circle = try #require(renderer.root.findEntity(named: "timing.circle") as? ModelEntity)
            let material = try #require(circle.model?.materials.first as? UnlitMaterial)
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            #expect(material.color.tint.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            #expect(circle.isEnabled && green > red && green > blue)
            #expect(!m.allClear && !m.label.contains("CLEAR") && state.teamScore == 0)
        }
    }
    @Test func circleResultFeedbackFollowsCommittedVerdictsAndEntitiesAreReused() throws {
        let (state, config) = try fixture(time: 4.4, judged: true)
        let renderer = TimingIndicatorRenderer()
        func tint() throws -> UIColor {
            let circle = try #require(renderer.root.findEntity(named: "timing.circle") as? ModelEntity)
            let material = try #require(circle.model?.materials.first as? UnlitMaterial)
            return material.color.tint
        }
        func present(_ verdicts: [PlayerID: Judgement]) throws {
            let e = state.encounters[0]
            let s = LaserGameState(sessionGeneration: state.sessionGeneration, phase: .activity,
                gameTime: state.gameTime, activityProgress: state.activityProgress,
                teamHealth: state.teamHealth, teamScore: state.teamScore,
                encounters: [.init(encounter: e.encounter, judgements: verdicts, effectsCommitted: true)])
            renderer.apply(try #require(LaserTimingPresentation.make(state: s, configuration: config)), variant: .closing, reduceMotion: false)
        }
        try present([.player1: .clear, .player2: .clear]); let clear = try tint()
        try present([.player1: .hit(.notAirborne), .player2: .clear]); let hit = try tint()
        try present([.player1: .unavailable(.stale), .player2: .unavailable(.stale)]); let unavailable = try tint()
        #expect(!clear.isEqual(hit) && !clear.isEqual(unavailable))
        let (pending, _) = try fixture(time: 4)
        renderer.apply(try #require(LaserTimingPresentation.make(state: pending, configuration: config)), variant: .closing, reduceMotion: false)
        #expect(!(try tint()).isEqual(clear), "Green target convergence is not the committed CLEAR feedback")
        let count = renderer.root.children.count
        for _ in 0..<30 { renderer.apply(renderer.model, variant: .closing, reduceMotion: false) }
        #expect(renderer.root.children.count == count)
        #expect(renderer.root.findEntity(named: "timing.circle") != nil)
    }
    @Test(arguments: [LaserMove.duck, .jump]) func selectedCircleSupportsSoloWithoutInventingP2(move: LaserMove) throws {
        let (state, config) = try fixture(move, time: 4.4, judged: true)
        let original = state.encounters[0].encounter
        let solo = try LaserEncounter(id: original.id, attemptID: original.attemptID,
            targets: [original.targets[0]], roster: [.player1])
        let s = LaserGameState(sessionGeneration: state.sessionGeneration, phase: .activity,
            gameTime: 4.4, activityProgress: 0.1, teamHealth: 5, teamScore: 100,
            encounters: [.init(encounter: solo, judgements: [.player1: .clear], effectsCommitted: true)])
        let m = try #require(LaserTimingPresentation.make(state: s, configuration: config))
        #expect(m.allClear && m.label == "P1 CLEAR" && m.verdicts[.player2] == nil)
    }
    @Test func productionPauseHidesThenResumesTheSameSourceModel() throws {
        let (state, config) = try fixture(time: 3)
        let scene = LaserScene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: config, encounters: state.encounters.map(\.encounter))
        presenter.apply(state: state, events: [], snapshot: nil)
        let m = scene.timingPresentation
        scene.setTimingPaused(true)
        #expect(scene.root.findEntity(named: "timing.circularCue")?.isEnabled == false)
        scene.setTimingPaused(false)
        #expect(scene.root.findEntity(named: "timing.circularCue")?.isEnabled == true)
        #expect(scene.timingPresentation == m)
        presenter.stop()
        #expect(scene.root.findEntity(named: "timing.circularCue")?.isEnabled == false)
    }

    @Test(arguments: [LaserMove.duck, .jump])
    func circularSweepUsesSourceProgressAndOnlyCommittedClearShowsPerfect(move: LaserMove) throws {
        let renderer = CircularTimingCueRenderer()
        for time in [1.15, 2.6, 3.99, 4.0, 4.06, 4.2, 4.4] {
            let (s,c) = try fixture(move, time: time, judged: time == 4.4)
            let m = try #require(LaserTimingPresentation.make(state: s, configuration: c))
            renderer.apply(m, reduceMotion: false)
            #expect(renderer.renderedProgress == Double(Int((m.progress * 120).rounded(.down)))/120)
            #expect((renderer.displayedState == "perfect") == (time == 4.4))
            if time == 4.2 { #expect(renderer.displayedState == "pending") }
            #expect(renderer.root.findEntity(named: "timing.circular.perfect")?.isEnabled == (time == 4.4))
        }
        let count = renderer.root.children.count
        let (s,c) = try fixture(move, time: 3)
        let m = try #require(LaserTimingPresentation.make(state: s, configuration: c))
        for _ in 0..<100 { renderer.apply(m, reduceMotion: true) }
        #expect(renderer.root.children.count == count && renderer.renderedProgress == 1)
        #expect(renderer.root.findEntity(named: "timing.circular.crossingPulse")?.isEnabled == false)
        renderer.apply(nil, reduceMotion: false)
        #expect(!renderer.root.isEnabled && renderer.displayedState == "hidden")
    }
    @Test func perfectRequiresCommittedCompleteRosterNotJustRingArrival() throws {
        let (state, config) = try fixture(time: 4.4, judged: true)
        for verdicts in [[PlayerID.player1: Judgement.clear], [.player1: .clear, .player2: .unavailable(.stale)], [.player1: .clear, .player2: .hit(.notAirborne)], [.player1: .clear, .player2: .clear]] {
            for committed in [false, true] {
                let e = state.encounters[0]
                let s = LaserGameState(sessionGeneration: state.sessionGeneration, phase: .activity, gameTime: 4.4,
                    activityProgress: 0, teamHealth: 5, teamScore: 0,
                    encounters: [.init(encounter: e.encounter, judgements: verdicts, effectsCommitted: committed)])
                let m = try #require(LaserTimingPresentation.make(state: s, configuration: config))
                #expect((CircularTimingCueRenderer.state(for: m) == "perfect") == (committed && verdicts.count == 2 && verdicts.values.allSatisfy { $0 == .clear }))
                #expect(s.teamScore == 0 && s.teamHealth == 5)
            }
        }
    }

    @Test func cleanBadgeUsesOneConnectedArcArrowAndSeparateLargeLabel() throws {
        let renderer = CircularTimingCueRenderer()
        #expect(renderer.progressMeshCount == 120)
        #expect(renderer.root.findEntity(named: "timing.radial.0") == nil)
        let arrow = try #require(renderer.root.findEntity(named: "timing.circular.icon.duck"))
        let label = try #require(renderer.root.findEntity(named: "timing.circular.label.duck"))
        #expect(arrow.position.y == 0 && label.position.y < -CircularTimingCueRenderer.diameter/2)
        #expect(CircularTimingCueRenderer.actionLabel(for: "duck") == "DUCK")
        #expect(CircularTimingCueRenderer.actionLabel(for: "jump") == "JUMP")
        let first = CircularTimingCueRenderer.arcVertices(progress: 0.5)
        #expect(first.count > 4)
        #expect(abs(first[0].y - 0.18) < 0.00001)
        #expect(abs(first[first.count-2].y + 0.18) < 0.00001)
    }

}
