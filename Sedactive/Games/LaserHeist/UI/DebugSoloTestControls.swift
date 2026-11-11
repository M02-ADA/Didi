#if DEBUG
import SwiftUI

/// DEBUG Solo Test only: a compact tester panel over the live round. "Skip to Next Gate"
/// shortens the current minute (the coordinator's director, never the progress bar alone),
/// and during a vault P1's three buttons can be tapped as a fallback for the wrist press.
/// Tracking is shown as the producer reports it; nothing here creates body evidence.
struct DebugSoloTestControls: View {
    let session: GameSessionCoordinator

    var body: some View {
        // Game time moves without SwiftUI state changes: re-read a few times a second.
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            VStack(alignment: .leading, spacing: 6) {
                Text("DEBUG · SOLO TEST").font(.system(size: 11, weight: .heavy, design: .monospaced))
                Text(status).font(.system(size: 11, design: .monospaced))
                Text(tracking).font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(isTracked ? Color.green : Color.orange)
                if let pressed = session.debugSoloVaultPressed {
                    HStack(spacing: 6) {
                        ForEach(LaserVaultButton.allCases, id: \.self) { button in
                            Button(label(button)) { session.debugPressVaultButton(button) }
                                .buttonStyle(.borderedProminent)
                                .tint(pressed.contains(button) ? .green : .yellow)
                                .disabled(pressed.contains(button))
                                .accessibilityIdentifier("debugSoloVault.\(button.rawValue)")
                        }
                    }
                } else {
                    Button("Skip to Next Gate") { session.debugSkipToNextGate() }
                        .buttonStyle(.borderedProminent).tint(.yellow)
                        .disabled(!session.canDebugSkipToNextGate)
                        .accessibilityIdentifier("debugSkipToNextGate")
                }
                if !session.debugSkips.isEmpty {
                    Text("skips \(session.debugSkips.count) · dropped lasers \(session.debugSkips.map(\.droppedLasers).reduce(0, +))")
                        .font(.system(size: 10, design: .monospaced))
                }
            }
            .foregroundStyle(.white)
            .padding(10)
            .background(.black.opacity(0.65), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yellow, lineWidth: 1.5))
        }
    }

    private func label(_ button: LaserVaultButton) -> String {
        switch button { case .top: "P1 ▲"; case .middle: "P1 ●"; case .bottom: "P1 ▼" }
    }

    private var status: String {
        guard let state = session.state else { return "round not started" }
        let phase: String = switch state.phase {
        case .activity: "activity"
        case .vault: "GATE"
        case .diamondTime: "DIAMOND TIME"
        case .ended(let outcome): "ended \(outcome)"
        }
        let next = session.liveVaultIn.map { String(format: " · gate in %.0f s", $0) } ?? ""
        return "gate \(state.missionProgress)/\(state.missionTarget) · \(phase)\(next)"
    }

    private var isTracked: Bool {
        session.latestSnapshot?.players[.player1]?.trackingStatus == .reliable
    }

    private var tracking: String {
        if isTracked { return "P1 tracked" }
        return session.debugSoloTrackingLost ? "P1 lost · no evidence (UNAVAILABLE)" : "P1 not detected · no evidence"
    }
}
#endif
