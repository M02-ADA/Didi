import Foundation

/// Cosmetic travel while the pre-round hold keeps ordinary encounters and GameClock stopped.
/// Uses the existing streamed corridor; never moves the camera, avatars or judged geometry.
@MainActor final class LeanTutorialTravel {
    private weak var scene: LaserScene?
    private var origin: Float?
    private var generation: UUID?
    private var retiredGeneration: UUID?
    private var previous: Double?

    func update(scene: LaserScene, tutorial: LeanTutorial, generation: UUID, at now: Double, eligible: Bool) {
        guard tutorial.generation == generation, generation != retiredGeneration, tutorial.isActive else {
            previous = nil; return
        }
        if self.generation != generation || self.scene !== scene {
            self.generation = generation; self.scene = scene; origin = nil; previous = nil
        }
        // Hand off the CURRENT offset to Heart. Do not restore or keep writing during later modules.
        guard tutorial.isPractising else { previous = nil; return }
        if origin == nil { origin = scene.travelOffset }
        guard eligible, !tutorial.isSuspended, now.isFinite else { previous = nil; return }
        defer { previous = now }
        guard let previous, now > previous, now - previous <= 0.25 else { return }
        scene.setTravelDistance(scene.travelOffset + scene.layout.travelSpeed * Float(now - previous))
    }
    func suspend() { previous = nil }
    /// Explicit view teardown only, after later tutorial presenters have released their offsets.
    func stop() {
        if let origin { scene?.setTravelDistance(origin) }
        retiredGeneration = generation
        scene = nil; origin = nil; generation = nil; previous = nil
    }
}
