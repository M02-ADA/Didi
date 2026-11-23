//
//  GateHandGlow.swift
//  Sedactive
//

import Foundation
import RealityKit
import UIKit

/// The gate's hand cue (Kevin, 22 November 2026): while a player's gate button is live, the hand
/// their mascot presses it with (the console-side fist, `RobotAvatarLayer.reachConsole`) carries a
/// soft warm-white glow, so the players see at once which hand opens the gate. Presentation only:
/// it reads the button's drawn state (`GateConsoleView.state`, from the game's `vault.buttons`) and
/// the fist's approach (`RobotAvatarLayer.consoleApproach`); it judges nothing.
///
/// States (`Phase`, set by `VaultPresentation`):
/// - `off`: nothing (no gate, the gate still arriving, timed out, hidden, walking into the vault).
///   From any glow it fades out in `fadeOut` (ease-in).
/// - `live` (this player's button is live and the mascot reaches for it): a ramp-in over `rampIn`
///   (ease-out, a small overshoot in size), then a steady glow that breathes gently; as the fist
///   nears the button it brightens and swells a little and the breathing settles (charging).
/// - `pressed` (the game's activation of this player's button): a contact flare (the glow pops to
///   full and swells in `flareRise`, settles by `flareSettle`, one thin ring thrown out), a short
///   hold, then a clean fade, gone `pressDuration` after the press. A button already shown pressed
///   when the cue first sees it (a console shown mid-gate) lights nothing.
/// Reduce Motion: no breathing, no size change and no ring; the glow still eases in and out.
///
/// Everything is a function of the phase and the time since it began (the mascots' presentation
/// clock), so a phase change starts from what is shown and nothing jumps.
nonisolated struct GateHandGlow: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case off, live, pressed }

    /// What the glow shows: the aura's opacity and size, and the contact ring's (sizes × `auraSize`).
    struct Frame: Equatable, Sendable {
        var aura: Float = 0
        var auraScale: Float = 1
        var flare: Float = 0
        var flareScale: Float = 1
        var isVisible: Bool { aura > 0.002 || flare > 0.002 }
    }

    /// Ramp-in when the button goes live (s), and the fade when the cue ends without a press.
    static let rampIn = 0.28
    static let fadeOut = 0.22
    /// The steady live glow, how much brighter and larger it gets with the fist on the button, and its
    /// breathing (period, opacity and size amplitude; none with the fist on the button).
    static let liveLevel: Float = 0.88
    static let approachBoost: Float = 0.12
    static let approachGrow: Float = 0.14
    static let pulsePeriod = 1.1
    static let pulseOpacity: Float = 0.1
    static let pulseScale: Float = 0.06
    /// The ramp-in's starting size and overshoot (ease-out-back).
    static let rampStartScale: Float = 0.55
    static let rampOvershoot: Float = 1.6
    /// The press: the flare's rise and settle, the hold at full glow, the fade.
    static let flareRise = 0.05
    static let flareSettle = 0.3
    static let flarePeakScale: Float = 1.45
    static let pressHold = 0.42
    static let pressFade = 0.4
    static var pressDuration: Double { pressHold + pressFade }
    /// The contact ring: life, size range (× `auraSize`), opacity at the press.
    static let ringLife = 0.36
    static let ringFrom: Float = 0.45, ringTo: Float = 1.25
    static let ringOpacity: Float = 0.85

    private(set) var phase: Phase = .off
    private var start: Double?
    /// What was shown when the phase began (each phase eases from it).
    private var from = Frame()
    /// What is shown now.
    private(set) var shown = Frame()

    /// Moves to `target` (when it differs) at `time` and returns what to show. `approach`: how close
    /// the fist is to pressing (0 … 1).
    mutating func advance(to target: Phase, at time: Double, approach: Float = 0, reduceMotion: Bool = false) -> Frame {
        // The flare answers a press on a cued hand only.
        let target = target == .pressed && phase == .off ? .off : target
        if target != phase || start == nil || time < (start ?? time) {
            if target != phase { from = shown }
            phase = target
            start = time
        }
        shown = frame(at: max(0, time - (start ?? time)), approach: max(0, min(1, approach)), reduceMotion: reduceMotion)
        return shown
    }

    private func frame(at tau: Double, approach a: Float, reduceMotion: Bool) -> Frame {
        switch phase {
        case .off:
            let f = Float(min(1, tau / Self.fadeOut))
            return Frame(aura: from.aura * (1 - f * f), auraScale: from.auraScale * (reduceMotion ? 1 : 1 - 0.15 * f),
                         flare: from.flare * (1 - f), flareScale: from.flareScale)
        case .live:
            let p = Float(min(1, tau / Self.rampIn))
            let ease = 1 - pow(1 - p, 3)
            var aura = from.aura + (Self.liveLevel + Self.approachBoost * a - from.aura) * ease
            if reduceMotion { return Frame(aura: min(1, aura), auraScale: 1, flare: from.flare * (1 - ease)) }
            let startScale = from.aura > 0.01 ? from.auraScale : Self.rampStartScale
            var scale = startScale + (1 + Self.approachGrow * a - startScale) * Self.easeOutBack(p)
            let breathe = Float(sin(2 * .pi * tau / Self.pulsePeriod)) * (1 - a) * ease
            aura += Self.pulseOpacity * breathe
            scale *= 1 + Self.pulseScale * breathe
            return Frame(aura: max(0, min(1, aura)), auraScale: scale, flare: from.flare * (1 - ease), flareScale: from.flareScale)
        case .pressed:
            var aura: Float = 1, scale: Float = 1
            if !reduceMotion {
                if tau < Self.flareRise {
                    let k = 1 - pow(1 - Float(tau / Self.flareRise), 2)
                    aura = from.aura + (1 - from.aura) * k
                    scale = from.auraScale + (Self.flarePeakScale - from.auraScale) * k
                } else if tau < Self.flareSettle {
                    let x = Float((tau - Self.flareRise) / (Self.flareSettle - Self.flareRise))
                    scale = Self.flarePeakScale + (1 - Self.flarePeakScale) * x * x * (3 - 2 * x)
                }
            }
            if tau > Self.pressHold {
                let f = Float(min(1, (tau - Self.pressHold) / Self.pressFade))
                aura *= 1 - f * f
                if !reduceMotion { scale *= 1 - 0.12 * f }
            }
            guard !reduceMotion, tau < Self.ringLife else { return Frame(aura: aura, auraScale: scale) }
            let q = Float(tau / Self.ringLife)
            return Frame(aura: aura, auraScale: scale, flare: Self.ringOpacity * (1 - q) * (1 - q),
                         flareScale: Self.ringFrom + (Self.ringTo - Self.ringFrom) * (1 - pow(1 - q, 3)))
        }
    }

    /// Ease-out with a small overshoot (`rampOvershoot`), for the glow's size as it lights.
    static func easeOutBack(_ p: Float) -> Float {
        let c = rampOvershoot, x = p - 1
        return 1 + (c + 1) * x * x * x + c * x * x
    }
}

