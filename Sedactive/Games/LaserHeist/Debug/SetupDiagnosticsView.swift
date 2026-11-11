#if DEBUG
import SwiftUI

/// DEBUG only: a button on the setup screen that opens live calibration diagnostics, to tell
/// a real tracking failure from an over-strict check on the iPad. Numbers and reasons only:
/// no camera image, mask or pose history is shown or stored.
struct SetupDiagnosticsToggle: View {
    let flow: LaserInputFlow
    @State private var shown = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if shown, let session = flow.session { SetupDiagnosticsView(session: session) }
            Button(shown ? "Hide diagnostics" : "Diagnostics") { shown.toggle() }
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(sketch: 0xFFC83A), in: Capsule())
                .foregroundStyle(Color(sketch: 0x16123A))
                .buttonStyle(.plain)
                .accessibilityIdentifier("setupDiagnosticsToggle")
        }
        .padding([.trailing, .bottom], 16)
    }
}

struct SetupDiagnosticsView: View {
    let session: GameSessionCoordinator

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            ScrollView {
                Text(Self.report(session))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(width: 560, height: 360)
            .padding(10)
            .background(.black.opacity(0.85), in: .rect(cornerRadius: 12))
        }
    }

    static func report(_ session: GameSessionCoordinator) -> String {
        guard let setup = session.setup else { return "No live setup." }
        let controls = setup.diagnosticControls
        let progress = controls.calibration
        var lines = ["\(session.isSoloPractice ? "SOLO TEST (P1 only)" : "CO-OP") · camera \(AppDependencies.shared.camera.state.status)",
                     "setup \(setup.phase) · session \(session.phase) · people in view \(session.presence.peopleInView)",
                     "calibration \(progress.phase.rawValue) · attempts \(session.presence.attempts) · \(progress.reason)"]
        let now = CameraHostClock.now()
        // Gameplay evidence: what the live round would judge from right now.
        lines.append("readiness \(session.liveReadiness.map { String(describing: $0.phase) } ?? "-") · plan \(session.hasLiveRoundPlan ? "installed" : "none")"
            + (session.livePlanError.map { " · plan error \($0)" } ?? ""))
        for player in session.inputConfiguration.roster {
            let slot = controls.tracking.latest?[player]
            let p = progress.players[player] ?? .init()
            let d = p.last
            func c(_ j: BodyJoint) -> String { String(format: "%.2f", d.confidence[j] ?? 0) }
            let refused = p.rejected.sorted { $0.value > $1.value }.map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", ")
            lines.append("")
            lines.append("\(player.rawValue): tracking \(slot.map { "\($0.state.rawValue)/\($0.reason.rawValue)" } ?? "none") · window \(p.samples)/\(StandingCollectionPolicyV1.sampleCount) · accepted \(p.accepted) · resets \(d.resets)")
            lines.append("  latest issue: \(p.latestIssue?.rawValue ?? "none") · refused: \(refused.isEmpty ? "none" : refused)")
            lines.append("  head top: \(d.crownSeen ? "seen" : d.crown?.rawValue ?? "—") · soles: \(d.solesSeen ? "seen" : d.soles?.rawValue ?? "—")")
            lines.append("  face nose \(c(.nose)) eyes \(c(.leftEye))/\(c(.rightEye)) ears \(c(.leftEar))/\(c(.rightEar)) neck \(c(.neck))")
            lines.append("  body shoulders \(c(.leftShoulder))/\(c(.rightShoulder)) hips \(c(.leftHip))/\(c(.rightHip))")
            lines.append("  legs knees \(c(.leftKnee))/\(c(.rightKnee)) ankles \(c(.leftAnkle))/\(c(.rightAnkle))")
            let apart = d.ankleSeparationPixels.map { String(format: "%.0f px", $0) } ?? "—"
            let share = d.ankleSeparationShare.map { String(format: "%.2f", $0) } ?? "—"
            let body = d.bodyHeightPixels.map { String(format: "%.0f px", $0) } ?? "—"
            lines.append("  ankles apart \(apart) (\(share) of body \(body)) · spread \(String(format: "%.1f", p.spreadPixels)) px · mask rows \(p.maskRows.map(String.init) ?? "?")")
            if let sample = session.latestSnapshot?.players[player], let snapshot = session.latestSnapshot {
                let g = sample.geometry
                func v(_ e: EstimatedScalar) -> String { e.validity == .valid ? "ok" : "\(e.validity)" }
                lines.append(String(format: "  evidence %@ (%.2fs old): head %@ wrists %@/%@ soles %@/%@ jump %@",
                    "\(sample.trackingStatus)", now - snapshot.capturedAt, v(g.crownY), v(g.leftWristY), v(g.rightWristY),
                    v(g.leftSoleY), v(g.rightSoleY), "\(sample.jumpState.phase)/\(sample.jumpState.validity)"))
            }
            if let last = LiveAvatarPresenter.debugLastFrame[player] {
                lines.append(String(format: "  mascot input %.2fs old · %@", now - last.capturedAt, last.available ? "available" : "unavailable"))
            }
        }
        lines.append("")
        lines.append("timing: " + session.setupTimeline.marks.map { mark in
            String(format: "%@ +%.1fs", mark.name, mark.at - (session.setupTimeline.origin ?? mark.at))
        }.joined(separator: " · "))
        return lines.joined(separator: "\n")
    }
}
#endif

#if DEBUG
/// DEBUG layout check (`-setupStagePreview`): the setup stage over a stand-in 16:9 "camera"
/// with two figures where real players stand, and sample statuses. No camera, no session.
struct SetupStagePreview: View {
    var body: some View {
        CalibrationStageView(cameraPreview: AnyView(StandIn()), playerStatus: [
            .player1: .calibrating(progress: 0.6, issue: nil), .player2: .calibrating(progress: 0.2, issue: .feetCutOff)],
            onBack: {}) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stand still and upright!").font(.title.bold())
                    Text("Step back so your feet are in view.").font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Leave camera setup", role: .cancel) {}.buttonStyle(.bordered).controlSize(.large)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(.regularMaterial, in: .rect(cornerRadius: 20)).preferredColorScheme(.dark)
        }
    }

    private struct StandIn: View {
        var body: some View {
            GeometryReader { g in
                ZStack {
                    LinearGradient(colors: [.gray.opacity(0.5), .gray.opacity(0.25)], startPoint: .top, endPoint: .bottom)
                    // Two adults about 1.7 m tall, 2.5 m from the camera: roughly 80 % of the frame height.
                    ForEach([0.27, 0.73], id: \.self) { x in
                        Image(systemName: "figure.stand").resizable().scaledToFit()
                            .frame(height: g.size.height * 0.8)
                            .foregroundStyle(.white.opacity(0.6))
                            .position(x: g.size.width * x, y: g.size.height * 0.52)
                    }
                }
            }
        }
    }
}
#endif
