//
//  HoverboardReaction.swift
//  Sedactive
//

import Foundation
import RealityKit
import UIKit

/// A hoverboard's own energy system answering its player's verdict (Kevin, 18 November 2026:
/// board-integrated, then an impact pass the same day). Presentation only: it reads a shown CLEAR
/// or HIT and moves nothing judged. The board's X stays its ride (`LateralSteering`), its deck top
/// stays under the feet, and the lane never moves.
///
/// Everything belongs to the board (`PlayerHoverboard.usdz`) and lives in its model's space: the
/// raised rim ring, its four rim plates, the emblem "sun" core, the light bars, the deck's circuit
/// lines, chevrons and groove, the vent slots and the thrusters (their materials), the thrusters'
/// light on the floor, and three thin layers built from the rim's own outline:
/// - the rim's energy skin (`RimOutline.segment`), 1 mm off the rim, lit segment by segment;
/// - the energy field (`RimOutline.field`), a low translucent curtain rising from the rim lip:
///   the board's glow, since RealityKit draws no bloom here;
/// - HIT only, short jagged discharges that start and end on the rim lip (`RimOutline.arc`).
///
/// - CLEAR (PERFECT!'s gold): the core ignites on the first frame, a gold charge races from the
///   core round both sides of the ring (0.14 s), the whole system flashes warm white for two frames
///   and holds a radiant gold peak with the field standing tall, then releases through gold and
///   amber to idle. Charge → golden peak → release → idle.
/// - HIT (ZAPPED!'s coral-red, hot pink and its white-hot flash): a white-hot flash on the first
///   frame, the ring and field in full coral-red with four arcs crackling over the rim, a surge
///   running round the ring while the rest flickers, a short dead gap, a secondary coral jolt
///   with hot-pink arcs, then a brownout and reboot. Shock → surge → unstable flicker → recovery.
/// UNAVAILABLE gets none. A new reaction restarts the board's one reaction (never stacks).
nonisolated enum HoverboardReaction: Equatable, Sendable {
    case clear, hit

    /// One short beat each.
    var duration: Double { self == .clear ? 0.66 : 0.6 }

    /// The rim's segment count: the ring lights segment by segment (a radar sweep).
    static let segments = 32
    /// Where HIT's discharges strike: the rim's front left and right, and over each end.
    static let arcSites = 4
    /// Shapes per site (the current changes shape on twos).
    static let arcVariants = 3

    /// One energy channel's state: `energy` 0 is the authored look, 1 the peak; below 0 the
    /// authored lights dim (HIT's brownout). `heat` picks the colour from deep (0) to the
    /// white-hot highlight (1).
    struct Glow: Equatable, Sendable {
        var energy: Float = 0
        var heat: Float = 0

        /// The step the materials use (a few material swaps per reaction, never one per frame).
        var level: Int {
            energy >= 0 ? Int((min(1, energy) * 12).rounded()) : -Int((min(0.8, -energy) * 10).rounded())
        }
        var tone: Int { Int((max(0, min(1, heat)) * 3).rounded()) }
        /// The energy field's opacity step (0 hidden … 8).
        var fieldLevel: Int { Int((max(0, min(1, energy)) * 8).rounded()) }
    }

    /// One frame of a reaction (the rim's segments, field and arcs have their own functions).
    struct Pose: Equatable, Sendable {
        /// HIT's brief shudder (radians of roll); the deck drops by its rise under the feet.
        var roll: Float = 0
        /// The emblem's sun and disc.
        var core = Glow()
        /// The four plates set into the rim.
        var plates = Glow()
        /// The deck's circuit lines, chevrons and the groove inside the rim.
        var circuit = Glow()
        /// The light bars on the band.
        var bars = Glow()
        /// The vent slots, the thrusters and their light on the floor.
        var vents = Glow()
    }

    /// One HIT discharge: where on the rim, which shape, and whether it is the secondary one.
    struct Arc: Equatable, Sendable {
        var site: Int
        var variant: Int
        var secondary: Bool
    }

    // MARK: Timing

    /// CLEAR: the charge meets at the back, flashes warm white, then holds the gold peak.
    static let meet = 0.14
    static let flashEnd = 0.18
    static let peakEnd = 0.26
    /// Where the rim's front and back plates sit, as `frontDistance` (35°/145°/215°/325° round the outline).
    static let frontPlates: Float = 0.306
    static let backPlates: Float = 0.694
    /// HIT: the white-hot flash, the full coral surge, the unstable flicker, a dead gap, the
    /// secondary discharge, then the brownout and reboot.
    static let flashOut = 0.035
    static let surgeEnd = 0.07
    static let disruptEnd = 0.21
    static let dischargeStart = 0.25
    static let dischargeEnd = 0.32

    /// The pose at `tau` seconds (pure, deterministic). Reduce Motion: no sweep, flicker, arcs,
    /// brownout or shudder; every light fades up to its colour and back.
    func pose(at tau: Double, reduceMotion: Bool) -> Pose {
        var p = Pose()
        guard tau >= 0, tau < duration else { return p }
        if reduceMotion {
            let glow = calm(tau)
            p.core = glow; p.plates = glow; p.circuit = glow; p.bars = glow; p.vents = glow
            return p
        }
        if self == .clear {
            let flash = Glow(energy: 1, heat: 1), gold = Glow(energy: 1, heat: 0.4)
            let peak = tau >= Self.meet && tau < Self.peakEnd ? (tau < Self.flashEnd ? flash : gold) : nil
            p.core = peak ?? (tau < 0.05 ? flash : tau < Self.meet ? Glow(energy: 0.9, heat: 0.4)
                : cool(tau, from: Self.peakEnd, to: duration, heat: 0.4))
            let h = Self.sweepHead(tau)
            p.plates = peak ?? (tau < Self.meet ? (h >= Self.backPlates ? Glow(energy: 1, heat: 0.7)
                : h >= Self.frontPlates ? Glow(energy: 0.85, heat: 0.4) : Glow())
                : cool(tau, from: Self.peakEnd, to: duration - 0.04, heat: 0.4))
            p.bars = peak ?? (tau < Self.meet ? Glow(energy: Float(0.65 + 0.3 * tau / Self.meet), heat: 0.4)
                : cool(tau, from: Self.peakEnd, to: duration - 0.06, heat: 0.4))
            // The charge floods from the ring into the deck as it meets at the back.
            p.circuit = peak ?? (tau < 0.05 ? Glow()
                : tau < Self.meet ? Glow(energy: Float(0.75 * Self.smooth(0.05, Self.meet, tau)), heat: 0.4)
                : cool(tau, from: Self.peakEnd, to: duration - 0.1, heat: 0.4))
            p.vents = peak ?? (tau < 0.04 ? Glow()
                : tau < Self.meet ? Glow(energy: Float(0.7 * Self.smooth(0.04, Self.meet, tau)), heat: 0.4)
                : cool(tau, from: Self.peakEnd, to: duration, heat: 0.4))
        } else {
            p.roll = Float(0.02 * exp(-tau / 0.09) * sin(2 * .pi * 15 * tau))
            if tau < Self.surgeEnd {
                // The shock lands on frame one: white-hot, then the full coral-red surge.
                let surge = tau < Self.flashOut ? Glow(energy: 1, heat: 1) : Glow(energy: 1, heat: 0)
                p.core = surge; p.plates = surge; p.circuit = surge; p.bars = surge; p.vents = surge
            } else if tau < Self.dischargeStart {
                // Instability on twos (12 Hz), each channel out of step; mostly red, a pink accent.
                let k = min(5, max(0, Int((tau - Self.surgeEnd) * 12)))
                p.core = Self.stutter(k, [(1, 0.4), (0.15, 0), (0.95, 0), (-0.3, 0), (0.7, 0.4), (0.2, 0)])
                p.bars = Self.stutter(k, [(-0.5, 0), (1, 0), (0.2, 0), (0.9, 0.4), (-0.45, 0), (0.4, 0)])
                p.circuit = Self.stutter(k, [(0.9, 0), (0.3, 0), (0.85, 0.4), (0.1, 0), (0.5, 0), (0, 0)])
                p.plates = Self.stutter(k, [(0.9, 0.4), (0.25, 0), (1, 0), (0.35, 0), (0.6, 0.7), (0.1, 0)])
                p.vents = Self.stutter(k, [(0.8, 0), (-0.3, 0), (0.7, 0), (0.1, 0), (0.4, 0), (0, 0)])
            } else if tau < Self.dischargeEnd {
                // The secondary discharge: one more coral jolt through everything (its arcs hot pink).
                let jolt = tau < Self.dischargeStart + 0.035 ? Glow(energy: 1, heat: 0.4) : Glow(energy: 0.6, heat: 0)
                p.core = jolt; p.plates = jolt; p.circuit = jolt; p.bars = jolt; p.vents = jolt
            } else {
                // Brownout, then the board reboots to its idle look.
                let reboot = Glow(energy: Float(-0.55 * (1 - Self.smooth(Self.dischargeEnd, duration, tau))), heat: 0)
                p.core = reboot; p.bars = reboot; p.vents = reboot
            }
        }
        return p
    }

    /// The rim's segment `index` at `tau` (0 is the authored rim).
    func segment(_ index: Int, at tau: Double, reduceMotion: Bool) -> Glow {
        guard tau >= 0, tau < duration else { return Glow() }
        if reduceMotion { return calm(tau) }
        let d = Self.frontDistance(index)
        if self == .clear {
            if tau < Self.meet {
                let h = Self.sweepHead(tau)
                if d <= h {
                    // A white-hot head with the gold charge filling the ring behind it.
                    let behind = Double(h - d)
                    return Glow(energy: Float(0.7 + 0.3 * exp(-behind / 0.1)), heat: Float(0.33 + 0.67 * exp(-behind / 0.06)))
                }
                return d - h < 0.07 ? Glow(energy: 0.4, heat: 1) : Glow()
            }
            if tau < Self.flashEnd { return Glow(energy: 1, heat: 1) }
            if tau < Self.peakEnd { return Glow(energy: 1, heat: 0.4) }
            return cool(tau, from: Self.peakEnd, to: duration, heat: 0.4)
        }
        if tau < Self.surgeEnd { return tau < Self.flashOut ? Glow(energy: 1, heat: 1) : Glow(energy: 1, heat: 0) }
        let step = Int(tau * 24) / 2
        if tau < Self.disruptEnd {
            // The surge runs from the struck front round both sides to the back, white-hot and
            // jagged at its head; the ring behind it flickers red, the ring ahead is starved.
            let r = Float((tau - Self.surgeEnd) / (Self.disruptEnd - Self.surgeEnd))
            if abs(d - r) < 0.1 { return Self.hash(index, step &+ 3) > 0.3 ? Glow(energy: 1, heat: Self.hash(index, step) > 0.5 ? 1 : 0.7) : Glow(energy: 0.3, heat: 0) }
            if d > r { return Glow(energy: 0.12, heat: 0) }
            let flicker = Float(Self.hash(index, step))
            return Glow(energy: 0.25 + 0.7 * flicker, heat: Self.hash(index, step &+ 17) > 0.8 ? 0.4 : 0)
        }
        if tau < Self.dischargeStart {
            // A dead gap: the ring drops out but for a few sputtering segments.
            return Self.hash(index, step &+ 29) > 0.8 ? Glow(energy: 0.5, heat: 0) : Glow()
        }
        if tau < Self.dischargeEnd {
            if tau < Self.dischargeStart + 0.035 { return Glow(energy: 1, heat: 0.4) }
            return Self.hash(index, step &+ 41) > 0.4 ? Glow(energy: 0.7, heat: 0) : Glow(energy: 0.2, heat: 0)
        }
        // A red residue drains out of the ring.
        let drain = 1 - Self.smooth(Self.dischargeEnd, Self.dischargeEnd + 0.14, tau)
        return Glow(energy: Float(0.35 * drain), heat: 0)
    }

    /// The energy field over segment `index` at `tau`: its opacity (`energy`) and colour.
    func field(_ index: Int, at tau: Double, reduceMotion: Bool) -> Glow {
        guard tau >= 0, tau < duration else { return Glow() }
        if reduceMotion {
            let glow = calm(tau)
            return Glow(energy: 0.6 * glow.energy, heat: glow.heat)
        }
        let d = Self.frontDistance(index)
        if self == .clear {
            if tau < Self.meet {
                let h = Self.sweepHead(tau)
                guard d <= h else { return Glow() }
                return Glow(energy: Float(0.25 + 0.5 * exp(-Double(h - d) / 0.12)), heat: 0.4)
            }
            if tau < Self.flashEnd { return Glow(energy: 1, heat: 1) }
            if tau < Self.peakEnd { return Glow(energy: 0.9, heat: 0.4) }
            let s = min(1, (tau - Self.peakEnd) / 0.26)
            let e = Float((1 - s) * (1 - s)) * 0.9
            return e < 0.06 ? Glow() : Glow(energy: e, heat: Float(0.4 * (1 - s)))
        }
        if tau < Self.surgeEnd { return tau < Self.flashOut ? Glow(energy: 1, heat: 1) : Glow(energy: 1, heat: 0) }
        let step = Int(tau * 24) / 2
        if tau < Self.disruptEnd {
            let r = Float((tau - Self.surgeEnd) / (Self.disruptEnd - Self.surgeEnd))
            if abs(d - r) < 0.1 { return Glow(energy: 0.9, heat: 0.4) }
            return d < r && Self.hash(index, step &+ 7) > 0.6 ? Glow(energy: 0.55, heat: 0) : Glow()
        }
        if tau >= Self.dischargeStart && tau < Self.dischargeEnd {
            return tau < Self.dischargeStart + 0.035 ? Glow(energy: 0.9, heat: 0.4)
                : Self.hash(index, step &+ 13) > 0.5 ? Glow(energy: 0.5, heat: 0) : Glow()
        }
        return Glow()
    }

    /// HIT's discharges over the rim at `tau`: all four sites on the shock, a crackle of two, a
    /// dead gap, then the secondary (hot-pink) discharge. CLEAR and Reduce Motion have none.
    func arcs(at tau: Double, reduceMotion: Bool) -> [Arc] {
        guard self == .hit, !reduceMotion, tau >= 0 else { return [] }
        let step = Int(tau * 24) / 2
        func arc(_ site: Int, secondary: Bool = false) -> Arc {
            Arc(site: site, variant: Int(Self.hash(site &+ 50, step) * Double(Self.arcVariants)) % Self.arcVariants, secondary: secondary)
        }
        if tau < 0.12 { return (0..<Self.arcSites).map { arc($0) } }
        if tau < 0.19 { return (0..<Self.arcSites).filter { Self.hash($0, step &+ 61) > 0.45 }.map { arc($0) } }
        if tau >= Self.dischargeStart && tau < Self.dischargeEnd {
            let first = Int(Self.hash(step, 71) * 4) % 4
            return [arc(first, secondary: true), arc((first + 2) % 4, secondary: true)]
        }
        return []
    }

    /// How far round the ring segment `index` sits from the front centre (the emblem, 0) to the
    /// back centre (1). Segments count anticlockwise from screen right seen from above, the
    /// asset's own outline order, so the front centre is three quarters of the way round.
    static func frontDistance(_ index: Int) -> Float {
        let u = (Float(index) + 0.5) / Float(segments)
        let offset = abs(u - 0.75)
        return min(offset, 1 - offset) / 0.5
    }

    /// CLEAR's sweep head, 0 (front) to 1 (back): it leaves the core on the first frame (the
    /// front segments already lit), charges fast and lands softly at the back.
    static func sweepHead(_ tau: Double) -> Float {
        let x = min(1, max(0, tau / meet))
        return Float(0.05 + 0.95 * (1 - (1 - x) * (1 - x)))
    }

    /// Smooth release from the peak: quick at first, a long soft tail; the colour cools too.
    private func cool(_ tau: Double, from: Double, to: Double, heat: Float) -> Glow {
        let s = min(1, max(0, (tau - from) / (to - from)))
        let e = Float((1 - s) * (1 - s))
        return e < 0.02 ? Glow() : Glow(energy: e, heat: heat * Float(1 - s))
    }

    /// Reduce Motion: one soft rise and fall, in the reaction's colour.
    private func calm(_ tau: Double) -> Glow {
        let e = Float(0.85 * sin(.pi * min(1, tau / duration)))
        return e < 0.02 ? Glow() : Glow(energy: e, heat: self == .clear ? 0.4 : 0)
    }

    private static func stutter(_ k: Int, _ steps: [(Float, Float)]) -> Glow {
        let (energy, heat) = steps[min(k, steps.count - 1)]
        return Glow(energy: energy, heat: heat)
    }

    // MARK: Curves

    static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }
    static func hash(_ a: Int, _ b: Int) -> Double {
        var h = UInt64(truncatingIfNeeded: a &* 73_856_093 ^ b &* 19_349_663) &+ 0x9E37_79B9_7F4A_7C15
        h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
        h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((h ^ (h >> 31)) % 10_000) / 10_000
    }
}

