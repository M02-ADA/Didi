#if DEBUG
import SwiftUI

/// DEBUG tester panel over a live round (Solo Test and co-op test rounds; never Release). Both
/// skips stay visible from the round's start to its Results, whatever the tracking does, and
/// are enabled only while they have a destination:
/// - "Skip to Next Gate" shortens the current activity minute so its vault arrives in a few
///   seconds (`GameSessionCoordinator.debugSkipToNextGate`); off at a gate, after the last one,
///   and while the round is paused (a resume may still plan replacement lasers before it).
/// - "Skip to Diamond Time" enters the real Diamond Time through the coordinator; a paused
///   round applies it on resume. Off from Diamond Time on.
/// In a Solo Test, P1's three gate buttons can also be tapped as a fallback for the wrist press.
/// Tracking is shown as the producer reports it; nothing here creates body evidence.
struct DebugRoundControls: View {
    let session: GameSessionCoordinator

    var body: some View {
        // Game time moves without SwiftUI state changes: re-read a few times a second.
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            VStack(alignment: .leading, spacing: 6) {
                Text(session.isSoloPractice ? "DEBUG · SOLO TEST" : "DEBUG · CO-OP TEST")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                Text(status).font(.system(size: 11, design: .monospaced))
                ForEach(session.inputConfiguration.roster, id: \.self) { player in
                    Text(tracking(player)).font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(isTracked(player) ? Color.green : Color.orange)
                    if let steer = steering(player) {
                        Text(steer).font(.system(size: 10, design: .monospaced))
                    }
                    // At a gate: the judge's own reading of each wrist (nearest button, distance in
                    // zone radii, status, press) and the zone shift.
                    if session.state?.phase == .vault, let contact = GameSessionCoordinator.debugVaultContact[player] {
                        Text("  gate: " + contact).font(.system(size: 9, design: .monospaced)).lineLimit(3)
                    }
                }
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
                }
                HStack(spacing: 6) {
                    Button("Skip to Next Gate") { session.debugSkipToNextGate() }
                        .disabled(!session.canDebugSkipToNextGate)
                        .accessibilityIdentifier("debugSkipToNextGate")
                    Button(session.debugPendingSkipToDiamondTime ? "Diamond Time queued" : "Skip to Diamond Time") {
                        session.debugSkipToDiamondTime()
                    }
                    .disabled(!session.canDebugSkipToDiamondTime)
                    .accessibilityIdentifier("debugSkipToDiamondTime")
                }
                .buttonStyle(.borderedProminent).tint(.yellow).controlSize(.small)
                Text(skipNote).font(.system(size: 10, design: .monospaced))
                testMove
            }
            .foregroundStyle(.white)
            .padding(10)
            .background(.black.opacity(0.65), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yellow, lineWidth: 1.5))
            .frame(maxWidth: 300, alignment: .leading)
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
        let paused = session.phase == .paused ? " · PAUSED" : ""
        let next = session.liveVaultIn.map { String(format: " · gate in %.0f s", $0) } ?? ""
        return "gate \(state.missionProgress)/\(state.missionTarget) · \(phase)\(next)\(paused)"
    }

    /// Why a skip is off, or what the skips did (never scored).
    private var skipNote: String {
        let lasers = session.debugGateSkips.map(\.droppedLasers).reduce(0, +)
            + session.debugSkips.map(\.withdrawnTargets).reduce(0, +)
        let done = session.debugGateSkips.isEmpty && session.debugSkips.isEmpty ? "" : " · skipped \(lasers) lasers (not scored)"
        switch session.state?.phase {
        case .vault?: return "at a gate: next gate after it" + done
        case .diamondTime?, .ended?: return "Diamond Time reached: no skips" + done
        default: break
        }
        if session.phase == .paused { return "paused: Diamond Time applies on resume" + done }
        if session.state?.phase == .activity, !session.canDebugSkipToNextGate { return "next gate is already close or none left" + done }
        return done.isEmpty ? "skips never score" : String(done.dropFirst(3))
    }

    /// DEBUG steering diagnostic, apart from the skips: moves Lemon through the same steering
    /// controller and entity update as a lean, without Vision. If this moves Lemon and a lean
    /// does not, the lean input is at fault; if neither does, the transform path is.
    private var testMove: some View {
        let active = RobotAvatarLayer.debugTestSteer
        return VStack(alignment: .leading, spacing: 4) {
            Text("STEERING TEST (P1, no Vision)").font(.system(size: 10, weight: .heavy, design: .monospaced))
            HStack(spacing: 6) {
                Button("◀ Test Move Left") { RobotAvatarLayer.debugTestSteer = -RobotAvatarLayer.debugTestSteerSpeed }
                    .tint(active.map { $0 < 0 } == true ? .green : .cyan)
                    .accessibilityIdentifier("debugTestMoveLeft")
                Button("Test Move Right ▶") { RobotAvatarLayer.debugTestSteer = RobotAvatarLayer.debugTestSteerSpeed }
                    .tint(active.map { $0 > 0 } == true ? .green : .cyan)
                    .accessibilityIdentifier("debugTestMoveRight")
                Button("Stop Test Move") { RobotAvatarLayer.debugTestSteer = nil }
                    .tint(.gray)
                    .disabled(active == nil)
                    .accessibilityIdentifier("debugTestMoveStop")
            }
            .buttonStyle(.borderedProminent).controlSize(.mini)
        }
        .padding(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.cyan, lineWidth: 1))
    }

    /// Lean steering, as the mascot shows it: filtered lean, speed, travel, applied world X, limit.
    private func steering(_ player: PlayerID) -> String? {
        guard let r = RobotAvatarLayer.debugSteering[player] else { return nil }
        let lean = r.filteredLean.map { String(format: "%+.3f", $0) } ?? "-"
        let partner = r.partnerDistance.map { String(format: " · gap %.2f", $0) } ?? ""
        let screen = r.screenX.map { String(format: " · screen %.2f", $0) } ?? ""
        let age = r.poseAge.map { String(format: "%.2f s", $0) } ?? "none"
        return String(format: "  %@ lean %@ h → %+.2f m/s · v %+.2f · x %+.2f m (board %+.2f)%@ · %@%@ · pose %@",
                      r.solo ? "SOLO" : "CO-OP", lean, r.targetSpeed, r.velocity, r.appliedX, r.boardWorldX ?? .nan,
                      screen, r.constraint.rawValue, partner, age)
    }

    private func isTracked(_ player: PlayerID) -> Bool {
        session.latestSnapshot?.players[player]?.trackingStatus == .reliable
    }

    private func tracking(_ player: PlayerID) -> String {
        let name = player == .player1 ? "P1" : "P2"
        if isTracked(player) { return "\(name) tracked" }
        if player == .player1, session.debugSoloTrackingLost { return "P1 lost · no evidence (UNAVAILABLE)" }
        return "\(name) not tracked · no evidence (UNAVAILABLE)"
    }
}
#endif
