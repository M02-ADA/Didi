//
//  VerticalLaser.swift
//  Sedactive
//

import RealityKit
import UIKit

/// PROTOTYPE (Kevin, 15 November 2026): a vertical security laser for a future LEAN encounter, a
/// coral beam dropped from a ceiling emitter into a floor receiver. Visual only: no encounter,
/// GameClock, collision, judgment or score uses it yet; only the DEBUG `VerticalLaserPreview` shows
/// it. The palette and materials are the horizontal gate's (`LaserGateArt`).
///
/// **What makes it a vertical obstacle, not a turned horizontal beam:**
/// - Hardware at both ends: a pod hanging from the ceiling and a low receiver plinth on the floor,
///   so its lateral place in the shared corridor is anchored to the floor, where perspective makes
///   it readable. It is a post you go around, at any `x`; nothing assumes a P1 or P2 lane.
/// - Its own power-on story, in the warning: the emitter charges (rings gather into its lens), fires
///   a pilot spark that falls to the floor, the receiver locks on (a blip), then the beam pours
///   down into it. When the gate turns active the beam lands: a flash, and a ring of light spreads
///   across the floor. Energy runs downward while armed; on power-down the beam pulls back up
///   into the ceiling.
///
/// **Deterministic and scrubbable:** `present(_:ambientTime:)` sets every layer from the phase alone,
/// with no RealityKit animations, so the same input always draws the same frame. Callers derive the
/// phase from game time later (warning progress, seconds since active or since the verdict), the
/// way `LaserGate.setWarningProgress` is driven. `ambientTime` only drives the cosmetic hum and
/// energy packets (TEAM_ALIGNMENT §C).
///
/// **Judged geometry:** the opaque core is `coreWidth` wide and never changes width; nothing moves it
/// sideways. The glow spreads `glowReach` past both edges. A vertical beam has no danger side (a
/// player may pass on either), so before LEAN gameplay the team must decide whether the judged width
/// is the core alone (the horizontal rule allows only a 5 mm fringe on a safe side) or includes the
/// glow (`lateralDecorationReach`).
///
/// Reduce Motion: no falling pilot, travelling tip, gathering rings, packets or hum; the beam fades
/// in at full length and fades out in place.
@MainActor
final class VerticalLaser {
    enum Phase: Equatable {
        /// Installed and armed, not firing: dim lenses and the beam's unpowered path.
        case inactive
        /// From 0 (warning shown) to 1 (the gate turns active).
        case warning(progress: Float)
        /// Seconds since the gate turned active.
        case active(elapsed: Double)
        /// Seconds since it powered down (after the verdict).
        case powerDown(elapsed: Double)
        /// Powered down: hardware only, cool violet lenses.
        case off
    }

    // MARK: Timing (shares of the warning, and seconds)

    /// Charging until the pilot spark falls…
    static let pilotStart: Float = 0.45
    /// …and the receiver locks and the beam pours down from here to the end of the warning.
    static let extensionStart: Float = 0.62
    /// The landing when the gate turns active (flash, floor ring, bloom).
    static let impactDuration: Double = 0.22
    static let powerDownDuration: Double = 0.3
    static let humPeriod: Double = 1.8
    static let packetPeriod: Double = 0.9

    // MARK: Geometry (meters)

    /// The opaque core's width (prototype value; the judged width is TBD with Jevon).
    static let coreWidth: Float = 0.05
    /// How far the glow spreads past each core edge at rest.
    static let glowReach: Float = 0.09
    /// The emitter pod below the ceiling, and its collar around the lens.
    static let podLength: Float = 0.2
    static let collarHeight: Float = 0.04
    /// The floor receiver plinth.
    static let receiverSize: SIMD3<Float> = [0.3, 0.07, 0.3]
    /// The glowing stub at the emitter while it charges.
    static let stubLength: Float = 0.08

    let root = Entity()
    private(set) var phase: Phase?
    private(set) var x: Float = 0
    private(set) var worldZ: Float = 0
    /// Overridable for tests and the DEBUG preview's `reduced` option.
    var reduceMotion = UIAccessibility.isReduceMotionEnabled

