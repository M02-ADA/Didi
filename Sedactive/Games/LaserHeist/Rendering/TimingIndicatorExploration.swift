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

/// Internal presentation: a bounded ring sweep, never an action-success window.
/// All artwork and ring segments are built once; updates only toggle cached faces.
@MainActor final class CircularTimingCueRenderer {
    let root = Entity()
    static let diameter: Float = 0.52
    static let segmentCount = 72
    private let faces: [String: ModelEntity]
    private let segments: [ModelEntity]
    private let pulse: ModelEntity
    private let activeMaterial = UnlitMaterial(color: UIColor(red: 0.43, green: 0.84, blue: 1, alpha: 1))
    private let successMaterial = UnlitMaterial(color: UIColor(red: 0.35, green: 1, blue: 0.63, alpha: 1))
    private let hitMaterial = UnlitMaterial(color: UIColor(red: 1, green: 0.39, blue: 0.52, alpha: 1))
    private let neutralMaterial = UnlitMaterial(color: .lightGray)
    private var ringStyle: String?
    private(set) var displayedState = "hidden"
    private(set) var litSegmentCount = 0

    init() {
        root.name = "timing.circularCue"
        let background = ModelEntity(mesh: .generatePlane(width: 0.50, height: 0.50, cornerRadius: 0.25),
            materials: [UnlitMaterial(color: UIColor(red: 0.085, green: 0.065, blue: 0.19, alpha: 1))])
        background.name = "timing.circular.background"; root.addChild(background)
        let track = ModelEntity(mesh: .generatePlane(width: Self.diameter, height: Self.diameter, cornerRadius: Self.diameter/2),
            materials: [UnlitMaterial(color: UIColor(red: 0.32, green: 0.25, blue: 0.53, alpha: 1))])
        track.position.z = -0.001; root.addChild(track)
        var pieces: [ModelEntity] = []
        let mesh = MeshResource.generatePlane(width: 0.018, height: 0.013, cornerRadius: 0.006)
        for i in 0..<Self.segmentCount {
            let angle = Float(i) / Float(Self.segmentCount) * 2 * .pi
            let e = ModelEntity(mesh: mesh, materials: [activeMaterial])
            e.name = "timing.radial.\(i)"
            e.position = [sin(angle)*0.25, cos(angle)*0.25, 0.003]
            e.orientation = simd_quatf(angle: -angle, axis: [0, 0, 1])
            root.addChild(e); pieces.append(e)
        }
        segments = pieces
        pulse = ModelEntity(mesh: .generatePlane(width: 0.54, height: 0.54, cornerRadius: 0.27),
            materials: [activeMaterial])
        pulse.name = "timing.circular.crossingPulse"; pulse.position.z = -0.002
        root.addChild(pulse); pulse.isEnabled = false
        var cached: [String: ModelEntity] = [:]
        for key in ["duck", "jump", "perfect", "hit", "unavailable", "pending", "paused"] {
            var material = UnlitMaterial(applyPostProcessToneMap: false)
            if let image = Self.art(key), let texture = try? TextureResource(image: image, options: .init(semantic: .color)) {
                material.color = .init(tint: .white, texture: .init(texture))
                material.blending = .transparent(opacity: 1.0)
            }
            let e = ModelEntity(mesh: .generatePlane(width: 0.44, height: 0.44), materials: [material])
            e.name = "timing.circular.\(key)"; e.position.z = 0.005
            root.addChild(e); cached[key] = e
        }
        faces = cached; root.isEnabled = false
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
        // Full ring at crossing means arrival only. Green/check/PERFECT requires CLEAR.
        litSegmentCount = reduceMotion ? Self.segmentCount : Int((value.progress * Double(Self.segmentCount)).rounded(.down))
        let style = value.phase == .result ? displayedState : value.phase == .passed || value.phase == .paused ? "neutral" : "active"
        if ringStyle != style {
            ringStyle = style
            let material = style == "perfect" ? successMaterial : style == "hit" ? hitMaterial : style == "active" ? activeMaterial : neutralMaterial
            for e in segments { e.model?.materials = [material] }
        }
        for (i, e) in segments.enumerated() { e.isEnabled = i < litSegmentCount }
        let elapsed = value.gameTime - value.crossingTime
        pulse.isEnabled = !reduceMotion && value.phase == .crossing && elapsed >= 0 && elapsed < 0.12
        pulse.scale = .init(repeating: 1 + Float(sin(min(1, max(0, elapsed/0.12)) * .pi))*0.035)
    }