/// Drives one board's own surfaces through a reaction. The `Body` mesh's material slots are found
/// by their authored colours (one named material each, `Art/LaserHeist/Hoverboard/`), and each
/// lit look is made once per step and shared by both boards. Materials change only when a
/// channel's step changes (a few times per reaction), meshes are made once per app run, and the
/// board is exactly as authored at rest. The per-player accent stripes are left alone.
@MainActor
final class HoverboardReactionFX {
    /// The board's lit parts, by their authored colour in `hoverboard_build.py`.
    enum Role: CaseIterable, Hashable {
        case ring, plates, groove, deckLines, chevrons, lightBars, sun, emblem, slots, thrusters

        var authoredColor: UInt32 {
            switch self {
            case .ring: 0x9282D4
            case .plates: 0xC6BEEA
            case .groove: 0x2F2970
            case .deckLines: 0x2E295E
            case .chevrons: 0xF4E0C2
            case .lightBars: 0xFFE4B8
            case .sun: 0xFCD79A
            case .emblem: 0x2A2360
            case .slots: 0x2C2566
            case .thrusters: 0xFFD9A0
            }
        }

        /// Peak emission and how far the surface takes the energy's colour. Gold above about
        /// 1.3 clips to pale yellow (no bloom), so the ring and plates stay just under it.
        var peak: (intensity: Float, tint: Float) {
            switch self {
            case .ring: (1.3, 0.9)
            case .plates: (1.8, 0.95)
            case .groove: (1.6, 1)
            case .deckLines: (2.4, 1)
            case .chevrons: (2.0, 0.95)
            case .lightBars: (2.2, 0.95)
            case .sun: (3.6, 0.95)
            case .emblem: (1.2, 0.7)
            case .slots: (1.8, 1)
            case .thrusters: (3.5, 0.9)
            }
        }

