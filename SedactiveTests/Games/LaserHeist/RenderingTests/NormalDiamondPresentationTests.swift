import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// K06: normal (passage) diamonds follow the domain's authoritative diamond
/// states: placed by travel speed × time to their passage, one entity each,
/// collected/missed/closed as judged, and gone at the vault boundary.
@MainActor
struct NormalDiamondPresentationTests {
    private let generation = UUID()

    private func scene() async throws -> LaserScene {
        let scene = LaserScene()
        scene.installDiamondArt(try #require(await LaserScene.loadDiamondArtwork()))
        return scene
    }

    private func configuration() throws -> LaserRoundConfiguration {
        try LaserRoundConfiguration(
            evidenceTiming: LaserEvidenceTiming(windowBefore: 0.35, windowAfter: 0.25, deliveryAllowance: 0.1),
            clearanceMargin: 0.005, diamondPoints: nil, actionCueLead: 1.4)
    }

    private func state(_ time: Double, _ phase: LaserRoundPhase = .activity, generation: UUID? = nil) -> LaserGameState {
        LaserGameState(sessionGeneration: generation ?? self.generation, phase: phase, gameTime: time, activityProgress: time,
                       teamHealth: 5, teamScore: 0, encounters: [])
    }

    private func diamond(_ index: Int, lane: PlayerID = .player1, spawn: Double = 10, entry: Double = 14, exit: Double = 15,
                         outcome: NormalDiamond.Outcome = .pending) -> NormalDiamond {
        NormalDiamond(id: UUID(uuidString: String(format: "D1A00000-0000-4000-8000-%012d", index))!, lane: lane,
                      offsetX: 0.1, heightAboveFloor: 1.2, spawnedAt: spawn, entry: entry, exit: exit, outcome: outcome)
    }

    @Test func aDiamondComesDownTheCorridorToItsLaneAtItsPassage() async throws {
        let scene = try await scene()
        let view = NormalDiamondPresentation(scene: scene)
        var items = [diamond(1)]
        view.source = { items }
        view.update(state: state(9.9))
        #expect(view.shownIDs.isEmpty, "not before the domain spawns it")
        var depths: [Float] = []
        for time in stride(from: 10.0, through: 14.5, by: 0.5) {
            view.update(state: state(time))
            let entity = try #require(scene.root.findEntity(named: "diamond"))
            depths.append(entity.position.z)
        }
        #expect(zip(depths, depths.dropFirst()).allSatisfy { $0 < $1 }, "it only comes closer")
        let entity = try #require(scene.root.findEntity(named: "diamond"))
        #expect(abs(entity.position.z - scene.mapping.interactionPlaneZ) < 1e-4, "at the players' plane mid-passage")
        let lane = scene.mapping.playerPosition(.player1, heightAboveFloor: 1.2)
        #expect(abs(entity.position.x - (lane.x + 0.1 * scene.mapping.metersPerGameUnit)) < 1e-4)
        #expect(abs(entity.position.y - lane.y) < 1e-4)
        items[0].outcome = .pending
        #expect(view.collections == 0)
    }

    @Test func collectionShowsOnceAndTheDiamondGoes() async throws {
        let scene = try await scene()
        let view = NormalDiamondPresentation(scene: scene)
        var items = [diamond(1)]
        view.source = { items }
        view.update(state: state(13))
        items[0].outcome = .collected
        for time in [14.0, 14.05, 14.1] { view.update(state: state(time)) }
        #expect(view.collections == 1, "one collection, however often it is applied")
        view.update(state: state(14.0 + Diamond.collectDuration + 0.2))
        #expect(view.shownIDs.isEmpty)
    }

    @Test func aMissedDiamondPassesWithoutFeedbackAndLeavesBeforeTheCamera() async throws {
        let scene = try await scene()
        let view = NormalDiamondPresentation(scene: scene)
        var items = [diamond(1)]
        view.source = { items }
        view.update(state: state(13))
        items[0].outcome = .missed
        // Crossing at 14.5; at 5.2 m/s it reaches the camera's clearance about 0.5 s later.
        view.update(state: state(14.8))
        #expect(view.shownIDs.count == 1 && view.collections == 0, "still travelling, no reward")
        view.update(state: state(15.2))
        #expect(view.shownIDs.isEmpty, "removed once it has passed the players")
    }

    @Test func oneEntityPerDiamondAcrossFrames() async throws {
        let scene = try await scene()
        let view = NormalDiamondPresentation(scene: scene)
        let items = [diamond(1), diamond(2, lane: .player2, spawn: 11, entry: 15, exit: 16), diamond(3, spawn: 12, entry: 16, exit: 17)]
        view.source = { items }
        var roots: Set<ObjectIdentifier> = []
        for time in stride(from: 12.0, through: 13.5, by: 0.25) {
            view.update(state: state(time))
            for entity in scene.root.children.flatMap(\.children) where entity.name == "diamond" { roots.insert(ObjectIdentifier(entity)) }
        }
        #expect(view.shownIDs.count == 3)
        #expect(roots.count == 3, "never re-created per frame")
    }

    @Test func theVaultBoundaryAndANewGenerationLeaveNone() async throws {
        let scene = try await scene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [])
        presenter.normalDiamonds.source = { [diamond(1)] }
        presenter.apply(state: state(13), events: [], snapshot: nil)
        #expect(presenter.normalDiamonds.shownIDs.count == 1)
        presenter.apply(state: state(13.1, .vault), events: [], snapshot: nil)
        #expect(presenter.normalDiamonds.shownIDs.isEmpty)
        presenter.apply(state: state(13.2), events: [], snapshot: nil)
        presenter.apply(state: state(13.3, generation: UUID()), events: [], snapshot: nil)
        presenter.apply(state: state(13.3), events: [], snapshot: nil)
        #expect(presenter.normalDiamonds.shownIDs.count <= 1)
    }

