import RealityKit
import SwiftUI
import UIKit

/// Renderer adapter only: authoritative time, evidence, verdicts and totals stay in the session/game.
@MainActor
final class LaserReplayPresentation {
    private var subscription: EventSubscription?
    private var session: GameSessionCoordinator?
    private var elapsed = 0.0
    private var busy = false
    private var shown: UUID?
    private var feedbackShown = false
    private let debug = Entity()
    private var markers: [ModelEntity] = []
    private var bandEdges: [ModelEntity] = []

    func start(on content: RealityViewCameraContent, scene: LaserScene,
               session: GameSessionCoordinator) {
        guard subscription == nil else { return }
        self.session = session
        elapsed = 0
        shown = nil
        feedbackShown = false
        let colors: [UIColor] = [.cyan, .purple, .purple, .green, .green]
        for _ in PlayerID.allCases {
            for color in colors {
                let marker = ModelEntity(mesh: .generateSphere(radius: 0.025), materials: [UnlitMaterial(color: color)])
                markers.append(marker)
                debug.addChild(marker)
            }
        }
        for _ in 0..<2 {
            let edge = ModelEntity(mesh: .generateBox(size: [scene.layout.corridorWidth, 0.004, 0.004]),
                                   materials: [UnlitMaterial(color: .yellow)])
            bandEdges.append(edge)
            debug.addChild(edge)
        }
        scene.root.addChild(debug)
        #if DEBUG
        debug.isEnabled = !ProcessInfo.processInfo.arguments.contains("-hideDebugOverlay")
        #else
        debug.isEnabled = false
        #endif
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
        debug.removeFromParent()
        markers.removeAll()
        bandEdges.removeAll()
        session = nil
    }

    private func render(scene: LaserScene, session: GameSessionCoordinator) {
        guard let state = session.state else { return }
        let time = state.gameTime
        let encounter = session.script.encounters.last { $0.targets[0].crossingTime - 4 <= time }
            ?? session.script.encounters[0]
        let target = encounter.targets[0]
        if shown != encounter.id {
            shown = encounter.id
            feedbackShown = false
            scene.clearLaserFeedback()
            scene.setLaserBand(lowerEdge: Float(target.beam.lowerY), upperEdge: Float(target.beam.upperY))
            for (edge, y) in zip(bandEdges, [target.beam.lowerY, target.beam.upperY]) {
                edge.position = scene.mapping.laserPosition(heightAboveFloor: Float(y),
                                                           worldZ: scene.mapping.interactionPlaneZ + 0.03)
            }
        }
        let relative = time - target.crossingTime
        let plane = scene.mapping.interactionPlaneZ
        let speed = (plane - scene.layout.laserSpawnZ) / 4
        let depth = relative < 0 ? plane + speed * Float(relative) : plane + min(0.6, speed * Float(relative))
        scene.setLaserDepth(depth)
        let current = state.encounters.first { $0.encounter.id == encounter.id }
        scene.setLaserVisualState(current?.effectsCommitted == true ? .disabled : (time < target.warningTime ? .inactive : .active))
        scene.setLaserWarningProgress(Float(max(0, min(1, (time - target.warningTime) / 1.6))))
        let cue: LaserFeedback.Move = target.requiredMove == .duck ? .duck : .jump
        scene.setMoveCue(time >= target.warningTime && relative < 0 ? cue : nil,
                         actionRemaining: relative >= -1.4 && relative < 0 ? Float(-relative / 1.4) : nil)
        if current?.effectsCommitted == true, !feedbackShown {
            for player in PlayerID.allCases {
                let lane: GameWorldMapping.Lane = player == .player1 ? .parent : .child
                switch current?.judgements[player] {
                case .clear: scene.presentOutcome(.clear, for: lane)
                case .hit: scene.presentOutcome(.hit, for: lane)
                case .unavailable: scene.presentOutcome(.unavailable, for: lane)
                default: break
                }
            }
            feedbackShown = true
        }
        guard let packet = session.latestSnapshot else { return }
        for (index, player) in PlayerID.allCases.enumerated() {
            guard let body = packet.players[player] else { continue }
            let lane: GameWorldMapping.Lane = player == .player1 ? .parent : .child
            let points = [body.geometry.crownY, body.geometry.leftWristY, body.geometry.rightWristY,
                          body.geometry.leftSoleY, body.geometry.rightSoleY]
            for (offset, point) in points.enumerated() {
                let marker = markers[index * 5 + offset]
                marker.isEnabled = point.validity == .valid
                if let y = point.value {
                    marker.position = scene.mapping.playerPosition(lane, heightAboveFloor: Float(y))
                    marker.position.x += [Float(0), -0.16, 0.16, -0.08, 0.08][offset]
                    marker.position.z += 0.06
                }
            }
            if let crown = body.geometry.crownY.value, let left = body.geometry.leftSoleY.value,
               let right = body.geometry.rightSoleY.value, let entity = scene.players[lane] {
                let floor = min(left, right)
                let original = lane == .parent ? scene.layout.parentSize.y : scene.layout.childSize.y
                entity.scale.y = Float(crown - floor) * scene.mapping.metersPerGameUnit / original
                entity.position.y = Float(floor) * scene.mapping.metersPerGameUnit
            }
        }
    }
}
