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
///
/// State changes animate on RealityKit time, which is cosmetic (TEAM_ALIGNMENT §C):
/// the beam entity and the core's height are never animated, so the visible
/// band always matches the judged band. With Reduce Motion, movement is
/// replaced by fades.
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
    /// Authored transforms of the animated parts, restored on every state change.
    private var restTransforms: [Entity.ID: Transform] = [:]
    private var ringPulses: [AnimationPlaybackController] = []
    private var warningProgress: Float = 0

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
        for part in animatedParts {
            restTransforms[part.id] = part.transform
        }
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

    /// A copy of the authored hit spark, for impacts shown away from the gate.
    func makeImpactSpark() -> Entity {
        let spark = emitters[0].spark.clone(recursive: true)
        spark.transform = .identity
        spark.isEnabled = false
        return spark
    }

    /// How close the warning is to turning active, from 0 (warning shown) to 1
    /// (beam goes solid). Callers derive it from Jevon's warning and cue times;
    /// the dashed beam brightens and the emitter rings pulse faster as it rises.
    func setWarningProgress(_ progress: Float) {
        warningProgress = min(max(progress, 0), 1)
        guard state == .warning else { return }
        warning.components.set(OpacityComponent(opacity: 0.55 + 0.45 * warningProgress))
        for pulse in ringPulses {
            pulse.speed = 1 + 1.5 * warningProgress
        }
    }

    func setState(_ newState: VisualState) {
        guard newState != state else { return }
        // What was lit, so powering down fades from it, e.g. when an attempt is withdrawn.
        let beamWasOn = state == .active || state == .hit
        let litEmitters: Float? = switch state {
        case nil, .disabled: nil
        case .inactive: 0.5
        default: 1
        }
        let litWarning: Float? = state == .warning ? 0.55 + 0.45 * warningProgress : nil
        state = newState
        for part in animatedParts {
            reset(part)
        }
        ringPulses = []
        if newState != .warning {
            warningProgress = 0
        }

        switch newState {
        case .inactive:
            for emitter in emitters {
                emitter.active.isEnabled = true
                emitter.active.components.set(OpacityComponent(opacity: 0.5))
            }
        case .warning:
            // The dashed beam draws across from the left emitter while the rings pulse.
            showEmitters()
            warning.isEnabled = true
            sweepIn(warning, duration: 0.32)
            for emitter in emitters {
                emitter.ring.isEnabled = true
                if let pulse = play(Self.pulse(emitter.ring.transform), on: emitter.ring) {
                    ringPulses.append(pulse)
                }
            }
            setWarningProgress(warningProgress)
        case .active, .hit:
            showEmitters()
            core.isEnabled = true
            glow.isEnabled = true
            if newState == .hit {
                // A short flare of the decorative glow and the emitter sparks.
                flare(glow, height: 1.8, duration: 0.2)
                for emitter in emitters {
                    emitter.spark.isEnabled = true
                    play(Self.pop(emitter.spark.transform), on: emitter.spark)
                }
            } else if !beamWasOn {
                // Ignition: the solid core fires across fast, the glow follows with a flare.
                sweepIn(core, duration: 0.14)
                sweepIn(glow, duration: 0.22, flare: 2.2)
            }
            breathe(glow)
        case .disabled:
            // Power down: whatever was lit fades out and the emitters dim to their disabled art.
            for emitter in emitters {
                emitter.disabled.isEnabled = true
                if let litEmitters {
                    emitter.active.isEnabled = true
                    fade(emitter.active, from: litEmitters, to: 0, duration: 0.25)
                    if litEmitters < 1 {
                        // A dim emitter doesn't hide the disabled art, so cross-fade it in.
                        fade(emitter.disabled, from: 0, to: 1, duration: 0.25)
                    }
                }
            }
            if let litWarning {
                warning.isEnabled = true
                fade(warning, from: litWarning, to: 0, duration: 0.2)
            }
            if beamWasOn {
                core.isEnabled = true
                glow.isEnabled = true
                fade(core, from: 1, to: 0, duration: 0.24)
                fade(glow, from: 1, to: 0, duration: 0.2)
                if let rest = restTransforms[glow.id] {
                    var collapsed = rest
                    collapsed.scale.y *= 0.25
                    settle(glow, from: rest, to: collapsed, duration: 0.2, timing: .easeIn)
                }
            }
        }
    }

    // MARK: - Animation

    private var animatedParts: [Entity] {
        [core, glow, warning] + emitters.flatMap { [$0.active, $0.disabled, $0.ring, $0.spark] }
    }

    private static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    /// Restores a part's authored look and hides it; each state re-shows what it needs.
    private func reset(_ part: Entity) {
        part.stopAllAnimations()
        if let rest = restTransforms[part.id] {
            part.transform = rest
        }
        part.components.remove(OpacityComponent.self)
        part.isEnabled = false
    }

    private func showEmitters() {
        for emitter in emitters {
            emitter.active.isEnabled = true
        }
    }

    /// Grows a beam part across from the left emitter. Only its width and x
    /// position animate, so the core's height (the band) never changes; `flare`
    /// briefly thickens decorative parts such as the glow.
    private func sweepIn(_ part: Entity, duration: TimeInterval, flare: Float = 1) {
        guard let rest = restTransforms[part.id] else { return }
        var from = rest
        from.scale.x = 0.001
        from.scale.y *= flare
        from.translation.x -= authoredBeamSize.x / 2
        settle(part, from: from, to: rest, duration: duration, timing: .easeOut)
    }

    /// Briefly thickens a decorative part, then settles it on its authored height.
    private func flare(_ part: Entity, height: Float, duration: TimeInterval) {
        guard let rest = restTransforms[part.id] else { return }
        var from = rest
        from.scale.y *= height
        settle(part, from: from, to: rest, duration: duration, timing: .easeOut)
    }

    /// Slow, low-contrast glow breathing while the beam is on; no flashing.
    private func breathe(_ part: Entity) {
        part.components.set(OpacityComponent(opacity: 0.85))
        guard !Self.reduceMotion else { return }
        let breathing = FromToByAnimation<Float>(from: 1, to: 0.7, duration: 0.9, timing: .easeInOut,
                                                 bindTarget: .opacity, repeatMode: .autoReverse)
        if let resource = try? AnimationResource.generate(with: breathing).repeat() {
            part.playAnimation(resource, handoffType: .compose)
        }
    }

    /// Fades a part and leaves it at `to`. Fades stay on with Reduce Motion.
    private func fade(_ part: Entity, from: Float, to: Float, duration: TimeInterval) {
        part.components.set(OpacityComponent(opacity: to))
        let animation = FromToByAnimation<Float>(from: from, to: to, duration: duration, timing: .easeIn, bindTarget: .opacity)
        if let resource = try? AnimationResource.generate(with: animation) {
            part.playAnimation(resource, handoffType: .compose)
        }
    }

    /// Animates a part's transform and leaves it at `to`; skipped with Reduce Motion.
    private func settle(_ part: Entity, from: Transform, to: Transform, duration: TimeInterval, timing: AnimationTimingFunction) {
        part.transform = to
        guard !Self.reduceMotion else { return }
        let animation = FromToByAnimation(from: from, to: to, duration: duration, timing: timing, bindTarget: .transform)
        if let resource = try? AnimationResource.generate(with: animation) {
            part.playAnimation(resource, handoffType: .compose)
        }
    }

    @discardableResult
    private func play(_ resource: AnimationResource?, on part: Entity) -> AnimationPlaybackController? {
        guard !Self.reduceMotion, let resource else { return nil }
        return part.playAnimation(resource, handoffType: .compose)
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