    /// The emitter's aperture and the receiver's, in world Y: the beam runs between them.
    let topY: Float
    let bottomY: Float
    private let ceilingY: Float
    private let floorY: Float
    private let cameraPosition: SIMD3<Float>
    private let interactionPlaneZ: Float
    private var beamLength: Float { topY - bottomY }

    /// Turned about Y to face the camera, so the flat beam layers read as a round beam from any lateral place.
    private let facing = Entity()
    private let core = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.core])
    private let haloLeft = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.halo])
    private let haloRight = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.halo])
    private let trace = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.trace])
    private let flash = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.flash])
    /// The white-hot end of the beam while it pours down or pulls back up.
    private let tip = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.packet])
    /// Energy running down the armed beam.
    private let packet = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.packet])
    /// The pilot spark that falls from the emitter to the receiver, and its short trail.
    private let pilot = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.flare])
    private let pilotTrail = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.packet])
    private let emitterFlare = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.flare])
    private let emitterOffFlare = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.offFlare])
    private let receiverFlare = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.flare])
    private let receiverOffFlare = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.offFlare])
    private let emitterRing = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.ring])
    private let receiverRing = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.ring])
    // On the hardware (world-facing).
    private let emitterLens = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.lens])
    private let emitterOffLens = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.offLens])
    private let receiverLens = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.lens])
    private let receiverOffLens = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.offLens])
    private let ceilingSplash = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.splash])
    private let floorPool = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.splash])
    private let impactRing = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.ring])

    private static let sizes = (flare: Float(0.3), offFlare: Float(0.16), ring: Float(0.4), lens: Float(0.11),
                                pilot: Float(0.14), pool: Float(1.3), impact: Float(1.0), splash: Float(0.9))

    init(layout: LaserWorldLayout = LaserWorldLayout(), mapping: GameWorldMapping = GameWorldMapping()) {
        ceilingY = layout.corridorHeight
        floorY = layout.corridorFloorY
        cameraPosition = layout.cameraPosition
        interactionPlaneZ = mapping.interactionPlaneZ
        topY = ceilingY - Self.podLength - Self.collarHeight
        bottomY = floorY + Self.receiverSize.y
        root.name = "verticalLaser"
        buildHardware()
        buildBeam()
        setPlacement(x: 0, worldZ: layout.laserEmergeZ)
        present(.inactive)
    }

    private static let down = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
    private static let up = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
    /// A +X-running quad (the core's and glow's gradients run across v) turned to run vertically.
    private static let upright = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])

    /// The always-installed hardware: a ceiling plate and pod with a lighter collar around the
    /// downward lens; a floor plinth with a rim, its top plate and an upward lens.
    private func buildHardware() {
        func add(_ entity: Entity, at position: SIMD3<Float>, scale: SIMD3<Float> = .one, orientation: simd_quatf? = nil) {
            entity.position = position
            entity.scale = scale
            if let orientation { entity.orientation = orientation }
            root.addChild(entity)
        }
        let plate = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.plateMaterial])
        add(plate, at: [0, ceilingY - 0.012, 0], scale: [0.34, 0.42, 1], orientation: Self.down)
        let pod = ModelEntity(mesh: LaserGateArt.barrelMesh, materials: [LaserGateArt.barrelMaterial])
        add(pod, at: [0, ceilingY - Self.podLength / 2, 0], scale: [Self.podLength, 1.2, 1.2], orientation: Self.upright)
        let collar = ModelEntity(mesh: .generateBox(width: 0.19, height: Self.collarHeight, depth: 0.19, cornerRadius: 0.012),
                                 materials: [LaserGateArt.flat(LaserGateArt.plateRim)])
        add(collar, at: [0, ceilingY - Self.podLength - Self.collarHeight / 2, 0])
        add(emitterLens, at: [0, topY - 0.001, 0], scale: [Self.sizes.lens, Self.sizes.lens, 1], orientation: Self.down)
        add(emitterOffLens, at: [0, topY - 0.0012, 0], scale: [Self.sizes.lens, Self.sizes.lens, 1], orientation: Self.down)
        add(ceilingSplash, at: [0, ceilingY - 0.016, 0], scale: [Self.sizes.splash, Self.sizes.splash, 1], orientation: Self.down)

        let size = Self.receiverSize
        let plinth = ModelEntity(mesh: .generateBox(width: size.x, height: size.y, depth: size.z, cornerRadius: 0.02),
                                 materials: [LaserGateArt.barrelMaterial])
        add(plinth, at: [0, floorY + size.y / 2, 0])
        let rim = ModelEntity(mesh: .generateBox(width: size.x + 0.012, height: 0.014, depth: size.z + 0.012, cornerRadius: 0.006),
                              materials: [LaserGateArt.flat(LaserGateArt.plateRim)])
        add(rim, at: [0, bottomY - 0.007, 0])
        let top = ModelEntity(mesh: LaserGateArt.unitQuad, materials: [LaserGateArt.plateMaterial])
        add(top, at: [0, bottomY + 0.0008, 0], scale: [0.26, 0.3, 1], orientation: Self.up)
        add(receiverLens, at: [0, bottomY + 0.0016, 0], scale: [Self.sizes.lens, Self.sizes.lens, 1], orientation: Self.up)
        add(receiverOffLens, at: [0, bottomY + 0.0014, 0], scale: [Self.sizes.lens, Self.sizes.lens, 1], orientation: Self.up)
        add(floorPool, at: [0, floorY + 0.012, 0], scale: [Self.sizes.pool, Self.sizes.pool, 1], orientation: Self.up)
        add(impactRing, at: [0, floorY + 0.014, 0], orientation: Self.up)
    }

    /// The camera-facing beam layers, back to front: path, glow, core, flash, tip and packets, flares.
    private func buildBeam() {
        root.addChild(facing)
        let layers: [(Entity, Float)] = [(trace, -0.006), (haloLeft, -0.004), (haloRight, -0.004), (core, 0), (flash, 0.002),
                                         (tip, 0.003), (packet, 0.003), (pilotTrail, 0.004), (pilot, 0.005),
                                         (emitterRing, 0.012), (receiverRing, 0.012),
                                         (emitterOffFlare, 0.018), (receiverOffFlare, 0.018), (emitterFlare, 0.02), (receiverFlare, 0.02)]
        for (layer, z) in layers {
            layer.position.z = z
            facing.addChild(layer)
        }
        for layer in [core, tip, packet, pilotTrail] { layer.orientation = Self.upright }
        // The halo fades outward from its v = 0 edge: a quarter turn puts that edge against the core.
        haloLeft.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        haloRight.orientation = simd_quatf(angle: -.pi / 2, axis: [0, 0, 1])
        emitterFlare.position.y = topY
        emitterOffFlare.position.y = topY
        emitterRing.position.y = topY
        receiverFlare.position.y = bottomY + 0.01
        receiverOffFlare.position.y = bottomY + 0.01
        receiverRing.position.y = bottomY + 0.01
    }

    // MARK: - Placement (from the caller; never animated)

    /// Puts the obstacle at a lateral world X and depth. Far away it emerges from the corridor's
    /// haze like a horizontal gate; past the players it resolves the same way (`LaserHazard`).
    /// `appearance` (0…1) fades the whole obstacle in where it first stands
    /// (`VerticalLaserTrack.appearDuration`), so it never pops in or jumps sideways.
    func setPlacement(x: Float, worldZ: Float, appearance: Float = 1) {
        self.x = x
        self.worldZ = worldZ
        root.position = [x, 0, worldZ]
        facing.orientation = simd_quatf(angle: atan2(cameraPosition.x - x, cameraPosition.z - worldZ), axis: [0, 1, 0])
        let haze = CorridorDepth.haze(atDistance: viewDistance)
        let past = worldZ - interactionPlaneZ
        let t = Self.clamp((past - LaserHazard.resolveStart) / (LaserHazard.resolveEnd - LaserHazard.resolveStart))
        opacity = (1 - haze) * (1 - Self.smooth(t)) * Self.clamp(appearance)
        if opacity > 0.999 {
            root.components.remove(OpacityComponent.self)
        } else {
            root.components.set(OpacityComponent(opacity: opacity))
        }
        layoutTrace()
    }

    /// The obstacle's whole-assembly opacity from haze and resolve (tests and debugging).
    private(set) var opacity: Float = 1
    private var viewDistance: Float { cameraPosition.z - worldZ }

    // MARK: - Presentation

    /// Draws `phase`. `ambientTime` (any cosmetic clock, seconds) only drives the armed hum and packets.
    func present(_ phase: Phase, ambientTime: Double = 0) {
        self.phase = phase
        var look = Look()
        switch phase {
        case .inactive:
            look.trace = LaserGate.traceOpacity
            look.emitterHeat = 0.5
            look.receiverHeat = 0.4
            look.ceilingSplash = 0.3
        case .warning(let raw):
            warning(Self.clamp(raw), into: &look)
        case .active(let elapsed):
            active(max(0, elapsed), ambientTime: ambientTime, into: &look)
        case .powerDown(let elapsed):
            powerDown(max(0, elapsed), into: &look)
        case .off:
            look.emitterOff = 1
            look.receiverOff = 1
        }
        apply(look)
    }

    /// Every layer's value for one frame; zero is hidden.
    private struct Look {
        var trace: Float = 0
        /// The lit beam's lower end (it always hangs from the emitter), and its opacity.
        var beamBottom: Float?
        var core: Float = 0
        var halo: Float = 0
        var haloSpread: Float = 1
        var flash: Float = 0
        var tip: Float = 0
        var packet: (y: Float, opacity: Float)?
        var pilot: (y: Float, opacity: Float)?
        var emitterHeat: Float = 0, receiverHeat: Float = 0
        var emitterOff: Float = 0, receiverOff: Float = 0
        var emitterPop: Float = 1, receiverPop: Float = 1
        var emitterRing: (scale: Float, opacity: Float)?
        var receiverRing: (scale: Float, opacity: Float)?
        var ceilingSplash: Float = 0
        var floorPool: Float = 0
        var impact: (scale: Float, opacity: Float)?
    }

    /// Charge → pilot → lock → pour. The beam is full length exactly at `progress` 1.
    private func warning(_ p: Float, into look: inout Look) {
        let charge = min(1, p / Self.pilotStart)
        look.trace = LaserGate.traceOpacity
        look.emitterHeat = 0.55 + 0.45 * charge
        look.receiverHeat = 0.4 + 0.2 * charge
        look.ceilingSplash = 0.3 + 0.5 * charge * charge
        // Charge: rings gather into the emitter's lens, faster as the warning runs out.
        if p < Self.extensionStart {
            let u = p / Self.extensionStart
            if reduceMotion {
                look.emitterRing = (0.7, 0.4 + 0.6 * charge)
            } else {
                let cycle = (1.6 * u + 1.6 * u * u).truncatingRemainder(dividingBy: 1)
                let e = cycle * cycle
                look.emitterRing = (1.25 + (0.3 - 1.25) * e, (0.1 + 0.9 * e) * (1 - Self.smooth(Self.clamp((u - 0.85) / 0.15))))
            }
        }
        // A short stub glows at the emitter while it charges.
        look.beamBottom = topY - Self.stubLength
        look.core = 0.45 + 0.55 * charge * charge
        // The pilot spark falls under gravity (eased in) and the receiver locks as it lands.
        if p >= Self.pilotStart, p < Self.extensionStart, !reduceMotion {
            let u = (p - Self.pilotStart) / (Self.extensionStart - Self.pilotStart)
            look.pilot = (topY - beamLength * u * u, 1)
        }
        if p >= Self.extensionStart {
            look.receiverHeat = 1
            let lock = Self.clamp((p - Self.extensionStart) / 0.14)
            look.receiverRing = reduceMotion ? (0.8, 1 - lock) : (0.3 + 0.9 * Self.easeOut(lock), 1 - lock)
            look.floorPool = 0.25 * lock
            // The pour: fast start, gentle arrival, reaching the receiver exactly as the gate turns active.
            let t = (p - Self.extensionStart) / (1 - Self.extensionStart)
            let poured = Self.easeOut(t)
            let reach = reduceMotion ? 1 : Self.stubLength / beamLength + (1 - Self.stubLength / beamLength) * poured
            look.beamBottom = topY - beamLength * reach
            look.core = reduceMotion ? 0.35 + 0.65 * poured : 0.45 + 0.55 * max(charge * charge, poured)
            look.halo = 0.9 * poured
            look.tip = !reduceMotion && t < 1 ? 1 : 0
        }
    }

    /// The landing, then the hum: the core never changes; only light around it moves.
    private func active(_ elapsed: Double, ambientTime: Double, into look: inout Look) {
        let k = Float(min(1, elapsed / Self.impactDuration))
        let landed = Self.easeOut(k)
        look.beamBottom = bottomY
        look.core = 1
        look.emitterHeat = 1
        look.receiverHeat = 1
        look.ceilingSplash = 0.8
        look.flash = elapsed < 0.14 ? 0.35 * (1 - Float(elapsed / 0.14)) : 0
        look.floorPool = 0.25 + 0.35 * Self.clamp(Float(elapsed / 0.2))
        look.halo = 1
        if reduceMotion {
            look.impact = k < 1 ? (1, 0.6 * (1 - k)) : nil
            return
        }
        look.haloSpread = 1 + 0.5 * (1 - landed)
        look.receiverPop = 1 + 0.7 * (1 - landed)
        look.emitterPop = 1 + 0.3 * (1 - landed)
        look.impact = k < 1 ? (0.35 + 1.1 * landed, 0.8 * (1 - k)) : nil
        // Hum: a slow, low-contrast swell of the glow, with no flashing.
        look.halo = 0.88 + 0.12 * Float(cos(2 * .pi * ambientTime / Self.humPeriod))
        // Energy runs down into the receiver about once a second, once the landing has settled.
        let cycle = Float((ambientTime / Self.packetPeriod).truncatingRemainder(dividingBy: 1))
        if elapsed > Self.impactDuration, cycle < 0.7 {
            let u = cycle / 0.7
            look.packet = (topY - 0.06 - (beamLength - 0.12) * u, 0.9 - 0.75 * u * u)
        }
    }

    /// The beam pulls back up into the emitter (eased in) as it fades; the receiver lets go first.
    private func powerDown(_ elapsed: Double, into look: inout Look) {
        let d = Float(min(1, elapsed / Self.powerDownDuration))
        look.emitterHeat = 1 - d
        look.emitterOff = d
        look.receiverHeat = max(0, 1 - 2 * d)
        look.receiverOff = min(1, 2 * d)
        look.ceilingSplash = 0.8 * (1 - d)
        look.floorPool = 0.6 * (1 - Self.clamp(Float(elapsed / 0.2)))
        guard d < 1 else { return }
        if reduceMotion {
            look.beamBottom = bottomY
            look.core = 1 - d
            look.halo = 1 - d
        } else {
            look.beamBottom = bottomY + beamLength * d * d
            look.core = 1 - d * d
            look.halo = 1 - d
            look.tip = 1 - d
        }
    }

    private func apply(_ look: Look) {
        show(trace, look.trace)
        layoutTrace()
        // Hidden layers are laid out too, so a frame depends only on its own inputs (scrubbing).
        let bottom = look.beamBottom ?? topY
        do {
            let length = max(topY - bottom, 0.001), middle = (topY + bottom) / 2
            core.position.y = middle
            core.scale = [length, Self.coreWidth, 1]
            flash.position.y = middle
            flash.scale = [Self.coreWidth, length, 1]
            let reach = Self.glowReach * look.haloSpread
            for (halo, side) in [(haloLeft, Float(-1)), (haloRight, 1)] {
                halo.position = [side * (Self.coreWidth / 2 + reach / 2), middle, halo.position.z]
                halo.scale = [length, reach, 1]
            }
            tip.position.y = bottom + 0.11
            tip.scale = [0.24, Self.coreWidth, 1]
            let lit = topY - bottom > 0.001
            show(core, lit ? look.core : 0)
            show(haloLeft, lit ? look.halo : 0)
            show(haloRight, lit ? look.halo : 0)
            show(flash, lit ? look.flash : 0)
            show(tip, lit ? look.tip : 0)
        }
        packet.position.y = look.packet?.y ?? topY
        packet.scale = [0.45, Self.coreWidth, 1]
        show(packet, look.packet?.opacity ?? 0)
        pilot.position.y = look.pilot?.y ?? topY
        pilot.scale = [Self.sizes.pilot, Self.sizes.pilot, 1]
        pilotTrail.position.y = pilot.position.y + 0.16
        pilotTrail.scale = [0.3, 0.035, 1]
        show(pilot, look.pilot?.opacity ?? 0)
        show(pilotTrail, look.pilot?.opacity ?? 0)

        show(emitterLens, look.emitterHeat)
        show(emitterOffLens, look.emitterOff)
        show(receiverLens, look.receiverHeat)
        show(receiverOffLens, look.receiverOff)
        emitterFlare.scale = [Self.sizes.flare * look.emitterPop, Self.sizes.flare * look.emitterPop, 1]
        receiverFlare.scale = [Self.sizes.flare * look.receiverPop, Self.sizes.flare * look.receiverPop, 1]
        show(emitterFlare, look.emitterHeat)
        show(receiverFlare, look.receiverHeat)
        for flare in [emitterOffFlare, receiverOffFlare] { flare.scale = [Self.sizes.offFlare, Self.sizes.offFlare, 1] }
        show(emitterOffFlare, look.emitterOff)
        show(receiverOffFlare, look.receiverOff)
        for (ring, value) in [(emitterRing, look.emitterRing), (receiverRing, look.receiverRing)] {
            let scale = Self.sizes.ring * (value?.scale ?? 1)
            ring.scale = [scale, scale, 1]
            show(ring, value?.opacity ?? 0)
        }
        show(ceilingSplash, look.ceilingSplash)
        show(floorPool, look.floorPool)
        let impactScale = Self.sizes.impact * (look.impact?.scale ?? 1)
        impactRing.scale = [impactScale, impactScale, 1]
        show(impactRing, look.impact?.opacity ?? 0)
    }

    /// The unpowered path, full length; never narrower than the core, and far away at least ~0.1° of
    /// view (`LaserGate.traceAngle`), easing back to the core's width as it comes into warning range.
    private func layoutTrace() {
        trace.position.y = (topY + bottomY) / 2
        trace.scale = [traceWidth, beamLength, 1]
    }

    var traceWidth: Float {
        if case .warning = phase { return Self.coreWidth }
        let t = Self.clamp((viewDistance - LaserGate.traceNear) / (LaserGate.traceFar - LaserGate.traceNear))
        return Self.coreWidth + max(0, viewDistance * LaserGate.traceAngle - Self.coreWidth) * Self.smooth(t)
    }

    private func show(_ entity: Entity, _ opacity: Float) {
        entity.isEnabled = opacity > 0.001
        if opacity >= 0.999 || opacity <= 0.001 {
            entity.components.remove(OpacityComponent.self)
        } else {
            entity.components.set(OpacityComponent(opacity: opacity))
        }
    }

    // MARK: - Diagnostics (tests and the preview's log)

    /// The lit beam's world-Y span, or `nil` when no beam is drawn.
    var litSpan: ClosedRange<Float>? {
        guard core.isEnabled else { return nil }
        return (core.position.y - core.scale.x / 2)...(core.position.y + core.scale.x / 2)
    }
    /// The drawn core's width (constant: judged geometry never animates).
    var drawnCoreWidth: Float { core.scale.y }
    var showsTrace: Bool { trace.isEnabled }
    /// Whether anything coral is drawn along the beam's path (core, glow, tip, packets, pilot).
    var isEnergized: Bool { [core, haloLeft, haloRight, tip, packet, pilot].contains { $0.isEnabled } }
    /// How far drawn layers reach past each core edge, sideways (the fairness question above).
    var lateralDecorationReach: Float { haloLeft.isEnabled ? haloLeft.scale.y : 0 }
    /// The beam layers' turn toward the camera (radians about Y).
    var facingAngle: Float { facing.orientation.angle * (facing.orientation.axis.y < 0 ? -1 : 1) }

    // MARK: - Easing

    private static func clamp(_ x: Float) -> Float { min(max(x, 0), 1) }
    private static func smooth(_ t: Float) -> Float { t * t * (3 - 2 * t) }
    private static func easeOut(_ t: Float) -> Float { 1 - pow(1 - clamp(t), 3) }
}
