import Foundation
import RealityKit
import UIKit

/// Presentation only. Circular cue is selected; horizontal variants are comparison/fallback renderers.
nonisolated enum TimingIndicatorVariant: String, CaseIterable, Sendable {
    case approved, circular, closing
    #if DEBUG
    case fill, sweep
    #endif
    var title: String {
        switch self {
        case .approved: "Legacy fallback"
        case .circular: "Circular cue"
        case .closing: "Closing Gate (comparison)"
        #if DEBUG
        case .fill: "A · Fill"
        case .sweep: "B · Sweep"
        #endif
        }
    }
    var isFill: Bool {
        #if DEBUG
        self == .fill
        #else
        false
        #endif
    }
}

nonisolated struct LaserTimingPresentation: Equatable, Sendable {
    enum Phase: String, Sendable { case approach, prepare, crossing, passed, result, paused }
    let generation: UUID
    let encounterID: UUID
    let attemptID: UUID
    let move: LaserMove
    let gameTime: Double
    let warningTime: Double
    let cueTime: Double
    let crossingTime: Double
    /// Capture eligibility, NOT a perfect-movement window. Not painted as green.
    let evidenceWindow: ClosedRange<Double>
    let progress: Double
    let remaining: Double
    let phase: Phase
    let verdicts: [PlayerID: Judgement]
    let successCommitted: Bool
    var label: String {
        switch phase {
        case .approach: "APPROACH"
        case .prepare: "PREPARE · CROSSING AT TICK"
        case .crossing: "CROSSING"
        case .passed: "PASSED · AWAITING RESULT"
        case .paused: "PAUSED"
        case .result:
            PlayerID.allCases.compactMap { id in
                guard let j = verdicts[id] else { return nil }
                let value: String
                switch j { case .clear: value = "CLEAR"; case .hit: value = "HIT"; case .unavailable: value = "UNAVAILABLE"; case .pending: value = "PENDING" }
                return "\(id == .player1 ? "P1" : "P2") \(value)"
            }.joined(separator: " · ")
        }
    }
    var allClear: Bool { !verdicts.isEmpty && verdicts.values.allSatisfy { $0 == .clear } }
    var anyHit: Bool { verdicts.values.contains { if case .hit = $0 { true } else { false } } }

    static func make(state: LaserGameState, configuration: LaserRoundConfiguration,
                     withdrawn: Set<UUID> = [], paused: Bool = false) -> Self? {
        guard state.phase == .activity, state.gameTime.isFinite else { return nil }
        let time = state.gameTime
        let choices = state.encounters.filter { !withdrawn.contains($0.encounter.attemptID) }.flatMap { encounter in
            encounter.encounter.targets.map { (encounter, $0) }
        }.filter { _, target in time >= target.warningTime && time <= target.crossingTime + max(1, configuration.evidenceTiming.windowAfter + configuration.evidenceTiming.deliveryAllowance) }
        // Same earliest unresolved approach as the approved cue; only if none, show a
        // short source-time-driven crossing/result tail. No timer or event fabrication.
        let active = choices.filter { e, t in time < t.crossingTime && e.judgements[t.playerID]?.timingIsPending != false }
            .min { $0.1.crossingTime < $1.1.crossingTime }
        let previous = choices.filter { time >= $0.1.crossingTime }.max { $0.1.crossingTime < $1.1.crossingTime }
        guard let (encounter, target) = active ?? previous else { return nil }
        let cue = min(max(configuration.scheduling?.actionCueTime(for: target)
            ?? configuration.actionCueLead.map { target.crossingTime - $0 } ?? target.crossingTime,
            target.warningTime), target.crossingTime)
        let results = encounter.judgements
        let resolved = !results.isEmpty && results.values.allSatisfy { !$0.timingIsPending }
        let phase: Phase = paused ? .paused : time < cue ? .approach : time < target.crossingTime ? .prepare
            : resolved ? .result : time < target.crossingTime + 0.12 ? .crossing : .passed
        return .init(generation: state.sessionGeneration, encounterID: encounter.encounter.id,
            attemptID: encounter.encounter.attemptID, move: target.requiredMove, gameTime: time,
            warningTime: target.warningTime, cueTime: cue, crossingTime: target.crossingTime,
            evidenceWindow: configuration.evidenceTiming.captureWindow(crossing: target.crossingTime),
            progress: min(1, max(0, (time - target.warningTime) / (target.crossingTime - target.warningTime))),
            remaining: max(0, target.crossingTime - time), phase: phase, verdicts: results,
            successCommitted: encounter.effectsCommitted && encounter.encounter.targets.allSatisfy { results[$0.playerID] == .clear })
    }

    /// Reduced Motion keeps a static phase diagram instead of sweeping/closing motion.
    func displayedProgress(reduceMotion: Bool) -> Double {
        guard reduceMotion else { return progress }
        switch phase { case .approach: return 0; case .prepare: return 0.5; case .paused: return 0; default: return 1 }
    }
}

