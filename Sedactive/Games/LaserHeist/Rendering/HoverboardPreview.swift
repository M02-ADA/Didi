//
//  HoverboardPreview.swift
//  Sedactive
//

#if DEBUG
import Foundation
import RealityKit
import SwiftUI

/// Developer-only review of the players' 3D hoverboard (`PlayerHoverboard`)
/// on its own: one board in front of the camera, in the corridor's lighting,
/// with no players, gameplay or camera input. Synthetic inputs only; nothing
/// here is tracking data.
///
/// Launch with `-hoverboardPreview <mode> -hideDebugOverlay` (the second flag
/// opens the game scene directly; the routing list is `LaserInputFlow`'s):
/// - `turntable` (default): the board turns slowly; each turn alternates the
///   P1 (Lemon) and P2 (Tangerine) accent.
/// - `bank`: the board faces the camera and banks left and right as a
///   synthetic lean sweeps, with a jump push-off every few seconds, then a
///   tracking loss that levels it out.
@MainActor
final class HoverboardPreview {
    enum Mode: String { case turntable, bank }

    static var requestedMode: Mode? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-hoverboardPreview") else { return nil }
        return index + 1 < arguments.count ? Mode(rawValue: arguments[index + 1]) ?? .turntable : .turntable
    }

    /// Where the board stands: in front of the players' plane, a little below eye level.
    static let position: SIMD3<Float> = [0, 0.62, 0.55]
    /// Seconds per turn, and the synthetic lean sweep's period.
    static let turnPeriod: Double = 8
    static let sweepPeriod: Double = 4

    private var boards: [PlayerHoverboard] = []
    private let stand = Entity()
    private var subscription: EventSubscription?
    private var time: Double = 0
    private(set) var mode: Mode = .turntable

    func start(on content: RealityViewCameraContent, scene: LaserScene, mode: Mode) async {
        self.mode = mode
        guard let template = await PlayerHoverboard.sharedTemplate() else { return }
        // Only the board: no pictograms or shared 2D board behind it.
        for player in scene.players.values { player.isEnabled = false }
        scene.hoverboard?.root.isEnabled = false
        stand.name = "hoverboardPreview"
        stand.position = Self.position
        scene.root.addChild(stand)
        // Lit like the mascots: the same key and fill directions.
        let key = DirectionalLight()
        key.light.intensity = 3000
        key.look(at: Self.position, from: Self.position + [1.5, 3, 3], relativeTo: nil)
        let fill = DirectionalLight()
        fill.light.intensity = 1200
        fill.look(at: Self.position, from: Self.position + [-2, 1.5, 2], relativeTo: nil)
        stand.addChild(key)
        stand.addChild(fill)
        for player in PlayerID.allCases {
            let board = PlayerHoverboard(template: template, player: player, floorY: scene.layout.corridorFloorY - Self.position.y)
            board.root.isEnabled = player == .player1
            board.input.available = true
            stand.addChild(board.root)
            boards.append(board)
        }
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.advance(by: event.deltaTime)
        }
    }

    private func advance(by deltaTime: TimeInterval) {
        time += deltaTime
        switch mode {
        case .turntable:
            let turns = time / Self.turnPeriod
            let angle = Float(turns.truncatingRemainder(dividingBy: 1) * 2 * .pi)
            for board in boards { board.root.orientation = simd_quatf(angle: angle, axis: [0, 1, 0]) }
            let shown = Int(turns) % 2 == 0 ? PlayerID.player1 : .player2
            for board in boards { board.root.isEnabled = board.player == shown }
        case .bank:
            // 0–12 s: lean sweeps with a jump at 5 s; 12–15 s: tracking lost; repeat.
            let t = time.truncatingRemainder(dividingBy: 15)
            for board in boards {
                board.input.available = t < 12
                board.input.lean = t < 12 ? Float(0.3 * sin(2 * .pi * t / Self.sweepPeriod)) : 0.3
                board.input.lift = t > 5 && t < 5.6 ? Float(0.25 * sin(.pi * (t - 5) / 0.6)) : 0
            }
        }
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
        stand.removeFromParent()
        boards = []
    }
}
#endif