        /// Only authored lights brown out.
        var isLight: Bool { self == .lightBars || self == .sun || self == .thrusters }

        func glow(in pose: HoverboardReaction.Pose) -> HoverboardReaction.Glow {
            switch self {
            case .ring: HoverboardReaction.Glow()
            case .plates: pose.plates
            case .groove, .deckLines, .chevrons: pose.circuit
            case .lightBars: pose.bars
            case .sun, .emblem: pose.core
            case .slots, .thrusters: pose.vents
            }
        }
    }

    /// Deep → white-hot, per reaction. CLEAR is PERFECT!'s gold (amber, radiant gold, golden
    /// yellow, warm white). HIT reuses ZAPPED!'s own colours (`LaserTeamCalloutView`'s red face,
    /// the zap's coral `LaserGateArt.coral`, the hot-pink face, the zap's white-hot
    /// `LaserGateArt.hot`), so a struck board reads red and coral with brief white and pink.
    static func tone(_ kind: HoverboardReaction, _ tone: Int) -> SIMD3<Float> {
        let tones: [SIMD3<Float>] = kind == .clear
            ? [[1, 0.52, 0.1], [1, 0.74, 0.1], [1, 0.86, 0.3], [1, 0.95, 0.8]]
            : [[0.96, 0.22, 0.26], [1, 0.27, 0.35], [1, 0.23, 0.5], [1, 0.95, 0.93]]
        return tones[max(0, min(3, tone))]
    }

