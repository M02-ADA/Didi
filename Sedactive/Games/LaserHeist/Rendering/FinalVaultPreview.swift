//
//  FinalVaultPreview.swift
//  Sedactive
//

#if DEBUG
import Foundation
import RealityKit
import SwiftUI

/// DEBUG review of the final vault entry without a camera: launch with
/// `-replay -finalVaultPreview [solo] [p1:<x>] [p2:<x>] [reduce] [noblink] [seconds]`. The mascots stand in their lanes
/// (rest pose, no body data), or with `p1:`/`p2:` on boards at that world X (where a lean left them
/// before the vault), while `FinalVaultPresentation` plays the entry on RealityKit frame time and
/// loops, or holds at `seconds` (screenshots). No session, game state, lasers or diamonds:
/// presentation review only, never gameplay.
@MainActor @Observable
final class FinalVaultPreview {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-finalVaultPreview") }

    /// Solo (Lemon only) and a held time, from the arguments after the flag.
    static var requested: (solo: Bool, heldAt: Double?) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-finalVaultPreview") else { return (false, nil) }
        let rest = arguments[(index + 1)...].prefix { !$0.hasPrefix("-") }
        return (rest.contains("solo"), rest.compactMap(Double.init).first)
    }

    /// `p1:<x>` / `p2:<x>`: each mascot's board position (world X) before the entry.
    static var startX: [PlayerID: Float] {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-finalVaultPreview") else { return [:] }
        var out: [PlayerID: Float] = [:]
        for word in arguments[(index + 1)...].prefix(while: { !$0.hasPrefix("-") }) {
            for (prefix, player) in [("p1:", PlayerID.player1), ("p2:", .player2)] where word.hasPrefix(prefix) {
                out[player] = Float(word.dropFirst(prefix.count))
            }
        }
        return out
    }

    @ObservationIgnored private var subscription: EventSubscription?
    @ObservationIgnored private var elapsed = 0.0
    /// The blink after the landing (`DiamondTimeBlinkView`), as in a live round.
    private(set) var blinkClosure = 0.0

    func start(on content: RealityViewCameraContent, scene: LaserScene, solo: Bool, heldAt: Double?) {
        let vault = FinalVaultPresentation(scene: scene)
        let timeline = LaserFinalVaultTimeline(roster: solo ? [.player1] : PlayerID.allCases)
        let insideHold = 2.5
        let robots = scene.robotAvatars
        let shownLanes = Dictionary(uniqueKeysWithValues: scene.players.map { ($0.key, $0.value.isEnabled) })
        robots?.authoritativeBoardX = Self.startX
        if robots?.smoothing == nil { robots?.smoothing = 0.03 } // no live presenter here to set it
        var clock = 0.0 // the mascots' own frame clock (they render every frame, as in a round)
        func render(_ dt: Double) { clock += dt; robots?.render(now: clock) }
        for _ in 0..<60 { render(1.0 / 60) } // settle on the start positions
        func show(_ t: Double) {
            vault.update(t < timeline.end ? .entry(timeline, elapsed: t) : .inside(timeline))
            // As a live round: the blink after the landing, and Diamond Time's own view (no mascots)
            // from its shut middle.
            // `noblink`: the earlier instant switch at the landing's end, for comparison captures.
            let noBlink = ProcessInfo.processInfo.arguments.contains("noblink")
            let closure = noBlink ? 0 : timeline.blinkClosure(at: t)
            if closure != blinkClosure { blinkClosure = closure }
            let diamondTime = t >= (noBlink ? timeline.total : timeline.blinkSwitch)
            for (player, lane) in scene.players { lane.isEnabled = !diamondTime && shownLanes[player, default: true] }
        }
        if let heldAt {
            // Played up to the held moment frame by frame, as in a round.
            var t = 0.0
            while t < heldAt { show(t); render(1.0 / 60); t += 1.0 / 60 }
            show(heldAt); render(1.0 / 60)
            return
        }
        show(0)
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            guard let self else { return }
            elapsed += event.deltaTime
            if elapsed > timeline.end + insideHold { elapsed = 0; vault.update(.hidden) }
            show(elapsed)
            render(event.deltaTime)
        }
    }
}
#endif