private extension Judgement {
    var timingIsPending: Bool { if case .pending = self { true } else { false } }
}

/// One reusable native subtree. Source-time transforms only; no timer or subscriptions.
@MainActor final class TimingIndicatorRenderer {
    let root = Entity()
    private let horizontal = Entity()
    private let circular = CircularTimingCueRenderer()
    #if DEBUG
    private let fill: ModelEntity
    private let target: ModelEntity
    #endif
    private let left: ModelEntity
    private let right: ModelEntity
    private let circle: ModelEntity
    private let dot: ModelEntity
    private let innerRing: ModelEntity
    private let halo: ModelEntity
    private let captions = Entity()
    private var captionFaces: [String: ModelEntity] = [:]
    private var shownLabel: String?
    private let palette: [[UnlitMaterial]]
    private let circlePalette: [[UnlitMaterial]]
    private let innerCirclePalette: [[UnlitMaterial]]
    private let closingMarkerPalette: [[UnlitMaterial]]
    private var lastTint: Int?
    private var lastCircleTint: Int?
    private(set) var model: LaserTimingPresentation?
    private(set) var variant: TimingIndicatorVariant = .circular
    static let width: Float = 1.03
    static let circleDiameter: Float = 0.17
    static let haloDiameter: Float = 0.22
    static let markerWidth: Float = 0.035
    static let crossingEmphasis = 0.12

    init() {
        func color(_ n: UInt32) -> UIColor { UIColor(red: CGFloat((n >> 16) & 255)/255, green: CGFloat((n >> 8)&255)/255, blue: CGFloat(n&255)/255, alpha: 1) }
        palette = [0x7565FF, 0xFFD447, 0x7BEFFF, 0x37D9A1, 0xF67585, 0x8C8BA9].map { [UnlitMaterial(color: color($0))] }
        // Green identifies the crossing destination; only verdicts produce result feedback.
        circlePalette = [0x45F578, 0x72FF99, 0xB0FFD0, 0x27DF72, 0xF67585, 0x8C8BA9].map { [UnlitMaterial(color: color($0))] }
        innerCirclePalette = [0xA1FFBA, 0xC0FFD0, 0xE7FFF0, 0xC5FFDC, 0xFFD0D8, 0xC4C3D5].map { [UnlitMaterial(color: color($0))] }
        closingMarkerPalette = [0xE7FFE9, 0xFFFFFF].map { [UnlitMaterial(color: color($0))] }
        let dark = UnlitMaterial(color: color(0x19152F))
        func plane(_ name: String, _ width: Float, _ height: Float, _ materials: [UnlitMaterial]) -> ModelEntity {
            let e = ModelEntity(mesh: .generatePlane(width: width, height: height, cornerRadius: min(width, height)/2), materials: materials)
            e.name = name; return e
        }
        root.addChild(horizontal); root.addChild(circular.root)
        let track = plane("timing.track", Self.width + 0.04, 0.12, [dark]); horizontal.addChild(track)
        let outline = plane("timing.outline", Self.width + 0.06, 0.14, [UnlitMaterial(color: color(0xC8BEF4))])
        outline.position.z = -0.001; horizontal.addChild(outline)
        #if DEBUG
        fill = plane("timing.fill", Self.width, 0.08, palette[0]); fill.position.z = 0.003
        target = plane("timing.crossing.target", 0.018, 0.12, palette[2]); target.position.z = 0.004
        horizontal.addChild(fill); horizontal.addChild(target)
        #endif
        left = plane("timing.marker.left", Self.markerWidth, 0.13, palette[2]); left.position.z = 0.005
        right = plane("timing.marker.right", Self.markerWidth, 0.13, palette[2]); right.position.z = 0.005
        horizontal.addChild(left); horizontal.addChild(right)
        // Native rounded planes form a thick ring, dark core and dot. No texture/shader
        // generation for the target. Closing markers render above every ring/core layer.
        circle = plane("timing.circle", Self.circleDiameter, Self.circleDiameter, circlePalette[0])
        circle.position.z = 0.008
        innerRing = plane("timing.circle.innerRing", 0.12, 0.12, innerCirclePalette[0]); innerRing.position.z = 0.001
        circle.addChild(innerRing)
        let core = plane("timing.circle.core", 0.10, 0.10, [dark]); core.position.z = 0.002
        circle.addChild(core)
        dot = plane("timing.circle.dot", 0.024, 0.024, innerCirclePalette[0]); dot.position.z = 0.003
        circle.addChild(dot); horizontal.addChild(circle)
        halo = plane("timing.circle.halo", Self.haloDiameter, Self.haloDiameter, circlePalette[2])
        halo.position.z = 0.006
        let haloCore = plane("timing.circle.halo.core", 0.198, 0.198, [dark]); haloCore.position.z = 0.001
        halo.addChild(haloCore); horizontal.addChild(halo)
        halo.isEnabled = false
        captions.position = [0, -0.165, 0.010]; horizontal.addChild(captions)
        root.name = "timing.closingGate"; root.isEnabled = false
    }

