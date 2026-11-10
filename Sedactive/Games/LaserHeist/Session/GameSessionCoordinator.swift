//
//  GameSessionCoordinator.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation
import Observation

/// Scene/update ownership only. This token is not player identity or capture generation.
nonisolated struct LaserLiveFrameAttachment: Equatable, Sendable {
    fileprivate let id: UUID
}

/// One CP1 consumer per round. Replay uses synthetic time; configured live rounds use host-time readiness.
@MainActor @Observable
final class GameSessionCoordinator {
    private(set) var configuration: LaserRoundConfiguration?
    private(set) var encounters: [LaserEncounter]
    let inputConfiguration: BodyInputConfiguration
    let setup: LaserSessionSetup?
    var isReplay: Bool { replayDriver != nil }
    #if DEBUG
    var isDebugWristPreview: Bool { replayDriver?.isWristDiamondPreview == true }
    #endif
    var isCompleteReplay: Bool { replayDriver?.script.fullRound != nil }
    /// Read-only domain state for the separately reviewed K06 rendering handoff.
    var diamondStates: [UUID: LaserDiamondState] { game?.diamonds ?? [:] }
    var diamondsCollected: Int { game?.diamondsCollected ?? 0 }
    var activityDuration: Double { replayDriver?.script.activityDuration ?? configuration?.activityDuration ?? 0 }
    private(set) var phase: SessionState = .idle
    private(set) var state: LaserGameState?
    private(set) var summary: RoundSummary?
    private(set) var results: [ReplayTargetResult] = []
    private(set) var latestSnapshot: BodySnapshot?
    private(set) var events: [GameEvent] = []
    private(set) var inputStatus: BodyInputStatus = .stopped
    private(set) var inputContext: BodyInputContext?
    private(set) var inputStreamEnded = false
    private(set) var liveReadiness: LaserLiveReadiness?
    private(set) var recoveryNeedsPlan = false
    var hasLiveRoundPlan: Bool { !isReplay && configuration != nil && !encounters.isEmpty && liveReadiness?.policy != nil }
    private(set) var liveFrameHostReady = false
    var canStartLiveRound: Bool {
        hasLiveRoundPlan && liveFrameHostReady && phase == .awaitingSetup && liveReadiness?.phase == .ready
    }
    var hasWristDiamondPlan: Bool { wristDiamondConfiguration != nil }
    var liveWristBlockers: [LaserLiveWristBlocker] {
        var result: [LaserLiveWristBlocker] = []
        let context = provider.currentContext
        if context?.isActive != true || provider.status != .running { result.append(.source) }
        if setup?.hasConfirmedReliablePair != true || context?.wristContact == nil { result.append(.binding) }
        if !PlayerID.allCases.allSatisfy({ context?.calibrationRevisions[$0] != nil }) { result.append(.calibration) }
        if !hasWristDiamondPlan { result.append(.geometry) }
        if !hasLiveRoundPlan { result.append(.roundPlan) }
        if liveReadiness?.phase != .ready && liveReadiness?.phase != .running { result.append(.measurements) }
        if phase == .paused || phase == .restartRequired || phase == .finished { result.append(.paused) }
        return result
    }
    var canPauseLiveRound: Bool { !isReplay && (phase == .running || phase == .countdown) }
    private let hostNow: @MainActor () -> Double
    private let provider: any BodyInputProviding
    private let replayDriver: LaserReplayDriver?
    private var iterator: AsyncStream<BodySnapshot>.Iterator?
    private var inputTask: Task<Void, Never>?
    private var startupTask: Task<Void, any Error>?
    private var cleanupTask: Task<Void, Never>?
    private var observerToken: UUID?
    private var subscriptionClaimed = false
    private var lifetime: UUID?
    private var inputRevision: UInt64 = 0
    private var clock: GameClock?
    private var game: LaserGame?
    private var committed: Set<UUID> = []
    private var advancing = false
    private var countdownRequested = false
    private var recoveryAttempted = false
    private var withdrawnLiveEncounters: [LaserEncounter] = []
    private var approvedRecovery: [LaserEncounter]?
    private let recoveryPlanner: (@MainActor (LaserLiveRecoveryRequest) throws -> [LaserEncounter]?)?
    private var liveTerminationTask: Task<Void, Never>?
    private var liveFrameAttachment: LaserLiveFrameAttachment?
    private var wristDiamondConfiguration: LaserWristDiamondConfiguration?
    private var installedLiveWristContext: BodyInputContext?
    private var wristDiamonds: LaserWristDiamondConsumer?

