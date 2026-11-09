//
//  GameSessionCoordinator.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import Foundation
import Observation

/// One CP1 consumer per round. Live input remains in setup until readiness/recovery integration exists.
@MainActor @Observable
final class GameSessionCoordinator {
    let configuration: LaserRoundConfiguration
    let encounters: [LaserEncounter]
    let inputConfiguration: BodyInputConfiguration
    let setup: LaserSessionSetup?
    var isReplay: Bool { replayDriver != nil }
    var activityDuration: Double { replayDriver?.script.activityDuration ?? configuration.activityDuration }
    private(set) var phase: SessionState = .idle
    private(set) var state: LaserGameState?
    private(set) var summary: RoundSummary?
    private(set) var results: [ReplayTargetResult] = []
    private(set) var latestSnapshot: BodySnapshot?
    private(set) var events: [GameEvent] = []
    private(set) var inputStatus: BodyInputStatus = .stopped
    private(set) var inputContext: BodyInputContext?
    private(set) var inputStreamEnded = false
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

    init(provider: any BodyInputProviding, inputConfiguration: BodyInputConfiguration,
         configuration: LaserRoundConfiguration, encounters: [LaserEncounter],
         replayDriver: LaserReplayDriver? = nil, setupControls: (any LaserSetupControlling)? = nil) {
        precondition(replayDriver == nil || replayDriver?.provider === provider,
                     "Replay driving must use the injected provider")
        self.provider = provider
        self.inputConfiguration = inputConfiguration
        self.configuration = configuration
        self.encounters = encounters
        self.replayDriver = replayDriver
        precondition(setupControls == nil || (replayDriver == nil && setupControls?.provider === provider),
                     "Setup must control the injected live provider")
        setup = setupControls.map { LaserSessionSetup(controls: $0, generation: inputConfiguration.sessionGeneration) }
    }

    convenience init(liveProvider: BodyInputService, inputConfiguration: BodyInputConfiguration,
                     configuration: LaserRoundConfiguration, encounters: [LaserEncounter]) {
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
                guard let context = provider.currentContext, context.isActive,
                      context.sessionGeneration == inputConfiguration.sessionGeneration,
                      PlayerID.allCases.allSatisfy({ context.calibrationRevisions[$0] != nil }) else {
                    throw LaserDataError.invalidValue("missing compatible replay context")
                }
                var engine = try LaserGame(configuration: configuration, context: context,
                                          historyCapacityPerPlayer: 120)
                for encounter in encounters { try engine.register(encounter) }
                iterator = stream.makeAsyncIterator()
                clock = try GameClock(sourceTime: 0)
                game = engine
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
        let time = min(sourceTime, replayDriver.script.duration)
        try requireLaserValue(time.isFinite && time >= clock.gameTime, "replay frame time")
        while let deliveryTime = replayDriver.nextDeliveryTime(through: time) {
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
            latestSnapshot = packet
            if game.roundOutcome != nil { break }
        }
        try replayDriver.applyActions(through: time, clock: &clock, game: &game)
        try clock.advance(to: time)
        try replayDriver.recordCoverage(through: time, game: &game)
        try game.advance(to: clock.gameTime)
        events.append(contentsOf: game.drainEvents())
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
        lifetime = nil
        phase = .finished
        setup?.close()
        game?.exit(outcome: reason)
        if let more = game?.drainEvents() { events.append(contentsOf: more) }
        if summary == nil { summary = game?.summary }
        refresh(at: game?.gameTime ?? 0)
        latestSnapshot = nil
        if hadLifetime { await releaseInput() }
    }

    func fail(_ error: any Error) async {
        await stop(reason: .technicalInterruption)
        phase = .failed(String(describing: error))
    }

    private func acceptSetupSnapshot(_ packet: BodySnapshot) {
        // This method runs after next() suspends. Read producer state again, never relabel old data.
        readInputStatus()
        guard phase == .awaitingSetup,
              packet.sessionGeneration == inputConfiguration.sessionGeneration,
              inputContext?.accepts(packet) == true else { return }
        // One bounded presentation/debug value only; no game, clock, scoring or readiness here.
        if latestSnapshot == nil || packet.frameID > latestSnapshot!.frameID { latestSnapshot = packet }
    }

    private func readInputStatus() {
        let context = provider.currentContext
        let status = provider.status
        if inputContext != context || inputStatus != status {
            if inputRevision < .max { inputRevision += 1 }
            latestSnapshot = nil
            if phase == .running {
                game?.pause()
                phase = .awaitingSetup
            }
        }
        inputContext = context
        inputStatus = status
        setup?.refresh()
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
            await provider.stop()
            // Retain the status claim until pending source startup has really exited. A delayed
            // start cannot stop or publish into a new session taking over the same provider.
            _ = try? await startup?.value
            if provider.status != .stopped { await provider.stop() }
            await task?.value
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
                                                  effectsCommitted: committed.contains(encounter.id)))
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
