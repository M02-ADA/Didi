//
//  LaserGate.swift
//  Sedactive
//

import RealityKit
import UIKit

/// One LaserHeist security laser: emitters set into the corridor walls and a
/// coral energy beam between them (art in `LaserGateArt`).
///
/// The `LaserGate` Reality Composer Pro scene supplies the named parts and
/// their placement; this class dresses them with the procedural art.
///
/// **The judged band is the only geometry that matters.** The beam's opaque
/// core is exactly the band (`setBandHeight`), and nothing animates its height.
/// The decorative layers follow one rule. A miss is judged at one edge only:
/// a DUCK clears below the band's lower edge, and a JUMP clears above its
/// upper edge (`LaserCollisionJudge`). So the beam's glow may spread only to
/// the danger side (`setDangerSide`). On the safe side, a
/// faint fringe of at most `safeFringe` (the judge's clearance margin) softens
/// the edge. Rendering never decides a state: callers pass the state that
/// Jevon's game state implies (TEAM_ALIGNMENT §B).
///
/// One gate keeps one identity from far away to the crossing, and its beam
/// powers on like an energy blade: during the warning the emitters charge,
/// then the beam extends out of its emitter across the corridor (driven by the
/// warning's own progress, so it is fully extended exactly when the gate turns
/// active); after the verdict it retracts back into the emitter.
///
/// State changes animate on RealityKit time, which is cosmetic (TEAM_ALIGNMENT §C).
/// With Reduce Motion, movement is replaced by fades.
@MainActor
final class LaserGate {
    enum VisualState: String, CaseIterable {
        case inactive, warning, active, hit, disabled
    }

    /// Where the judged danger lies relative to the band: above it for a DUCK
    /// (the crown must stay below), below it for a JUMP (the soles must clear
    /// it). `.both` is for previews with no judged move.
    enum DangerSide {
        case above, below, both
    }

    /// The longest state-change animation (the hit flare and the power-down
    /// fades are 0.2–0.25 s): after it a powered-down gate can be hidden.
    static let longestTransition: Double = 0.25
    /// How far the softened edge may spread past the band's safe edge: the
    /// replay's 5 mm clearance margin. Anything brighter stays inside the band
    /// or on its danger side.
    static let safeFringe: Float = 0.005
    /// How far the authored `LaserMount_*` anchors sit in from the walls, so
    /// the wall plates lie flat on the walls and the barrels reach the beam.
    static let wallInset: Float = 0.07

    /// Gate root, centred on the beam's centre line.
    let root: Entity
    private(set) var state: VisualState?

    // Authored slots (named in the RCP scene; states switch them on and off).
    private let beam: Entity
    private let core: Entity
    private let glow: Entity
    private let warning: Entity
    private let emitters: [Emitter]
    private let authoredBeamSize: SIMD2<Float>
    /// Authored transforms of the animated slots, restored on every state change.
    private var restTransforms: [Entity.ID: Transform] = [:]

