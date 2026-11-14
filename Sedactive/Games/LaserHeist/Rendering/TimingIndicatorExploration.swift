#if DEBUG
import Foundation
import RealityKit
import UIKit

/// DEBUG presentation only. Never an ideal/action-success window or an input to judgement.
nonisolated enum TimingIndicatorVariant: String, CaseIterable, Sendable {
    case approved, fill, sweep, closing
    var title: String {
        switch self { case .approved: "Approved"; case .fill: "A · Fill"; case .sweep: "B · Sweep"; case .closing: "C · Closing Gate" }
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

/// One renderer, a bounded reusable set of unlit planes, no animation/timer/subscription.
/// The existing cue owns this subtree, so its camera placement and lifecycle remain shared.
@MainActor final class TimingIndicatorRenderer {
    let root = Entity()
    private let fill: ModelEntity
    private let left: ModelEntity
    private let right: ModelEntity
    private let target: ModelEntity
    private let captions = Entity()
    private var captionFaces: [String: ModelEntity] = [:]
    private let palette: [UnlitMaterial]
    private(set) var model: LaserTimingPresentation?
    private(set) var variant: TimingIndicatorVariant = .approved
    static let width: Float = 1.03

    init() {
        func color(_ n: UInt32) -> UIColor { UIColor(red: CGFloat((n >> 16) & 255)/255, green: CGFloat((n >> 8)&255)/255, blue: CGFloat(n&255)/255, alpha: 1) }
        palette = [0x7565FF, 0xFFD447, 0x7BEFFF, 0x37D9A1, 0xF67585, 0x8C8BA9].map { UnlitMaterial(color: color($0)) }
        func plane(_ name: String, _ width: Float, _ height: Float, _ material: UnlitMaterial) -> ModelEntity {
            let e = ModelEntity(mesh: .generatePlane(width: width, height: height, cornerRadius: min(width, height) / 2), materials: [material]); e.name = name; return e
        }
        let track = plane("timing.track", Self.width + 0.04, 0.12, UnlitMaterial(color: color(0x19152F)))
        root.addChild(track)
        let outline = plane("timing.outline", Self.width + 0.06, 0.14, UnlitMaterial(color: color(0xC8BEF4)))
        outline.position.z = -0.001; root.addChild(outline)
        fill = plane("timing.fill", Self.width, 0.08, palette[0]); fill.position.z = 0.003
        left = plane("timing.marker.left", 0.035, 0.13, palette[2]); left.position.z = 0.005
        right = plane("timing.marker.right", 0.035, 0.13, palette[2]); right.position.z = 0.005
        target = plane("timing.crossing.target", 0.018, 0.12, palette[1]); target.position.z = 0.004
        root.addChild(fill); root.addChild(left); root.addChild(right); root.addChild(target)
        captions.position = [0, -0.105, 0.006]; root.addChild(captions)
        root.name = "timing.exploration"; root.isEnabled = false
    }

    func apply(_ value: LaserTimingPresentation?, variant: TimingIndicatorVariant, reduceMotion: Bool) {
        self.model = value; self.variant = variant
        root.isEnabled = variant != .approved && value != nil
        guard let value, root.isEnabled else { return }
        let p = Float(value.displayedProgress(reduceMotion: reduceMotion)), w = Self.width
        let tint = value.phase == .result ? (value.anyHit ? 4 : value.allClear ? 3 : 5)
            : value.phase == .paused ? 5 : value.phase == .approach ? 0 : value.phase == .prepare ? 1 : 2
        let material = palette[tint]
        fill.model?.materials = [material]; left.model?.materials = [material]; right.model?.materials = [material]
        fill.isEnabled = variant == .fill || reduceMotion
        left.isEnabled = !reduceMotion && variant != .fill
        right.isEnabled = !reduceMotion && variant == .closing
        fill.scale.x = max(0.001, p); fill.position.x = -w/2 + w*p/2
        left.position.x = variant == .closing ? -w/2 * (1-p) : -w/2 + w*p
        right.position.x = w/2 * (1-p)
        // The end tick (or centre tick) is a crossing destination, never an ideal zone.
        target.position.x = variant == .closing && !reduceMotion ? 0 : w/2
        target.model?.materials = [palette[2]]
        target.scale.y = value.phase == .crossing && !reduceMotion ? 1.2 : 1
        for face in captionFaces.values { face.isEnabled = false }
        let label = reduceMotion ? "\(value.label) · REDUCED MOTION" : value.label
        let face: ModelEntity
        if let cached = captionFaces[label] { face = cached }
        else {
            // Bounded vocabulary: phase labels + P1/P2 verdict combinations only.
            let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 60)).image { _ in
                let style = NSMutableParagraphStyle(); style.alignment = .center
                (label as NSString).draw(in: CGRect(x: 0, y: 0, width: 800, height: 60), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 27, weight: .heavy), .foregroundColor: UIColor.white, .paragraphStyle: style])
            }
            var mat = UnlitMaterial(color: .white)
            if let cg = image.cgImage, let texture = try? TextureResource.generate(from: cg, options: .init(semantic: .color)) {
                mat.color = .init(tint: .white, texture: .init(texture))
                mat.blending = .transparent(opacity: 1.0)
            }
            face = ModelEntity(mesh: .generatePlane(width: 1.25, height: 0.094), materials: [mat])
            captions.addChild(face); captionFaces[label] = face
        }
        face.isEnabled = true
    }
}
#endif
