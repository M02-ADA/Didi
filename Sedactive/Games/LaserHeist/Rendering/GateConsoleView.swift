//
//  GateConsoleView.swift
//  Sedactive
//

import Foundation
import RealityKit
import UIKit
#if canImport(RealityKitContent)
import RealityKitContent
#endif

/// One player's gate button as drawn: ONE activation button, the Blender asset `GateButton.usdz`
/// (Kevin, task owner, 19 November 2026), mounted on the gate's own door frame (20 November 2026: on a
/// compact collar off the frame's jamb; no console, stand, box or extra wall). Geometry from
/// `LaserGateConsole`; state from the game's `vault.buttons` (and, for its approach response, the
/// fist's reach toward its zone, `RobotAvatarLayer.consoleApproach`): nothing here judges or presses.
///
/// The button asset's parts (`Art/LaserHeist/GateButton/README.md`): `Housing`, `Collar`, `Socket`,
/// `Cap` (origin at its back, pressed along its local −Z) and `Accents` (light bars and socket ring).
/// Round it, a halo (red while live, bright green once activated) and a green light.
///
/// States (motion and light, never colour alone):
/// - Unavailable (gate arriving, or timed out unpressed): the cap rests a little sunk, the lights dark.
/// - Available: the cap springs up (arming); a strong red cap, red accents and a soft red halo round
///   the plate, brighter as the fist approaches (`setApproach`).
/// - Pressed (once per gate, on the game's activation): the cap drives down to the collar (50 ms),
///   overshoots and rebounds into its locked depth; at the bottom of the press the CAP TURNS GREEN, its
///   accents turn green, the halo pops bright green and a green light washes the wall.
/// - Gate opened (`surge`): a short white flash of the accents and strips, settling green.
/// Reduce Motion: states change at once; no travel, flash or pop.
@MainActor
final class GateConsoleView {
    enum ButtonState: Equatable { case unavailable, available, completed }

    struct Palette {
        static let strip: UInt32 = 0x8C7BFF
        static let dim: UInt32 = 0x3B3470
        static let accentOff: UInt32 = 0x3A1018
        static let accent: UInt32 = 0xFF2A22, accentHot: UInt32 = 0xFF7A5C
        static let success: UInt32 = 0x3BE08A
        static let flash: UInt32 = 0xFFF4F0
        /// The activated cap: a bright green face and a deeper green sidewall, both lit from within.
        static let capGreen: UInt32 = 0x1FD467, capGreenSide: UInt32 = 0x0E8A44, capGreenGlow: UInt32 = 0x12C85A
        static let haloRed: UInt32 = 0xFF3B30, haloGreen: UInt32 = 0x4BFF95
        /// The mounting collar: dark metal, like the button's housing.
        static let collar: UInt32 = 0x2B2468
    }

    /// The cap's travel along its axis from its modelled rest: pressed (its edge level with the
    /// collar), locked once activated, and sunk while unavailable.
    static let capPressed: Float = -0.025
    static let capSettled: Float = -0.02
    static let capLowered: Float = -0.012
    static let capRest: Float = 0
    /// The halo round the plate (radius) and its opacities: idle, activated.
    static let haloRadius: Float = 0.6
    static let haloIdle: Float = 0.35, haloActive: Float = 1.0
    /// The green light that washes the module when activated: intensity and reach.
    static let lightIntensity: Float = 7000
    static let lightRange: Float = 1.6

