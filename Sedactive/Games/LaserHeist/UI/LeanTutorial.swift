import Foundation
import Observation

/// Lean-only first-play presentation. Continue acknowledges the instructions; it does not
/// certify a physical movement, calibration, identity, or gameplay readiness.
@MainActor @Observable
final class LeanTutorial {
    enum Stage: Equatable { case notStarted, introduction, practiceLeft, practiceRight, completed }
    static let completionKey = "laserHeist.ftue.lean.v1.completed"
    private(set) var stage: Stage = .notStarted
    private(set) var generation: UUID?
    @ObservationIgnored private let defaults: UserDefaults
    var isCompleted: Bool { defaults.bool(forKey: Self.completionKey) }
    var isActive: Bool { [.introduction, .practiceLeft, .practiceRight].contains(stage) }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// A new setup always discards an unfinished visit. Completion survives Retry and relaunch.
    func prepare(generation: UUID) {
        self.generation = generation
        stage = isCompleted ? .completed : .notStarted
    }

    func beginIfEligible(generation: UUID, eligible: Bool) {
        guard self.generation == generation, eligible, stage == .notStarted, !isCompleted else { return }
        stage = .introduction
    }

    func advance(generation: UUID) {
        guard self.generation == generation else { return }
        switch stage {
        case .introduction: stage = .practiceLeft
        case .practiceLeft: stage = .practiceRight
        case .practiceRight: finish()
        default: break
        }
    }

    func skip(generation: UUID) {
        guard self.generation == generation, isActive else { return }
        finish()
    }

    func abandon() { generation = nil; stage = .notStarted }
    private func finish() {
        defaults.set(true, forKey: Self.completionKey)
        stage = .completed
    }

    #if DEBUG
    /// Called only from the pre-game selection screen, never during a round.
    func resetForNextPlay() { defaults.removeObject(forKey: Self.completionKey); abandon() }
    #endif
}