    func apply(_ value: LaserTimingPresentation?, variant: TimingIndicatorVariant, reduceMotion: Bool) {
        self.model = value; self.variant = variant
        root.isEnabled = variant != .approved && value != nil
        horizontal.isEnabled = variant != .circular
        circular.apply(variant == .circular ? value : nil, reduceMotion: reduceMotion)
        guard let value, root.isEnabled, variant != .circular else { return }
        let p = Float(value.displayedProgress(reduceMotion: reduceMotion)), w = Self.width
        let tint = value.phase == .result ? (value.anyHit ? 4 : value.allClear ? 3 : 5)
            : value.phase == .paused || value.phase == .passed ? 5 : value.phase == .approach ? 0 : value.phase == .prepare ? 1 : 2
        let markerStyle = variant == .closing ? 100 + (value.phase == .crossing ? 1 : 0) : tint
        if lastTint != markerStyle {
            lastTint = markerStyle
            let materials = variant == .closing ? closingMarkerPalette[value.phase == .crossing ? 1 : 0] : palette[tint]
            left.model?.materials = materials; right.model?.materials = materials
            #if DEBUG
            fill.model?.materials = palette[tint]
            #endif
        }
        let elapsed = value.gameTime - value.crossingTime
        let resolved = value.phase == .result
        left.isEnabled = !reduceMotion && !variant.isFill && !(variant == .closing && resolved)
        right.isEnabled = !reduceMotion && variant == .closing && !resolved
        // Same constant speed on both sides of crossing. Progress reaches exactly zero
        // offset at crossing, then continues through for the existing bounded 120ms.
        let approachOffset = -w/2 * (1-p)
        let followOffset = Float(min(Self.crossingEmphasis, max(0, elapsed))
            / (value.crossingTime-value.warningTime)) * w/2
        left.position.x = variant == .closing ? (elapsed < 0 ? approachOffset : followOffset) : -w/2 + w*p
        right.position.x = -left.position.x
        left.position.z = variant == .closing ? 0.016 : 0.005
        right.position.z = left.position.z
        // Fade modestly while passing through; keep +120ms visible until the committed
        // result resolves the markers. No position snap or independently running animation.
        let followShare = Float(min(1, max(0, elapsed/Self.crossingEmphasis)))
        let markerOpacity: Float = variant == .closing ? 1 - 0.55*followShare : 1
        left.components.set(OpacityComponent(opacity: markerOpacity))
        right.components.set(OpacityComponent(opacity: markerOpacity))
        #if DEBUG
        fill.isEnabled = variant.isFill || (reduceMotion && variant != .closing)
        fill.scale.x = max(0.001, p); fill.position.x = -w/2 + w*p/2
        target.isEnabled = variant != .closing
        target.position.x = w/2
        #endif
        circle.isEnabled = variant == .closing
        let circleTint = value.phase == .result ? (value.anyHit ? 4 : value.allClear ? 3 : 5)
            : value.phase == .paused || value.phase == .passed ? 5 : value.phase == .approach ? 0 : value.phase == .prepare ? 1 : 2
        if lastCircleTint != circleTint {
            lastCircleTint = circleTint
            circle.model?.materials = circlePalette[circleTint]
            innerRing.model?.materials = innerCirclePalette[circleTint]; dot.model?.materials = innerCirclePalette[circleTint]
        }
        // A 120ms cosmetic emphasis derived solely from the original crossing timestamp.
        // At crossing the green ring lights immediately, with a scale peak at +60ms.
        // Target green is never a player-success judgement.
        let crossing = value.phase == .crossing && !reduceMotion
        let t = min(1, max(0, (value.gameTime-value.crossingTime)/Self.crossingEmphasis))
        let pulse = crossing ? Float(sin(t * .pi)) : 0
        circle.scale = .init(repeating: 1 + 0.10*pulse)
        halo.isEnabled = variant == .closing && crossing
        halo.scale = .init(repeating: 1 + 0.10*pulse)
        captions.position.y = variant == .closing ? -0.165 : -0.105
        let baseLabel = variant == .closing ? value.label.replacingOccurrences(of: "AT TICK", with: "AT CIRCLE") : value.label
        let label = reduceMotion ? "\(baseLabel) · REDUCED MOTION" : baseLabel
        let cacheKey = "\(variant == .closing ? "circle" : "line"):\(label)"
        guard shownLabel != cacheKey else { return }
        shownLabel = cacheKey
        for face in captionFaces.values { face.isEnabled = false }
        let face: ModelEntity
        if let cached = captionFaces[cacheKey] { face = cached }
        else {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 60)).image { _ in
                if variant == .closing {
                    let textWidth = (label as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 27, weight: .heavy)]).width
                    UIColor(red: 0.10, green: 0.08, blue: 0.20, alpha: 0.94).setFill()
                    UIBezierPath(roundedRect: CGRect(x: (800-textWidth)/2-12, y: 0,
                        width: textWidth+24, height: 38), cornerRadius: 12).fill()
                }
                let style = NSMutableParagraphStyle(); style.alignment = .center
                (label as NSString).draw(in: CGRect(x: 0, y: 0, width: 800, height: 60), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 27, weight: .heavy), .foregroundColor: UIColor.white, .paragraphStyle: style])
            }
            var mat = UnlitMaterial(color: .white)
            if let cg = image.cgImage, let texture = try? TextureResource.generate(from: cg, options: .init(semantic: .color)) {
                mat.color = .init(tint: .white, texture: .init(texture)); mat.blending = .transparent(opacity: 1.0)
            }
            face = ModelEntity(mesh: .generatePlane(width: 1.25, height: 0.094), materials: [mat])
            captions.addChild(face); captionFaces[cacheKey] = face
        }
        face.isEnabled = true
    }
}

