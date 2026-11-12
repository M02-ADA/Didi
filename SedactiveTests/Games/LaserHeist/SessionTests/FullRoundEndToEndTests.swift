import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// Autonomous end-to-end QA (12 November 2026): complete co-op live rounds through the REAL
/// coordinator, live round director, GameClock, readiness, wrist-contact consumer and game, with
/// the REAL scene presenter (gates, Final Vault, Diamond Time, mascots) applied from the
/// authoritative state every frame. Production timing: five 60 s minutes (`segmentLength` 60),
/// accelerated only by feeding host-clock frames faster than real time.
///
/// Input is SYNTHETIC and deterministic: body samples that clear each laser at its crossing, and
/// wrist points placed in each gate's contact zones. It proves the state machine and its
/// presentation, never physical detection quality.
@MainActor struct FullRoundEndToEndTests {
    struct RoundRecord {
        var countdownToRunning = false
        var gateOpenedAt: [Double] = []
        var gateSucceededAt: [Double] = []
        var diamondTimeStartedAt: Double?
        var entryHostSeconds = 0.0
        var diamondTimeEndedAt: Double?
        var score = 0
        var health = 0
        var collected = 0
        var generation = UUID()
    }

    @Test func threeConsecutiveFullCoopRoundsFromCalibrationToResults() async throws {
        var generations: Set<UUID> = []
        for round in 1...3 {
            let record = try await Self.playFullCoopRound(round: round)
            generations.insert(record.generation)
            print(String(format: "E2E round %d · gates opened at %@ · succeeded at %@ · Diamond Time %.2f→%.2f s (entry held %.2f host s) · score %d hearts %d diamonds %d",
                         round, record.gateOpenedAt.map { String(format: "%.2f", $0) }.joined(separator: "/"),
                         record.gateSucceededAt.map { String(format: "%.2f", $0) }.joined(separator: "/"),
                         record.diamondTimeStartedAt ?? -1, record.diamondTimeEndedAt ?? -1, record.entryHostSeconds,
                         record.score, record.health, record.collected))
        }
        #expect(generations.count == 3, "every Play Again is a fresh session")
    }

