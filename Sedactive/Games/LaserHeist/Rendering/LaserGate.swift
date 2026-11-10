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
/// upper edge (`LaserCollisionJudge`). So glow, tracer lines and the curtain
/// may spread only to the danger side (`setDangerSide`). On the safe side, a
/// faint fringe of at most `safeFringe` (the judge's clearance margin) softens
/// the edge. Rendering never decides a state: callers pass the state that
/// Jevon's game state implies (TEAM_ALIGNMENT §B).
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
    private let dashes = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.dashes(repeats: 14)])
    /// Light spill above and below the band (one is the danger halo, the other the safe fringe).
    private let upperSpill = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.halo])
    private let lowerSpill = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.halo])
    /// Danger-side curtain: a faint sheet and two tracer lines beyond the band.
    private let curtain = Entity()
    private let sheet = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.sheet])
    private let tracers = (0..<2).map { _ in ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.tracer]) }
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
        Self.place(dashes, size: [coreSize.x, coreSize.y], at: .zero, in: warning)
        for (part, z) in [(upperSpill, -0.004), (lowerSpill, -0.004)] as [(Entity, Float)] {
            part.position.z = z
            glow.addChild(part)
        }
        curtain.position.z = -0.003
        glow.addChild(curtain)
        curtain.addChild(sheet)
        for tracer in tracers { curtain.addChild(tracer) }
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

    /// Sizes the solid core (and the dashed warning) to the judged band height in meters.
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
        for part in [upperSpill, lowerSpill, packet, sheet] + tracers where part.isEnabled {
            let parentY = part.parent === curtain ? curtain.position.y : 0
            let half = abs(part.scale.y) / 2
            low = min(low, parentY + part.position.y - half)
            high = max(high, parentY + part.position.y + half)
        }
        return (max(0, -bandHeight / 2 - low), max(0, high - bandHeight / 2))
    }

    // MARK: - States

    /// How close the warning is to turning active, from 0 (warning shown) to 1
    /// (beam goes solid). Callers derive it from Jevon's warning and cue times.
    /// The charge builds as it rises: the dashes brighten, the rings gather
    /// faster, the lenses heat up and light starts to spill.
    func setWarningProgress(_ progress: Float) {
        warningProgress = min(max(progress, 0), 1)
        guard state == .warning else { return }
        let p = warningProgress
        warning.components.set(OpacityComponent(opacity: 0.5 + 0.5 * p))
        for pulse in ringPulses {
            pulse.speed = 1 + 1.6 * p
        }
        if Self.reduceMotion {
            for emitter in emitters { emitter.ring.components.set(OpacityComponent(opacity: 0.4 + 0.6 * p)) }
        }
        for emitter in emitters {
            emitter.active.components.set(OpacityComponent(opacity: 0.55 + 0.45 * p))
            emitter.splash.components.set(OpacityComponent(opacity: 0.35 + 0.65 * p * p))
        }
        // Charge-up: light gathers on the danger side, eased in, so ignition reads as earned.
        showGlow(curtain: false)
        glow.isEnabled = p > 0
        glow.components.set(OpacityComponent(opacity: 0.45 * p * p))
        riser.isEnabled = hasRiser
        riser.components.set(OpacityComponent(opacity: 0.25 + 0.35 * p))
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
        let litWarning: Float? = state == .warning ? 0.5 + 0.5 * warningProgress : nil
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
            // The dashed targeting line draws out of the emitter while energy gathers into it.
            showEmitters()
            warning.isEnabled = true
            sweepIn(warning, duration: 0.32)
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
            showGlow(curtain: true)
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
                // Ignition, front-loaded: the core fires out of the emitter, then
                // the light and the curtain follow, the lenses flash, light hits the floor.
                sweepIn(core, duration: 0.12)
                sweepSpill(duration: 0.2, flare: 1.7)
                sweepCurtain(duration: 0.26, delay: 0.05)
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
            if let litWarning {
                warning.isEnabled = true
                fade(warning, from: litWarning, to: 0, duration: 0.2)
            }
            if beamWasOn {
                core.isEnabled = true
                showGlow(curtain: true)
                riser.isEnabled = hasRiser
                fade(core, from: 1, to: 0, duration: 0.22)
                fade(glow, from: 1, to: 0, duration: 0.2)
                fade(curtain, from: 1, to: 0, duration: 0.14)
                fade(riser, from: 1, to: 0, duration: 0.2)
                collapseSpill(duration: 0.2)
                drainPacket(duration: 0.2)
            }
        }
    }

    // MARK: - Layout

    private var spanLength: Float { span.upperBound - span.lowerBound }
    private var hasRiser: Bool { (joinOffset.map { abs($0) > 0.002 }) ?? false }
    /// The emitter end of the beam: the wall whose emitter is shown (left when both are).
    private var originSide: Float { emittersShown.left || !emittersShown.right ? -1 : 1 }
    private var innerX: Float { originSide < 0 ? span.upperBound : span.lowerBound }
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

    /// Danger-side halo against safe-side fringe, in meters beyond each band edge.
    private var spillSizes: SpillSizes {
        switch dangerSide {
        case .above: SpillSizes(upper: 0.05, lower: Self.safeFringe)
        case .below: SpillSizes(upper: Self.safeFringe, lower: 0.05)
        case .both: SpillSizes(upper: 0.035, lower: 0.035)
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
        if var model = dashes.components[ModelComponent.self] {
            model.materials = [LaserGateArt.dashes(repeats: (spanLength / LaserGateArt.dashPeriod).rounded())]
            dashes.components.set(model)
        }
        glow.position = [centerX, 0, 0]
        glow.scale = [spanLength, 1, 1]
        let sizes = spillSizes
        upperSpill.transform = spillRest(upper: true, height: sizes.upper)
        lowerSpill.transform = spillRest(upper: false, height: sizes.lower)
        upperSpill.components.set(OpacityComponent(opacity: dangerSide == .below ? 0.7 : 1))
        lowerSpill.components.set(OpacityComponent(opacity: dangerSide == .above ? 0.7 : 1))
        layoutCurtain()
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

    /// The danger-side curtain: two tracer lines and a sheet beyond the far edge.
    /// For a JUMP it stops above the floor; previews (`.both`) have none.
    private func layoutCurtain() {
        guard dangerSide != .both else { return }
        let sign: Float = dangerSide == .above ? 1 : -1
        let edge = bandHeight / 2
        // Room below a JUMP band before the floor.
        let room = dangerSide == .below ? max(0, (floorDrop ?? .infinity) - edge - 0.03) : .infinity
        for (index, tracer) in tracers.enumerated() {
            let gap = 0.065 * Float(index + 1)
            tracer.isEnabled = gap + 0.007 <= room
            tracer.position = [0, sign * (edge + gap), 0]
            tracer.scale = [1, 0.016, 1]
            tracer.components.set(OpacityComponent(opacity: index == 0 ? 0.8 : 0.5))
        }
        let sheetHeight = min(0.15, room)
        sheet.isEnabled = sheetHeight > 0.02
        sheet.transform = spillRest(upper: sign > 0, height: sheetHeight)
    }

    // MARK: - Animation

    private var animatedSlots: [Entity] {
        [core, glow, warning] + emitters.flatMap { [$0.active, $0.disabled, $0.ring, $0.spark] }
    }

    private var codeLayers: [Entity] {
        [flash, curtain, floorLight, riser, packet, upperSpill, lowerSpill] + emitters.flatMap { [$0.flare, $0.splash] }
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

    /// Shows the light around the beam: both spills, the floor light and, on
    /// request, the danger-side curtain (never for a preview with no danger side).
    private func showGlow(curtain showsCurtain: Bool) {
        glow.isEnabled = true
        upperSpill.isEnabled = true
        lowerSpill.isEnabled = true
        floorLight.isEnabled = floorLightOpacity > 0
        curtain.isEnabled = showsCurtain && dangerSide != .both
    }

    private func showEmitters() {
        for emitter in emitters {
            emitter.active.isEnabled = true
            emitter.flare.isEnabled = true
            emitter.splash.isEnabled = true
        }
    }

    /// Grows a beam slot out of the emitter. Only its width and x position
    /// animate, so the core's height (the band) never changes.
    private func sweepIn(_ part: Entity, duration: TimeInterval) {
        guard let rest = restTransforms[part.id] else { return }
        var from = rest
        from.scale.x = 0.001
        from.translation.x += originSide * authoredBeamSize.x / 2
        settle(part, from: from, to: rest, duration: duration, timing: .easeOut)
    }

    /// The spill follows the core out of the emitter, briefly flared on its danger side.
    private func sweepSpill(duration: TimeInterval, flare: Float) {
        let sizes = spillSizes
        for (part, upper, height) in [(upperSpill, true, sizes.upper), (lowerSpill, false, sizes.lower)] {
            let rest = spillRest(upper: upper, height: height)
            var from = spillRest(upper: upper, height: height * (height > Self.safeFringe ? flare : 1))
            from.scale.x = 0.001
            from.translation.x = originSide * 0.5
            settle(part, from: from, to: rest, duration: duration, timing: .easeOut)
        }
    }

    private func sweepCurtain(duration: TimeInterval, delay: TimeInterval) {
        guard curtain.isEnabled else { return }
        var from = Transform()
        from.scale.x = 0.001
        from.translation.x = originSide * 0.5
        settle(curtain, from: from, to: Transform(), duration: duration, timing: .easeOut, delay: delay)
    }

    /// A HIT: the danger-side light flares and settles; the safe fringe stays put.
    private func flareSpill(height: Float, duration: TimeInterval) {
        let sizes = spillSizes
        for (part, upper, size) in [(upperSpill, true, sizes.upper), (lowerSpill, false, sizes.lower)] where size > Self.safeFringe {
            settle(part, from: spillRest(upper: upper, height: size * height), to: spillRest(upper: upper, height: size),
                   duration: duration, timing: .easeOut)
        }
    }

    /// Power-down: the light shrinks back onto the band as it fades.
    private func collapseSpill(duration: TimeInterval) {
        let sizes = spillSizes
        for (part, upper, size) in [(upperSpill, true, sizes.upper), (lowerSpill, false, sizes.lower)] {
            settle(part, from: spillRest(upper: upper, height: size), to: spillRest(upper: upper, height: size * 0.25),
                   duration: duration, timing: .easeIn)
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
                                          to: spillRest(upper: upper, height: size * 1.35), duration: 0.9,
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