/// Presentation only: a clean arrow badge, continuous progress arc and separate
/// Sketch-style action word. Cached geometry/art; original encounter time only.
@MainActor final class CircularTimingCueRenderer {
    let root = Entity()
    static let diameter: Float = 0.36
    static let progressSteps = 120
    private let faces: [String: Entity]
    private let progress: ModelEntity
    private let meshes: [MeshResource]
    private let pulse: ModelEntity
    private let activeMaterial = UnlitMaterial(color: UIColor(red: 0.43, green: 0.84, blue: 1, alpha: 1))
    private let successMaterial = UnlitMaterial(color: UIColor(red: 0.35, green: 1, blue: 0.63, alpha: 1))
    private let hitMaterial = UnlitMaterial(color: UIColor(red: 1, green: 0.39, blue: 0.52, alpha: 1))
    private let neutralMaterial = UnlitMaterial(color: .lightGray)
    private var ringStyle: String?
    private var meshIndex: Int?
    private(set) var displayedState = "hidden"
    private(set) var renderedProgress: Double = 0
    var progressMeshCount: Int { meshes.count }

    init() {
        root.name = "timing.circularCue"
        let dark = UnlitMaterial(color: UIColor(red: 0.085, green: 0.065, blue: 0.19, alpha: 1))
        let track = ModelEntity(mesh: .generatePlane(width: Self.diameter, height: Self.diameter, cornerRadius: Self.diameter/2),
            materials: [UnlitMaterial(color: UIColor(red: 0.37, green: 0.34, blue: 0.49, alpha: 1))])
        track.position.z = -0.001; root.addChild(track)
        let background = ModelEntity(mesh: .generatePlane(width: 0.321, height: 0.321, cornerRadius: 0.1605), materials: [dark])
        background.name = "timing.circular.background"; root.addChild(background)
        // One connected annular sector per cached progress step: no separate bars,
        // gaps, texture regeneration or mesh creation during gameplay updates.
        meshes = (1...Self.progressSteps).compactMap { i in
            let vertices = Self.arcVertices(progress: Double(i)/Double(Self.progressSteps))
            var descriptor = MeshDescriptor(name: "timing.arc.\(i)")
            descriptor.positions = MeshBuffers.Positions(vertices)
            descriptor.normals = MeshBuffers.Normals(Array(repeating: SIMD3<Float>(0,0,1), count: vertices.count))
            var indices: [UInt32] = []
            for j in 0..<(vertices.count/2-1) {
                let n = UInt32(j*2)
                indices += [n,n+1,n+2,n+2,n+1,n+3]
            }
            descriptor.primitives = .triangles(indices)
            return try? MeshResource.generate(from: [descriptor])
        }
        progress = ModelEntity(mesh: meshes.last ?? .generatePlane(width: 0.001, height: 0.001), materials: [activeMaterial])
        progress.name = "timing.circular.progress"; progress.position.z = 0.003; root.addChild(progress)
        pulse = ModelEntity(mesh: .generatePlane(width: 0.374, height: 0.374, cornerRadius: 0.187), materials: [activeMaterial])
        pulse.name = "timing.circular.crossingPulse"; pulse.position.z = -0.002
        root.addChild(pulse); pulse.isEnabled = false
        var cached: [String: Entity] = [:]
        for key in ["duck", "jump", "perfect", "hit", "unavailable", "pending", "paused"] {
            let group = Entity(); group.name = "timing.circular.\(key)"
            let icon = ModelEntity(mesh: .generatePlane(width: 0.285, height: 0.285), materials: [Self.material(Self.icon(key))])
            icon.name = "timing.circular.icon.\(key)"; icon.position.z = 0.005; group.addChild(icon)
            let label = ModelEntity(mesh: .generatePlane(width: 0.66, height: 0.2053), materials: [Self.material(Self.label(key))])
            label.name = "timing.circular.label.\(key)"; label.position = [0,-0.245,0.006]; group.addChild(label)
            root.addChild(group); cached[key] = group
        }
        faces = cached; root.isEnabled = false
    }

