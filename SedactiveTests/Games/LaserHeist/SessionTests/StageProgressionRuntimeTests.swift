import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// 17 November 2026 (after device play): the five-stage progression, combined HORIZONTAL + VERTICAL
/// encounters and the HUD progress, checked through the REAL runtime (production coordinator,
/// `LaserGame`, live director and presenter), not only the static script.
///
/// Root causes fixed:
/// - A combined encounter's full-width DUCK was registered at its own warning (3 s before its
///   crossing), only 1.25 s before its vertical layer crossed: the two hazards shared the screen for
///   about 1.5 s, so the sequence read as a LEAN and then an unrelated DUCK. It is now registered
///   with its layer, so the whole arrangement shows for about 4 s before the first crossing.
/// - Without the mascots' normalized bands (pictograms in Release, `-judgedLaserBands`, a mascot
///   without its scale), each horizontal laser was drawn as two lane halves at each player's own
///   judged height: one laser looked like HIGH on one side and LOW on the other.
/// - The HUD fill was one whole-round share across the track, diamond segment included, so it ran
///   ahead of the checkpoints and froze short of each from stage 3 on (and for most of a stage after
///   a DEBUG skip), then jumped at the gate.
@MainActor
struct StageProgressionRuntimeTests {
    // MARK: - The schedule

    @Test func fiveStagesHaveTheirSlotsAndCombinedSequencesWithoutCompoundCrossings() throws {
        let beats = LaserWaveBeat.fiveMinuteScript()
        #expect(beats.count == 73)
        var slots = [0, 0, 0, 0, 0], combined = [0, 0, 0, 0, 0]
        for (index, beat) in beats.enumerated() {
            let stage = Int(beat.nominalCrossingTime / 60)
            slots[stage] += 1
            if beat.move != .lean {
                // A horizontal laser asks both players for the same move: one continuous beam.
                #expect(Set(PlayerID.allCases.compactMap { beat.demand(for: $0)?.move }) == [beat.move]
                        && beat.demands.count == 2, "beat \(index) split")
            }
            guard beat.followsLayer else { continue }
            combined[stage] += 1
            let layer = beats[index - 1]
            #expect(layer.move == .lean && beat.move == .duck)
            #expect(LaserWaveBeat.layeredHorizontalIDs.contains(beat.id))
        }
        #expect(slots == [9, 13, 15, 17, 19] && combined == [0, 3, 4, 5, 7])
        #expect(LaserWaveBeat.layeredHorizontalIDs.count == 19)

