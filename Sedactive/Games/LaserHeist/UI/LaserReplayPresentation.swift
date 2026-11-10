import RealityKit
import SwiftUI
import UIKit

/// Renderer adapter only: authoritative time, evidence, verdicts and totals stay in the session/game.
/// Jevon owns the frame loop and session advancement below; Kevin's
/// `GameplayScenePresenter` draws the resulting state (LH-24 ownership split).
@MainActor
final class LaserReplayPresentation {
    private var subscription: EventSubscription?
    private var session: GameSessionCoordinator?
    private var elapsed = 0.0
    private var busy = false
    private var presenter: GameplayScenePresenter?

    func start(on content: RealityViewCameraContent, scene: LaserScene,
               session: GameSessionCoordinator) {
        guard subscription == nil else { return }
        self.session = session
        elapsed = 0
        #if DEBUG
        let markers = !ProcessInfo.processInfo.arguments.contains("-hideDebugOverlay")
        #else
        let markers = false
        #endif
        presenter = GameplayScenePresenter(scene: scene, configuration: session.script.configuration,
                                           encounters: session.script.encounters, showsDebugMarkers: markers)
        // Sound follows what the presenter shows; the round's music joins in.
        presenter?.onSound = { AudioService.shared.play($0) }
        AudioService.shared.preloadEffects()
        AudioService.shared.setMusic(.mission)
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self, weak scene] event in
            guard let self, let scene, session.phase == .running else { return }
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
        presenter?.stop()
        presenter = nil
        session = nil
    }

    private func render(scene: LaserScene, session: GameSessionCoordinator) {
        guard let state = session.state else { return }
        presenter?.apply(state: state, events: session.events, snapshot: session.latestSnapshot,
                         upcomingVaultIn: Self.upcomingVaultIn(state: state, script: session.script))
    }

    /// Activity seconds until the replay's vault opens, read from the replay
    /// script (the session's own schedule; nothing is added to it). During the
    /// activity, game time and activity progress advance together, so the time
    /// left on one is the time left on the other. `nil` once the vault began.
    static func upcomingVaultIn(state: LaserGameState, script: LaserReplayScript) -> Double? {
        guard state.phase == .activity, state.vault == nil,
              let opens = script.vaultActions.first(where: { $0.player == nil })?.time,
              opens > state.gameTime else { return nil }
        return opens - state.gameTime
    }
}
