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
/// - Approach: when the session says how much activity time is left before
///   the next vault (`upcomingVaultIn`; the replay script knows, production
///   is PENDING Jevon), the locked door already stands at the corridor's far
///   end, fully opaque, then comes closer at travel speed, reaching its stop
///   as travel stops for the vault. No fade. No countdown or buttons show
///   before the vault begins.
/// - A new `vault.id` while the phase is `.vault`: an approaching door is
///   already at the authored `VaultDoorStop`; otherwise the door fades in
///   there, locked, standing still in the corridor (travel is stopped). A
///   vault that begins and resolves between two updates (a long
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
///   bottom), Theo's wall buttons (Sketch Hi-Fi 30 OCT "Opening the Door",
///   `VaultDoor` scene `VaultButtons`): red when idle, green with a check
///   when active. A newly activated one pops once. When all three of a
///   player's buttons are active, an outline frames that player's column, once.
/// - `vault.opened` or `coopGateSucceeded`: the door opens, once. It then
///   stays put in the corridor and passes the players as travel resumes, and
///   is hidden before it reaches the camera.
/// - `.ended(.vaultFailed)`: the countdown empties, turns red and reads 0;
///   the door stays locked. Results follows at once (no added delay).
/// - Any other end while the vault is closed (e.g. End round): hidden.
///
/// Reduce Motion: no pops; the outline and the exiting door change at once;
/// the door panels fade instead of sliding. Nothing is conveyed by colour
/// alone: an active button adds a check, completion adds an outline,
/// urgency thickens the bar, and failure shows 0.
///
/// The indicators are status only, not hit targets; activation comes only
/// from Jevon's `vault.buttons`. Their placement is provisional until G11
/// (contact geometry). The countdown and number sit on the door and move
/// with it; the button columns stand on the corridor walls beside the
/// players, as in the Sketch, and travel with the door once it opens.
@MainActor
final class VaultPresentation {
    struct Diagnostics: Equatable {
        var reveals = 0
        /// Doors that came down the corridor before their vault began.
        var approaches = 0
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

