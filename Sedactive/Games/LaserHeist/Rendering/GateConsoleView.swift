//
//  GateConsoleView.swift
//  Sedactive
//

import Foundation
import RealityKit
import UIKit

/// One player's wall console as drawn (owner, 12 November 2026: unified vertical console, three
/// large physical buttons, RED available → GREEN completed). Geometry from `LaserGateConsole`;
/// state from the game's `vault.buttons` only (`VaultPresentation`): nothing here judges or presses.
///
/// Art direction: the corridor's own language. Housing in its indigo (`0x2A2560`) with a lighter
/// mounting plate, neon edge strips in the corridor's violet that turn the HUD's success green when
/// the side is complete, bezels in the door's dark navy. Lit (physically based) where depth must read
/// (housing, bezel, cap body), emissive where it must glow (cap face, halo, strips).
/// Button states, all on the SAME geometry, glow and check art:
/// - Available: red cap (emissive), pink-red rim glow.
/// - Pressed (once per button per gate, on the game's activation): the cap sinks into its bezel
///   (60 ms ease-out), the glow pulses (0.12 s out, 0.22 s back), the colour turns green at the bottom
///   of the press, the check pops in (0.2 s); the cap settles slightly sunk (150–200 ms).
/// - Completed: green cap and rim glow, check; stays until the gate ends.
/// Reduce Motion: the state changes at once, no movement or pulse.
@MainActor
final class GateConsoleView {
    enum ButtonState: Equatable { case available, completed }

    struct Palette {
        static let housing: UInt32 = 0x2A2560
        static let plate: UInt32 = 0x342D74
        static let bezel: UInt32 = 0x16133A
        static let strip: UInt32 = 0x8C7BFF
        static let red: UInt32 = 0xD81F37, redGlow: UInt32 = 0xFF3B55, redFace: UInt32 = 0xFF7083
        static let green: UInt32 = 0x1FA35E, greenGlow: UInt32 = 0x3BCF7E, greenFace: UInt32 = 0x8DFFC0
    }

    /// Cap travel: rest proud of the bezel, fully pressed, and where it settles once completed.
    static let capRest: Float = LaserGateConsole.pressSurface - capThickness / 2
    static let capPressed: Float = 0.003, capSettled: Float = 0.007
    static let capThickness: Float = 0.02

    private struct Button {
        let mount: Entity
        let cap: Entity
        let body: ModelEntity
        let face: ModelEntity
        let halo: ModelEntity
        let check: ModelEntity
    }

    let root = Entity()
    let console: LaserGateConsole
    private var buttons: [LaserVaultButton: Button] = [:]
    private var strips: [ModelEntity] = []
    private(set) var states: [LaserVaultButton: ButtonState] = [:]
    /// Presses animated per button since the last reset (diagnostics and tests).
    private(set) var presses: [LaserVaultButton: Int] = [:]
    private(set) var sideComplete = false

