import SwiftUI

enum ProgressTutorialPhase: String, CaseIterable {
    case bar, vault, diamond
    var copy: String {
        switch self {
        case .bar: "This bar shows how far\nyou've gone"
        case .vault: "Each circle is a vault\ndoor to open"
        case .diamond: "Reach the Diamond\nVault at the end!"
        }
    }
    var pointerIdentifier: String {
        switch self {
        case .bar: "ftueProgressPointer"
        case .vault: "ftueVaultPointer"
        case .diamond: "ftueDiamondPointer"
        }
    }
    var pointerLabel: String {
        switch self {
        case .bar: "Pointer to the progress bar"
        case .vault: "Pointer to the centered vault checkpoint"
        case .diamond: "Pointer to the Diamond at the end of the progress bar"
        }
    }
    static let duration = 4.0
}

/// Geometry uses the measured HUD slot and the same endpoint fraction as FTUEProgressBar.
struct ProgressTutorialSpotlightLayout {
    let bar: CGRect
    let viewport: CGSize
    let phase: ProgressTutorialPhase

    var scale: CGFloat { bar.height / 65 }
    var stroke: CGFloat { 8 * scale }
    var connectorWidth: CGFloat { 5 * scale }
    var cutout: CGRect { bar.insetBy(dx: -2 * scale, dy: -2 * scale) }
    var anchorX: CGFloat {
        phase == .diamond ? bar.minX + bar.width * GameplayHUDModel.diamondPosition : bar.midX
    }
    var textCenterX: CGFloat { phase == .diamond ? bar.midX + 0.13 * bar.width : bar.midX }
    var highlight: CGRect {
        if phase == .bar { return bar.insetBy(dx: -18 * scale, dy: -18 * scale) }
        let diameter = bar.height * 1.42
        return CGRect(x: anchorX - diameter / 2, y: bar.midY - diameter / 2, width: diameter, height: diameter)
    }
    var textTop: CGFloat { max(viewport.height * 0.39, highlight.maxY + 104 * scale) }
    var connector: CGRect {
        let start = highlight.maxY - stroke / 2
        return CGRect(x: anchorX - connectorWidth / 2, y: start, width: connectorWidth,
                      height: textTop - 28 * scale - start)
    }
}

/// Highlights a subject on the single existing FTUE bar.
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
                        .accessibilityLabel(phase.pointerLabel)
                        .accessibilityIdentifier(phase.pointerIdentifier)
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
                        .offset(x: layout.textCenterX - proxy.size.width * 0.39, y: layout.textTop)
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