    /// The pickup sound plays once per collection, for normal diamonds too.
    @Test func thePickupSoundsOncePerCollection() async throws {
        let scene = try await scene()
        let presenter = GameplayScenePresenter(scene: scene, configuration: try configuration(), encounters: [])
        var items = [diamond(1), diamond(2, lane: .player2)]
        presenter.normalDiamonds.source = { items }
        var heard: [SoundCue] = []
        presenter.onSound = { heard.append($0) }
        presenter.apply(state: state(13), events: [], snapshot: nil)
        items[0].outcome = .collected
        for time in [14.0, 14.02, 14.04] { presenter.apply(state: state(time), events: [], snapshot: nil) }
        items[1].outcome = .missed
        presenter.apply(state: state(15.2), events: [], snapshot: nil)
        #expect(heard.filter { $0 == .diamondCollect }.count == 1)
    }

    /// The adapter keeps passage diamonds only and maps the domain's outcomes.
    @Test func theAdapterMapsOnlyNormalDiamonds() throws {
        let layout = try LaserReplayScript.load().input.configuration.playerPlaneLayout
        func spawn(_ index: Int) throws -> LaserDiamondSpawn {
            try LaserDiamondSpawn(id: UUID(uuidString: String(format: "D1A10000-0000-4000-8000-%012d", index))!,
                                  position: LaserDiamondPosition(x: layout.centerX(for: .player2) + 0.2, y: 1.1),
                                  eligiblePlayers: [.player2], spawnedAt: 1, entry: 3, exit: 4)
        }
        let passage = LaserDiamondState(spawn: try spawn(1), lifetime: .passage, outcome: .missed(at: 4))
        let bonus = LaserDiamondState(spawn: try spawn(2), lifetime: .diamondTime(deadline: 30), outcome: nil)
        let mapped = LaserReplayPresentation.normalDiamonds([passage.spawn.id: passage, bonus.spawn.id: bonus], layout: layout)
        #expect(mapped.count == 1)
        let item = try #require(mapped.first)
        // Mirrored about the lane like the players: plane +0.2 shows 0.2 toward screen left.
        #expect(item.lane == .player2 && item.outcome == .missed && abs(item.offsetX + 0.2) < 1e-5)
        #expect(item.spawnedAt == 1 && item.crossingTime == 3.5)
    }

    /// Jevon's seeded five-vault replay: through its first activity minute the
    /// presenter shows the domain's normal diamonds, counts exactly the
    /// collections the domain made, and leaves none at the first vault.
    @Test func theCompleteReplayShowsItsNormalDiamonds() async throws {
        let scene = try await scene()
        let script = try LaserReplayScript.complete().freshRound(generation: UUID())
        let session = try LaserReplayDriver.makeSession(script: script)
        try await session.start()
        let configuration = try #require(session.configuration)
        let presenter = GameplayScenePresenter(scene: scene, configuration: configuration, encounters: session.encounters)
        let layout = session.inputConfiguration.playerPlaneLayout
        presenter.normalDiamonds.source = { LaserReplayPresentation.normalDiamonds(session.diamondStates, layout: layout) }
        var peak = 0
        var time = 0.0
        while let state = session.state, state.phase == .activity, time < 70 {
            time += 1.0 / 30
            try await session.advance(to: time)
            guard let state = session.state else { break }
            presenter.apply(state: state, events: session.events, snapshot: nil)
            peak = max(peak, presenter.normalDiamonds.shownIDs.count)
        }
        let collected = session.diamondStates.values.filter {
            if case .passage = $0.lifetime, case .collected = $0.outcome { true } else { false }
        }.count
        #expect(peak > 0, "diamonds appeared during the first minute")
        #expect(presenter.normalDiamonds.collections == collected, "one collection shown per domain collection")
        #expect(session.state?.phase == .vault)
        #expect(presenter.normalDiamonds.shownIDs.isEmpty, "none left at the vault boundary")
        await session.stop()
    }
}

/// The replay's frame signal: nothing advances before the first rendered
/// frame of a generation, then each frame adds its own time.
struct ReplayFrameClockTests {
    @Test func theFirstFrameIsTimeZero() {
        var clock = ReplayFrameClock()
        #expect(clock.frame(deltaTime: 2.5) == 0, "a slow first frame never consumes the opening")
        #expect(clock.frame(deltaTime: 1.0 / 60) == 1.0 / 60)
        #expect(abs(clock.frame(deltaTime: 1.0 / 60) - 2.0 / 60) < 1e-12)
    }

    @Test func invalidDeltasAddNothing() {
        var clock = ReplayFrameClock()
        _ = clock.frame(deltaTime: 0.02)
        #expect(clock.frame(deltaTime: -1) == 0 && clock.frame(deltaTime: .nan) == 0 && clock.frame(deltaTime: .infinity) == 0)
    }

    /// Retry: each generation's clock starts unrendered; nothing carries over.
    @Test func eachGenerationStartsUnrendered() {
        var first = ReplayFrameClock()
        _ = first.frame(deltaTime: 0.1)
        _ = first.frame(deltaTime: 5)
        let second = ReplayFrameClock()
        #expect(!second.hasRenderedFrame && second.elapsed == 0)
    }
}