    /// Provisional indicator layout (pending G11), after Theo's Sketch: one
    /// column of buttons on each corridor wall, P1's on the left and P2's on
    /// the right, at the screen's outer edges. At the door's stop the door
    /// projects behind the two mascots, so the columns stand nearer, on the
    /// walls just ahead of the players, clear of both figures, the HUD, the
    /// countdown and the lock light on every iPad landscape size.
    /// `VaultPresentationTests` checks this projection.
    static let indicatorColumnX: Float = 2.8
    /// World depth of the columns while the door stands at its stop.
    static let indicatorDepthZ: Float = -2.4
    static let indicatorHeights: [LaserVaultButton: Float] = [.top: 2.15, .middle: 1.6, .bottom: 1.05]
    /// Bounding square of one button (its art is `buttonSize`).
    static let indicatorSize: Float = 0.42
    /// Theo's button art, 772 × 1050 px.
    static let buttonSize: SIMD2<Float> = [0.31, 0.42]
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
    /// Parent of the countdown and number, on the door.
    let root = Entity()
    /// Parent of the button columns and outlines, on the corridor walls.
    let buttons = Entity()
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
    /// Live rounds: each button's world centre (X, height) and radius: its wrist contact zone
    /// through the mascot mapping (`GameWorldMapping.mascotPoint`), the same as the wrists' reach
    /// cursors: a cursor on a button is a wrist in its zone. Nil (replay, or no zone): Theo's walls.
    var liveButtons: ((PlayerID, LaserVaultButton) -> (center: SIMD2<Float>, radius: Float)?)?
    /// Live rounds with mascots: each player's wall-mounted button console (`LaserGateConsole`).
    /// When every shown player has one, the buttons are mounted on it, facing into the corridor,
    /// where the mascot's hand lands from its dock; `liveButtons` is then not used.
    var liveConsoles: ((PlayerID) -> LaserGateConsole?)?
    /// The drawn consoles (housing and physical buttons), built once per console geometry.
    private(set) var consoleViews: [PlayerID: GateConsoleView] = [:]
    private var consoleMode = false
    /// Live buttons stand IN FRONT of the mascots (toward the camera), so a leaning mascot's
    /// large head never covers them (iPad screenshot, 11 November 2026); the reach cursors are
    /// drawn just in front of the buttons.
    static let liveButtonDepthInFront: Float = 0.25
    /// Depth of the button columns while the door stands at its stop (wall or live layout).
    private var buttonsBaseZ = indicatorDepthZ
    private var liveLayout = false
    private var outlineRest: [PlayerID: SIMD3<Float>] = [:]
    /// The players whose button column is shown: both, or P1 alone in a DEBUG Solo Test.
    var visiblePlayers: Set<PlayerID> = Set(PlayerID.allCases) {
        didSet { for (player, parts) in indicators { for p in parts.values { p.part.isEnabled = visiblePlayers.contains(player) } } }
    }
    private var succeeded: Set<UUID> = []
    private var failed: Set<UUID> = []
    private var openedID: UUID?
    private var failedID: UUID?
    /// The countdown look last applied: (urgent, failed).
    private var style: (urgent: Bool, failed: Bool)?
    private var hidden = true
    /// The next vault's locked door is coming down the corridor (no vault yet).
    private(set) var approaching = false
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
        buttons.name = "vault.buttons"
        buttons.isEnabled = false
        buttons.position = [0, 0, Self.indicatorDepthZ]
        scene.root.addChild(buttons)
        let art = scene.vaultButtonArt
        for player in PlayerID.allCases {
            let x = (player == .player1 ? -1 : 1) * Self.indicatorColumnX
            var parts: [LaserVaultButton: (Entity, Entity, Entity)] = [:]
            for button in LaserVaultButton.allCases {
                let part = Entity()
                part.name = "vault.indicator.\(player.rawValue).\(button.rawValue)"
                let idle = Self.button(art?[VaultButtonArtKey(player: player, active: false)], player: player, active: false)
                let active = Self.button(art?[VaultButtonArtKey(player: player, active: true)], player: player, active: true)
                part.addChild(idle)
                part.addChild(active)
                part.position = [x, Self.indicatorHeights[button] ?? 1.6, 0.05]
                buttons.addChild(part)
                parts[button] = (part, idle, active)
            }
            indicators[player] = parts
            let outline = Self.outline()
            outline.name = "vault.outline.\(player.rawValue)"
            outline.position = [x, Self.outlineCenterY, 0.045]
            outline.isEnabled = false
            buttons.addChild(outline)
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

    /// - Parameter upcomingVaultIn: activity seconds until the next vault
    ///   begins, from the session's schedule, or `nil` when it isn't known
    ///   (production until Jevon exposes it). With it, the locked door comes
    ///   down the corridor like a laser gate; without it, it fades in at its stop.
    func update(state: LaserGameState, travelDistance: Float, upcomingVaultIn: Double? = nil) {
        defer { hasApplied = true }
        if let fade = exiting?.fade, fade.isComplete { removeExiting() }
        if approach(state: state, upcomingVaultIn: upcomingVaultIn) { return }
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
        for view in consoleViews.values { view.reset() }
        hasApplied = false
    }

    /// Where a door waits until its vault is near: just inside the corridor's
    /// far end, so it reads as part of the corridor, not as something placed
    /// in front of the players.
    var approachHorizonZ: Float { scene.layout.corridorFarZ + 2 }

    /// How far ahead of its stop the door stands at the horizon.
    var approachDistance: Float { max(0, scene.layout.vaultDoorStopZ - approachHorizonZ) }

    /// Shows the next vault's locked door in the corridor while the team still
    /// travels: standing at the far end until the vault is within the
    /// corridor's length, then coming closer at travel speed × activity time
    /// left, the same rule as laser gates. Travel stops when the vault begins,
    /// so the door is then exactly at its stop and nothing jumps. Fully opaque
    /// from its first frame; distance alone makes it small. Presentation only:
    /// the countdown and buttons appear when the vault actually begins.
    /// Returns whether the door is approaching (and the rest of `update` is skipped).
    private func approach(state: LaserGameState, upcomingVaultIn lead: Double?) -> Bool {
        guard state.phase == .activity, let lead, lead > 0 else { return false }
        let distance = min(scene.layout.travelSpeed * Float(lead), approachDistance)
        // The previous vault's opened door must have passed out of view first:
        // there is one door.
        if let vault = state.vault, !(vault.id == vaultID && openedID == vaultID && (approaching || scene.vaultDoorDepth == nil)) {
            return false
        }
        if !approaching {
            hideAll()
            hidden = false
            approaching = true
            scene.resetVaultDoor()
            scene.showVaultDoorOpaque()
            diagnostics.approaches += 1
        }
        scene.setVaultDoorDepth(scene.layout.vaultDoorStopZ - distance)
        // The wall consoles appear (all red) a few seconds before the gate, so the players can steer
        // to their docks before its time starts; nothing is judged until the gate opens.
        if lead <= Self.consoleLead { revealConsolesEarly() }
        return true
    }

    /// How long before a live gate its wall consoles appear (seconds of activity time).
    static let consoleLead: Double = 4

    private func revealConsolesEarly() {
        guard !consoleMode else { return }
        let shown = PlayerID.allCases.filter { visiblePlayers.contains($0) }
        let consoles = Dictionary(uniqueKeysWithValues: shown.compactMap { p in liveConsoles?(p).map { (p, $0) } })
        guard !shown.isEmpty, consoles.count == shown.count else { return }
        buttons.stopAllAnimations()
        buttons.components.set(OpacityComponent(opacity: 1))
        buttons.isEnabled = true
        shownButtons = [:]
        layoutConsoles(consoles)
        for view in consoleViews.values { view.reset() }
    }

    private func begin(_ vault: LaserVaultState, travelDistance: Float) {
        let arrived = approaching
        approaching = false
        if !arrived, !hidden, scene.vaultDoorDepth != nil { handOffPreviousDoor() }
        vaultID = vault.id
        openedID = nil
        failedID = nil
        hidden = false
        shownButtons = [:]
        completedSides = []
        for view in consoleViews.values { view.reset() }
        anchor = travelDistance + (scene.mapping.interactionPlaneZ - scene.layout.vaultDoorStopZ)
        scene.resetVaultDoor()
        scene.setVaultDoorDepth(scene.layout.vaultDoorStopZ)
        // An approaching door is already in view: it arrives, it doesn't fade in again.
        if !arrived { scene.revealVaultDoor() }
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
        for part in [root, buttons] {
            part.stopAllAnimations()
            part.components.set(OpacityComponent(opacity: 1))
            part.isEnabled = true
        }
        layoutButtons()
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
                if consoleMode, let view = consoleViews[player] {
                    // The physical button: press, pulse, RED → GREEN (once).
                    view.complete(button, reduceMotion: reducesMotion())
                    diagnostics.activations += 1
                    continue
                }
                if !reducesMotion() {
                    Self.pop(parts.part, to: 1.35)
                    diagnostics.pops += 1
                }
                diagnostics.activations += 1
            }
            shownButtons[player] = now
            if consoleMode, now.count == LaserVaultButton.allCases.count, visiblePlayers.contains(player),
               completedSides.insert(player).inserted {
                consoleViews[player]?.setSideComplete(true)
                diagnostics.sideCompletions += 1
            } else if !consoleMode, now.count == LaserVaultButton.allCases.count, visiblePlayers.contains(player),
               completedSides.insert(player).inserted,
               let outline = outlines[player] {
                outline.isEnabled = true
                if !reducesMotion() {
                    Self.pop(outline, to: 1.06, rest: outlineRest[player] ?? .one)
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
        Self.fadeOut(buttons, after: 0.3, duration: 0.5)
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
        // The wall columns travel with the door once it opens.
        // Wall columns ride with the door; live buttons beside the players stay put (they fade).
        buttons.position.z = liveLayout ? buttonsBaseZ : buttonsBaseZ + (depth - scene.layout.vaultDoorStopZ)
        let nearCamera = scene.layout.cameraPosition.z - GameplayScenePresenter.cameraClearance
        scene.setVaultDoorDepth(depth < nearCamera ? depth : nil)
    }

    /// Places every shown column: on its live contact zones when all of them are known, else on
    /// the wall columns. Each button's art then spans its zone's diameter.
    private func layoutButtons() {
        let shown = PlayerID.allCases.filter { visiblePlayers.contains($0) }
        let consoles = Dictionary(uniqueKeysWithValues: shown.compactMap { p in liveConsoles?(p).map { (p, $0) } })
        if !shown.isEmpty, consoles.count == shown.count {
            layoutConsoles(consoles)
            return
        }
        consoleMode = false
        scene.robotAvatars?.consolesActive = false
        for view in consoleViews.values { view.root.isEnabled = false }
        for parts in indicators.values { for p in parts.values { p.part.orientation = simd_quatf() } }
        for outline in outlines.values { outline.orientation = simd_quatf() }
        var live: [PlayerID: [LaserVaultButton: (center: SIMD2<Float>, radius: Float)]] = [:]
        for player in shown {
            for button in LaserVaultButton.allCases {
                if let zone = liveButtons?(player, button) { live[player, default: [:]][button] = zone }
            }
        }
        let isLive = !shown.isEmpty && shown.allSatisfy { live[$0]?.count == LaserVaultButton.allCases.count }
        liveLayout = isLive
        buttonsBaseZ = isLive ? scene.mapping.interactionPlaneZ + Self.liveButtonDepthInFront : Self.indicatorDepthZ
        buttons.position.z = buttonsBaseZ
        for (player, parts) in indicators {
            let x = (player == .player1 ? -1 : 1) * Self.indicatorColumnX
            var bounds: (min: SIMD2<Float>, max: SIMD2<Float>)?
            for (button, part) in parts {
                let zone = isLive ? live[player]?[button] : nil
                let center = zone?.center ?? [x, Self.indicatorHeights[button] ?? 1.6]
                let size = zone.map { 2 * $0.radius / Self.buttonSize.y } ?? 1
                part.part.position = [center.x, center.y, 0.05]
                part.idle.scale = [size, size, size]
                part.active.scale = [size, size, size]
                let half = Self.buttonSize * size / 2
                bounds = (min(bounds?.min ?? center - half, center - half), max(bounds?.max ?? center + half, center + half))
            }
            if let outline = outlines[player], !isLive {
                // Theo's wall columns: the outline as designed.
                outline.position = [x, Self.outlineCenterY, 0.045]
                outline.scale = .one
                outlineRest[player] = .one
            } else if let outline = outlines[player], let bounds {
                let pad = Self.outlinePadding
                let extent = bounds.max - bounds.min + 2 * pad
                let center = (bounds.max + bounds.min) / 2
                outline.position = [center.x, center.y, 0.045]
                outline.scale = [extent.x / Self.outlineSize.x, extent.y / Self.outlineSize.y, 1]
                outlineRest[player] = outline.scale
            }
        }
    }

    /// The unified wall consoles (`GateConsoleView`): the 2D indicator art and outlines step aside;
    /// the buttons' parent stands at depth 0 so the consoles keep their world positions.
    private func layoutConsoles(_ consoles: [PlayerID: LaserGateConsole]) {
        liveLayout = true
        consoleMode = true
        buttonsBaseZ = 0
        buttons.position.z = 0
        scene.robotAvatars?.consolesActive = true
        for (player, parts) in indicators {
            for p in parts.values { p.part.isEnabled = false }
            outlines[player]?.isEnabled = false
            guard let console = consoles[player] else { consoleViews[player]?.root.isEnabled = false; continue }
            let view: GateConsoleView
            if let existing = consoleViews[player], existing.console == console {
                view = existing
            } else {
                consoleViews[player]?.root.removeFromParent()
                view = GateConsoleView(console: console)
                buttons.addChild(view.root)
                consoleViews[player] = view
            }
            view.root.isEnabled = true
            // The game's current activations, at once (a console shown mid-gate is never replayed).
            for button in LaserVaultButton.allCases {
                if shownButtons[player, default: []].contains(button) { view.complete(button, reduceMotion: true) }
            }
        }
    }

    /// Where one button is drawn now (world X/height), for tests and diagnostics.
    func buttonPosition(_ player: PlayerID, _ button: LaserVaultButton) -> SIMD3<Float>? {
        guard let part = indicators[player]?[button]?.part else { return nil }
        return [part.position.x, part.position.y, buttons.position.z + part.position.z]
    }

    private func hideAll() {
        hidden = true
        approaching = false
        removeExiting()
        scene.setVaultDoorDepth(nil)
        scene.resetVaultDoor()
        countdown.isEnabled = false
        digitsRoot.isEnabled = false
        countdownFraction = nil
        countdownDigit = nil
        root.stopAllAnimations()
        root.isEnabled = false
        buttons.stopAllAnimations()
        buttons.isEnabled = false
        scene.robotAvatars?.consolesActive = false
        indicatorsShown = false
    }

    // MARK: - Look (placeholder until Theo's art)

    private static let trackColor: UInt32 = 0x1C1944
    /// The wall consoles: the corridor's indigo, a lighter mounting face, the LOW ledge between.
    private static let consoleColor: UInt32 = 0x2A2560
    private static let consoleLedgeColor: UInt32 = 0x332D72
    private static let consoleFaceColor: UInt32 = 0x4A438F
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
    private static func pop(_ part: Entity, to peak: Float, rest scale: SIMD3<Float> = .one) {
        part.stopAllAnimations()
        part.scale = scale
        let rest = part.transform
        var big = rest
        big.scale = scale * peak
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

    /// One button state: a clone of Theo's art from the `VaultDoor` scene, or the
    /// code art without it. Active adds a white check, so state never relies on colour.
    private static func button(_ template: Entity?, player: PlayerID, active: Bool) -> Entity {
        guard let template else {
            return face(indicatorArt(active: active), fallback: active ? 0x3BCF7E : 0x2A2560)
        }
        let face = template.clone(recursive: true)
        face.transform = .identity
        guard active else { return face }
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        if let image = checkArt(), let texture = try? TextureResource(image: image, options: .init(semantic: .color)) {
            material.color = .init(tint: .white, texture: .init(texture))
            material.blending = .transparent(opacity: 1.0)
            material.opacityThreshold = 0.02
        }
        let check = ModelEntity(mesh: .generatePlane(width: 0.2, height: 0.2), materials: [material])
        check.name = "vault.indicator.check"
        // Centred on the button's face, which sits toward the corridor in each side's art.
        check.position = [(player == .player1 ? 1 : -1) * buttonSize.x * 0.14, 0, 0.003]
        face.addChild(check)
        return face
    }

    /// A white check with a dark rim, readable on the green button.
    static func checkArt() -> CGImage? {
        let size = CGSize(width: 128, height: 128)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let check = UIBezierPath()
            check.move(to: CGPoint(x: 30, y: 66))
            check.addLine(to: CGPoint(x: 54, y: 90))
            check.addLine(to: CGPoint(x: 98, y: 38))
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            color(0x1C1944).setStroke()
            check.lineWidth = 26
            check.stroke()
            UIColor.white.setStroke()
            check.lineWidth = 14
            check.stroke()
        }.cgImage
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