    init(provider: any BodyInputProviding, inputConfiguration: BodyInputConfiguration,
         configuration: LaserRoundConfiguration? = nil, encounters: [LaserEncounter] = [],
         replayDriver: LaserReplayDriver? = nil, setupControls: (any LaserSetupControlling)? = nil,
         liveTimingPolicy: LaserLiveTimingPolicy? = nil,
         wristDiamondConfiguration: LaserWristDiamondConfiguration? = nil,
         hostNow: @escaping @MainActor () -> Double = CameraHostClock.now,
         recoveryPlanner: (@MainActor (LaserLiveRecoveryRequest) throws -> [LaserEncounter]?)? = nil) {
        precondition(replayDriver == nil || replayDriver?.provider === provider,
                     "Replay driving must use the injected provider")
        self.provider = provider
        self.inputConfiguration = inputConfiguration
        self.configuration = configuration
        self.encounters = encounters
        self.replayDriver = replayDriver
        self.hostNow = hostNow
        self.recoveryPlanner = recoveryPlanner
        #if DEBUG
        precondition(wristDiamondConfiguration == nil || replayDriver == nil || replayDriver?.isWristDiamondPreview == true,
                     "Only the explicit DEBUG E08 fixture may replace scripted diamond contacts")
        #else
        precondition(wristDiamondConfiguration == nil || replayDriver == nil,
                     "Legacy replay membership and J07 must not both drive diamonds")
        #endif
        precondition(wristDiamondConfiguration.map { $0.layout == inputConfiguration.playerPlaneLayout } ?? true,
                     "Diamond zones must use the accepted CP1 player plane")
        self.wristDiamondConfiguration = wristDiamondConfiguration
        liveReadiness = replayDriver == nil ? LaserLiveReadiness(policy: liveTimingPolicy) : nil
        precondition(setupControls == nil || (replayDriver == nil && setupControls?.provider === provider),
                     "Setup must control the injected live provider")
        setup = setupControls.map { LaserSessionSetup(controls: $0, generation: inputConfiguration.sessionGeneration) }
    }

    convenience init(liveProvider: BodyInputService, inputConfiguration: BodyInputConfiguration,
                     configuration: LaserRoundConfiguration? = nil, encounters: [LaserEncounter] = []) {
        self.init(provider: liveProvider, inputConfiguration: inputConfiguration, configuration: configuration,
                  encounters: encounters, setupControls: LaserLiveSetupControls(service: liveProvider))
    }

