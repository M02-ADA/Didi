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
    private var frameClock = ReplayFrameClock()
    private var busy = false
    private var presenter: GameplayScenePresenter?
    private var liveAttachment: LaserLiveFrameAttachment?
    #if DEBUG
    var debugDiamondReadout: DebugDiamondVisualReadout?
    #endif

    /// DEBUG `-liveButtonLayout`: the synthetic replay shows the live vault-button layout and
    /// reach cursors (Simulator layout check without a camera). Never in Release.
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
                    case .collected: collected = true
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

    func stop() {
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

    private func render(scene: LaserScene, session: GameSessionCoordinator) {
        guard let state = session.state else { return }
        presenter?.apply(state: state, events: session.events, snapshot: session.latestSnapshot,
                         upcomingVaultIn: session.isCompleteReplay
                            ? Self.upcomingVaultIn(state: state, activityDuration: session.activityDuration)
                            : session.liveVaultIn)
        // The wrists' reach cursors show while a vault's buttons are waiting to be pressed.
        scene.robotAvatars?.showsReachCursors = state.phase == .vault && state.vault?.opened != true
            && (!session.isReplay || Self.previewsLiveButtons)
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
            case .collected: .collected
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
