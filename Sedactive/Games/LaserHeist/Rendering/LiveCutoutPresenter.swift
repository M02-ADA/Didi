//
//  LiveCutoutPresenter.swift
//  Sedactive
//

import QuartzCore
import RealityKit

/// Shows Edo's CP2 player cutouts on the players' surfaces: the RealityKit
/// consumer of `PlayerCutoutProviding` (CP2 Phase 2, LH-14).
///
/// It claims one presentation consumer for the running generation, observes
/// state, and drains images on its own scheduled turn, never inside the
/// provider's callback. It holds one lease at a time, through GPU completion;
/// then, for each player, it shows the new image only if the lease is still
/// current at the moment of display, together with that frame's placement and
/// debug markers. Anything else keeps the previous image or falls back to the
/// pictogram. It never reads gameplay snapshots or changes body data:
/// placement comes only from the leased frame's own snapshot and placement.
///
/// Times passed to the provider are host-clock seconds, the clock CP1 capture
/// times use (`CACurrentMediaTime`).
@MainActor
final class LiveCutoutPresenter {
    /// What one player currently shows, from which source frame.
    struct Displayed: Equatable {
        let frameID: UInt64
        let sessionGeneration: UUID
        let capturedAt: Double
        let snapshot: BodySnapshot
    }

    struct Diagnostics: Equatable {
        var activations = 0
        var notCurrent = 0
        var fallbacks = 0
        var uploadFailures = 0
    }

    private let store: CutoutTextureStore
    private var mapping: GameWorldMapping
    private let layout: PlayerPlaneLayout
    private let players: [PlayerID: PlayerCutoutEntity]
    private let hostTime: @MainActor () -> Double
    /// Untuned and off by default: no hold duration has been approved (CP2 §9).
    var maximumDisplayAge: Double?
    var showsDebugMarkers = false

    private var provider: (any PlayerCutoutProviding)?
    private var observerID: UUID?
    private var consumer: CutoutConsumerToken?
    private var work: Task<Void, Never>?
    private var needsWork = false
    private var inFlight: (upload: CutoutTextureStore.Upload, lease: CutoutLease)?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var displayed: [PlayerID: Displayed] = [:]
    private(set) var diagnostics = Diagnostics()
    /// Test hook: runs synchronously right after an upload is committed.
    var onSubmitted: (() -> Void)?

    init(
        store: CutoutTextureStore, mapping: GameWorldMapping, layout: PlayerPlaneLayout,
        players: [PlayerID: PlayerCutoutEntity], hostTime: @escaping @MainActor () -> Double = { CACurrentMediaTime() }
    ) {
        self.store = store
        self.mapping = mapping
        self.layout = layout
        self.players = players
        self.hostTime = hostTime
    }

    var isAttached: Bool { provider != nil }
    var claimedConsumer: CutoutConsumerToken? { consumer }

    /// Starts presenting `provider`'s images. One provider at a time.
    func attach(_ provider: any PlayerCutoutProviding) throws {
        detach()
        self.provider = provider
        // The store wakes its current presenter when it can upload again, even
        // after an upload whose presenter has gone (scene detach mid-upload).
        store.onIdle = { [weak self] in self?.schedule() }
        // The provider replays its current state synchronously in here; that
        // only schedules work, so nothing re-enters it.
        observerID = try provider.observe { [weak self] event in
            self?.handle(event)
        }
    }

    /// Stops presenting: releases the claim, revokes any upload still on the
    /// GPU and returns both players to the pictogram. Safe to call repeatedly.
    func detach() {
        work?.cancel()
        work = nil
        needsWork = false
        inFlight?.upload.isCancelled = true
        if let provider {
            if let observerID { try? provider.removeObserver(observerID) }
            if let consumer { _ = try? provider.releaseConsumer(consumer) }
        }
        provider = nil
        observerID = nil
        consumer = nil
        for player in PlayerID.allCases { fallBack(player) }
        resumeIdleWaitersIfIdle()
    }

    /// Updates the world mapping, e.g. after the authored lanes load.
    func setMapping(_ mapping: GameWorldMapping) {
        self.mapping = mapping
    }

    /// Falls back for players whose shown image is older than
    /// `maximumDisplayAge`. Call from the render update hook; this keeps no
    /// clock of its own.
    func refresh(now: Double) {
        guard let maximumDisplayAge else { return }
        for (player, shown) in displayed where now - shown.capturedAt > maximumDisplayAge {
            fallBack(player)
        }
    }

