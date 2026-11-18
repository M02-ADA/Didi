import SwiftUI

enum ProgressTutorialPhase: String, CaseIterable {
    case bar, vault
    var copy: String {
        switch self {
        case .bar: "This bar shows how far\nyou've gone"
        case .vault: "Each circle is a vault door\nto open"
        }
    }
    static let duration = 4.0
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
                let k = min(proxy.size.width / 1210, proxy.size.height / 834)
                let origin = proxy.frame(in: .global).origin
                let bar = measured.offsetBy(dx: -origin.x, dy: -origin.y)
                let textY = max(bar.maxY + 140 * k, proxy.size.height * 0.46)
                ZStack {
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: proxy.size))
                        path.addRoundedRect(in: bar.insetBy(dx: -4 * k, dy: -4 * k),
                            cornerSize: CGSize(width: 36 * k, height: 36 * k))
                    }.fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                    if phase == .bar {
                        Rectangle().fill(LaserHeistDesign.cream.opacity(0.5))
                            .frame(width: bar.width, height: 0.6 * k)
                            .position(x: bar.midX, y: bar.maxY + 15 * k)
                    } else {
                        let start = bar.midY + 13 * k
                        let end = textY - 72 * k
                        Rectangle().fill(LaserHeistDesign.cream.opacity(0.6))
                            .frame(width: k, height: max(0, end - start))
                            .position(x: bar.midX, y: (start + end) / 2)
                            .accessibilityLabel("Pointer to the centered vault checkpoint")
                            .accessibilityIdentifier("ftueVaultPointer")
                    }
                    Text(phase.copy)
                        .font(.system(size: 60 * k, weight: .bold, design: .rounded))
                        .foregroundStyle(LaserHeistDesign.cream)
                        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
                        .frame(width: proxy.size.width * 0.78)
                        .position(x: phase == .vault ? bar.midX : proxy.size.width / 2, y: textY)
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
