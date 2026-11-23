import Foundation
import RealityKit

/// Adapter from committed FTUE verdicts to the EXISTING cue, gate and team callout renderers.
/// No health, score, movement inference, timers or retry decisions live here.
@MainActor final class FTUEPracticePresentation {
    private var beam: LaserHazard?
    private var attempt: UUID?
    private var feedbackSerial: Int?
    private weak var scene: LaserScene?
    private var originalTravel: Float?
    private var attemptTravel: Float = 0
    private var originalVariant: TimingIndicatorVariant?
    private var presented = false

    func update(scene: LaserScene, practice: FTUELaserPractice, callouts: LaserTeamCalloutModel, suspended: Bool) {
        if originalTravel == nil { originalTravel = scene.travelOffset; originalVariant = scene.timingVariant; self.scene = scene }
        if attempt != practice.attemptID {
            beam?.root.removeFromParent(); scene.clearLaserFeedback(); callouts.clear()
            attempt = practice.attemptID; feedbackSerial = nil; presented = false; attemptTravel = scene.travelOffset
            beam = scene.makeHeartTrainingHazard()
            beam?.root.name = "ftue.practice.\(practice.move.rawValue).\(practice.attemptID)"
            let target = practice.encounter.targets[0]
            let h = LaserLiveRoundGeometryV1.standingHeight(practice.input.calibrations[target.playerID]!, layout: practice.input.playerPlaneLayout)
            let scale = scene.robotAvatars?.laserBandScale(for: target.playerID, mapping: scene.mapping)
                ?? Float(RobotAvatarLayer.standingHeight) / scene.mapping.metersPerGameUnit / Float(h)
            beam?.setBand(lowerEdge: Float(target.beam.lowerY) * scale, upperEdge: Float(target.beam.upperY) * scale)
            scene.selectTimingVariant(.converging)
        }
        scene.setTravelDistance(attemptTravel + scene.layout.travelSpeed * Float(practice.elapsed))
        beam?.setDepth(GameplayScenePresenter.obstacleDepth(in: scene, crossingTime: practice.crossing, at: practice.elapsed))
        beam?.setState(practice.outcome == .hit ? .hit : .active)
        scene.setTimingPaused(suspended)
        scene.setTimingPresentation(LaserTimingPresentation.make(state: practice.state, configuration: practice.configuration, paused: suspended))
        callouts.setTutorialSuspended(suspended)
        guard !suspended, !presented, practice.requiresFailureFeedback || practice.outcome == .clear else { return }
        presented = true
        for (player, verdict) in practice.verdicts {
            let outcome: LaserFeedback.Outcome
            switch verdict { case .clear: outcome = .clear; case .hit: outcome = .hit; default: outcome = .unavailable }
            scene.presentOutcome(outcome, for: player, band: beam!.band)
        }
        AudioService.shared.play(practice.outcome == .clear ? .laserClear : .laserHit)
        // Legitimate committed practice outcome; intentionally NO normal damage/score event.
        callouts.show(practice.outcome == .clear ? .perfect : .zapped, compact: false)
        feedbackSerial = callouts.shown?.serial
    }
    func finishedAttempt(_ model: LaserTeamCalloutModel) -> UUID? {
        guard let feedbackSerial, model.finishedSerial == feedbackSerial else { return nil }
        return attempt
    }
    func stop(callouts: LaserTeamCalloutModel) {
        guard originalTravel != nil else { return }
        beam?.root.removeFromParent(); beam = nil; attempt = nil; feedbackSerial = nil; presented = false
        scene?.clearLaserFeedback(); scene?.setTimingPaused(false)
        if let originalVariant { scene?.selectTimingVariant(originalVariant) }
        if let originalTravel { scene?.setTravelDistance(originalTravel) }
        self.originalTravel = nil; originalVariant = nil; scene = nil; callouts.clear()
    }
}
