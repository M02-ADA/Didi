import Foundation
import Observation
import CoreGraphics

/// Tutorial flow for the current setup generation.
@MainActor @Observable
final class LeanTutorial {
    enum Stage: Equatable { case notStarted, introduction, freeLean, collectiblesIntroduction, collection(FTUECollectible), heart(HeartTutorialPhase), jumpDuckIntroduction, laserPractice(LaserMove), progressExplanation(ProgressTutorialPhase), vaultButtonIntroduction, vaultPractice, diamondCollectionIntroduction, diamondTimeDemo, completed }
    enum LeanExit: Equatable { case verifiedMovement, explorationTimeout }
    private(set) var leanExit: LeanExit?
    @ObservationIgnored private var practiceTime = 0.0
    @ObservationIgnored private var previousPracticeTick: Double?
    #if DEBUG
    @ObservationIgnored private var practiceBlockedSince: Double?
    @ObservationIgnored private var loggedPracticeBlock = false
    #endif
    static let completionKey = "laserHeist.ftue.lean.v1.completed"
    static let jumpDuckCompletionKey = "laserHeist.ftue.jumpDuck.v1.completed"
    static let progressCompletionKey = "laserHeist.ftue.progress.v1.completed"
    static let heartCompletionKey = "laserHeist.ftue.heart.v1.completed"
    let progressJourney = FTUEProgressJourney()
    private(set) var stage: Stage = .notStarted
    private(set) var generation: UUID?
    private(set) var roster: [PlayerID] = []
    private(set) var demonstrated: Set<PlayerID> = []
    private(set) var isSuspended = false
    private(set) var headTopFraction: CGFloat?
    private(set) var progressHUDFrame: CGRect?
    @ObservationIgnored private var visibleProgress: ProgressTutorialPhase?
    private(set) var healthHUDFrame: CGRect?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var replayForVisit = false
    @ObservationIgnored private var introVisible = false
    @ObservationIgnored private var visibleHeart: HeartTutorialPhase?
    @ObservationIgnored private var visiblePractice: Stage?
    @ObservationIgnored private var activation = Double.infinity
    @ObservationIgnored private var lastSource: AvatarSourceFrame?
    @ObservationIgnored private var context: BodyInputContext?
    private struct Attempt { var armed = false; var x: Float?; var movingFrames = 0; var direction: Float = 0 }
    @ObservationIgnored private var attempts: [PlayerID: Attempt] = [:]
    @ObservationIgnored private var suppressed = false
    var hasCompletedLean: Bool { defaults.bool(forKey: Self.completionKey) }
    var isCompleted: Bool { hasCompletedLean && defaults.bool(forKey: Self.heartCompletionKey) && defaults.bool(forKey: Self.jumpDuckCompletionKey) && defaults.bool(forKey: Self.progressCompletionKey) }
    var progressPhase: ProgressTutorialPhase? { if case .progressExplanation(let phase) = stage { return phase }; return nil }
    var heartPhase: HeartTutorialPhase? { if case .heart(let phase) = stage { return phase }; return nil }
    var isActive: Bool { [.introduction, .freeLean, .collectiblesIntroduction, .vaultButtonIntroduction, .vaultPractice, .diamondCollectionIntroduction, .diamondTimeDemo].contains(stage) || collection != nil || heartPhase != nil || stage == .jumpDuckIntroduction || practiceMove != nil || progressPhase != nil }
    var practiceMove: LaserMove? { if case .laserPractice(let move) = stage { return move }; return nil }
    var isPractising: Bool { stage == .freeLean }
    var collection: FTUECollectible? { if case .collection(let kind) = stage { return kind }; return nil }
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func setHeadTop(_ value: CGFloat, generation: UUID) {
        guard self.generation == generation, value.isFinite, value > 0, value < 1 else { return }
        if headTopFraction != value { headTopFraction = value }
    }
    /// Explicit replay overrides completion for this generation without clearing its saved record.
    func prepare(generation: UUID, roster: [PlayerID] = PlayerID.allCases, replayRequested: Bool = false) {
        progressJourney.reset(generation: generation)
        self.generation = generation; self.roster = roster; replayForVisit = replayRequested
        headTopFraction = nil; healthHUDFrame = nil; progressHUDFrame = nil; visibleProgress = nil; isSuspended = false; introVisible = false; visibleHeart = nil
        clearPractice(); context = nil; lastSource = nil; practiceTime = 0; leanExit = nil
        stage = isCompleted && !replayForVisit ? .completed : .notStarted
    }
    func beginIfEligible(generation: UUID, eligible: Bool) {
        guard self.generation == generation, eligible, !roster.isEmpty, stage == .notStarted, (!isCompleted || replayForVisit) else { return }
        if replayForVisit || !hasCompletedLean { stage = .introduction }
        else if !defaults.bool(forKey: Self.heartCompletionKey) { stage = .collectiblesIntroduction }
        else if !defaults.bool(forKey: Self.jumpDuckCompletionKey) { stage = .jumpDuckIntroduction }
        else { stage = .progressExplanation(.bar) }
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
        introVisible = false; stage = .freeLean; clearPractice()
    }
    /// Starts the evidence window when practice is visible.
    func practiceVisible(_ stage: Stage, generation: UUID, at time: Double) {
        guard self.generation == generation, self.stage == stage, isPractising, !isSuspended else { return }
        guard visiblePractice == nil else { return }
        visiblePractice = stage; activation = time; attempts = [:]
        #if DEBUG
        logPractice("visible", generation: generation, at: time)
        #endif
    }
    func setSuspended(_ value: Bool, generation: UUID) {
        guard self.generation == generation, isActive, isSuspended != value else { return }
        isSuspended = value; introVisible = false; visibleHeart = nil; visibleProgress = nil; clearPractice()
    }
    func canExploreLean(in session: GameSessionCoordinator) -> Bool {
        guard let input = session.inputContext, input.isActive, input.sessionGeneration == generation,
              roster == session.inputConfiguration.roster,
              roster.allSatisfy({ input.calibrationRevisions[$0] != nil }) else { return false }
        return session.preRoundTutorialPending && session.canStartLiveRound
            && session.inputStatus == .running && session.setup?.hasConfirmedReliablePair == true
    }