        // As scheduled for real players: the DUCK is registered with its layer (both shown together),
        // and its action cue starts only after the LEAN's evidence window has closed (no LEAN + DUCK
        // at one crossing).
        let script = try LaserReplayScript.complete(seed: 1)
        let timing = script.configuration.evidenceTiming
        let cueLead = try #require(script.configuration.scheduling?.players[.player1]?.cueLead)
        for duck in script.encounters where LaserWaveBeat.layeredHorizontalIDs.contains(duck.id) {
            let index = try #require(beats.firstIndex { $0.id == duck.id })
            let layer = try #require(script.encounters.first { $0.id == beats[index - 1].id })
            #expect(abs(LaserLiveRoundDirector.registrationTime(duck) - LaserLiveRoundDirector.registrationTime(layer)) < 1e-9)
            #expect(duck.targets.allSatisfy { $0.crossingTime - cueLead >= layer.targets[0].crossingTime + timing.windowAfter })
            // Its own warning and crossing are unchanged.
            #expect(duck.targets.allSatisfy { abs($0.crossingTime - $0.warningTime - 3) < 1e-9 })
        }
    }

    // MARK: - What the presenter actually shows

    private struct Shown {
        var overlap: [UUID: Double] = [:]          // combined DUCK id → seconds both hazards were on screen
        var horizontalFrames = 0, splitFrames = 0, partialSpanFrames = 0, wrongHeightFrames = 0
    }

    /// The complete replay through the production coordinator, presented every 0.1 s.
    private func playAndWatch() async throws -> (GameSessionCoordinator, Shown, LaserScene) {
        let script = try LaserReplayScript.complete(seed: 1)
        let end = script.duration
        let session = try LaserReplayDriver.makeSession(script: script)
        try await session.start()
        let scene = LaserScene()   // no mascots: each player's own judged band (the pictogram case)
        let presenter = GameplayScenePresenter(scene: scene, configuration: script.configuration, encounters: script.encounters)
        let beats = LaserWaveBeat.fiveMinuteScript()
        var shown = Shown()
        let step = 0.1
        var time = 0.0
        while time < end {
            try await session.advance(to: time)
            guard let state = session.state else { time += step; continue }
            presenter.apply(state: state, events: session.events, snapshot: nil)
            for item in state.encounters {
                let encounter = item.encounter
                let keys = encounter.targets.filter { $0.requiredMove != .lean }.map {
                    LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: $0.playerID) }
                let visible = keys.compactMap { presenter.hazard(for: $0) }.filter(\.root.isEnabled)
                guard !visible.isEmpty else { continue }
                shown.horizontalFrames += 1
                if visible.count > 1 { shown.splitFrames += 1 }
                if visible.contains(where: { $0.span != scene.fullLaserSpan }) { shown.partialSpanFrames += 1 }
                // Drawn at the most demanding member's band: the lowest for a DUCK, the highest for a JUMP.
                if let drawn = visible.first, keys.count == 2 {
                    let bands = encounter.targets.map { presenter.displayedBand($0) }
                    let expected = encounter.targets[0].requiredMove == .duck
                        ? bands.min { $0.lowerBound < $1.lowerBound }! : bands.max { $0.upperBound < $1.upperBound }!
                    if abs(drawn.band.lowerBound - expected.lowerBound) > 1e-4 { shown.wrongHeightFrames += 1 }
                }
                // A combined sequence: is its vertical layer on screen in the same frame?
                guard LaserWaveBeat.layeredHorizontalIDs.contains(encounter.id),
                      let index = beats.firstIndex(where: { $0.id == encounter.id }),
                      let layer = state.encounters.first(where: { $0.encounter.id == beats[index - 1].id })?.encounter else { continue }
                let vertical = layer.targets.contains { target in
                    presenter.verticalLasers.laser(for: "\(layer.attemptID.uuidString)-\(target.playerID.rawValue)")?.root.isEnabled == true
                }
                if vertical { shown.overlap[encounter.id, default: 0] += step }
            }
            time += step
        }
        try await session.advance(to: script.duration)
        return (session, shown, scene)
    }

    @Test func combinedSequencesShowBothHazardsTogetherAndEveryHorizontalLaserIsOneFullBeam() async throws {
        let (session, shown, _) = try await playAndWatch()
        #expect(session.summary?.vaultsOpened == 5)
        let beats = LaserWaveBeat.fiveMinuteScript()
        var byStage = [0, 0, 0, 0, 0]
        for (id, seconds) in shown.overlap {
            let beat = try #require(beats.first { $0.id == id })
            // The vertical beam (revealed 4 s before it crosses) and the full-width DUCK share the
            // screen until the vertical beam has passed and powered down.
            #expect(seconds >= 3.9, "\(id): together for only \(seconds) s")
            byStage[Int(beat.nominalCrossingTime / 60)] += 1
        }
        print("COMBINED overlap s: " + shown.overlap.values.sorted().map { String(format: "%.1f", $0) }.joined(separator: " "))
        #expect(byStage == [0, 3, 4, 5, 7], "combined sequences seen per stage: \(byStage)")
        // Every horizontal laser, every frame: one gate, wall to wall, at one height.
        #expect(shown.horizontalFrames > 1000)
        #expect(shown.splitFrames == 0 && shown.partialSpanFrames == 0 && shown.wrongHeightFrames == 0,
                "split \(shown.splitFrames) · partial \(shown.partialSpanFrames) · height \(shown.wrongHeightFrames)")
        // Both hazards of every combined sequence are judged, per player, once.
        let results = session.results
        for id in LaserWaveBeat.layeredHorizontalIDs {
            let index = try #require(beats.firstIndex { $0.id == id })
            for encounterID in [id, beats[index - 1].id] {
                let judged = results.filter { $0.encounterID == encounterID }
                #expect(Set(judged.map(\.playerID)).count == judged.count && !judged.isEmpty)
            }
        }
        #expect(results.count == 138 && results.allSatisfy { $0.judgement == .clear })
    }

    // MARK: - The HUD progress

    /// The complete replay through the production coordinator: the HUD fill sampled every 0.25 s.
    @Test func theProgressFillMovesThroughEveryStageAndHoldsAtEachGate() async throws {
        let script = try LaserReplayScript.complete(seed: 1)
        let session = try LaserReplayDriver.makeSession(script: script)
        try await session.start()
        let dots = GameplayHUDModel.checkpointPositions(count: 5)
        var samples: [(time: Double, fill: Double, gates: Int, phase: LaserRoundPhase)] = []
        var time = 0.0
        while time < script.duration, session.summary == nil {
            try await session.advance(to: time)
            if let state = session.state {
                let model = GameplayHUDModel(state: state, events: session.events, configuration: script.configuration,
                                             activityDuration: session.activityDuration, stageProgress: session.stageProgress)
                samples.append((time, model.fillEnd, model.vaultsOpened, state.phase))
            }
            time += 0.25
        }
        try await session.advance(to: script.duration)
        #expect(samples.count > 1000)
        // Never backwards, and never a jump: the most a 0.25 s step moves is one stage's segment over 60 s.
        let stageSpeed = (dots[0] - GameplayHUDModel.fillStart) / 60 * 0.25
        for (a, b) in zip(samples, samples.dropFirst()) where b.fill < GameplayHUDModel.fillFull {
            #expect(b.fill >= a.fill - 1e-9, "backwards at \(b.time)")
            #expect(b.fill - a.fill <= stageSpeed + 1e-6, "jump at \(b.time): \(a.fill) → \(b.fill)")
        }
        for stage in 0..<5 {
            let activity = samples.filter { $0.gates == stage && $0.phase == .activity }
            let start = try #require(activity.first), floor = stage == 0 ? GameplayHUDModel.fillStart : dots[stage - 1]
            // Starts on the last opened checkpoint, then fills its own segment all stage long.
            #expect(abs(start.fill - floor) < 0.005, "stage \(stage + 1) starts at \(start.fill)")
            for elapsed in [15.0, 30.0, 45.0] {
                let sample = try #require(activity.first { $0.time >= start.time + elapsed })
                let expected = floor + (dots[stage] - floor) * elapsed / 60
                #expect(abs(sample.fill - expected) < 0.004, "stage \(stage + 1) +\(elapsed) s: \(sample.fill) vs \(expected)")
            }
            let late = try #require(activity.last { $0.time <= start.time + 59 })
            #expect(late.fill > activity.first { $0.time >= start.time + 45 }!.fill, "still moving late in stage \(stage + 1)")
            // The gate: the fill holds on its checkpoint; the next stage only once the gate opened.
            let gate = samples.filter { $0.gates == stage && $0.phase == .vault }
            #expect(!gate.isEmpty && gate.allSatisfy { abs($0.fill - dots[stage]) < 1e-9 })
        }
        #expect(session.summary?.vaultsOpened == 5)
    }

    /// Staging compatibility (16 November 2026, Diamond Time is 20 active seconds): after the fifth
    /// gate the complete replay runs the CONFIGURED Diamond Time to its end, the HUD's fill stays on
    /// the diamond (no reset), and its countdown starts at the configured seconds and only falls.
    /// Nothing here repeats the duration: it comes from `LaserRoundConfiguration`.
    @Test func theFinalVaultLeadsIntoTheWholeConfiguredDiamondTimeWithoutResettingTheFill() async throws {
        let script = try LaserReplayScript.complete(seed: 1)
        let duration = script.configuration.diamondTimeDuration
        #expect(duration == LaserRoundConfiguration.defaultDiamondTimeDuration)
        let session = try LaserReplayDriver.makeSession(script: script)
        try await session.start()
        var samples: [(fill: Double, seconds: Int?, gates: Int, phase: LaserRoundPhase, banner: GameplayHUDModel.Banner)] = []
        var time = 0.0
        while time <= script.duration, session.summary == nil {
            try await session.advance(to: time)
            if let state = session.state {
                let model = GameplayHUDModel(state: state, events: session.events, configuration: script.configuration,
                    activityDuration: session.activityDuration, stageProgress: session.stageProgress,
                    enteringFinalVault: session.finalVaultEntry.map { !$0.isComplete } ?? false)
                samples.append((model.fillEnd, model.diamondSecondsLeft, model.vaultsOpened, state.phase, model.banner))
            }
            time += 0.25
        }
        try await session.advance(to: script.duration)
        let summary = try #require(session.summary, "the replay's duration covers the whole Diamond Time")
        #expect(summary.vaultsOpened == 5)
        let start = try #require(session.events.last { $0.kind == .phaseChanged(.diamondTime) }?.gameTime)
        // Diamond Time begins only after the final vault and lasts the configured seconds.
        #expect(start >= 300 && start + duration <= script.duration + 1e-9)
        #expect(abs(summary.gameDuration - (start + duration)) <= 0.3, "ended at \(summary.gameDuration)")
        let bonus = samples.filter { $0.phase == .diamondTime }
        #expect(!bonus.isEmpty && bonus.allSatisfy { $0.gates == 5 && $0.fill == GameplayHUDModel.fillFull })
        #expect(bonus.first?.banner == .retrieveDiamonds)
        let seconds = bonus.compactMap(\.seconds)
        #expect(seconds.first == Int(duration.rounded(.up)), "countdown starts at \(String(describing: seconds.first))")
        #expect(zip(seconds, seconds.dropFirst()).allSatisfy { $0 >= $1 } && (seconds.last ?? 99) <= 1)
        // From the last stage on, the fill never falls back (no reset at the final vault or after it).
        let fromFinalStage = samples.drop { $0.gates < 4 }
        #expect(zip(fromFinalStage, fromFinalStage.dropFirst()).allSatisfy { $1.fill >= $0.fill - 1e-9 })
    }

    /// A live round's director and game (co-op, no body evidence), with the DEBUG skip, pause hold,
    /// recovery hold and gate reset of the HUD's stage progress.
    @Test func liveStageProgressFollowsTheDirectorsTimelineAndOnlyGatesAdvanceStages() throws {
        let script = try LaserReplayScript.load()
        let input = script.input.configuration
        let configuration = try LaserFullReplayPlan.roundConfiguration()
        var director = try LaserLiveRoundDirector(calibrations: input.calibrations, layout: input.playerPlaneLayout,
                                                  configuration: configuration, seed: 3)
        let revisions = input.calibrations.mapValues(\.revision)
        let context = BodyInputContext(sessionGeneration: input.sessionGeneration,
            cameraGeometryRevision: script.input.cameraGeometryRevision, calibrationRevisions: revisions,
            cutovers: [:], isActive: true, wristContact: nil)
        var game = try LaserGame(configuration: configuration, context: context, historyCapacityPerPlayer: 120)
        game.configureBoards(try director.boards())
        var tracker = LaserStageProgress()
        var time = 0.0, openedVault: UUID?
        func run(until end: Double) throws {
            while time < end - 1e-9 {
                time += 0.05
                while let due = try director.nextDue(through: time, game: game) {
                    try game.advance(to: max(game.gameTime, due.time))
                    switch due.action {
                    case .heart: break
                    case .register(let e): try game.register(e)
                    case .normalDiamond(let s, let b): try game.spawnNormalDiamonds([s], beforeVaultAt: b)
                    case .openVault(let id, _): try game.openVault(id: id, at: game.gameTime); openedVault = id
                    }
                }
                try game.advance(to: max(time, game.gameTime))
                tracker.update(game: game, directorFraction: director.stageFraction(at: game.gameTime))
            }
        }
        func press() throws {
            let id = try #require(openedVault)
            try game.touchVaultBatch(id: id, contacts: PlayerID.allCases.flatMap { player in
                LaserVaultButton.allCases.map { .init(playerID: player, button: $0, calibrationRevision: revisions[player]!) } },
                generation: context.sessionGeneration, at: game.gameTime)
            openedVault = nil
            tracker.update(game: game, directorFraction: director.stageFraction(at: game.gameTime))
        }

        try run(until: 30)
        #expect(abs((tracker.value ?? -1) - 0.5) < 0.01, "half of stage 1 at 30 s")
        // A pause holds game time: nothing moves.
        let held = tracker.value
        tracker.update(game: game, directorFraction: director.stageFraction(at: game.gameTime))
        #expect(tracker.value == held)
        // A recovery that pushes the timeline back never moves the bar backwards.
        tracker.update(phase: .activity, ended: false, vaultOpened: false, gates: 0, activityProgress: game.activityProgress,
                       directorFraction: 0.45)
        #expect(tracker.value == held)
        try run(until: 61)
        // The stage's time is up: the fill sits on the gate and waits; no stage is unlocked by it.
        #expect(tracker.value == 1 && game.roundPhase == .vault && game.missionProgress == 0)
        try run(until: 63.5)   // within the gate's 5 s
        #expect(tracker.value == 1 && game.missionProgress == 0, "the gate stays shut until it is opened")
        try press()
        let stage2Start = game.gameTime
        #expect(game.missionProgress == 1 && tracker.value == 0, "the gate opened: stage 2 starts from its checkpoint")
        try run(until: stage2Start + 20)
        let stage2 = try #require(tracker.value)
        #expect(abs(stage2 - 20.0 / 60) < 0.01, "stage 2 one third through: \(stage2)")
        // DEBUG Skip to Next Gate: the bar jumps to the skipped stage's own timeline (5 s from its
        // gate), keeps filling, and reaches the gate without opening it.
        let skipped = director.debugSkipToVault(game: game)
        let skip = try #require(skipped)
        tracker.update(game: game, directorFraction: director.stageFraction(at: game.gameTime))
        let afterSkip = try #require(tracker.value)
        #expect(abs(afterSkip - (1 - LaserLiveRoundDirector.debugSkipLead / 60)) < 0.01)
        try run(until: skip.vaultAt - 2)
        #expect((tracker.value ?? 0) > afterSkip && (tracker.value ?? 1) < 1)
        try run(until: skip.vaultAt + 2)
        #expect(tracker.value == 1 && game.missionProgress == 1 && game.roundPhase == .vault)
        try press()
        #expect(game.missionProgress == 2 && tracker.value == 0)
    }

    @Test func theHUDMapsStageProgressOntoEachStagesOwnSegment() throws {
        let configuration = try LaserFullReplayPlan.roundConfiguration()
        let dots = GameplayHUDModel.checkpointPositions(count: 5)
        func model(gates: Int, progress: Double?, phase: LaserRoundPhase = .activity) -> GameplayHUDModel {
            var state = LaserGameState(sessionGeneration: UUID(), phase: phase, gameTime: 100, activityProgress: 100,
                                       teamHealth: 5, teamScore: 0, encounters: [])
            state.missionProgress = gates
            state.missionTarget = 5
            return GameplayHUDModel(state: state, events: [], configuration: configuration, activityDuration: 300,
                                    stageProgress: progress)
        }
        #expect(abs(model(gates: 0, progress: 0).fillEnd - GameplayHUDModel.fillStart) < 1e-9)
        #expect(abs(model(gates: 0, progress: 1).fillEnd - dots[0]) < 1e-9)
        #expect(abs(model(gates: 2, progress: 0.5).fillEnd - (dots[1] + dots[2]) / 2) < 1e-9)
        #expect(abs(model(gates: 4, progress: 1).fillEnd - dots[4]) < 1e-9)
        // Markers: done exactly when their gate has opened.
        #expect(model(gates: 2, progress: 0).markerStates == [.completed, .completed, .current, .upcoming, .upcoming])
        #expect(model(gates: 1, progress: 1).markerStates == [.completed, .current, .upcoming, .upcoming, .upcoming])
    }
}
