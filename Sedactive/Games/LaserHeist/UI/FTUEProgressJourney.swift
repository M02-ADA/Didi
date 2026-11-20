import Foundation
import Observation

/// Orange-fill presentation only. No gameplay percentage, clock, gate or completion authority.
@MainActor @Observable final class FTUEProgressJourney {
    static let initial = GameplayHUDModel.fillStart + 100.0 / 667
    static let checkpoint = 0.5
    static let duration = 0.65
    private(set) var fillEnd = initial
    private(set) var isActivePresentation = false
    private(set) var generation: UUID?
    @ObservationIgnored private var previous: Double?
    @ObservationIgnored private var origin = initial
    @ObservationIgnored private var target = initial
    @ObservationIgnored private var elapsed = 0.0

    static func endpoint(for stage: LeanTutorial.Stage) -> Double {
        switch stage {
        case .notStarted, .introduction: initial
        case .freeLean: 0.22
        case .collectiblesIntroduction: 0.25
        case .collection(.diamond): 0.27
        case .collection(.heart): 0.29
        case .heart(.introduction): 0.31
        case .heart(.hurt): 0.34
        case .heart(.warning): 0.36
        case .jumpDuckIntroduction: 0.38
        case .laserPractice(.jump): 0.40
        case .laserPractice(.duck): 0.46
        case .laserPractice: 0.40
        // A destination illustration. The Diamond sits inside the HUD's outer edge.
        case .progressExplanation(.diamond), .diamondCollectionIntroduction: GameplayHUDModel.diamondPosition
        case .progressExplanation, .vaultButtonIntroduction, .vaultButtonHandoff, .completed: checkpoint
        }
    }
    func hasReachedExplanationEndpoint(_ phase: ProgressTutorialPhase) -> Bool {
        isActivePresentation && fillEnd == Self.endpoint(for: .progressExplanation(phase))
    }

    func reset(generation: UUID?) {
        self.generation = generation; isActivePresentation = false; fillEnd = Self.initial
        origin = Self.initial; target = Self.initial; previous = nil; elapsed = 0
    }
    /// Driven by the EXISTING scene callback. Inactivity never contributes catch-up time.
    func update(stage: LeanTutorial.Stage, generation: UUID, at now: Double, active: Bool) {
        guard self.generation == generation, now.isFinite else { return }
        isActivePresentation = active
        guard active else { previous = nil; return }
        let destination = Self.endpoint(for: stage)
        if destination != target { origin = fillEnd; target = destination; elapsed = 0 }
        defer { previous = now }
        guard let previous, now > previous, now - previous <= 0.25 else { return }
        elapsed = min(Self.duration, elapsed + now - previous)
        let u = elapsed / Self.duration
        let next = elapsed == Self.duration ? target : origin + (target - origin) * u * u * (3 - 2 * u)
        if fillEnd != next { fillEnd = next }
    }
}
