//
//  VaultPresentation.swift
//  Sedactive
//

import RealityKit
import UIKit

/// Presents Jevon's authoritative Dual Key Vault (LH-18 P0): the existing
/// vault door, its shared countdown and six button status indicators.
/// Driven by `GameplayScenePresenter` from the same game state and events;
/// it decides nothing and keeps no clock.
///
/// State to visual:
/// - Entering `.vault` with a new `vault.id`: the door fades in, locked, at
///   the authored `VaultDoorStop`, standing still in the corridor (travel is
///   stopped). There is no approach: the next vault's start time is not in
///   game state yet.
/// - `vault.deadline − gameTime`, over the configured vault duration: the
///   countdown bar on the door. Game time freezes on pause, so does the bar.
/// - `vault.buttons[player]`: three indicators per player (top, middle,
///   bottom). A newly activated one pops once.
/// - `vault.opened` or `coopGateSucceeded`: the door opens, once. It then
///   stays put in the corridor and passes the players as travel resumes, and
///   is hidden before it reaches the camera.
/// - `.ended(.vaultFailed)`: the countdown empties and turns red; the door
///   stays locked. Results follows at once (no added delay).
/// - Any other end while the vault is closed (e.g. End round): hidden.
///
/// The indicators are status only, not hit targets: their positions and
/// look are provisional until G11 (contact geometry) and Theo's design.
/// They sit on the door, so they move and fade with it.
@MainActor
final class VaultPresentation {
    struct Diagnostics: Equatable {
        var reveals = 0
        var opens = 0
        var activations = 0
        var timeouts = 0
    }

    enum Indicator: Equatable { case idle, active }

    /// Provisional indicator layout on the door face (pending G11 and Theo),
    /// chosen from the game camera's projection at the door's stop: in the
    /// landscape view the players cover the door's sides (P1 from head height
    /// down, the replay HUD the top-left corner), so the one place clear of
    /// both figures, the HUD, the countdown and the lock light on every iPad
    /// landscape size is the middle of the door. P1's column is left of the
    /// centre seam and P2's mirrors it on the right, both below the countdown
    /// and above the hoverboard. `VaultPresentationTests` checks this projection.
    static let indicatorColumnX: Float = 0.55
    static let indicatorHeights: [LaserVaultButton: Float] = [.top: 2.15, .middle: 1.6, .bottom: 1.05]
    /// About 35 pt across at the door's distance.
    static let indicatorSize: Float = 0.34
    /// Countdown bar just below the lock light, narrow enough to stay clear of P1.
    static let countdownHeight: Float = 2.55
    static let countdownWidth: Float = 1.4

    private let scene: LaserScene
    private let vaultDuration: Double
    /// Parent of the six indicators, on the interaction plane.
    let root = Entity()
    private var indicators: [PlayerID: [LaserVaultButton: (part: Entity, idle: Entity, active: Entity)]] = [:]
    private let countdown = Entity()
    private let countdownTrack: ModelEntity
    private let countdownFill: ModelEntity
    private var attachedToDoor: Bool?
    private var vaultID: UUID?
    /// Travel distance at which the door would stand on the interaction plane.
    private var anchor: Float?
    private var shownButtons: [PlayerID: Set<LaserVaultButton>] = [:]
    private var succeeded: Set<UUID> = []
    private var openedID: UUID?
    private var failedID: UUID?
    private var hidden = true
    private(set) var diagnostics = Diagnostics()
    /// Remaining share of the vault opportunity shown, or `nil` when no countdown shows.
    private(set) var countdownFraction: Float?
    private(set) var indicatorsShown = false

    init(scene: LaserScene, configuration: LaserRoundConfiguration) {
        self.scene = scene
        vaultDuration = configuration.vaultDuration
        root.name = "vault.indicators"
        root.isEnabled = false
        countdown.name = "vault.countdown"
        countdownTrack = ModelEntity(mesh: .generatePlane(width: Self.countdownWidth, height: 0.1),
                                     materials: [Self.flat(0x1C1944)])
        countdownFill = ModelEntity(mesh: .generatePlane(width: Self.countdownWidth - 0.1, height: 0.06),
                                    materials: [Self.flat(0xFFE3B3)])
        countdownFill.position.z = 0.002
        countdown.addChild(countdownTrack)
        countdown.addChild(countdownFill)
        countdown.isEnabled = false
        countdown.position = [0, Self.countdownHeight, 0.04]
        root.addChild(countdown)
        for player in PlayerID.allCases {
            var parts: [LaserVaultButton: (Entity, Entity, Entity)] = [:]
            for button in LaserVaultButton.allCases {
                let part = Entity()
                part.name = "vault.indicator.\(player.rawValue).\(button.rawValue)"
                let idle = Self.face(Self.indicatorArt(active: false), fallback: 0x2A2560)
                let active = Self.face(Self.indicatorArt(active: true), fallback: 0x3BCF7E)
                part.addChild(idle)
                part.addChild(active)
                part.position = [(player == .player1 ? -1 : 1) * Self.indicatorColumnX,
                                 Self.indicatorHeights[button] ?? 1.6, 0.05]
                root.addChild(part)
                parts[button] = (part, idle, active)
            }
            indicators[player] = parts
        }
    }

