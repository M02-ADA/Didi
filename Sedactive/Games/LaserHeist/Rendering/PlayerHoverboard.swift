//
//  PlayerHoverboard.swift
//  Sedactive
//

import Foundation
import RealityKit
import UIKit
#if canImport(RealityKitContent)
import RealityKitContent
#endif

/// One player's 3D hoverboard, standing under that player's mascot on its lane.
///
/// The model is `PlayerHoverboard.usdz` in the Reality Composer Pro package,
/// built from `Art/LaserHeist/Hoverboard/` (Blender source, script and
/// previews). Both players share the geometry; each gets its own clone with
/// its accent colour (Lemon yellow, Tangerine orange).
///
/// Presentation only (TEAM_ALIGNMENT §C): the board never moves the player's
/// lane entity, its `ride`, the mascot or anything judged. It only moves
/// itself, and only on RealityKit frame time (cosmetic animation):
/// - Idle hover: the deck sinks up to `hoverDepth` and back. It never rises
///   above the soles, so the feet never sink into it.
/// - Bank: the board tilts toward the mascot's shown trunk lean (K03), at most
///   `maximumBank`, smoothed over `bankTime`. The deck drops by the bank's rise
///   under the stance, so the higher side stays under the raised foot.
/// - Ride (live lean): the board CARRIES the mascot sideways (`Input.ride`: the shown hip
///   shift plus the lean steering travel, `LateralSteering`, which alone keeps the boards off
///   the walls and apart), and the mascot's feet are planted on the board, so avatar and board
///   move together with no foot sliding.
/// - Glide (no ride given): the board stays under the mascot's stance, so a side
///   step or dodge carries it along.
/// - A jump push-off sinks the board slightly, and the contact shadow under
///   the mascot fades while it is airborne.
/// - Tracking loss: no stale input is kept. The mascot's shown pose relaxes,
///   and while the player is unavailable the board eases back to level.
@MainActor
final class PlayerHoverboard {
    /// The asset's name in the Reality Composer Pro package.
    static let resourceName = "PlayerHoverboard"

    /// The board was modelled for 1.6 m mascots and is shown at their current
    /// size (`RobotAvatarLayer.standingHeight`), so it always fits their stance.
    nonisolated static let scale: Float = RobotAvatarLayer.standingHeight / 1.6

    /// Largest bank, about 6°: clearly visible with a lean, never unstable-looking
    /// (owner request 11 November 2026; 3° read as no response). The deck drops by its rise
    /// under the stance, so together with the hover and push-off it stays within 3.5 cm.
    nonisolated static let maximumBank: Float = 0.105
    /// Bank per radian of shown trunk lean (the robot's lean is at most 0.35).
    nonisolated static let bankPerLean: Float = 0.5
    /// Bank smoothing time constant (seconds): responsive, but never a snap.
    nonisolated static let bankTime: Float = 0.12
    /// How far the idle hover sinks the deck, and how long one breath takes.
    nonisolated static let hoverDepth: Float = 0.008 * scale
    nonisolated static let hoverPeriod: Float = 2.6
    /// A slower pitch sway that stabilises the hover (radians, period).
    nonisolated static let pitchAmplitude: Float = 0.006
    nonisolated static let pitchPeriod: Float = 3.7
    /// Half the mascots' stance (`Foot_L`/`Foot_R` at ±0.139 model units, 0.16 m
    /// on a 1.6 m mascot). The deck drops by a bank's rise here, so neither sole sinks.
    nonisolated static let footHalfSpan: Float = 0.16 * scale
    /// Half the mascots' foot length: the deck drops by a pitch's rise here.
    nonisolated static let footHalfLength: Float = 0.16 * scale
    /// Extra sink per metre of jump lift (the push-off), capped at `maximumRecoil`.
    nonisolated static let recoilPerLift: Float = 0.05
    nonisolated static let maximumRecoil: Float = 0.008 * scale
    nonisolated static let recoilTime: Float = 0.1
    /// How quickly the board follows the stance when it glides (no ride given). Where it may go is
    /// `LateralSteering`'s: the walls and the partner's board, never a lane limit (owner, 12 November
    /// 2026: the earlier ±0.45 m outward / 0.06 m inward lane limits kept the mascots nearly still).
    nonisolated static let glideTime: Float = 0.08
    /// Half the board's width in the asset (1.16 m at 1.6 m mascots), for the steering's spacing
    /// when the loaded model reports no bounds.
    nonisolated static let halfWidth: Float = 0.58 * scale
    /// Lift at which the contact shadow is gone.
    nonisolated static let shadowFadeLift: Float = 0.25

    /// Accent colours of the end stripes (Theo's mascot colours).
    static let accentColor: [PlayerID: UIColor] = [
        .player1: UIColor(red: 0xF6 / 255, green: 0xCA / 255, blue: 0x58 / 255, alpha: 1),
        .player2: UIColor(red: 0xF7 / 255, green: 0x81 / 255, blue: 0x46 / 255, alpha: 1),
    ]

