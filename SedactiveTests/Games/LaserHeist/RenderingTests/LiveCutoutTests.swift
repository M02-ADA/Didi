import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// CP2 Phase 2: the RealityKit consumer of Edo's `PlayerCutoutHandoff`,
/// driven by the CP2 test producer with real GPU uploads. Host time is
/// injected (`CutoutTestData` captures frame N at time N).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LiveCutoutTests {
    final class Clock { var now: Double = 100 }

    /// One handoff, producer, scene and presenter, wired like production.
    final class Rig {
        let budget: CutoutMemoryBudget
        let handoff: PlayerCutoutHandoff
        let producer: CutoutTestProducer
        let scene = LaserScene()
        let store: CutoutTextureStore
        let presenter: LiveCutoutPresenter
        let clock = Clock()
        let layout = PlayerPlaneLayout(leftCenterX: -0.5, rightCenterX: 0.65, gameUnitsPerImageHeight: 2)
        private var statusRevision: UInt64 = 0

        init(maximumImageBytes: Int = 1 << 20) throws {
            budget = CutoutMemoryBudget(limits: try CutoutMemoryLimits())
            handoff = PlayerCutoutHandoff(budget: budget, freshness: try CutoutFreshnessPolicy())
            producer = try CutoutTestProducer(budget: budget)
            store = try CutoutTextureStore(maximumImageBytes: maximumImageBytes)
            let clock = clock
            let scene = scene
            presenter = LiveCutoutPresenter(
                store: store, mapping: scene.mapping, layout: layout,
                players: [.player1: scene.players[.player1]!, .player2: scene.players[.player2]!],
                hostTime: { clock.now })
        }

        func entity(_ id: PlayerID) -> PlayerCutoutEntity { scene.players[id]! }

        func input(generation: UUID? = nil, camera: UInt64 = 1, status: BodyInputStatus = .running) throws {
            statusRevision += 1
            try handoff.updateInput(CutoutTestData.event(statusRevision, status: status, generation: generation, camera: camera))
        }

        func start() async throws {
            try input()
            try presenter.attach(handoff)
            await presenter.waitUntilIdle()
        }

        func offer(_ frame: UInt64, missing: Set<PlayerID> = [], generation: UUID? = nil, camera: UInt64 = 1) async throws {
            let packet = try await producer.frame(
                CutoutTestData.snapshot(frame, generation: generation, camera: camera), missing: missing)
            try handoff.offer(packet, at: clock.now)
            await presenter.waitUntilIdle()
        }

        func shownQuad(_ id: PlayerID) -> ModelEntity? { entity(id).liveSurfaces.first(where: \.isEnabled) }
    }

    // MARK: - Placement and mirroring

    @Test func canvasPlacementFollowsContentScaleAndMirrorsAboutTheLane() throws {
        let mapping = GameWorldMapping()
        let quad = mapping.cutoutQuad(
            canvasWidth: 100, canvasHeight: 200,
            contentRect: try CutoutPixelRect(x: 10, y: 20, width: 50, height: 100),
            playerPlaneRect: try CutoutPlayerPlaneRect(x: 1, y: 0.5, width: 0.5, height: 1),
            laneCenter: 1.2)
        // 0.01 units per pixel: canvas 1 x 2, left 0.9, bottom -0.3, centre (1.4, 0.7).
        #expect(abs(quad.size.x - 1) < 1e-5 && abs(quad.size.y - 2) < 1e-5)
        // Mirrored about x = 1.2 and measured from it: 1.2 - 1.4.
        #expect(abs(quad.center.x - -0.2) < 1e-5 && abs(quad.center.y - 0.7) < 1e-5)
        // A point on the content edge mirrors the same way: its distance from the lane flips sign.
        let edge = mapping.cutoutPoint(x: 1.0, y: 0.5, laneCenter: 1.2)
        #expect(abs(edge.x - 0.2) < 1e-5 && abs(edge.y - 0.5) < 1e-5)
    }

    @Test func playerOneIsAlwaysTheLeftLane() {
        let mapping = GameWorldMapping()
        #expect(mapping.playerPosition(.player1).x < mapping.playerPosition(.player2).x)
    }

    // MARK: - Consumer lifecycle

    @Test func claimsOneConsumerAndShowsBothPlayersWithTheirOwnPlacement() async throws {
        let rig = try Rig()
        try await rig.start()
        let consumer = try #require(rig.presenter.claimedConsumer)
        #expect(rig.handoff.state.consumer == consumer)
        #expect(throws: CutoutError.consumerAlreadyClaimed) {
            try rig.handoff.claimConsumer(generation: consumer.sessionGeneration)
        }

        try await rig.offer(1)
        for id in PlayerID.allCases {
            #expect(rig.presenter.displayed[id]?.frameID == 1)
            #expect(rig.entity(id).isShowingLive)
        }
        // The lease is released once shown, and nothing is left on the GPU.
        #expect(!rig.handoff.hasAcquiredFrame)
        #expect(rig.store.inFlight == nil)
        #expect(rig.store.submittedCount == rig.store.completedCount)

        // P1's body (centre -0.65) is 0.15 left of its lane (-0.5): shown mirrored, 0.15 right.
        let p1 = try #require(rig.shownQuad(.player1))
        #expect(abs(p1.position.x - 0.15) < 1e-5 && abs(p1.position.y - 0.4) < 1e-5)
        #expect(abs(p1.scale.x - 0.8) < 1e-5 && abs(p1.scale.y - 0.8) < 1e-5)
        // P2's body is centred on its lane.
        let p2 = try #require(rig.shownQuad(.player2))
        #expect(abs(p2.position.x) < 1e-5)
        // Each player shows its own texture.
        let p1Texture = (p1.model?.materials.first as? UnlitMaterial)?.color.texture?.resource
        let p2Texture = (p2.model?.materials.first as? UnlitMaterial)?.color.texture?.resource
        #expect(p1Texture != nil && p1Texture !== p2Texture)
    }

    @Test func newerFramesReplaceOlderAndStaleFramesCannotOverwrite() async throws {
        let rig = try Rig()
        try await rig.start()
        try await rig.offer(1)
        let firstIndex = rig.store.frontIndex(for: .player1)
        try await rig.offer(2)
        #expect(rig.presenter.displayed[.player1]?.frameID == 2)
        // Front and back alternate; only one quad shows.
        #expect(rig.store.frontIndex(for: .player1) != firstIndex)
        #expect(rig.entity(.player1).liveSurfaces.filter(\.isEnabled).count == 1)

        let older = try await rig.producer.frame(CutoutTestData.snapshot(1))
        #expect(throws: CutoutError.staleObservation) { try rig.handoff.offer(older, at: rig.clock.now) }
        await rig.presenter.waitUntilIdle()
        #expect(rig.presenter.displayed[.player1]?.frameID == 2)
        #expect(rig.presenter.displayed[.player2]?.frameID == 2)
    }

    @Test func missingPlayerFallsBackWithoutBorrowingTheOtherImage() async throws {
        let rig = try Rig()
        try await rig.start()
        try await rig.offer(1)
        try await rig.offer(2, missing: [.player1])
        #expect(rig.presenter.displayed[.player1] == nil)
        #expect(!rig.entity(.player1).isShowingLive)
        #expect(rig.entity(.player1).liveSurfaces.allSatisfy { !$0.isEnabled })
        #expect(rig.presenter.displayed[.player2]?.frameID == 2)
        #expect(rig.entity(.player2).isShowingLive)

        // P1 returns with the next frame that has its image.
        try await rig.offer(3)
        #expect(rig.presenter.displayed[.player1]?.frameID == 3)
        #expect(rig.entity(.player1).isShowingLive)
    }

    @Test func contextChangeDuringUploadHidesAndNeverActivatesTheOldFrame() async throws {
        let rig = try Rig()
        try await rig.start()
        try await rig.offer(1)
        let shown = rig.presenter.diagnostics.activations
        rig.presenter.onSubmitted = { [rig] in
            rig.presenter.onSubmitted = nil
            try? rig.input(camera: 2)
        }
        try await rig.offer(2)
        // Frame 1 hid at once; frame 2 finished on the GPU but was no longer current.
        #expect(rig.presenter.displayed.isEmpty)
        #expect(rig.presenter.diagnostics.activations == shown)
        #expect(rig.presenter.diagnostics.notCurrent > 0)
        for id in PlayerID.allCases { #expect(!rig.entity(id).isShowingLive) }
        #expect(!rig.handoff.hasAcquiredFrame)

        // Frames from the new camera geometry show again.
        try await rig.offer(3, camera: 2)
        #expect(rig.presenter.displayed[.player1]?.frameID == 3)
    }

    @Test func generationChangeReclaimsForTheNewGeneration() async throws {
        let rig = try Rig()
        try await rig.start()
        try await rig.offer(1)
        let next = UUID()
        try rig.input(generation: next)
        await rig.presenter.waitUntilIdle()
        #expect(rig.presenter.claimedConsumer?.sessionGeneration == next)
        #expect(rig.presenter.displayed.isEmpty)
        try await rig.offer(1, generation: next)
        #expect(rig.presenter.displayed[.player2]?.sessionGeneration == next)
    }

    @Test func stoppingInputHidesCutoutsAndDropsTheClaim() async throws {
        let rig = try Rig()
        try await rig.start()
        try await rig.offer(1)
        try rig.input(status: .stopped)
        await rig.presenter.waitUntilIdle()
        #expect(rig.presenter.claimedConsumer == nil)
        #expect(rig.presenter.displayed.isEmpty)
        for id in PlayerID.allCases { #expect(!rig.entity(id).isShowingLive) }
    }

    @Test func detachAndReattachDoNotResurrectOldTextures() async throws {
        let rig = try Rig()
        try await rig.start()
        try await rig.offer(1)
        rig.presenter.detach()
        #expect(rig.handoff.state.consumer == nil)
        #expect(rig.presenter.displayed.isEmpty)
        for id in PlayerID.allCases { #expect(!rig.entity(id).isShowingLive) }

        // Detach and reattach while frame 2 is still on the GPU.
        try rig.presenter.attach(rig.handoff)
        await rig.presenter.waitUntilIdle()
        rig.presenter.onSubmitted = { [rig] in
            rig.presenter.onSubmitted = nil
            rig.presenter.detach()
            try? rig.presenter.attach(rig.handoff)
        }
        try await rig.offer(2)
        #expect(rig.presenter.displayed.isEmpty)
        for id in PlayerID.allCases { #expect(!rig.entity(id).isShowingLive) }
        #expect(rig.presenter.claimedConsumer != nil)

        try await rig.offer(3)
        #expect(rig.presenter.displayed[.player1]?.frameID == 3)
    }

    @Test func jumpMovesTheCutoutByExactlyItsPlacementOnAStillHoverboard() async throws {
        let rig = try Rig()
        let authored = Entity()
        let corridor = Entity()
        corridor.name = "Corridor"
        authored.addChild(corridor)
        let board = Entity()
        board.name = "Hoverboard"
        corridor.addChild(board)
        for name in ["Front", "Back"] {
            let part = Entity()
            part.name = name
            board.addChild(part)
        }
        rig.scene.installEnvironment(authored: authored)
        #expect(rig.scene.hoverboard != nil)
        let placements = rig.scene.players.mapValues(\.position)
        try await rig.start()
        try await rig.offer(1)
        let standing = try PlayerID.allCases.map { try #require(rig.shownQuad($0)).position(relativeTo: nil) }

        // Frame 2: P1 is 0.3 units up (a jump); P2 has not moved.
        let snapshot = try CutoutTestData.snapshot(2)
        var slots: [PlayerID: PlayerCutoutSlot] = [:]
        for id in PlayerID.allCases {
            let base = try CutoutTestData.placement(id)
            let rect = base.playerPlaneRect
            let placement = CutoutPlacement(
                sourceCropPx: base.sourceCropPx, textureContentRectPx: base.textureContentRectPx,
                playerPlaneRect: try CutoutPlayerPlaneRect(
                    x: rect.x, y: rect.y + (id == .player1 ? 0.3 : 0), width: rect.width, height: rect.height))
            slots[id] = .available(image: try await rig.producer.image(snapshot, id), placement: placement)
        }
        try rig.handoff.offer(
            PlayerCutoutFrame(bodySnapshot: snapshot, sourceImageSizePx: CutoutImageSize(width: 8, height: 8), players: slots),
            at: rig.clock.now)
        slots = [:]
        await rig.presenter.waitUntilIdle()

        let jumped = try PlayerID.allCases.map { try #require(rig.shownQuad($0)).position(relativeTo: nil) }
        #expect(rig.presenter.displayed[.player1]?.frameID == 2)
        // The cutout moves exactly with its placement: nothing adds or removes height.
        #expect(abs(jumped[0].y - standing[0].y - 0.3) < 1e-5)
        #expect(abs(jumped[0].x - standing[0].x) < 1e-5 && abs(jumped[0].z - standing[0].z) < 1e-5)
        #expect(simd_distance(jumped[1], standing[1]) < 1e-5)
        // The lane anchors and the stable container never move.
        #expect(rig.scene.players.mapValues(\.position) == placements)
        for id in PlayerID.allCases { #expect(rig.entity(id).ride.transform == .identity) }
    }

    @Test func fittingThePictogramNeverMovesTheLiveCutoutOrThePlayer() async throws {
        let rig = try Rig()
        try await rig.start()
        try await rig.offer(1)
        let entity = rig.entity(.player1)
        let quad = try #require(rig.shownQuad(.player1))
        let before = quad.transformMatrix(relativeTo: nil)
        let placement = entity.position

        // Replay-style body fit for P1 while its live cutout shows.
        rig.scene.setPlaceholderBody(for: .player1, floor: 0.2, crown: 1.9)
        #expect(quad.transformMatrix(relativeTo: nil) == before)
        #expect(entity.position == placement && entity.scale == .one && entity.ride.transform == .identity)
        // Feedback sits above the live content (its placement top, 0.8), not the fitted pictogram.
        #expect(abs(entity.visibleTop - 0.8) < 1e-5)

        // When P1 falls back, the pictogram spans floor to crown and feedback follows it.
        try await rig.offer(2, missing: [.player1])
        let surface = try #require(entity.findEntity(named: "player.player1.surface"))
        let bounds = surface.visualBounds(relativeTo: entity)
        #expect(abs(bounds.min.y - 0.2) < 1e-4 && abs(bounds.max.y - 1.9) < 1e-4)
        #expect(abs(entity.visibleTop - 1.9) < 1e-4)
        #expect(entity.position == placement && entity.scale == .one)
    }

    // MARK: - Display freshness (PR #17)

    @Test func cutoutExpiresWithoutANewerFrame() async throws {
        let rig = try Rig()
        rig.presenter.maximumDisplayAge = 0.5
        rig.clock.now = 1.2
        try await rig.start()
        try await rig.offer(1)
        #expect(rig.presenter.displayed[.player1]?.frameID == 1)

        // No newer frame arrives; only the render loop's refresh runs.
        rig.presenter.refresh(now: 1.4)
        #expect(rig.entity(.player1).isShowingLive && rig.entity(.player2).isShowingLive)
        rig.presenter.refresh(now: 1.6)
        for id in PlayerID.allCases {
            #expect(rig.presenter.displayed[id] == nil)
            #expect(!rig.entity(id).isShowingLive)
            #expect(rig.store.frontIndex(for: id) == nil)
        }
        #expect(rig.presenter.diagnostics.fallbacks == 2)

        // A fresh frame shows again.
        rig.clock.now = 2.1
        try await rig.offer(2)
        #expect(rig.presenter.displayed[.player1]?.frameID == 2)
    }

    @Test func withoutAnAgreedLimitTheLastCurrentImageStays() async throws {
        let rig = try Rig()
        try await rig.start()
        try await rig.offer(1)
        // `maximumDisplayAge` is nil until the CP2 hold duration is agreed.
        rig.presenter.refresh(now: 1_000_000)
        #expect(rig.presenter.displayed[.player1]?.frameID == 1)
        #expect(rig.entity(.player1).isShowingLive)
    }

    @Test func sceneRefreshExpiresAttachedCutoutsAndIgnoresDetached() async throws {
        let rig = try Rig()
        try rig.input()
        // Host time here is the real clock (seconds since boot), far later than the
        // fixture's capture times, so the limit is set beyond any real host time:
        // the frame shows however slowly the GPU upload completes.
        let limit = 1e9
        try rig.scene.attachLiveCutouts(rig.handoff, layout: rig.layout, maximumDisplayAge: limit)
        let presenter = try #require(rig.scene.liveCutouts)
        await presenter.waitUntilIdle()
        let packet = try await rig.producer.frame(CutoutTestData.snapshot(1))
        try rig.handoff.offer(packet, at: 100)
        await presenter.waitUntilIdle()
        #expect(presenter.displayed[.player1]?.frameID == 1)

        rig.scene.refreshLiveCutouts(now: 1 + limit + 1)
        #expect(presenter.displayed.isEmpty)
        for id in PlayerID.allCases { #expect(!rig.entity(id).isShowingLive) }

        // After detach, the per-frame refresh has nothing to act on.
        rig.scene.detachLiveCutouts()
        rig.scene.refreshLiveCutouts(now: 1 + limit + 2)
        #expect(rig.scene.liveCutouts == nil)
    }

    // MARK: - GPU resources

    @Test func resourcesStayBoundedAndBudgetIsReleased() async throws {
        let rig = try Rig()
        try await rig.start()
        try await rig.offer(1)
        let resources = rig.store.surfaces.mapValues { $0.resources.map(ObjectIdentifier.init) }
        for frame in 2...12 { try await rig.offer(UInt64(frame)) }
        #expect(rig.presenter.displayed[.player1]?.frameID == 12)
        // Same two textures per player; no new TextureResources per frame.
        #expect(rig.store.surfaces.mapValues { $0.resources.map(ObjectIdentifier.init) } == resources)
        #expect(rig.store.surfaces.values.allSatisfy { $0.textures.count == 2 })
        #expect(rig.store.stagingBufferCount == 2)
        #expect(rig.store.inFlight == nil && rig.store.submittedCount == rig.store.completedCount)
        // Nothing keeps a CP2 image alive once it is shown.
        #expect(rig.budget.usage.images == 0)
        #expect(rig.budget.usage.peakImages <= rig.budget.limits.maximumImages)
    }

    @Test func uploadThatCannotStartReleasesTheLease() async throws {
        let rig = try Rig(maximumImageBytes: 16)
        try await rig.start()
        try await rig.offer(1)
        #expect(rig.presenter.diagnostics.uploadFailures == 1)
        #expect(!rig.handoff.hasAcquiredFrame)
        #expect(rig.presenter.displayed.isEmpty)
        #expect(rig.budget.usage.images == 0)
    }

    @Test func storeAcceptsOneCommandBufferAndClearsItselfOnCompletion() async throws {
        let budget = CutoutMemoryBudget(limits: try CutoutMemoryLimits())
        let producer = try CutoutTestProducer(budget: budget)
        let store = try CutoutTextureStore(maximumImageBytes: 1 << 20)
        let image = try await producer.image(CutoutTestData.snapshot(1))
        // The caller's completion does nothing: the store still frees itself.
        let upload = try store.submit([(.player1, image)]) { _, _ in }
        #expect(throws: CutoutTextureStore.StoreError.busy) {
            try store.submit([(.player1, image)]) { _, _ in }
        }
        // Not activatable while the GPU may still be writing.
        #expect(store.activate(upload, player: .player1) == nil)
        await store.waitUntilIdle()
        #expect(store.inFlight == nil && store.completedCount == 1)
        // It wrote the hidden back (surface 0, nothing in front yet) and only that.
        #expect(upload.targets == [.player1: 0])
        #expect(store.frontIndex(for: .player1) == nil)
        #expect(store.activate(upload, player: .player2) == nil)
        #expect(store.activate(upload, player: .player1) == 0)
        #expect(store.frontIndex(for: .player1) == 0)
    }

    // MARK: - Regression: detach mid-upload, expiry mid-upload

    @Test func sceneDetachDuringUploadThenReattachRendersAgain() async throws {
        let rig = try Rig()
        try rig.input()
        try rig.scene.attachLiveCutouts(rig.handoff, layout: rig.layout)
        weak var old: LiveCutoutPresenter?
        old = rig.scene.liveCutouts
        await old?.waitUntilIdle()
        let store = try #require(rig.scene.cutoutStore)
        var frame2: PlayerCutoutFrame? = try await rig.producer.frame(CutoutTestData.snapshot(2))
        var frame3: PlayerCutoutFrame? = try await rig.producer.frame(CutoutTestData.snapshot(3))

        // While frame 2 is on the GPU: the scene detaches (its presenter goes
        // away), reattaches, and frame 3 arrives for the new presenter.
        await withCheckedContinuation { (submitted: CheckedContinuation<Void, Never>) in
            old?.onSubmitted = { [rig] in
                rig.scene.detachLiveCutouts()
                try? rig.scene.attachLiveCutouts(rig.handoff, layout: rig.layout)
                if let frame3 { try? rig.handoff.offer(frame3, at: rig.clock.now) }
                submitted.resume()
            }
            if let frame2 { try? rig.handoff.offer(frame2, at: rig.clock.now) }
        }
        frame2 = nil
        frame3 = nil
        let next = try #require(rig.scene.liveCutouts)
        await store.waitUntilIdle()
        await next.waitUntilIdle()

        #expect(old == nil)
        // The orphaned upload freed the store, which woke the new presenter.
        #expect(store.inFlight == nil)
        #expect(store.submittedCount == 2 && store.completedCount == 2)
        for id in PlayerID.allCases {
            #expect(next.displayed[id]?.frameID == 3)
            #expect(rig.entity(id).isShowingLive)
        }
        // Frame 2 never showed: only frame 3's two players were activated.
        #expect(next.diagnostics.activations == 2)
        #expect(!rig.handoff.hasAcquiredFrame)
        #expect(rig.budget.usage.images == 0)
    }

    @Test func presenterWakesWhenAnOrphanedUploadFinishes() async throws {
        let rig = try Rig()
        try await rig.start()
        var orphan: CutoutImage? = try await rig.producer.image(CutoutTestData.snapshot(1))
        var packet: PlayerCutoutFrame? = try await rig.producer.frame(CutoutTestData.snapshot(2))
        // An upload no presenter will finish (its presenter is gone) keeps the store busy.
        _ = try rig.store.submit([(.player1, orphan!)]) { _, _ in }
        // The presenter's drain is queued first and finds the store busy...
        try rig.handoff.offer(packet!, at: rig.clock.now)
        orphan = nil
        packet = nil
        // ...and the GPU completion is queued behind it on the main actor.
        usleep(100_000)
        await rig.store.waitUntilIdle()
        await rig.presenter.waitUntilIdle()
        // The store's own completion woke the presenter, which then showed frame 2.
        #expect(rig.presenter.displayed[.player1]?.frameID == 2)
        #expect(rig.presenter.displayed[.player2]?.frameID == 2)
        #expect(rig.store.inFlight == nil && rig.store.submittedCount == rig.store.completedCount)
        #expect(rig.budget.usage.images == 0)
    }

    @Test func expiryDuringUploadShowsExactlyTheWrittenTexture() async throws {
        let rig = try Rig()
        rig.presenter.maximumDisplayAge = 0.5
        rig.clock.now = 1
        try await rig.start()
        try await rig.offer(1)
        for id in PlayerID.allCases { #expect(rig.store.frontIndex(for: id) == 0) }

        // Frame 2 is written into surface 1; frame 1 expires while it is on the GPU.
        rig.presenter.onSubmitted = { [rig] in
            rig.presenter.onSubmitted = nil
            rig.presenter.refresh(now: 2)
        }
        rig.clock.now = 2
        try await rig.offer(2)

        #expect(rig.presenter.diagnostics.fallbacks == 2)
        for id in PlayerID.allCases {
            #expect(rig.presenter.displayed[id]?.frameID == 2)
            #expect(rig.store.frontIndex(for: id) == 1)
            let shown = try #require(rig.shownQuad(id))
            // Surface 1 is bound to texture 1, the one frame 2 was written into.
            #expect(rig.entity(id).liveSurfaces.firstIndex { $0 === shown } == 1)
        }
    }

    @Test func frameThatExpiresDuringUploadIsNeverShown() async throws {
        let rig = try Rig()
        rig.presenter.maximumDisplayAge = 0.5
        rig.clock.now = 1
        try await rig.start()
        try await rig.offer(1)
        rig.presenter.onSubmitted = { [rig] in
            rig.presenter.onSubmitted = nil
            rig.clock.now = 5
            rig.presenter.refresh(now: 5)
        }
        rig.clock.now = 2
        try await rig.offer(2)

        #expect(rig.presenter.displayed.isEmpty)
        #expect(rig.presenter.diagnostics.notCurrent == 2)
        for id in PlayerID.allCases {
            #expect(!rig.entity(id).isShowingLive)
            #expect(rig.store.frontIndex(for: id) == nil)
        }
        #expect(!rig.handoff.hasAcquiredFrame)
        #expect(rig.budget.usage.images == 0)
    }

    /// A mascot is the player's only body: cutouts stay hidden beside it, even
    /// as new frames arrive, and return only with a frame after it leaves.
    @Test func aMascotTakesPrecedenceOverALiveCutout() async throws {
        let rig = try Rig()
        try await rig.start()
        try await rig.offer(1)
        #expect(PlayerID.allCases.allSatisfy { rig.entity($0).isShowingLive })

        let mascots = RobotAvatarLayer(scene: rig.scene, players: Set(PlayerID.allCases),
                                       templates: try await RobotAvatarLayer.sharedTemplates())
        #expect(PlayerID.allCases.allSatisfy { !rig.entity($0).isShowingLive })
        try await rig.offer(2)
        #expect(PlayerID.allCases.allSatisfy { !rig.entity($0).isShowingLive })

        mascots.remove()
        try await rig.offer(3)
        #expect(PlayerID.allCases.allSatisfy { rig.entity($0).isShowingLive })
    }

    @Test func sceneAttachAndDetachRestorePictograms() async throws {
        let rig = try Rig()
        try rig.input()
        try rig.scene.attachLiveCutouts(rig.handoff, layout: rig.layout)
        let presenter = try #require(rig.scene.liveCutouts)
        await presenter.waitUntilIdle()
        #expect(rig.handoff.state.consumer != nil)
        rig.scene.detachLiveCutouts()
        #expect(rig.scene.liveCutouts == nil)
        #expect(rig.handoff.state.consumer == nil)
        for id in PlayerID.allCases { #expect(!rig.entity(id).isShowingLive) }
    }
}
