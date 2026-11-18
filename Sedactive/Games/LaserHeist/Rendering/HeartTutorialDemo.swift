import RealityKit

/// Presentation of the session-authorized training round. No collision decisions or health here.
@MainActor final class HeartTutorialDemo {
    private(set) var beam: LaserHazard?
    private(set) var receipt: HeartTrainingDamage?
    private var serial: Int?
    private weak var travelScene: LaserScene?
    private var travelOrigin: Float?

    func update(scene: LaserScene, training: HeartTrainingEncounter?, callouts: LaserTeamCalloutModel,
                suspended: Bool) {
        guard let training, !training.invalidated else { stop(); return }
        if training.feedbackFinished { beam?.root.removeFromParent(); beam = nil; return }
        if beam == nil {
            travelScene = scene
            travelOrigin = scene.travelOffset
            beam = scene.makeHeartTrainingHazard()
        }
        // Same forward illusion as ordinary play: fixed camera/mascot Z, streamed corridor,
        // and a world-fixed obstacle moving with it. No independent beam speed or clock.
        scene.setTravelDistance((travelOrigin ?? 0) + scene.layout.travelSpeed * Float(training.elapsed))
        beam?.setDepth(GameplayScenePresenter.obstacleDepth(in: scene,
            crossingTime: HeartTrainingEncounter.crossingTime, at: training.elapsed))
        beam?.setState(training.damage == nil ? .active : .hit)
        callouts.setTutorialSuspended(suspended)
        guard !suspended, let damage = training.damage, receipt == nil else { return }
        receipt = damage
        // Explicit SCRIPTED TRAINING damage receipt; never a forged normal target judgement.
        for player in damage.players { scene.presentOutcome(.hit, for: player, band: beam!.band) }
        scene.presentTeamEffect(healthDelta: -1, scoreDelta: 0)
        AudioService.shared.play(.laserHit)
        callouts.showTrainingDamage(damage)
        serial = callouts.shown?.serial
    }
    func feedbackFinished(_ callouts: LaserTeamCalloutModel) -> HeartTrainingDamage? {
        guard let serial, callouts.finishedSerial == serial else { return nil }
        return receipt
    }
    func stop() {
        beam?.root.removeFromParent(); beam = nil; receipt = nil; serial = nil
        // Return ownership while the warning overlay is blurred; no travel leaks into the
        // ordinary presenter's fresh-round origin or a replacement tutorial scene.
        if let travelOrigin { travelScene?.setTravelDistance(travelOrigin) }
        travelOrigin = nil; travelScene = nil
    }
}
