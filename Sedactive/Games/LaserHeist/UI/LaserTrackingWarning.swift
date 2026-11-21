import SwiftUI

/// The in-round tracking warning (`LaserHeistUI/Recalibrate`, Theo's "Please Fix Your Standing
/// Position", 13 November 2026). A projection of the session's own state only: it never pauses,
/// resumes, binds or calibrates anything, and it keeps no clock.
///
/// - Shown while a STARTED round is paused for a tracking reason: a player not tracked (left the
///   view, uncertain, no usable packet), the pair unconfirmed, stale evidence or a lost source, or
///   an identity that needs a fresh binding.
/// - Not shown for a pause caused only by a missing landmark of a tracked player (a wrist hidden
///   in a duck): the setup stage's own hint names it ("P1: keep your hands in view").
/// - Not shown during calibration, before the round, for a manual pause, or when the game scene
///   (not tracking) holds the round.
/// - It ends when the session leaves the pause: the countdown (same players recovered) or a new
///   setup after Recalibrate (identity lost). Recalibrate is the existing "Restart setup".
nonisolated struct LaserTrackingWarning: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        /// Waiting for players to come back into view.
        case waitingForPlayers
        /// Everyone is usable again; the session's readiness check runs before its countdown.
        case recovering
        /// The tracker can no longer tell who is who: only a fresh setup (binding and calibration).
        case needsRecalibration
    }
    enum Action: Equatable, Sendable { case recalibrate, continueRound }

    let stage: Stage
    let detail: String
    /// The prominent button, if this stage has one.
    let primary: Action?

    struct Input: Equatable, Sendable {
        var roundStarted = false
        var roundEnded = false
        var sessionPhase: SessionState?
        var setupPhase: LaserSetupPhase?
        var readinessBlocker: LaserLiveReadinessBlocker?
        var awaitsIdentityRecovery = false
        var recoveryNeedsContinue = false
        var hasPacket = true
        var attention: [PlayerID: LiveEvidenceAttention] = [:]
        var solo = false

        /// The session's state for the warning (one mapping for the screen and the tests).
        @MainActor init(session: GameSessionCoordinator) {
            roundStarted = session.state != nil
            roundEnded = session.summary != nil
            sessionPhase = session.phase
            setupPhase = session.setup?.phase
            readinessBlocker = session.liveReadiness?.blocker
            awaitsIdentityRecovery = session.awaitsIdentityRecovery
            recoveryNeedsContinue = session.recoveryNeedsPlan
            hasPacket = session.latestSnapshot != nil
            attention = LiveEvidenceAttention.players(session.latestSnapshot, roster: session.inputConfiguration.roster)
            solo = session.isSoloPractice
        }

        init(roundStarted: Bool = false, roundEnded: Bool = false, sessionPhase: SessionState? = nil,
             setupPhase: LaserSetupPhase? = nil, readinessBlocker: LaserLiveReadinessBlocker? = nil,
             awaitsIdentityRecovery: Bool = false, recoveryNeedsContinue: Bool = false, hasPacket: Bool = true,
             attention: [PlayerID: LiveEvidenceAttention] = [:], solo: Bool = false) {
            self.roundStarted = roundStarted; self.roundEnded = roundEnded; self.sessionPhase = sessionPhase
            self.setupPhase = setupPhase; self.readinessBlocker = readinessBlocker
            self.awaitsIdentityRecovery = awaitsIdentityRecovery; self.recoveryNeedsContinue = recoveryNeedsContinue
            self.hasPacket = hasPacket; self.attention = attention; self.solo = solo
        }

        /// A started round held by the session for tracking (not a manual or scene pause).
        var isTrackingPause: Bool {
            guard roundStarted, !roundEnded else { return false }
            guard sessionPhase == .paused || sessionPhase == .restartRequired || setupPhase == .restartRequired else { return false }
            return readinessBlocker != .manualPause && readinessBlocker != .presentation
        }

        var identityLost: Bool {
            !solo && (setupPhase == .restartRequired || sessionPhase == .restartRequired || awaitsIdentityRecovery)
        }
    }

    /// Whether this state by itself calls for the warning: a tracking reason, not a landmark.
    static func triggers(_ input: Input) -> Bool {
        guard input.isTrackingPause else { return false }
        if input.identityLost || input.awaitsIdentityRecovery || !input.hasPacket { return true }
        if input.attention.values.contains(.tracking) { return true }
        return [.binding, .staleEvidence, .source].contains(input.readinessBlocker)
    }

    /// What the warning shows for this state (once it is up).
    init(_ input: Input) {
        if input.identityLost {
            (stage, detail, primary) = (.needsRecalibration,
                "We can't tell who is who anymore. Recalibrate to keep playing; this round will end.", .recalibrate)
        } else if input.recoveryNeedsContinue {
            (stage, detail, primary) = (.recovering, "Everyone is back. Tap Continue to resume; your score is kept.", .continueRound)
        } else if input.hasPacket, input.attention.isEmpty {
            (stage, detail, primary) = (.recovering, "Found you! Hold still, the round continues in a moment.", nil)
        } else {
            let who = LiveEvidenceAttention.line(input.attention, solo: input.solo)
                ?? (input.solo ? "Stand in the middle, whole body in view." : "Stand in your places, whole body in view.")
            (stage, detail, primary) = (.waitingForPlayers, "\(who) Your score is kept.", nil)
        }
    }
}

