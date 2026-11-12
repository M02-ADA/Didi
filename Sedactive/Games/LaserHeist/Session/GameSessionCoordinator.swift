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
    /// The scripted entry into the final vault (live rounds), from the moment Diamond Time is
    /// unlocked until the team stands inside; `nil` before it and in replay. While it is
    /// incomplete the session holds `GameClock`, so Diamond Time has not started counting.
    private(set) var finalVaultEntry: LaserFinalVaultEntry?
    /// Host time the entry last advanced to while the clock was held.
    private var finalVaultStamp: Double?
    var activityDuration: Double { replayDriver?.script.activityDuration ?? configuration?.activityDuration ?? 0 }
    private(set) var phase: SessionState = .idle {
        didSet {
            #if DEBUG
            if oldValue != phase {
                print(String(format: "[LaserState] t %.3f · session %@ → %@ · readiness %@ · setup %@", ProcessInfo.processInfo.systemUptime,
                             "\(oldValue)", "\(phase)", "\(String(describing: liveReadiness?.phase))", "\(String(describing: setup?.phase))"))
            }
            #endif
        }
    }
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
    var hasLiveRoundPlan: Bool {
        !isReplay && configuration != nil && (!encounters.isEmpty || liveDirector != nil) && liveReadiness?.policy != nil
    }
    /// The round's whole laser schedule as known now (registered plus the director's plan),
    /// for display sizing only.
    var plannedEncounters: [LaserEncounter] {
        guard let liveDirector else { return encounters }
        let registered = Set(encounters.map(\.id))
        return encounters + liveDirector.baseEncounters.filter { !registered.contains($0.id) }
    }
    /// Live rounds: game seconds until the current minute's vault, during the activity.
    var liveVaultIn: Double? {
        guard let boundary = liveDirector?.vaultBoundary, state?.phase == .activity, let time = state?.gameTime,
              boundary > time else { return nil }
        return boundary - time
    }
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
        if !inputConfiguration.roster.allSatisfy({ context?.calibrationRevisions[$0] != nil }) { result.append(.calibration) }
        if !hasWristDiamondPlan { result.append(.geometry) }
        if !hasLiveRoundPlan { result.append(.roundPlan) }
        if liveReadiness?.phase != .ready && liveReadiness?.phase != .running { result.append(.measurements) }
        if phase == .paused || phase == .restartRequired || phase == .finished { result.append(.paused) }
        return result
    }
    var canPauseLiveRound: Bool { !isReplay && (phase == .running || phase == .countdown) }
    /// DEBUG Solo Test only: once the round has begun, losing P1 neither pauses nor restarts it.
    /// Always false in co-op and in Release.
    var soloRoundToleratesTrackingLoss: Bool {
        #if DEBUG
        inputConfiguration.soloPlayer != nil && game != nil && summary == nil
        #else
        false
        #endif
    }
    #if DEBUG
    private func controls(trackingP1IsLive setup: LaserSessionSetup?) -> Bool {
        guard let slot = setup?.diagnosticControls.tracking.latest?[.player1] else { return false }
        return slot.state == .tracking && !slot.requiresRebind
    }
    /// One DEBUG skip record: when it entered Diamond Time and what it withdrew (never scored).
    struct DebugSkip: Equatable { let gameTime: Double; let withdrawnTargets: Int; let closedDiamonds: Int }
    private(set) var debugSkips: [DebugSkip] = []
    /// One DEBUG skip to the next gate: which vault it led to, when, and what it dropped (never scored).
    struct DebugGateSkip: Equatable { let vault: Int; let droppedLasers: Int; let droppedDiamonds: Int; let vaultAt: Double }
    private(set) var debugGateSkips: [DebugGateSkip] = []
    private(set) var debugSoloTrackingLost = false
    private var debugPendingVaultPress: LaserVaultButton?
    /// A "Skip to Diamond Time" waiting for the next running frame (a paused round applies it on resume).
    private(set) var debugPendingSkipToDiamondTime = false

    /// "Skip to Diamond Time" is available: a live test round (Solo or co-op) before Diamond Time,
    /// running or paused for tracking (then it applies on resume). Tracking is not required.
    var canDebugSkipToDiamondTime: Bool {
        guard !isReplay, phase == .running || phase == .paused, summary == nil, !debugPendingSkipToDiamondTime,
              let roundPhase = game?.roundPhase else { return false }
        return roundPhase == .activity || roundPhase == .vault
    }

    /// DEBUG: enters the real Diamond Time on the next running frame (`LaserGame.debugSkipToDiamondTime`),
    /// where its diamonds are placed exactly as after a final vault. Logged; nothing skipped is scored.
    /// Repeated taps queue one skip.
    func debugSkipToDiamondTime() {
        guard canDebugSkipToDiamondTime else { return }
        debugPendingSkipToDiamondTime = true
        advanceLive()
    }

    /// "Skip to Next Gate" is available: a running live test round in its activity, with a vault
    /// still ahead more than the skip lead away. Not while paused: a resume may still need to plan
    /// its replacement lasers before that vault.
    var canDebugSkipToNextGate: Bool {
        guard !isReplay, phase == .running, summary == nil, var director = liveDirector,
              let game, game.roundPhase == .activity else { return false }
        return director.debugSkipToVault(game: game) != nil
    }

    /// DEBUG: ends the current minute early so its vault arrives in
    /// `LaserLiveRoundDirector.debugSkipLead` game seconds. No clock moves; nothing dropped is
    /// judged or scored; a vault already that close makes a repeated tap do nothing.
    func debugSkipToNextGate() {
        advanceLive()
        guard canDebugSkipToNextGate, var director = liveDirector, let game,
              let skipped = director.debugSkipToVault(game: game) else { return }
        liveDirector = director
        let record = DebugGateSkip(vault: director.currentVaultIndex + 1, droppedLasers: skipped.droppedLasers,
                                   droppedDiamonds: skipped.droppedDiamonds, vaultAt: skipped.vaultAt)
        debugGateSkips.append(record)
        print(String(format: "[LaserSkip] to vault %d at game %.2f s (now %.2f) · dropped %d unregistered lasers, %d diamonds (not judged, not scored)",
                     record.vault, record.vaultAt, game.gameTime, record.droppedLasers, record.droppedDiamonds))
    }

    /// The open Solo Test vault's P1 buttons already pressed (nil outside an open vault).
    var debugSoloVaultPressed: Set<LaserVaultButton>? {
        guard inputConfiguration.soloPlayer == .player1, let vault = game?.vault, game?.roundPhase == .vault,
              !vault.opened else { return nil }
        return vault.buttons[.player1] ?? []
    }

    /// DEBUG Solo Test tap fallback for one of P1's vault buttons, applied on the next frame.
    func debugPressVaultButton(_ button: LaserVaultButton) {
        guard debugSoloVaultPressed?.contains(button) == false, phase == .running else { return }
        debugPendingVaultPress = button
        advanceLive()
    }
    #endif
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
    /// Live round director (complete replay schedule on the live GameClock); nil in replay.
    private var liveDirector: LaserLiveRoundDirector?
    /// The open live vault's zones, re-armed on a recreated wrist consumer after a pause.
    private var liveVault: (id: UUID, zones: [LaserVaultZone])?
    /// The open live vault's contact zones (presentation draws the buttons on them).
    var liveVaultZones: [LaserVaultZone]? { liveVault?.zones }
    /// Live rounds with mascots (set by the play view): how far each player's mascot is from its
    /// vault button console at a capture time, as a reach in the player's unmirrored plane (game
    /// units; 0 docked; `RobotAvatarLayer.vaultReachShift`). With it, a vault zone is judged where
    /// the mascot's hand reaches: relative to the player's own body centre, beyond by that shift.
    /// Nil (replay, tests, no mascots): the approved lane-relative zones.
    var vaultMascotReach: ((PlayerID, _ capturedAt: Double) -> Double?)?

    #if DEBUG
    /// The DEBUG round panel's gate-contact line per player (latest packet at an open gate).
    static var debugVaultContact: [PlayerID: String] = [:]
    private var lastVaultContactLog: Double = -1

    /// Per player: each wrist's nearest judged button, its distance to that (shifted) zone and the
    /// judge's own status, the shift, and which buttons the game has. Numbers only.
    private func logVaultContact(_ readout: [LaserWristDiamondConsumer.VaultReadout], shifts: [PlayerID: Double],
                                 pressed: [PlayerID: Set<LaserVaultButton>], at time: Double) {
        var lines: [PlayerID: String] = [:]
        for player in inputConfiguration.roster {
            var parts: [String] = []
            for wrist in LaserContactWrist.allCases {
                let rows = readout.filter { $0.playerID == player && $0.wrist == wrist }
                guard let first = rows.first else { continue }
                let w = wrist == .left ? "L" : "R"
                if first.distance == nil { parts.append("\(w) \(first.status)"); continue }
                let near = rows.min { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }!
                let p = near.point.map { String(format: "(%.2f, %.2f)", $0.x, $0.y) } ?? "-"
                parts.append(String(format: "%@ wrist %@ → %@ d %.3f (r %.3f) %@%@", w, p, near.button.rawValue.uppercased(),
                                    near.distance ?? 0, near.radius, near.status, near.pressed ? " PRESS" : ""))
            }
            let shift = shifts[player].map { $0.isFinite ? String(format: "%.3f", $0) : "unplaceable" } ?? "none"
            let has = (pressed[player] ?? []).map { $0.rawValue }.sorted().joined(separator: ",")
            lines[player] = "\(parts.joined(separator: " · ")) · zone shift \(shift) · lit [\(has)]"
        }
        Self.debugVaultContact = lines
        let anyPress = readout.contains(where: \.pressed)
        guard anyPress || time - lastVaultContactLog >= 0.5 else { return }
        lastVaultContactLog = time
        for (player, line) in lines.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print("[LaserGateContact] \(player.rawValue) \(line)")
        }
    }
    #endif

    /// This capture's vault zone shifts (see `vaultMascotReach`): empty without mascots; a
    /// non-finite shift when the zone cannot be placed (no valid body centre or mascot position).
    func vaultZoneShifts(for snapshot: BodySnapshot) -> [PlayerID: Double] {
        guard let reach = vaultMascotReach else { return [:] } // only vault zones read it
        var shifts: [PlayerID: Double] = [:]
        for player in inputConfiguration.roster {
            let center = snapshot.players[player]?.geometry.centerX
            guard let mascot = reach(player, snapshot.capturedAt), mascot.isFinite,
                  let center, center.validity == .valid, let x = center.value else { shifts[player] = .infinity; continue }
            shifts[player] = x - inputConfiguration.playerPlaneLayout.centerX(for: player) + mascot
        }
        return shifts
    }
    /// Builds the live round plan from the producer's ACCEPTED context once setup is complete.
    private let liveRoundPlanner: (@MainActor (BodyInputContext, [PlayerID: PlayerCalibration]) throws -> LaserLiveWristRoundPlan)?
    private var installingLivePlan = false
    private(set) var livePlanError: String?
    /// Automatic onboarding: link, calibrate, accept and count down without buttons, each step
    /// only when the same conditions its button required hold. Off for tests and DEBUG tools.
    let automaticSetup: Bool
    /// Tests step the driver themselves (`advanceSetupAutomatically`) for determinism.
    private let automaticSetupTimer: Bool
    private(set) var presence = LaserSetupPresence()
    /// DEBUG Solo Test: one player (P1) practises; results are diagnostic, not a co-op round.
    var isSoloPractice: Bool { inputConfiguration.soloPlayer != nil }
    /// A begun round paused because the tracker can no longer vouch for a player's identity
    /// (setup needs a rebind). The round is kept; it resumes if the tracker confirms the same pair
    /// again, otherwise the players restart explicitly.
    var awaitsIdentityRecovery: Bool {
        game != nil && summary == nil && phase == .paused && setup?.phase == .restartRequired
    }
    private var setupTask: Task<Void, Never>?
    private var uprightPromptStart: Double?
    private var retryAt: Double?
    #if DEBUG
    private(set) var setupTimeline = LaserSetupTimeline()
    private var lastLoggedIssue: [PlayerID: String] = [:]
    private var lastLoggedJump: [PlayerID: String] = [:]
    private var lastLoggedReadiness: String?
    /// DEBUG: each player's last logged tracker slot (state/reason/rebind), for bystander diagnosis.
    private var lastLoggedSlot: [PlayerID: String] = [:]
    private var lastSearchLog = -Double.infinity
    private var lastLoggedFrame: [PlayerID: UInt64] = [:]
    #endif

    init(provider: any BodyInputProviding, inputConfiguration: BodyInputConfiguration,
         configuration: LaserRoundConfiguration? = nil, encounters: [LaserEncounter] = [],
         replayDriver: LaserReplayDriver? = nil, setupControls: (any LaserSetupControlling)? = nil,
         liveTimingPolicy: LaserLiveTimingPolicy? = nil,
         wristDiamondConfiguration: LaserWristDiamondConfiguration? = nil,
         hostNow: @escaping @MainActor () -> Double = CameraHostClock.now,
         recoveryPlanner: (@MainActor (LaserLiveRecoveryRequest) throws -> [LaserEncounter]?)? = nil,
         liveRoundPlanner: (@MainActor (BodyInputContext, [PlayerID: PlayerCalibration]) throws -> LaserLiveWristRoundPlan)? = nil,
         automaticSetup: Bool = false, automaticSetupTimer: Bool = true) {
        self.automaticSetup = automaticSetup && replayDriver == nil
        self.automaticSetupTimer = automaticSetupTimer
        precondition(replayDriver == nil || replayDriver?.provider === provider,
                     "Replay driving must use the injected provider")
        self.provider = provider
        self.inputConfiguration = inputConfiguration
        self.configuration = configuration
        self.encounters = encounters
        self.replayDriver = replayDriver
        self.hostNow = hostNow
        self.recoveryPlanner = recoveryPlanner
        self.liveRoundPlanner = liveRoundPlanner
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
        liveReadiness = replayDriver == nil ? LaserLiveReadiness(policy: liveTimingPolicy, roster: inputConfiguration.roster) : nil
        precondition(setupControls == nil || (replayDriver == nil && setupControls?.provider === provider),
                     "Setup must control the injected live provider")
        setup = setupControls.map { LaserSessionSetup(controls: $0, generation: inputConfiguration.sessionGeneration,
                                                      roster: inputConfiguration.roster) }
    }

    convenience init(liveProvider: BodyInputService, inputConfiguration: BodyInputConfiguration,
                     configuration: LaserRoundConfiguration? = nil, encounters: [LaserEncounter] = [],
                     liveRoundPlanner: (@MainActor (BodyInputContext, [PlayerID: PlayerCalibration]) throws -> LaserLiveWristRoundPlan)? = nil,
                     automaticSetup: Bool = false) {
        self.init(provider: liveProvider, inputConfiguration: inputConfiguration, configuration: configuration,
                  encounters: encounters, setupControls: LaserLiveSetupControls(service: liveProvider),
                  liveRoundPlanner: liveRoundPlanner, automaticSetup: automaticSetup)
    }

    func start() async throws {
        guard phase == .idle else { return }
        phase = .starting
        #if DEBUG
        if automaticSetup { setupTimeline.mark("setup opened", at: hostNow()) }
        #endif
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
                #if DEBUG
                if automaticSetup { setupTimeline.mark("camera running", at: hostNow()) }
                #endif
                if automaticSetup, automaticSetupTimer {
                    // Status reads and controls run here, outside the provider's status callback.
                    setupTask = Task { @MainActor [weak self] in
                        while !Task.isCancelled {
                            try? await Task.sleep(for: LaserAutomaticSetupPolicy.tick)
                            guard let self, self.lifetime == token else { return }
                            self.advanceSetupAutomatically()
                        }
                    }
                }
                inputTask = Task { @MainActor [weak self] in
                    guard self?.lifetime == token else { return }
                    for await packet in stream {
                        guard !Task.isCancelled, let self, self.lifetime == token else { return }
                        self.acceptSetupSnapshot(packet)
                    }
                    guard let self, self.lifetime == token else { return }
                    self.inputStreamEnded = true
                    self.latestSnapshot = nil
                    debugRestart("stream ended")
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
        setupTask?.cancel(); setupTask = nil
        let hadLifetime = lifetime != nil
        wristDiamonds = nil
        lifetime = nil
        phase = .finished
        liveFrameAttachment = nil
        liveFrameHostReady = false
        setup?.close()
        debugRestart("stop")
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
        #if DEBUG
        // Every jump-phase change with the soles and head behind it (the 1 Hz line misses jumps).
        for (player, sample) in packet.players where lastLoggedJump[player] != "\(sample.jumpState.phase)" {
            lastLoggedJump[player] = "\(sample.jumpState.phase)"
            let g = sample.geometry
            func v(_ m: EstimatedScalar) -> String { m.value.map { String(format: "%.2f", $0) } ?? "\(m.validity)" }
            print("[LaserJump] \(player.rawValue) frame \(packet.frameID) → \(sample.jumpState.phase) · soles \(v(g.leftSoleY))/\(v(g.rightSoleY)) head \(v(g.crownY))")
        }
        #endif
        if let context = inputContext {
            do {
                try liveReadiness?.observe(packet, context: context,
                    bindingConfirmed: setup?.hasConfirmedReliablePair == true && setup?.canCancelCalibration == false,
                    at: hostNow())
            } catch { debugRestart("observe threw: \(error)"); liveReadiness?.requireRestart() }
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
            debugRestart("installed context changed: was \(String(describing: installedLiveWristContext)) now \(String(describing: context))")
            liveReadiness?.requireRestart() // even a pre-countdown cutover needs a new setup/plan
        }
        #if DEBUG
        let readinessNow = "\(String(describing: liveReadiness?.phase))"
        // Blocked → blocked (one blocker for another, every frame while calibrating) is noise.
        if readinessNow != lastLoggedReadiness,
           !(readinessNow.contains("blocked") && (lastLoggedReadiness?.contains("blocked") ?? false)) {
            print(String(format: "[LaserState] t %.3f · readiness %@ → %@ · session %@ · setup %@ · binding %@", ProcessInfo.processInfo.systemUptime,
                         lastLoggedReadiness ?? "-", readinessNow, "\(phase)", "\(String(describing: setup?.phase))",
                         setup?.hasConfirmedReliablePair == true ? "confirmed" : "NOT confirmed"))
        }
        lastLoggedReadiness = readinessNow
        #endif
        guard liveReadiness != nil else { return } // Replay never reads a host-time source.
        do {
            let time = hostNow()
            try liveReadiness?.updateContext(context, at: time)
            if setup != nil, setup?.hasConfirmedReliablePair != true {
                latestSnapshot = nil
                if !soloRoundToleratesTrackingLoss { try liveReadiness?.invalidateBinding(at: time) }
            }
        }
        catch { debugRestart("status read threw: \(error)"); liveReadiness?.requireRestart() }
        #if DEBUG
        // Every P1/P2 tracker change, with the people Vision sees (iPad bystander diagnosis: which
        // slot went uncertain, lost or identity-ambiguous, and why).
        if let setup, let latest = setup.diagnosticControls.tracking.latest {
            for player in inputConfiguration.roster {
                let slot = latest[player]
                let text = "\(slot.state.rawValue)/\(slot.reason.rawValue)\(slot.requiresRebind ? " REBIND" : "")"
                if lastLoggedSlot[player] != text {
                    print("[LaserTrackPair] \(player.rawValue) \(lastLoggedSlot[player] ?? "-") → \(text) · people \(setup.diagnosticControls.peopleInView ?? -1) · session \(phase)")
                    lastLoggedSlot[player] = text
                }
            }
        }
        #endif
        if setup?.phase == .restartRequired {
            // DEBUG Solo Test: losing P1 (same camera source and context) neither pauses nor ends
            // the round; P1's evidence stays UNAVAILABLE until B2 tracks them again.
            if soloRoundToleratesTrackingLoss, context != nil, context == installedLiveWristContext {
                // DEBUG Solo Test round: kept running (P1's evidence is UNAVAILABLE meanwhile).
            } else if game != nil, summary == nil, let context, context.isActive,
                      context.sessionGeneration == inputConfiguration.sessionGeneration {
                // (A changed context still restarts: above, and in readiness once its clock runs.)
                // A begun round on the same camera source whose identity the tracker can no longer
                // vouch for (iPad, 12 November 2026: a bystander or a long occlusion): PAUSE and keep
                // the round (clock, hearts, score, encounters, calibrations), never guess who is who.
                // If the tracker confirms the same pair again, the round resumes by itself; if it
                // cannot (a latched identity needs a new binding), the players choose Restart.
                #if DEBUG
                if !awaitsIdentityRecovery {
                    print("[LaserInterrupt] co-op identity lost mid-round → PAUSED (round kept) · " + inputConfiguration.roster.map {
                        "\($0.rawValue) \(lastLoggedSlot[$0] ?? "-")" }.joined(separator: ", ")
                        + " · people \(setup?.diagnosticControls.peopleInView ?? -1)")
                }
                #endif
                do { try liveReadiness?.requireIdentityRecovery(at: hostNow()) }
                catch { debugRestart("identity pause threw: \(error)"); liveReadiness?.requireRestart() }
            } else {
                #if DEBUG
                if game != nil, summary == nil {
                    // Only a changed or lost camera source / input context still ends a begun round.
                    print("[LaserInterrupt] round ended: input source/context changed · " + inputConfiguration.roster.map {
                        "\($0.rawValue) \(lastLoggedSlot[$0] ?? "-")" }.joined(separator: ", ")
                        + " · people \(setup?.diagnosticControls.peopleInView ?? -1)")
                }
                #endif
                debugRestart("setup restartRequired"); liveReadiness?.requireRestart()
            }
        }
        #if DEBUG
        if inputConfiguration.soloPlayer != nil, let slot = setup?.diagnosticControls.tracking.latest?[.player1] {
            if slot.requiresRebind, !debugSoloTrackingLost {
                debugSoloTrackingLost = true
                print("[LaserSolo] P1 tracking lost: no restart; evidence UNAVAILABLE until re-linked")
            } else if debugSoloTrackingLost, controls(trackingP1IsLive: setup) {
                debugSoloTrackingLost = false
                print("[LaserSolo] P1 re-linked (only person in view): tracking resumed with the same calibration")
            }
        }
        #endif
        installAcceptedLivePlanIfReady()
        if synchronizeLive { synchronizeLiveGame(allowAdvance: false) }
    }

    /// Once setup has accepted both calibrations, install the live round built from them.
    /// Runs inside the status read, only once per session; failure leaves the round blocked.
    private func installAcceptedLivePlanIfReady() {
        guard let liveRoundPlanner, !installingLivePlan, configuration == nil, !isReplay, lifetime != nil,
              phase == .awaitingSetup, setup?.phase == .awaitingGameplayReadiness,
              let context = provider.currentContext, context.isActive else { return }
        installingLivePlan = true
        defer { installingLivePlan = false }
        do {
            try installLiveWristRound(liveRoundPlanner(context, provider.acceptedCalibrations))
            livePlanError = nil
        } catch { livePlanError = String(describing: error) }
    }

    /// One step of the automatic onboarding (the setup tick calls this; tests call it directly).
    /// Searching → linked → upright prompt → calibrating → accepted → plan → countdown. Each
    /// step uses the existing setup command, so binding, freshness, identity and anatomy rules
    /// are unchanged; a step whose conditions do not hold simply waits or reports why.
    func advanceSetupAutomatically() {
        guard automaticSetup, !isReplay, lifetime != nil, let setup else { return }
        let now = hostNow()
        setup.refresh()
        #if DEBUG
        let controls = setup.diagnosticControls
        if let latest = controls.tracking.latest {
            for player in PlayerID.allCases where latest[player].state == .tracking {
                setupTimeline.mark("\(player.rawValue) tracked", at: now)
            }
        }
        if (controls.peopleInView ?? 0) >= 1 { setupTimeline.mark("first person in view", at: now) }
        if (controls.peopleInView ?? 0) >= 2 { setupTimeline.mark("both people in view", at: now) }
        #endif
        switch setup.phase {
        case .awaitingBinding:
            if provider.currentContext?.isActive == true { try? setup.beginBinding() }
        case .confirmPlayers:
            if (try? setup.confirmPlayers()) != nil {
                #if DEBUG
                setupTimeline.mark("players linked", at: now)
                #endif
            }
        case .awaitingCalibration:
            guard presence.attempts < LaserAutomaticSetupPolicy.maximumAttempts else { break }
            // The players are asked to stand still and upright BEFORE any sample is taken.
            if let start = uprightPromptStart {
                if now - start >= LaserAutomaticSetupPolicy.uprightPrompt, (try? setup.requestCalibration(id: UUID())) != nil {
                    uprightPromptStart = nil; presence.attempts += 1
                    #if DEBUG
                    setupTimeline.mark("calibration started", at: now, detail: "attempt \(presence.attempts)")
                    #endif
                }
            } else { uprightPromptStart = now }
        case .reviewCandidate:
            if let id = setup.candidateIDForConfirmation, (try? setup.confirmCandidate(id: id)) != nil {
                #if DEBUG
                logCalibration(accepted: true, at: now)
                #endif
            }
        case .blocked:
            // A failed attempt: show why, then try again by itself a limited number of times.
            if retryAt == nil {
                presence.lastIssue = setup.diagnosticControls.calibration.players.values.compactMap(\.latestIssue).first
                    ?? Self.issue(in: setup.diagnosticReason)
                #if DEBUG
                logCalibration(accepted: false, at: now)
                #endif
                retryAt = now + LaserAutomaticSetupPolicy.retryDelay
            } else if let at = retryAt, now >= at, presence.attempts < LaserAutomaticSetupPolicy.maximumAttempts {
                retryAt = nil
                setup.cancelCalibration()
            }
        default:
            break
        }
        if setup.phase != .awaitingCalibration { uprightPromptStart = nil }
        if case .blocked = setup.phase {} else { retryAt = nil }
        #if DEBUG
        // While searching for the pair: who Vision sees and why the tracker has not linked, every 2 s.
        if setup.phase == .binding || setup.phase == .awaitingBinding || setup.phase == .waitingForReliablePair,
           now - lastSearchLog >= 2 {
            lastSearchLog = now
            let controls = setup.diagnosticControls
            let people = controls.debugPeople.map { p in
                String(format: "x %.2f sh %.2f/%.2f hip %.2f/%.2f", p.x, p.core[0], p.core[1], p.core[2], p.core[3])
            }
            let slots = PlayerID.allCases.map { player in
                controls.tracking.latest.map { "\(player.rawValue) \($0[player].state.rawValue)/\($0[player].reason.rawValue)" } ?? "\(player.rawValue) -"
            }
            print("[LaserSetupSearch] \(setup.phase) armed \(controls.tracking.requestID != nil) · \(controls.debugVision) · people \(people.count): \(people.joined(separator: " | ")) · \(slots.joined(separator: ", "))")
        }
        // One console line whenever a player's refusal reason changes (no image data).
        for player in PlayerID.allCases {
            let p = setup.diagnosticControls.calibration.players[player]
            let issue = p?.latestIssue?.rawValue ?? (p == nil ? "-" : "ok")
            if lastLoggedIssue[player] != issue {
                lastLoggedIssue[player] = issue
                let d = p?.last
                print(String(format: "[LaserSetupSample] %@ %@ window %d/%d · head %@ · soles %@ · ankles apart %@",
                    player.rawValue, issue, p?.samples ?? 0, StandingCollectionPolicyV1.sampleCount,
                    d?.crownSeen == true ? "seen" : d?.crown?.rawValue ?? "-",
                    d?.solesSeen == true ? "seen" : d?.soles?.rawValue ?? "-",
                    d?.ankleSeparationShare.map { String(format: "%.2f of body", $0) } ?? "-"))
            }
            // Every sample (not only changes): the raw numbers behind the reason.
            if let d = setup.diagnosticControls.calibration.players[player]?.last, d.frameID != lastLoggedFrame[player] {
                lastLoggedFrame[player] = d.frameID
                func c(_ j: BodyJoint) -> String { String(format: "%.2f", d.confidence[j] ?? 0) }
                let ranges: [String] = (p?.moveRangePixels ?? []).map { String(format: "%.1f", $0) }
                let stabilityText: String = " · window \(p?.samples ?? 0) range head/soles px " + ranges.joined(separator: "/")
                print("[LaserSetupJoints] \(player.rawValue) frame \(d.frameID) · vision bodies \(d.visionBodies) · mask \(d.maskQuality) regions \(d.maskRegions)"
                    + " · nose \(c(.nose)) eyes \(c(.leftEye))/\(c(.rightEye)) ears \(c(.leftEar))/\(c(.rightEar)) neck \(c(.neck))"
                    + " · hips \(c(.leftHip))/\(c(.rightHip)) knees \(c(.leftKnee))/\(c(.rightKnee)) ankles \(c(.leftAnkle))/\(c(.rightAnkle))"
                    + " · head \(d.crownSeen ? "seen" : d.crown?.rawValue ?? "-") soles \(d.solesSeen ? "seen" : d.soles?.rawValue ?? "-")"
                    + (d.bodyHeightPixels.map { String(format: " · body %.0f px", $0) } ?? "")
                    + String(format: " · head-top above nose %@ [%.2f–%.2f] · foot height %@ [≤%.2f] · feet gap filled %@",
                        d.crownAboveNose.map { String(format: "%.3f", $0) } ?? "-",
                        AnatomicalCandidatePolicyV1.minimumCrownAboveNoseShare, AnatomicalCandidatePolicyV1.maximumCrownAboveNoseShare,
                        d.footHeight.map { String(format: "%.3f", $0) } ?? "-",
                        AnatomicalCandidatePolicyV1.maximumFootHeightShare,
                        d.feetGapFilled.map { String(format: "%.2f", $0) } ?? "-")
                    + stabilityText)
            }
        }
        #endif
        presence.promptingUpright = uprightPromptStart != nil
        presence.willRetry = presence.attempts < LaserAutomaticSetupPolicy.maximumAttempts
        refreshPresence()
        // Both references accepted, the round planned and the scene drawing: count down.
        if canStartLiveRound, !countdownRequested, (try? beginLiveCountdown()) != nil {
            #if DEBUG
            setupTimeline.mark("countdown", at: now)
            #endif
        }
        #if DEBUG
        // Once a second during the round: the live evidence the judge would use.
        if phase == .running || phase == .countdown || phase == .paused, now - lastSearchLog >= 1 {
            lastSearchLog = now
            for player in inputConfiguration.roster {
                let s = latestSnapshot?.players[player]
                func v(_ e: EstimatedScalar?) -> String { e.map { $0.validity == .valid ? String(format: "%.2f", $0.value ?? 0) : "\($0.validity)" } ?? "-" }
                // Per stage (iPad co-op diagnosis): tracker slot, packet age and status, readiness.
                let slot = setup.diagnosticControls.tracking.latest?[player]
                let age = latestSnapshot.map { String(format: "%.0f ms", (now - $0.capturedAt) * 1000) } ?? "-"
                print("[LaserLive] \(phase) readiness \(String(describing: liveReadiness?.phase)) · \(player.rawValue) head \(v(s?.geometry.crownY)) wrists \(v(s?.geometry.leftWristY))/\(v(s?.geometry.rightWristY)) soles \(v(s?.geometry.leftSoleY))/\(v(s?.geometry.rightSoleY)) jump \(s.map { "\($0.jumpState.phase)" } ?? "-") · health \(state?.teamHealth ?? -1) score \(state?.teamScore ?? -1)"
                    + " · track \(slot.map { "\($0.state.rawValue)/\($0.reason.rawValue)\($0.requiresRebind ? " REBIND" : "")" } ?? "-")"
                    + " · sample \(s.map { "\($0.trackingStatus)" } ?? "-") age \(age) · blocker \(liveReadiness?.blocker.map { "\($0)" } ?? "none") skipped \(liveReadiness?.skippedFrames ?? 0)")
            }
        }
        if hasLiveRoundPlan { setupTimeline.mark("round planned", at: now) }
        if phase == .running { setupTimeline.mark("gameplay running", at: now) }
        #endif
    }

    /// DEBUG: why a live session had to restart (no-op in Release).
    private func debugRestart(_ reason: @autoclosure () -> String) {
        #if DEBUG
        print("[LaserSetupRestart] \(reason())")
        #endif
    }

    /// Players asked to try again after the automatic attempts ran out.
    func retryCalibrationManually() {
        guard let setup else { return }
        presence.attempts = 0; retryAt = nil; uprightPromptStart = nil
        setup.cancelCalibration()
        advanceSetupAutomatically()
    }

    private func refreshPresence() {
        guard let setup else { return }
        let controls = setup.diagnosticControls
        presence.peopleInView = controls.peopleInView ?? presence.peopleInView
        let progress = controls.calibration
        let context = provider.currentContext
        presence.players = presence.players.filter { inputConfiguration.roster.contains($0.key) }
        for player in inputConfiguration.roster {
            if context?.calibrationRevisions[player] != nil {
                presence.players[player] = .ready
            } else if setup.canCancelCalibration, let value = progress.players[player] {
                presence.players[player] = .calibrating(
                    progress: Double(value.samples) / Double(StandingCollectionPolicyV1.sampleCount), issue: value.latestIssue)
            } else if setup.hasConfirmedReliablePair || controls.tracking.latest?[player].state == .tracking {
                presence.players[player] = setup.canCancelCalibration ? .calibrating(progress: 0, issue: nil) : .linked
            } else {
                presence.players[player] = .searching
            }
        }
    }

    private static func issue(in reason: String) -> StandingSampleIssue? {
        StandingSampleIssue.allCases.first { reason.contains("(\($0.rawValue))") }
    }

    #if DEBUG
    private func logCalibration(accepted: Bool, at now: Double) {
        guard let setup else { return }
        let progress = setup.diagnosticControls.calibration
        let detail = PlayerID.allCases.map { player -> String in
            let p = progress.players[player] ?? .init()
            let reasons = p.rejected.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" }
            return "\(player.rawValue): accepted \(p.accepted), window \(p.samples), refused [\(reasons.joined(separator: ","))], "
                + String(format: "spread %.1f px, mask rows %@", p.spreadPixels, p.maskRows.map(String.init) ?? "?")
        }.joined(separator: " | ")
        setupTimeline.mark(accepted ? "calibration accepted" : "calibration attempt \(presence.attempts) failed", at: now, detail: detail)
    }
    #endif

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
        configuration = plan.configuration
        // A director registers its encounters as the round reaches them; a fixed plan registers all.
        encounters = plan.director == nil ? plan.encounters : []
        liveDirector = plan.director
        wristDiamondConfiguration = plan.diamonds; installedLiveWristContext = context
        liveReadiness = LaserLiveReadiness(policy:plan.timing, roster: inputConfiguration.roster)
        #if DEBUG
        liveReadiness?.continuesWithoutEvidence = inputConfiguration.soloPlayer != nil
        #endif
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

    func collectAvatarDiamondContacts(_ contacts: [UUID: Set<PlayerID>], frameHost token: LaserLiveFrameAttachment) {
        guard !contacts.isEmpty, lifetime != nil, liveFrameAttachment == token, phase == .running,
              liveReadiness?.isClockHeld == false, let context = inputContext,
              context == provider.currentContext, context.isActive,
              var stagedGame = game, !stagedGame.isPaused, stagedGame.roundOutcome == nil,
              stagedGame.roundPhase == .activity || stagedGame.roundPhase == .diamondTime,
              var stagedWrist = wristDiamonds else { return }
        do {
            try stagedWrist.receiveBodyContacts(contacts, context: context, atHostTime: hostNow(), game: &stagedGame)
            guard stagedGame.diamondsCollected != game?.diamondsCollected else { return }
            game = stagedGame
            wristDiamonds = stagedWrist
            collectLiveState()
        } catch {
            debugRestart("avatar diamond contact rejected: \(error)")
        }
    }

    func detachLiveFrameHost(_ token: LaserLiveFrameAttachment) {
        guard liveFrameAttachment == token else { return }
        liveFrameAttachment = nil
        liveFrameHostReady = false
        guard lifetime != nil else { return }
        do { try liveReadiness?.invalidatePresentation(at: hostNow()) }
        catch { debugRestart("pause threw: \(error)"); liveReadiness?.requireRestart() }
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
        catch { debugRestart("continue threw: \(error)"); liveReadiness?.requireRestart() }
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
        catch { debugRestart("detach host threw: \(error)"); liveReadiness?.requireRestart() }
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
                        let planned: [LaserEncounter]?
                        if let recoveryPlanner { planned = try recoveryPlanner(request) }
                        else { planned = try liveDirector?.recover(request) }
                        guard let replacement = planned else {
                            recoveryNeedsPlan = true; phase = .paused; return
                        }
                        try LaserLiveRecovery.validate(replacement, request: request, configuration: configuration,
                                                       boundary: liveDirector?.vaultBoundary)
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
                guard let configuration, let context = inputContext, provider.currentContext == context,
                      setup?.hasConfirmedReliablePair == true || soloRoundToleratesTrackingLoss else { return }
                if game == nil {
                    var initial = try LaserGame(configuration: configuration, context: context, historyCapacityPerPlayer: 120)
                    #if DEBUG
                    initial.soloPracticePlayer = inputConfiguration.soloPlayer
                    #endif
                    for encounter in encounters { try initial.register(encounter) }
                    game = initial
                    finalVaultEntry = nil; finalVaultStamp = nil
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
                    var consumer = try LaserWristDiamondConsumer(configuration: plan, context: context,
                        lifetime: token, afterCapturedAt: hostNow(), planner: wristDiamonds?.replacementPlanner)
                    if let vault = liveVault, game?.roundPhase == .vault, let current = game {
                        try consumer.openVault(id: vault.id, zones: vault.zones, game: current, atHostTime: hostNow())
                    }
                    wristDiamonds = consumer
                }
                phase = .running
                var stagedGame = game!, stagedWrist = wristDiamonds, stagedDirector = liveDirector
                var stagedRegistered: [LaserEncounter] = [], stagedVault = liveVault
                let revision = inputRevision
                // Planned work that has come due: each at its own exact game time, in order.
                // The director's own state (minute start, planner) is kept even when nothing is due.
                if var director = stagedDirector {
                    while let due = try director.nextDue(through: readiness.gameTime, game: stagedGame) {
                        try stagedGame.advance(to: max(stagedGame.gameTime, due.time))
                        guard stagedGame.roundOutcome == nil else { break }
                        switch due.action {
                        case .register(let encounter):
                            try stagedGame.register(encounter); stagedRegistered.append(encounter)
                        case .normalDiamond(let spawn, let boundary):
                            try stagedGame.spawnNormalDiamonds([spawn], beforeVaultAt: boundary)
                        case .openVault(let id, let zones):
                            try stagedGame.openVault(id: id, at: stagedGame.gameTime)
                            try stagedWrist?.openVault(id: id, zones: zones, game: stagedGame, atHostTime: hostNow())
                            stagedVault = (id, zones)
                        }
                        try stagedWrist?.refresh(game: stagedGame, context: context, atHostTime: hostNow())
                    }
                    stagedDirector = director
                }
                // Receive before inclusive advance: equal-deadline arrivals remain eligible.
                if let packet, let captured = liveReadiness?.capturedGameTime(for: packet) {
                    try stagedGame.receive(packet, capturedGameTime: captured, arrivedAt: readiness.gameTime)
                    let shifts = vaultZoneShifts(for: packet)
                    try stagedWrist?.receive(packet, context: context, atHostTime: hostNow(),
                        capturedGameTime: captured, arrivedGameTime: readiness.gameTime, game: &stagedGame,
                        vaultZoneShifts: shifts)
                    #if DEBUG
                    if let readout = stagedWrist?.lastVaultReadout, !readout.isEmpty {
                        logVaultContact(readout, shifts: shifts, pressed: stagedGame.vault?.buttons ?? [:], at: packet.capturedAt)
                    }
                    #endif
                }
                #if DEBUG
                // DEBUG Solo Test tap fallback: P1's own vault button, at this frame's game time,
                // through the same domain command a wrist contact uses (logged, never automatic).
                if let button = debugPendingVaultPress {
                    debugPendingVaultPress = nil
                    if inputConfiguration.soloPlayer == .player1, stagedGame.roundPhase == .vault,
                       let vault = stagedGame.vault, !vault.opened,
                       let revision = context.calibrationRevisions[.player1] {
                        let added = try stagedGame.touchVaultBatch(id: vault.id, contacts: [LaserVaultContact(
                            playerID: .player1, button: button, calibrationRevision: revision)],
                            generation: context.sessionGeneration, at: readiness.gameTime)
                        print("[LaserSolo] DEBUG tap · vault \(vault.id.uuidString.suffix(2)) \(button.rawValue) → \(added > 0 ? "pressed" : "no change")")
                    }
                }
                // DEBUG Solo Test "Skip to Diamond Time", at this frame's game time, so the Diamond
                // Time diamonds below are placed in this same frame, as after a final vault.
                if debugPendingSkipToDiamondTime {
                    debugPendingSkipToDiamondTime = false
                    if let skipped = try stagedGame.debugSkipToDiamondTime(at: readiness.gameTime) {
                        debugSkips.append(DebugSkip(gameTime: stagedGame.gameTime, withdrawnTargets: skipped.withdrawnTargets,
                                                    closedDiamonds: skipped.closedDiamonds))
                        print(String(format: "[LaserSkip] to Diamond Time at game %.2f s · withdrew %d laser targets (not judged, not scored), closed %d diamonds",
                                     stagedGame.gameTime, skipped.withdrawnTargets, skipped.closedDiamonds))
                    }
                }
                #endif
                // The final vault unlocks Diamond Time at the opening press: place its targets then.
                if stagedGame.roundPhase == .diamondTime, !stagedGame.hasStartedDiamondTimeDiamonds,
                   var director = stagedDirector {
                    let spawns = try director.diamondTimeSpawns(at: stagedGame.gameTime,
                        deadline: stagedGame.gameTime + configuration.diamondTimeDuration)
                    try stagedGame.startDiamondTimeDiamonds(spawns)
                    stagedWrist?.adoptPlanner(director.planner)
                    stagedDirector = director
                }
                if stagedGame.roundPhase != .vault { stagedVault = nil }
                try stagedGame.advance(to: readiness.gameTime)
                try stagedWrist?.refresh(game: stagedGame, context: context, atHostTime: hostNow())
                // No suspension/callback between this producer recheck and staged assignment.
                guard lifetime != nil, inputRevision == revision, provider.currentContext == context else { return }
                game = stagedGame; wristDiamonds = stagedWrist; liveDirector = stagedDirector
                encounters.append(contentsOf: stagedRegistered); liveVault = stagedVault
                collectLiveState()
                if summary != nil { phase = .finished; finishLiveInput(); return }
                try advanceFinalVaultEntry()
                if !soloRoundToleratesTrackingLoss, encounters.contains(where: { encounter in
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
            debugRestart("synchronize threw: \(error)")
            liveReadiness?.requireRestart()
            game?.exit(outcome: .technicalInterruption)
            collectLiveState()
            phase = .restartRequired
            finishLiveInput()
        }
    }

    /// The final vault entry plays on held game time, from the frame Diamond Time is unlocked
    /// (final vault or DEBUG skip): Diamond Time's active seconds start once the team is inside,
    /// and no wrist evidence from before the release can collect a diamond. Only running host
    /// time advances the script; after a pause it holds the clock again where it stopped.
    private func advanceFinalVaultEntry() throws {
        guard let game, game.roundPhase == .diamondTime, game.roundOutcome == nil else { return }
        let now = hostNow()
        if finalVaultEntry == nil {
            finalVaultEntry = LaserFinalVaultEntry(roster: inputConfiguration.roster)
            print(String(format: "[LaserFinalVault] entry starts at game %.2f s · %d mascot(s), %.2f s held",
                         game.gameTime, finalVaultEntry!.timeline.jumpers.count, finalVaultEntry!.timeline.total))
        }
        guard var entry = finalVaultEntry, !entry.isComplete else { return }
        guard liveReadiness?.isClockHeld == true else {
            try liveReadiness?.holdClock()
            wristDiamonds?.invalidate(atHostTime: now)
            finalVaultStamp = now
            return
        }
        entry.advance(by: now - (finalVaultStamp ?? now))
        finalVaultStamp = now
        finalVaultEntry = entry
        guard entry.isComplete else { return }
        try liveReadiness?.releaseClock(at: now)
        // Fresh outside→inside entries only: the wrists' baseline restarts at the release.
        wristDiamonds?.invalidate(atHostTime: now)
        print(String(format: "[LaserFinalVault] inside · Diamond Time starts at game %.2f s", game.gameTime))
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
        if let more = game?.drainEvents() {
            events.append(contentsOf: more)
            #if DEBUG
            for event in more { if case .targetJudged(let id, let player, let verdict) = event.kind,
                let target = encounters.first(where: { $0.id == id })?.targets.first(where: { $0.playerID == player }) {
                let sample = latestSnapshot?.players[player]
                print(String(format: "[LaserVerdict] %@ %@ beam %.2f–%.2f → %@ · head %@ soles %@/%@ jump %@",
                    player.rawValue, target.requiredMove.rawValue, target.beam.lowerY, target.beam.upperY, "\(verdict)",
                    sample?.geometry.crownY.value.map { String(format: "%.2f", $0) } ?? "-",
                    sample?.geometry.leftSoleY.value.map { String(format: "%.2f", $0) } ?? "-",
                    sample?.geometry.rightSoleY.value.map { String(format: "%.2f", $0) } ?? "-",
                    sample.map { "\($0.jumpState.phase)" } ?? "-"))
            } }
            #endif
        }
        if summary == nil { summary = game?.summary }
        refresh(at: game?.gameTime ?? 0)
    }

    private func finishLiveInput() {
        guard liveTerminationTask == nil else { return }
        setupTask?.cancel(); setupTask = nil
        wristDiamonds = nil
        lifetime = nil
        liveFrameAttachment = nil
        liveFrameHostReady = false
        setup?.close()
        debugRestart("finishLiveInput")
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
                for player in encounter.targets.map(\.playerID) {
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
