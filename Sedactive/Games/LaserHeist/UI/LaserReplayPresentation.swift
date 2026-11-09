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
        guard subscription == nil, session.isReplay else { return }
        self.session = session
        elapsed = 0
        #if DEBUG
        let markers = !ProcessInfo.processInfo.arguments.contains("-hideDebugOverlay")
        #else
        let markers = false
        #endif
        presenter = GameplayScenePresenter(scene: scene, configuration: session.configuration,
                                           encounters: session.encounters, showsDebugMarkers: markers)
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
        presenter?.apply(state: state, events: session.events, snapshot: session.latestSnapshot)
    }
}
