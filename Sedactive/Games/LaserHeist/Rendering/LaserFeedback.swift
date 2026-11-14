//
//  LaserFeedback.swift
//  Sedactive
//

import RealityKit
import UIKit

/// Player-facing laser cues (LH-05): the shared DUCK/JUMP instruction with a
/// countdown to the crossing, and a short per-player outcome badge and impact.
///
/// It presents what the caller passes and decides nothing: the move, the cue
/// and crossing times and every verdict come from Jevon's encounter and game
/// state (TEAM_ALIGNMENT §B). The cue follows Theo's Sketch type style
/// (drawn in code: the hand-off has no cue bitmap); the badges remain
/// temporary code art until Theo's VFX assets exist.
/// Animations are cosmetic RealityKit time; with Reduce Motion they become fades.
@MainActor
final class LaserFeedback {
    /// The move both players make for one laser: a high beam means duck, a low beam means jump.
    enum Move: String, CaseIterable {
        case duck, jump
    }

    /// How a player's finalized verdict is shown. PENDING shows nothing, and
    /// UNAVAILABLE stays neutral: it reports tracking, never a player mistake.
    enum Outcome: String, CaseIterable {
        case clear, hit, unavailable
    }

    let root = Entity()
    private let cue = Entity()
    private let cuePanels: [Move: Entity]
    private let countdown: ModelEntity
    private var shownCue: (move: Move, acting: Bool)?
    private let badges: [PlayerID: Entity]
    private let badgeFaces: [PlayerID: [Outcome: Entity]]
    private var impacts: [PlayerID: Entity] = [:]
    private lazy var timingRenderer: TimingIndicatorRenderer = {
        let renderer = TimingIndicatorRenderer()
        renderer.root.position = [0, 0, 0.004]
        cue.addChild(renderer.root)
        return renderer
    }()
    private(set) var timingVariant: TimingIndicatorVariant = .circular
    private(set) var timingModel: LaserTimingPresentation?
    private var timingPaused = false
    private var approvedCue: (Move?, Float?) = (nil, nil)

    func selectTimingVariant(_ variant: TimingIndicatorVariant) {
        if timingVariant != variant { shownCue = nil }
        timingVariant = variant
        if variant == .approved {
            timingRenderer.apply(nil, variant: .approved, reduceMotion: Self.reduceMotion)
            let previous = approvedCue
            setMoveCue(previous.0, actionRemaining: previous.1)
            countdown.isEnabled = previous.0 != nil && previous.1 != nil
        } else { setTimingPresentation(timingModel) }
    }
    func setTimingPaused(_ paused: Bool) {
        timingPaused = paused
        if timingVariant != .approved { setTimingPresentation(timingModel) }
    }
    func setTimingPresentation(_ model: LaserTimingPresentation?) {
        timingModel = model
        guard timingVariant != .approved else { return }
        guard let model, !timingPaused else {
            timingRenderer.apply(nil, variant: timingVariant, reduceMotion: Self.reduceMotion)
            if shownCue != nil { hideCue() }
            return
        }
        let move: Move = model.move == .duck ? .duck : .jump
        if shownCue?.move != move || shownCue?.acting != true { showCue(move, acting: true) }
        countdown.isEnabled = false
        for panel in cuePanels.values { panel.isEnabled = timingVariant != .circular && panel == cuePanels[move] }
        timingRenderer.root.position.y = timingVariant == .circular ? 0.075 : -0.215
        if timingVariant == .circular {
            cue.stopAllAnimations(); cue.scale = .one
            cue.components.set(OpacityComponent(opacity: 1))
        }
        timingRenderer.apply(model, variant: timingVariant, reduceMotion: Self.reduceMotion)
    }