    /// What the board follows each frame: the mascot's shown pose.
    struct Input: Equatable {
        /// Shown trunk lean (radians, + toward screen right).
        var lean: Float = 0
        /// The mascot's root X on its lane (metres), for the contact shadow.
        var centerX: Float = 0
        /// The centre of the mascot's feet on its lane (metres): where the board glides to.
        var stanceX: Float = 0
        /// The mascot's root lift (metres).
        var lift: Float = 0
        /// Whether the player is tracked. Unavailable: the board levels out.
        var available = false
        /// The board's ride offset (metres from the lane centre, render-smoothed, kept off the
        /// walls and the partner by `LateralSteering`): the board sits exactly here, carrying the
        /// planted feet.
        /// Nil: glide under the stance instead.
        var ride: Float?
    }

    /// The board's own motion, stepped on frame time. Deterministic: the same
    /// inputs and steps give the same motion.
    struct Motion: Equatable {
        var bank: Float = 0
        var recoil: Float = 0
        /// The board's offset from the lane centre (metres).
        var offsetX: Float = 0
        var hoverPhase: Float = 0
        var pitchPhase: Float = 0

        init(hoverPhase: Float = 0, pitchPhase: Float = 0) {
            self.hoverPhase = hoverPhase
            self.pitchPhase = pitchPhase
        }

        static func bankTarget(for input: Input) -> Float {
            guard input.available, input.lean.isFinite else { return 0 }
            return min(maximumBank, max(-maximumBank, bankPerLean * input.lean))
        }

        mutating func step(dt: Float, input: Input) {
            let dt = max(0, min(dt, 0.1))
            bank += (Self.bankTarget(for: input) - bank) * (1 - exp(-dt / bankTime))
            let push = input.available && input.lift.isFinite ? min(maximumRecoil, recoilPerLift * max(0, input.lift)) : 0
            recoil += (push - recoil) * (1 - exp(-dt / recoilTime))
            if let ride = input.ride, ride.isFinite {
                offsetX = ride // the feet are planted on it: no lag
            } else {
                let glide = input.stanceX.isFinite ? input.stanceX : 0
                offsetX += (glide - offsetX) * (1 - exp(-dt / glideTime))
            }
            hoverPhase = (hoverPhase + 2 * .pi * dt / hoverPeriod).truncatingRemainder(dividingBy: 2 * .pi)
            pitchPhase = (pitchPhase + 2 * .pi * dt / pitchPeriod).truncatingRemainder(dividingBy: 2 * .pi)
        }

        /// Roll about the board's long axis: a lean to screen right dips the right side.
        var roll: Float { -bank }
        var pitch: Float { pitchAmplitude * sin(pitchPhase) }
        /// How far the deck sits below the soles' plane (≤ 0): the hover, the
        /// push-off, and whatever a bank or pitch would otherwise raise under a foot.
        var height: Float {
            -(hoverDepth * (1 - cos(hoverPhase)) / 2 + recoil
              + footHalfSpan * sin(abs(bank)) + footHalfLength * sin(abs(pitch)))
        }
    }

    let player: PlayerID
    /// Lane-local container. The lane entity itself never moves.
    let root = Entity()
    /// The model clone; it hovers and banks.
    let model: Entity
    private let underglow: ModelEntity
    private let contactShadow: ModelEntity
    private(set) var motion: Motion
    var input = Input()
    private var shadowOpacity: Float = -1
    private var glowOpacity: Float = -1

    /// - Parameters:
    ///   - template: the loaded board; it is cloned, never shown.
    ///   - floorY: the corridor floor's height relative to the lane (the
    ///     players' feet), where the thrusters' light lands.
    init(template: Entity, player: PlayerID, floorY: Float) {
        _ = Self.registration
        self.player = player
        root.name = "player.\(player.rawValue).hoverboard"
        model = template.clone(recursive: true)
        model.name = "hoverboard.model"
        root.addChild(model)
        // Each board starts its hover at its own phase, so the two never breathe in unison.
        motion = Motion(hoverPhase: player == .player1 ? 0 : 2.2, pitchPhase: player == .player1 ? 1.1 : 0)
        if let accent = model.findEntity(named: "Accent"), let color = Self.accentColor[player] {
            Self.tint(accent, color)
        }
        underglow = ModelEntity(mesh: Self.glowMesh, materials: [Self.glowMaterial])
        underglow.name = "hoverboard.underglow"
        underglow.position = [0, floorY + 0.02, 0]
        underglow.scale = [Self.scale, 1, Self.scale]
        root.addChild(underglow)
        contactShadow = ModelEntity(mesh: Self.shadowMesh, materials: [Self.shadowMaterial])
        contactShadow.name = "hoverboard.contactShadow"
        contactShadow.position = [0, 0.003, 0]
        model.addChild(contactShadow)
        root.components.set(HoverboardComponent(board: self))
        apply()
    }

    /// Advances the hover and bank by `dt` seconds of frame time (`HoverboardSystem`).
    func step(dt: Float) {
        motion.step(dt: dt, input: input)
        apply()
    }

