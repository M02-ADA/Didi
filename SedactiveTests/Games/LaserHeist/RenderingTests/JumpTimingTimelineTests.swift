import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// JUMP TIMING TIMELINE (iPad, 13 November 2026: JUMP timing felt wrong after the gate changes).
/// One complete co-op live round through the REAL coordinator, live director, GameClock, judge and
/// scene presenter (lasers, gates and their travel hold, mascots), sampled at 30 Hz. For every
/// target it records, on the one GameClock: warning, action cue, crossing, when its laser was first
/// shown, when its 3D gate turned warning and active, when the drawn laser met the players' plane,
/// the verdict, the mascot's jump and the gate travel holds.
///
/// Input is SYNTHETIC and has no camera latency: each player jumps a parabola (0.5 s airtime) with
/// its apex AT the crossing, or ducks around it; one jump is deliberately late. It measures the
/// presentation and judge timing, never Vision's capture latency or detection quality.
@MainActor struct JumpTimingTimelineTests {
    struct Row {
        var stage = 0
        var move: LaserMove = .jump
        var warning = 0.0, cue = 0.0, crossing = 0.0
        var shown: Double?, warned: Double?, active: Double?
        var visualCrossing: Double?
        var verdict: (time: Double, judgement: Judgement)?
        var late = false
        var mascotAirborneAtCrossing: Float?
        var mascotApex: Double?
        var mascotPeak: Float = 0
    }

    static let dt = 1.0 / 30
    static let airtime = 0.5
    static let lateBy = 0.4