    init(console: LaserGateConsole) {
        self.console = console
        root.name = "vault.console.\(console.player.rawValue)"
        let inward = SIMD3<Float>(-console.side, 0, 0)
        let facing = simd_quatf(from: [0, 0, 1], to: inward)
        // The housing leans with the column (top toward the camera), within the plate's own plane.
        let housing = console.housing
        let lean = simd_quatf(angle: housing.tilt, axis: [1, 0, 0])
        let box = ModelEntity(mesh: .generateBox(size: housing.size, cornerRadius: 0.018),
                              materials: [Self.lit(Palette.housing, roughness: 0.55, metallic: 0.25)])
        box.name = "vault.console.housing"
        box.position = housing.center
        box.orientation = lean
        root.addChild(box)
        // The mounting plate on the open face, inset from the housing's edge.
        let plateSize = SIMD2(housing.size.z - 0.03, housing.size.y - 0.03)
        let plate = ModelEntity(mesh: .generateBox(size: [plateSize.x, plateSize.y, 0.006], cornerRadius: 0.003),
                                materials: [Self.lit(Palette.plate, roughness: 0.45, metallic: 0.3)])
        plate.name = "vault.console.plate"
        plate.orientation = lean * facing
        plate.position = [console.faceX, housing.center.y, housing.center.z] + inward * 0.003
        root.addChild(plate)
        // Neon edge strips along both long edges of the plate.
        for edge: Float in [-1, 1] {
            let strip = ModelEntity(mesh: .generateBox(size: [0.012, plateSize.y - 0.05, 0.008], cornerRadius: 0.004),
                                    materials: [Self.glow(Palette.strip)])
            strip.name = "vault.console.strip"
            strip.orientation = lean * facing
            strip.position = [console.faceX, housing.center.y, housing.center.z]
                + lean.act([0, 0, edge * (plateSize.x / 2 - 0.016)]) + inward * 0.007
            root.addChild(strip)
            strips.append(strip)
        }
        for (key, b) in console.buttons {
            let mount = Entity()
            mount.name = "vault.console.button.\(key.rawValue)"
            mount.orientation = simd_quatf(from: [0, 0, 1], to: b.normal)
            mount.position = b.center
            // Bezel: a dark ring set into the plate, its front just proud of it.
            let bezel = ModelEntity(mesh: .generateCylinder(height: 0.018, radius: b.radius + LaserGateConsole.bezel),
                                    materials: [Self.lit(Palette.bezel, roughness: 0.3, metallic: 0.65)])
            bezel.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            bezel.position = [0, 0, 0.0]
            mount.addChild(bezel)
            // Glow on the plate around the button (behind the cap, in front of the plate).
            let halo = ModelEntity(mesh: .generatePlane(width: 3 * b.radius, height: 3 * b.radius), materials: [Self.halo(Palette.redGlow)])
            halo.name = "vault.console.halo"
            halo.position = [0, 0, 0.0095]
            mount.addChild(halo)
            // Cap: the pressable surface (its radius is the judged zone's on the mascot).
            let cap = Entity()
            cap.position = [0, 0, Self.capRest]
            let body = ModelEntity(mesh: .generateCylinder(height: Self.capThickness, radius: b.radius),
                                   materials: [Self.lit(Palette.red, roughness: 0.35, metallic: 0.1, emissive: Palette.red, intensity: 0.6)])
            body.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            cap.addChild(body)
            let face = ModelEntity(mesh: .generateCylinder(height: 0.003, radius: b.radius * 0.74),
                                   materials: [Self.glow(Palette.redFace)])
            face.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            face.position = [0, 0, Self.capThickness / 2 + 0.0015]
            cap.addChild(face)
            let check = ModelEntity(mesh: .generatePlane(width: b.radius * 1.1, height: b.radius * 1.1), materials: [Self.checkMaterial()])
            check.name = "vault.console.check"
            check.position = [0, 0, Self.capThickness / 2 + 0.004]
            check.isEnabled = false
            cap.addChild(check)
            mount.addChild(cap)
            root.addChild(mount)
            buttons[key] = Button(mount: mount, cap: cap, body: body, face: face, halo: halo, check: check)
            states[key] = .available
        }
    }

    /// Back to all available (a new gate).
    func reset() {
        for key in buttons.keys { apply(key, .available) }
        presses = [:]
        setSideComplete(false)
    }