    /// Holds the reaction's layers beside the model, given the model's transform every frame
    /// (`PlayerHoverboard.apply`), so they bank, hover and ride with the board while the model's
    /// own bounds (the steering's board width) stay exactly the asset's.
    let anchor = Entity()
    /// The rim's energy skin.
    let ribbon: ModelEntity
    /// The energy field rising from the rim lip.
    let field: ModelEntity
    /// HIT's discharges, one per site.
    let arcs: [ModelEntity]
    private let body: ModelEntity?
    /// The Body's materials at rest: authored, with each lit slot rebuilt once as a fresh copy
    /// (`fresh(_:)`), so a reaction only ever switches between materials the board owns.
    private let restMaterials: [any RealityKit.Material]
    /// The `Body` slot each role drives.
    private let slots: [(index: Int, role: Role)]
    private var kind: HoverboardReaction = .clear
    private var shownBody: [MaterialKey?] = []
    private var shownRibbon: [MaterialKey?] = []
    private var shownField: [FieldKey?] = []
    private var shownArcs: [HoverboardReaction.Arc?] = []

    init(root: Entity, model: Entity) {
        body = Self.findBody(in: model)
        var rest = body?.model?.materials ?? []
        var slots: [(Int, Role)] = []
        for (index, material) in rest.enumerated() {
            guard let pbr = material as? PhysicallyBasedMaterial, let role = Self.role(of: pbr) else { continue }
            slots.append((index, role))
            let authored = Self.authored[role] ?? Self.fresh(pbr)
            Self.authored[role] = authored
            rest[index] = authored
        }
        restMaterials = rest
        if let body, var component = body.model, !slots.isEmpty {
            component.materials = rest
            body.model = component
        }
        self.slots = slots
        shownBody = Array(repeating: nil, count: slots.count)
        shownRibbon = Array(repeating: nil, count: HoverboardReaction.segments)
        shownField = Array(repeating: nil, count: HoverboardReaction.segments)
        shownArcs = Array(repeating: nil, count: HoverboardReaction.arcSites)
        let rim = Self.authored[.ring].map { $0 as any RealityKit.Material } ?? SimpleMaterial()
        ribbon = ModelEntity(mesh: Self.ribbonMesh, materials: Array(repeating: rim, count: HoverboardReaction.segments))
        ribbon.name = "hoverboard.rimEnergy"
        field = ModelEntity(mesh: Self.fieldMesh, materials: Array(repeating: Self.hiddenField, count: HoverboardReaction.segments))
        field.name = "hoverboard.energyField"
        arcs = (0..<HoverboardReaction.arcSites).map { site in
            let arc = ModelEntity(mesh: Self.arcMeshes[site][0], materials: [Self.arcOuter, Self.arcCore])
            arc.name = "hoverboard.discharge\(site)"
            return arc
        }
        anchor.name = "hoverboard.reaction"
        anchor.transform = model.transform
        root.addChild(anchor)
        for entity in [ribbon, field] + arcs {
            entity.isEnabled = false
            anchor.addChild(entity)
        }
    }

