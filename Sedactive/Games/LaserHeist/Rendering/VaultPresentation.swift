//
//  VaultPresentation.swift
//  Sedactive
//

import RealityKit
import UIKit

/// Presents Jevon's authoritative Dual Key Vault (LH-18): the existing vault
/// door, its shared countdown and six button status indicators, for every
/// vault of a round. Driven by `GameplayScenePresenter` from the same game
/// state and events; it decides nothing and keeps no clock.
///
/// State to visual:
/// - A new `vault.id` while the phase is `.vault`: the door fades in, locked,
///   at the authored `VaultDoorStop`, standing still in the corridor (travel
///   is stopped). There is no approach: the next vault's start time is not in
///   game state. A vault that begins and resolves between two updates (a long
///   frame) is shown from its own `coopGateSucceeded`/`coopGateFailed` event.
/// - If the previous vault's opened door is still in view when the next one
///   begins, that door is handed to a one-off exiting copy that fades out
///   where it stands, so the door never jumps back to its stop. At most one
///   copy exists; it is removed when its fade completes, or on the next
///   handoff, reset or stop.
/// - `vault.deadline − gameTime`: the countdown bar, over the configured
///   vault duration, and the whole seconds left as a number between the two
///   button columns. In the last `urgentRemaining` seconds the bar thickens
///   and turns warm. Game time freezes on pause, so do both.
/// - `vault.buttons[player]`: three indicators per player (top, middle,
///   bottom): a ring when idle, a check when active. A newly activated one
///   pops once. When all three of a player's buttons are active, an outline
///   frames that player's column, once.
/// - `vault.opened` or `coopGateSucceeded`: the door opens, once. It then
///   stays put in the corridor and passes the players as travel resumes, and
///   is hidden before it reaches the camera.
/// - `.ended(.vaultFailed)`: the countdown empties, turns red and reads 0;
///   the door stays locked. Results follows at once (no added delay).
/// - Any other end while the vault is closed (e.g. End round): hidden.
///
/// Reduce Motion: no pops; the outline and the exiting door change at once;
/// the door panels fade instead of sliding. Nothing is conveyed by colour
/// alone: idle/active differ in shape (ring/check), completion adds an
/// outline, urgency thickens the bar, and failure shows 0.
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
        /// Players whose three buttons were all shown active, once per vault.
        var sideCompletions = 0
        /// Vaults that began while the previous opened door was still in view.
        var handoffs = 0
        /// Pop animations played (none with Reduce Motion).
        var pops = 0
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
    /// The seconds-left number, centred between the two columns.
    static let digitHeight: Float = 0.42
    static let digitCenterY: Float = 1.6
    /// Margin of a completed column's outline around its three indicators.
    static let outlinePadding: Float = 0.05
    static let outlineThickness: Float = 0.03
    /// Remaining seconds from which the countdown shows urgency (provisional, Theo).
    static let urgentRemaining: Double = 2
    /// The previous door's fade when the next vault begins (cosmetic, RealityKit time).
    static let exitFadeDuration: TimeInterval = 0.35

    private let scene: LaserScene
    private let vaultDuration: Double
    /// Parent of the countdown, number, indicators and outlines, on the door.
    let root = Entity()
    private var indicators: [PlayerID: [LaserVaultButton: (part: Entity, idle: Entity, active: Entity)]] = [:]
    private var outlines: [PlayerID: Entity] = [:]
    private let countdown = Entity()
    private let countdownTrack: ModelEntity
    private let countdownFill: ModelEntity
    private let digitsRoot = Entity()
    private var digits: [Int: Entity] = [:]
    private var attachedToDoor: Bool?
    private var vaultID: UUID?
    /// Travel distance at which the door would stand on the interaction plane.
    private var anchor: Float?
    private var shownButtons: [PlayerID: Set<LaserVaultButton>] = [:]
    private var completedSides: Set<PlayerID> = []
    private var succeeded: Set<UUID> = []
    private var failed: Set<UUID> = []
    private var openedID: UUID?
    private var failedID: UUID?
    /// The countdown look last applied: (urgent, failed).
    private var style: (urgent: Bool, failed: Bool)?
    private var hidden = true
    /// Whether a state of this generation was applied before (a vault first
    /// seen already resolved is only shown if it resolved since then).
    private var hasApplied = false
    private var exiting: (entity: Entity, fade: AnimationPlaybackController?)?
    private(set) var diagnostics = Diagnostics()
    /// Remaining share of the vault opportunity shown, or `nil` when no countdown shows.
    private(set) var countdownFraction: Float?
    /// Whole seconds left as shown, or `nil` when no countdown shows.
    private(set) var countdownDigit: Int?
    private(set) var indicatorsShown = false
    /// Reads the system setting when used; tests override it.
    var reducesMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }

    init(scene: LaserScene, configuration: LaserRoundConfiguration) {
        self.scene = scene
        vaultDuration = configuration.vaultDuration
        root.name = "vault.indicators"
        root.isEnabled = false
        countdown.name = "vault.countdown"
        countdownTrack = ModelEntity(mesh: .generatePlane(width: Self.countdownWidth, height: 0.1),
                                     materials: [Self.flat(Self.trackColor)])
        countdownFill = ModelEntity(mesh: .generatePlane(width: Self.countdownWidth - 0.1, height: 0.06),
                                    materials: [Self.flat(Self.fillColor)])
        countdownFill.position.z = 0.002
        countdown.addChild(countdownTrack)
        countdown.addChild(countdownFill)
        countdown.isEnabled = false
        countdown.position = [0, Self.countdownHeight, 0.04]
        root.addChild(countdown)
        digitsRoot.name = "vault.countdown.digits"
        digitsRoot.position = [0, Self.digitCenterY, 0.05]
        digitsRoot.isEnabled = false
        for value in 0...max(0, Int(configuration.vaultDuration.rounded(.up))) {
            let digit = Self.digit(value)
            digit.isEnabled = false
            digitsRoot.addChild(digit)
            digits[value] = digit
        }
        root.addChild(digitsRoot)
        for player in PlayerID.allCases {
            let x = (player == .player1 ? -1 : 1) * Self.indicatorColumnX
            var parts: [LaserVaultButton: (Entity, Entity, Entity)] = [:]
            for button in LaserVaultButton.allCases {
                let part = Entity()
                part.name = "vault.indicator.\(player.rawValue).\(button.rawValue)"
                let idle = Self.face(Self.indicatorArt(active: false), fallback: 0x2A2560)
                let active = Self.face(Self.indicatorArt(active: true), fallback: 0x3BCF7E)
                part.addChild(idle)
                part.addChild(active)
                part.position = [x, Self.indicatorHeights[button] ?? 1.6, 0.05]
                root.addChild(part)
                parts[button] = (part, idle, active)
            }
            indicators[player] = parts
            let outline = Self.outline()
            outline.name = "vault.outline.\(player.rawValue)"
            outline.position = [x, Self.outlineCenterY, 0.045]
            outline.isEnabled = false
            root.addChild(outline)
            outlines[player] = outline
        }
    }

    /// The indicator shown for a button, or `nil` when indicators are hidden.
    func indicator(_ player: PlayerID, _ button: LaserVaultButton) -> Indicator? {
        guard indicatorsShown, let parts = indicators[player]?[button] else { return nil }
        return parts.active.isEnabled ? .active : .idle
    }

    /// Whether a player's column shows its completion outline, or `nil` when indicators are hidden.
    func sideComplete(_ player: PlayerID) -> Bool? {
        guard indicatorsShown else { return nil }
        return outlines[player]?.isEnabled ?? false
    }

    /// Whether the countdown shows urgency, or `nil` when no countdown shows.
    var countdownUrgent: Bool? { countdownFraction == nil ? nil : style?.urgent }
    /// The previous vault's door, fading out, if any.
    var exitingDoor: Entity? { exiting?.entity }

    /// The authoritative success event for a vault (`coopGateSucceeded`).
    func markSucceeded(_ gateID: UUID) {
        succeeded.insert(gateID)
    }

    /// The authoritative timeout event for a vault (`coopGateFailed`).
    func markFailed(_ gateID: UUID) {
        failed.insert(gateID)
    }

    // MARK: - Applying game state

    func update(state: LaserGameState, travelDistance: Float) {
        defer { hasApplied = true }
        if let fade = exiting?.fade, fade.isComplete { removeExiting() }
        guard let vault = state.vault else { return hideAll() }
        let ended: LaserRoundOutcome? = if case .ended(let outcome) = state.phase { outcome } else { nil }
        if vault.id != vaultID {
            // Only entering a vault reveals it; one left in state from before is
            // not re-shown, unless it resolved since the last update.
            let resolvedSince = hasApplied && (succeeded.contains(vault.id) || failed.contains(vault.id))
            guard state.phase == .vault || resolvedSince else { return }
            begin(vault, travelDistance: travelDistance)
        }
        let isOpen = openedID == vault.id
        let opens = vault.opened || succeeded.contains(vault.id)
        if let ended, ended != .vaultFailed, !isOpen, !opens {
            return hideAll()
        }
        guard !hidden else { return }
        showActivations(vault)
        if !isOpen, opens {
            open(vault)
        }
        updateCountdown(vault, at: state.gameTime, failed: ended == .vaultFailed || failed.contains(vault.id))
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
        anchor = nil
        openedID = nil
        failedID = nil
        succeeded = []
        failed = []
        shownButtons = [:]
        completedSides = []
        hasApplied = false
    }

    private func begin(_ vault: LaserVaultState, travelDistance: Float) {
        if !hidden, scene.vaultDoorDepth != nil { handOffPreviousDoor() }
        vaultID = vault.id
        openedID = nil
        failedID = nil
        hidden = false
        shownButtons = [:]
        completedSides = []
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
        applyStyle(urgent: false, failed: false)
        countdownFill.isEnabled = true
        countdownFill.scale = .one
        countdown.isEnabled = true
        digitsRoot.isEnabled = true
        for parts in indicators.values.flatMap(\.values) {
            parts.idle.isEnabled = true
            parts.active.isEnabled = false
            parts.part.stopAllAnimations()
            parts.part.scale = .one
        }
        for outline in outlines.values {
            outline.stopAllAnimations()
            outline.scale = .one
            outline.isEnabled = false
        }
        root.stopAllAnimations()
        root.components.set(OpacityComponent(opacity: 1))
        root.isEnabled = true
        indicatorsShown = true
        diagnostics.reveals += 1
    }

    /// The previous vault's opened door is still in view: leave a copy of it
    /// fading out where it stands, so the real door can start the new vault
    /// at its stop without visibly jumping there.
    private func handOffPreviousDoor() {
        removeExiting()
        diagnostics.handoffs += 1
        guard !reducesMotion(), let copy = scene.makeVaultDoorCopy(excluding: root.name) else { return }
        copy.name = "vaultDoor.exiting"
        copy.components.set(OpacityComponent(opacity: 0))
        let fade = FromToByAnimation<Float>(from: 1, to: 0, duration: Self.exitFadeDuration, timing: .easeIn, bindTarget: .opacity)
        let controller = (try? AnimationResource.generate(with: fade)).map { copy.playAnimation($0) }
        exiting = (copy, controller)
    }

    private func removeExiting() {
        exiting?.entity.stopAllAnimations()
        exiting?.entity.removeFromParent()
        exiting = nil
    }

    private func showActivations(_ vault: LaserVaultState) {
        for player in PlayerID.allCases {
            let now = vault.buttons[player, default: []]
            for button in now.subtracting(shownButtons[player, default: []]) {
                guard let parts = indicators[player]?[button] else { continue }
                parts.idle.isEnabled = false
                parts.active.isEnabled = true
                if !reducesMotion() {
                    Self.pop(parts.part, to: 1.35)
                    diagnostics.pops += 1
                }
                diagnostics.activations += 1
            }
            shownButtons[player] = now
            if now.count == LaserVaultButton.allCases.count, completedSides.insert(player).inserted,
               let outline = outlines[player] {
                outline.isEnabled = true
                if !reducesMotion() {
                    Self.pop(outline, to: 1.06)
                    diagnostics.pops += 1
                }
                diagnostics.sideCompletions += 1
            }
        }
    }

    private func open(_ vault: LaserVaultState) {
        openedID = vault.id
        scene.setVaultDoorState(.open, animated: true, reduceMotion: reducesMotion())
        countdown.isEnabled = false
        digitsRoot.isEnabled = false
        countdownFraction = nil
        countdownDigit = nil
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
                applyStyle(urgent: true, failed: true)
                countdownFill.isEnabled = false
                diagnostics.timeouts += 1
            }
            countdownFraction = 0
            showDigit(0)
            return
        }
        let remaining = max(0, vault.deadline - time)
        let fraction = vaultDuration > 0 ? Float(min(1, remaining / vaultDuration)) : 0
        countdownFraction = fraction
        countdownFill.scale.x = max(fraction, 0.001)
        showDigit(Int(remaining.rounded(.up)))
        applyStyle(urgent: remaining <= Self.urgentRemaining, failed: false)
    }

    private func showDigit(_ value: Int) {
        let shown = min(max(0, value), digits.count - 1)
        guard countdownDigit != shown else { return }
        countdownDigit = shown
        for (value, digit) in digits { digit.isEnabled = value == shown }
    }

    /// Urgency thickens the bar and warms it; failure turns the track red.
    /// Materials change only when the look changes, not every frame.
    private func applyStyle(urgent: Bool, failed: Bool) {
        if let style, style == (urgent, failed) { return }
        style = (urgent, failed)
        countdown.scale = urgent ? [1, 1.6, 1] : .one
        countdownFill.model?.materials = [Self.flat(urgent ? Self.urgentColor : Self.fillColor)]
        countdownTrack.model?.materials = [Self.flat(failed ? Self.failedColor : Self.trackColor)]
        let digitColor = failed ? Self.failedColor : urgent ? Self.urgentColor : Self.fillColor
        for digit in digits.values {
            (digit.children.first as? ModelEntity)?.model?.materials = [Self.flat(digitColor)]
        }
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
        removeExiting()
        scene.setVaultDoorDepth(nil)
        scene.resetVaultDoor()
        countdown.isEnabled = false
        digitsRoot.isEnabled = false
        countdownFraction = nil
        countdownDigit = nil
        root.stopAllAnimations()
        root.isEnabled = false
        indicatorsShown = false
    }

    // MARK: - Look (placeholder until Theo's art)

    private static let trackColor: UInt32 = 0x1C1944
    private static let fillColor: UInt32 = 0xFFE3B3
    private static let urgentColor: UInt32 = 0xFF9A3C
    private static let failedColor: UInt32 = 0xE5484D
    private static let completeColor: UInt32 = 0x3BCF7E

    static var outlineCenterY: Float {
        let heights = indicatorHeights.values
        return ((heights.max() ?? 1.6) + (heights.min() ?? 1.6)) / 2
    }

    /// The completed-column outline's outer size.
    static var outlineSize: SIMD2<Float> {
        let heights = indicatorHeights.values
        return [indicatorSize + 2 * outlinePadding,
                (heights.max() ?? 0) - (heights.min() ?? 0) + indicatorSize + 2 * outlinePadding]
    }

    /// A rectangle framing one player's three indicators.
    private static func outline() -> Entity {
        let width = outlineSize.x, height = outlineSize.y
        let frame = Entity()
        let t = outlineThickness
        for (size, position) in [(SIMD2(width, t), SIMD2<Float>(0, (height - t) / 2)),
                                 (SIMD2(width, t), SIMD2<Float>(0, -(height - t) / 2)),
                                 (SIMD2(t, height), SIMD2<Float>(-(width - t) / 2, 0)),
                                 (SIMD2(t, height), SIMD2<Float>((width - t) / 2, 0))] {
            let edge = ModelEntity(mesh: .generatePlane(width: size.x, height: size.y), materials: [flat(completeColor)])
            edge.position = [position.x, position.y, 0]
            frame.addChild(edge)
        }
        return frame
    }

    /// One countdown number, centred on its parent.
    private static func digit(_ value: Int) -> Entity {
        let holder = Entity()
        holder.name = "vault.countdown.digit.\(value)"
        let mesh = MeshResource.generateText("\(value)", extrusionDepth: 0.001,
                                             font: .monospacedDigitSystemFont(ofSize: CGFloat(digitHeight), weight: .heavy))
        let text = ModelEntity(mesh: mesh, materials: [flat(fillColor)])
        let bounds = mesh.bounds
        text.position = [-bounds.center.x, -bounds.center.y, 0]
        holder.addChild(text)
        return holder
    }

    /// A quick scale pop about the entity's own place (its translation is kept).
    private static func pop(_ part: Entity, to peak: Float) {
        part.stopAllAnimations()
        part.scale = .one
        let rest = part.transform
        var big = rest
        big.scale = .init(repeating: peak)
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
