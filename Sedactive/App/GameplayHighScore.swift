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

    static func isEligible(_ outcome: LaserRoundOutcome) -> Bool {
        switch outcome {
        case .completed, .healthDepleted, .vaultFailed: true
        case .aborted, .technicalInterruption: false
        }
    }

    func record(_ summary: RoundSummary, isNormalGameplay: Bool) {
        guard isNormalGameplay,
              Self.isEligible(summary.outcome),
              records[summary.sessionGeneration] == nil else { return }

        let isNew = summary.teamScore > highScore
        if isNew {
            highScore = summary.teamScore
            defaults.set(highScore, forKey: Self.key)
        }
        records[summary.sessionGeneration] = Record(highScore: highScore, isNew: isNew)
    }
}
