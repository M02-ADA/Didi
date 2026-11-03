import SwiftUI

/// Essential feedback for the synthetic, camera-free development slice.
struct ReplaySliceHUD: View {
    let session: GameSessionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LASER HEIST · BODY REPLAY").font(.headline)
            Text("Health \(session.state?.teamHealth ?? 5) / 5   ·   Team score \(session.state?.teamScore ?? 0)")
            Text("P1: left · P2: right").font(.caption)
            ProgressView(value: session.state?.gameTime ?? 0, total: session.script.duration)
                .frame(maxWidth: 280)
                .accessibilityLabel("Replay progress")
            switch session.phase {
            case .finished:
                Text("Replay complete").font(.title2.bold())
                Text("\(session.results.count) target results · no camera used")
            case .failed(let message): Text("Replay stopped: \(message)")
            case .idle: Text("Preparing body replay…")
            case .running: Text("Follow DUCK / JUMP; badges show each player's result.")
            }
            if !session.results.isEmpty {
                Text("Last verdicts: P1 \(lastVerdict(.player1)) · P2 \(lastVerdict(.player2))")
                    .font(.callout.bold())
            }
            #if DEBUG
            if let packet = session.latestSnapshot {
                Text("Frame \(packet.frameID) · captured \(packet.capturedAt, specifier: "%.2f")")
                    .font(.caption.monospaced())
                Text("Cyan: crown · Purple: wrists · Green: soles")
                    .font(.caption)
                Text("Yellow: judged band edges").font(.caption)
                if let encounter = session.script.encounters.last(where: { $0.targets[0].crossingTime - 4 <= (session.state?.gameTime ?? 0) }) {
                    let target = encounter.targets[0]
                    Text("Band \(target.beam.lowerY, specifier: "%.3f")–\(target.beam.upperY, specifier: "%.3f") · margin \(session.script.configuration.clearanceMargin, specifier: "%.3f")")
                        .font(.caption.monospaced())
                }
            }
            #endif
        }
        .padding()
        .frame(maxWidth: 340, alignment: .leading)
        .foregroundStyle(.white)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    private func lastVerdict(_ player: PlayerID) -> String {
        guard let result = session.results.last(where: { $0.playerID == player }) else { return "PENDING" }
        switch result.judgement {
        case .clear: return "CLEAR"
        case .hit: return "HIT"
        case .unavailable: return "UNAVAILABLE"
        case .pending: return "PENDING"
        }
    }
}