    /// The indicator shown for a button, or `nil` when indicators are hidden.
    func indicator(_ player: PlayerID, _ button: LaserVaultButton) -> Indicator? {
        guard indicatorsShown, let parts = indicators[player]?[button] else { return nil }
        return parts.active.isEnabled ? .active : .idle
    }

    /// The authoritative success event for a vault (`coopGateSucceeded`).
    func markSucceeded(_ gateID: UUID) {
        succeeded.insert(gateID)
    }

    // MARK: - Applying game state

    func update(state: LaserGameState, travelDistance: Float) {
        guard let vault = state.vault else { return hideAll() }
        let ended: LaserRoundOutcome? = if case .ended(let outcome) = state.phase { outcome } else { nil }
        if vault.id != vaultID {
            // Only entering a vault reveals it; a finished one left in state is not re-shown.
            guard state.phase == .vault else { return }
            begin(vault, travelDistance: travelDistance)
        }
        let isOpen = openedID == vault.id
        if let ended, ended != .vaultFailed, !isOpen, !(vault.opened || succeeded.contains(vault.id)) {
            return hideAll()
        }
        guard !hidden else { return }
        showActivations(vault)
        if !isOpen, vault.opened || succeeded.contains(vault.id) {
            open(vault)
        }
        updateCountdown(vault, at: state.gameTime, failed: ended == .vaultFailed)
        place(travelDistance: travelDistance)
    }

    /// Hides the door, countdown and indicators; called when the session stops.
    func stop() {
        hideAll()
    }

    /// Forgets the current vault, e.g. for a new session generation.
    func reset() {
        hideAll()
        vaultID = nil
        openedID = nil
        failedID = nil
        succeeded = []
        shownButtons = [:]
    }

    private func begin(_ vault: LaserVaultState, travelDistance: Float) {
        vaultID = vault.id
        openedID = nil
        failedID = nil
        hidden = false
        shownButtons = [:]
        anchor = travelDistance + (scene.mapping.interactionPlaneZ - scene.layout.vaultDoorStopZ)
        scene.resetVaultDoor()
        scene.setVaultDoorDepth(scene.layout.vaultDoorStopZ)
        scene.revealVaultDoor()
        if attachedToDoor == nil {
            // Countdown and indicators ride on the door; without door artwork
            // they stand where the door would be.
            attachedToDoor = scene.attachToVaultDoor(root)
            if attachedToDoor == false {
                root.position = [0, 0, scene.layout.vaultDoorStopZ]
                scene.root.addChild(root)
            }
        }
        countdownTrack.model?.materials = [Self.flat(0x1C1944)]
        countdownFill.isEnabled = true
        countdown.isEnabled = true
        for parts in indicators.values.flatMap(\.values) {
            parts.idle.isEnabled = true
            parts.active.isEnabled = false
            parts.part.stopAllAnimations()
            parts.part.scale = .one
        }
        root.stopAllAnimations()
        root.components.set(OpacityComponent(opacity: 1))
        root.isEnabled = true
        indicatorsShown = true
        diagnostics.reveals += 1
    }

    private func showActivations(_ vault: LaserVaultState) {
        for player in PlayerID.allCases {
            let now = vault.buttons[player, default: []]
            for button in now.subtracting(shownButtons[player, default: []]) {
                guard let parts = indicators[player]?[button] else { continue }
                parts.idle.isEnabled = false
                parts.active.isEnabled = true
                Self.pop(parts.part)
                diagnostics.activations += 1
            }
            shownButtons[player] = now
        }
    }

    private func open(_ vault: LaserVaultState) {
        openedID = vault.id
        scene.setVaultDoorState(.open, animated: true)
        countdown.isEnabled = false
        countdownFraction = nil
        // Let the last activation read, then fade the indicators out (cosmetic).
        Self.fadeOut(root, after: 0.3, duration: 0.5)
        indicatorsShown = false
        diagnostics.opens += 1
    }