    func start() async throws {
        guard phase == .idle else { return }
        phase = .starting
        let token = UUID()
        lifetime = token
        do {
            guard provider.status == .stopped else {
                throw LaserDataError.invalidValue("session requires a stopped, unowned provider")
            }
            // Claim status before starting so an already-owned observer fails without touching capture.
            observerToken = try provider.statusUpdates { [weak self] _ in self?.readInputStatus() }
        } catch {
            lifetime = nil
            phase = .failed(String(describing: error))
            throw error
        }
        do {
            let startup = Task { @MainActor [provider, inputConfiguration] in
                try Task.checkCancellation()
                try await provider.start(configuration: inputConfiguration)
            }
            startupTask = startup
            try await withTaskCancellationHandler {
                try await startup.value
            } onCancel: {
                startup.cancel()
            }
            guard lifetime == token, phase == .starting, !Task.isCancelled else {
                throw CancellationError()
            }
            let stream = try provider.snapshotStream(generation: inputConfiguration.sessionGeneration)
            subscriptionClaimed = true
            readInputStatus()
            if isReplay {
                guard let configuration, let context = provider.currentContext, context.isActive,
                      context.sessionGeneration == inputConfiguration.sessionGeneration,
                      PlayerID.allCases.allSatisfy({ context.calibrationRevisions[$0] != nil }) else {
                    throw LaserDataError.invalidValue("missing compatible replay context")
                }
                var engine = try LaserGame(configuration: configuration, context: context,
                                          historyCapacityPerPlayer: 120)
                if replayDriver?.script.fullRound == nil {
                    for encounter in encounters { try engine.register(encounter) }
                }
                iterator = stream.makeAsyncIterator()
                clock = try GameClock(sourceTime: 0)
                game = engine
                if let plan = wristDiamondConfiguration {
                    wristDiamonds = try LaserWristDiamondConsumer(configuration:plan,context:context,
                        lifetime:token,afterCapturedAt:0)
                }
                phase = .running
                refresh(at: 0)
            } else {
                // Source activity/uncalibrated CP1 packets are not permission to run a game.
                phase = .awaitingSetup
                setup?.activate()
                inputTask = Task { @MainActor [weak self] in
                    guard self?.lifetime == token else { return }
                    for await packet in stream {
                        guard !Task.isCancelled, let self, self.lifetime == token else { return }
                        self.acceptSetupSnapshot(packet)
                    }
                    guard let self, self.lifetime == token else { return }
                    self.inputStreamEnded = true
                    self.latestSnapshot = nil
                    self.liveReadiness?.requireRestart()
                    self.synchronizeLiveGame()
                }
            }
        } catch {
            let wasCurrent = lifetime == token
            if wasCurrent {
                lifetime = nil
                phase = Task.isCancelled || error is CancellationError
                    ? .finished : .failed(String(describing: error))
            }
            await releaseInput()
            throw error
        }
    }

    /// Serialized absolute-time updates: large frames still process every delivery/deadline in order.
    func advance(to sourceTime: Double) async throws {
        guard let replayDriver else {
            throw LaserDataError.invalidValue("synthetic advance is replay-only")
        }
        guard phase == .running, !advancing else { return }
        advancing = true
        defer { advancing = false }
        guard var clock, var game, var iterator, let token = lifetime else { return }
        let revision = inputRevision
        var stagedWrist = wristDiamonds
        let time = min(sourceTime, replayDriver.script.duration)
        try requireLaserValue(time.isFinite && time >= clock.gameTime, "replay frame time")
        while game.roundOutcome == nil {
            let delivery = replayDriver.nextDeliveryTime(through: time)
            let action = replayDriver.nextActionTime(through: time)
            guard delivery != nil || action != nil else { break }
            if let action, delivery == nil || action < delivery! {
                try replayDriver.applyNextAction(clock: &clock, game: &game)
                if let context = provider.currentContext {
                    try stagedWrist?.refresh(game:game,context:context,atHostTime:action)
                }
                continue
            }
            guard let deliveryTime = delivery else { break }
            // Snapshot-only, compatible scripted source; drain each packet before advancing again.
            try replayDriver.deliverNext()
            guard let packet = await iterator.next(isolation: MainActor.shared) else { throw LaserDataError.invalidValue("replay ended early") }
            guard phase == .running, lifetime == token else { return }
            if Task.isCancelled {
                await stop(reason: .technicalInterruption)
                throw CancellationError()
            }
            // Never restore a local pre-suspension game/iterator against a newer context.
            guard revision == inputRevision, provider.currentContext == inputContext,
                  inputContext?.accepts(packet) == true else {
                throw LaserDataError.invalidValue("replay context changed during delivery")
            }
            try clock.advance(to: deliveryTime)
            guard let captured = clock.gameTime(forCaptureTime: packet.capturedAt) else {
                throw LaserDataError.invalidValue("unmapped replay capture")
            }
            try game.receive(packet, capturedGameTime: captured, arrivedAt: clock.gameTime)
            if let context = provider.currentContext {
                try stagedWrist?.receive(packet,context:context,atHostTime:deliveryTime,
                    capturedGameTime:captured,arrivedGameTime:clock.gameTime,game:&game)
            }
            latestSnapshot = packet
            if game.roundOutcome != nil { break }
        }
        try clock.advance(to: time)
        try replayDriver.recordCoverage(through: time, game: &game)
        try game.advance(to: clock.gameTime)
        if let context = provider.currentContext {
            try stagedWrist?.refresh(game:game,context:context,atHostTime:time)
        }
        guard lifetime == token, inputRevision == revision, provider.currentContext == inputContext else { return }
        events.append(contentsOf: game.drainEvents())
        self.wristDiamonds = stagedWrist
        self.clock = clock
        self.game = game
        self.iterator = iterator
        refresh(at: time)
        if let final = game.summary {
            if summary == nil { summary = final }
            phase = .finished
            refresh(at: time)
            lifetime = nil
            await releaseInput()
        }
    }