    /// Builds every cue, badge and texture once; showing them later only toggles and animates.
    init() {
        let panelSize: SIMD2<Float> = [0.9, 0.28]
        let panelMesh = MeshResource.generatePlane(width: panelSize.x, height: panelSize.y)
        var cuePanels: [Move: Entity] = [:]
        for move in Move.allCases {
            let panel = ModelEntity(mesh: panelMesh, materials: [Self.material(Self.cueArt(for: move), fallback: Self.color(0x1C1944))])
            panel.name = "laserFeedback.cue.\(move.rawValue)"
            cuePanels[move] = panel
        }
        // Shrinks to nothing at the crossing, when the beam reaches the players.
        let countdown = ModelEntity(mesh: .generatePlane(width: panelSize.x * 0.84, height: 0.022),
                                    materials: [Self.material(nil, fallback: Self.color(0xFFE3B3))])
        countdown.name = "laserFeedback.cue.countdown"
        countdown.position = [0, -panelSize.y / 2 - 0.045, 0.002]

        let badgeMesh = MeshResource.generatePlane(width: 0.2, height: 0.2)
        var badges: [PlayerID: Entity] = [:]
        var badgeFaces: [PlayerID: [Outcome: Entity]] = [:]
        let badgeMaterials = Outcome.allCases.map { Self.material(Self.badgeArt(for: $0), fallback: Self.badgeColor($0)) }
        for player in PlayerID.allCases {
            let badge = Entity()
            badge.name = "laserFeedback.badge.\(player.rawValue)"
            badge.isEnabled = false
            var faces: [Outcome: Entity] = [:]
            for (outcome, material) in zip(Outcome.allCases, badgeMaterials) {
                let face = ModelEntity(mesh: badgeMesh, materials: [material])
                face.name = "\(badge.name).\(outcome.rawValue)"
                badge.addChild(face)
                faces[outcome] = face
            }
            badges[player] = badge
            badgeFaces[player] = faces
        }
        self.cuePanels = cuePanels
        self.countdown = countdown
        self.badges = badges
        self.badgeFaces = badgeFaces

        root.name = "laserFeedback"
        cue.name = "laserFeedback.cue"
        cue.isEnabled = false
        for panel in cuePanels.values {
            cue.addChild(panel)
        }
        cue.addChild(countdown)
        root.addChild(cue)
        for badge in badges.values {
            root.addChild(badge)
        }
    }

    /// Where the move cue sits in the world; it faces the fixed camera.
    func setCuePosition(_ position: SIMD3<Float>) {
        cue.position = position
    }

    /// Uses the gate artwork's hit spark for impacts; without it, a HIT shows only its badge.
    func setImpactArt(_ makeSpark: () -> Entity) {
        for impact in impacts.values {
            impact.removeFromParent()
        }
        for player in PlayerID.allCases {
            let spark = makeSpark()
            spark.name = "laserFeedback.impact.\(player.rawValue)"
            root.addChild(spark)
            impacts[player] = spark
        }
    }

    /// Shows the move cue in two phases. During the hazard warning
    /// (`actionRemaining == nil`) it is a smaller, muted preview of the coming
    /// move. From the action cue it is full size with a countdown:
    /// `actionRemaining` is the share of the cue lead still to go, 1 at the
    /// action cue and 0 when the beam reaches the players. `nil` hides the cue.
    /// The cue on screen, if any, and whether it is the action cue.
    var shownMoveCue: (move: Move, acting: Bool)? { shownCue }

    func setMoveCue(_ move: Move?, actionRemaining: Float? = nil) {
        approvedCue = (move, actionRemaining)
        if timingVariant != .approved { return } // one chosen renderer owns cue visibility
        guard let move else {
            if shownCue != nil { hideCue() }
            return
        }
        let acting = actionRemaining != nil
        if shownCue?.move != move || shownCue?.acting != acting {
            showCue(move, acting: acting)
        }
        if let actionRemaining {
            countdown.scale.x = min(max(actionRemaining, 0.001), 1)
        }
    }

    /// Shows one player's finalized verdict above their head and, for a HIT, a
    /// short spark where their lane meets the beam. The badge clears itself after
    /// about a second; neither effect changes the judged band.
    func showOutcome(_ outcome: Outcome, for player: PlayerID, badgeAt badgePosition: SIMD3<Float>, impactAt impactPosition: SIMD3<Float>) {
        guard let badge = badges[player], let faces = badgeFaces[player] else { return }
        badge.stopAllAnimations()
        badge.transform = Transform(translation: badgePosition)
        badge.isEnabled = true
        for (face, entity) in faces {
            entity.isEnabled = face == outcome
        }
        switch outcome {
        case .clear:
            // Positive: a springy pop, then fade.
            fade(badge, in: 0.12, hold: 0.85, out: 0.3)
            pop(badge, from: 0.4, rise: 0.05, duration: 0.3, timing: Self.overshoot)
        case .hit:
            // Firm: a quick pop and a small shake, no overshoot.
            fade(badge, in: 0.08, hold: 0.9, out: 0.3)
            pop(badge, from: 0.5, rise: 0, duration: 0.14, timing: .easeOut, then: Self.shake(badge.transform))
            if let impact = impacts[player] {
                impact.stopAllAnimations()
                impact.transform = Transform(scale: .init(repeating: 0.6), translation: impactPosition)
                impact.isEnabled = true
                fade(impact, in: 0.04, hold: 0.12, out: 0.22)
                pop(impact, from: 0.25, rise: 0, duration: 0.12, timing: .easeOut)
            }
        case .unavailable:
            // Neutral: a calm fade only, no pop, shake or spark.
            fade(badge, in: 0.25, hold: 0.75, out: 0.35)
        }
    }