/// The drawn hand glow of one mascot: a soft warm-white aura and a thin contact ring, two quads in
/// the mascot's lane (like `LaserHitZap`), placed each frame by `RobotAvatarLayer` on the fist as
/// the camera sees it. Unlit, not tone-mapped and never writing depth, so it reads as light and
/// never cuts into the translucent mascot.
@MainActor
final class GateHandGlowView {
    /// The aura's diameter at the fist (m): its bright core is about the fist, its halo about three
    /// fists, so it frames the hand, not the body.
    static let auraSize: Float = 0.5
    /// How far in front of the body (toward the camera) the glow stands, so the body never hides it.
    static let front: Float = 0.3
    /// Warm white: the core, and the falloff toward the aura's edge.
    static let core = SIMD3<Float>(1, 0.985, 0.95)
    static let warm = SIMD3<Float>(1, 0.86, 0.62)

    let root = Entity()
    private let aura: ModelEntity
    private let ring: ModelEntity

    init() {
        let r = Resources.shared
        root.name = "gateHandGlow"
        root.isEnabled = false
        aura = ModelEntity(mesh: r.quad, materials: [r.aura])
        aura.name = "gateHandGlow.aura"
        ring = ModelEntity(mesh: r.quad, materials: [r.ring])
        ring.name = "gateHandGlow.ring"
        root.addChild(aura)
        root.addChild(ring)
    }

