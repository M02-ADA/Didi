#if DEBUG
import SwiftUI

/// Renderer selection only; this view owns no gameplay timing or evidence.
struct TimingIndicatorControls: View {
    let session: GameSessionCoordinator?
    let scene: LaserScene
    let retry: () -> Void
    @State private var selected: TimingIndicatorVariant = launchVariant ?? .closing
    @State private var busy = false
    @State private var error: String?
    static var isComparison: Bool { ProcessInfo.processInfo.arguments.contains("-timingComparison") }
    static var launchVariant: TimingIndicatorVariant? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-timingIndicator"), args.indices.contains(i + 1) else { return nil }
        return TimingIndicatorVariant(rawValue: args[i + 1])
    }
    static let steps: [(String, Double)] = [
        ("Duck early", 1.15), ("Duck prepare", 2.6), ("Duck near", 3.85), ("Duck immediately before", 3.99),
        ("Duck crossing", 4), ("Duck pulse", 4.06), ("Duck result", 4.4),
        ("Jump early", 7.15), ("Jump prepare", 8.6), ("Jump near", 9.85), ("Jump immediately before", 9.99),
        ("Jump crossing", 10), ("Jump pulse", 10.06), ("Jump result", 10.4)]
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if Self.isComparison {
                Text("SYNTHETIC REPLAY · same encounters / no camera")
                    .font(.caption2.bold())
                Text(String(format: "t %.2f · score %d", session?.state?.gameTime ?? 0, session?.state?.teamScore ?? 0))
                    .font(.caption.monospaced()).accessibilityIdentifier("timingSourceReadout")
                HStack {
                    Menu("Step fixture") {
                        ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, step in
                            Button(step.0) { advance(step.1) }.disabled(busy || (session?.state?.gameTime ?? 0) > step.1)
                                .accessibilityIdentifier("timingStep\(i)")
                        }
                    }.accessibilityIdentifier("timingSteps")
                    Button("Retry fixture", action: retry).accessibilityIdentifier("timingRetry")
                }
                if let error { Text(error).accessibilityIdentifier("timingError") }
            }
            Menu("Timing · \(selected.title)") {
                ForEach(TimingIndicatorVariant.allCases, id: \.self) { variant in
                    Button(variant.title) { selected = variant; scene.selectTimingVariant(variant) }
                        .accessibilityIdentifier("timingVariant_\(variant.rawValue)")
                }
            }
            .accessibilityIdentifier("timingSelector")
            .font(.caption.bold())
        }
        .buttonStyle(.bordered).tint(.cyan)
        .foregroundStyle(.white).padding(10)
        .background(.black.opacity(0.75), in: .rect(cornerRadius: 12))
        .padding(.trailing, 14).padding(.bottom, 10)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
    private func advance(_ time: Double) {
        guard Self.isComparison, let session, session.isReplay, !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await session.advance(to: time) } catch { self.error = String(describing: error) }
        }
    }
}
#endif