    func stop(reason: LaserRoundOutcome = .aborted) async {
        let hadLifetime = lifetime != nil
        wristDiamonds = nil
        lifetime = nil
        phase = .finished
        liveFrameAttachment = nil
        liveFrameHostReady = false
        setup?.close()
        liveReadiness?.requireRestart()
        game?.exit(outcome: reason)
        if let more = game?.drainEvents() { events.append(contentsOf: more) }
        if summary == nil { summary = game?.summary }
        refresh(at: game?.gameTime ?? 0)
        latestSnapshot = nil
        if hadLifetime || cleanupTask != nil || liveTerminationTask != nil { await releaseInput() }
    }

    func fail(_ error: any Error) async {
        await stop(reason: .technicalInterruption)
        phase = .failed(String(describing: error))
    }

    private func acceptSetupSnapshot(_ packet: BodySnapshot) {
        // This method runs after next() suspends. Read producer state again, never relabel old data.
        readInputStatus(synchronizeLive: false)
        guard [.awaitingSetup, .countdown, .running, .paused].contains(phase),
              packet.sessionGeneration == inputConfiguration.sessionGeneration,
              inputContext?.accepts(packet) == true else { return }
        // Keep one current snapshot; the same sole stream also supplies authoritative live evidence.
        if latestSnapshot == nil || packet.frameID > latestSnapshot!.frameID { latestSnapshot = packet }
        if let context = inputContext {
            do {
                try liveReadiness?.observe(packet, context: context,
                    bindingConfirmed: setup?.hasConfirmedReliablePair == true && setup?.canCancelCalibration == false,
                    at: hostNow())
            } catch { liveReadiness?.requireRestart() }
        }
        synchronizeLiveGame(packet: packet)
    }

    private func readInputStatus(synchronizeLive: Bool = true) {
        let context = provider.currentContext
        let status = provider.status
        if inputContext != context || inputStatus != status {
            wristDiamonds?.invalidate(atHostTime: replayDriver?.provider.now ?? hostNow())
            if inputRevision < .max { inputRevision += 1 }
            latestSnapshot = nil
            if isReplay, phase == .running {
                game?.pause()
                phase = .awaitingSetup
            }
        }
        inputContext = context
        inputStatus = status
        setup?.refresh()
        if let installedLiveWristContext, installedLiveWristContext != context {
            liveReadiness?.requireRestart() // even a pre-countdown cutover needs a new setup/plan
        }
        guard liveReadiness != nil else { return } // Replay never reads a host-time source.
        do {
            let time = hostNow()
            try liveReadiness?.updateContext(context, at: time)
            if setup != nil, setup?.hasConfirmedReliablePair != true {
                latestSnapshot = nil
                try liveReadiness?.invalidateBinding(at: time)
            }
        }
        catch { liveReadiness?.requireRestart() }
        if setup?.phase == .restartRequired { liveReadiness?.requireRestart() }
        if synchronizeLive { synchronizeLiveGame(allowAdvance: false) }
    }