    /// Prolonged (non-identity) tracking loss mid-round: the round PAUSES with its GameClock, then
    /// the SAME session resumes (settle, countdown) with progress and hearts kept, and the first
    /// gate still opens at its 60 s game-time boundary: paused time is never spent.
    @Test func aSustainedTrackingLossPausesAndTheSameRoundResumes() async throws {
        let rig = try J07SessionRig(deferredPlan: true)
        try await rig.start(installDeferredPlan: false)
        let session = rig.session
        let calibrations = try LaserReplayScript.load().input.configuration.calibrations
        let complete = try LaserLiveWristRoundPlan.completeRound(context: rig.fixture.context,
            calibrations: calibrations, layout: rig.fixture.input.playerPlaneLayout, seed: 11)
        try session.installLiveWristRound(.init(expectedContext: complete.expectedContext,
            configuration: complete.configuration, encounters: complete.encounters,
            timing: .init(settlingDuration: 0.125, maximumEvidenceAge: 0.5, countdownDuration: 0.25, trackingGrace: 1),
            diamonds: complete.diamonds, director: complete.director))
        try await rig.finishStart()
        let generation = session.inputConfiguration.sessionGeneration
        var host = 0.625
        let configuration = try #require(session.configuration)
        func send(bad: String? = nil) async throws {
            host += 0.125
            try await rig.send(host, bad: bad, bodySamples: bad == nil
                ? try Self.clearingSamples(rig, configuration: configuration, layout: session.inputConfiguration.playerPlaneLayout) : nil)
        }
        // Into minute 1, between lasers (nothing judged is touched by the outage).
        for _ in 0..<80 { try await send() }
        let before = try #require(session.state)
        for _ in 0..<12 { try await send(bad: "unbound") } // 1.5 s without usable evidence
        #expect(session.phase == .paused && session.summary == nil && !session.awaitsIdentityRecovery)
        let paused = try #require(session.state)
        #expect(paused.gameTime < before.gameTime + 1.05, "the clock stopped within the 1 s grace")
        for _ in 0..<16 { try await send(bad: "unbound") } // still out: still paused, clock still
        #expect(session.phase == .paused && session.state?.gameTime == paused.gameTime)
        for _ in 0..<40 where session.phase != .running { try await send() } // back: settle, countdown
        #expect(session.phase == .running, "the same round resumes")
        #expect(session.inputConfiguration.sessionGeneration == generation)
        let resumed = try #require(session.state)
        #expect(resumed.missionProgress == before.missionProgress && resumed.teamHealth == before.teamHealth)
        #expect(abs(resumed.gameTime - paused.gameTime) < 0.3, "game time continues from the pause")
        for _ in 0..<800 where session.state?.phase == .activity { try await send() }
        let gate = try #require(session.state)
        #expect(gate.phase == .vault && gate.gameTime >= 60 - 1e-6 && gate.gameTime < 62,
                "gate 1 still at its 60 s boundary (game \(gate.gameTime))")
        await session.stop()
    }

    /// SYNTHETIC body samples for this frame: each player clears a laser crossing now (duck below
    /// it, or soles above it and airborne), and otherwise stands as calibrated.
    static func clearingSamples(_ rig: J07SessionRig, configuration: LaserRoundConfiguration,
                                layout: PlayerPlaneLayout) throws -> [PlayerID: PlayerBodySample] {
        let session = rig.session
        let gameTime = session.state?.gameTime ?? 0
        return try rig.fixture.players.mapValues { standing in
            let center = try EstimatedScalar(value: layout.centerX(for: standing.playerID), validity: .valid)
            let target = session.encounters.flatMap(\.targets).first {
                $0.playerID == standing.playerID && abs($0.crossingTime - gameTime) <= 0.25
            }
            guard let target else {
                let g = standing.geometry
                return PlayerBodySample(playerID: standing.playerID, calibrationRevision: standing.calibrationRevision,
                    trackingStatus: standing.trackingStatus, geometry: .init(crownY: g.crownY, leftWristY: g.leftWristY,
                        rightWristY: g.rightWristY, leftSoleY: g.leftSoleY, rightSoleY: g.rightSoleY, centerX: center),
                    jumpState: standing.jumpState)
            }
            let margin = configuration.clearanceMargin
            let upper = try EstimatedScalar(value: target.beam.lowerY - margin - 0.01, validity: .valid)
            let sole = try EstimatedScalar(value: target.beam.upperY + margin + 0.01, validity: .valid)
            return PlayerBodySample(playerID: standing.playerID, calibrationRevision: standing.calibrationRevision,
                trackingStatus: .reliable, geometry: target.requiredMove == .duck
                    ? .init(crownY: upper, leftWristY: upper, rightWristY: upper, leftSoleY: standing.geometry.leftSoleY,
                            rightSoleY: standing.geometry.rightSoleY, centerX: center)
                    : .init(crownY: standing.geometry.crownY, leftWristY: standing.geometry.leftWristY,
                            rightWristY: standing.geometry.rightWristY, leftSoleY: sole, rightSoleY: sole, centerX: center),
                jumpState: target.requiredMove == .jump ? .init(phase: .airborne, validity: .valid) : standing.jumpState)
        }
    }

    // MARK: - One complete co-op round

    static func playFullCoopRound(round: Int) async throws -> RoundRecord {
        var record = RoundRecord()
        // Calibration → countdown → running through the real setup gate and readiness.
        let rig = try J07SessionRig(deferredPlan: true)
        try await rig.start(installDeferredPlan: false)
        let session = rig.session
        let calibrations = try LaserReplayScript.load().input.configuration.calibrations
        let complete = try LaserLiveWristRoundPlan.completeRound(context: rig.fixture.context,
            calibrations: calibrations, layout: rig.fixture.input.playerPlaneLayout, seed: UInt64(round))
        let director = try #require(complete.director)
        #expect(director.segmentLength == 60, "production stage length")
        try session.installLiveWristRound(.init(expectedContext: complete.expectedContext,
            configuration: complete.configuration, encounters: complete.encounters,
            timing: .init(settlingDuration: 0.125, maximumEvidenceAge: 0.5, countdownDuration: 0.25, trackingGrace: 1),
            diamonds: complete.diamonds, director: complete.director))
        try await rig.finishStart()
        record.countdownToRunning = session.phase == .running
        record.generation = session.inputConfiguration.sessionGeneration
        let configuration = try #require(session.configuration)
        let startHealth = try #require(session.state?.teamHealth)

        // The presentation the players see, from the same authoritative state each frame.
        let scene = LaserScene()
        scene.installEnvironment(authored: nil)
        scene.installVaultDoor(await LaserScene.loadVaultDoorArtwork())
        scene.installDiamondArt(await LaserScene.loadDiamondArtwork())
        scene.installFinalVaultArt(await FinalVaultArt.load())
        let robots = RobotAvatarLayer(scene: scene, players: Set(PlayerID.allCases), templates: try await RobotAvatarLayer.sharedTemplates())
        scene.robotAvatars = robots
        let presenter = GameplayScenePresenter(scene: scene, configuration: configuration, encounters: session.plannedEncounters)
        let layout = session.inputConfiguration.playerPlaneLayout
        let display = LaserReplayPresentation.diamondDisplay(scene: scene, layout: layout)
        presenter.diamondTime.source = { [weak session] _ in
            guard let session else { return [] }
            return session.diamondStates.values.compactMap { state in
                guard case .diamondTime = state.lifetime,
                      let lane = PlayerID.allCases.first(where: { state.spawn.eligiblePlayers.contains($0) }),
                      let id = Int(state.spawn.id.uuidString.suffix(12), radix: 16) else { return nil }
                let collected: Bool
                switch state.outcome { case .collected: collected = true; case nil: collected = false; default: return nil }
                let shown = display(lane, state.spawn.position)
                return DiamondTimeDiamond(id: id, lane: lane, offsetX: shown.offsetX, heightAboveFloor: shown.height, collected: collected)
            }.sorted { $0.id < $1.id }
        }
        func render() {
            guard let state = session.state else { return }
            presenter.apply(state: state, events: session.events, snapshot: session.latestSnapshot,
                            upcomingVaultIn: session.liveVaultIn, finalVault: session.finalVaultEntry)
        }

        // Synthetic evidence: clear every laser at its crossing; wrists only where told.
        let outside = Dictionary(uniqueKeysWithValues: LaserContactHand.ordered.map { ($0, WristGameplayFixture.outside) })
        var hostTime = 0.625
        func send(_ points: [LaserContactHand: WristPlanePoint] = [:]) async throws {
            hostTime += 0.125
            let samples = try Self.clearingSamples(rig, configuration: configuration, layout: layout)
            try await rig.send(hostTime, points: points, bodySamples: samples)
            render()
        }

        // MARK: Five one-minute stages, each ending at its gate.
        var minuteStart = 0.0
        for gate in 0..<5 {
            for _ in 0..<800 where session.state?.phase == .activity { try await send() }
            let state = try #require(session.state)
            try #require(state.phase == .vault, "round \(round): gate \(gate + 1) reached")
            record.gateOpenedAt.append(state.gameTime)
            // The authoritative clock reaches the minute's 60 s boundary (lasers settle first).
            #expect(state.gameTime >= minuteStart + 60 - 1e-6 && state.gameTime < minuteStart + 62,
                    "round \(round): gate \(gate + 1) at \(state.gameTime), minute began \(minuteStart)")
            // HUD: earlier checkpoints done, this one current.
            let hud = GameplayHUDModel(state: state, events: session.events, configuration: configuration, activityDuration: 300)
            #expect(hud.markerStates == (0..<5).map { $0 < gate ? .completed : $0 == gate ? .current : .upcoming })
            #expect(hud.banner == .pressButtons && state.missionProgress == gate)
            // The gate is shown, its door at its stop.
            #expect(presenter.vault.diagnostics.reveals + presenter.vault.diagnostics.approaches >= gate + 1)
            #expect(scene.vaultDoorDepth != nil, "round \(round): gate \(gate + 1) door in the corridor")
            // Real button contact: outside first, then each button's zone, for both players.
            let zones = try #require(session.liveVaultZones)
            #expect(zones.count == 6 && Set(zones.map(\.playerID)) == Set(PlayerID.allCases))
            for button in LaserVaultButton.allCases {
                try await send(outside)
                let wrists = Dictionary(uniqueKeysWithValues: zones.filter { $0.button == button }.map {
                    (LaserContactHand(playerID: $0.playerID, wrist: .left), WristPlanePoint(x: $0.position.x, y: $0.position.y))
                })
                try await send(wrists)
            }
            let after = try #require(session.state)
            #expect(after.missionProgress == gate + 1, "round \(round): gate \(gate + 1) opened by its buttons")
            record.gateSucceededAt.append(after.gameTime)
            #expect(presenter.vault.diagnostics.opens == gate + 1, "round \(round): gate \(gate + 1) door shown opening")
            minuteStart = after.gameTime
            if gate < 4 {
                try await send()
                #expect(session.state?.phase == .activity, "round \(round): minute \(gate + 2) begins at once")
            }
        }

        // Every laser was registered once, judged once, and cleared (synthetic evidence clears).
        let ids = session.encounters.map(\.id)
        #expect(Set(ids).count == ids.count && ids.count == director.baseEncounters.count,
                "round \(round): \(ids.count) lasers, no duplicates or missing ones")
        let verdicts = session.events.compactMap { event -> Judgement? in
            if case .targetJudged(_, _, let j) = event.kind { j } else { nil }
        }
        #expect(verdicts.count == ids.count * 2 && verdicts.allSatisfy { if case .clear = $0 { true } else { false } })
        #expect(session.state?.teamHealth == startHealth, "no laser hit: hearts unchanged")

        // MARK: Final Vault entry (held GameClock), Lemon then Tangerine.
        let unlocked = try #require(session.state)
        try #require(unlocked.phase == .diamondTime, "round \(round): the fifth gate unlocks Diamond Time")
        record.diamondTimeStartedAt = unlocked.gameTime
        let entry = try #require(session.finalVaultEntry)
        #expect(entry.timeline.jumpers == [.player1, .player2] && !entry.isComplete)
        let hostAtEntry = hostTime
        var sawLemonFirst = false, sawTangerine = false, sawWall = false
        for _ in 0..<80 where session.finalVaultEntry?.isComplete == false {
            try await send()
            if case .entry = presenter.finalVault.stage { sawWall = sawWall || scene.root.findEntity(named: "finalVault.wall")?.isEnabled == true }
            let p1 = robots.scriptedMoves[.player1], p2 = robots.scriptedMoves[.player2]
            if (p1?.offset.y ?? 0) > 0.05, p2 == RobotAvatarLayer.ScriptedMove.none { sawLemonFirst = true }
            if (p2?.offset.y ?? 0) > 0.05 { sawTangerine = true }
            #expect(session.state?.gameTime == unlocked.gameTime, "the clock is held during the entry")
            if session.finalVaultEntry?.isComplete == false {
                #expect(presenter.diamondTime.floatingIDs.isEmpty, "no diamonds before the team is inside")
            }
            #expect(GameplayHUDModel(state: session.state!, events: session.events, configuration: configuration,
                                     activityDuration: 300, enteringFinalVault: true).banner == .none)
        }
        record.entryHostSeconds = hostTime - hostAtEntry
        #expect(session.finalVaultEntry?.isComplete == true, "round \(round): entry complete")
        #expect(sawWall, "round \(round): the vault wall was shown")
        #expect(sawLemonFirst, "round \(round): Lemon jumped while Tangerine waited")
        #expect(sawTangerine, "round \(round): Tangerine jumped")
        try await send()
        #expect(presenter.finalVault.stage == .inside(entry.timeline) && !scene.isCorridorShown, "inside the vault room")
        #expect(presenter.diamondTime.floatingIDs.count == 4, "Diamond Time diamonds shown")
        #expect(scene.vaultDoorDepth == nil || !scene.isCorridorShown, "no gate left in view")

        // MARK: Diamond Time: one real collection, no false ones, a held wrist scores once.
        let start = unlocked.gameTime
        let active = session.diamondStates.values.filter { $0.outcome == nil }.sorted { $0.spawn.id.uuidString < $1.spawn.id.uuidString }
        #expect(active.count == 4 && active.allSatisfy { $0.interactionDeadline == start + 10 })
        let target = try #require(active.first)
        let player = try #require(target.spawn.eligiblePlayers.first)
        let hand = LaserContactHand(playerID: player, wrist: .left)
        let scoreBefore = try #require(session.state?.teamScore)
        // An unreachable wrist (far from every diamond) collects nothing.
        try await send(outside)
        try await send([hand: WristGameplayFixture.outside])
        #expect(session.diamondsCollected == 0)
        try await send([hand: .init(x: target.spawn.position.x, y: target.spawn.position.y)])
        #expect(session.diamondsCollected == 1 && session.state?.teamScore == scoreBefore + 25, "exactly one award")
        for _ in 0..<3 { try await send([hand: .init(x: target.spawn.position.x, y: target.spawn.position.y)]) }
        #expect(session.diamondsCollected == 1 && session.state?.teamScore == scoreBefore + 25, "a held wrist scores once")
        #expect(GameplayHUDModel(state: session.state!, events: session.events, configuration: configuration,
                                 activityDuration: 300).banner == .retrieveDiamonds)

        // MARK: The authoritative deadline ends it; Results.
        for _ in 0..<200 where session.summary == nil { try await send() }
        let summary = try #require(session.summary, "round \(round): Results")
        record.diamondTimeEndedAt = summary.gameDuration
        #expect(summary.gameDuration == start + 10, "Diamond Time ends at its deadline")
        #expect(summary.outcome == .completed && summary.vaultsOpened == 5 && summary.diamondsCollected == 1)
        #expect(summary.teamScore == scoreBefore + 25)
        // A late camera sample after time is up awards nothing.
        let remaining = session.diamondStates.values.first { state in
            if case .diamondTime = state.lifetime, case .collected? = state.outcome { return false }
            if case .diamondTime = state.lifetime { return true }
            return false
        }
        if let late = remaining, let latePlayer = late.spawn.eligiblePlayers.first {
            _ = try? await rig.send(hostTime + 0.125, points: [LaserContactHand(playerID: latePlayer, wrist: .left):
                .init(x: late.spawn.position.x, y: late.spawn.position.y)])
        }
        #expect(session.summary == summary && session.diamondsCollected == 1, "late samples change nothing")
        record.score = summary.teamScore; record.health = session.state?.teamHealth ?? -1; record.collected = summary.diamondsCollected
        await session.stop()
        presenter.stop()
        robots.remove()
        return record
    }
}