    private func updateCountdown(_ vault: LaserVaultState, at time: Double, failed: Bool) {
        guard openedID != vault.id else { return }
        if failed {
            if failedID != vault.id {
                failedID = vault.id
                countdownTrack.model?.materials = [Self.flat(0xE5484D)]
                countdownFill.isEnabled = false
                diagnostics.timeouts += 1
            }
            countdownFraction = 0
            return
        }
        let remaining = max(0, vault.deadline - time)
        let fraction = vaultDuration > 0 ? Float(min(1, remaining / vaultDuration)) : 0
        countdownFraction = fraction
        countdownFill.scale.x = max(fraction, 0.001)
    }

    /// The door stands still in the corridor: on its stop while the team waits,
    /// then passing the players as travel resumes, hidden before the camera.
    private func place(travelDistance: Float) {
        guard let anchor else { return }
        let depth = scene.mapping.interactionPlaneZ - (anchor - travelDistance)
        let nearCamera = scene.layout.cameraPosition.z - GameplayScenePresenter.cameraClearance
        scene.setVaultDoorDepth(depth < nearCamera ? depth : nil)
    }

    private func hideAll() {
        hidden = true
        scene.setVaultDoorDepth(nil)
        scene.resetVaultDoor()
        countdown.isEnabled = false
        countdownFraction = nil
        root.stopAllAnimations()
        root.isEnabled = false
        indicatorsShown = false
    }

    // MARK: - Look (placeholder until Theo's art)

    private static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    /// A quick scale pop about the indicator's own place (its translation is kept).
    private static func pop(_ part: Entity) {
        part.stopAllAnimations()
        part.scale = .one
        guard !reduceMotion else { return }
        let rest = part.transform
        var big = rest
        big.scale = .init(repeating: 1.35)
        let up = FromToByAnimation(from: rest, to: big, duration: 0.12, timing: .easeOut, bindTarget: .transform)
        let down = FromToByAnimation(from: big, to: rest, duration: 0.18, timing: .easeIn, bindTarget: .transform)
        guard let steps = try? [up, down].map({ try AnimationResource.generate(with: $0) }),
              let sequence = try? AnimationResource.sequence(with: steps) else { return }
        part.playAnimation(sequence)
    }

    private static func fadeOut(_ part: Entity, after delay: TimeInterval, duration: TimeInterval) {
        part.components.set(OpacityComponent(opacity: 0))
        let hold = FromToByAnimation<Float>(from: 1, to: 1, duration: delay, bindTarget: .opacity)
        let fade = FromToByAnimation<Float>(from: 1, to: 0, duration: duration, timing: .easeIn, bindTarget: .opacity)
        guard let steps = try? [hold, fade].map({ try AnimationResource.generate(with: $0) }),
              let sequence = try? AnimationResource.sequence(with: steps) else { return }
        part.playAnimation(sequence)
    }

    private static func face(_ image: CGImage?, fallback: UInt32) -> ModelEntity {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: color(fallback))
        if let image, let texture = try? TextureResource(image: image, options: .init(semantic: .color)) {
            material.color = .init(tint: .white, texture: .init(texture))
            material.blending = .transparent(opacity: 1.0)
            material.opacityThreshold = 0.02
        }
        return ModelEntity(mesh: .generatePlane(width: indicatorSize, height: indicatorSize), materials: [material])
    }

    /// Idle: a lavender ring on a dark disc. Active: a green disc with a white check.
    private static func indicatorArt(active: Bool) -> CGImage? {
        let size = CGSize(width: 96, height: 96)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let disc = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
            color(active ? 0x3BCF7E : 0x1C1944).setFill()
            UIBezierPath(ovalIn: disc).fill()
            color(active ? 0xFFFFFF : 0x9D8CFF).setStroke()
            if active {
                let check = UIBezierPath()
                check.move(to: CGPoint(x: 28, y: 50))
                check.addLine(to: CGPoint(x: 43, y: 64))
                check.addLine(to: CGPoint(x: 69, y: 34))
                check.lineWidth = 9
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                check.stroke()
            } else {
                let ring = UIBezierPath(ovalIn: disc.insetBy(dx: 4, dy: 4))
                ring.lineWidth = 6
                ring.stroke()
            }
        }
        return image.cgImage
    }

    private static func flat(_ hex: UInt32) -> UnlitMaterial {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: color(hex))
        return material
    }

    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