    /// Clears the cue, badges and impacts, e.g. when a new encounter starts.
    func clear() {
        timingModel = nil
        if timingVariant != .approved {
            timingRenderer.apply(nil, variant: timingVariant, reduceMotion: Self.reduceMotion)
            if shownCue != nil { hideCue() }
        }
        setMoveCue(nil)
        for entity in Array(badges.values) + Array(impacts.values) {
            entity.stopAllAnimations()
            entity.isEnabled = false
        }
    }

    // MARK: - Animation

    private static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }
    /// Gentle overshoot for playful entrances.
    private static let overshoot = AnimationTimingFunction.cubicBezier(controlPoint1: [0.175, 0.885], controlPoint2: [0.32, 1.275])

    /// Size and opacity of the cue while it previews the coming move.
    private static let previewScale: Float = 0.8
    private static let previewOpacity: Float = 0.6

    /// Fades the preview in, or pops it up to the full action cue.
    private func showCue(_ move: Move, acting: Bool) {
        let wasPreviewing = shownCue?.move == move
        shownCue = (move, acting)
        for (panelMove, panel) in cuePanels {
            panel.isEnabled = panelMove == move
        }
        countdown.isEnabled = acting
        let scale = acting ? 1 : Self.previewScale
        let opacity = acting ? 1 : Self.previewOpacity
        cue.stopAllAnimations()
        cue.scale = .init(repeating: scale)
        cue.isEnabled = true
        cue.components.set(OpacityComponent(opacity: opacity))
        let fromOpacity = wasPreviewing ? Self.previewOpacity : 0
        play(FromToByAnimation<Float>(from: fromOpacity, to: opacity, duration: 0.16, timing: .easeOut, bindTarget: .opacity), on: cue)
        let fromScale = wasPreviewing ? Self.previewScale : 0.6 * scale
        pop(cue, from: fromScale / scale, rise: 0, duration: acting ? 0.26 : 0.3, timing: acting ? Self.overshoot : .easeOut)
    }

    private func hideCue() {
        let opacity = shownCue?.acting == true ? 1 : Self.previewOpacity
        shownCue = nil
        cue.stopAllAnimations()
        cue.components.set(OpacityComponent(opacity: 0))
        play(FromToByAnimation<Float>(from: opacity, to: 0, duration: 0.16, timing: .easeIn, bindTarget: .opacity), on: cue)
    }

    /// Fades in, holds and fades out, leaving the entity invisible.
    private func fade(_ entity: Entity, in fadeIn: TimeInterval, hold: TimeInterval, out fadeOut: TimeInterval) {
        entity.components.set(OpacityComponent(opacity: 0))
        let steps = [
            FromToByAnimation<Float>(from: 0, to: 1, duration: fadeIn, timing: .easeOut, bindTarget: .opacity),
            FromToByAnimation<Float>(from: 1, to: 1, duration: hold, bindTarget: .opacity),
            FromToByAnimation<Float>(from: 1, to: 0, duration: fadeOut, timing: .easeIn, bindTarget: .opacity),
        ]
        if let sequence = try? AnimationResource.sequence(with: steps.compactMap { try? AnimationResource.generate(with: $0) }) {
            entity.playAnimation(sequence, handoffType: .compose)
        }
    }

    /// Scales up from `from` (and rises by `rise`) to the entity's current
    /// transform, optionally followed by another transform animation. Skipped
    /// with Reduce Motion.
    private func pop(_ entity: Entity, from scale: Float, rise: Float, duration: TimeInterval, timing: AnimationTimingFunction, then next: AnimationResource? = nil) {
        guard !Self.reduceMotion else { return }
        let rest = entity.transform
        var from = rest
        from.scale *= scale
        from.translation.y -= rise
        guard let pop = try? AnimationResource.generate(with: FromToByAnimation(from: from, to: rest, duration: duration, timing: timing, bindTarget: .transform))
        else { return }
        let resource = next.flatMap { try? AnimationResource.sequence(with: [pop, $0]) } ?? pop
        entity.playAnimation(resource, handoffType: .compose)
    }

    private func play(_ animation: FromToByAnimation<Float>, on entity: Entity) {
        if let resource = try? AnimationResource.generate(with: animation) {
            entity.playAnimation(resource, handoffType: .compose)
        }
    }

    /// Two quick sideways oscillations (0.3 s) that end at rest.
    private static func shake(_ rest: Transform) -> AnimationResource? {
        let frames = [0.03, -0.03, 0.02, -0.012, 0.005, 0].map { (offset: Float) in
            var frame = rest
            frame.translation.x += offset
            return frame
        }
        return try? AnimationResource.generate(with: SampledAnimation(frames: frames, frameInterval: 0.05, bindTarget: .transform))
    }

    // MARK: - Temporary art

    /// The move as Theo's Sketch cue ("Hi-Fi Revisi 30 OCT", Game 1): an arrow
    /// and "DUCK!"/"JUMP!" in white SF Pro Rounded Black with a hard dark drop
    /// shadow and a soft halo, no panel, so it reads over the corridor at a
    /// distance. The arrow and word carry the move, never colour alone.
    private static func cueArt(for move: Move) -> CGImage? {
        let size = CGSize(width: 720, height: 224)
        return render(size) { context in
            let cg = context.cgContext
            // Sketch: 52.7 pt text, shadows (3, 5) 0 blur at 91 % black and (0, 4) 8 blur at 25 %.
            let scale: CGFloat = 2.6
            let symbol = UIImage(systemName: move == .duck ? "arrow.down" : "arrow.up",
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 52.7 * scale * 0.86, weight: .black))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            let label = NSAttributedString(string: move == .duck ? "DUCK!" : "JUMP!", attributes: [
                .font: roundedFont(size: 52.7 * scale, weight: .black),
                .foregroundColor: UIColor.white,
            ])
            let symbolSize = symbol?.size ?? .zero
            let labelSize = label.size()
            let gap: CGFloat = 4 * scale
            let total = symbolSize.width + gap + labelSize.width
            let x = (size.width - total) / 2
            let symbolRect = CGRect(x: x, y: (size.height - symbolSize.height) / 2, width: symbolSize.width, height: symbolSize.height)
            let labelOrigin = CGPoint(x: x + symbolSize.width + gap, y: (size.height - labelSize.height) / 2)
            let draw = {
                symbol?.draw(in: symbolRect)
                label.draw(at: labelOrigin)
            }
            // Halo, then the soft and hard shadows, then the white face.
            cg.saveGState()
            cg.setShadow(offset: .zero, blur: 18 * scale, color: UIColor.black.withAlphaComponent(0.55).cgColor)
            draw()
            cg.restoreGState()
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 4 * scale), blur: 8 * scale, color: UIColor.black.withAlphaComponent(0.25).cgColor)
            draw()
            cg.restoreGState()
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 3 * scale, height: 5 * scale), blur: 0, color: UIColor.black.withAlphaComponent(0.91).cgColor)
            draw()
            cg.restoreGState()
            draw()
        }
    }

    /// Round badge whose symbol differs per outcome, so colour is never the only signal.
    private static func badgeArt(for outcome: Outcome) -> CGImage? {
        let size = CGSize(width: 256, height: 256)
        let symbolName = switch outcome {
        case .clear: "checkmark"
        case .hit: "xmark"
        case .unavailable: "eye.slash"
        }
        return render(size) { _ in
            let circle = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8))
            badgeColor(outcome).setFill()
            circle.fill()
            UIColor.white.setStroke()
            circle.lineWidth = 10
            circle.stroke()
            let symbol = UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 104, weight: .heavy))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            if let symbol {
                symbol.draw(at: CGPoint(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2))
            }
        }
    }

    private static func badgeColor(_ outcome: Outcome) -> UIColor {
        switch outcome {
        case .clear: color(0x2FB58A)
        case .hit: color(0xE5484D)
        case .unavailable: color(0x6E6A9E)
        }
    }

    private static func render(_ size: CGSize, draw: (UIGraphicsImageRendererContext) -> Void) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image(actions: draw).cgImage
    }

    /// Unlit, not tone-mapped and alpha-blended, so soft edges stay soft.
    private static func material(_ image: CGImage?, fallback: UIColor) -> UnlitMaterial {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: fallback)
        if let image, let texture = try? TextureResource(image: image, options: .init(semantic: .color)) {
            material.color = .init(tint: .white, texture: .init(texture))
            material.blending = .transparent(opacity: 1.0)
        }
        return material
    }

    private static func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = font.fontDescriptor.withDesign(.rounded) else { return font }
        return UIFont(descriptor: descriptor, size: size)
    }

    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