    func suspendPracticeClock() { previousPracticeTick = nil }
    func advancePractice(generation: UUID, at now: Double, ready: Bool) {
        guard self.generation == generation, isPractising else { return }
        let eligible = ready && !isSuspended && visiblePractice == stage && now.isFinite && now >= activation
        #if DEBUG
        if eligible {
            if loggedPracticeBlock { logPractice("resumed", generation: generation, at: now) }
            practiceBlockedSince = nil
            loggedPracticeBlock = false
        } else if now.isFinite {
            let since = practiceBlockedSince ?? now
            practiceBlockedSince = since
            if !loggedPracticeBlock && now - since >= 1 {
                logPractice("waiting ready=\(ready) paused=\(isSuspended) visible=\(visiblePractice == stage)",
                            generation: generation, at: now)
                loggedPracticeBlock = true
            }
        }
        #endif
        guard eligible else {
            previousPracticeTick = nil
            return
        }
        defer { if isPractising { previousPracticeTick = now } }
        guard let previousPracticeTick, now > previousPracticeTick else { return }
        // This is eligible active time, not a render delta. The view breaks the
        // interval on activity/readiness changes, even when scene updates are sparse.
        practiceTime += now - previousPracticeTick
        let verified = Set(roster).isSubset(of: demonstrated)
        guard (practiceTime >= 4 && verified) || practiceTime >= 10 else { return }
        leanExit = verified ? .verifiedMovement : .explorationTimeout
        // This flag records completion of exploration, regardless of its exit reason.
        defaults.set(true, forKey: Self.completionKey)
        stage = .collectiblesIntroduction
        #if DEBUG
        logPractice("accepted transition to collectiblesIntroduction exit=\(String(describing: leanExit))",
                    generation: generation, at: now)
        #endif
        clearPractice()
    }
    func finishCollectiblesIntroduction(generation: UUID) {
        guard self.generation == generation, stage == .collectiblesIntroduction, !isSuspended else { return }
        stage = .collection(.diamond)
    }
    func acceptPickup(_ receipt: FTUEPickupReceipt) {
        guard generation == receipt.generation, collection == receipt.kind, !isSuspended else { return }
        stage = receipt.kind == .diamond ? .collection(.heart) : .heart(.introduction)
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
        for player in roster where !demonstrated.contains(player) {
            guard let value = observation.players[player] else { attempts[player] = nil; continue }
            var attempt = attempts[player] ?? Attempt()
            let sign: Float = value.command < 0 ? -1 : 1
            if value.command == 0, value.velocity == 0 {
                attempt.armed = true; attempt.x = value.x; attempt.movingFrames = 0; attempt.direction = 0
            } else if attempt.armed, let x = attempt.x,
                      value.command * sign > 0, attempt.direction == 0 || attempt.direction == sign,
                      (value.velocity * sign > 0 && (value.x - x) * sign > 0
                       || value.velocity == 0 && value.blockedDirection == sign) {
                // Fresh neutral + two independent commanded frames are still required.
                // A confirmed directional clamp substitutes only for impossible movement.
                attempt.movingFrames += 1; attempt.x = value.x; attempt.direction = sign
                if attempt.movingFrames >= 2 { demonstrated.insert(player) }
            } else { attempt = Attempt() }
            attempts[player] = attempt
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
            stage = .jumpDuckIntroduction
        }
    }
    func finishJumpDuckIntroduction(generation: UUID) {
        guard self.generation == generation, stage == .jumpDuckIntroduction, !isSuspended else { return }
        stage = .laserPractice(.jump)
    }
    func synchronizePractice(_ practice: FTUELaserPractice, generation: UUID) {
        guard self.generation == generation, practice.generation == generation,
              Set(practice.roster) == Set(roster), practiceMove != nil, !isSuspended else { return }
        if practice.completed {
            defaults.set(true, forKey: Self.jumpDuckCompletionKey)
            stage = .progressExplanation(.bar)
        } else { stage = .laserPractice(practice.move) }
    }
    func setProgressHUDFrame(_ frame: CGRect, generation: UUID) {
        guard self.generation == generation, frame.width > 0, frame.height > 0,
              frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else { return }
        if progressHUDFrame != frame { progressHUDFrame = frame }
    }
    func progressVisible(_ phase: ProgressTutorialPhase, visible: Bool, generation: UUID) {
        guard self.generation == generation, progressPhase == phase else { return }
        visibleProgress = visible && !isSuspended ? phase : nil
    }
    func finishProgress(_ phase: ProgressTutorialPhase, generation: UUID) {
        guard self.generation == generation, progressPhase == phase, visibleProgress == phase, !isSuspended,
              progressJourney.hasReachedExplanationEndpoint(phase) else { return }
        visibleProgress = nil
        switch phase {
        case .bar: stage = .progressExplanation(.vault)
        case .vault: stage = .vaultButtonIntroduction
        case .diamond: stage = .diamondCollectionIntroduction
        }
    }

