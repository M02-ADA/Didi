#if DEBUG
import SwiftUI

/// The existing E05/J03 commands, shown in the real game scene. No accepted-reference store,
/// geometry defaults, input subscription, calibration promotion or alternate readiness gate.
struct LiveWristSetupControls: View {
    let flow: LaserInputFlow
    let service: BodyInputService
    @State private var error: String?
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            Text("REAL WRIST SETUP · CONTACT REFUSED UNTIL E05 + J03 + REVIEWED GEOMETRY")
                .font(.caption.bold()).accessibilityIdentifier("liveWristSetupTitle")
            if let session = flow.session, let setup = session.setup {
                let progress = service.calibrationProgress
                Text("Standing candidate: \(progress.phase.rawValue) · \(progress.sampleCount)/\(StandingCollectionPolicyV1.sampleCount)")
                    .accessibilityIdentifier("liveWristCalibrationProgress")
                Text(progress.reason).font(.caption2)
                if let candidate = progress.candidate {
                    Text("\(candidate.hasValidatedAnatomy ? "Validated references" : "EXPERIMENTAL / NOT ACCEPTABLE") · source frame \(candidate.lastFrameID)")
                        .accessibilityIdentifier("liveWristCandidateQuality")
                }
                HStack {
                    Button("Confirm P1/P2") { perform { try setup.confirmPlayers() } }
                        .disabled(setup.phase != .confirmPlayers).accessibilityIdentifier("liveWristConfirmPair")
                    Button("Collect standing candidate") { perform { try setup.requestCalibration(id:UUID()) } }
                        .disabled(setup.phase != .awaitingCalibration).accessibilityIdentifier("liveWristCollect")
                }
                HStack {
                    Button("Cancel collection") { setup.cancelCalibration() }
                        .disabled(!setup.canCancelCalibration).accessibilityIdentifier("liveWristCancelCollection")
                    Button("Accept validated candidate") {
                        perform {
                            guard let id = setup.candidateIDForConfirmation else { throw LiveVisionError.unsupportedAnatomy }
                            try setup.confirmCandidate(id:id)
                        }
                    }.disabled(setup.candidateIDForConfirmation == nil || progress.candidate?.hasValidatedAnatomy != true)
                        .accessibilityIdentifier("liveWristAccept")
                }
                Text("Contact: \(session.liveWristBlockers.isEmpty && session.phase == .running ? "CURRENT SESSION GATES ONLY" : "REFUSED")")
                    .accessibilityIdentifier("liveWristContactState")
                ForEach(session.liveWristBlockers,id:\.self) { reason in Text(reason.explanation).font(.caption2) }
                Text("Accepted P1/P2: \(service.currentContext?.calibrationRevisions.count ?? 0)/2 · no manual XY or radius override")
            } else {
                Text("Start camera setup, explicitly Arm a genuine pair, then confirm both players.")
                Text("Calibration and production diamond geometry are not accepted. Contact REFUSED.")
                    .accessibilityIdentifier("liveWristContactState")
            }
            if let error { Text(error).foregroundStyle(.orange).accessibilityIdentifier("liveWristActionError") }
        }
        .font(.caption).buttonStyle(.bordered).padding(10)
        .background(.black.opacity(0.85),in:.rect(cornerRadius:12))
    }
    private func perform(_ action:() throws -> Void) {
        do { try action();error = nil }
        catch { self.error = "Existing provider refused the action: \(error)" }
    }
}
#endif
