import Foundation
import Observation

/// App-local records for completed live rounds. Results reads the decision
/// for its generation, so saving the new maximum cannot erase the record badge.
@MainActor @Observable
final class GameplayHighScore {
    struct Record: Equatable {
        let highScore: Int
        let isNew: Bool
    }

    static let key = "LaserHeist.highScore"
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var highScore: Int
    private var records: [UUID: Record] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        highScore = defaults.integer(forKey: Self.key)
    }

    func record(for generation: UUID) -> Record? {
        records[generation]
    }

    func record(_ summary: RoundSummary, isNormalGameplay: Bool) {
        guard isNormalGameplay,
              summary.outcome == .completed || summary.outcome == .healthDepleted,
              records[summary.sessionGeneration] == nil else { return }

        let isNew = summary.teamScore > highScore
        if isNew {
            highScore = summary.teamScore
            defaults.set(highScore, forKey: Self.key)
        }
        records[summary.sessionGeneration] = Record(highScore: highScore, isNew: isNew)
    }
}
