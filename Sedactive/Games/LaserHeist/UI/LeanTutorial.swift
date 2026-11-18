import Foundation
import Observation
import CoreGraphics

/// Lean + Heart presentation sequence. Each roster player must show neutral, then intentional
/// commanded motion AND actual displacement on two distinct fresh source frames per direction.
/// There is no new lean threshold, dwell timer, steering controller, or gameplay success verdict.
@MainActor @Observable
final class LeanTutorial {
    enum Stage: Equatable { case notStarted, introduction, practiceLeft, practiceRight, heart(HeartTutorialPhase), completed }
    static let completionKey = "laserHeist.ftue.lean.v1.completed"
    static let heartCompletionKey = "laserHeist.ftue.heart.v1.completed"
    private(set) var stage: Stage = .notStarted
    private(set) var generation: UUID?
    private(set) var roster: [PlayerID] = []
    private(set) var demonstrated: Set<PlayerID> = []
    private(set) var isSuspended = false
    private(set) var headTopFraction: CGFloat?
    private(set) var healthHUDFrame: CGRect?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var replayForVisit = false
    @ObservationIgnored private var introVisible = false
    @ObservationIgnored private var visibleHeart: HeartTutorialPhase?
    @ObservationIgnored private var visiblePractice: Stage?
    @ObservationIgnored private var activation = Double.infinity
    @ObservationIgnored private var lastSource: AvatarSourceFrame?
    @ObservationIgnored private var context: BodyInputContext?
    private struct Attempt { var armed = false; var x: Float?; var movingFrames = 0 }
    @ObservationIgnored private var attempts: [PlayerID: Attempt] = [:]
    @ObservationIgnored private var suppressed = false
    var hasCompletedLean: Bool { defaults.bool(forKey: Self.completionKey) }
    var isCompleted: Bool { hasCompletedLean && defaults.bool(forKey: Self.heartCompletionKey) }
    var heartPhase: HeartTutorialPhase? { if case .heart(let phase) = stage { return phase }; return nil }
    var isActive: Bool { [.introduction, .practiceLeft, .practiceRight].contains(stage) || heartPhase != nil }
    var isPractising: Bool { stage == .practiceLeft || stage == .practiceRight }
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func setHeadTop(_ value: CGFloat, generation: UUID) {
        guard self.generation == generation, value.isFinite, value > 0, value < 1 else { return }
        if headTopFraction != value { headTopFraction = value }
    }
    /// Explicit replay overrides completion for this generation without clearing its saved record.
    func prepare(generation: UUID, roster: [PlayerID] = PlayerID.allCases, replayRequested: Bool = false) {
        self.generation = generation; self.roster = roster; replayForVisit = replayRequested
        headTopFraction = nil; healthHUDFrame = nil; isSuspended = false; introVisible = false; visibleHeart = nil
        clearPractice(); context = nil; lastSource = nil
        stage = isCompleted && !replayForVisit ? .completed : .notStarted
    }
    func beginIfEligible(generation: UUID, eligible: Bool) {
        guard self.generation == generation, eligible, !roster.isEmpty, stage == .notStarted, (!isCompleted || replayForVisit) else { return }
        stage = hasCompletedLean && !replayForVisit ? .heart(.introduction) : .introduction
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
        isSuspended = value; introVisible = false; visibleHeart = nil; clearPractice()
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
        else {
            defaults.set(true, forKey: Self.completionKey)
            stage = .heart(.introduction); clearPractice()
        }
    }
    func setHealthHUDFrame(_ frame: CGRect, generation: UUID) {
        guard self.generation == generation, frame.width > 0, frame.height > 0,
              frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else { return }
        if healthHUDFrame != frame { healthHUDFrame = frame }
    }
    func heartVisible(_ phase: HeartTutorialPhase, visible: Bool, generation: UUID) {
        guard self.generation == generation, heartPhase == phase else { return }
        visibleHeart = visible && !isSuspended ? phase : nil
    }
    /// Called only after an authorized encounter receipt and the existing ZAPPED completion.
    func finishTrainingEncounter(_ training: HeartTrainingEncounter, generation: UUID) {
        guard self.generation == generation, training.context.sessionGeneration == generation,
              training.feedbackFinished, !training.invalidated, training.damage != nil,
              training.roster == Set(roster), heartPhase == .hurt, !isSuspended else { return }
        stage = .heart(.warning); visibleHeart = nil
    }
    func finishHeart(_ phase: HeartTutorialPhase, generation: UUID) {
        guard phase != .hurt, self.generation == generation, heartPhase == phase, visibleHeart == phase, !isSuspended else { return }
        visibleHeart = nil
        if let next = phase.next { stage = .heart(next) }
        else {
            defaults.set(true, forKey: Self.heartCompletionKey)
            replayForVisit = false; stage = .completed
        }
    }
    func abandon() {
        replayForVisit = false; visibleHeart = nil; healthHUDFrame = nil
        generation = nil; stage = .notStarted; isSuspended = false; introVisible = false
        clearPractice(); context = nil; lastSource = nil
    }
    private func clearPractice() {
        demonstrated = []; attempts = [:]; visiblePractice = nil; activation = .infinity; suppressed = false
    }
    #if DEBUG
    func resetForNextPlay() { defaults.removeObject(forKey: Self.completionKey); defaults.removeObject(forKey: Self.heartCompletionKey); abandon() }
    /// Static screenshot route ONLY; never completes/persists a tutorial or reaches live input.
    func showPracticeForLayout(_ requested: Stage, generation: UUID) {
        guard self.generation == generation, requested == .practiceLeft || requested == .practiceRight else { return }
        stage = requested; clearPractice()
    }
    #endif
}
