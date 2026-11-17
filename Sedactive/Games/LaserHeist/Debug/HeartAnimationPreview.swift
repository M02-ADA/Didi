#if DEBUG
import Foundation
import Observation
import RealityKit
import RealityKitContent
import SwiftUI

/// Explicit visual-only corridor fixture. It creates no game session, input or reward events.
/// Launch: -replay -heartAnimationPreview. Uses PlayView's existing render tick for cleanup.
@MainActor @Observable
final class HeartAnimationPreview {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-heartAnimationPreview") }
    private(set) var status = "Loading"
    private(set) var collections = 0
    private(set) var generation: UUID?
    @ObservationIgnored private(set) var heart: HeartCollectible?
    @ObservationIgnored private var art: HeartArt?
    @ObservationIgnored private weak var scene: LaserScene?
    @ObservationIgnored private var request: UUID?
    @ObservationIgnored private var approvedReference: Entity?
    @ObservationIgnored private var companionDiamond: Diamond?

    func start(scene: LaserScene, generation: UUID) async throws {
        stop()
        let token = UUID()
        request = token
        status = "Loading"
        let art = try await HeartArt.load()
        guard !Task.isCancelled, request == token else { return }
        self.art = art
        self.scene = scene
        self.generation = generation
        collections = 0
        scene.isLaserVisible = false
        if ProcessInfo.processInfo.arguments.contains("-heartColorSource") {
            // Direct approved resource, without HeartArt/HeartCollectible wrappers or overrides.
            let reference = try await Entity(named: "Heart3D.usdz", in: realityKitContentBundle)
            guard !Task.isCancelled, request == token else { return }
            reference.position = [0, 1.8, 0.1]
            scene.root.addChild(reference)
            approvedReference = reference
            status = "Original approved asset"
        } else {
            showAnother()
        }
    }

    func showAnother(reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled) {
        guard let art, let scene, let generation else { return }
        approvedReference?.removeFromParent()
        approvedReference = nil
        heart?.retire()
        let next = art.makeHeart(generation: generation)
        next.root.position = [0, 1.8, 0.1]
        scene.root.addChild(next.root)
        heart = next
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-heartPreviousPalette") { next.usePreviousPaletteForComparison() }
        if arguments.contains("-heartOriginalPalette") { next.useAuthoredPaletteForComparison() }
        if arguments.contains("-heartNoGlow") { next.hideGlowForComparison() }
        if arguments.contains("-heartWithDiamond"), companionDiamond == nil, let diamond = scene.makeDiamond() {
            diamond.root.setPosition([0.5, 1.8, 0.1], relativeTo: scene.root)
            diamond.showIdle(reduceMotion: true)
            companionDiamond = diamond
        }
        if arguments.contains("-heartTipBefore") { next.compareTipShading(unlit: false) }
        if arguments.contains("-heartTipUnlit") { next.compareTipShading(unlit: true) }
        if let i = arguments.firstIndex(of: "-heartAngle"), arguments.indices.contains(i + 1) {
            let angle: Float = arguments[i + 1] == "side" ? .pi / 2 : .pi / 4
            next.root.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
        }
        if arguments.contains("-heartColorBefore") { next.useDefaultEnvironmentForComparison() }
        next.showIdle(reduceMotion: reduceMotion || arguments.contains("-heartColorStill"))
        status = "Idle"
    }

    func collect(now: TimeInterval = CACurrentMediaTime(), reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled) {
        guard let heart, let generation,
              heart.collect(generation: generation, target: heart.target, now: now, reduceMotion: reduceMotion) else { return }
        collections += 1
        status = "Collecting"
    }

    func update(now: TimeInterval) {
        guard let heart, let generation else { return }
        heart.update(now: now, generation: generation)
        if heart.phase == .retired {
            self.heart = nil
            status = "Retired"
        }
    }

    func stop() {
        request = nil
        companionDiamond?.retire()
        companionDiamond = nil
        approvedReference?.removeFromParent()
        approvedReference = nil
        heart?.retire()
        heart = nil
        art = nil
        scene = nil
        generation = nil
        status = "Stopped"
    }
}

struct HeartAnimationPreviewControls: View {
    let preview: HeartAnimationPreview
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 6) {
            Text("SYNTHETIC HEART VFX · PRESENTATION ONLY").font(.caption.bold())
            Text("No game session · no health or score changes").font(.caption)
            Text("\(preview.status) · visual collections \(preview.collections)")
                .font(.caption.monospaced()).accessibilityIdentifier("heartPreviewStatus")
            Text(preview.generation?.uuidString ?? "none").font(.caption2.monospaced())
                .accessibilityIdentifier("heartPreviewGeneration")
            HStack {
                Button("Collect visual") { preview.collect() }.accessibilityIdentifier("heartPreviewCollect")
                    .disabled(preview.status != "Idle")
                Button("New Heart") { preview.showAnother() }.accessibilityIdentifier("heartPreviewNew")
                    .disabled(preview.generation == nil)
                Button("Stop") { preview.stop() }.accessibilityIdentifier("heartPreviewStop")
                Button("Retry preview", action: retry).accessibilityIdentifier("heartPreviewRetry")
            }.buttonStyle(.bordered).tint(.pink)
        }
        .foregroundStyle(.white).padding(12)
        .background(.black.opacity(0.8), in: .rect(cornerRadius: 12)).padding(.bottom, 64)
    }
}
#endif
