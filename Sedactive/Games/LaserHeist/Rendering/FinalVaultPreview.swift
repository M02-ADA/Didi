//
//  FinalVaultPreview.swift
//  Sedactive
//

#if DEBUG
import Foundation
import RealityKit
import SwiftUI

/// DEBUG review of the final vault entry without a camera: launch with
/// `-replay -finalVaultPreview [solo] [seconds]`. The mascots stand in their lanes
/// (rest pose, no body data) while `FinalVaultPresentation` plays the entry on
/// RealityKit frame time and loops, or holds at `seconds` (screenshots). No session,
/// game state, lasers or diamonds: presentation review only, never gameplay.
@MainActor
final class FinalVaultPreview {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-finalVaultPreview") }

    /// Solo (Lemon only) and a held time, from the arguments after the flag.
    static var requested: (solo: Bool, heldAt: Double?) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-finalVaultPreview") else { return (false, nil) }
        let rest = arguments[(index + 1)...].prefix { !$0.hasPrefix("-") }
        return (rest.contains("solo"), rest.compactMap(Double.init).first)
    }

    private var subscription: EventSubscription?
    private var elapsed = 0.0

    func start(on content: RealityViewCameraContent, scene: LaserScene, solo: Bool, heldAt: Double?) {
        let vault = FinalVaultPresentation(scene: scene)
        let timeline = LaserFinalVaultTimeline(roster: solo ? [.player1] : PlayerID.allCases)
        let insideHold = 2.5
        func show(_ t: Double) {
            vault.update(t < timeline.total ? .entry(timeline, elapsed: t) : .inside(timeline))
        }
        show(heldAt ?? 0)
        guard heldAt == nil else { return }
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            guard let self else { return }
            elapsed += event.deltaTime
            if elapsed > timeline.total + insideHold { elapsed = 0; vault.update(.hidden) }
            show(elapsed)
        }
    }
}
#endif