    let root = Entity()
    let console: LaserGateConsole
    /// The button's mount (on its axis at the plate's front face, +Z along `normal`).
    let buttonMount = Entity()
    /// The halo and the light on the wall round the button.
    let module = Entity()
    private var cap: Entity?
    private var capBase = SIMD3<Float>.zero
    /// One metre along the button's axis (the mount's +Z) in the cap's parent space: the USD export
    /// may rotate the asset's parts, so the press is converted, never assumed to be the cap's own Z.
    private var capAxis = SIMD3<Float>(0, 0, 1)
    /// The cap's model entities and their authored (red) materials, restored on reset.
    private var capModels: [(entity: Entity, materials: [any RealityKit.Material])] = []
    private var accents: [Entity] = []
    private var strips: [ModelEntity] = []
    private let halo = ModelEntity()
    private let light = Entity()
    /// The compact collar from the door frame's jamb to the plate's back.
    private let collar = ModelEntity()
    /// Whether the button drawn is the Blender asset (false: the simple stand-in while it loads or
    /// when the package is unavailable).
    private(set) var usesAsset = false
    private(set) var state: ButtonState = .unavailable
    /// The game's per-button states, for diagnostics (one button).
    var states: [LaserVaultButton: ButtonState] { [.activate: state] }
    /// Presses and arming rises animated since the last reset, and gate-opening surges played.
    private(set) var presses: [LaserVaultButton: Int] = [:]
    private(set) var arms = 0
    private(set) var surges = 0
    private(set) var sideComplete = false
    /// The approach build-up shown (0…3: none → the fist on the button).
    private(set) var approachLevel = 0
    /// The colours shown now (diagnostics): accents, strips, the halo (and its opacity), the cap, the light.
    private(set) var accentColor: UInt32 = Palette.accentOff
    private(set) var stripColor: UInt32 = Palette.dim
    private(set) var haloColor: UInt32 = Palette.haloRed
    private(set) var haloOpacity: Float = 0
    private(set) var capIsGreen = false
    private(set) var lightLevel: Float = 0
    private var reduceMotion = false

    init(console: LaserGateConsole) {
        self.console = console
        root.name = "vault.console.\(console.player.rawValue)"
        let b = console.button
        buttonMount.name = "vault.console.button.activate"
        buttonMount.position = b.center
        buttonMount.orientation = Self.orientation(normal: b.normal, up: b.up)
        root.addChild(buttonMount)
        buildModule()
        let buttonModel = Self.loadedTemplate
        install(buttonModel?.clone(recursive: true) ?? Self.standIn(), asset: buttonModel != nil)
        if buttonModel == nil {
            Task { @MainActor [weak self] in
                guard let button = await Self.sharedTemplate(), let self, !self.usesAsset else { return }
                self.install(button.clone(recursive: true), asset: true)
            }
        }
    }

    // MARK: - States

    /// A new gate: unpressed, and available (`ready`: the cap springs up) or still unavailable.
    func reset(ready: Bool = true, reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled) {
        self.reduceMotion = reduceMotion
        presses = [:]
        surges = 0
        setSideComplete(false)
        let wasDown = state != .available
        apply(ready ? .available : .unavailable)
        if ready, wasDown, !reduceMotion, let cap {
            // Arming: a mechanical spring rise with a small overshoot.
            arms += 1
            play(cap, [(Self.capLowered, Self.capRest + 0.004, 0.16, .easeOut), (Self.capRest + 0.004, Self.capRest, 0.12, .easeInOut)],
                 ending: Self.capRest)
        }
    }

    /// The gate's time ended without this side's press (timeout): the cap sinks, the lights go dark.
    func setUnavailable() {
        guard state == .available else { return }
        apply(.unavailable)
    }

    /// How close the player's fist is to pressing (0 far … 1 on the button, `RobotAvatarLayer.reachPull`):
    /// while available, the accents and the halo brighten in steps.
    func setApproach(_ amount: Float) {
        let level = state == .available ? Int((max(0, min(1, amount)) * 3).rounded()) : 0
        guard level != approachLevel else { return }
        approachLevel = level
        guard state == .available else { return }
        setAccents(Self.mix(Palette.accent, Palette.accentHot, Float(level) / 3))
        setHalo(Palette.haloRed, opacity: Self.haloIdle + 0.15 * Float(level))
    }

    /// Kept for the game's button keys: the one button completed.
    func complete(_ key: LaserVaultButton, reduceMotion: Bool) {
        complete(reduceMotion: reduceMotion)
    }