/// A started round's pause that is NOT tracking loss (a tracked player's hidden landmark, the
/// game scene not ready, or a recovery that needs a tap), shown as a compact notice over the
/// frozen game instead of the full warning. A manual pause shows the HUD's own pause menu.
nonisolated struct LaserRoundPauseNotice: Equatable, Sendable {
    let text: String
    let offersContinue: Bool

    init?(_ input: LaserTrackingWarning.Input) {
        guard input.roundStarted, !input.roundEnded, input.sessionPhase == .paused,
              input.readinessBlocker != .manualPause else { return nil }
        if input.recoveryNeedsContinue {
            (text, offersContinue) = ("Round paused. Stand in your places, then tap Continue.", true)
        } else if input.readinessBlocker == .presentation {
            (text, offersContinue) = ("Round paused. It continues when the game is ready.", false)
        } else {
            let who = LiveEvidenceAttention.line(input.attention, solo: input.solo) ?? "Hold your places."
            (text, offersContinue) = ("Paused. \(who) The round continues by itself.", false)
        }
    }
}

/// Presentation hysteresis tied to the session's pause, not to time: once a tracking pause has
/// shown the warning it stays up until that pause ends (countdown, running, a new setup or the
/// round's end), so a player half back in view never flips the screen between the warning and
/// the setup stage.
nonisolated struct LaserTrackingWarningLatch: Equatable, Sendable {
    private(set) var latched = false

    /// The warning for this state, and the latch for the next.
    mutating func update(_ input: LaserTrackingWarning.Input) -> LaserTrackingWarning? {
        guard input.isTrackingPause else { latched = false; return nil }
        latched = latched || LaserTrackingWarning.triggers(input)
        return latched ? LaserTrackingWarning(input) : nil
    }

    /// The same decision without changing the latch (rendering before `update` runs).
    func peek(_ input: LaserTrackingWarning.Input) -> LaserTrackingWarning? {
        var copy = self
        return copy.update(input)
    }
}

/// The full-screen warning over the (still mounted) setup stage, landscape, the supplied art
/// aspect-fit and unaltered on its own frame colours, the status and actions beneath it.
struct LaserTrackingWarningOverlay: View {
    let flow: LaserInputFlow
    let session: GameSessionCoordinator
    @State private var latch = LaserTrackingWarningLatch()

    var body: some View {
        let input = LaserTrackingWarning.Input(session: session)
        Group {
            if let warning = latch.peek(input) {
                LaserTrackingWarningScreen(warning: warning, busy: flow.isStarting || flow.isClosing,
                    recalibrate: { Task { await flow.retryLiveSetup() } },
                    continueRound: { session.continueLiveRound() },
                    leave: { Task { await flow.closeLiveSetup() } })
                .transition(.opacity)
            } else if let notice = LaserRoundPauseNotice(input) {
                LaserRoundPauseNoticeView(notice: notice, continueRound: { session.continueLiveRound() })
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: latch.peek(input)?.stage)
        .onChange(of: input, initial: true) { _, value in _ = latch.update(value) }
    }
}

/// The compact pause notice: a card under the HUD, over the frozen game.
struct LaserRoundPauseNoticeView: View {
    let notice: LaserRoundPauseNotice
    var continueRound: () -> Void = {}

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "pause.circle.fill").font(.title).foregroundStyle(LaserTrackingWarningScreen.cream)
                .accessibilityHidden(true)
            Text(notice.text)
                .font(.title3.weight(.semibold))
                .foregroundStyle(LaserTrackingWarningScreen.cream)
                .lineLimit(2)
                .accessibilityIdentifier("roundPauseNotice")
            if notice.offersContinue {
                Button("Continue", action: continueRound)
                    .buttonStyle(.borderedProminent).tint(.orange).foregroundStyle(.black).controlSize(.large)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(LaserTrackingWarningScreen.frameBottom.opacity(0.92), in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(LaserTrackingWarningScreen.cream.opacity(0.35), lineWidth: 2))
        .frame(maxWidth: 900)
        .padding(.top, 200)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }
}

struct LaserTrackingWarningScreen: View {
    let warning: LaserTrackingWarning
    var busy = false
    var recalibrate: () -> Void = {}
    var continueRound: () -> Void = {}
    var leave: () -> Void = {}

    static let frameTop = Color(red: 43 / 255, green: 40 / 255, blue: 87 / 255)
    static let frameBottom = Color(red: 32 / 255, green: 30 / 255, blue: 69 / 255)
    static let cream = Color(red: 254 / 255, green: 229 / 255, blue: 187 / 255)

    var body: some View {
        ZStack {
            LinearGradient(colors: [Self.frameTop, Self.frameBottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Image("LaserHeistUI/Recalibrate")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .accessibilityLabel("Please fix your standing position")
                    .accessibilityIdentifier("trackingWarning")
                    .layoutPriority(1)
                Text(warning.detail)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Self.cream)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .accessibilityIdentifier("trackingWarningDetail")
                HStack(spacing: 14) {
                    switch warning.primary {
                    case .recalibrate:
                        Button("Recalibrate", action: recalibrate)
                            .buttonStyle(.borderedProminent).tint(.orange).foregroundStyle(.black)
                            .accessibilityIdentifier("trackingWarningRecalibrate")
                    case .continueRound:
                        Button("Continue", action: continueRound)
                            .buttonStyle(.borderedProminent).tint(.orange).foregroundStyle(.black)
                            .accessibilityIdentifier("trackingWarningContinue")
                        Button("Recalibrate", action: recalibrate).buttonStyle(.bordered).tint(Self.cream)
                    case nil:
                        // Never a trap: the players can always choose a fresh setup instead of waiting.
                        Button("Recalibrate", action: recalibrate).buttonStyle(.bordered).tint(Self.cream)
                            .accessibilityIdentifier("trackingWarningRecalibrate")
                    }
                    Button("Leave", role: .cancel, action: leave).buttonStyle(.bordered).tint(Self.cream)
                }
                .controlSize(.large)
                .disabled(busy)
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .preferredColorScheme(.dark)
    }
}
