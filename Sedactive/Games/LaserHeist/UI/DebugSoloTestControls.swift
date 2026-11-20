#if DEBUG
import SwiftUI

/// DEBUG tester panel over a live round (Solo Test and co-op test rounds; never Release): a small
/// card under the HUD's pause button, from the round's start to its Results, whatever the tracking
/// does. Compact by default: the round type, the gate count and the two skips, enabled only while
/// they have a destination:
/// - "Next Gate" shortens the current activity minute so its vault arrives in a few seconds
///   (`GameSessionCoordinator.debugSkipToNextGate`); off at a gate, after the last one, and while
///   the round is paused (a resume may still plan replacement lasers before it).
/// - "Diamond Time" requests resume from a manual pause and enters the real phase once the
///   round is running. If tracking is blocked, the skip waits for recovery. Off from Diamond Time on.
/// Skips never score. In a Solo Test, P1's three gate buttons can also be tapped as a fallback for
/// the wrist press (shown only at an open gate). Tracking, steering, gate contact and the steering
/// test sit under Advanced (collapsed; it scrolls). Tracking is shown as the producer reports it;
/// nothing here creates body evidence.
///
/// Placement (17 November 2026): the old 300 pt panel hung over P2's wall console. The card now
/// stays in the top band, above the mascots' heads and well above both players' gate consoles
/// (`maxBottomFraction`); Advanced closes by itself when a gate opens, and only the card's own
/// controls take touches.
struct DebugRoundControls: View {
    let session: GameSessionCoordinator
    var isHidden = false
    var onClose: (() -> Void)? = nil

    var onHide: (() -> Void)? = nil
    @State private var showsAdvanced = false
    @State private var isMinimized = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The card never reaches below this share of the screen height: the gate consoles start at
    /// about 51 % (landscape 11-inch iPad, `-gateConsolePreview`), the mascots' heads at about 35 %.
    /// Only Advanced, opened on demand, reaches past the heads' top.
    static let maxBottomFraction: CGFloat = 0.46
    /// The compact card's width (points): it ends left of the PERFECT!/ZAPPED! callout's ring
    /// (about x 913 pt on the 1210 pt screen), with the skips stacked. Advanced widens it, on demand.
    static let width: CGFloat = 218
    static let advancedWidth: CGFloat = 300
    /// `-debugRoundControlsPreview`: the card over a replay (`PlayView`), for Simulator layout review.
    static var previewRequested: Bool { ProcessInfo.processInfo.arguments.contains("-debugRoundControlsPreview") }