    static func arcVertices(progress: Double) -> [SIMD3<Float>] {
        let fraction = min(1, max(0, progress)), count = max(1, Int(ceil(fraction*96)))
        return (0...count).flatMap { i -> [SIMD3<Float>] in
            let angle = Float(Double(i)/Double(count)*fraction*2 * .pi)
            return [SIMD3(sin(angle)*0.18, cos(angle)*0.18, 0),
                    SIMD3(sin(angle)*0.161, cos(angle)*0.161, 0)]
        }
    }

    static func state(for value: LaserTimingPresentation) -> String {
        if value.phase == .result { return value.anyHit ? "hit" : value.successCommitted ? "perfect" : "unavailable" }
        if value.phase == .paused { return "paused" }
        if value.phase == .passed { return "pending" }
        return value.move == .duck ? "duck" : "jump"
    }

    func apply(_ value: LaserTimingPresentation?, reduceMotion: Bool) {
        root.isEnabled = value != nil
        guard let value else { displayedState = "hidden"; pulse.isEnabled = false; return }
        displayedState = Self.state(for: value)
        for (key, face) in faces { face.isEnabled = key == displayedState }
        let index = reduceMotion ? Self.progressSteps : Int((value.progress * Double(Self.progressSteps)).rounded(.down))
        renderedProgress = Double(index)/Double(Self.progressSteps)
        progress.isEnabled = index > 0 && meshes.count == Self.progressSteps
        if meshIndex != index, progress.isEnabled {
            meshIndex = index; progress.model?.mesh = meshes[index-1]
        }
        let style = value.phase == .result ? displayedState : value.phase == .passed || value.phase == .paused ? "neutral" : "active"
        if ringStyle != style {
            ringStyle = style
            progress.model?.materials = [style == "perfect" ? successMaterial : style == "hit" ? hitMaterial : style == "active" ? activeMaterial : neutralMaterial]
        }
        let elapsed = value.gameTime - value.crossingTime
        pulse.isEnabled = !reduceMotion && value.phase == .crossing && elapsed >= 0 && elapsed < 0.12
        pulse.scale = .init(repeating: 1 + Float(sin(min(1, max(0, elapsed/0.12)) * .pi))*0.035)
    }