    /// Shows `frame` with the glow centred at `position` (world), drawn `size` metres across at scale 1.
    func show(_ frame: GateHandGlow.Frame, at position: SIMD3<Float>, size: Float) {
        guard frame.isVisible else { return hide() }
        root.isEnabled = true
        root.setPosition(position, relativeTo: nil)
        Self.set(aura, opacity: frame.aura)
        aura.scale = SIMD3(repeating: size * frame.auraScale)
        Self.set(ring, opacity: frame.flare)
        ring.scale = SIMD3(repeating: size * frame.flareScale)
        ring.position.z = 0.004
    }

    func hide() {
        guard root.isEnabled else { return }
        root.isEnabled = false
    }

    var isShown: Bool { root.isEnabled }

    private static func set(_ part: ModelEntity, opacity: Float) {
        part.isEnabled = opacity > 0.002
        guard part.isEnabled else { return }
        if part.components[OpacityComponent.self]?.opacity != opacity {
            part.components.set(OpacityComponent(opacity: max(0, min(1, opacity))))
        }
    }

    @MainActor
    private final class Resources {
        static let shared = Resources()
        let quad: MeshResource = .generatePlane(width: 1, height: 1)
        let aura: UnlitMaterial
        let ring: UnlitMaterial

        private init() {
            // A soft plateau the size of the fist, melting into a warm halo with a clean falloff.
            aura = Self.material(Self.texture(128) { r in
                let core = 1 - Self.smooth(0.18, 0.36, r)
                let halo = 0.95 * exp(-pow(r / 0.58, 2) * 1.5)
                let alpha = max(0.97 * core, halo) * (1 - Self.smooth(0.8, 1, r))
                return (GateHandGlowView.core + (GateHandGlowView.warm - GateHandGlowView.core) * Self.smooth(0.2, 0.85, r), alpha)
            }, name: "gateHandGlow.aura")
            // One thin soft ring (the contact flare).
            ring = Self.material(Self.texture(128) { r in
                (GateHandGlowView.core + (GateHandGlowView.warm - GateHandGlowView.core) * 0.4, exp(-pow((r - 0.86) / 0.05, 2)))
            }, name: "gateHandGlow.ring")
        }

        static func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
            let t = min(1, max(0, (x - e0) / (e1 - e0)))
            return t * t * (3 - 2 * t)
        }

        /// A square premultiplied texture from `shade(r)` (r: 0 at the centre, 1 at the edge's middle).
        private static func texture(_ size: Int, _ shade: (Float) -> (SIMD3<Float>, Float)) -> CGImage? {
            var pixels = [UInt8](repeating: 0, count: size * size * 4)
            for row in 0..<size {
                for column in 0..<size {
                    let x = (Float(column) + 0.5) / Float(size) * 2 - 1, y = (Float(row) + 0.5) / Float(size) * 2 - 1
                    let r = (x * x + y * y).squareRoot()
                    let (color, a) = r < 1 ? shade(r) : (.zero, 0)
                    let alpha = max(0, min(1, a)), i = (row * size + column) * 4
                    pixels[i] = UInt8(color.x * alpha * 255)
                    pixels[i + 1] = UInt8(color.y * alpha * 255)
                    pixels[i + 2] = UInt8(color.z * alpha * 255)
                    pixels[i + 3] = UInt8(alpha * 255)
                }
            }
            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }

        private static func material(_ image: CGImage?, name: String) -> UnlitMaterial {
            var material = UnlitMaterial(applyPostProcessToneMap: false)
            if let image, let texture = try? TextureResource(image: image, withName: name, options: .init(semantic: .color)) {
                material.color = .init(tint: .white, texture: .init(texture))
            } else {
                material.color = .init(tint: UIColor(white: 1, alpha: 0.5))
            }
            material.blending = .transparent(opacity: 1.0)
            material.faceCulling = .none
            // Light, not a surface: it never hides what is behind it or cuts into the translucent mascot.
            material.writesDepth = false
            return material
        }
    }
}
