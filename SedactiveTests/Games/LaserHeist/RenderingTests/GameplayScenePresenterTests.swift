import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// LH-24: the gameplay presenter draws Jevon's authoritative state: one
/// lane-local laser per target at its own band and times, the shared cue,
/// and one-time feedback from ordered events. These build game state directly
/// (no session) except the replay test, which drives the real coordinator.
@MainActor
struct GameplayScenePresenterTests {
    private let generation = UUID()

    private func configuration(cueLead: Double? = 1.4) throws -> LaserRoundConfiguration {
        try LaserRoundConfiguration(
            evidenceTiming: LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25, deliveryAllowance: 0.1),
            clearanceMargin: 0.005, diamondPoints: nil, actionCueLead: cueLead)
    }

    /// A duck encounter with P1's band at 1.60–1.62 and P2's at 1.10–1.12.
    private func encounter(_ index: Int, crossing: [PlayerID: Double], warningLead: Double = 3) throws -> LaserEncounter {
        let id = UUID(uuidString: String(format: "24000000-0000-4000-8000-%012d", index))!
        let targets = try PlayerID.allCases.map { player in
            let lower = player == .player1 ? 1.60 : 1.10
            return try LaserTarget(playerID: player, calibrationRevision: 1, requiredMove: .duck,
                                   beam: LaserBeamBand(lowerY: lower, upperY: lower + 0.02),
                                   warningTime: crossing[player]! - warningLead, crossingTime: crossing[player]!)
        }
        return try LaserEncounter(id: id, attemptID: id, targets: targets)
    }

    private func state(_ time: Double, _ encounters: [LaserEncounter], judged: [UUID: [PlayerID: Judgement]] = [:],
                       phase: LaserRoundPhase = .activity, generation: UUID? = nil) -> LaserGameState {
        LaserGameState(sessionGeneration: generation ?? self.generation, phase: phase, gameTime: time, activityProgress: 0,
                       teamHealth: 5, teamScore: 0, encounters: encounters.map { encounter in
            LaserEncounterState(encounter: encounter, judgements: PlayerID.allCases.reduce(into: [:]) {
                $0[$1] = judged[encounter.id]?[$1] ?? .pending(.awaitingFinalization)
            }, effectsCommitted: false)
        })
    }

    private func event(_ sequence: UInt64, _ time: Double, _ kind: LaserGameEventKind) -> GameEvent {
        GameEvent(id: UUID(), sessionGeneration: generation, sequence: sequence, gameTime: time, kind: kind)
    }

    private func key(_ encounter: LaserEncounter, _ player: PlayerID) -> LaserTargetKey {
        LaserTargetKey(encounterID: encounter.id, attemptID: encounter.attemptID, playerID: player)
    }

    // MARK: - Per-player lasers

    @Test func eachPlayerSeesTheirOwnBandInTheirOwnLane() throws {
        let scene = LaserScene()
        let laser = try encounter(1, crossing: [.player1: 10, .player2: 10])
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [laser])
        presenter.apply(state: state(7.5, [laser]), events: [], snapshot: nil)

        let p1 = try #require(presenter.hazard(for: key(laser, .player1)))
        let p2 = try #require(presenter.hazard(for: key(laser, .player2)))
        #expect(presenter.visibleHazardCount == 2)
        #expect(abs(p1.band.lowerBound - 1.60) < 1e-5 && abs(p1.band.upperBound - 1.62) < 1e-5)
        #expect(abs(p2.band.lowerBound - 1.10) < 1e-5 && abs(p2.band.upperBound - 1.12) < 1e-5)
        // The solid core is centred on each player's own band.
        #expect(abs(p1.root.position.y - 1.61) < 1e-4 && abs(p2.root.position.y - 1.11) < 1e-4)
        // P1 covers the left lane up to the boundary, P2 the right; inner emitters hidden.
        #expect(p1.span.upperBound == p2.span.lowerBound)
        #expect(p1.span.lowerBound < scene.mapping.playerPosition(.player1).x && p2.span.upperBound > scene.mapping.playerPosition(.player2).x)
        #expect(p1.emittersShown.left && !p1.emittersShown.right)
        #expect(!p2.emittersShown.left && p2.emittersShown.right)
        // Gameplay hides the shared preview laser.
        #expect(!scene.isLaserVisible)
    }

    /// A scene whose authored corridor has a `Travel` group looping every 12 m.
    private func travellingScene() -> (LaserScene, Entity) {
        let authored = Entity()
        let travel = Entity()
        travel.name = "Travel"
        authored.addChild(travel)
        let anchors = Entity()
        anchors.name = "Anchors"
        authored.addChild(anchors)
        let loop = Entity()
        loop.name = "TravelLoop"
        loop.position = [0, 0, -12]
        anchors.addChild(loop)
        let scene = LaserScene()
        scene.installEnvironment(authored: authored)
        return (scene, travel)
    }

    @Test func gatesStandStillInTheCorridorAndMeetThePlayersAtTheirCrossing() throws {
        let (scene, travel) = travellingScene()
        // P2 crosses 0.8 s after P1, with a longer warning: different timing, same world.
        let id = UUID()
        let targets = try PlayerID.allCases.map { player in
            let crossing = player == .player1 ? 10.0 : 10.8
            return try LaserTarget(playerID: player, calibrationRevision: 1, requiredMove: .duck,
                                   beam: LaserBeamBand(lowerY: player == .player1 ? 1.6 : 1.1, upperY: player == .player1 ? 1.62 : 1.12),
                                   warningTime: crossing - (player == .player1 ? 3 : 5), crossingTime: crossing)
        }
        let laser = try LaserEncounter(id: id, attemptID: id, targets: targets)
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [laser])
        let plane = scene.mapping.interactionPlaneZ, speed = scene.layout.travelSpeed

        presenter.apply(state: state(7, [laser]), events: [], snapshot: nil)
        let z1 = try #require(presenter.hazard(for: key(laser, .player1))?.worldZ)
        let z2 = try #require(presenter.hazard(for: key(laser, .player2))?.worldZ)
        let corridor = travel.position.z
        presenter.apply(state: state(8.5, [laser]), events: [], snapshot: nil)
        // Both gates and the corridor move toward the players by the same distance.
        let moved = speed * 1.5
        #expect(abs(try #require(presenter.hazard(for: key(laser, .player1))?.worldZ) - z1 - moved) < 1e-4)
        #expect(abs(try #require(presenter.hazard(for: key(laser, .player2))?.worldZ) - z2 - moved) < 1e-4)
        let corridorMoved = (travel.position.z - corridor + 12).truncatingRemainder(dividingBy: 12)
        #expect(abs(corridorMoved - moved.truncatingRemainder(dividingBy: 12)) < 1e-4)

        // Each gate is on the interaction plane exactly at its own crossing time.
        presenter.apply(state: state(10, [laser]), events: [], snapshot: nil)
        #expect(abs(try #require(presenter.hazard(for: key(laser, .player1))?.worldZ) - plane) < 1e-4)
        presenter.apply(state: state(10.8, [laser]), events: [], snapshot: nil)
        #expect(abs(try #require(presenter.hazard(for: key(laser, .player2))?.worldZ) - plane) < 1e-4)
        // A passed gate keeps travelling with the corridor rather than parking.
        let passed = try #require(presenter.hazard(for: key(laser, .player1))?.worldZ)
        #expect(abs(passed - (plane + speed * 0.8)) < 1e-4)
    }

    @Test func gatesComeIntoViewUnarmedAndLeaveBeforeTheCamera() throws {
        let scene = LaserScene()
        let laser = try encounter(1, crossing: [.player1: 10, .player2: 10])
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [laser])
        let lead = GameplayScenePresenter.approachLead(in: scene)
        // Still beyond the spawn point: not shown.
        presenter.apply(state: state(10 - lead - 0.1, [laser]), events: [], snapshot: nil)
        #expect(presenter.visibleHazardCount == 0)
        // In view but before its 3 s warning: an unarmed gate standing in the corridor.
        presenter.apply(state: state(10 - lead + 0.1, [laser]), events: [], snapshot: nil)
        #expect(presenter.hazard(for: key(laser, .player1))?.state == .inactive)
        #expect(scene.shownMoveCue == nil)
        presenter.apply(state: state(7.2, [laser]), events: [], snapshot: nil)
        #expect(presenter.hazard(for: key(laser, .player1))?.state == .warning)
        // Unjudged and nearly at the camera: hidden, never drawn across the lens.
        let nearCamera = 10 + Double((scene.layout.cameraPosition.z - scene.mapping.interactionPlaneZ) / scene.layout.travelSpeed)
        presenter.apply(state: state(nearCamera, [laser]), events: [], snapshot: nil)
        #expect(presenter.hazard(for: key(laser, .player1))?.root.isEnabled == false)
    }

    /// The world offset between a gate and the corridor's travel group: constant
    /// while the gate stands still in the corridor.
    private func corridorOffset(_ hazard: LaserHazard?, _ travel: Entity) throws -> Float {
        try #require(hazard).worldZ - travel.position.z
    }

    @Test func gatesStayPutInTheCorridorThroughVaultAndPause() throws {
        let (scene, travel) = travellingScene()
        let speed = scene.layout.travelSpeed, plane = scene.mapping.interactionPlaneZ
        // A crosses at 10 and is judged; the vault runs 10.5–12; B crosses at 16, so
        // its approach (about 4.2 s) would begin during the vault.
        let a = try encounter(1, crossing: [.player1: 10, .player2: 10])
        let b = try encounter(2, crossing: [.player1: 16, .player2: 16])
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [a, b])
        let judgedA: [UUID: [PlayerID: Judgement]] = [a.id: [.player1: .clear, .player2: .clear]]
        let judgedEvents = PlayerID.allCases.enumerated().map { index, player in
            event(UInt64(index + 1), 10.35, .targetJudged(encounterID: a.id, playerID: player, judgement: .clear))
        }

        presenter.apply(state: state(10.4, [a, b], judged: judgedA), events: judgedEvents, snapshot: nil)
        presenter.apply(state: state(10.5, [a, b], judged: judgedA, phase: .vault), events: judgedEvents, snapshot: nil)
        // (a) A's powering-down gate stops with the corridor at the vault.
        let held = try corridorOffset(presenter.hazard(for: key(a, .player1)), travel)
        presenter.apply(state: state(10.7, [a, b], judged: judgedA, phase: .vault), events: judgedEvents, snapshot: nil)
        #expect(abs(try corridorOffset(presenter.hazard(for: key(a, .player1)), travel) - held) < 1e-4)

        // (b) B, not yet armed, doesn't slide toward the stopped team.
        presenter.apply(state: state(11.9, [a, b], judged: judgedA, phase: .vault), events: judgedEvents, snapshot: nil)
        #expect(presenter.hazard(for: key(b, .player1)) == nil)

        // Travel resumes: B stands still in the corridor from then on...
        presenter.apply(state: state(12, [a, b], judged: judgedA), events: judgedEvents, snapshot: nil)
        let anchored = try corridorOffset(presenter.hazard(for: key(b, .player1)), travel)
        presenter.apply(state: state(12.5, [a, b], judged: judgedA), events: judgedEvents, snapshot: nil)
        #expect(abs(try corridorOffset(presenter.hazard(for: key(b, .player1)), travel) - anchored) < 1e-4)
        // ...including through a pause (same game time)...
        presenter.apply(state: state(12.5, [a, b], judged: judgedA), events: judgedEvents, snapshot: nil)
        #expect(abs(try corridorOffset(presenter.hazard(for: key(b, .player1)), travel) - anchored) < 1e-4)
        // ...and still reaches the players exactly at its crossing time.
        presenter.apply(state: state(16, [a, b], judged: judgedA), events: judgedEvents, snapshot: nil)
        #expect(abs(try #require(presenter.hazard(for: key(b, .player1))).worldZ - plane) < 1e-4)
        #expect(abs(presenter.travelDistance - speed * (0.1 + 4)) < 1e-4)
    }

    @Test func corridorTravelHoldsDuringPausesAndTheVault() throws {
        let (scene, travel) = travellingScene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [])
        presenter.apply(state: state(1, []), events: [], snapshot: nil)
        presenter.apply(state: state(2, []), events: [], snapshot: nil)
        let afterSecond = travel.position.z
        #expect(abs(presenter.travelDistance - scene.layout.travelSpeed) < 1e-4)
        // A pause: same game time, no travel.
        presenter.apply(state: state(2, []), events: [], snapshot: nil)
        #expect(travel.position.z == afterSecond)
        // Standing at a vault: game time runs, the team doesn't travel.
        presenter.apply(state: state(4, [], phase: .vault), events: [], snapshot: nil)
        #expect(travel.position.z == afterSecond)
        // Diamond Time travels again, from where it stopped.
        presenter.apply(state: state(5, [], phase: .diamondTime), events: [], snapshot: nil)
        #expect(abs(presenter.travelDistance - 2 * scene.layout.travelSpeed) < 1e-4)
        // A new generation (Retry) starts the journey again.
        presenter.apply(state: state(0.5, [], generation: UUID()), events: [], snapshot: nil)
        #expect(presenter.travelDistance == 0 && travel.position.z == 0)
    }

    @Test func statesFollowTheCueLeadAndEachPlayersJudgement() throws {
        let scene = LaserScene()
        let laser = try encounter(1, crossing: [.player1: 10, .player2: 10])
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(cueLead: 1.4), encounters: [laser])

        presenter.apply(state: state(8, [laser]), events: [], snapshot: nil)
        #expect(presenter.hazard(for: key(laser, .player1))?.state == .warning)
        presenter.apply(state: state(8.7, [laser]), events: [], snapshot: nil)
        #expect(presenter.hazard(for: key(laser, .player1))?.state == .active)

        let judged: [UUID: [PlayerID: Judgement]] = [laser.id: [.player1: .hit(.insufficientClearance), .player2: .clear]]
        let events = [event(1, 10.35, .targetJudged(encounterID: laser.id, playerID: .player1, judgement: .hit(.insufficientClearance))),
                      event(2, 10.35, .targetJudged(encounterID: laser.id, playerID: .player2, judgement: .clear))]
        presenter.apply(state: state(10.4, [laser], judged: judged), events: events, snapshot: nil)
        #expect(presenter.hazard(for: key(laser, .player1))?.state == .hit)
        #expect(presenter.hazard(for: key(laser, .player2))?.state == .disabled)
        presenter.apply(state: state(10.65, [laser], judged: judged), events: events, snapshot: nil)
        #expect(presenter.hazard(for: key(laser, .player1))?.state == .disabled)
        // Hidden once powered down.
        presenter.apply(state: state(10.9, [laser], judged: judged), events: events, snapshot: nil)
        #expect(presenter.visibleHazardCount == 0)
    }

    // MARK: - Cue

    @Test func cueFollowsTheEarliestPendingTargetOnlyDuringActivity() throws {
        let scene = LaserScene()
        let laser = try encounter(1, crossing: [.player1: 10, .player2: 10])
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [laser])

        presenter.apply(state: state(6.5, [laser]), events: [], snapshot: nil)
        #expect(scene.shownMoveCue == nil)
        presenter.apply(state: state(7.5, [laser]), events: [], snapshot: nil)
        #expect(scene.shownMoveCue?.move == .duck && scene.shownMoveCue?.acting == false)
        presenter.apply(state: state(9, [laser]), events: [], snapshot: nil)
        #expect(scene.shownMoveCue?.acting == true)
        // No stale cue once the vault (or Diamond Time) starts.
        presenter.apply(state: state(9, [laser], phase: .vault), events: [], snapshot: nil)
        #expect(scene.shownMoveCue == nil)
        presenter.apply(state: state(9.1, [laser], phase: .diamondTime), events: [], snapshot: nil)
        #expect(scene.shownMoveCue == nil)
        // Nor after the crossing.
        presenter.apply(state: state(10.1, [laser]), events: [], snapshot: nil)
        #expect(scene.shownMoveCue == nil)
    }

    // MARK: - Events

    @Test func oneTimeEffectsHappenOncePerEventSequence() throws {
        let scene = LaserScene()
        let laser = try encounter(1, crossing: [.player1: 10, .player2: 10])
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [laser])
        let judged: [UUID: [PlayerID: Judgement]] = [laser.id: [.player1: .clear, .player2: .hit(.notAirborne)]]
        var events = [event(1, 10.35, .targetJudged(encounterID: laser.id, playerID: .player1, judgement: .clear)),
                      event(2, 10.35, .targetJudged(encounterID: laser.id, playerID: .player2, judgement: .hit(.notAirborne))),
                      event(3, 10.35, .teamEffectsCommitted(encounterID: laser.id, healthDelta: -1, scoreDelta: 100))]
        for _ in 0..<3 {
            presenter.apply(state: state(10.4, [laser], judged: judged), events: events, snapshot: nil)
        }
        #expect(presenter.diagnostics.badges == 2)
        #expect(presenter.diagnostics.teamEffects == 1)
        #expect(scene.lastTeamEffect?.healthDelta == -1 && scene.lastTeamEffect?.scoreDelta == 100)
        // A replayed (older) sequence number is ignored.
        events.append(event(2, 10.5, .targetJudged(encounterID: laser.id, playerID: .player2, judgement: .clear)))
        presenter.apply(state: state(10.5, [laser], judged: judged), events: events, snapshot: nil)
        #expect(presenter.diagnostics.badges == 2)
    }

    @Test func withdrawnAttemptStopsBeingAHazardImmediately() throws {
        let scene = LaserScene()
        let laser = try encounter(1, crossing: [.player1: 10, .player2: 10])
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [laser])
        presenter.apply(state: state(9, [laser]), events: [], snapshot: nil)
        #expect(presenter.hazard(for: key(laser, .player1))?.state == .active)

        let withdrawn = [event(1, 9.05, .attemptWithdrawn(encounterID: laser.id, attemptID: laser.attemptID))]
        presenter.apply(state: state(9.05, [laser]), events: withdrawn, snapshot: nil)
        for player in PlayerID.allCases {
            #expect(presenter.hazard(for: key(laser, player))?.state == .disabled)
        }
        #expect(scene.shownMoveCue == nil)
        presenter.apply(state: state(9.6, [laser]), events: withdrawn, snapshot: nil)
        #expect(presenter.visibleHazardCount == 0)
    }

    // MARK: - Overlap and pool

    @Test func overlappingWindowsShareABoundedReusedPool() throws {
        let scene = LaserScene()
        let first = try encounter(1, crossing: [.player1: 10, .player2: 10], warningLead: 6)
        let second = try encounter(2, crossing: [.player1: 15, .player2: 15], warningLead: 6)
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [first, second])
        // Windows [4, 10.85] and [9, 15.85] overlap: two per player, plus one headroom.
        #expect(presenter.capacity == [.player1: 3, .player2: 3])

        presenter.apply(state: state(9.5, [first, second]), events: [], snapshot: nil)
        #expect(presenter.visibleHazardCount == 4)
        let near = try #require(presenter.hazard(for: key(first, .player1))?.worldZ)
        let far = try #require(presenter.hazard(for: key(second, .player1))?.worldZ)
        #expect(near > far)

        let judged: [UUID: [PlayerID: Judgement]] = [first.id: [.player1: .clear, .player2: .clear],
                                                      second.id: [.player1: .clear, .player2: .clear]]
        for time in stride(from: 10.0, through: 17, by: 0.25) {
            presenter.apply(state: state(time, [first, second], judged: time > 15.5 ? judged : [first.id: judged[first.id]!]),
                            events: [], snapshot: nil)
        }
        #expect(presenter.visibleHazardCount == 0)
        #expect(presenter.diagnostics.createdHazards == 4)
        #expect(presenter.diagnostics.droppedHazards == 0)
        // A fresh generation (Retry) reuses the same hazards.
        presenter.apply(state: state(9.5, [first, second], generation: UUID()), events: [], snapshot: nil)
        #expect(presenter.visibleHazardCount == 4)
        #expect(presenter.diagnostics.createdHazards == 4)
    }

    @Test func directorScheduleExpectsThreeGatesPerPlayer() throws {
        let fixture = try #require(LaserReplayScenarios.make().first).input.configuration
        let scheduling = try LaserSchedulingConfiguration(
            players: [.player1: .conservativeCandidate, .player2: .conservativeCandidate], searchStep: 0.25, maximumSearchSteps: 2000)
        let configuration = try LaserRoundConfiguration(
            evidenceTiming: LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25, deliveryAllowance: 0.1),
            clearanceMargin: 0.005, diamondPoints: nil, scheduling: scheduling)
        let schedule = try LaserWaveDirector().schedule(script: LaserWaveBeat.fiveMinuteScript(), calibrations: fixture.calibrations,
                                                        layout: fixture.playerPlaneLayout, configuration: configuration)
        // A gate is in view about 4.2 s before its crossing, plus 0.35 s to
        // finalize and 0.5 s to power down: a little over the 5 s spacing, so
        // two can be visible per player, plus headroom.
        let capacity = GameplayScenePresenter.capacity(for: schedule.encounters, configuration: configuration,
                                                       approachLead: GameplayScenePresenter.approachLead(in: LaserScene()))
        #expect(capacity == [.player1: 3, .player2: 3])
        // And the director really gives the two players different bands.
        let first = try #require(schedule.encounters.first)
        #expect(first.targets[0].beam != first.targets[1].beam)
    }

    /// UNAVAILABLE is neither a pass nor a hit: a calm badge, no spark, and the gate powers down.
    // MARK: - Sound

    /// Verdict sounds follow the authoritative verdict events, once per event,
    /// however often the same history is applied; UNAVAILABLE stays silent.
    @Test func verdictSoundsFollowTheVerdictEventsOnce() throws {
        let laser = try encounter(1, crossing: [.player1: 10, .player2: 10])
        let presenter = GameplayScenePresenter(scene: LaserScene(), configuration: try configuration(), encounters: [laser])
        var heard: [SoundCue] = []
        presenter.onSound = { heard.append($0) }
        let judged: [UUID: [PlayerID: Judgement]] = [laser.id: [.player1: .clear, .player2: .hit(.notAirborne)]]
        let events = [event(1, 10.35, .targetJudged(encounterID: laser.id, playerID: .player1, judgement: .clear)),
                      event(2, 10.35, .targetJudged(encounterID: laser.id, playerID: .player2, judgement: .hit(.notAirborne))),
                      event(3, 10.35, .teamEffectsCommitted(encounterID: laser.id, healthDelta: -1, scoreDelta: 100))]
        for _ in 0..<3 { presenter.apply(state: state(10.4, [laser], judged: judged), events: events, snapshot: nil) }
        #expect(heard == [.laserClear, .laserHit], "no second HIT from the team-damage effect")

        heard = []
        let other = try encounter(2, crossing: [.player1: 20, .player2: 20])
        let unavailable = Judgement.unavailable(.noSample)
        presenter.apply(state: state(20.4, [other], judged: [other.id: [.player1: unavailable]]),
                        events: events + [event(4, 20.35, .targetJudged(encounterID: other.id, playerID: .player1, judgement: unavailable))],
                        snapshot: nil)
        #expect(heard.isEmpty, "UNAVAILABLE is never a success or failure sound")
    }

    /// The DUCK cue sounds when the action is called (cue lead before the
    /// crossing), once for both players, never during the warning before it.
    @Test func theActionCueSoundsOnceWhenTheActionIsCalled() throws {
        let laser = try encounter(1, crossing: [.player1: 10, .player2: 10])
        let presenter = GameplayScenePresenter(scene: LaserScene(), configuration: try configuration(cueLead: 1.4), encounters: [laser])
        var heard: [SoundCue] = []
        presenter.onSound = { heard.append($0) }
        for time in stride(from: 7.0, through: 8.5, by: 0.1) { presenter.apply(state: state(time, [laser]), events: [], snapshot: nil) }
        #expect(heard.isEmpty, "the warning before the cue is silent")
        for time in stride(from: 8.6, through: 9.9, by: 0.1) { presenter.apply(state: state(time, [laser]), events: [], snapshot: nil) }
        #expect(heard == [.cueDuck])
    }

    /// Retry: a new generation starts its sounds afresh.
    @Test func aNewGenerationHearsItsOwnCues() throws {
        let laser = try encounter(1, crossing: [.player1: 10, .player2: 10])
        let presenter = GameplayScenePresenter(scene: LaserScene(), configuration: try configuration(cueLead: 1.4), encounters: [laser])
        var heard: [SoundCue] = []
        presenter.onSound = { heard.append($0) }
        presenter.apply(state: state(9, [laser]), events: [], snapshot: nil)
        let retry = UUID()
        presenter.apply(state: state(9, [laser], generation: retry), events: [], snapshot: nil)
        #expect(heard == [.cueDuck, .cueDuck])
    }

    @Test func unavailableShowsItsOwnBadgeWithoutASparkOrAHitGate() throws {
        let scene = LaserScene()
        let laser = try encounter(1, crossing: [.player1: 10, .player2: 10])
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [laser])
        let unavailable = Judgement.unavailable(.noSample)
        presenter.apply(state: state(10.4, [laser], judged: [laser.id: [.player1: unavailable]]),
                        events: [event(1, 10.35, .targetJudged(encounterID: laser.id, playerID: .player1, judgement: unavailable))], snapshot: nil)
        #expect(presenter.diagnostics.badges == 1)
        let badge = try #require(scene.root.findEntity(named: "laserFeedback.badge.\(PlayerID.player1.rawValue)"))
        #expect(badge.isEnabled)
        #expect(scene.root.findEntity(named: "laserFeedback.impact.\(PlayerID.player1.rawValue)")?.isEnabled != true)
        #expect(presenter.hazard(for: key(laser, .player1))?.state == .disabled)
    }

    /// A new generation on the same scene never inherits the old round's badge.
    @Test func aNewGenerationClearsTheOldRoundsBadges() throws {
        let scene = LaserScene()
        let laser = try encounter(1, crossing: [.player1: 10, .player2: 10])
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [laser])
        let judged: [UUID: [PlayerID: Judgement]] = [laser.id: [.player1: .clear, .player2: .clear]]
        presenter.apply(state: state(10.4, [laser], judged: judged),
                        events: [event(1, 10.35, .targetJudged(encounterID: laser.id, playerID: .player1, judgement: .clear))], snapshot: nil)
        let badge = try #require(scene.root.findEntity(named: "laserFeedback.badge.\(PlayerID.player1.rawValue)"))
        #expect(badge.isEnabled)
        presenter.apply(state: state(0.5, [], generation: UUID()), events: [], snapshot: nil)
        #expect(!badge.isEnabled)
    }

    @Test func stopHidesLasersAndCue() throws {
        let scene = LaserScene()
        let laser = try encounter(1, crossing: [.player1: 10, .player2: 10])
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [laser])
        presenter.apply(state: state(9, [laser]), events: [], snapshot: nil)
        let hazards = PlayerID.allCases.compactMap { presenter.hazard(for: key(laser, $0)) }
        presenter.stop()
        #expect(presenter.visibleHazardCount == 0)
        #expect(hazards.allSatisfy { !$0.root.isEnabled })
        #expect(scene.shownMoveCue == nil)
    }

    // MARK: - Replay round

    @Test func endingTheRoundMidLaserStopsHazardsAndCue() async throws {
        let script = try LaserReplayScript.load().freshRound(generation: UUID())
        let session = GameSessionCoordinator(script: script)
        try await session.start()
        let scene = LaserScene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: script.configuration, encounters: script.encounters)
        // Mid-approach of the first laser (crossing at 4 s, warning at 1 s).
        for tick in 0...105 { try await session.advance(to: Double(tick) / 30) }
        presenter.apply(state: try #require(session.state), events: session.events, snapshot: session.latestSnapshot)
        #expect(presenter.visibleHazardCount == 2)
        #expect(scene.shownMoveCue != nil)

        // End round: the session ends the round, then PlayView stops the presentation.
        await session.stop()
        presenter.apply(state: try #require(session.state), events: session.events, snapshot: session.latestSnapshot)
        #expect(scene.shownMoveCue == nil)
        for encounter in script.encounters.prefix(1) {
            for player in PlayerID.allCases {
                #expect(presenter.hazard(for: key(encounter, player))?.state == .disabled)
            }
        }
        presenter.stop()
        #expect(presenter.visibleHazardCount == 0)
    }

    @Test func replayRoundShowsEachVerdictOnceAndNoCueOutsideActivity() async throws {
        let script = try LaserReplayScript.load().freshRound(generation: UUID())
        let session = GameSessionCoordinator(script: script)
        try await session.start()
        let scene = LaserScene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: script.configuration, encounters: script.encounters)
        var staleCue = false
        for tick in 0...Int(script.duration * 30 + 1) {
            try await session.advance(to: Double(tick) / 30)
            guard let state = session.state else { continue }
            presenter.apply(state: state, events: session.events, snapshot: session.latestSnapshot)
            if state.phase != .activity, scene.shownMoveCue != nil { staleCue = true }
        }
        #expect(session.phase == .finished)
        #expect(!staleCue)
        // Three encounters: six per-player verdicts and three shared effects, each once.
        #expect(presenter.diagnostics.badges == 6)
        #expect(presenter.diagnostics.teamEffects == 3)
        #expect(presenter.visibleHazardCount == 0)
        #expect(presenter.diagnostics.droppedHazards == 0)
        // Player placements never moved while the pictograms followed the replay bodies.
        #expect(scene.players.values.allSatisfy { $0.position.y == 0 && $0.scale == .one })
    }
}