    @Test func lasersCuesAndVerdictsAgreeOnTheGameClockBeforeAndAfterEveryGate() async throws {
        let rig = try J07SessionRig(deferredPlan: true)
        try await rig.start(installDeferredPlan: false)
        let session = rig.session
        let calibrations = try LaserReplayScript.load().input.configuration.calibrations
        let complete = try LaserLiveWristRoundPlan.completeRound(context: rig.fixture.context,
            calibrations: calibrations, layout: rig.fixture.input.playerPlaneLayout, seed: 7)
        try session.installLiveWristRound(.init(expectedContext: complete.expectedContext,
            configuration: complete.configuration, encounters: complete.encounters,
            timing: .init(settlingDuration: 0.125, maximumEvidenceAge: 0.5, countdownDuration: 0.25, trackingGrace: 1),
            diamonds: complete.diamonds, director: complete.director))
        try await rig.finishStart()
        let configuration = try #require(session.configuration)
        let layout = session.inputConfiguration.playerPlaneLayout

        let scene = LaserScene()
        scene.installEnvironment(authored: nil)
        scene.installVaultDoor(await LaserScene.loadVaultDoorArtwork())
        let references = calibrations.mapValues { AvatarReference(calibration: $0, layout: layout) }
        let robots = RobotAvatarLayer(scene: scene, players: Set(PlayerID.allCases), references: references,
                                      templates: try await RobotAvatarLayer.sharedTemplates())
        scene.robotAvatars = robots
        let presenter = GameplayScenePresenter(scene: scene, configuration: configuration, encounters: session.plannedEncounters)
        presenter.vault.reducesMotion = { false }
        presenter.vault.liveConsoles = { [weak robots] in robots?.consoles[$0] }
        let plane = scene.mapping.interactionPlaneZ
        // The mascots stand on the players' plane: the beam reaches them when it reaches the plane
        // (an offset of d metres would read as d / travelSpeed seconds early or late).
        for (player, robot) in robots.robots {
            let centre = robot.model.visualBounds(relativeTo: nil).center.z
            #expect(abs(centre - plane) < 0.02, "\(player): mascot centre \(centre), plane \(plane)")
        }

        var rows: [LaserTargetKey: Row] = [:]
        var lastZ: [LaserTargetKey: (time: Double, z: Float)] = [:]
        var gateSucceeded: [Double] = []
        var holds: [Double] = []
        var lateKey: LaserTargetKey?
        var hostTime = 0.625
        var offset: Double? // host − game (the clock never pauses here)
        let standing = rig.fixture.players

        func stage(of crossing: Double) -> Int { 1 + gateSucceeded.filter { $0 <= crossing }.count }

        /// SYNTHETIC body for the capture at game time `g`.
        func samples(at g: Double) throws -> [PlayerID: PlayerBodySample] {
            try standing.mapValues { s in
                let center = try EstimatedScalar(value: layout.centerX(for: s.playerID), validity: .valid)
                let geometry = s.geometry
                let floor = min(geometry.leftSoleY.value ?? 0, geometry.rightSoleY.value ?? 0)
                let height = (geometry.crownY.value ?? 1.7) - floor
                let near = session.encounters.compactMap { e -> (LaserTargetKey, LaserTarget)? in
                    guard let t = e.targets.first(where: { $0.playerID == s.playerID }), abs(t.crossingTime - g) <= 0.6 else { return nil }
                    return (LaserTargetKey(encounterID: e.id, attemptID: e.attemptID, playerID: s.playerID), t)
                }.min { abs($0.1.crossingTime - g) < abs($1.1.crossingTime - g) }
                var crown = geometry.crownY, lw = geometry.leftWristY, rw = geometry.rightWristY
                var ls = geometry.leftSoleY, rs = geometry.rightSoleY, jump = s.jumpState
                if let (key, target) = near {
                    if target.requiredMove == .duck, abs(target.crossingTime - g) <= 0.25 {
                        let low = try EstimatedScalar(value: target.beam.lowerY - configuration.clearanceMargin - 0.01, validity: .valid)
                        crown = low; lw = low; rw = low
                    } else if target.requiredMove == .jump {
                        // Apex at the crossing (or `lateBy` after it for the late player).
                        let late = key == lateKey ? Self.lateBy : 0
                        let tau = g - (target.crossingTime - Self.airtime / 2 + late)
                        let peak = target.beam.upperY + configuration.clearanceMargin + 0.06 - floor
                        let lift = tau > 0 && tau < Self.airtime ? 4 * peak * tau * (Self.airtime - tau) / (Self.airtime * Self.airtime) : 0
                        ls = try EstimatedScalar(value: (geometry.leftSoleY.value ?? 0) + lift, validity: .valid)
                        rs = try EstimatedScalar(value: (geometry.rightSoleY.value ?? 0) + lift, validity: .valid)
                        jump = .init(phase: lift > 0.03 * height ? .airborne : .grounded, validity: .valid)
                    }
                }
                return PlayerBodySample(playerID: s.playerID, calibrationRevision: s.calibrationRevision, trackingStatus: .reliable,
                    geometry: .init(crownY: crown, leftWristY: lw, rightWristY: rw, leftSoleY: ls, rightSoleY: rs, centerX: center),
                    jumpState: jump)
            }
        }

        func record() {
            guard let state = session.state else { return }
            let t = state.gameTime
            for encounter in state.encounters {
                for target in encounter.encounter.targets {
                    let key = LaserTargetKey(encounterID: encounter.encounter.id, attemptID: encounter.encounter.attemptID, playerID: target.playerID)
                    var row = rows[key] ?? Row(stage: stage(of: target.crossingTime), move: target.requiredMove,
                                               warning: target.warningTime, cue: Self.cueTime(target, configuration), crossing: target.crossingTime)
                    row.late = key == lateKey
                    if let hazard = presenter.hazard(for: key) {
                        if hazard.root.isEnabled || presenter.sharedBeams.contains(LaserTargetKey(encounterID: key.encounterID,
                            attemptID: key.attemptID, playerID: .player1)) {
                            row.shown = row.shown ?? t
                        }
                        if hazard.state == .warning { row.warned = row.warned ?? t }
                        if hazard.state == .active { row.active = row.active ?? t }
                        if Self.isPending(encounter.judgements[target.playerID]) {
                            let z = hazard.root.position.z
                            if let previous = lastZ[key], previous.z < plane, z >= plane, row.visualCrossing == nil {
                                row.visualCrossing = previous.time + (t - previous.time) * Double((plane - previous.z) / (z - previous.z))
                            }
                            lastZ[key] = (t, z)
                        }
                    }
                    if target.requiredMove == .jump, let lift = robots.robots[target.playerID]?.retargeter.lift,
                       abs(t - target.crossingTime) <= 0.6 {
                        if lift > row.mascotPeak { row.mascotPeak = lift; row.mascotApex = t }
                        if row.mascotAirborneAtCrossing == nil, t >= target.crossingTime { row.mascotAirborneAtCrossing = lift }
                    }
                    rows[key] = row
                }
            }
        }

        var lastTravel = presenter.travelDistance
        var holding: Double?
        func send(_ points: [LaserContactHand: WristPlanePoint] = [:]) async throws {
            hostTime += Self.dt
            let g = offset.map { hostTime - $0 } ?? (session.state?.gameTime ?? 0)
            try await rig.send(hostTime, points: points, bodySamples: try samples(at: g))
            guard let state = session.state else { return }
            if offset == nil, state.phase == .activity { offset = hostTime - state.gameTime }
            presenter.apply(state: state, events: session.events, snapshot: session.latestSnapshot,
                            upcomingVaultIn: session.liveVaultIn, finalVault: session.finalVaultEntry)
            // A gate's travel hold: activity frames in which the corridor did not move.
            // Measured from the gate's success (the last press), the start of the next minute.
            if state.phase != .activity { holding = nil }
            else if let opened = gateSucceeded.last, state.gameTime > opened, holds.count < gateSucceeded.count {
                if presenter.travelDistance == lastTravel { holding = holding ?? opened }
                else if let start = holding { holds.append(state.gameTime - start); holding = nil }
            }
            lastTravel = presenter.travelDistance
            record()
        }

        let outside = Dictionary(uniqueKeysWithValues: LaserContactHand.ordered.map { ($0, WristGameplayFixture.outside) })
        for gate in 0..<5 {
            for _ in 0..<2400 where session.state?.phase == .activity {
                // The late jumper: P2's first JUMP of stage 3 (after gate 2).
                if lateKey == nil, gate == 2, let now = session.state?.gameTime {
                    lateKey = session.encounters.sorted { $0.targets[0].crossingTime < $1.targets[0].crossingTime }.compactMap { e in
                        e.targets.first { $0.playerID == .player2 && $0.requiredMove == .jump && $0.crossingTime > now + 1 }
                            .map { _ in LaserTargetKey(encounterID: e.id, attemptID: e.attemptID, playerID: .player2) }
                    }.first
                }
                try await send()
            }
            try #require(session.state?.phase == .vault, "gate \(gate + 1) reached")
            let zones = try #require(session.liveVaultZones)
            for button in LaserVaultButton.allCases {
                try await send(outside)
                try await send(Dictionary(uniqueKeysWithValues: zones.filter { $0.button == button }.map {
                    (LaserContactHand(playerID: $0.playerID, wrist: .left), WristPlanePoint(x: $0.position.x, y: $0.position.y))
                }))
            }
            gateSucceeded.append(try #require(session.state?.gameTime))
            if gate == 4 { break }
        }
        // Verdicts from the game's own events.
        for event in session.events {
            guard case .targetJudged(let id, let player, let judgement) = event.kind,
                  let encounter = session.encounters.first(where: { $0.id == id }) else { continue }
            let key = LaserTargetKey(encounterID: id, attemptID: encounter.attemptID, playerID: player)
            if rows[key]?.verdict == nil { rows[key]?.verdict = (event.gameTime, judgement) }
        }

        // MARK: Report (the timeline the players saw), then the checks.
        let timing = configuration.evidenceTiming
        let judged = rows.filter { $0.value.verdict != nil }.sorted { ($0.value.crossing, $0.key.playerID.rawValue) < ($1.value.crossing, $1.key.playerID.rawValue) }
        func f(_ x: Double?) -> String { x.map { String(format: "%7.3f", $0) } ?? "    –  " }
        var firstAfterGate: Set<LaserTargetKey> = []
        for s in 1...5 {
            for move in [LaserMove.jump, .duck] {
                if let first = judged.first(where: { $0.value.stage == s && $0.value.move == move && $0.key.playerID == .player1 }) {
                    firstAfterGate.insert(first.key)
                }
            }
        }
        print("[JumpTimeline] stage move player  warning    cue  crossing | shown  warned  active  visualX  Δvisual | verdict  Δverdict result | mascot lift@X  apexΔ")
        for (key, row) in judged where firstAfterGate.contains(key) || row.late {
            let result: String = switch row.verdict!.judgement { case .clear: "CLEAR"; case .hit: "HIT"; case .unavailable: "UNAVAIL"; case .pending: "PEND" }
            print("[JumpTimeline] \(row.stage) \(row.move == .jump ? "JUMP" : "DUCK") \(key.playerID.rawValue)\(row.late ? " LATE" : "")"
                  + " \(f(row.warning)) \(f(row.cue)) \(f(row.crossing)) | \(f(row.shown)) \(f(row.warned)) \(f(row.active)) \(f(row.visualCrossing))"
                  + " \(f(row.visualCrossing.map { $0 - row.crossing })) | \(f(row.verdict!.time)) \(f(row.verdict!.time - row.crossing)) \(result)"
                  + (row.move == .jump ? String(format: " | %.3f/%.3f %@", row.mascotAirborneAtCrossing ?? -1, row.mascotPeak,
                                                f(row.mascotApex.map { $0 - row.crossing })) : ""))
        }
        print("[JumpTimeline] gates succeeded at \(gateSucceeded.map { String(format: "%.3f", $0) }) · travel holds \(holds.map { String(format: "%.3f", $0) }) s")

        #expect(judged.count > 40, "a full round of judged targets (\(judged.count))")
        let opening = VaultDoor.openingDuration(reduceMotion: false)
        #expect(holds.count == 4 && holds.allSatisfy { abs($0 - opening) <= Self.dt + 1e-6 },
                "after gates 1–4 the corridor holds only for the door's opening (\(holds))")
        var worst = 0.0
        for (key, row) in judged {
            let where_ = "stage \(row.stage) \(row.move) \(key.playerID) at \(row.crossing)"
            // Visual crossing: the drawn laser meets the players' plane at the authoritative crossing.
            let visual = try #require(row.visualCrossing, "\(where_): the laser was drawn crossing")
            worst = max(worst, abs(visual - row.crossing))
            #expect(abs(visual - row.crossing) < 1e-3, "\(where_): drawn crossing \(visual)")
            // The whole warning and the action cue are shown, after gates too.
            #expect((row.shown ?? .infinity) <= row.warning + Self.dt + 1e-6, "\(where_): shown at \(row.shown ?? -1), warning \(row.warning)")
            #expect((row.warned ?? .infinity) <= row.warning + Self.dt + 1e-6, "\(where_): warning look at \(row.warned ?? -1)")
            #expect(abs((row.active ?? .infinity) - row.cue) <= Self.dt + 1e-6, "\(where_): action cue at \(row.active ?? -1), due \(row.cue)")
            // The verdict: at or after the crossing, by the judge's finalization deadline.
            let verdict = row.verdict!
            #expect(verdict.time >= row.crossing - 1e-6 && verdict.time <= timing.finalizationTime(crossing: row.crossing) + Self.dt + 1e-6,
                    "\(where_): verdict at \(verdict.time)")
            if row.late {
                #expect({ if case .hit = verdict.judgement { true } else { false } }(), "\(where_): a late jump is a HIT (\(verdict.judgement))")
            } else {
                #expect({ if case .clear = verdict.judgement { true } else { false } }(), "\(where_): on time is CLEAR (\(verdict.judgement))")
            }
            // The mascot is in the air when the laser crosses an on-time jump.
            if row.move == .jump, !row.late {
                #expect((row.mascotAirborneAtCrossing ?? 0) > 0, "\(where_): mascot lift at the crossing \(row.mascotAirborneAtCrossing ?? -1)")
                // The mascot's apex follows the body's (at the crossing) within its filter: two frames.
                #expect(abs((row.mascotApex ?? .infinity) - row.crossing) <= 2 * Self.dt + 1e-6, "\(where_): mascot apex \(row.mascotApex ?? -1)")
            }
        }
        #expect(lateKey != nil && rows[lateKey!]?.verdict != nil, "the late jump was judged")
        print(String(format: "[JumpTimeline] worst |drawn − authoritative crossing| over %d targets: %.6f s", judged.count, worst))
        await session.stop()
        presenter.stop()
        robots.remove()
    }

    static func isPending(_ judgement: Judgement?) -> Bool {
        guard let judgement else { return true }
        if case .pending = judgement { return true }
        return false
    }

    /// The presenter's action-cue rule (`GameplayScenePresenter.cueTime`).
    static func cueTime(_ target: LaserTarget, _ configuration: LaserRoundConfiguration) -> Double {
        let cue = configuration.scheduling?.actionCueTime(for: target)
            ?? configuration.actionCueLead.map { target.crossingTime - $0 } ?? target.crossingTime
        return min(max(cue, target.warningTime), target.crossingTime)
    }
}