    /// Read status/readiness without finalizing deadlines or publishing a fake snapshot.
    func refreshLiveReadiness() {
        guard !isReplay, lifetime != nil else { return }
        readInputStatus()
    }

    /// The renderer supplies a signal; original host time and the one live GameClock decide time.
    /// Install once in the existing setup session AFTER real E05 acceptance. No new provider,
    /// source generation, stream or GameClock. The owner supplies all reviewed plan/zone inputs.
    func installLiveWristRound(_ plan: LaserLiveWristRoundPlan) throws {
        readInputStatus(synchronizeLive:false)
        guard !isReplay, lifetime != nil, phase == .awaitingSetup, game == nil, clock == nil,
              configuration == nil, !inputStreamEnded, liveFrameAttachment == nil,
              setup?.hasConfirmedReliablePair == true, setup?.canCancelCalibration == false,
              provider.status == .running, let context = provider.currentContext,
              context == plan.expectedContext, context.sessionGeneration == inputConfiguration.sessionGeneration,
              plan.diamonds.layout == inputConfiguration.playerPlaneLayout else {
            throw LaserDataError.invalidValue("live wrist plan requires current accepted setup")
        }
        // All candidate/context validation precedes assignment. No acceptance is created here.
        configuration = plan.configuration; encounters = plan.encounters
        wristDiamondConfiguration = plan.diamonds; installedLiveWristContext = context
        liveReadiness = LaserLiveReadiness(policy:plan.timing)
        readInputStatus() // new fresh settling/scene attachment/countdown remain mandatory
    }

    func advanceLive() {
        guard !isReplay, lifetime != nil else { return }
        readInputStatus(synchronizeLive: false)
        synchronizeLiveGame()
    }

    func attachLiveFrameHost() throws -> LaserLiveFrameAttachment {
        guard hasLiveRoundPlan, lifetime != nil, liveFrameAttachment == nil else {
            throw LaserDataError.invalidValue("inactive or already attached live frame host")
        }
        let token = LaserLiveFrameAttachment(id: UUID())
        liveFrameAttachment = token
        liveFrameHostReady = false
        return token
    }

    func advanceLive(frameHost token: LaserLiveFrameAttachment) {
        guard lifetime != nil, liveFrameAttachment == token else { return }
        liveFrameHostReady = true
        advanceLive()
    }

    func detachLiveFrameHost(_ token: LaserLiveFrameAttachment) {
        guard liveFrameAttachment == token else { return }
        liveFrameAttachment = nil
        liveFrameHostReady = false
        guard lifetime != nil else { return }
        do { try liveReadiness?.invalidatePresentation(at: hostNow()) }
        catch { liveReadiness?.requireRestart() }
        synchronizeLiveGame()
    }

    func beginLiveCountdown() throws {
        guard !isReplay, lifetime != nil, hasLiveRoundPlan, liveFrameHostReady else {
            throw LaserDataError.invalidValue("missing live plan/policy")
        }
        readInputStatus()
        guard liveReadiness?.phase == .ready else { throw LaserDataError.invalidValue("live input not ready") }
        countdownRequested = true
        recoveryAttempted = false
        synchronizeLiveGame()
        guard phase == .countdown else { throw LaserDataError.invalidValue("recovery plan not ready") }
    }

    func pauseLiveRound() {
        guard canPauseLiveRound else { return }
        do { try liveReadiness?.setManualPause(true, at: hostNow()) }
        catch { liveReadiness?.requireRestart() }
        synchronizeLiveGame()
    }