    func finishDiamondCollectionIntroduction(generation: UUID) {
        guard self.generation == generation, stage == .diamondCollectionIntroduction, !isSuspended else { return }
        stage = .diamondTimeDemo
    }

    func finishDiamondTime(_ round: FTUEDiamondTimeSession, generation: UUID) {
        guard self.generation == generation, round.inputs.context.sessionGeneration == generation,
              stage == .diamondTimeDemo, !isSuspended, round.isComplete else { return }
        completeProgressModule()
    }

    func finishVaultButtonIntroduction(generation: UUID) {
        guard self.generation == generation, stage == .vaultButtonIntroduction, !isSuspended else { return }
        stage = .vaultPractice
    }

    func finishVaultPractice(_ practice: FTUEVaultPractice, generation: UUID, doorIsClear: Bool) {
        guard self.generation == generation, stage == .vaultPractice, !isSuspended,
              practice.inputs.round.context.sessionGeneration == generation,
              practice.inputs.round.roster == roster, practice.didOpen, doorIsClear else { return }
        stage = .progressExplanation(.diamond)
    }

    private func completeProgressModule() {
        defaults.set(true, forKey: Self.progressCompletionKey)
        replayForVisit = false
        stage = .completed
    }

    func abandon() {
        replayForVisit = false; visibleHeart = nil; healthHUDFrame = nil; progressHUDFrame = nil; visibleProgress = nil
        progressJourney.reset(generation: nil)
        generation = nil; stage = .notStarted; isSuspended = false; introVisible = false
        clearPractice(); context = nil; lastSource = nil; practiceTime = 0; leanExit = nil
    }
    private func clearPractice() {
        demonstrated = []; attempts = [:]; visiblePractice = nil; activation = .infinity; suppressed = false; previousPracticeTick = nil
        #if DEBUG
        practiceBlockedSince = nil
        loggedPracticeBlock = false
        #endif
    }

    #if DEBUG
    private func logPractice(_ event: String, generation: UUID, at now: Double) {
        let required = roster.map(\.rawValue).joined(separator: ",")
        let proof = demonstrated.map(\.rawValue).sorted().joined(separator: ",")
        print(String(format: "[FreeLean] t=%.3f active=%.3f generation=%@ required=%@ proof=%@ %@",
                     now, practiceTime, generation.uuidString, required, proof, event))
    }
    #endif
    #if DEBUG
    func resetForNextPlay() { defaults.removeObject(forKey: Self.completionKey); defaults.removeObject(forKey: Self.heartCompletionKey); defaults.removeObject(forKey: Self.jumpDuckCompletionKey); defaults.removeObject(forKey: Self.progressCompletionKey); abandon() }
    /// Static screenshot route ONLY; never completes/persists a tutorial or reaches live input.
    func showPracticeForLayout(_ requested: Stage, generation: UUID) {
        guard self.generation == generation, requested == .freeLean else { return }
        stage = requested; clearPractice()
    }
    #endif
}