    /// Shows a button completed (the game activated it). The press plays once; repeating is a no-op.
    func complete(_ key: LaserVaultButton, reduceMotion: Bool) {
        guard states[key] == .available, let b = buttons[key] else { return }
        presses[key, default: 0] += 1
        states[key] = .completed
        guard !reduceMotion else {
            apply(key, .completed)
            return
        }
        b.cap.stopAllAnimations()
        b.halo.stopAllAnimations()
        func at(_ z: Float) -> Transform { Transform(translation: [0, 0, z]) }
        b.cap.transform = at(Self.capSettled)
        if let down = try? AnimationResource.generate(with: FromToByAnimation<Transform>(
               from: at(Self.capRest), to: at(Self.capPressed), duration: 0.06, timing: .easeOut, bindTarget: .transform)),
           let up = try? AnimationResource.generate(with: FromToByAnimation<Transform>(
               from: at(Self.capPressed), to: at(Self.capSettled), duration: 0.18, timing: .easeInOut, bindTarget: .transform)),
           let press = try? AnimationResource.sequence(with: [down, up]) {
            b.cap.playAnimation(press)
        }
        var big = b.halo.transform, rest = b.halo.transform
        rest.scale = .one
        big.scale = [1.45, 1.45, 1]
        if let out = try? AnimationResource.generate(with: FromToByAnimation<Transform>(
               from: rest, to: big, duration: 0.12, timing: .easeOut, bindTarget: .transform)),
           let back = try? AnimationResource.generate(with: FromToByAnimation<Transform>(
               from: big, to: rest, duration: 0.22, timing: .easeInOut, bindTarget: .transform)),
           let pulse = try? AnimationResource.sequence(with: [out, back]) {
            b.halo.playAnimation(pulse)
        }
        // Green at the bottom of the press; the check pops in.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self, self.states[key] == .completed else { return }
            self.apply(key, .completed, positionCap: false)
            var small = b.check.transform, full = b.check.transform
            small.scale = [0.6, 0.6, 1]
            full.scale = .one
            if let pop = try? AnimationResource.generate(with: FromToByAnimation<Transform>(
                   from: small, to: full, duration: 0.2, timing: .easeOut, bindTarget: .transform)) {
                b.check.playAnimation(pop)
            }
        }
    }

    /// The side's three buttons are complete: the edge strips turn green.
    func setSideComplete(_ done: Bool) {
        sideComplete = done
        for strip in strips { strip.model?.materials = [Self.glow(done ? Palette.greenGlow : Palette.strip)] }
    }

    /// The materials and cap position of a state, at once.
    private func apply(_ key: LaserVaultButton, _ state: ButtonState, positionCap: Bool = true) {
        guard let b = buttons[key] else { return }
        states[key] = state
        let done = state == .completed
        b.body.model?.materials = [Self.lit(done ? Palette.green : Palette.red, roughness: 0.35, metallic: 0.1,
                                            emissive: done ? Palette.green : Palette.red, intensity: 0.6)]
        b.face.model?.materials = [Self.glow(done ? Palette.greenFace : Palette.redFace)]
        b.halo.model?.materials = [Self.halo(done ? Palette.greenGlow : Palette.redGlow)]
        b.check.isEnabled = done
        if positionCap {
            b.cap.stopAllAnimations()
            b.cap.transform = Transform(translation: [0, 0, done ? Self.capSettled : Self.capRest])
        }
    }

    /// Diagnostics: the cap's current depth and the colour family shown.
    func capDepth(_ key: LaserVaultButton) -> Float? { buttons[key]?.cap.transform.translation.z }
    func glowColor(_ key: LaserVaultButton) -> UInt32? {
        guard let state = states[key] else { return nil }
        return state == .completed ? Palette.greenGlow : Palette.redGlow
    }
    func isCheckShown(_ key: LaserVaultButton) -> Bool { buttons[key]?.check.isEnabled ?? false }

    // MARK: - Materials

    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func lit(_ hex: UInt32, roughness: Float, metallic: Float, emissive: UInt32? = nil, intensity: Float = 0) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color(hex))
        m.roughness = .init(floatLiteral: roughness)
        m.metallic = .init(floatLiteral: metallic)
        if let emissive {
            m.emissiveColor = .init(color: color(emissive))
            m.emissiveIntensity = intensity
        }
        return m
    }

    private static func glow(_ hex: UInt32) -> UnlitMaterial {
        UnlitMaterial(color: color(hex))
    }

    private static var haloTexture: TextureResource? = {
        let size = 64
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for row in 0..<size {
            for column in 0..<size {
                let u = (Float(column) + 0.5) / Float(size) * 2 - 1, v = (Float(row) + 0.5) / Float(size) * 2 - 1
                let r = min(1, (u * u + v * v).squareRoot())
                // A soft ring peaking just outside the bezel (0.78 of the halo's half-width), fading out.
                let a = max(0, 1 - abs(r - 0.78) / 0.24) * (r < 1 ? 1 : 0)
                let i = (row * size + column) * 4
                let value = UInt8(min(255, a * 1.6 * 255))
                pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value; pixels[i + 3] = value
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return try? TextureResource(image: image, withName: "vault.console.halo", options: .init(semantic: .color))
    }()

    private static func halo(_ hex: UInt32) -> UnlitMaterial {
        var m = UnlitMaterial(applyPostProcessToneMap: false)
        if let haloTexture {
            m.color = .init(tint: color(hex), texture: .init(haloTexture))
            m.blending = .transparent(opacity: 0.9)
        } else {
            m.color = .init(tint: color(hex).withAlphaComponent(0.3))
            m.blending = .transparent(opacity: 0.3)
        }
        return m
    }

    private static func checkMaterial() -> UnlitMaterial {
        var m = UnlitMaterial(applyPostProcessToneMap: false)
        if let image = VaultPresentation.checkArt(), let texture = try? TextureResource(image: image, options: .init(semantic: .color)) {
            m.color = .init(tint: .white, texture: .init(texture))
            m.blending = .transparent(opacity: 1.0)
            m.opacityThreshold = 0.02
        }
        return m
    }
}
