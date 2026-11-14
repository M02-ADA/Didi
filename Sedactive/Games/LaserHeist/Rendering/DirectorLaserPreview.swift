//
//  DirectorLaserPreview.swift
//  Sedactive
//

#if DEBUG
import Foundation
import RealityKit
import SwiftUI

/// Developer-only check of `GameplayScenePresenter` against real
/// `LaserWaveDirector` output, without a camera or the replay session.
///
/// The schedule is genuine: the director plans the first minute of the
/// five-minute script for the replay fixture's two calibrations, so P1 and P2
/// get different bands. P2 crosses 0.8 s after P1, and a 6 s warning lead
/// with the director's 5 s minimum spacing makes each player's consecutive
/// lasers overlap on screen. Only the outcomes are scripted preview data:
/// each target is judged at its finalization time (CLEAR, HIT or
/// UNAVAILABLE in turn), and one attempt is withdrawn mid-approach. The
/// preview's time runs on RealityKit frame time and decides nothing; the
/// round loops with a fresh generation.
///
/// Launch with `-directorLaserPreview` (combine with `-syntheticCutouts both`
/// to check layering against live cutouts).
@MainActor
final class DirectorLaserPreview {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-directorLaserPreview") }

    private var subscription: EventSubscription?
    private var presenter: GameplayScenePresenter?
    private var configuration: LaserRoundConfiguration?
    private var schedule: [LaserEncounter] = []
    private var time = 0.0
    private var generation = UUID()
    private var events: [GameEvent] = []
    private var judgements: [LaserTargetKey: Judgement] = [:]
    private var committed: Set<UUID> = []
    private var withdrawn: Set<UUID> = []
    private(set) var startupError: String?

    func start(on content: RealityViewCameraContent, scene: LaserScene) {
        guard subscription == nil else { return }
        do {
            let fixture = try LaserReplayScript.load().input.configuration
            let configuration = try Self.configuration()
            let beats = Array(LaserWaveBeat.fiveMinuteScript().prefix(8))
            schedule = try LaserWaveDirector().schedule(script: beats, calibrations: fixture.calibrations,
                                                        layout: fixture.playerPlaneLayout,
                                                        configuration: configuration).encounters
            self.configuration = configuration
            presenter = GameplayScenePresenter(
                scene: scene, configuration: configuration, encounters: schedule,
                showsDebugMarkers: !ProcessInfo.processInfo.arguments.contains("-hideDebugOverlay"))
        } catch {
            startupError = String(describing: error)
            return
        }
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.advance(by: event.deltaTime)
        }
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
        presenter?.stop()
        presenter = nil
    }

    /// Both players use the conservative candidate, with a 6 s warning lead;
    /// P2 crosses 0.8 s after P1.
    private static func configuration() throws -> LaserRoundConfiguration {
        func profile(offset: Double) -> LaserPlayerDifficulty {
            let base = LaserPlayerDifficulty.conservativeCandidate
            return LaserPlayerDifficulty(
                requestedCrownDropShare: base.requestedCrownDropShare, requestedSoleLiftShare: base.requestedSoleLiftShare,
                beamThicknessShare: base.beamThicknessShare, maximumCrownDropShare: base.maximumCrownDropShare,
                maximumSoleLiftShare: base.maximumSoleLiftShare, clearanceReserveShare: base.clearanceReserveShare,
                maximumJumpsInWindow: base.maximumJumpsInWindow, jumpWindow: base.jumpWindow,
                minimumJumpSpacing: base.minimumJumpSpacing, maximumConsecutiveJumps: base.maximumConsecutiveJumps,
                minimumTargetSpacing: base.minimumTargetSpacing, warningLead: 6, cueLead: base.cueLead,
                crossingOffset: offset)
        }
        return try LaserRoundConfiguration(
            evidenceTiming: LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25, deliveryAllowance: 0.1),
            clearanceMargin: 0.005, diamondPoints: nil,
            scheduling: LaserSchedulingConfiguration(players: [.player1: profile(offset: 0), .player2: profile(offset: 0.8)],
                                                     searchStep: 0.25, maximumSearchSteps: 2000))
    }

    private func advance(by delta: TimeInterval) {
        guard let configuration, let presenter else { return }
        time += delta
        let lastEnd = schedule.flatMap(\.targets).map {
            configuration.evidenceTiming.finalizationTime(crossing: $0.crossingTime)
        }.max() ?? 0
        if time > lastEnd + 2 { restart() }
        for (index, encounter) in schedule.enumerated() {
            // One attempt is withdrawn 1.5 s before its first crossing.
            let firstCrossing = encounter.targets.map(\.crossingTime).min() ?? 0
            if index == 4, time >= firstCrossing - 1.5, withdrawn.insert(encounter.attemptID).inserted {
                emit(.attemptWithdrawn(encounterID: encounter.id, attemptID: encounter.attemptID), at: firstCrossing - 1.5)
            }
            guard !withdrawn.contains(encounter.attemptID) else { continue }
            for target in encounter.targets {
                let key = LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: target.playerID)
                let due = configuration.evidenceTiming.finalizationTime(crossing: target.crossingTime)
                guard time >= due, judgements[key] == nil else { continue }
                let judgement = Self.outcome(index: index, player: target.playerID)
                judgements[key] = judgement
                emit(.targetJudged(encounterID: encounter.id, playerID: target.playerID, judgement: judgement), at: due)
            }
            let pair = encounter.targets.compactMap {
                judgements[LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: $0.playerID)]
            }
            if pair.count == encounter.targets.count, committed.insert(encounter.id).inserted {
                let hits = pair.filter { if case .hit = $0 { true } else { false } }.count
                let clears = pair.filter { $0 == .clear }.count
                emit(.teamEffectsCommitted(encounterID: encounter.id, healthDelta: -hits, scoreDelta: 100 * clears), at: time)
            }
        }
        presenter.apply(state: state(), events: events, snapshot: nil)
    }

    /// CLEAR for both, then HIT for P1, then UNAVAILABLE for P2, in turn.
    private static func outcome(index: Int, player: PlayerID) -> Judgement {
        switch (index % 3, player) {
        case (1, .player1): .hit(.insufficientClearance)
        case (2, .player2): .unavailable(.noSample)
        default: .clear
        }
    }

    private func state() -> LaserGameState {
        let encounters = schedule.map { encounter in
            var verdicts: [PlayerID: Judgement] = [:]
            for target in encounter.targets {
                let key = LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: target.playerID)
                verdicts[target.playerID] = judgements[key] ?? .pending(.awaitingFinalization)
            }
            return LaserEncounterState(encounter: encounter, judgements: verdicts, effectsCommitted: committed.contains(encounter.id))
        }
        return LaserGameState(sessionGeneration: generation, phase: .activity, gameTime: time, activityProgress: 0,
                              teamHealth: 5, teamScore: 0, encounters: encounters)
    }

    private func emit(_ kind: LaserGameEventKind, at gameTime: Double) {
        events.append(GameEvent(id: UUID(), sessionGeneration: generation, sequence: UInt64(events.count + 1),
                                gameTime: gameTime, kind: kind))
    }

    private func restart() {
        time = 0
        generation = UUID()
        events = []
        judgements = [:]
        committed = []
        withdrawn = []
    }
}
#endif
