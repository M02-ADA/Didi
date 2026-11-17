import Foundation
import Observation
import CoreGraphics

/// Lean-only presentation progress. Each roster player must show neutral, then intentional
/// commanded motion AND actual displacement on two distinct fresh source frames per direction.
/// There is no new lean threshold, dwell timer, steering controller, or gameplay success verdict.
@MainActor @Observable
final class LeanTutorial {
    enum Stage: Equatable { case notStarted, introduction, practiceLeft, practiceRight, completed }
    static let completionKey = "laserHeist.ftue.lean.v1.completed"
    private(set) var stage: Stage = .notStarted
    private(set) var generation: UUID?
    private(set) var roster: [PlayerID] = []
    private(set) var demonstrated: Set<PlayerID> = []
    private(set) var isSuspended = false
    private(set) var headTopFraction: CGFloat?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var introVisible = false
    @ObservationIgnored private var visiblePractice: Stage?
    @ObservationIgnored private var activation = Double.infinity
    @ObservationIgnored private var lastSource: AvatarSourceFrame?
    @ObservationIgnored private var context: BodyInputContext?
    private struct Attempt { var armed = false; var x: Float?; var movingFrames = 0 }
    @ObservationIgnored private var attempts: [PlayerID: Attempt] = [:]
    @ObservationIgnored private var suppressed = false
    var isCompleted: Bool { defaults.bool(forKey: Self.completionKey) }
    var isActive: Bool { [.introduction, .practiceLeft, .practiceRight].contains(stage) }
    var isPractising: Bool { stage == .practiceLeft || stage == .practiceRight }
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func setHeadTop(_ value: CGFloat, generation: UUID) {
        guard self.generation == generation, value.isFinite, value > 0, value < 1 else { return }
        if headTopFraction != value { headTopFraction = value }
    }
    func prepare(generation: UUID, roster: [PlayerID] = PlayerID.allCases) {
        self.generation = generation; self.roster = roster
        headTopFraction = nil; isSuspended = false; introVisible = false
        clearPractice(); context = nil; lastSource = nil
        stage = isCompleted ? .completed : .notStarted
    }
    func beginIfEligible(generation: UUID, eligible: Bool) {
        guard self.generation == generation, eligible, !roster.isEmpty, stage == .notStarted, !isCompleted else { return }
        stage = .introduction
    }
    func introductionVisible(_ visible: Bool, generation: UUID) {
        guard self.generation == generation, stage == .introduction else { return }
        introVisible = visible
    }
    #if DEBUG
    var freezesIntroductionForLayout = false
    #endif
    func finishIntroduction(generation: UUID) {
        #if DEBUG
        guard !freezesIntroductionForLayout else { return }
        #endif
        guard self.generation == generation, stage == .introduction, introVisible, !isSuspended else { return }
        introVisible = false; stage = .practiceLeft; clearPractice()
    }
    /// Called when the projected practice artwork appears, not while a guide is loading.
    func practiceVisible(_ stage: Stage, generation: UUID, at time: Double) {
        guard self.generation == generation, self.stage == stage, isPractising, !isSuspended else { return }
        visiblePractice = stage; activation = time; attempts = [:]
    }
    func setSuspended(_ value: Bool, generation: UUID) {
        guard self.generation == generation, isActive, isSuspended != value else { return }
        isSuspended = value; introVisible = false; clearPractice()
    }
    func shouldRead(_ source: AvatarSourceFrame) -> Bool {
        isPractising && !isSuspended && visiblePractice == stage && source != lastSource
    }
    /// Repeated render ticks cannot count a held packet twice. Original frame AND capture time
    /// must advance. Identity/context cutovers discard this direction's whole roster proof.
    func observe(_ observation: LeanMovementObservation?, generation: UUID, at time: Double) {
        guard self.generation == generation, isPractising, !isSuspended, visiblePractice == stage else { return }
        guard let observation else {
            if !suppressed { attempts = [:]; suppressed = true }
            return
        }
        let source = observation.source
        guard source.context.generation == generation, observation.context.sessionGeneration == generation,
              source.capturedAt > activation, source.capturedAt <= time,
              time - source.capturedAt <= LiveAvatarPresenter.maximumPoseAge else { return }
        if let old = context, old != observation.context {
            clearPractice(); visiblePractice = stage; activation = time
            context = observation.context; lastSource = nil
            return // require a NEW post-cutover neutral frame
        }
        context = observation.context
        if let lastSource, source.context == lastSource.context,
           source.frameID <= lastSource.frameID || source.capturedAt <= lastSource.capturedAt { return }
        lastSource = source; suppressed = false
        let sign: Float = stage == .practiceLeft ? -1 : 1
        for player in roster where !demonstrated.contains(player) {
            guard let value = observation.players[player] else { attempts[player] = nil; continue }
            var attempt = attempts[player] ?? Attempt()
            if value.command == 0, value.velocity == 0 {
                attempt.armed = true; attempt.x = value.x; attempt.movingFrames = 0
            } else if attempt.armed, let x = attempt.x,
                      value.command * sign > 0, value.velocity * sign > 0, (value.x - x) * sign > 0 {
                attempt.movingFrames += 1; attempt.x = value.x
                if attempt.movingFrames >= 2 { demonstrated.insert(player) }
            } else { attempt = Attempt() }
            attempts[player] = attempt
        }
        guard Set(roster).isSubset(of: demonstrated) else { return }
        if stage == .practiceLeft { stage = .practiceRight; clearPractice() }
        else { stage = .completed; defaults.set(true, forKey: Self.completionKey); clearPractice() }
    }
    func abandon() {
        generation = nil; stage = .notStarted; isSuspended = false; introVisible = false
        clearPractice(); context = nil; lastSource = nil
    }
    private func clearPractice() {
        demonstrated = []; attempts = [:]; visiblePractice = nil; activation = .infinity; suppressed = false
    }
    #if DEBUG
    func resetForNextPlay() { defaults.removeObject(forKey: Self.completionKey); abandon() }
    /// Static screenshot route ONLY; never completes/persists a tutorial or reaches live input.
    func showPracticeForLayout(_ requested: Stage, generation: UUID) {
        guard self.generation == generation, requested == .practiceLeft || requested == .practiceRight else { return }
        stage = requested; clearPractice()
    }
    #endif
}
