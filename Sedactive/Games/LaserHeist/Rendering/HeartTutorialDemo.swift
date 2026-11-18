import RealityKit

/// Presentation of the session-authorized training round. No collision decisions or health here.
@MainActor final class HeartTutorialDemo {
    private(set) var beam: LaserHazard?
    private(set) var receipt: HeartTrainingDamage?
    private var serial: Int?

    func update(scene: LaserScene, training: HeartTrainingEncounter?, callouts: LaserTeamCalloutModel,
                suspended: Bool) {
        guard let training, !training.invalidated else { stop(); return }
        if training.feedbackFinished { beam?.root.removeFromParent(); beam = nil; return }
        if beam == nil { beam = scene.makeHeartTrainingHazard() }
        let fraction = Float(training.elapsed / HeartTrainingEncounter.crossingTime)
        beam?.setDepth(scene.layout.laserSpawnZ + (scene.mapping.interactionPlaneZ - scene.layout.laserSpawnZ) * fraction)
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
    func stop() { beam?.root.removeFromParent(); beam = nil; receipt = nil; serial = nil }
}
