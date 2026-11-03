//
//  VaultDoor.swift
//  Sedactive
//

import RealityKit
import UIKit

/// The Dual Key Vault door from the `VaultDoor` Reality Composer Pro scene: a
/// still frame whose light shows locked (red) or unlocked (green), and two
/// panels that slide sideways behind the frame and its surround.
///
/// Presentation only. Whether and when a vault opens comes from Jevon's vault
/// events; this class never times, validates or scores a vault.
@MainActor
final class VaultDoor {
    enum State {
        case locked, open
    }

    /// Temporary tuning values, not approved constants.
    static let lightDuration: TimeInterval = 0.15
    static let openDuration: TimeInterval = 0.7
    static let closeDuration: TimeInterval = 0.55

    let root: Entity
    private(set) var state: State = .locked
    private let unlockedLight: Entity
    private let panels: [(part: Entity, closed: Transform, open: Transform)]

    /// Returns `nil` when the artwork lacks a named part.
    init?(artwork: Entity) {
        guard let door = artwork.findEntity(named: "VaultDoorRoot"),
              let light = door.findEntity(named: "UnlockedLight"),
              let left = door.findEntity(named: "LeftDoorPanel"),
              let right = door.findEntity(named: "RightDoorPanel")
        else { return nil }
        door.removeFromParent()
        door.transform = .identity
        root = door
        unlockedLight = light
        // Each panel slides out by its own width, fully behind the frame.
        panels = [(left, Float(-1)), (right, Float(1))].map { panel, side in
            var open = panel.transform
            open.translation.x += side * panel.visualBounds(relativeTo: panel).extents.x
            return (panel, panel.transform, open)
        }
        show(.locked)
    }

    /// Unlocking switches the light to green, then the panels slide apart;
    /// locking slides them shut and turns the light red again. With Reduce
    /// Motion the panels fade instead of sliding.
    func setState(_ newState: State, animated: Bool) {
        guard newState != state else { return }
        guard animated else { return show(newState) }
        state = newState
        let opening = newState == .open
        unlockedLight.stopAllAnimations()
        unlockedLight.isEnabled = true
        fade(unlockedLight, from: opening ? 0 : 1, to: opening ? 1 : 0, duration: Self.lightDuration)
        for panel in panels {
            panel.part.stopAllAnimations()
            let from = opening ? panel.closed : panel.open
            let to = opening ? panel.open : panel.closed
            if UIAccessibility.isReduceMotionEnabled {
                panel.part.transform = panel.closed
                fade(panel.part, from: opening ? 1 : 0, to: opening ? 0 : 1, duration: Self.closeDuration)
            } else {
                panel.part.components.remove(OpacityComponent.self)
                slide(panel.part, from: from, to: to, duration: opening ? Self.openDuration : Self.closeDuration,
                      delay: opening ? Self.lightDuration : 0)
            }
        }
    }

    /// Closed and locked, with no animation; use when a new vault starts.
    func reset() {
        show(.locked)
    }

    private func show(_ newState: State) {
        state = newState
        unlockedLight.stopAllAnimations()
        unlockedLight.isEnabled = newState == .open
        unlockedLight.components.set(OpacityComponent(opacity: 1))
        for panel in panels {
            panel.part.stopAllAnimations()
            panel.part.components.remove(OpacityComponent.self)
            panel.part.transform = newState == .open ? panel.open : panel.closed
        }
    }

    /// Leaves the panel at `to`; until `delay` has passed it holds at `from`.
    /// The hold is its own step: an animation `delay` would show `to` meanwhile.
    private func slide(_ part: Entity, from: Transform, to: Transform, duration: TimeInterval, delay: TimeInterval) {
        part.transform = to
        var steps = [FromToByAnimation(from: from, to: to, duration: duration, timing: .easeInOut, bindTarget: .transform)]
        if delay > 0 {
            steps.insert(FromToByAnimation(from: from, to: from, duration: delay, bindTarget: .transform), at: 0)
        }
        guard let resources = try? steps.map({ try AnimationResource.generate(with: $0) }),
              let sequence = try? AnimationResource.sequence(with: resources)
        else { return }
        part.playAnimation(sequence)
    }

    private func fade(_ part: Entity, from: Float, to: Float, duration: TimeInterval) {
        part.components.set(OpacityComponent(opacity: to))
        let animation = FromToByAnimation<Float>(from: from, to: to, duration: duration, timing: .easeInOut, bindTarget: .opacity)
        if let resource = try? AnimationResource.generate(with: animation) {
            part.playAnimation(resource, handoffType: .compose)
        }
    }
}
