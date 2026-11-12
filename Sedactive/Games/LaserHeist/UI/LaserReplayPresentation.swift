import RealityKit
import SwiftUI
import UIKit

/// Renderer adapter only: authoritative time, evidence, verdicts and totals stay in the session/game.
/// Jevon owns the frame loop and session advancement below; Kevin's
/// `GameplayScenePresenter` draws the resulting state (LH-24 ownership split).
/// The legacy-named adapter supports both modes: delta time drives only replay; live uses a
/// synchronous coordinator signal and never creates a per-frame Task or another clock.
@MainActor
final class LaserReplayPresentation {
    private var subscription: EventSubscription?
    private var session: GameSessionCoordinator?
    /// The replay's frame-update signal (TEAM_ALIGNMENT §C), one per generation.
    private var flightScenePhase: LaserRoundPhase?
    var diamondFlights: DiamondHUDFlightModel?
    private var frameClock = ReplayFrameClock()
    private var busy = false
    private var presenter: GameplayScenePresenter?
    private var liveAttachment: LaserLiveFrameAttachment?
    #if DEBUG
    var debugDiamondReadout: DebugDiamondVisualReadout?
    #endif

    /// DEBUG `-liveButtonLayout`: the synthetic replay shows the live vault-button layout and
    /// reach cursors (Simulator layout check without a camera). Never in Release.
    /// DEBUG `-showReachCursors`: draws each tracked wrist as a reach cursor at open vaults.
    /// Off by default; never in Release.
    static var showsReachCursors: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-showReachCursors")
        #else
        false
        #endif
    }

    static var previewsLiveButtons: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-liveButtonLayout")
        #else
        false
        #endif
    }

    func start(on content: RealityViewCameraContent, scene: LaserScene,
               session: GameSessionCoordinator) {
        guard subscription == nil, let configuration = session.configuration,
              session.isReplay || session.hasLiveRoundPlan else { return }
        if !session.isReplay {
            guard let attachment = try? session.attachLiveFrameHost() else { return }
            liveAttachment = attachment
        }
        self.session = session
        frameClock = ReplayFrameClock()
        #if DEBUG
        // Band-edge and body evidence markers are a diagnostic, never ordinary
        // gameplay: opt in with `-showDebugMarkers`.
        let markers = ProcessInfo.processInfo.arguments.contains("-showDebugMarkers")
        #else
        let markers = false
        #endif
        presenter = GameplayScenePresenter(scene: scene, configuration: configuration,
                                           encounters: session.plannedEncounters, showsDebugMarkers: markers)
        // Capture the real visual position synchronously before the native collection effect.
        presenter?.normalDiamonds.onCollected = { [weak self, weak session] id, world in
            guard let generation = session?.state?.sessionGeneration else { return }
            self?.diamondFlights?.collect(.normal(id), generation: generation, world: world,
                reduceMotion: UIAccessibility.isReduceMotionEnabled) {
                    content.project(point: $0, to: .named(DiamondHUDFlightModel.space))
                }
        }
        presenter?.diamondTime.onCollected = { [weak self, weak session] id, world in
            guard let generation = session?.state?.sessionGeneration else { return }
            self?.diamondFlights?.collect(.bonus(id), generation: generation, world: world,
                reduceMotion: UIAccessibility.isReduceMotionEnabled) {
                    content.project(point: $0, to: .named(DiamondHUDFlightModel.space))
                }
        }
        // A DEBUG Solo Test vault shows P1's buttons only (its roster); co-op shows both.
        presenter?.vault.visiblePlayers = Set(session.inputConfiguration.roster)
        if !session.isReplay || Self.previewsLiveButtons {
            // Live: each button drawn ON its wrist contact zone with the mascot's mirror and scale;
            // the wrists' reach cursors use the same mapping (cursor on button = wrist in zone).
            let layout = session.inputConfiguration.playerPlaneLayout
            let calibrations = session.inputConfiguration.calibrations
            presenter?.vault.liveButtons = { [weak session, weak scene] player, button in
                guard let session, let scene else { return nil }
                let zone: (x: Double, y: Double, radius: Double, standing: Double)
                if let live = session.liveVaultZones?.first(where: { $0.playerID == player && $0.button == button }) {
                    zone = (live.position.x, live.position.y, live.radius,
                            LaserLiveRoundGeometryV1.standingHeight(fromVaultRadius: live.radius))
                } else if session.isReplay, let c = calibrations[player], let share = LaserLiveRoundGeometryV1.vaultShares[button] {
                    // DEBUG layout preview over the synthetic replay: the live geometry from its calibrations.
                    let h = LaserLiveRoundGeometryV1.standingHeight(c, layout: layout)
                    zone = (layout.centerX(for: player) + LaserLiveRoundGeometryV1.outward(player) * share.out * h,
                            share.y * h, LaserLiveRoundGeometryV1.vaultRadiusShare * h, h)
                } else { return nil }
                let shown = scene.mapping.mascotPoint(x: zone.x, y: zone.y, player: player,
                    laneCenter: layout.centerX(for: player), standingHeight: zone.standing)
                return (shown.center, Float(zone.radius) * shown.scale)
            }
            // With mascots: the buttons on each wall's console, where the mascot's hand lands.
            presenter?.vault.liveConsoles = { [weak scene] player in scene?.robotAvatars?.consoles[player] }
        }
        // Sound follows what the presenter shows; the round's music joins in.
        presenter?.onSound = { AudioService.shared.play($0) }
        AudioService.shared.preloadEffects()
        AudioService.shared.setMusic(.mission)
        if session.isCompleteReplay || session.hasWristDiamondPlan {
            // Existing K06 source hook. Domain decides presence/collection; this adapter only maps display values.
            let layout = session.inputConfiguration.playerPlaneLayout
            let display = Self.diamondDisplay(scene: scene, layout: layout)
            presenter?.diamondTime.source = { [weak session] _ in
                guard let session else { return [] }
                return session.diamondStates.values.compactMap { state in
                    guard case .diamondTime = state.lifetime,
                          let lane = PlayerID.allCases.first(where: { state.spawn.eligiblePlayers.contains($0) }),
                          let id = Int(state.spawn.id.uuidString.suffix(12), radix: 16) else { return nil }
                    let collected: Bool
                    switch state.outcome {
                    case .collected, .collectedByBody: collected = true
                    case nil: collected = false
                    default: return nil
                    }
                    let shown = display(lane, state.spawn.position)
                    return DiamondTimeDiamond(id: id, lane: lane, offsetX: shown.offsetX,
                        heightAboveFloor: shown.height, collected: collected)
                }.sorted { $0.id < $1.id }
            }
            // Same K06 domain-state mapping for replay OR explicitly configured live geometry.
            // This does not select any production radius/placement or infer a collection.
            presenter?.normalDiamonds.source = { [weak session] in
                guard let session else { return [] }
                return Self.normalDiamonds(session.diamondStates, layout: layout, display: display)
            }
        }
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self, weak scene] event in
            guard let self, let scene, self.session === session, self.subscription != nil else { return }
            if !session.isReplay {
                guard let attachment = self.liveAttachment else { return }
                session.advanceLive(frameHost: attachment)
                self.render(scene: scene, session: session)
                session.collectAvatarDiamondContacts(self.avatarDiamondContacts(scene: scene, session: session),
                                                     frameHost: attachment)
                return
            }
            guard session.phase == .running else { return }
            #if DEBUG
            if session.isDebugWristPreview {
                self.render(scene:scene,session:session) // user advances original fixture time; no extra clock
                return
            }
            #endif
            let elapsed = self.frameClock.frame(deltaTime: event.deltaTime)
            guard !self.busy else { return }
            self.busy = true
            let time = elapsed
            Task { @MainActor [weak self] in
                defer { self?.busy = false }
                do {
                    try await session.advance(to: time)
                    guard self?.session === session, self?.subscription != nil else { return }
                    self?.render(scene: scene, session: session)
                } catch { await session.fail(error) }
            }
        }
    }

    #if DEBUG
    private var reachLoggedAt: Double?
    /// Once a second while a live vault waits (iPad lean/reach check): per player, each button's
    /// distance from the nearer tracked wrist to its contact zone (player plane, game units) against
    /// its radius, whether a wrist is inside, the buttons the game registered, and the mascot's
    /// applied lateral travel. Read-only; the consumer alone decides a press.
    private func logReach(state: LaserGameState, session: GameSessionCoordinator, scene: LaserScene) {
        guard !session.isReplay, state.phase == .vault, let vault = state.vault, !vault.opened,
              let zones = session.liveVaultZones else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - (reachLoggedAt ?? -1) >= 1 else { return }
        reachLoggedAt = now
        for player in session.inputConfiguration.roster {
            let wrists = session.latestSnapshot?.wristContact?.players[player]
            let points = [wrists?.left.playerPlane, wrists?.right.playerPlane].compactMap { $0 }
            let buttons = zones.filter { $0.playerID == player }.sorted { $0.position.y > $1.position.y }.map { zone -> String in
                let d = points.map { hypot($0.x - zone.position.x, $0.y - zone.position.y) }.min()
                return "\(zone.button.rawValue) " + (d.map { String(format: "%.2f/%.2f%@", $0, zone.radius, $0 <= zone.radius ? " IN" : "") } ?? "no wrist")
            }
            let pressed = (vault.buttons[player] ?? []).map(\.rawValue).sorted().joined(separator: ",")
            let travel = scene.robotAvatars?.robots[player].map { String(format: "%.2f m", $0.retargeter.sway) } ?? "-"
            print("[LaserReach] \(player.rawValue) wrists \(points.count) · " + buttons.joined(separator: " · ")
                  + " · pressed {\(pressed)} · mascot travel \(travel)")
        }
    }
    #endif

    func stop() {
        diamondFlights?.clear()
        subscription?.cancel()
        subscription = nil
        if let liveAttachment { session?.detachLiveFrameHost(liveAttachment) }
        liveAttachment = nil
        presenter?.stop()
        presenter = nil
        session = nil
        #if DEBUG
        debugDiamondReadout?.clear()
        #endif
    }

    private func avatarDiamondContacts(scene: LaserScene, session: GameSessionCoordinator) -> [UUID: Set<PlayerID>] {
        guard let presenter, let avatars = scene.robotAvatars, let state = session.state,
              let snapshot = session.latestSnapshot, session.phase == .running,
              state.phase == .activity || state.phase == .diamondTime else { return [:] }
        let active = session.diamondStates.values.filter {
            $0.outcome == nil && state.gameTime >= $0.spawn.entry && state.gameTime < $0.interactionDeadline
        }
        guard !active.isEmpty else { return [:] }
        let bodies = Dictionary(uniqueKeysWithValues: session.inputConfiguration.roster.compactMap { player in
            guard snapshot.players[player]?.trackingStatus == .reliable else { return nil as (PlayerID, [AvatarDiamondContactCapsule])? }
            return (player, avatars.diamondContactBody(player))
        })
        var contacts: [UUID: Set<PlayerID>] = [:]
        for target in active {
            let id = target.spawn.id
            let sphere: (center: SIMD3<Float>, radius: Float)?
            switch target.lifetime {
            case .passage:
                sphere = presenter.normalDiamonds.bodyContactSphere(id: id)
            case .diamondTime:
                sphere = Int(id.uuidString.suffix(12), radix: 16).flatMap { presenter.diamondTime.bodyContactSphere(id: $0) }
            }
            guard let sphere, sphere.radius > 0 else { continue }
            for player in target.spawn.eligiblePlayers where bodies[player]?.contains(where: {
                $0.overlaps(center: sphere.center, radius: sphere.radius)
            }) == true {
                contacts[id, default: []].insert(player)
            }
        }
        return contacts
    }

    private func render(scene: LaserScene, session: GameSessionCoordinator) {
        guard let state = session.state else { return }
        if flightScenePhase != state.phase { diamondFlights?.clear(); flightScenePhase = state.phase }
        diamondFlights?.session(state.sessionGeneration, running: session.phase == .running && session.summary == nil)
        presenter?.apply(state: state, events: session.events, snapshot: session.latestSnapshot,
                         upcomingVaultIn: session.isCompleteReplay
                            ? Self.upcomingVaultIn(state: state, activityDuration: session.activityDuration)
                            : session.liveVaultIn,
                         finalVault: session.finalVaultEntry)
        // The wrists' reach cursors (the tracked wrist the gate judges) are an engineering view only
        // (owner, 12 November 2026: players see the mascots and the buttons, no helper circles):
        // DEBUG `-showReachCursors`, while a vault's buttons wait. Contact is judged either way.
        scene.robotAvatars?.showsReachCursors = Self.showsReachCursors && state.phase == .vault
            && state.vault?.opened != true && (!session.isReplay || Self.previewsLiveButtons)
        #if DEBUG
        logReach(state: state, session: session, scene: scene)
        #endif
        #if DEBUG
        if let presenter {
            debugDiamondReadout?.record(normal:presenter.normalDiamonds.shownIDs,
                bonus:presenter.diamondTime.floatingIDs,
                collections:presenter.normalDiamonds.collections + presenter.diamondTime.collections,
                generation:state.sessionGeneration)
        }
        #endif
    }

    /// The domain's normal (passage) diamonds in display terms: lane from the
    /// first eligible player, sideways offset from that lane's centre, height
    /// and passage times as planned, outcome as judged. Diamond Time's
    /// persistent targets are left to `DiamondTimePresentation`.
    /// Where a player-plane diamond is drawn, relative to its lane: mirrored about the lane
    /// like the players (`GameWorldMapping`), and scaled like the lasers when bands are
    /// normalized to the mascots' height, so a diamond sits where the mascot's hand reaches
    /// when the player's wrist reaches the diamond.
    typealias DiamondDisplay = @MainActor (PlayerID, LaserDiamondPosition) -> (offsetX: Float, height: Float)
    static func diamondDisplay(scene: LaserScene?, layout: PlayerPlaneLayout) -> DiamondDisplay {
        { [weak scene] lane, position in
            let scale = scene.flatMap { s in s.robotAvatars?.laserBandScale(for: lane, mapping: s.mapping) } ?? 1
            return (Float(layout.centerX(for: lane) - position.x) * scale, Float(position.y) * scale)
        }
    }

    static func normalDiamonds(_ states: [UUID: LaserDiamondState], layout: PlayerPlaneLayout,
                               display: DiamondDisplay? = nil) -> [NormalDiamond] {
        let display = display ?? diamondDisplay(scene: nil, layout: layout)
        return states.values.compactMap { state -> NormalDiamond? in
            guard case .passage = state.lifetime,
                  let lane = PlayerID.allCases.first(where: { state.spawn.eligiblePlayers.contains($0) }) else { return nil }
            let outcome: NormalDiamond.Outcome = switch state.outcome {
            case nil: .pending
            case .collected, .collectedByBody: .collected
            case .missed: .missed
            case .closed: .closed
            }
            let shown = display(lane, state.spawn.position)
            return NormalDiamond(id: state.spawn.id, lane: lane,
                                 offsetX: shown.offsetX, heightAboveFloor: shown.height,
                                 spawnedAt: state.spawn.spawnedAt, entry: state.spawn.entry, exit: state.spawn.exit,
                                 outcome: outcome)
        }
    }

    /// Activity seconds until the next vault, for the complete replay: its
    /// vaults open at the end of each activity minute (confirmed rule: one
    /// vault after each minute, `missionTarget` vaults over `activityDuration`).
    /// Read from authoritative state only; `nil` outside the activity, after
    /// the last vault, or without that schedule. Live rounds pass `nil` until
    /// the session exposes its own next-vault time (PENDING Jevon).
    static func upcomingVaultIn(state: LaserGameState, activityDuration: Double) -> Double? {
        let vaults = state.missionTarget
        guard state.phase == .activity, vaults > 0, activityDuration > 0 else { return nil }
        let spacing = activityDuration / Double(vaults)
        let next = state.missionProgress + 1
        guard next <= vaults else { return nil }
        let lead = Double(next) * spacing - state.activityProgress
        return lead > 0 ? lead : nil
    }
}


/// The replay's source time from the RealityKit render loop: the first frame
/// this generation renders is time zero, then each frame adds its own
/// `deltaTime`. Nothing advances before the scene's first frame, so loading,
/// attaching and a slow first frame never use up the round's opening seconds.
/// Presentation-side only; game time itself stays the session's `GameClock`.
///
/// A RealityKit update is the earliest frame signal available here; it is a
/// conservative readiness signal, not proof that the frame reached the screen.
struct ReplayFrameClock: Equatable {
    private(set) var elapsed = 0.0
    private(set) var hasRenderedFrame = false

    /// Records one rendered frame and returns the replay time to advance to.
    mutating func frame(deltaTime: Double) -> Double {
        guard hasRenderedFrame else {
            hasRenderedFrame = true
            return elapsed
        }
        if deltaTime.isFinite, deltaTime > 0 { elapsed += deltaTime }
        return elapsed
    }
}
