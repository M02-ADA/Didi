import SwiftUI

/// Minimal input selection. Home artwork/navigation can be developed independently of source control.
struct LaserInputSelectionView: View {
    let flow: LaserInputFlow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label("LASER HEIST", systemImage: "diamond.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text("Make your next move.")
                    .font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text("Choose camera setup for two players, or explore the sample round.")
                    .font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 16) {
                    Button {
                        Task { await flow.startLiveSetup() }
                    } label: {
                        Label("Camera setup", systemImage: "person.2.fill")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent).tint(.orange).foregroundStyle(.black)
                    .disabled(!flow.canStartLive).accessibilityIdentifier("chooseLive")
                    Text("Place the iPad securely in landscape, then stand side by side facing it with room to move. Movement checks must be ready before a round can start.")
                        .foregroundStyle(.secondary)
                    Divider()
                    Button { flow.showReplay() } label: {
                        Label("Replay demo", systemImage: "play.rectangle")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered).accessibilityIdentifier("chooseReplay")
                    Text("A sample round with no camera. You can return here at any time.")
                        .foregroundStyle(.secondary)
                }
                .controlSize(.large)
                .padding(24).background(.white.opacity(0.06), in: .rect(cornerRadius: 20))
                if let message = flow.message {
                    Label(message, systemImage: "info.circle")
                        .font(.callout).accessibilityIdentifier("inputFlowMessage")
                }
                #if DEBUG
                Button("Camera diagnostics") { flow.showDiagnostics() }
                    .buttonStyle(.bordered).controlSize(.large)
                    .disabled(!flow.canStartLive).accessibilityIdentifier("cameraDiagnostics")
                #endif
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(32).frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.035, green: 0.055, blue: 0.11)).preferredColorScheme(.dark)
    }
}