    /// Phase intent from the session's reviewed round plan, never a button/contact detector.
    /// Due laser effects must be settled before entering the vault opportunity.
    func beginLiveVault(id: UUID) throws {
        guard !isReplay, lifetime != nil else { throw LaserDataError.invalidValue("inactive live vault intent") }
        advanceLive()
        guard phase == .running, game?.roundPhase == .activity,
              state?.encounters.allSatisfy({ $0.effectsCommitted }) == true,
              let time = liveReadiness?.gameTime else {
            throw LaserDataError.invalidValue("unresolved laser effects before vault")
        }
        try game?.openVault(id: id, at: time)
        collectLiveState()
    }

    /// Existing round-plan owner supplies domain spawns; never infer a live reach/radius.
    func spawnLiveDiamonds(_ spawns: [LaserDiamondSpawn], beforeVaultAt boundary: Double) throws {
        advanceLive()
        guard !isReplay, phase == .running, wristDiamondConfiguration != nil,
              var stagedGame = game, let context = inputContext, provider.currentContext == context else {
            throw LaserDataError.invalidValue("missing running diamond plan/context")
        }
        var stagedWrist = wristDiamonds
        try stagedGame.spawnNormalDiamonds(spawns, beforeVaultAt: boundary)
        try stagedWrist?.refresh(game: stagedGame, context: context, atHostTime: hostNow())
        guard provider.currentContext == context else { return }
        game = stagedGame; wristDiamonds = stagedWrist; collectLiveState()
    }

    func startLiveDiamondTimeDiamonds(_ spawns: [LaserDiamondSpawn]) throws {
        advanceLive()
        guard !isReplay, phase == .running, wristDiamondConfiguration != nil,
              var stagedGame = game, let context = inputContext, provider.currentContext == context else {
            throw LaserDataError.invalidValue("missing running bonus diamond plan/context")
        }
        var stagedWrist = wristDiamonds
        try stagedGame.startDiamondTimeDiamonds(spawns)
        try stagedWrist?.refresh(game: stagedGame, context: context, atHostTime: hostNow())
        guard provider.currentContext == context else { return }
        game = stagedGame; wristDiamonds = stagedWrist; collectLiveState()
    }

    func continueLiveRound() {
        guard !isReplay, phase == .paused, lifetime != nil else { return }
        do { try liveReadiness?.setManualPause(false, at: hostNow()) }
        catch { liveReadiness?.requireRestart() }
        countdownRequested = true
        recoveryAttempted = false
        synchronizeLiveGame()
    }

