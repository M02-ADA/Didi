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
                                           encounters: session.encounters, showsDebugMarkers: markers)
        // Sound follows what the presenter shows; the round's music joins in.
        presenter?.onSound = { AudioService.shared.play($0) }
        AudioService.shared.preloadEffects()
        AudioService.shared.setMusic(.mission)
        if session.isCompleteReplay {
            // Existing K06 source hook. Domain decides presence/collection; this adapter only maps display values.
            let layout = session.inputConfiguration.playerPlaneLayout
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
                    return DiamondTimeDiamond(id: id, lane: lane,
                        offsetX: Float(state.spawn.position.x - layout.centerX(for: lane)),
                        heightAboveFloor: Float(state.spawn.position.y), collected: collected)
                }.sorted { $0.id < $1.id }
            }
            // K06: normal diamonds from the same domain states, complete replay only
            // (its placements are the replay plan's, not production defaults).
            presenter?.normalDiamonds.source = { [weak session] in
                guard let session else { return [] }
                return Self.normalDiamonds(session.diamondStates, layout: layout)
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
                            ? Self.upcomingVaultIn(state: state, activityDuration: session.activityDuration) : nil)
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
    static func normalDiamonds(_ states: [UUID: LaserDiamondState], layout: PlayerPlaneLayout) -> [NormalDiamond] {
        states.values.compactMap { state -> NormalDiamond? in
            guard case .passage = state.lifetime,
                  let lane = PlayerID.allCases.first(where: { state.spawn.eligiblePlayers.contains($0) }) else { return nil }
            let outcome: NormalDiamond.Outcome = switch state.outcome {
            case nil: .pending
            case .collected: .collected
            case .missed: .missed
            case .closed: .closed
            }
            return NormalDiamond(id: state.spawn.id, lane: lane,
                                 offsetX: Float(state.spawn.position.x - layout.centerX(for: lane)),
                                 heightAboveFloor: Float(state.spawn.position.y),
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
