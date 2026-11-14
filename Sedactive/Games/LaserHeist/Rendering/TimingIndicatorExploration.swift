import Foundation
import RealityKit
import UIKit

/// Presentation only. Closing Gate is selected; the legacy bar is an internal fallback.
nonisolated enum TimingIndicatorVariant: String, CaseIterable, Sendable {
    case approved, closing
    #if DEBUG
    case fill, sweep
    #endif
    var title: String {
        switch self {
        case .approved: "Legacy fallback"
        case .closing: "Closing Gate"
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
            remaining: max(0, target.crossingTime - time), phase: phase, verdicts: results)
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
    #if DEBUG
    private let fill: ModelEntity
    private let target: ModelEntity
    #endif
    private let left: ModelEntity
    private let right: ModelEntity
    private let circle: ModelEntity
    private let dot: ModelEntity
    private let halo: ModelEntity
    private let captions = Entity()
    private var captionFaces: [String: ModelEntity] = [:]
    private var shownLabel: String?
    private let palette: [[UnlitMaterial]]
    private let circlePalette: [[UnlitMaterial]]
    private var lastTint: Int?
    private var lastCircleTint: Int?
    private(set) var model: LaserTimingPresentation?
    private(set) var variant: TimingIndicatorVariant = .closing
    static let width: Float = 1.03
    static let circleDiameter: Float = 0.17
    static let haloDiameter: Float = 0.22
    static let markerWidth: Float = 0.035
    static let markerRest: Float = 0.115
    static let crossingEmphasis = 0.12

    init() {
        func color(_ n: UInt32) -> UIColor { UIColor(red: CGFloat((n >> 16) & 255)/255, green: CGFloat((n >> 8)&255)/255, blue: CGFloat(n&255)/255, alpha: 1) }
        palette = [0x7565FF, 0xFFD447, 0x7BEFFF, 0x37D9A1, 0xF67585, 0x8C8BA9].map { [UnlitMaterial(color: color($0))] }
        circlePalette = [0x33B8DE, 0x7BEFFF, 0xDBFFFF, 0x37D9A1, 0xF67585, 0x8C8BA9].map { [UnlitMaterial(color: color($0))] }
        let dark = UnlitMaterial(color: color(0x19152F))
        func plane(_ name: String, _ width: Float, _ height: Float, _ materials: [UnlitMaterial]) -> ModelEntity {
            let e = ModelEntity(mesh: .generatePlane(width: width, height: height, cornerRadius: min(width, height)/2), materials: materials)
            e.name = name; return e
        }
        let track = plane("timing.track", Self.width + 0.04, 0.12, [dark]); root.addChild(track)
        let outline = plane("timing.outline", Self.width + 0.06, 0.14, [UnlitMaterial(color: color(0xC8BEF4))])
        outline.position.z = -0.001; root.addChild(outline)
        #if DEBUG
        fill = plane("timing.fill", Self.width, 0.08, palette[0]); fill.position.z = 0.003
        target = plane("timing.crossing.target", 0.018, 0.12, palette[2]); target.position.z = 0.004
        root.addChild(fill); root.addChild(target)
        #endif
        left = plane("timing.marker.left", Self.markerWidth, 0.13, palette[2]); left.position.z = 0.005
        right = plane("timing.marker.right", Self.markerWidth, 0.13, palette[2]); right.position.z = 0.005
        root.addChild(left); root.addChild(right)
        // Native rounded planes form a thick ring, dark core and dot. No texture/shader
        // generation for the target, and the moving markers stop outside its perimeter.
        circle = plane("timing.circle", Self.circleDiameter, Self.circleDiameter, circlePalette[0])
        circle.position.z = 0.008
        let core = plane("timing.circle.core", 0.11, 0.11, [dark]); core.position.z = 0.001
        circle.addChild(core)
        dot = plane("timing.circle.dot", 0.024, 0.024, circlePalette[0]); dot.position.z = 0.002
        circle.addChild(dot); root.addChild(circle)
        halo = plane("timing.circle.halo", Self.haloDiameter, Self.haloDiameter, circlePalette[2])
        halo.position.z = 0.006
        let haloCore = plane("timing.circle.halo.core", 0.198, 0.198, [dark]); haloCore.position.z = 0.001
        halo.addChild(haloCore); root.addChild(halo)
        halo.isEnabled = false
        captions.position = [0, -0.165, 0.010]; root.addChild(captions)
        root.name = "timing.closingGate"; root.isEnabled = false
    }

    func apply(_ value: LaserTimingPresentation?, variant: TimingIndicatorVariant, reduceMotion: Bool) {
        self.model = value; self.variant = variant
        root.isEnabled = variant != .approved && value != nil
        guard let value, root.isEnabled else { return }
        let p = Float(value.displayedProgress(reduceMotion: reduceMotion)), w = Self.width
        let tint = value.phase == .result ? (value.anyHit ? 4 : value.allClear ? 3 : 5)
            : value.phase == .paused || value.phase == .passed ? 5 : value.phase == .approach ? 0 : value.phase == .prepare ? 1 : 2
        if lastTint != tint {
            lastTint = tint
            left.model?.materials = palette[tint]; right.model?.materials = palette[tint]
            #if DEBUG
            fill.model?.materials = palette[tint]
            #endif
        }
        left.isEnabled = !reduceMotion && !variant.isFill
        right.isEnabled = !reduceMotion && variant == .closing
        let gap = Self.markerRest + (w/2 - Self.markerRest) * (1-p)
        left.position.x = variant == .closing ? -gap : -w/2 + w*p
        right.position.x = gap
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
            circle.model?.materials = circlePalette[circleTint]; dot.model?.materials = circlePalette[circleTint]
        }
        // A 120ms cosmetic emphasis derived solely from the original crossing timestamp.
        // At crossing the ring lights immediately, with a scale peak at +60ms.
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
