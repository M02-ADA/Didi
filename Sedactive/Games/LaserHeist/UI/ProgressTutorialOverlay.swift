import SwiftUI

enum ProgressTutorialPhase: String, CaseIterable {
    case bar, vault
    var copy: String {
        switch self {
        case .bar: "This bar shows how far\nyou've gone"
        case .vault: "Each circle is a vault\ndoor to open"
        }
    }
    static let duration = 4.0
}

/// Geometry is resolved from the rendered HUD slot. Its center is also the checkpoint anchor
/// because FTUEProgressBar places the checkpoint at the midpoint on both axes.
struct ProgressTutorialSpotlightLayout {
    let bar: CGRect
    let viewport: CGSize
    let phase: ProgressTutorialPhase

    var scale: CGFloat { bar.height / 65 }
    var stroke: CGFloat { 8 * scale }
    var connectorWidth: CGFloat { 5 * scale }
    var cutout: CGRect { bar.insetBy(dx: -2 * scale, dy: -2 * scale) }
    var highlight: CGRect {
        if phase == .bar { return bar.insetBy(dx: -18 * scale, dy: -18 * scale) }
        let diameter = bar.height * 1.42
        return CGRect(x: bar.midX - diameter / 2, y: bar.midY - diameter / 2, width: diameter, height: diameter)
    }
    var textTop: CGFloat { max(viewport.height * 0.39, highlight.maxY + 104 * scale) }
    var connector: CGRect {
        let start = highlight.maxY - stroke / 2
        return CGRect(x: bar.midX - connectorWidth / 2, y: start, width: connectorWidth,
                      height: textTop - 28 * scale - start)
    }
}

/// Highlights the ONE existing HUD bar. The pointer uses that bar's measured checkpoint center.
struct ProgressTutorialOverlay: View {
    let tutorial: LeanTutorial
    let phase: ProgressTutorialPhase
    @Environment(\.scenePhase) private var scenePhase
    private struct Visibility: Equatable { let phase: ProgressTutorialPhase; let active: Bool; let generation: UUID? }
    private var active: Bool {
        scenePhase == .active && !tutorial.isSuspended && tutorial.progressJourney.isActivePresentation
            && tutorial.progressJourney.fillEnd == FTUEProgressJourney.checkpoint && tutorial.progressHUDFrame != nil
    }
    var body: some View {
        GeometryReader { proxy in
            if active, let measured = tutorial.progressHUDFrame {
                let origin = proxy.frame(in: .global).origin
                let layout = ProgressTutorialSpotlightLayout(
                    bar: measured.offsetBy(dx: -origin.x, dy: -origin.y),
                    viewport: proxy.size, phase: phase)
                ZStack(alignment: .topLeading) {
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: proxy.size))
                        path.addRoundedRect(in: layout.cutout,
                            cornerSize: CGSize(width: layout.cutout.height / 2, height: layout.cutout.height / 2))
                    }.fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                    Capsule()
                        .fill(LaserHeistDesign.cream)
                        .frame(width: layout.connector.width, height: layout.connector.height)
                        .position(x: layout.connector.midX, y: layout.connector.midY)
                        .accessibilityElement()
                        .accessibilityLabel(phase == .bar ? "Pointer to the progress bar" : "Pointer to the centered vault checkpoint")
                        .accessibilityIdentifier(phase == .bar ? "ftueProgressPointer" : "ftueVaultPointer")
                    Capsule()
                        .strokeBorder(LaserHeistDesign.cream, lineWidth: layout.stroke)
                        .frame(width: layout.highlight.width, height: layout.highlight.height)
                        .position(x: layout.highlight.midX, y: layout.highlight.midY)
                        .accessibilityHidden(true)
                    Text(phase.copy)
                        .font(.system(size: 67 * layout.scale, weight: .bold, design: .rounded))
                        .foregroundStyle(LaserHeistDesign.cream)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .frame(width: proxy.size.width * 0.78)
                        .offset(x: layout.bar.midX - proxy.size.width * 0.39, y: layout.textTop)
                        .accessibilityIdentifier("progressTutorialTitle")
                }
            }
        }
        .ignoresSafeArea().allowsHitTesting(false)
        .task(id: Visibility(phase: phase, active: active, generation: tutorial.generation)) {
            guard active, let generation = tutorial.generation else { return }
            tutorial.progressVisible(phase, visible: true, generation: generation)
            do { try await Task.sleep(for: .seconds(ProgressTutorialPhase.duration)) } catch { return }
            guard !Task.isCancelled, active else { return }
            tutorial.finishProgress(phase, generation: generation)
        }
        .onDisappear {
            if let generation = tutorial.generation { tutorial.progressVisible(phase, visible: false, generation: generation) }
        }
    }
}