    private func synchronizeLiveGame(packet: BodySnapshot? = nil, allowAdvance: Bool = true) {
        guard !isReplay, lifetime != nil, let readiness = liveReadiness else { return }
        do {
            switch readiness.phase {
            case .restartRequired:
                game?.exit(outcome: .technicalInterruption)
                collectLiveState()
                phase = .restartRequired
                finishLiveInput()
                return
            case .ready where countdownRequested:
                guard liveFrameHostReady else { return }
                guard let configuration, let context = inputContext, provider.currentContext == context else { return }
                if game != nil, !withdrawnLiveEncounters.isEmpty, approvedRecovery == nil {
                    guard !recoveryAttempted else { return }
                    recoveryAttempted = true
                    let request = LaserLiveRecoveryRequest(withdrawn: withdrawnLiveEncounters,
                        gameTime: readiness.gameTime, hostTime: hostNow(), context: context)
                    do {
                        guard let replacement = try recoveryPlanner?(request) else {
                            recoveryNeedsPlan = true; phase = .paused; return
                        }
                        try LaserLiveRecovery.validate(replacement, request: request, configuration: configuration)
                        try requireLaserValue(replacement.allSatisfy { game?.hasUsedAttempt($0.attemptID) == false },
                                              "recovery attempt identity already used in round")
                        approvedRecovery = replacement
                    } catch { recoveryNeedsPlan = true; phase = .paused; return }
                }
                try requireLaserValue(Set(encounters.map(\.id)).count == encounters.count
                    && Set(encounters.map(\.attemptID)).count == encounters.count
                    && encounters.allSatisfy { $0.targets.allSatisfy {
                        context.calibrationRevisions[$0.playerID] == $0.calibrationRevision
                    } }, "live plan calibration/identity")
                try liveReadiness?.beginCountdown(at: hostNow())
                recoveryNeedsPlan = false
                phase = .countdown
                return
            case .countdown:
                phase = .countdown
                return
            case .running:
                // Coalesced status callbacks may overtake a queued CP1 packet. They can pause or
                // invalidate immediately, but only the stream/frame path finalizes evidence.
                guard allowAdvance, liveFrameHostReady else { return }
                guard let configuration, let context = inputContext,
                      provider.currentContext == context, setup?.hasConfirmedReliablePair == true else { return }
                if game == nil {
                    var initial = try LaserGame(configuration: configuration, context: context, historyCapacityPerPlayer: 120)
                    for encounter in encounters { try initial.register(encounter) }
                    game = initial
                    withdrawnLiveEncounters = []; approvedRecovery = nil; recoveryAttempted = false
                } else if phase != .running {
                    var resumed = game!
                    resumed.resume()
                    let replacements = approvedRecovery ?? []
                    for encounter in replacements { try resumed.register(encounter) }
                    for old in withdrawnLiveEncounters {
                        for target in old.targets {
                            resumed.remove(LaserTargetKey(encounterID: old.id, attemptID: old.attemptID,
                                                         playerID: target.playerID))
                        }
                        committed.remove(old.id)
                    }
                    for replacement in replacements {
                        if let index = encounters.firstIndex(where: { $0.id == replacement.id }) { encounters[index] = replacement }
                    }
                    game = resumed
                    withdrawnLiveEncounters = []; approvedRecovery = nil; recoveryAttempted = false
                }
                if phase != .running, let plan = wristDiamondConfiguration, let token = lifetime {
                    wristDiamonds = try LaserWristDiamondConsumer(configuration: plan, context: context,
                        lifetime: token, afterCapturedAt: hostNow())
                }
                phase = .running
                // Receive before inclusive advance: equal-deadline arrivals remain eligible.
                var stagedGame = game!, stagedWrist = wristDiamonds
                let revision = inputRevision
                if let packet, let captured = liveReadiness?.capturedGameTime(for: packet) {
                    try stagedGame.receive(packet, capturedGameTime: captured, arrivedAt: readiness.gameTime)
                    try stagedWrist?.receive(packet, context: context, atHostTime: hostNow(),
                        capturedGameTime: captured, arrivedGameTime: readiness.gameTime, game: &stagedGame)
                }
                try stagedGame.advance(to: readiness.gameTime)
                try stagedWrist?.refresh(game: stagedGame, context: context, atHostTime: hostNow())
                // No suspension/callback between this producer recheck and staged assignment.
                guard lifetime != nil, inputRevision == revision, provider.currentContext == context else { return }
                game = stagedGame; wristDiamonds = stagedWrist
                collectLiveState()
                if summary != nil { phase = .finished; finishLiveInput(); return }
                if encounters.contains(where: { encounter in
                    encounter.targets.contains { target in
                        if case .unavailable = game?.judgement(for: LaserTargetKey(encounterID: encounter.id,
                            attemptID: encounter.attemptID, playerID: target.playerID)) { return true }
                        return false
                    }
                }) {
                    try liveReadiness?.invalidateMeasurements(at: hostNow())
                    try pauseLiveGame(at: readiness.gameTime)
                }
            default:
                if game != nil || phase == .countdown || phase == .paused {
                    try pauseLiveGame(at: readiness.gameTime)
                }
            }
        } catch {
            liveReadiness?.requireRestart()
            game?.exit(outcome: .technicalInterruption)
            collectLiveState()
            phase = .restartRequired
            finishLiveInput()
        }
    }