    var body: some View {
        GeometryReader { proxy in
            // The HUD's own Sketch scale (1210 × 834 pt artboard): the card sits just under its pause
            // button (bottom at 58 + 66 pt), right edges aligned (`GameplayHUD.topBar`).
            let k = min(proxy.size.width / 1210, proxy.size.height / 834)
            let trailing = max(16, (proxy.size.width - 1090.4 * k) / 2)
            let top = 134 * k
            let maxHeight = max(120, proxy.size.height * Self.maxBottomFraction - top)
            card(maxHeight: maxHeight)
                .padding(.top, top)
                .padding(.trailing, trailing)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topTrailing)
        }
        .ignoresSafeArea()
    }

    // MARK: - Card

    @ViewBuilder private func card(maxHeight: CGFloat) -> some View {
        // Game time moves without SwiftUI state changes: re-read a few times a second.
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let atGate = session.state?.phase == .vault
            Group {
                if isMinimized {
                    pill
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        if isHidden {
                            Color.clear.frame(height: 26).allowsHitTesting(false)
                        } else {
                            header.frame(height: 26)
                        }
                        skips
                        if !isHidden, let pressed = session.debugSoloVaultPressed { soloVaultButtons(pressed) }
                        if !isHidden, showsAdvanced {
                            Divider().overlay(Self.hairline)
                            // What is left under the header, the skips and (at a Solo gate) P1's buttons.
                            advanced(maxHeight: maxHeight - (session.debugSoloVaultPressed == nil ? 104 : 144))
                                .transition(.opacity)
                        }
                    }
                    .padding(10)
                    .frame(width: showsAdvanced ? Self.advancedWidth : Self.width, alignment: .leading)
                    .background(isHidden ? Color.clear : Self.surface, in: .rect(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(isHidden ? Color.clear : Self.hairline, lineWidth: 1)
                        .allowsHitTesting(false))
                    .frame(maxHeight: maxHeight, alignment: .top)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("debugRoundControls")
                    .transition(.opacity)
                }
            }
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            // A gate is when the players reach for their consoles: Advanced closes so the card
            // stays at its smallest; it can be reopened.
            .onChange(of: atGate) { _, nowAtGate in
                if nowAtGate, showsAdvanced { toggle { showsAdvanced = false } }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("DEBUG")
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .foregroundStyle(.black)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Self.accent, in: .capsule)
            Text(stage)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityIdentifier("debugStage")
            Spacer(minLength: 0)
            iconButton(showsAdvanced ? "chevron.up" : "slider.horizontal.3",
                       label: showsAdvanced ? "Hide advanced debug" : "Show advanced debug",
                       id: "debugAdvancedToggle", active: showsAdvanced) {
                toggle { showsAdvanced.toggle() }
            }
            if let onClose {
                if let onHide {
                    iconButton("eye.slash", label: "Hide developer tools", id: "debugHide", action: onHide)
                }
                iconButton("xmark", label: "Close debug controls", id: "debugClose") { onClose() }
            } else {
                iconButton("minus", label: "Minimize debug controls", id: "debugMinimize") {
                    toggle { isMinimized = true }
                }
            }
        }
    }

    /// Stacked in the narrow compact card; side by side once Advanced widens it.
    private var skips: some View {
        let layout = showsAdvanced ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 6))
        return layout {
            Button { session.debugSkipToNextGate() } label: {
                Label("Next Gate", systemImage: "forward.end.fill")
            }
            .disabled(!session.canDebugSkipToNextGate)
            .accessibilityIdentifier("debugSkipToNextGate")
            Button { session.debugSkipToDiamondTime() } label: {
                Label(session.debugPendingSkipToDiamondTime ? "Queued" : "Diamond Time", systemImage: "diamond.fill")
            }
            .disabled(!session.canDebugSkipToDiamondTime)
            .accessibilityIdentifier("debugSkipToDiamondTime")
            .accessibilityHint(session.debugPendingSkipToDiamondTime ? "Diamond Time applies on resume" : "")
        }
        .buttonStyle(DebugSkipButtonStyle(isHidden: isHidden))
    }

    /// Solo Test fallback for P1's gate buttons, only while P1's gate is open.
    private func soloVaultButtons(_ pressed: Set<LaserVaultButton>) -> some View {
        HStack(spacing: 6) {
            Text("P1 GATE").font(.system(size: 10, weight: .heavy, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
            ForEach(LaserVaultButton.allCases, id: \.self) { button in
                Button(label(button)) { session.debugPressVaultButton(button) }
                    .tint(pressed.contains(button) ? .green : Self.accent)
                    .disabled(pressed.contains(button))
                    .accessibilityIdentifier("debugSoloVault.\(button.rawValue)")
            }
        }
        .buttonStyle(.borderedProminent).controlSize(.small)
    }

    /// The minimized card: one small capsule that brings it back.
    private var pill: some View {
        Button { toggle { isMinimized = false } } label: {
            HStack(spacing: 5) {
                Image(systemName: "ladybug.fill")
                Text("DEBUG")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 11, weight: .heavy, design: .monospaced))
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Self.accent.opacity(0.9), in: .capsule)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show debug controls")
        .accessibilityIdentifier("debugExpand")
    }

    // MARK: - Advanced

    /// Everything that is not a skip: round status, tracking, steering, gate contact and the
    /// steering test. Scrolls only when it does not fit under the card's height limit.
    private func advanced(maxHeight: CGFloat) -> some View {
        ViewThatFits(in: .vertical) {
            advancedContent
            ScrollView { advancedContent }.scrollIndicators(.visible)
        }
        .frame(maxHeight: max(60, maxHeight))
    }

    private var advancedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            section("ROUND") {
                Text(status).font(.system(size: 10, design: .monospaced))
                Text(skipNote).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
            }
            section("TRACKING") {
                ForEach(session.inputConfiguration.roster, id: \.self) { player in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tracking(player)).font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(isTracked(player) ? Color.green : Color.orange)
                        if let steer = steering(player) {
                            Text(steer).font(.system(size: 9, design: .monospaced))
                        }
                        // At a gate: the judge's own reading of each wrist (nearest button, distance in
                        // zone radii, status, press) and the zone shift.
                        if session.state?.phase == .vault, let contact = GameSessionCoordinator.debugVaultContact[player] {
                            Text("gate: " + contact).font(.system(size: 9, design: .monospaced)).lineLimit(3)
                        }
                    }
                }
            }
            testMove
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(Self.accent)
            content()
        }
    }

    /// DEBUG steering diagnostic, apart from the skips: moves Lemon through the same steering
    /// controller and entity update as a lean, without Vision. If this moves Lemon and a lean
    /// does not, the lean input is at fault; if neither does, the transform path is.
    private var testMove: some View {
        let active = RobotAvatarLayer.debugTestSteer
        return section("STEERING TEST · P1, no Vision") {
            HStack(spacing: 6) {
                Button("◀ Left") { RobotAvatarLayer.debugTestSteer = -RobotAvatarLayer.debugTestSteerSpeed }
                    .tint(active.map { $0 < 0 } == true ? .green : .cyan)
                    .accessibilityLabel("Test Move Left")
                    .accessibilityIdentifier("debugTestMoveLeft")
                Button("Right ▶") { RobotAvatarLayer.debugTestSteer = RobotAvatarLayer.debugTestSteerSpeed }
                    .tint(active.map { $0 > 0 } == true ? .green : .cyan)
                    .accessibilityLabel("Test Move Right")
                    .accessibilityIdentifier("debugTestMoveRight")
                Button("Stop") { RobotAvatarLayer.debugTestSteer = nil }
                    .tint(.gray)
                    .disabled(active == nil)
                    .accessibilityLabel("Stop Test Move")
                    .accessibilityIdentifier("debugTestMoveStop")
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
        }
    }

    // MARK: - Parts

    private func iconButton(_ symbol: String, label: String, id: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(active ? .black : .white)
                .frame(width: 28, height: 26)
                .background(active ? Self.accent : .white.opacity(0.12), in: .rect(cornerRadius: 7, style: .continuous))
                // A comfortable target without a bigger card: 36 × 36 pt around the 28 × 26 glyph.
                .frame(width: 36, height: 36)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.vertical, -5)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func toggle(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { change() }
    }

    private static let accent = Color.yellow
    private static let surface = Color(red: 0.07, green: 0.06, blue: 0.16).opacity(0.78)
    private static let hairline = Color.yellow.opacity(0.45)

    private func label(_ button: LaserVaultButton) -> String {
        switch button { case .top: "▲"; case .middle: "●"; case .bottom: "▼" }
    }

    /// The compact round and stage indicator: Solo or co-op, gates so far, and a gate, Diamond
    /// Time or pause (the time to the next gate is under Advanced).
    private var stage: String {
        let mode = session.isSoloPractice ? "SOLO" : "CO-OP"
        guard let state = session.state else { return mode }
        let gates = "\(mode) \(state.missionProgress)/\(state.missionTarget)"
        if session.phase == .paused { return gates + " · ❚❚" }
        switch state.phase {
        case .vault: return gates + " · GATE"
        case .diamondTime: return gates + " · ◆"
        case .ended, .activity: return gates
        }
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

    /// Lean steering, as the mascot shows it: filtered lean, speed, travel, applied world X, limit.
    private func steering(_ player: PlayerID) -> String? {
        guard let r = RobotAvatarLayer.debugSteering[player] else { return nil }
        let lean = r.filteredLean.map { String(format: "%+.3f", $0) } ?? "-"
        let partner = r.partnerDistance.map { String(format: " · gap %.2f", $0) } ?? ""
        let screen = r.screenX.map { String(format: " · screen %.2f", $0) } ?? ""
        let age = r.poseAge.map { String(format: "%.2f s", $0) } ?? "none"
        return String(format: "%@ lean %@ h → %+.2f m/s · v %+.2f · x %+.2f m (board %+.2f)%@ · %@%@ · pose %@",
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

/// The two skips: compact yellow buttons, 40 pt tall, the card's full width.
private struct DebugSkipButtonStyle: ButtonStyle {
    let isHidden: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(.black.opacity(isEnabled ? 1 : 0.45))
            .opacity(isHidden ? 0 : 1)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(isHidden ? Color.clear : Color.yellow.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35),
                        in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect(cornerRadius: 10))
    }
}
#endif