    /// The reaction's colours from its first frame.
    func start(_ kind: HoverboardReaction) {
        self.kind = kind
        shownBody = shownBody.map { _ in nil }
        shownRibbon = shownRibbon.map { _ in nil }
        shownField = shownField.map { _ in nil }
        ribbon.isEnabled = true
    }

    /// Lights the board for one frame of the reaction.
    func apply(_ pose: HoverboardReaction.Pose, tau: Double, reduceMotion: Bool) {
        if let body, var model = body.model, model.materials.count == restMaterials.count {
            let keys = slots.map { Self.key(kind, $0.role, $0.role.glow(in: pose)) }
            if keys != shownBody {
                shownBody = keys
                for (slot, key) in zip(slots, keys) {
                    model.materials[slot.index] = key.map(Self.material) ?? restMaterials[slot.index]
                }
                body.model = model
            }
        }
        let segments = 0..<HoverboardReaction.segments
        let ringKeys = segments.map { Self.key(kind, .ring, kind.segment($0, at: tau, reduceMotion: reduceMotion)) }
        if ringKeys != shownRibbon, var model = ribbon.model {
            shownRibbon = ringKeys
            let rim = Self.authored[.ring].map { $0 as any RealityKit.Material } ?? model.materials[0]
            model.materials = ringKeys.map { $0.map(Self.material) ?? rim }
            ribbon.model = model
        }
        let fieldKeys = segments.map { i -> FieldKey? in
            let glow = kind.field(i, at: tau, reduceMotion: reduceMotion)
            return glow.fieldLevel > 0 ? FieldKey(kind: kind, tone: glow.tone, level: glow.fieldLevel) : nil
        }
        if fieldKeys != shownField, var model = field.model {
            shownField = fieldKeys
            field.isEnabled = fieldKeys.contains { $0 != nil }
            model.materials = fieldKeys.map { $0.map(Self.fieldMaterial) ?? Self.hiddenField }
            field.model = model
        }
        var shown = shownArcs.map { _ in HoverboardReaction.Arc?.none }
        for arc in kind.arcs(at: tau, reduceMotion: reduceMotion) where arc.site < shown.count { shown[arc.site] = arc }
        if shown != shownArcs {
            shownArcs = shown
            for (entity, arc) in zip(arcs, shown) {
                entity.isEnabled = arc != nil
                guard let arc, var model = entity.model else { continue }
                model.mesh = Self.arcMeshes[arc.site][arc.variant]
                model.materials = [arc.secondary ? Self.arcSecondary : Self.arcOuter, Self.arcCore]
                entity.model = model
            }
        }
    }

    /// The board exactly as authored again.
    func reset() {
        for entity in [ribbon, field] + arcs { entity.isEnabled = false }
        if let body, var model = body.model, model.materials.count == restMaterials.count, shownBody.contains(where: { $0 != nil }) {
            model.materials = restMaterials
            body.model = model
        }
        shownBody = shownBody.map { _ in nil }
        shownRibbon = shownRibbon.map { _ in nil }
        shownField = shownField.map { _ in nil }
        shownArcs = shownArcs.map { _ in nil }
    }

    /// The thrusters' floor light for this frame: its tint (nil: authored) and brightness factor.
    static func floorLight(_ kind: HoverboardReaction, _ pose: HoverboardReaction.Pose) -> (tint: HoverboardReaction?, scale: Float) {
        let vents = pose.vents.energy
        if vents > 0.05 { return (kind, 1 + 1.6 * vents) }
        return (nil, 1 + min(0, vents))
    }

    // MARK: Board materials

    private struct MaterialKey: Hashable {
        let kind: HoverboardReaction
        let role: Role
        let tone: Int
        let level: Int
    }

    private static var authored: [Role: PhysicallyBasedMaterial] = [:]
    private static var made: [MaterialKey: PhysicallyBasedMaterial] = [:]

