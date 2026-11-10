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
    private var elapsed = 0.0
    private var busy = false
    private var presenter: GameplayScenePresenter?
    private var liveAttachment: LaserLiveFrameAttachment?

    func start(on content: RealityViewCameraContent, scene: LaserScene,
               session: GameSessionCoordinator) {
        guard subscription == nil, let configuration = session.configuration,
              session.isReplay || session.hasLiveRoundPlan else { return }
        if !session.isReplay {
            guard let attachment = try? session.attachLiveFrameHost() else { return }
            liveAttachment = attachment
        }
        self.session = session
        elapsed = 0
        #if DEBUG
        let markers = !ProcessInfo.processInfo.arguments.contains("-hideDebugOverlay")
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
            self.elapsed += event.deltaTime
            guard !self.busy else { return }
            self.busy = true
            let time = self.elapsed
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
    }

    private func render(scene: LaserScene, session: GameSessionCoordinator) {
        guard let state = session.state else { return }
        presenter?.apply(state: state, events: session.events, snapshot: session.latestSnapshot,
                         upcomingVaultIn: session.isCompleteReplay
                            ? Self.upcomingVaultIn(state: state, activityDuration: session.activityDuration) : nil)
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