    /// Shows the button activated (the game activated it). The press plays once; repeating is a no-op.
    func complete(reduceMotion: Bool) {
        guard state != .completed else { return }
        presses[.activate, default: 0] += 1
        guard !reduceMotion, let cap else { return apply(.completed) }
        state = .completed
        approachLevel = 0
        // Down to the collar, a 1.5 mm overshoot, a rebound past the locked depth, settle.
        let from = capDepth() ?? Self.capRest
        play(cap, [(from, Self.capPressed, 0.05, .easeIn), (Self.capPressed, Self.capPressed - 0.0015, 0.025, .easeOut),
                   (Self.capPressed - 0.0015, Self.capSettled + 0.003, 0.09, .easeOut),
                   (Self.capSettled + 0.003, Self.capSettled, 0.08, .easeInOut)],
             ending: Self.capSettled)
        setAccents(Palette.flash)
        // At the bottom of the press (50 ms): the cap turns green, the halo pops, the light washes the module.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, self.state == .completed else { return }
            self.setCapGreen(true)
            self.setHalo(Palette.haloGreen, opacity: Self.haloActive)
            self.popHalo()
            self.setLight(Self.lightIntensity * 1.6)
            try? await Task.sleep(for: .milliseconds(70))
            guard self.state == .completed else { return }
            self.setAccents(Palette.success)
            try? await Task.sleep(for: .milliseconds(180))
            guard self.state == .completed else { return }
            self.setLight(Self.lightIntensity)
        }
    }

    /// The side's button is activated: the module's strips turn green (just after the press lands).
    func setSideComplete(_ done: Bool, reduceMotion: Bool = true) {
        sideComplete = done
        guard done, !reduceMotion else { return colorStrips(done ? Palette.success : Palette.strip) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard let self, self.sideComplete else { return }
            self.colorStrips(Palette.success)
        }
    }

    /// The game opened the gate: a short white flash through the accents and strips, settling green.
    func surge(reduceMotion: Bool) {
        guard state == .completed else { return }
        surges += 1
        guard !reduceMotion else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(260)) // let a press that opened the gate land first
            guard let self, self.state == .completed else { return }
            self.setAccents(Palette.flash)
            self.colorStrips(Palette.flash)
            self.popHalo()
            try? await Task.sleep(for: .milliseconds(180))
            guard self.state == .completed else { return }
            self.setAccents(Palette.success)
            self.colorStrips(Palette.success)
        }
    }

    /// A state's lights, cap colour and cap depth, at once.
    private func apply(_ state: ButtonState) {
        self.state = state
        approachLevel = 0
        switch state {
        case .unavailable:
            setAccents(Palette.accentOff)
            setHalo(Palette.haloRed, opacity: 0)
            setCapGreen(false)
            setLight(0)
        case .available:
            setAccents(Palette.accent)
            setHalo(Palette.haloRed, opacity: Self.haloIdle)
            setCapGreen(false)
            setLight(0)
        case .completed:
            setAccents(Palette.success)
            setHalo(Palette.haloGreen, opacity: Self.haloActive)
            setCapGreen(true)
            setLight(Self.lightIntensity)
        }
        if !sideComplete { colorStrips(state == .unavailable ? Palette.dim : Palette.strip) }
        if let cap {
            cap.stopAllAnimations()
            cap.position = capBase + capAxis * Self.depth(state)
        }
    }

    private static func depth(_ state: ButtonState) -> Float {
        switch state {
        case .unavailable: capLowered
        case .available: capRest
        case .completed: capSettled
        }
    }

    private func setAccents(_ hex: UInt32) {
        accentColor = hex
        let material = Self.glow(hex)
        for entity in accents {
            guard var model = entity.components[ModelComponent.self] else { continue }
            model.materials = Array(repeating: material, count: max(1, model.materials.count))
            entity.components.set(model)
        }
    }

    private func colorStrips(_ hex: UInt32) {
        stripColor = hex
        for strip in strips { strip.model?.materials = [Self.glow(hex)] }
    }

    /// The cap's own colour: its authored red, or green lit from within (face and sidewall).
    private func setCapGreen(_ green: Bool) {
        capIsGreen = green
        for (entity, authored) in capModels {
            guard var model = entity.components[ModelComponent.self] else { continue }
            if green {
                // The asset's cap lists its face first, its sidewall second.
                model.materials = model.materials.indices.map { i in
                    i == 0 ? Self.capGreen(Palette.capGreen) : Self.capGreen(Palette.capGreenSide)
                }
            } else {
                model.materials = authored
            }
            entity.components.set(model)
        }
    }

    private func setHalo(_ hex: UInt32, opacity: Float) {
        haloColor = hex
        haloOpacity = opacity
        halo.isEnabled = opacity > 0
        halo.model?.materials = [Self.haloMaterial(hex, opacity: opacity)]
    }

    /// The halo swells and settles (activation and the gate opening).
    private func popHalo() {
        guard !reduceMotion else { return }
        halo.stopAllAnimations()
        var small = halo.transform, big = halo.transform, rest = halo.transform
        small.scale = [0.8, 0.8, 1]
        big.scale = [1.25, 1.25, 1]
        rest.scale = .one
        halo.transform = rest
        if let out = try? AnimationResource.generate(with: FromToByAnimation<Transform>(
               from: small, to: big, duration: 0.14, timing: .easeOut, bindTarget: .transform)),
           let back = try? AnimationResource.generate(with: FromToByAnimation<Transform>(
               from: big, to: rest, duration: 0.3, timing: .easeInOut, bindTarget: .transform)),
           let pop = try? AnimationResource.sequence(with: [out, back]) {
            halo.playAnimation(pop)
        }
    }

    private func setLight(_ intensity: Float) {
        lightLevel = intensity
        guard var point = light.components[PointLightComponent.self] else { return }
        point.intensity = intensity
        light.components.set(point)
    }

    /// Plays the cap along its axis through `legs` (from, to, seconds, timing; depths from its rest)
    /// and leaves it at `ending`.
    private func play(_ cap: Entity, _ legs: [(Float, Float, Double, AnimationTimingFunction)], ending: Float) {
        cap.stopAllAnimations()
        let base = cap.transform
        func at(_ z: Float) -> Transform {
            var t = base
            t.translation = capBase + capAxis * z
            return t
        }
        cap.transform = at(ending)
        let resources = legs.compactMap { leg in
            try? AnimationResource.generate(with: FromToByAnimation<Transform>(
                from: at(leg.0), to: at(leg.1), duration: leg.2, timing: leg.3, bindTarget: .transform))
        }
        if resources.count == legs.count, let sequence = try? AnimationResource.sequence(with: resources) {
            cap.playAnimation(sequence)
        }
    }

    // MARK: - Diagnostics

    /// The cap's depth along the button's axis from its modelled rest (0 rest, negative pressed).
    func capDepth(_ key: LaserVaultButton = .activate) -> Float? {
        cap.map { simd_dot($0.position - capBase, capAxis) / simd_length_squared(capAxis) }
    }
    func glowColor(_ key: LaserVaultButton = .activate) -> UInt32? { accentColor }

    // MARK: - Building

    /// The button's collar to the door frame, its glow (the halo, over the plate and the frame round it)
    /// and the light in front of it. Nothing else is built.
    private func buildModule() {
        module.name = "vault.console.glow"
        module.position = console.button.center
        module.orientation = Self.orientation(normal: console.button.normal, up: console.button.up)
        root.addChild(module)
        halo.name = "vault.console.halo"
        halo.model = ModelComponent(mesh: .generatePlane(width: 2 * Self.haloRadius, height: 2 * Self.haloRadius),
                                    materials: [Self.haloMaterial(Palette.haloRed, opacity: 0)])
        // On the door's surface behind the collar: the glow the (unlit) door shows round the button,
        // behind the mascot (a quad inside its translucent body would cut a square out of it). The
        // light tints the button and the mascot.
        halo.position = [0, 0, -LaserGateConsole.plateDepth - LaserGateConsole.standoff + 0.003]
        halo.isEnabled = false
        module.addChild(halo)
        collar.name = "vault.console.collar"
        let size = LaserGateConsole.collarSize
        collar.model = ModelComponent(mesh: .generateBox(size: [size, size, LaserGateConsole.standoff], cornerRadius: 0.02),
                                      materials: [Self.lit(Palette.collar, roughness: 0.45, metallic: 0.6)])
        // Shifted outward so it sits wholly on the jamb (the door's panels slide open behind it).
        collar.position = [console.side * LaserGateConsole.collarShift, 0, -LaserGateConsole.plateDepth - LaserGateConsole.standoff / 2]
        module.addChild(collar)
        light.name = "vault.console.light"
        light.position = [0, 0, 0.3]
        var point = PointLightComponent(color: Self.color(Palette.capGreenGlow), intensity: 0, attenuationRadius: Self.lightRange)
        point.attenuationFalloffExponent = 2
        light.components.set(point)
        module.addChild(light)
    }

    /// Puts a button model (the asset's clone, or the stand-in) on the mount and re-applies the state.
    private func install(_ model: Entity, asset: Bool) {
        buttonMount.findEntity(named: "vault.console.buttonModel")?.removeFromParent()
        model.name = "vault.console.buttonModel"
        buttonMount.addChild(model)
        usesAsset = asset
        cap = model.findEntity(named: "Cap")
        capBase = cap?.position ?? .zero
        if let parent = cap?.parent {
            capAxis = parent.convert(position: [0, 0, 1], from: buttonMount) - parent.convert(position: .zero, from: buttonMount)
        }
        capModels = Self.models(in: cap).compactMap { e in e.components[ModelComponent.self].map { (e, $0.materials) } }
        accents = Self.models(in: model.findEntity(named: "Accents"))
        cap?.position = capBase + capAxis * Self.depth(state)
        setAccents(accentColor)
        setCapGreen(capIsGreen)
    }

    /// The entities with a model under `entity` (itself included).
    private static func models(in entity: Entity?) -> [Entity] {
        guard let entity else { return [] }
        var out: [Entity] = entity.components.has(ModelComponent.self) ? [entity] : []
        for child in entity.children { out += models(in: child) }
        return out
    }

    /// A simple stand-in with the asset's part names and proportions, shown only until the asset loads.
    private static func standIn() -> Entity {
        let root = Entity()
        let housing = ModelEntity(mesh: .generateBox(size: [2 * LaserGateConsole.plateHalf, 2 * LaserGateConsole.plateHalf, 0.05], cornerRadius: 0.03),
                                  materials: [lit(0x241E58, roughness: 0.42, metallic: 0.35)])
        housing.name = "Housing"
        housing.position = [0, 0, -0.025]
        root.addChild(housing)
        let cap = Entity()
        cap.name = "Cap"
        let body = ModelEntity(mesh: .generateCylinder(height: LaserGateConsole.capFront, radius: LaserGateConsole.radius),
                               materials: [lit(0xE3122C, roughness: 0.25, metallic: 0.05, emissive: 0xC0001A, intensity: 0.35)])
        body.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        body.position = [0, 0, LaserGateConsole.capFront / 2]
        cap.addChild(body)
        root.addChild(cap)
        let accents = Entity()
        accents.name = "Accents"
        let bars: [SIMD4<Float>] = [[0, 0.19, 0.08, 0.017], [0, -0.19, 0.08, 0.017], [0.19, 0, 0.017, 0.08], [-0.19, 0, 0.017, 0.08]]
        for bar in bars {
            let entity = ModelEntity(mesh: .generateBox(size: [bar.z, bar.w, 0.01], cornerRadius: 0.004), materials: [glow(Palette.accent)])
            entity.position = [bar.x, bar.y, 0.03]
            accents.addChild(entity)
        }
        root.addChild(accents)
        return root
    }

    /// The mount's rotation: +Z along the button's normal, +Y along its up.
    static func orientation(normal: SIMD3<Float>, up: SIMD3<Float>) -> simd_quatf {
        let z = simd_normalize(normal)
        var y = up - simd_dot(up, z) * z
        if simd_length(y) < 1e-4 { y = [0, 1, 0] }
        y = simd_normalize(y)
        let x = simd_cross(y, z)
        return simd_quatf(simd_float3x3(columns: (x, y, z)))
    }

    // MARK: - Loading the asset

    static let resourceName = "GateButton"
    private static var sharedLoad: Task<Entity?, Never>?
    /// The loaded button, once `sharedTemplate()` has finished; `nil` before or without it.
    private(set) static var loadedTemplate: Entity?

    /// The button from the Reality Composer Pro package, loaded once per app run (preloaded with the
    /// mascots, `RobotAvatarLayer.sharedTemplates()`); `nil` when the package or asset is unavailable
    /// (the console then keeps the stand-in). A failed load is retried on the next call.
    @discardableResult
    static func sharedTemplate() async -> Entity? {
        #if canImport(RealityKitContent)
        let load = sharedLoad ?? Task {
            do {
                return try await Entity(named: resourceName, in: realityKitContentBundle)
            } catch {
                print("GateConsoleView: \(resourceName) failed to load, keeping the stand-in: \(error)")
                return nil
            }
        }
        sharedLoad = load
        let template = await load.value
        if template == nil { sharedLoad = nil }
        loadedTemplate = template
        return template
        #else
        return nil
        #endif
    }

    // MARK: - Materials

    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static func mix(_ a: UInt32, _ b: UInt32, _ t: Float) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Float((a >> shift) & 0xFF), y = Float((b >> shift) & 0xFF)
            return UInt32(max(0, min(255, (x + (y - x) * t).rounded()))) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    private static func lit(_ hex: UInt32, roughness: Float, metallic: Float, emissive: UInt32? = nil, intensity: Float = 0,
                            clearcoat: Float = 0) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color(hex))
        m.roughness = .init(floatLiteral: roughness)
        m.metallic = .init(floatLiteral: metallic)
        if clearcoat > 0 { m.clearcoat = .init(floatLiteral: clearcoat) }
        if let emissive {
            m.emissiveColor = .init(color: color(emissive))
            m.emissiveIntensity = intensity
        }
        return m
    }

    /// The activated cap: glossy green, lit from within so it reads as glowing in the corridor.
    private static func capGreen(_ hex: UInt32) -> PhysicallyBasedMaterial {
        var m = lit(hex, roughness: 0.22, metallic: 0.05, emissive: Palette.capGreenGlow, intensity: 1.4, clearcoat: 0.6)
        m.clearcoatRoughness = .init(floatLiteral: 0.08)
        return m
    }

    private static func glow(_ hex: UInt32) -> UnlitMaterial {
        UnlitMaterial(color: color(hex))
    }

    /// A soft ring of light (white in the texture, tinted by the material), brightest just outside
    /// the plate and fading out at the halo's edge.
    private static let haloTexture: TextureResource? = {
        let size = 128
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let inner = LaserGateConsole.plateHalf / haloRadius
        let peak = inner + 0.06
        for row in 0..<size {
            for column in 0..<size {
                let u = (Float(column) + 0.5) / Float(size) * 2 - 1, v = (Float(row) + 0.5) / Float(size) * 2 - 1
                let r = (u * u + v * v).squareRoot()
                let a = r < 1 ? max(0, 1 - abs(r - peak) / (r < peak ? 0.18 : 1 - peak)) : 0
                let i = (row * size + column) * 4
                let value = UInt8(min(255, a * a * 255))
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

    private static func haloMaterial(_ hex: UInt32, opacity: Float) -> UnlitMaterial {
        var m = UnlitMaterial(applyPostProcessToneMap: false)
        if let haloTexture {
            m.color = .init(tint: color(hex), texture: .init(haloTexture))
        } else {
            m.color = .init(tint: color(hex).withAlphaComponent(0.4))
        }
        m.blending = .transparent(opacity: .init(floatLiteral: max(0, min(1, opacity))))
        // A glow: it never hides what is behind or inside it (the translucent mascot cut a square out of it).
        m.writesDepth = false
        return m
    }
}
