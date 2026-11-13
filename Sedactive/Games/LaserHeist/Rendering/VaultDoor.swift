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
    /// Motion the panels fade instead of sliding; `reduceMotion` defaults to
    /// the system setting.
    func setState(_ newState: State, animated: Bool, reduceMotion: Bool? = nil) {
        guard newState != state else { return }
        let reduceMotion = reduceMotion ?? UIAccessibility.isReduceMotionEnabled
        guard animated else { return show(newState) }
        state = newState
        let opening = newState == .open
        openingAnimations = []
        unlockedLight.stopAllAnimations()
        unlockedLight.isEnabled = true
        fade(unlockedLight, from: opening ? 0 : 1, to: opening ? 1 : 0, duration: Self.lightDuration)
        for panel in panels {
            panel.part.stopAllAnimations()
            let from = opening ? panel.closed : panel.open
            let to = opening ? panel.open : panel.closed
            let controller: AnimationPlaybackController?
            if reduceMotion {
                panel.part.transform = panel.closed
                controller = fade(panel.part, from: opening ? 1 : 0, to: opening ? 0 : 1, duration: Self.closeDuration)
            } else {
                panel.part.components.remove(OpacityComponent.self)
                controller = slide(panel.part, from: from, to: to, duration: opening ? Self.openDuration : Self.closeDuration,
                                   delay: opening ? Self.lightDuration : 0)
            }
            if opening, let controller { openingAnimations.append(controller) }
        }
    }

    /// Closed and locked, with no animation; use when a new vault starts.
    func reset() {
        show(.locked)
    }

    /// Brief fade-in on entering a vault, so the door doesn't pop in. Cosmetic
    /// (RealityKit time); the vault's timing is unaffected.
    static let revealDuration: TimeInterval = 0.25

    func reveal() {
        root.stopAllAnimations()
        fade(root, from: 0, to: 1, duration: Self.revealDuration)
    }

    /// Fully opaque at once, with any fade stopped: a door already standing in
    /// the corridor (an approaching vault) is never faded in.
    func showOpaque() {
        root.stopAllAnimations()
        root.components.set(OpacityComponent(opacity: 1))
    }

    /// The door's own opacity (1 without an opacity component).
    var opacity: Float { root.components[OpacityComponent.self]?.opacity ?? 1 }

    /// Adds a presentation part (e.g. the vault countdown) that moves with the door.
    func attach(_ part: Entity) {
        root.addChild(part)
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

    /// The panels' opening animations (slides, or fades with Reduce Motion), while the door opens.
    private var openingAnimations: [AnimationPlaybackController] = []
    /// How long opening takes from the unlock: the light, then the slide (or the fade).
    static func openingDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? closeDuration : lightDuration + openDuration
    }

    /// The door is open AND its panels have finished moving out of the doorway: the passage is
    /// clear (`VaultPresentation` holds the corridor's travel until then).
    var isOpenAndClear: Bool { state == .open && openingAnimations.allSatisfy(\.isComplete) }

    /// Leaves the panel at `to`; until `delay` has passed it holds at `from`.
    /// The hold is its own step: an animation `delay` would show `to` meanwhile.
    @discardableResult
    private func slide(_ part: Entity, from: Transform, to: Transform, duration: TimeInterval, delay: TimeInterval) -> AnimationPlaybackController? {
        part.transform = to
        var steps = [FromToByAnimation(from: from, to: to, duration: duration, timing: .easeInOut, bindTarget: .transform)]
        if delay > 0 {
            steps.insert(FromToByAnimation(from: from, to: from, duration: delay, bindTarget: .transform), at: 0)
        }
        guard let resources = try? steps.map({ try AnimationResource.generate(with: $0) }),
              let sequence = try? AnimationResource.sequence(with: resources)
        else { return nil }
        return part.playAnimation(sequence)
    }

    @discardableResult
    private func fade(_ part: Entity, from: Float, to: Float, duration: TimeInterval) -> AnimationPlaybackController? {
        part.components.set(OpacityComponent(opacity: to))
        let animation = FromToByAnimation<Float>(from: from, to: to, duration: duration, timing: .easeInOut, bindTarget: .opacity)
        guard let resource = try? AnimationResource.generate(with: animation) else { return nil }
        return part.playAnimation(resource, handoffType: .compose)
    }
}