    /// Nil: the authored look (no energy, or a dimmed part that has no light of its own).
    private static func key(_ kind: HoverboardReaction, _ role: Role, _ glow: HoverboardReaction.Glow) -> MaterialKey? {
        let level = glow.level
        guard level > 0 || (level < 0 && role.isLight) else { return nil }
        return MaterialKey(kind: kind, role: role, tone: level > 0 ? glow.tone : 0, level: level)
    }

    private static func material(_ key: MaterialKey) -> any RealityKit.Material {
        if let material = made[key] { return material }
        guard var pbr = authored[key.role] else { return SimpleMaterial() }
        let base = rgb(pbr.baseColor.tint)
        if key.level > 0 {
            let e = Float(key.level) / 12
            let color = tone(key.kind, key.tone)
            // The colour replaces the purple quickly: red over purple reads magenta, amber pink.
            let mix = min(1, e * (key.kind == .hit ? 2.5 : 2)) * (key.kind == .hit ? 1 : key.role.peak.tint)
            pbr.baseColor = .init(tint: uiColor(base + (color * 0.8 - base) * mix))
            pbr.emissiveColor = .init(color: uiColor(color))
            // The white-hot highlights burn brighter than the colour around them.
            let hot: Float = key.tone == 3 ? 1.35 : 1
            pbr.emissiveIntensity = max(key.role.isLight ? 1 : 0, e * key.role.peak.intensity * hot)
        } else {
            // Brownout: an authored light at a fraction of its glow.
            let dim = 1 - Float(-key.level) / 10
            pbr.baseColor = .init(tint: uiColor(base * (0.45 + 0.55 * dim)))
            pbr.emissiveIntensity *= dim
        }
        made[key] = pbr
        return pbr
    }

    /// A fresh material with the authored values. On the Simulator, a USD-loaded material given
    /// back after an edited copy had been shown kept drawing the copy (the emblem stayed pink
    /// after a HIT), so lit slots never use the loaded instances at all.
    private static func fresh(_ source: PhysicallyBasedMaterial) -> PhysicallyBasedMaterial {
        var pbr = PhysicallyBasedMaterial()
        pbr.baseColor = .init(tint: source.baseColor.tint)
        pbr.roughness = source.roughness
        pbr.metallic = source.metallic
        pbr.emissiveColor = .init(color: source.emissiveColor.color)
        pbr.emissiveIntensity = source.emissiveIntensity
        return pbr
    }

    /// The role whose authored colour this is (exact to rounding: the underside's 2B2560 is not
    /// the emblem's 2A2360).
    private static func role(of material: PhysicallyBasedMaterial) -> Role? {
        let c = rgb(material.baseColor.tint)
        return Role.allCases.first { role in
            let h = role.authoredColor
            let target = SIMD3<Float>(Float(h >> 16 & 0xFF), Float(h >> 8 & 0xFF), Float(h & 0xFF)) / 255
            return simd_reduce_max(abs(c - target)) < 0.75 / 255
        }
    }

    private static func rgb(_ color: UIColor) -> SIMD3<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Float(r), Float(g), Float(b)]
    }

    private static func uiColor(_ c: SIMD3<Float>) -> UIColor {
        UIColor(red: CGFloat(max(0, min(1, c.x))), green: CGFloat(max(0, min(1, c.y))), blue: CGFloat(max(0, min(1, c.z))), alpha: 1)
    }

    private static func findBody(in entity: Entity) -> ModelEntity? {
        if let model = entity as? ModelEntity, model.name == "Body" { return model }
        for child in entity.children { if let found = findBody(in: child) { return found } }
        return nil
    }

    // MARK: Energy field materials

    private struct FieldKey: Hashable {
        let kind: HoverboardReaction
        let tone: Int
        let level: Int
    }

    private static var fieldMade: [FieldKey: UnlitMaterial] = [:]

    /// The field's light: white, full at the rim and fading up to nothing in its alpha (straight,
    /// not premultiplied), drawn once.
    private static let fieldTexture: TextureResource? = {
        let width = 4, height = 64
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            // Image row 0 is the field's top (texture v = 1).
            let v = 1 - Float(row) / Float(height - 1)
            let a = pow(1 - v, 1.7) * (0.75 + 0.25 * exp(-v * 9))
            for column in 0..<width {
                let i = (row * width + column) * 4
                bytes[i] = 255; bytes[i + 1] = 255; bytes[i + 2] = 255; bytes[i + 3] = UInt8((a * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return try? TextureResource(image: image, withName: "hoverboard.energyField", options: .init(semantic: .color))
    }()

    private static let hiddenField: UnlitMaterial = {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .clear)
        material.blending = .transparent(opacity: 0.0)
        return material
    }()

    private static func fieldMaterial(_ key: FieldKey) -> any RealityKit.Material {
        if let made = fieldMade[key] { return made }
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        let color = uiColor(tone(key.kind, key.tone))
        // White with a straight-alpha fade, tinted (a premultiplied texture darkened the field's
        // thin top into a dark comb; an opacity texture was ignored and drew flat panels).
        if let fieldTexture { material.color = .init(tint: color, texture: .init(fieldTexture)) } else { material.color = .init(tint: color) }
        material.blending = .transparent(opacity: .init(scale: Float(key.level) / 8 * 0.85))
        fieldMade[key] = material
        return material
    }

    // MARK: Discharge materials

    private static func unlit(_ c: SIMD3<Float>) -> UnlitMaterial {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: uiColor(c))
        return material
    }
    /// ZAPPED!'s coral round a white-hot core; the secondary discharge is hot pink.
    private static let arcOuter = unlit([1, 0.27, 0.35])
    private static let arcSecondary = unlit([1, 0.23, 0.5])
    private static let arcCore = unlit([1, 0.95, 0.93])

    // MARK: Meshes (asset units; the board model scales them; shared by both boards)

    static let ribbonMesh: MeshResource = {
        let descriptors = (0..<HoverboardReaction.segments).map { RimOutline.segment($0) }
        return (try? MeshResource.generate(from: descriptors)) ?? .generateBox(size: 0.001)
    }()

    static let fieldMesh: MeshResource = {
        let descriptors = (0..<HoverboardReaction.segments).map { RimOutline.field($0) }
        return (try? MeshResource.generate(from: descriptors)) ?? .generateBox(size: 0.001)
    }()

    static let arcMeshes: [[MeshResource]] = (0..<HoverboardReaction.arcSites).map { site in
        (0..<HoverboardReaction.arcVariants).map { variant in
            (try? MeshResource.generate(from: RimOutline.arc(site: site, variant: variant))) ?? .generateBox(size: 0.001)
        }
    }
}