    /// Suspends until no work is scheduled and no upload is on the GPU.
    func waitUntilIdle() async {
        guard !isIdle else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: - Provider events

    private func handle(_ event: CutoutHandoffEvent) {
        switch event {
        case .state(let state):
            if let consumer, state.consumer != consumer {
                // Generation change or stop revoked the claim.
                self.consumer = nil
                inFlight?.upload.isCancelled = true
            }
            hideIncompatible(state)
            schedule()
        case .imageAvailable:
            schedule()
        }
    }

    /// Context changes hide what no longer belongs to the running source at
    /// once, rather than waiting for a new frame.
    private func hideIncompatible(_ state: CutoutHandoffState) {
        let running = state.input?.status == .running
        for (player, shown) in displayed {
            if !running || state.input?.context?.accepts(shown.snapshot, playerID: player) != true {
                fallBack(player)
            }
        }
    }

    /// At most one scheduled turn; repeated wakeups coalesce into it.
    private func schedule() {
        needsWork = true
        guard work == nil, provider != nil else { return }
        work = Task { [weak self] in
            self?.performWork()
        }
    }

    private func performWork() {
        work = nil
        guard needsWork, let provider else { return resumeIdleWaitersIfIdle() }
        needsWork = false
        if consumer == nil, let generation = provider.state.input?.sessionGeneration,
           provider.state.input?.status == .running, provider.state.consumer == nil {
            consumer = try? provider.claimConsumer(generation: generation)
        }
        drain()
        resumeIdleWaitersIfIdle()
    }

    // MARK: - Upload and activation

    private func drain() {
        guard let provider, let consumer, inFlight == nil, store.inFlight == nil else { return }
        guard let lease = try? provider.acquireLatest(consumer, at: hostTime()) else { return }
        var images: [(player: PlayerID, image: CutoutImage)] = []
        for player in PlayerID.allCases where lease.availablePlayers.contains(player) {
            if case .available(let image, _) = lease.frame.players[player] {
                images.append((player, image))
            }
        }
        guard !images.isEmpty else {
            present(lease, upload: nil)
            return
        }
        do {
            let upload = try store.submit(images) { [weak self] upload, succeeded in
                self?.complete(upload, succeeded: succeeded)
            }
            inFlight = (upload, lease)
            onSubmitted?()
        } catch {
            diagnostics.uploadFailures += 1
            _ = try? provider.release(lease.token)
        }
    }

    /// Runs after the store has already cleared its own busy state.
    private func complete(_ upload: CutoutTextureStore.Upload, succeeded: Bool) {
        guard let current = inFlight, current.upload === upload else {
            // Not this presenter's current upload: never shown.
            schedule()
            resumeIdleWaitersIfIdle()
            return
        }
        inFlight = nil
        if succeeded && !upload.isCancelled {
            present(current.lease, upload: upload)
        } else {
            if !succeeded { diagnostics.uploadFailures += 1 }
            _ = try? provider?.release(current.lease.token)
        }
        schedule()
        resumeIdleWaitersIfIdle()
    }

    /// Activates each uploaded player whose slot is still current and fresh
    /// right now, showing exactly the texture this upload wrote, with the
    /// frame's own placement and markers, then releases the lease. Players
    /// this frame reports unavailable fall back; nothing borrows the other
    /// player's image.
    private func present(_ lease: CutoutLease, upload: CutoutTextureStore.Upload?) {
        guard let provider else { return }
        let now = hostTime()
        let snapshot = lease.frame.bodySnapshot
        let fresh = maximumDisplayAge.map { now - snapshot.capturedAt <= $0 } ?? true
        for player in PlayerID.allCases {
            guard let entity = players[player] else { continue }
            switch lease.frame.players[player] {
            case .available(let image, let placement) where upload?.targets[player] != nil:
                guard let upload, fresh, provider.isCurrent(lease, playerID: player, at: now),
                      isNewer(snapshot, than: displayed[player]), let surfaces = store.surfaces[player] else {
                    diagnostics.notCurrent += 1
                    continue
                }
                if entity.liveSurfaces.isEmpty || store.frontIndex(for: player) == nil {
                    entity.bindLiveTextures(surfaces.resources)
                }
                guard let index = store.activate(upload, player: player) else { continue }
                let laneCenter = layout.centerX(for: player)
                let quad = mapping.cutoutQuad(
                    canvasWidth: image.descriptor.width, canvasHeight: image.descriptor.height,
                    contentRect: placement.textureContentRectPx, playerPlaneRect: placement.playerPlaneRect,
                    laneCenter: laneCenter)
                let plane = placement.playerPlaneRect
                entity.showLive(index: index, center: quad.center, size: quad.size,
                                contentTop: Float(plane.y + plane.height) * mapping.metersPerGameUnit)
                entity.setDebugMarkers(showsDebugMarkers ? markers(for: snapshot.players[player], laneCenter: laneCenter) : [])
                displayed[player] = Displayed(frameID: snapshot.frameID, sessionGeneration: snapshot.sessionGeneration,
                                              capturedAt: snapshot.capturedAt, snapshot: snapshot)
                diagnostics.activations += 1
            case .unavailable:
                if isNewer(snapshot, than: displayed[player]) || displayed[player] == nil {
                    fallBack(player)
                }
            default:
                break
            }
        }
        _ = try? provider.release(lease.token)
    }

    private func isNewer(_ snapshot: BodySnapshot, than shown: Displayed?) -> Bool {
        guard let shown, shown.sessionGeneration == snapshot.sessionGeneration else { return true }
        return snapshot.frameID > shown.frameID
    }

    private func fallBack(_ player: PlayerID) {
        if displayed.removeValue(forKey: player) != nil { diagnostics.fallbacks += 1 }
        players[player]?.showPlaceholder()
        store.clearFront(player)
    }

    /// Crown and lower-sole lines from the same snapshot as the image.
    private func markers(for sample: PlayerBodySample?, laneCenter: Double) -> [SIMD2<Float>] {
        guard let geometry = sample?.geometry, let x = geometry.centerX.value else { return [] }
        let soles = [geometry.leftSoleY.value, geometry.rightSoleY.value].compactMap { $0 }
        return ([geometry.crownY.value] + [soles.min()]).compactMap { $0 }.map {
            mapping.cutoutPoint(x: x, y: $0, laneCenter: laneCenter)
        }
    }

    private var isIdle: Bool { work == nil && inFlight == nil && store.inFlight == nil }

    private func resumeIdleWaitersIfIdle() {
        guard isIdle, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }
}
