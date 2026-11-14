import Foundation

/// Player-facing words for the automatic setup. A projection of session state only; it never
/// decides that anyone is linked, calibrated or ready. No technical terms reach the players.
nonisolated struct LaserAutomaticSetupCopy: Equatable, Sendable {
    enum Action: Equatable, Sendable { case tryAgain, restartSetup, continueRound }
    let title: String
    let instruction: String
    let action: Action?
    /// The calibration stage's Sketch title ("Hi-Fi Revisi 6 NOV" › Game Set Up: Home Copy 19
    /// "stand inside the box to start", Home Copy 42 "stand still, don’t move"), shown instead of
    /// `title` while the players are placed and measured; `nil` in every other state. From the setup
    /// PHASE only, never from per-frame landmark confidence, so it cannot flicker with pose noise.
    let headline: String?
    /// At most one short line under the headline, only when it says something the boxes do not
    /// (a player's current problem, a player still missing).
    let headlineDetail: String?

    static let placementHeadline = "stand inside the box to start"
    static let holdStillHeadline = "stand still, don’t move"
    var actionTitle: String? {
        switch action {
        case .tryAgain: "Try again"
        case .restartSetup: "Restart setup"
        case .continueRound: "Continue"
        case nil: nil
        }
    }

    struct Input: Equatable, Sendable {
        var isStarting = false
        var message: String?
        var sessionPhase: SessionState?
        var setupPhase: LaserSetupPhase?
        var presence = LaserSetupPresence()
        var hasRoundPlan = false
        var roundStarted = false
        var manualPause = false
        /// DEBUG Solo Test: one player, standing in the middle.
        var solo = false
        /// Why the round is not yet ready after calibration (from the live readiness gate).
        var readinessBlocker: LaserLiveReadinessBlocker?
        /// Which player the readiness gate is waiting for, and for what (`LiveEvidenceAttention`).
        var attention: [PlayerID: LiveEvidenceAttention] = [:]
        /// Whether the flow will restart setup by itself (before a round, within its bounded budget).
        var restartsAutomatically = true
        /// The paused round could not plan its recovery: it continues only when the players tap Continue.
        var recoveryNeedsContinue = false
    }

    init(_ input: Input) {
        let p = input.presence
        (headline, headlineDetail) = Self.sketchHeadline(input)
        if let message = input.message {
            (title, instruction, action) = ("Camera setup unavailable", message, .restartSetup); return
        }
        if input.isStarting {
            (title, instruction, action) = ("Starting camera…", "Allow camera access if asked.", nil); return
        }
        if input.roundStarted, input.sessionPhase == .paused, input.setupPhase == .restartRequired {
            // The round is kept, paused. Solo re-links its one player; in co-op the tracker cannot
            // re-confirm who is who in this session (it needs a new binding), so the screen says so
            // instead of promising a resume (iPad, 13 November 2026).
            (title, instruction, action) = input.solo
                ? ("Tracking paused",
                   "Return to the middle to continue. Your score is kept. If tracking doesn't recover, restart setup.", .restartSetup)
                : ("Tracking paused",
                   "We can't tell who is who anymore. Restart setup to calibrate again; this round will end.", .restartSetup)
            return
        }
        if input.sessionPhase == .restartRequired || input.setupPhase == .restartRequired {
            // Only promise an automatic restart the flow will actually make.
            (title, instruction, action) = ("Let's start again", input.restartsAutomatically
                ? "We lost track of who is who. Stand in your places; setup restarts by itself."
                : "We lost track of who is who. Tap Restart setup, then stand in your places.", .restartSetup); return
        }
        if input.sessionPhase == .paused {
            if input.manualPause {
                (title, instruction, action) = ("Round paused", "Get back to your places when you're ready.", .continueRound)
            } else if input.roundStarted {
                if input.recoveryNeedsContinue {
                    (title, instruction, action) = ("Round paused", "Stand in your places, then tap Continue. Your score is kept.",
                                                    .continueRound)
                } else if input.readinessBlocker == .presentation {
                    (title, instruction, action) = ("Round paused", "The round will continue when the game is ready.", nil)
                } else {
                    let who = LiveEvidenceAttention.line(input.attention, solo: input.solo)
                        ?? "Stand in your places with your whole body in view."
                    (title, instruction, action) = ("Tracking paused", "\(who) The round continues by itself; your score is kept.", nil)
                }
            } else {
                let who = LiveEvidenceAttention.line(input.attention, solo: input.solo) ?? "Stand in your places, upright and still."
                (title, instruction, action) = ("Get back in position", "\(who) The countdown restarts by itself.", nil)
            }
            return
        }
        switch input.setupPhase {
        case .confirmPlayers:
            (title, instruction, action) = ("Players found!", "Stay in your places.", nil)
        case .awaitingCalibration:
            (title, instruction, action) = ("Stand still and upright!", "Arms relaxed, head and feet in view.", nil)
        case .calibrating:
            let hint = Self.worstIssue(p).map { Self.hint($0, solo: input.solo) } ?? "Measuring… keep still."
            (title, instruction, action) = ("Stand still and upright!", hint, nil)
        case .reviewCandidate:
            (title, instruction, action) = ("Got it!", "Hold on…", nil)
        case .blocked:
            let hint = p.lastIssue.map { Self.hint($0, solo: input.solo) } ?? "Stand upright and still, head and feet in view."
            if p.willRetry {
                (title, instruction, action) = ("Let's try that again", hint, nil)
            } else {
                (title, instruction, action) = ("Calibration didn't finish", hint, .tryAgain)
            }
        case .awaitingGameplayReadiness:
            guard input.hasRoundPlan else { (title, instruction, action) = ("Calibrated!", "Preparing the round…", nil); return }
            // Name what readiness is waiting for, so the screen never looks stuck.
            let waiting: String = switch input.readinessBlocker {
            case .measurements: LiveEvidenceAttention.line(input.attention, solo: input.solo)
                ?? "Stay in view from head to toe, facing the iPad, hands visible."
            case .staleEvidence, .source: "Stay in view; the camera lost you for a moment."
            case .binding: input.solo ? "Stay in the middle." : "Stay in your own places."
            default: "Hold your places, the round starts in a moment."
            }
            (title, instruction, action) = ("Get ready!", waiting, nil)
        case .inactive, .awaitingBinding, .binding, .waitingForReliablePair, .restartRequired, nil:
            let instruction = Self.finding(peopleInView: p.peopleInView, solo: input.solo)
            (title, self.instruction, action) = (input.solo ? "Step into the middle" : "Step into your places", instruction, nil)
        }
    }

    /// While the players are being found: what the camera sees.
    static func finding(peopleInView: Int, solo: Bool) -> String {
        if solo {
            return switch peopleInView {
            case 0: "Stand in the middle, head to toe in view."
            case 1: "Hold still while we find you…"
            default: "Solo test needs just one person in view. Ask others to step out."
            }
        }
        return switch peopleInView {
        case 0: "P1 on the left, P2 on the right. Make sure the camera sees you both from head to toe."
        case 1: "We can see one player. Waiting for the second."
        default: "Hold your places while we find you both…"
        }
    }

    /// The Sketch headline for this state and its optional line, or `nil` outside placement and
    /// measuring (errors, retries, the round's own states keep their copy above).
    static func sketchHeadline(_ input: Input) -> (String?, String?) {
        guard input.message == nil, !input.isStarting, !input.roundStarted,
              input.sessionPhase != .paused, input.sessionPhase != .restartRequired else { return (nil, nil) }
        switch input.setupPhase {
        case .inactive, .awaitingBinding, .binding, .waitingForReliablePair:
            // Only when someone is still missing; with everyone in view the boxes say it all.
            let wanted = input.solo ? 1 : 2
            let detail = input.presence.peopleInView < wanted || input.presence.peopleInView > wanted
                ? finding(peopleInView: input.presence.peopleInView, solo: input.solo) : nil
            return (placementHeadline, detail)
        case .confirmPlayers:
            return (placementHeadline, nil)
        case .awaitingCalibration, .reviewCandidate:
            return (holdStillHeadline, nil)
        case .calibrating:
            // A player's current problem, named, so the right person fixes it.
            let issue = PlayerID.allCases.lazy.compactMap { player -> String? in
                guard case .calibrating(_, let issue?) = input.presence.players[player], issue != .moving else { return nil }
                return input.solo ? hint(issue, solo: true) : "\(player == .player1 ? "P1" : "P2"): \(hint(issue))"
            }.first
            return (holdStillHeadline, issue)
        default:
            return (nil, nil)
        }
    }

    /// The most useful hint while calibrating: the first player's current problem.
    static func worstIssue(_ presence: LaserSetupPresence) -> StandingSampleIssue? {
        for player in PlayerID.allCases {
            if case .calibrating(_, let issue?) = presence.players[player] { return issue }
        }
        return nil
    }

    static func hint(_ issue: StandingSampleIssue, solo: Bool = false) -> String {
        switch issue {
        case .notSeparated where solo: "Make sure you're the only person in view."
        case .notSeparated: "Move a little further apart."
        case .trackingLost: "Stay in your own place."
        case .bodyNotFullyVisible: "Make sure your whole body is in view."
        case .faceNotVisible: "Face the iPad so your face is visible."
        case .feetNotVisible: "Make sure both feet are visible."
        case .notUpright: "Stand up straight."
        case .headCutOff: "Step back so your head is in view."
        case .feetCutOff: "Step back so your feet are in view."
        case .headObstructed: "Keep your hands below your head."
        case .headUnclear: "Face the iPad and hold still, head clear of the background."
        case .feetTogether: "Stand with your feet a little apart."
        case .feetUnclear: "Stand with both feet flat, clearly visible on the floor."
        case .moving: "Hold still."
        case .tooFar: "Step closer, about 2–3 m from the iPad, facing it."
        }
    }

    /// Short chip text under each standing guide.
    static func chip(_ player: PlayerID, _ status: LaserSetupPlayerStatus, solo: Bool = false) -> String {
        let name = player == .player1 ? "P1" : "P2"
        switch status {
        case .searching: return "\(name) · Step in"
        case .linked: return "\(name) · Found"
        case .calibrating(let progress, let issue):
            let percent = Int((min(1, max(0, progress)) * 100).rounded())
            return issue == .moving || issue == nil ? "\(name) · \(percent)%" : "\(name) · \(Self.shortHint(issue!, solo: solo))"
        case .ready: return "\(name) · Ready"
        }
    }

    static func shortHint(_ issue: StandingSampleIssue, solo: Bool = false) -> String {
        switch issue {
        case .notSeparated where solo: "Only you in view"
        case .notSeparated: "Move apart"
        case .trackingLost: "Stay in place"
        case .bodyNotFullyVisible: "Whole body in view"
        case .faceNotVisible: "Face the iPad"
        case .feetNotVisible: "Show both feet"
        case .notUpright: "Stand up straight"
        case .headCutOff: "Head in view"
        case .feetCutOff: "Feet in view"
        case .headObstructed: "Hands below head"
        case .headUnclear: "Face the iPad"
        case .feetTogether: "Feet apart"
        case .feetUnclear: "Feet flat"
        case .moving: "Hold still"
        case .tooFar: "Step closer"
        }
    }
}