    static func actionLabel(for key: String) -> String {
        key == "duck" ? "DUCK" : key == "jump" ? "JUMP" : key == "perfect" ? "PERFECT!" : key == "hit" ? "HIT" : key == "paused" ? "PAUSED" : key == "pending" ? "WAIT" : "NO DATA"
    }
    private static func tint(_ key: String) -> UIColor {
        key == "perfect" ? UIColor(red: 0.45, green: 1, blue: 0.69, alpha: 1)
            : key == "hit" ? UIColor(red: 1, green: 0.48, blue: 0.61, alpha: 1) : .white
    }
    private static func icon(_ key: String) -> CGImage? {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 384, height: 384), format: format).image { _ in
            let name = key == "duck" ? "arrow.down" : key == "jump" ? "arrow.up" : key == "perfect" ? "checkmark" : key == "hit" ? "xmark" : key == "unavailable" ? "eye.slash" : key == "pending" ? "ellipsis" : "pause.fill"
            let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 215, weight: .black))?.withTintColor(tint(key), renderingMode: .alwaysOriginal)
            if let image { image.draw(at: CGPoint(x: (384-image.size.width)/2, y: (384-image.size.height)/2)) }
        }.cgImage
    }
    /// The previous in-game cue's rounded Black face, hard drop shadow and soft halo,
    /// now below the badge. Same visual language; no exclamation on action words.
    private static func label(_ key: String) -> CGImage? {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 720, height: 224), format: format).image { context in
            let font = UIFont.systemFont(ofSize: key == "perfect" || key == "unavailable" ? 115 : 137, weight: .black)
            let rounded = font.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
            let text = NSAttributedString(string: actionLabel(for: key), attributes: [.font: rounded, .foregroundColor: tint(key)])
            let size = text.size(), origin = CGPoint(x: (720-size.width)/2, y: (224-size.height)/2)
            let cg = context.cgContext
            cg.saveGState(); cg.setShadow(offset: .zero, blur: 12, color: UIColor.black.withAlphaComponent(0.65).cgColor); text.draw(at: origin); cg.restoreGState()
            cg.saveGState(); cg.setShadow(offset: CGSize(width: 5,height: 8), blur: 0, color: UIColor.black.withAlphaComponent(0.91).cgColor); text.draw(at: origin); cg.restoreGState()
            text.draw(at: origin)
        }.cgImage
    }
    private static func material(_ image: CGImage?) -> UnlitMaterial {
        var result = UnlitMaterial(applyPostProcessToneMap: false)
        if let image, let texture = try? TextureResource(image: image, options: .init(semantic: .color)) {
            result.color = .init(tint: .white, texture: .init(texture)); result.blending = .transparent(opacity: 1.0)
        }
        return result
    }
}