/// The board's outline as `hoverboard_build.py` builds it: a superellipse (1.16 × 0.46 m, exponent
/// 2.15) sampled by arc length anticlockwise from +X (Blender), Z up, the display side at −Y.
/// RealityKit sees Blender (x, y, z) as (x, z, −y).
nonisolated enum RimOutline {
    static let a: Float = 0.58, b: Float = 0.23, exponent: Float = 2.15
    /// Fraction of each segment left dark between segments.
    static let gap: Float = 0.14
    /// The ribbon's profile, outside to inside: (inset x, inset y, height, outward normal, up
    /// normal). It follows the rim's own profile (lip from 4 mm, top at 17 mm, the inner edge
    /// down to the groove), raised about 1 mm off its surface.
    static let profile: [(ox: Float, oy: Float, z: Float, out: Float, up: Float)] = [
        (0.0078, 0.0078, 0.0040, 0.96, 0.28),
        (0.0158, 0.0148, 0.0142, 0.62, 0.78),
        (0.0266, 0.0236, 0.0182, 0.12, 0.99),
        (0.0623, 0.0503, 0.0182, -0.05, 1),
        (0.0700, 0.0558, 0.0140, -0.6, 0.8),
    ]
    /// The energy field: from the rim's outer lip up this high, leaning out this far at its top.
    static let fieldHeight: Float = 0.085
    static let fieldLean: Float = 0.014
    /// Where the discharges run along the outline (arc-length fractions; the front centre is 0.75).
    static let arcSpans: [(Float, Float)] = [(0.6, 0.71), (0.79, 0.9), (0.44, 0.56), (0.94, 1.06)]

    static func point(_ a: Float, _ b: Float, _ t: Float) -> SIMD2<Float> {
        let c = cos(t), s = sin(t)
        return [a * copysign(pow(abs(c), 2 / exponent), c), b * copysign(pow(abs(s), 2 / exponent), s)]
    }

    /// Outward unit normal of the superellipse with semi-axes (a, b) at parameter t.
    static func normal(_ a: Float, _ b: Float, _ t: Float) -> SIMD2<Float> {
        let p = point(a, b, t)
        let g = SIMD2(exponent / a * pow(abs(p.x / a), exponent - 1) * (p.x < 0 ? -1 : 1),
                      exponent / b * pow(abs(p.y / b), exponent - 1) * (p.y < 0 ? -1 : 1))
        return simd_length(g) > 0 ? simd_normalize(g) : SIMD2(cos(t), sin(t))
    }

    /// The outer outline's parameter at arc-length fraction `u` (any real; wraps).
    static func parameter(_ u: Float) -> Float {
        let u = u - floor(u)
        let target = u * arc[arc.count - 1]
        var low = 0, high = arc.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if arc[mid] < target { low = mid } else { high = mid }
        }
        let f = (target - arc[low]) / max(1e-9, arc[high] - arc[low])
        return 2 * .pi * (Float(low) + f) / Float(arc.count - 1)
    }

    private static let arc: [Float] = {
        let n = 4096
        var lengths: [Float] = [0]
        var last = point(a, b, 0)
        for i in 1...n {
            let p = point(a, b, 2 * .pi * Float(i) / Float(n))
            lengths.append(lengths[i - 1] + simd_distance(p, last))
            last = p
        }
        return lengths
    }()

    /// A point on the outline inset by (ox, oy), and its outward normal, in RealityKit axes.
    static func rim(_ u: Float, ox: Float, oy: Float, height: Float) -> (position: SIMD3<Float>, outward: SIMD3<Float>) {
        let t = parameter(u)
        let p = point(a - ox, b - oy, t), n = normal(a - ox, b - oy, t)
        return ([p.x, height, -p.y], [n.x, 0, -n.y])
    }

    /// Triangles for a quad strip, facing `facing` (or both ways).
    private static func quad(_ q: [UInt32], _ positions: [SIMD3<Float>], facing: SIMD3<Float>?, into indices: inout [UInt32]) {
        let p = q.map { positions[Int($0)] }
        let front = [q[0], q[1], q[2], q[0], q[2], q[3]], back = [q[0], q[2], q[1], q[0], q[3], q[2]]
        guard let facing else { indices += front + back; return }
        indices += simd_dot(simd_cross(p[1] - p[0], p[2] - p[0]), facing) >= 0 ? front : back
    }

    /// One segment of the rim's energy skin, with material slot `index`.
    static func segment(_ index: Int) -> MeshDescriptor {
        let columns = 5
        let n = Float(HoverboardReaction.segments)
        let u0 = (Float(index) + gap / 2) / n, u1 = (Float(index) + 1 - gap / 2) / n
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = []
        for c in 0..<columns {
            let u = u0 + (u1 - u0) * Float(c) / Float(columns - 1)
            for row in profile {
                let r = rim(u, ox: row.ox, oy: row.oy, height: row.z)
                positions.append(r.position)
                normals.append(simd_normalize(r.outward * row.out + SIMD3(0, row.up, 0)))
            }
        }
        var indices: [UInt32] = []
        let rows = profile.count
        for c in 0..<(columns - 1) {
            for r in 0..<(rows - 1) {
                let i0 = UInt32(c * rows + r), i1 = UInt32((c + 1) * rows + r)
                quad([i0, i1, i1 + 1, i0 + 1], positions, facing: normals[Int(i0)] + normals[Int(i1 + 1)], into: &indices)
            }
        }
        var descriptor = MeshDescriptor(name: "rimEnergy.\(index)")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        descriptor.materials = .allFaces(UInt32(index))
        return descriptor
    }

    /// One segment of the energy field, with material slot `index`: a curtain from the rim's outer
    /// lip up `fieldHeight`, both sides drawn, its light fading upward (texture v, kept inside the
    /// texture so its bright base never wraps onto the top edge). Unlike the rim's skin, the
    /// segments touch: a glow, not a fence.
    static func field(_ index: Int) -> MeshDescriptor {
        let columns = 5
        let n = Float(HoverboardReaction.segments)
        let u0 = Float(index) / n, u1 = Float(index + 1) / n
        var positions: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = []
        for c in 0..<columns {
            let s = Float(c) / Float(columns - 1)
            let r = rim(u0 + (u1 - u0) * s, ox: 0.0125, oy: 0.012, height: 0.012)
            positions.append(r.position)
            positions.append(r.position + r.outward * fieldLean + SIMD3(0, fieldHeight, 0))
            uvs.append([0.5, 0.03]); uvs.append([0.5, 0.97])
        }
        var indices: [UInt32] = []
        for c in 0..<(columns - 1) {
            let i = UInt32(c * 2)
            quad([i, i + 2, i + 3, i + 1], positions, facing: nil, into: &indices)
        }
        var descriptor = MeshDescriptor(name: "energyField.\(index)")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        descriptor.materials = .allFaces(UInt32(index))
        return descriptor
    }

    /// One discharge over the rim at `site` (shape `variant`): a jagged bolt that leaves the rim
    /// lip, arcs up to 7 cm over it and lands on the lip again, as a coral ribbon (material 0)
    /// with a white-hot core (material 1) in front of it, both sides drawn.
    static func arc(site: Int, variant: Int) -> [MeshDescriptor] {
        let (u0, u1) = arcSpans[site % arcSpans.count]
        let seed = site &* 7 &+ variant &* 13 &+ 101
        let points = 11
        var path: [(position: SIMD3<Float>, outward: SIMD3<Float>)] = []
        let bulge: Float = 0.045 + 0.025 * Float(HoverboardReaction.hash(seed, 1))
        for k in 0..<points {
            let s = Float(k) / Float(points - 1)
            let jitter = k == 0 || k == points - 1 ? 0 : (Float(HoverboardReaction.hash(seed, k &+ 20)) - 0.5) * 0.35 / Float(points)
            let r = rim(u0 + (u1 - u0) * (s + jitter), ox: 0.008, oy: 0.008, height: 0.012)
            let zig: Float = k == 0 || k == points - 1 ? 0 : (k.isMultiple(of: 2) ? 1 : -1) * (0.008 + 0.016 * Float(HoverboardReaction.hash(seed, k)))
            path.append((r.position + r.outward * 0.012 + SIMD3(0, bulge * sin(.pi * s) + zig, 0), r.outward))
        }
        func ribbon(halfWidth: Float, forward: Float, material: UInt32) -> MeshDescriptor {
            var positions: [SIMD3<Float>] = [], indices: [UInt32] = []
            for k in 0..<(points - 1) {
                let a = path[k], b = path[k + 1]
                let d = simd_normalize(b.position - a.position)
                let taper = { (i: Int) -> Float in 0.55 + 0.45 * sin(.pi * Float(i) / Float(points - 1)) }
                let side = simd_normalize(simd_cross(a.outward, d))
                let base = UInt32(positions.count)
                let ea = a.position - d * halfWidth * 0.5, eb = b.position + d * halfWidth * 0.5 // overlap at the kinks
                positions += [ea - side * halfWidth * taper(k) + a.outward * forward, eb - side * halfWidth * taper(k + 1) + b.outward * forward,
                              eb + side * halfWidth * taper(k + 1) + b.outward * forward, ea + side * halfWidth * taper(k) + a.outward * forward]
                quad([base, base + 1, base + 2, base + 3], positions, facing: nil, into: &indices)
            }
            var descriptor = MeshDescriptor(name: "discharge.\(site).\(variant).\(material)")
            descriptor.positions = MeshBuffers.Positions(positions)
            descriptor.primitives = .triangles(indices)
            descriptor.materials = .allFaces(material)
            return descriptor
        }
        return [ribbon(halfWidth: 0.011, forward: 0, material: 0), ribbon(halfWidth: 0.0042, forward: 0.003, material: 1)]
    }
}