    private func apply() {
        model.transform = Transform(scale: SIMD3(repeating: Self.scale),
                                    rotation: simd_quatf(angle: motion.roll, axis: [0, 0, 1]) * simd_quatf(angle: motion.pitch, axis: [1, 0, 0]),
                                    translation: [motion.offsetX, motion.height, 0])
        underglow.position.x = motion.offsetX
        let lift = input.available && input.lift.isFinite ? max(0, input.lift) : 0
        // The shadow sits under the mascot, in the board's own (scaled, glided) space.
        let x = input.centerX.isFinite ? (input.centerX - motion.offsetX) / Self.scale : 0
        contactShadow.position.x = min(0.35, max(-0.35, x))
        let shadow = 1 - min(1, lift / Self.shadowFadeLift)
        if abs(shadow - shadowOpacity) > 0.01 {
            shadowOpacity = shadow
            contactShadow.isEnabled = shadow > 0.01
            contactShadow.components.set(OpacityComponent(opacity: shadow))
        }
        // The thrusters' light on the floor brightens a little as the board sinks toward it.
        let glow = 0.75 + 0.25 * (1 - cos(motion.hoverPhase)) / 2
        if abs(glow - glowOpacity) > 0.01 {
            glowOpacity = glow
            underglow.components.set(OpacityComponent(opacity: glow))
        }
    }

    private static func tint(_ entity: Entity, _ color: UIColor) {
        if var model = entity.components[ModelComponent.self] {
            model.materials = model.materials.map { material in
                guard var pbr = material as? PhysicallyBasedMaterial else { return material }
                pbr.baseColor = .init(tint: color)
                pbr.emissiveColor = .init(color: color)
                return pbr
            }
            entity.components.set(model)
        }
        for child in entity.children { tint(child, color) }
    }

    // MARK: - Loading

    private static var sharedLoad: Task<Entity?, Never>?
    /// The loaded board, once `sharedTemplate()` has finished; `nil` before or without it.
    private(set) static var loadedTemplate: Entity?

    /// The board from the Reality Composer Pro package, loaded once per app
    /// run; `nil` when the package or asset is unavailable (the scene then
    /// keeps its shared 2D board). A failed load is retried on the next call.
    static func sharedTemplate() async -> Entity? {
        #if canImport(RealityKitContent)
        let load = sharedLoad ?? Task {
            do {
                return try await Entity(named: resourceName, in: realityKitContentBundle)
            } catch {
                print("PlayerHoverboard: \(resourceName) failed to load, keeping the 2D board: \(error)")
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

    // MARK: - Shared meshes and materials

    private static let registration: Void = {
        HoverboardComponent.registerComponent()
        HoverboardSystem.registerSystem()
    }()

    private static let glowMesh = MeshResource.generatePlane(width: 1.3, depth: 0.55)
    private static let shadowMesh = MeshResource.generatePlane(width: 0.62, depth: 0.32)

    /// The thrusters' warm light on the corridor floor: a soft oval pool.
    private static let glowMaterial = radialMaterial("hoverboard.underglow", color: (1.0, 0.8, 0.52), alpha: 0.17, falloff: 2.0)
    /// The mascot's soft contact shadow on the deck.
    private static let shadowMaterial = radialMaterial("hoverboard.contactShadow", color: (0.08, 0.06, 0.2), alpha: 0.45, falloff: 1.2)

    private static func radialMaterial(_ name: String, color: (Float, Float, Float), alpha: Float, falloff: Float) -> UnlitMaterial {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        let size = 64
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for row in 0..<size {
            for column in 0..<size {
                let u = (Float(column) + 0.5) / Float(size) * 2 - 1
                let v = (Float(row) + 0.5) / Float(size) * 2 - 1
                let r = min(1, (u * u + v * v).squareRoot())
                let a = alpha * pow(1 - r * r, falloff)
                let i = (row * size + column) * 4
                pixels[i] = UInt8((color.0 * a * 255).rounded())
                pixels[i + 1] = UInt8((color.1 * a * 255).rounded())
                pixels[i + 2] = UInt8((color.2 * a * 255).rounded())
                pixels[i + 3] = UInt8((a * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let texture = try? TextureResource(image: image, withName: name, options: .init(semantic: .color))
        else {
            material.color = .init(tint: .clear)
            material.blending = .transparent(opacity: 0.0)
            return material
        }
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: 1.0)
        return material
    }
}

/// Marks a hoverboard root for `HoverboardSystem`.
struct HoverboardComponent: Component {
    weak var board: PlayerHoverboard?
}

/// Steps every hoverboard once per rendered frame on RealityKit's frame time.
/// Cosmetic only: no game clock, and nothing judged moves (TEAM_ALIGNMENT §C).
struct HoverboardSystem: System {
    private static let query = EntityQuery(where: .has(HoverboardComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let dt = Float(context.deltaTime)
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            entity.components[HoverboardComponent.self]?.board?.step(dt: dt)
        }
    }
}