    /// Matching custom vector silhouettes: rounded limbs, head and a ground cue.
    /// Ground/arrow are iconography, never synthesized body evidence.
    private static func art(_ key: String) -> CGImage? {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { context in
            let cg = context.cgContext
            let tint: UIColor = key == "perfect" ? UIColor(red: 0.45, green: 1, blue: 0.69, alpha: 1)
                : key == "hit" ? UIColor(red: 1, green: 0.48, blue: 0.61, alpha: 1) : .white
            func line(_ points: [CGPoint], width: CGFloat = 24) {
                let path = UIBezierPath(); path.move(to: points[0]); for p in points.dropFirst() { path.addLine(to: p) }
                path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
                tint.setStroke(); path.stroke()
            }
            if key == "duck" || key == "jump" {
                let duck = key == "duck"
                let head = CGRect(x: duck ? 260 : 224, y: duck ? 114 : 65, width: 64, height: 64)
                tint.setFill(); UIBezierPath(ovalIn: head).fill()
                if duck {
                    line([CGPoint(x: 277,y: 198), CGPoint(x: 229,y: 241), CGPoint(x: 181,y: 231)])
                    line([CGPoint(x: 270,y: 202), CGPoint(x: 324,y: 224), CGPoint(x: 354,y: 204)], width: 20)
                    line([CGPoint(x: 223,y: 248), CGPoint(x: 294,y: 275), CGPoint(x: 252,y: 309), CGPoint(x: 312,y: 309)])
                    line([CGPoint(x: 215,y: 248), CGPoint(x: 175,y: 279), CGPoint(x: 164,y: 309), CGPoint(x: 207,y: 309)], width: 21)
                } else {
                    line([CGPoint(x: 256,y: 152), CGPoint(x: 256,y: 231)])
                    line([CGPoint(x: 251,y: 168), CGPoint(x: 203,y: 149), CGPoint(x: 179,y: 115)], width: 20)
                    line([CGPoint(x: 263,y: 168), CGPoint(x: 309,y: 147), CGPoint(x: 334,y: 113)], width: 20)
                    line([CGPoint(x: 250,y: 231), CGPoint(x: 210,y: 264), CGPoint(x: 180,y: 243)], width: 23)
                    line([CGPoint(x: 264,y: 231), CGPoint(x: 300,y: 268), CGPoint(x: 330,y: 248)], width: 23)
                    line([CGPoint(x: 117,y: 254), CGPoint(x: 117,y: 192)], width: 12)
                    line([CGPoint(x: 99,y: 211), CGPoint(x: 117,y: 191), CGPoint(x: 135,y: 211)], width: 12)
                }
                cg.setAlpha(0.45); line([CGPoint(x: 166,y: 337), CGPoint(x: 346,y: 337)], width: 7); cg.setAlpha(1)
            } else if key == "perfect" {
                line([CGPoint(x: 177,y: 206), CGPoint(x: 231,y: 258), CGPoint(x: 339,y: 145)], width: 34)
            } else if key == "hit" {
                line([CGPoint(x: 201,y: 157), CGPoint(x: 311,y: 267)], width: 27)
                line([CGPoint(x: 311,y: 157), CGPoint(x: 201,y: 267)], width: 27)
            } else {
                line([CGPoint(x: 237,y: 163), CGPoint(x: 237,y: 254)], width: 18)
                line([CGPoint(x: 277,y: 163), CGPoint(x: 277,y: 254)], width: 18)
            }
            let text = key == "duck" ? "DUCK!" : key == "jump" ? "JUMP!" : key == "perfect" ? "PERFECT!" : key == "hit" ? "HIT" : key == "paused" ? "PAUSED" : key == "pending" ? "WAIT" : "NO DATA"
            let font = UIFont.systemFont(ofSize: key == "perfect" ? 63 : 70, weight: .black)
            let rounded = font.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
            let style = NSMutableParagraphStyle(); style.alignment = .center
            (text as NSString).draw(in: CGRect(x: 15, y: 360, width: 482, height: 90), withAttributes: [.font: rounded, .foregroundColor: tint, .paragraphStyle: style])
        }.cgImage
    }
}