    // Code-built layers.
    private let flash = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.flash])
    /// The warning's beam: the same core, shown faint while it charges (in the `Warning` slot).
    private let charge = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.core])
    /// Light spill above and below the band (one is the danger-side glow, the other the safe fringe).
    private let upperSpill = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.halo])
    private let lowerSpill = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.halo])
    private let floorLight = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.floorLight])
    /// Where two players' halves meet at different heights, the beam steps between them here.
    private let riser = Entity()
    private let riserCore = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.core])
    private let riserSpill = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.softGlow])
    /// Energy that runs from the emitter along the armed beam.
    private let packet = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.packet])

    private var span: ClosedRange<Float>
    private var bandHeight: Float
    private var dangerSide: DangerSide = .both
    private var joinOffset: Float?
    private var floorDrop: Float?
    private var emittersShown = (left: true, right: true)
    private var ringPulses: [AnimationPlaybackController] = []
    private var warningProgress: Float = 0
    /// How much of the span the warning's beam covers right now (0…1).
    private var reach: Float = 0

    private struct Emitter {
        /// -1 for the left wall, +1 for the right.
        let outward: Float
        let mount: Entity
        let active: Entity
        let disabled: Entity
        let ring: Entity
        let spark: Entity
        let flare: ModelEntity
        let splash: ModelEntity
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
        var mounts: [(Entity, Entity, Entity, Entity, Entity)] = []
        for name in ["EmitterLeft", "EmitterRight"] {
            guard let mount = part(name, in: gate),
                  let active = part("Active", in: mount), let disabled = part("Disabled", in: mount),
                  let ring = part("WarningRing", in: mount), let spark = part("HitSpark", in: mount)
            else { return nil }
            mounts.append((mount, active, disabled, ring, spark))
        }
        gate.removeFromParent()
        gate.transform = .identity
        root = gate
        self.beam = beam
        self.core = core
        self.glow = glow
        self.warning = warning
        authoredBeamSize = [coreSize.x, coreSize.y]
        span = -coreSize.x / 2...coreSize.x / 2
        bandHeight = coreSize.y

        // The core keeps its authored quad (the band) with the new material;
        // the other authored placeholders are replaced by code-built layers.
        if var model = core.components[ModelComponent.self] {
            model.materials = [LaserGateArt.core]
            core.components.set(model)
        }
        for slot in [glow, warning] { slot.components.remove(ModelComponent.self) }
        // The glow spreads in meters, not with the band, so it hangs off the gate, not the scaled beam.
        glow.removeFromParent()
        glow.transform = .identity
        gate.addChild(glow)
        Self.place(flash, size: [coreSize.x, coreSize.y], at: [0, 0, 0.002], in: beam)
        Self.place(charge, size: [coreSize.x, coreSize.y], at: .zero, in: warning)
        for (part, z) in [(upperSpill, -0.004), (lowerSpill, -0.004)] as [(Entity, Float)] {
            part.position.z = z
            glow.addChild(part)
        }
        floorLight.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        glow.addChild(floorLight)
        riser.addChild(riserSpill)
        riser.addChild(riserCore)
        riserSpill.position.z = -0.004
        riserCore.position.z = 0.0005
        gate.addChild(riser)
        packet.position.z = 0.003
        gate.addChild(packet)

        emitters = mounts.enumerated().map { index, parts in
            let (mount, active, disabled, ring, spark) = parts
            let outward: Float = index == 0 ? -1 : 1
            // Into the wall: rotate a +Z-facing quad to face the corridor.
            let wallFacing = simd_quatf(angle: -outward * .pi / 2, axis: [0, 1, 0])
            for slot in [active, disabled, ring] {
                slot.components.remove(ModelComponent.self)
                slot.transform = .identity
            }
            spark.transform.translation = [0, 0, 0.075]
            // The charge ring lies on the wall plate, so it gathers into the aperture
            // instead of poking through the wall beside it.
            ring.position = [outward * (Self.wallInset - 0.01), 0, 0]
            // Always-installed hardware: a wall plate and a short barrel out to the beam.
            let plate = Self.place(ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.plateMaterial]),
                                   size: [0.34, 0.42], at: [outward * (Self.wallInset - 0.004), 0, 0], in: mount)
            plate.orientation = wallFacing
            let barrel = ModelEntity(mesh: LaserGateArt.barrelMesh, materials: [LaserGateArt.barrelMaterial])
            barrel.position = [outward * Self.wallInset / 2, 0, 0]
            barrel.scale = [Self.wallInset, 1, 1]
            mount.addChild(barrel)
            // Lit: lens at the barrel tip, its light on the wall, and a camera-facing flare.
            let splash = Self.place(ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.splash]),
                                    size: [1.1, 0.85], at: [outward * (Self.wallInset - 0.008), 0, 0], in: active)
            splash.orientation = wallFacing
            let lens = Self.place(ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.lens]),
                                  size: [0.11, 0.11], at: [-outward * 0.001, 0, 0], in: active)
            lens.orientation = wallFacing
            let flare = Self.place(ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.flare]),
                                   size: [0.3, 0.3], at: [0, 0, 0.068], in: active)
            // Off: a cool lens and a faint violet glint.
            let offLens = Self.place(ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.offLens]),
                                     size: [0.11, 0.11], at: [-outward * 0.001, 0, 0], in: disabled)
            offLens.orientation = wallFacing
            Self.place(ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.offFlare]),
                       size: [0.16, 0.16], at: [0, 0, 0.066], in: disabled)
            // Warning: a ring on the plate that gathers into the aperture.
            let gatherRing = Self.place(ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.ring]),
                                        size: [0.4, 0.4], at: .zero, in: ring)
            gatherRing.orientation = wallFacing
            return Emitter(outward: outward, mount: mount, active: active, disabled: disabled, ring: ring, spark: spark,
                           flare: flare, splash: splash)
        }
        for part in animatedSlots {
            restTransforms[part.id] = part.transform
        }
        layout()
        for part in animatedSlots + codeLayers { part.isEnabled = false }
    }

    // MARK: - Geometry (from the presenter; never from animation)

    /// Places the emitters on the wall mounts and stretches the beam between them.
    func setSpan(leftX: Float, rightX: Float) {
        guard span != leftX...rightX else { return }
        span = leftX...rightX
        layout()
    }

    /// Shows or hides each wall emitter. A lane's half of a shared beam shows
    /// only its own wall's emitter; the halves meet at the lane boundary.
    func setEmittersVisible(left: Bool, right: Bool) {
        guard emittersShown != (left, right) else { return }
        emittersShown = (left, right)
        layout()
    }

    /// Sizes the solid core (and the warning's charging beam) to the judged band height in meters.
    func setBandHeight(_ height: Float) {
        guard height != bandHeight else { return }
        bandHeight = height
        layout()
    }

    /// Which side of the band the decorative layers may spread to.
    func setDangerSide(_ side: DangerSide) {
        guard side != dangerSide else { return }
        dangerSide = side
        layout()
    }

    /// Joins this half to its partner's half at the inner end: `offset` is the
    /// height (meters, from this band's centre) where the two meet, so a step
    /// between two players' bands is drawn in the gap between their lanes.
    /// `nil` leaves the inner end free.
    func setJoin(offset: Float?) {
        guard offset != joinOffset else { return }
        joinOffset = offset
        layout()
    }

    /// How far the corridor floor lies below the beam's centre, for the beam's
    /// light on the floor; `nil` hides it.
    func setFloorDrop(_ drop: Float?) {
        guard drop != floorDrop else { return }
        floorDrop = drop
        layout()
    }

    /// A copy of the authored hit spark, for impacts shown away from the gate.
    func makeImpactSpark() -> Entity {
        let spark = emitters[0].spark.clone(recursive: true)
        spark.transform = .identity
        spark.isEnabled = false
        return spark
    }

    /// How far the resting decorative layers along the beam reach past the
    /// band's lower and upper edges, in meters (the fairness rule's check).
    /// The riser is left out: it sits in the gap between the lanes.
    var decorationReach: (below: Float, above: Float) {
        var low: Float = 0, high: Float = 0
        for part in [upperSpill, lowerSpill, packet] where part.isEnabled {
            let half = abs(part.scale.y) / 2
            low = min(low, part.position.y - half)
            high = max(high, part.position.y + half)
        }
        return (max(0, -bandHeight / 2 - low), max(0, high - bandHeight / 2))
    }

    // MARK: - States

    /// Where in the warning the beam starts to extend; before it the emitters only charge.
    static let extensionStart: Float = 0.7
    /// The glowing stub at the aperture while the emitter charges (meters).
    static let stubLength: Float = 0.08

    /// How close the warning is to turning active, from 0 (warning shown) to 1
    /// (the gate turns active). Callers derive it from Jevon's warning and cue
    /// times, so the ignition is deterministic and needs no clock of its own:
    /// - Charge (0 … `extensionStart`): the rings gather faster, the lenses heat
    ///   up, light pools on the walls; only a short glowing stub sits at the aperture.
    /// - Extension (`extensionStart` … 1): the beam grows out of the emitter
    ///   across the corridor with a white-hot tip, eased out (fast start, gentle
    ///   arrival), reaching the far wall exactly as the gate turns active.
    func setWarningProgress(_ progress: Float) {
        warningProgress = min(max(progress, 0), 1)
        guard state == .warning else { return }
        let p = warningProgress
        let charge = min(1, p / Self.extensionStart)
        let t = max(0, (p - Self.extensionStart) / (1 - Self.extensionStart))
        let extended = 1 - pow(1 - t, 3)
        let stub = min(1, Self.stubLength / max(spanLength, 0.01))
        for pulse in ringPulses {
            pulse.speed = 1 + 1.6 * charge
        }
        if Self.reduceMotion {
            for emitter in emitters { emitter.ring.components.set(OpacityComponent(opacity: 0.4 + 0.6 * charge)) }
        }
        for emitter in emitters {
            emitter.active.components.set(OpacityComponent(opacity: 0.55 + 0.45 * charge))
            emitter.splash.components.set(OpacityComponent(opacity: 0.35 + 0.65 * charge * charge))
        }
        // With Reduce Motion the beam doesn't travel: it fades in at full length.
        reach = Self.reduceMotion ? (t > 0 ? 1 : stub) : stub + (1 - stub) * extended
        let brightness: Float = Self.reduceMotion && t > 0 ? 0.35 + 0.65 * extended : 0.45 + 0.55 * max(charge * charge, extended)
        showBeam(reach: reach, opacity: brightness)
        // The glow travels with the beam.
        showGlow()
        floorLight.isEnabled = false
        glow.components.set(OpacityComponent(opacity: 0.9 * extended))
        layoutSpills(reach: reach)
        // The white-hot tip leads the extension.
        packet.isEnabled = t > 0 && t < 1 && !Self.reduceMotion
        packet.position.x = originX - originSide * reach * spanLength
        packet.scale = [0.22, bandHeight, 1]
        packet.components.set(OpacityComponent(opacity: 1))
        riser.isEnabled = hasRiser && extended > 0.98
    }

    /// The warning's beam at `reach` of the span, anchored at the emitter.
    private func showBeam(reach: Float, opacity: Float) {
        warning.isEnabled = true
        warning.transform = beamTransform(reach: reach)
        warning.components.set(OpacityComponent(opacity: opacity))
    }

    /// A beam slot covering `reach` of the span from the emitter end (beam-local units).
    private func beamTransform(reach: Float) -> Transform {
        var transform = restTransforms[warning.id] ?? Transform()
        let r = max(reach, 0.001)
        transform.scale.x *= r
        transform.translation.x += originSide * (1 - r) * authoredBeamSize.x / 2
        return transform
    }

    /// The glow's spills covering `reach` of the span from the emitter end.
    private func layoutSpills(reach: Float) {
        let sizes = spillSizes, r = max(reach, 0.001)
        for (part, upper, height) in [(upperSpill, true, sizes.upper), (lowerSpill, false, sizes.lower)] {
            var transform = spillRest(upper: upper, height: height)
            transform.scale.x = r
            transform.translation.x = originSide * (1 - r) / 2
            part.transform = transform
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
        let litWarning: Float? = state == .warning ? 1 : nil
        let shownReach = state == .warning ? reach : (beamWasOn ? 1 : 0)
        state = newState
        for part in animatedSlots + codeLayers {
            reset(part)
        }
        layout()
        ringPulses = []
        if newState != .warning {
            warningProgress = 0
        }

        switch newState {
        case .inactive:
            // Installed and armed, not firing: dim lenses with a little light on the walls.
            showEmitters()
            for emitter in emitters {
                emitter.active.components.set(OpacityComponent(opacity: 0.5))
                emitter.splash.components.set(OpacityComponent(opacity: 0.5))
            }
        case .warning:
            // The emitters charge, then the beam extends (`setWarningProgress`).
            showEmitters()
            warning.isEnabled = true
            for emitter in emitters {
                emitter.ring.isEnabled = true
                if let gather = play(Self.gather(emitter.ring.transform), on: emitter.ring) {
                    ringPulses.append(gather)
                }
            }
            setWarningProgress(warningProgress)
        case .active, .hit:
            showEmitters()
            core.isEnabled = true
            showGlow()
            riser.isEnabled = hasRiser
            if newState == .hit {
                // A zap, not a celebration: the core flashes white, the light flares, the emitters spark.
                flash.isEnabled = true
                fade(flash, from: 0.9, to: 0, duration: 0.18)
                flareSpill(height: 2.2, duration: 0.22)
                for emitter in emitters {
                    emitter.spark.isEnabled = true
                    play(Self.pop(emitter.spark.transform), on: emitter.spark)
                    fade(emitter.splash, from: 1, to: 0.8, duration: 0.22)
                }
            } else if !beamWasOn {
                // Armed: the extended beam settles into its full look with a soft
                // bloom; the lenses pop and light reaches the floor. If the warning
                // ended before the beam reached the far wall, it finishes extending
                // at once (0.12 s), so it is complete while it can hit anyone.
                if shownReach < 0.999, let rest = restTransforms[core.id] {
                    var from = rest
                    let r = max(shownReach, 0.001)
                    from.scale.x *= r
                    from.translation.x += originSide * (1 - r) * authoredBeamSize.x / 2
                    settle(core, from: from, to: rest, duration: 0.12, timing: .easeOut)
                }
                flash.isEnabled = true
                fade(flash, from: 0.3, to: 0, duration: 0.14)
                flareSpill(height: 1.4, duration: 0.22)
                fade(floorLight, from: 0, to: floorLightOpacity, duration: 0.2)
                fade(riser, from: 0, to: 1, duration: 0.14)
                for emitter in emitters {
                    play(Self.pop(emitter.flare.transform, from: 1.7, duration: 0.18), on: emitter.flare)
                    fade(emitter.splash, from: 1, to: 0.8, duration: 0.3)
                }
            }
            if newState == .active {
                hum()
                runPackets()
            }
        case .disabled:
            // Power down: the lenses cool to violet, the beam drains back into the emitter and fades.
            for emitter in emitters {
                emitter.disabled.isEnabled = true
                if let litEmitters {
                    emitter.active.isEnabled = true
                    emitter.flare.isEnabled = true
                    emitter.splash.isEnabled = true
                    fade(emitter.active, from: litEmitters, to: 0, duration: 0.25)
                    if litEmitters < 1 {
                        // A dim emitter doesn't hide the cool lens, so cross-fade it in.
                        fade(emitter.disabled, from: 0, to: 1, duration: 0.25)
                    }
                }
            }
            if beamWasOn || (litWarning != nil && shownReach > 0) {
                // Retraction: the beam pulls back into its emitter as it fades (the
                // warning slot carries it: the same core, so nothing swaps), the glow
                // follows and a last streak drains into the lens. With Reduce Motion
                // it fades in place.
                let rest = beamTransform(reach: shownReach)
                showBeam(reach: shownReach, opacity: 1)
                settle(warning, from: rest, to: Self.reduceMotion ? rest : beamTransform(reach: 0), duration: 0.25, timing: .easeIn)
                fade(warning, from: litWarning == nil ? 1 : 0.9, to: 0, duration: 0.25)
                showGlow()
                floorLight.isEnabled = beamWasOn && floorLightOpacity > 0
                riser.isEnabled = hasRiser
                fade(glow, from: beamWasOn ? 1 : 0.9, to: 0, duration: 0.22)
                fade(riser, from: 1, to: 0, duration: 0.18)
                retractSpills(from: shownReach, duration: 0.22)
                if beamWasOn { drainPacket(duration: 0.22) }
            }
        }
    }

    // MARK: - Layout

    private var spanLength: Float { span.upperBound - span.lowerBound }
    private var hasRiser: Bool { (joinOffset.map { abs($0) > 0.002 }) ?? false }
    /// The emitter end of the beam: the wall whose emitter is shown (left when both are).
    private var originSide: Float { emittersShown.left || !emittersShown.right ? -1 : 1 }
    private var innerX: Float { originSide < 0 ? span.upperBound : span.lowerBound }
    /// The emitter end of the span, where the beam extends from and retracts into.
    private var originX: Float { originSide < 0 ? span.lowerBound : span.upperBound }
    /// Only a beam running near the floor (a JUMP) lights it; a DUCK beam high up
    /// leaves the floor dark, so no red smudges collect around the mascots' legs.
    private var floorLightOpacity: Float {
        guard let floorDrop, floorDrop < Self.floorLightReach else { return 0 }
        return 0.3 * (1 - floorDrop / Self.floorLightReach)
    }
    static let floorLightReach: Float = 1.0

    private struct SpillSizes {
        let upper: Float
        let lower: Float
    }

    /// How far the danger-side glow reaches past the band: one soft bloom that
    /// merges into the core, not separate lines.
    static let dangerGlow: Float = 0.11


    /// Danger-side glow against safe-side fringe, in meters beyond each band edge.
    /// Below a JUMP band the glow stops short of the corridor floor.
    private var spillSizes: SpillSizes {
        switch dangerSide {
        case .above: return SpillSizes(upper: Self.dangerGlow, lower: Self.safeFringe)
        case .below:
            let room = floorDrop.map { max(Self.safeFringe, $0 - bandHeight / 2 - 0.02) } ?? Self.dangerGlow
            return SpillSizes(upper: Self.safeFringe, lower: min(Self.dangerGlow, room))
        case .both: return SpillSizes(upper: 0.06, lower: 0.06)
        }
    }

    /// Puts every layer at rest for the current span, band, side, join and floor.
    private func layout() {
        let centerX = (span.lowerBound + span.upperBound) / 2
        emitters[0].mount.position.x = span.lowerBound
        emitters[1].mount.position.x = span.upperBound
        emitters[0].mount.isEnabled = emittersShown.left
        emitters[1].mount.isEnabled = emittersShown.right
        beam.position.x = centerX
        beam.scale = [spanLength / authoredBeamSize.x, bandHeight / authoredBeamSize.y, 1]
        glow.position = [centerX, 0, 0]
        glow.scale = [spanLength, 1, 1]
        let sizes = spillSizes
        upperSpill.transform = spillRest(upper: true, height: sizes.upper)
        lowerSpill.transform = spillRest(upper: false, height: sizes.lower)
        upperSpill.components.set(OpacityComponent(opacity: dangerSide == .below ? 0.7 : 1))
        lowerSpill.components.set(OpacityComponent(opacity: dangerSide == .above ? 0.7 : 1))
        if let floorDrop {
            floorLight.position = [0, -floorDrop + 0.004, 0]
            floorLight.scale = [1, 3, 1]
            floorLight.components.set(OpacityComponent(opacity: floorLightOpacity))
        }
        let offset = joinOffset ?? 0
        riser.position = [innerX, 0, 0]
        // The core's gradient runs across the band, so the vertical riser is the
        // same quad turned a quarter: hot along its middle, coral at its sides.
        riserCore.position.y = offset / 2
        riserCore.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        riserCore.scale = [abs(offset) + bandHeight, bandHeight, 1]
        riserSpill.position.y = offset / 2
        riserSpill.scale = [bandHeight + 0.05, abs(offset) + bandHeight + 0.04, 1]
        packet.position = [innerX, 0, 0.003]
        packet.scale = [0.5, bandHeight, 1]
    }

    /// One spill quad at rest: anchored on its band edge, reaching `height` beyond it.
    private func spillRest(upper: Bool, height: Float) -> Transform {
        let sign: Float = upper ? 1 : -1
        var transform = Transform()
        transform.translation = [0, sign * (bandHeight / 2 + height / 2), 0]
        transform.scale = [1, height, 1]
        // The texture fades upward from its bottom edge; below the band, turn it
        // half a turn in its own plane so it fades downward and still faces the camera.
        if !upper {
            transform.rotation = simd_quatf(angle: .pi, axis: [0, 0, 1])
        }
        return transform
    }

    // MARK: - Animation

    private var animatedSlots: [Entity] {
        [core, glow, warning] + emitters.flatMap { [$0.active, $0.disabled, $0.ring, $0.spark] }
    }

    private var codeLayers: [Entity] {
        [flash, floorLight, riser, packet, upperSpill, lowerSpill] + emitters.flatMap { [$0.flare, $0.splash] }
    }

    private static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    /// Restores a part's resting look and hides it; each state re-shows what it needs.
    private func reset(_ part: Entity) {
        part.stopAllAnimations()
        if let rest = restTransforms[part.id] {
            part.transform = rest
        }
        part.components.remove(OpacityComponent.self)
        part.isEnabled = false
    }

    /// Shows the light around the beam: both spills and the floor light.
    private func showGlow() {
        glow.isEnabled = true
        upperSpill.isEnabled = true
        lowerSpill.isEnabled = true
        floorLight.isEnabled = floorLightOpacity > 0
    }

    private func showEmitters() {
        for emitter in emitters {
            emitter.active.isEnabled = true
            emitter.flare.isEnabled = true
            emitter.splash.isEnabled = true
        }
    }

    /// A HIT: the danger-side light flares and settles; the safe fringe stays put.
    private func flareSpill(height: Float, duration: TimeInterval) {
        let sizes = spillSizes
        for (part, upper, size) in [(upperSpill, true, sizes.upper), (lowerSpill, false, sizes.lower)] where size > Self.safeFringe {
            settle(part, from: spillRest(upper: upper, height: size * height), to: spillRest(upper: upper, height: size),
                   duration: duration, timing: .easeOut)
        }
    }

    /// Retraction: the glow shrinks back toward the emitter with the beam.
    private func retractSpills(from reach: Float, duration: TimeInterval) {
        let sizes = spillSizes, r = max(reach, 0.001)
        for (part, upper, height) in [(upperSpill, true, sizes.upper), (lowerSpill, false, sizes.lower)] {
            var from = spillRest(upper: upper, height: height)
            from.scale.x = r
            from.translation.x = originSide * (1 - r) / 2
            var to = from
            if !Self.reduceMotion {
                to.scale.x = 0.001
                to.translation.x = originSide * 0.5
            }
            settle(part, from: from, to: to, duration: duration, timing: .easeIn)
        }
    }

    /// The armed beam hums: its danger-side light swells and settles, slow and
    /// low-contrast, with no flashing. Decorative only; the core never moves.
    private func hum() {
        glow.components.set(OpacityComponent(opacity: 1))
        guard !Self.reduceMotion else { return }
        let breathing = FromToByAnimation<Float>(from: 1, to: 0.8, duration: 0.9, timing: .easeInOut,
                                                 bindTarget: .opacity, repeatMode: .autoReverse)
        if let resource = try? AnimationResource.generate(with: breathing).repeat() {
            glow.playAnimation(resource, handoffType: .compose)
        }
        let sizes = spillSizes
        for (part, upper, size) in [(upperSpill, true, sizes.upper), (lowerSpill, false, sizes.lower)] where size > Self.safeFringe {
            let swell = FromToByAnimation(from: spillRest(upper: upper, height: size),
                                          to: spillRest(upper: upper, height: size * 1.2), duration: 0.9,
                                          timing: .easeInOut, bindTarget: .transform, repeatMode: .autoReverse)
            if let resource = try? AnimationResource.generate(with: swell).repeat() {
                part.playAnimation(resource, handoffType: .compose)
            }
        }
    }

    /// Energy runs out of the emitter along the armed beam, about once a
    /// second, fading as it goes. Two halves of a shared beam meet in the middle.
    private func runPackets() {
        guard !Self.reduceMotion else { return }
        packet.isEnabled = true
        var from = packet.transform, to = packet.transform
        from.translation.x = originSide < 0 ? span.lowerBound + Self.wallInset : span.upperBound - Self.wallInset
        to.translation.x = innerX
        let duration = TimeInterval(max(spanLength, 0.5) / 5.5)
        let move = FromToByAnimation(from: from, to: to, duration: duration, timing: .linear, bindTarget: .transform)
        let dim = FromToByAnimation<Float>(from: 0.9, to: 0.15, duration: duration, timing: .easeIn, bindTarget: .opacity)
        let rest = FromToByAnimation<Float>(from: 0, to: 0, duration: 0.45, bindTarget: .opacity)
        guard let moving = try? AnimationResource.group(with: [AnimationResource.generate(with: move),
                                                              AnimationResource.generate(with: dim)]),
              let pause = try? AnimationResource.generate(with: rest),
              let cycle = try? AnimationResource.sequence(with: [moving, pause]).repeat()
        else { return }
        packet.playAnimation(cycle, handoffType: .compose)
    }

    /// Power-down: a last streak drains from the beam back into the emitter.
    private func drainPacket(duration: TimeInterval) {
        guard !Self.reduceMotion else { return }
        packet.isEnabled = true
        var from = packet.transform, to = packet.transform
        from.translation.x = innerX
        to.translation.x = originSide < 0 ? span.lowerBound + Self.wallInset : span.upperBound - Self.wallInset
        to.scale.x *= 0.5
        settle(packet, from: from, to: to, duration: duration, timing: .easeIn)
        fade(packet, from: 1, to: 0, duration: duration)
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
    private func settle(_ part: Entity, from: Transform, to: Transform, duration: TimeInterval,
                        timing: AnimationTimingFunction, delay: TimeInterval = 0) {
        part.transform = to
        guard !Self.reduceMotion else { return }
        let animation = FromToByAnimation(from: from, to: to, duration: duration, timing: timing, bindTarget: .transform,
                                          fillMode: .backwards, delay: delay)
        if let resource = try? AnimationResource.generate(with: animation) {
            part.playAnimation(resource, handoffType: .compose)
        }
    }

    @discardableResult
    private func play(_ resource: AnimationResource?, on part: Entity) -> AnimationPlaybackController? {
        guard !Self.reduceMotion, let resource else { return nil }
        return part.playAnimation(resource, handoffType: .compose)
    }

    /// Warning: a ring closes in on the aperture and brightens, over and over,
    /// faster as the warning runs out. Energy gathering, not a flashing alarm.
    private static func gather(_ base: Transform) -> AnimationResource? {
        var from = base, to = base
        from.scale = .init(repeating: 1.25)
        to.scale = .init(repeating: 0.3)
        let close = FromToByAnimation(from: from, to: to, duration: 0.6, timing: .easeIn, bindTarget: .transform)
        let brighten = FromToByAnimation<Float>(from: 0.1, to: 1, duration: 0.6, timing: .easeIn, bindTarget: .opacity)
        guard let a = try? AnimationResource.generate(with: close), let b = try? AnimationResource.generate(with: brighten),
              let group = try? AnimationResource.group(with: [a, b])
        else { return nil }
        return group.repeat()
    }

    /// A short pop: the part starts at `from` times its size and settles.
    private static func pop(_ base: Transform, from scale: Float = 0.3, duration: TimeInterval = 0.16) -> AnimationResource? {
        var from = base
        from.scale = base.scale * scale
        let animation = FromToByAnimation(from: from, to: base, duration: duration, timing: .easeOut, bindTarget: .transform)
        return try? AnimationResource.generate(with: animation)
    }

    @discardableResult
    private static func place<E: Entity>(_ entity: E, size: SIMD2<Float>, at position: SIMD3<Float>, in parent: Entity) -> E {
        entity.scale = [size.x, size.y, 1]
        entity.position = position
        parent.addChild(entity)
        return entity
    }
}
