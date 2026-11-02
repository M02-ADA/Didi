//
//  LaserGate.swift
//  Sedactive
//

import RealityKit
import UIKit

/// One Option 1 laser gate built from the `LaserGate` Reality Composer Pro scene:
/// two compact wall emitters and a beam between them.
///
/// The beam's solid core is exactly the judged band: `setBandHeight` sizes it,
/// and the decorative glow only scales with it. Rendering never decides a
/// state; callers pass the state that Jevon's game state implies (TEAM_ALIGNMENT §B).
/// Warning pulses and hit sparks are cosmetic and never move the beam.
@MainActor
final class LaserGate {
    enum VisualState: String, CaseIterable {
        case inactive, warning, active, hit, disabled
    }

    /// Gate root, centred on the beam's centre line.
    let root: Entity
    private(set) var state: VisualState?

    private let beam: Entity
    private let core: Entity
    private let glow: Entity
    private let warning: Entity
    private let emitters: [Emitter]
    private let authoredBeamSize: SIMD2<Float>

    private struct Emitter {
        let mount: Entity
        let active: Entity
        let disabled: Entity
        let ring: Entity
        let spark: Entity
    }

    /// Returns `nil` when the artwork lacks a named part, so the caller can keep
    /// its fallback laser.
    init?(artwork: Entity) {
        func part(_ name: String, in parent: Entity?) -> Entity? { parent?.findEntity(named: name) }
        guard let gate = part("Gate", in: artwork),
              let beam = part("Beam", in: gate),
              let core = part("Core", in: beam), let glow = part("Glow", in: beam), let warning = part("Warning", in: beam),
              let coreSize = core.components[ModelComponent.self]?.mesh.bounds.extents
        else { return nil }
        var emitters: [Emitter] = []
        for name in ["EmitterLeft", "EmitterRight"] {
            guard let mount = part(name, in: gate),
                  let active = part("Active", in: mount), let disabled = part("Disabled", in: mount),
                  let ring = part("WarningRing", in: mount), let spark = part("HitSpark", in: mount)
            else { return nil }
            emitters.append(Emitter(mount: mount, active: active, disabled: disabled, ring: ring, spark: spark))
        }
        gate.removeFromParent()
        gate.transform = .identity
        root = gate
        self.beam = beam
        self.core = core
        self.glow = glow
        self.warning = warning
        self.emitters = emitters
        authoredBeamSize = [coreSize.x, coreSize.y]
    }

    /// Places the emitters on the wall mounts and stretches the beam between them.
    func setSpan(leftX: Float, rightX: Float) {
        emitters[0].mount.position.x = leftX
        emitters[1].mount.position.x = rightX
        beam.position.x = (leftX + rightX) / 2
        beam.scale.x = (rightX - leftX) / authoredBeamSize.x
    }

    /// Sizes the solid core (and the dashed warning) to the judged band height in meters.
    func setBandHeight(_ height: Float) {
        beam.scale.y = height / authoredBeamSize.y
    }

    func setState(_ newState: VisualState) {
        guard newState != state else { return }
        state = newState
        core.isEnabled = newState == .active || newState == .hit
        glow.isEnabled = core.isEnabled
        warning.isEnabled = newState == .warning
        for emitter in emitters {
            emitter.active.isEnabled = newState != .disabled
            emitter.disabled.isEnabled = newState == .disabled
            if newState == .inactive {
                emitter.active.components.set(OpacityComponent(opacity: 0.5))
            } else {
                emitter.active.components.remove(OpacityComponent.self)
            }
            show(emitter.ring, newState == .warning, animation: Self.pulse)
            show(emitter.spark, newState == .hit, animation: Self.pop)
        }
    }

    private func show(_ entity: Entity, _ visible: Bool, animation: (Transform) -> AnimationResource?) {
        entity.stopAllAnimations()
        entity.scale = .one
        entity.isEnabled = visible
        guard visible, !UIAccessibility.isReduceMotionEnabled, let resource = animation(entity.transform) else { return }
        entity.playAnimation(resource)
    }

    /// Gentle ~1 Hz scale pulse for the warning arcs; no flashing.
    private static func pulse(_ base: Transform) -> AnimationResource? {
        var from = base, to = base
        from.scale = .init(repeating: 0.85)
        to.scale = .init(repeating: 1.1)
        let animation = FromToByAnimation(from: from, to: to, duration: 0.5, timing: .easeInOut,
                                          bindTarget: .transform, repeatMode: .autoReverse)
        return try? AnimationResource.generate(with: animation).repeat()
    }

    /// Short pop-in for the hit spark; it then holds until the state changes.
    private static func pop(_ base: Transform) -> AnimationResource? {
        var from = base
        from.scale = .init(repeating: 0.3)
        let animation = FromToByAnimation(from: from, to: base, duration: 0.16, timing: .easeOut, bindTarget: .transform)
        return try? AnimationResource.generate(with: animation)
    }
}