    private func pauseLiveGame(at time: Double) throws {
        if phase != .paused {
            wristDiamonds?.invalidate(atHostTime: hostNow())
            if game?.isPaused != true {
                withdrawnLiveEncounters = encounters.filter { encounter in
                    !encounter.targets.allSatisfy { target in
                        guard let judgement = game?.judgement(for: LaserTargetKey(encounterID: encounter.id,
                            attemptID: encounter.attemptID, playerID: target.playerID)) else { return false }
                        switch judgement { case .clear, .hit: return true; default: return false }
                    }
                }
                try game?.pause(at: time)
            }
            collectLiveState()
            approvedRecovery = nil; recoveryAttempted = false
        }
        phase = .paused
    }

    private func collectLiveState() {
        if let more = game?.drainEvents() { events.append(contentsOf: more) }
        if summary == nil { summary = game?.summary }
        refresh(at: game?.gameTime ?? 0)
    }

    private func finishLiveInput() {
        guard liveTerminationTask == nil else { return }
        wristDiamonds = nil
        lifetime = nil
        liveFrameAttachment = nil
        liveFrameHostReady = false
        setup?.close()
        liveReadiness?.requireRestart()
        liveTerminationTask = Task { @MainActor [weak self] in await self?.releaseInput() }
    }

    private func releaseInput() async {
        if let cleanupTask {
            await cleanupTask.value
            return
        }
        let task = inputTask
        let startup = startupTask
        let observer = observerToken
        let claimed = subscriptionClaimed
        inputTask = nil
        startupTask = nil
        observerToken = nil
        subscriptionClaimed = false
        iterator = nil
        let cleanup = Task { @MainActor [provider, inputConfiguration] in
            task?.cancel()
            startup?.cancel()
            if claimed {
                try? provider.releaseSnapshotSubscription(generation: inputConfiguration.sessionGeneration)
            }
            // CP1 Retry ordering: cancel/close and join the old reader before source cleanup.
            await task?.value
            await provider.stop()
            // Retain the status claim until pending source startup has really exited. A delayed
            // start cannot stop or publish into a new session taking over the same provider.
            _ = try? await startup?.value
            if provider.status != .stopped { await provider.stop() }
            if let observer { try? provider.removeStatusObserver(observer) }
        }
        cleanupTask = cleanup
        await cleanup.value
        inputContext = provider.currentContext
        inputStatus = provider.status
    }

    private func refresh(at time: Double) {
        guard let game else { return }
        var encounterStates: [LaserEncounterState] = []
        for encounter in encounters {
            var verdicts: [PlayerID: Judgement] = [:]
            for target in encounter.targets {
                let key = LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: target.playerID)
                verdicts[target.playerID] = game.judgement(for: key)
                    ?? state?.encounters.first(where: { $0.encounter.id == encounter.id })?.judgements[target.playerID]
                    ?? .pending(.awaitingFinalization)
            }
            let finalized = verdicts.values.allSatisfy { if case .pending = $0 { false } else { true } }
            if finalized, committed.insert(encounter.id).inserted {
                for player in PlayerID.allCases {
                    let key = LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: player)
                    var frame: UInt64?
                    if case .selected(let evidence) = game.selection(for: key) { frame = evidence.snapshot.frameID }
                    results.append(ReplayTargetResult(encounterID: encounter.id, playerID: player,
                                                     judgement: verdicts[player]!, selectedFrameID: frame))
                }
            }
            encounterStates.append(LaserEncounterState(encounter: encounter, judgements: verdicts,
                effectsCommitted: finalized && !verdicts.values.contains { if case .unavailable = $0 { true } else { false } }))
        }
        state = LaserGameState(sessionGeneration: inputConfiguration.sessionGeneration,
            phase: game.roundPhase, gameTime: game.gameTime, activityProgress: game.activityProgress,
            teamHealth: game.teamHealth, teamScore: game.teamScore, encounters: encounterStates)
        state?.missionProgress = game.missionProgress
        state?.missionTarget = game.missionTarget
        state?.playerStats = game.playerStats
        state?.vault = game.vault
    }
}
